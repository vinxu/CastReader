#!/usr/bin/env python3
"""Authenticated per-user Qwen3-TTS Base clone adapter for CastReader."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import io
import json
import math
import os
import re
import shutil
import subprocess
import threading
import time
import uuid
import wave
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import httpx
import numpy as np
import soundfile as sf
import torch
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field

from adaptive_denoise import (
    AdaptiveDenoiseError,
    DEFAULT_DEEPFILTER_SHA256,
    DEFAULT_DIARIZATION_SHA256,
    DEFAULT_SPEAKER_SHA256,
    RELATIVE_SPEAKER_FLOOR,
    DiarizationUnavailable,
    DeepFilterRunner,
    SpeakerDiarizer,
)
from audio_quality import (
    ReferenceAudioResult,
    ReferenceQualityError,
    process_reference_audio,
)
from build_prompt import VoicePromptBuilder
from inference_scheduler import (
    PRIORITY_BACKGROUND,
    PRIORITY_INTERACTIVE,
    PRIORITY_PREFETCH,
    InferenceScheduler,
    ScheduledResult,
    SchedulerDeadlineExceeded,
    SchedulerOverloaded,
)
from request_coalescer import (
    IdempotencyConflict,
    IdempotencyWaitTimeout,
    RequestCoalescer,
)
from semantic_asr import (
    SemanticASREvidence,
    SemanticASRError,
    SemanticASRUnavailable,
    SemanticASRValidator,
    SemanticAudioMismatch,
    measured_word_timestamps,
)
from xvector_activation import marker_matches_current_release


MODEL_NAME = "qwen3-tts-0.6b-base-nari"
SAMPLE_RATE = 24_000
MAX_UPLOAD_BYTES = 4 * 1024 * 1024
MAX_PROMPT_BYTES = 2 * 1024 * 1024
VOICE_ID_RE = re.compile(r"^vc_[A-Za-z0-9_-]{1,61}$")
LANGUAGE_MAP = {
    "zh": "chinese",
    "en": "english",
    "fr": "french",
    "de": "german",
    "it": "italian",
    "ja": "japanese",
    "ko": "korean",
    "pt": "portuguese",
    "ru": "russian",
    "es": "spanish",
}

DATA_ROOT = Path(os.environ.get("CLONE_DATA_ROOT", "/workspace/castreader-clone"))
VOICE_ROOT = DATA_ROOT / "voices"
TOKEN_PATH = Path(os.environ.get("CLONE_TOKEN_FILE", DATA_ROOT / ".api-token"))
XVECTOR_WRITER_MARKER = Path(
    os.environ.get(
        "CLONE_XVECTOR_WRITER_MARKER",
        DATA_ROOT / ".xvector-writer-v1-enabled",
    )
)
MODEL_DIR = Path(os.environ.get("NARI_MODEL_DIR", "/workspace/qwen3-tts-base/model-0.6b-base"))
NARI_URL = os.environ.get("NARI_URL", "http://127.0.0.1:8094").rstrip("/")
CLONE_WARMUP = os.environ.get("CLONE_WARMUP", "1").strip() == "1"
MAX_QUEUE_SIZE = int(os.environ.get("CLONE_MAX_QUEUE_SIZE", "64"))
SYNTHESIS_TIMEOUT_SECONDS = float(os.environ.get("CLONE_SYNTHESIS_TIMEOUT_SECONDS", "45"))
VOICE_BUILD_TIMEOUT_SECONDS = float(os.environ.get("CLONE_VOICE_BUILD_TIMEOUT_SECONDS", "75"))
NARI_REQUEST_TIMEOUT_SECONDS = float(os.environ.get("NARI_REQUEST_TIMEOUT_SECONDS", "30"))
NARI_XVECTOR_TOTAL_TIMEOUT_SECONDS = float(
    os.environ.get(
        "NARI_XVECTOR_TOTAL_TIMEOUT_SECONDS",
        str(min(NARI_REQUEST_TIMEOUT_SECONDS, max(1.0, SYNTHESIS_TIMEOUT_SECONDS - 1.0))),
    )
)
NARI_TEMPERATURE = float(os.environ.get("NARI_TEMPERATURE", "0.9"))
NARI_TOP_K = int(os.environ.get("NARI_TOP_K", "50"))
NARI_TOP_P = float(os.environ.get("NARI_TOP_P", "1.0"))
NARI_REPETITION_PENALTY = float(os.environ.get("NARI_REPETITION_PENALTY", "1.05"))
VOICE_SPEAKER_EMBEDDING_SIZE = int(
    os.environ.get("CLONE_SPEAKER_EMBEDDING_SIZE", "1024")
)
ASR_MODEL_DIR_VALUE = os.environ.get("CLONE_ASR_MODEL_DIR", "").strip()
ASR_MODEL_DIR = Path(ASR_MODEL_DIR_VALUE).expanduser() if ASR_MODEL_DIR_VALUE else None
ASR_WARMUP = os.environ.get("CLONE_ASR_WARMUP", "0").strip() == "1"
DENOISE_PIPELINE_VERSION = "fixed-deepfilter-atten24-v1"
DENOISE_ATTENUATION_DB = 24
REFERENCE_SPEAKER_POLICY = "warn-only-v1"
DEEPFILTER_BIN = Path(
    os.environ.get("CLONE_DEEPFILTER_BIN", DATA_ROOT / "denoise/bin/deep-filter")
)
DEEPFILTER_SHA256 = os.environ.get(
    "CLONE_DEEPFILTER_SHA256", DEFAULT_DEEPFILTER_SHA256
).strip().lower()
DIARIZATION_MODEL = Path(
    os.environ.get(
        "CLONE_DIARIZATION_MODEL",
        DATA_ROOT / "quality/models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
    )
)
SPEAKER_MODEL = Path(os.environ.get("CLONE_SPEAKER_MODEL", ""))
DIARIZATION_SHA256 = os.environ.get(
    "CLONE_DIARIZATION_SHA256", DEFAULT_DIARIZATION_SHA256
).strip().lower()
SPEAKER_MODEL_SHA256 = os.environ.get(
    "CLONE_SPEAKER_MODEL_SHA256", DEFAULT_SPEAKER_SHA256
).strip().lower()
DIARIZATION_CLUSTER_THRESHOLD = float(
    os.environ.get("CLONE_DIARIZATION_CLUSTER_THRESHOLD", "0.30")
)
DENOISE_WARMUP = os.environ.get("CLONE_DENOISE_WARMUP", "1").strip() == "1"
PROBE_TEMP_PREFIX = "vc_tmpdn_"
PROBE_TEMP_MARKER = ".selector-temp-v1"
SCHEDULER = InferenceScheduler(max_queue_size=MAX_QUEUE_SIZE)
REQUEST_COALESCER = RequestCoalescer(max_entries=64, ttl_s=90.0)
CONTENT_COALESCER = RequestCoalescer(max_entries=32, ttl_s=120.0)
NARI_CLIENT = httpx.Client(timeout=NARI_REQUEST_TIMEOUT_SECONDS)
PROMPT_BUILDER_LOCK = threading.Lock()
PROMPT_BUILDER_INSTANCE: VoicePromptBuilder | None = None
PROMPT_SCHEMA_LOCK = threading.Lock()
PROMPT_UPGRADE_LOCK = threading.Lock()
PROMPT_METADATA_CACHE: dict[str, tuple[int, "VoicePromptMetadata"]] = {}
ASR_VALIDATOR_LOCK = threading.Lock()
ASR_VALIDATOR_INSTANCE: SemanticASRValidator | None = None
VOICE_MUTATION_LOCKS = tuple(threading.RLock() for _ in range(256))
VOICE_BUILD_REGISTRY_LOCK = threading.Lock()
VOICE_BUILD_CANCEL_EVENTS: dict[str, threading.Event] = {}
DEEPFILTER_RUNNER = DeepFilterRunner(DEEPFILTER_BIN, DEEPFILTER_SHA256)
SPEAKER_DIARIZER = SpeakerDiarizer(
    DIARIZATION_MODEL,
    SPEAKER_MODEL,
    cluster_threshold=DIARIZATION_CLUSTER_THRESHOLD,
    expected_segmentation_sha256=DIARIZATION_SHA256,
    expected_embedding_sha256=SPEAKER_MODEL_SHA256,
)
DENOISE_TELEMETRY_LOCK = threading.Lock()
DENOISE_TELEMETRY: dict[str, int] = {
    "created_atten24": 0,
    "denoise_failures": 0,
    "denoise_reference_rejections": 0,
    "speaker_consistency_warnings": 0,
    "multiple_speaker_rejections": 0,
    "diarization_unavailable": 0,
}

GENERATED_AUDIO_REJECTION_HEADERS = {
    "X-Voice-Retryable": "false",
    "X-Voice-Error-Code": "VOICE_GENERATED_AUDIO_REJECTED",
}
OUTPUT_TEXT_MISMATCH_HEADERS = {
    "X-Voice-Retryable": "false",
    "X-Voice-Error-Code": "VOICE_OUTPUT_TEXT_MISMATCH",
}
ASR_UNAVAILABLE_HEADERS = {
    "Retry-After": "2",
    "X-Voice-Retryable": "true",
    "X-Voice-Error-Code": "VOICE_ASR_VALIDATION_UNAVAILABLE",
}

REFERENCE_FRAME_SECONDS = 1_920 / SAMPLE_RATE
LATIN_WORD_PATTERN = re.compile(
    r"\d+(?:[.,]\d+)?|[^\W\d_]+(?:['’\-][^\W\d_]+)?",
    re.UNICODE,
)


class SpeechRequest(BaseModel):
    text: str = Field(min_length=1, max_length=600)
    voice_id: str = Field(min_length=4, max_length=64)
    language_id: str = Field(default="en", min_length=2, max_length=10)
    seed: int = Field(default=20260825, ge=0, le=2_147_483_647)


class CaptionedSpeechRequest(BaseModel):
    input: str = Field(min_length=1, max_length=600)
    voice: str = Field(min_length=4, max_length=64)
    language: str = Field(default="en", min_length=2, max_length=10)
    speed: float = Field(default=1.0, ge=0.5, le=2.0)
    response_format: str = "mp3"
    return_timestamps: bool = True
    stream: bool = False


class GeneratedAudioQualityError(RuntimeError):
    def __init__(
        self,
        reason: str,
        metrics: dict[str, float] | None = None,
        *,
        code: str = "VOICE_GENERATED_AUDIO_REJECTED",
    ):
        super().__init__(reason)
        self.metrics = metrics or {}
        self.code = code


@dataclass(frozen=True, slots=True)
class ValidatedVoiceAudio:
    wav: bytes
    asr: SemanticASREvidence | None


@dataclass(frozen=True, slots=True)
class GeneratedVoiceCandidate:
    wav: bytes
    mode: str


@dataclass(frozen=True, slots=True)
class VoicePromptMetadata:
    schema: str
    reference_text: str | None
    speaker_embedding: torch.Tensor
    semantic_contract_error: dict[str, object] | None
    semantic_attested: bool


def _is_cjk(character: str) -> bool:
    return (
        "\u3400" <= character <= "\u9fff"
        or "\u3040" <= character <= "\u30ff"
        or "\uac00" <= character <= "\ud7af"
    )


def transcript_speaking_metrics(text: str) -> dict[str, float | int]:
    """Return a conservative lower bound for a complete spoken transcript.

    Qwen Base ICL assumes the reference audio and reference text cover exactly
    the same utterance. CastReader clients display a fixed script, but a user
    can release the recorder before reaching its end. Acoustic quality alone
    cannot detect that semantic truncation, so reject only recordings whose
    measured speech would require an implausibly fast complete read.
    """

    cjk_characters = sum(_is_cjk(character) for character in text)
    latin_words = sum(
        not any(_is_cjk(character) for character in match.group(0))
        for match in LATIN_WORD_PATTERN.finditer(text)
    )
    minimum_seconds = latin_words / 3.6 + cjk_characters / 8.0
    return {
        "latin_word_count": latin_words,
        "cjk_character_count": cjk_characters,
        "minimum_complete_speech_s": round(minimum_seconds, 3),
    }


def validate_reference_transcript_duration(
    text: str,
    speech_duration_s: float,
) -> dict[str, float | int]:
    metrics = transcript_speaking_metrics(text)
    minimum = float(metrics["minimum_complete_speech_s"])
    if minimum > 0 and speech_duration_s + 0.05 < minimum:
        detail = {
            "code": "VOICE_REFERENCE_TEXT_MISMATCH",
            "message": "The recording does not contain the complete reference text. Record the full sentence again.",
            "metrics": {
                **metrics,
                "speech_duration_s": round(speech_duration_s, 3),
            },
        }
        raise HTTPException(422, detail=detail)
    return metrics


def observe_reference_transcript_duration(
    text: str,
    speech_duration_s: float,
) -> dict[str, float | int | bool | str]:
    """Record a non-blocking transcript hint for diagnostics only.

    New prompts are speaker-only, so users may read the sample, speak their
    own text, use an accent, or choose another supported language.  A supplied
    transcript can still help support/debugging, but it never controls whether
    the voice is created.
    """

    metrics: dict[str, float | int | bool | str] = transcript_speaking_metrics(text)
    minimum = float(metrics["minimum_complete_speech_s"])
    metrics.update(
        {
            "speech_duration_s": round(speech_duration_s, 3),
            "duration_plausible": minimum <= 0 or speech_duration_s + 0.05 >= minimum,
            "enforcement": "advisory-only",
        }
    )
    return metrics


def _prompt_reference_speech_duration(prompt: dict[str, object]) -> float | None:
    measured = prompt.get("reference_speech_duration_s")
    if isinstance(measured, (float, int)) and not isinstance(measured, bool):
        value = float(measured)
        if math.isfinite(value) and value > 0:
            return value
    # Legacy prompts do not carry VAD metrics. Their full reference codec
    # sequence is still a safe upper bound for spoken duration and lets the
    # worker quarantine obviously incomplete historical recordings.
    for key in ("decoder_reference_code", "reference_codec_embeddings"):
        value = prompt.get(key)
        if isinstance(value, torch.Tensor) and value.ndim >= 1 and value.shape[0] > 0:
            return float(value.shape[0]) * REFERENCE_FRAME_SECONDS
    return None


def validate_prompt_semantic_contract(prompt: dict[str, object]) -> None:
    if prompt.get("schema") == "qwen3_tts_base_voice_clone_prompt_xvector_v1":
        return
    text = prompt.get("ref_text")
    if not isinstance(text, str) or not text.strip():
        raise HTTPException(422, "invalid voice prompt")
    duration = _prompt_reference_speech_duration(prompt)
    if duration is not None:
        validate_reference_transcript_duration(text, duration)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def structured_log(event: str, **fields: object) -> None:
    print(
        json.dumps(
            {"timestamp": utc_now(), "event": event, **fields},
            ensure_ascii=False,
            separators=(",", ":"),
        ),
        flush=True,
    )


def increment_denoise_metric(name: str) -> None:
    with DENOISE_TELEMETRY_LOCK:
        DENOISE_TELEMETRY[name] = DENOISE_TELEMETRY.get(name, 0) + 1


def denoise_health() -> dict[str, object]:
    with DENOISE_TELEMETRY_LOCK:
        counters = dict(DENOISE_TELEMETRY)
    deepfilter = DEEPFILTER_RUNNER.status()
    diarization = SPEAKER_DIARIZER.model_status()
    return {
        "pipeline_version": DENOISE_PIPELINE_VERSION,
        "selector_version": DENOISE_PIPELINE_VERSION,
        "mode": "on",
        "mode_source": "fixed-policy",
        "all_recordings": True,
        "attenuation_db": DENOISE_ATTENUATION_DB,
        "deepfilter_passes": 1,
        "prompt_builds": 1,
        "probe_count": 0,
        "raw_fallback": False,
        "reference_speaker_policy": REFERENCE_SPEAKER_POLICY,
        "ready": bool(
            deepfilter["ready"]
            and diarization["ready"]
            and not diarization.get("load_error")
        ),
        "deepfilter": deepfilter,
        "diarization": diarization,
        "counters": counters,
    }


def denoise_unavailable() -> HTTPException:
    return HTTPException(
        503,
        detail={
            "code": "VOICE_DENOISE_UNAVAILABLE",
            "message": "Voice noise reduction is temporarily unavailable. Please retry.",
        },
        headers={
            "Retry-After": "2",
            "X-Voice-Retryable": "true",
            "X-Voice-Error-Code": "VOICE_DENOISE_UNAVAILABLE",
        },
    )


def decode_reference(raw: bytes) -> tuple[np.ndarray, int]:
    try:
        audio, sample_rate = sf.read(
            io.BytesIO(raw),
            dtype="float32",
            always_2d=True,
        )
    except (RuntimeError, ValueError) as error:
        raise HTTPException(422, "reference must be valid WAV or FLAC") from error
    return audio, int(sample_rate)


def prepare_decoded_reference(
    audio: np.ndarray,
    sample_rate: int,
) -> ReferenceAudioResult:
    try:
        return process_reference_audio(audio, sample_rate)
    except ReferenceQualityError as error:
        structured_log(
            "voice_reference_quality_rejected",
            code=error.code,
            quality=error.metrics,
        )
        raise HTTPException(
            422,
            detail={
                "code": error.code,
                "message": error.message,
                "metrics": error.metrics,
            },
        ) from error


def prompt_builder() -> VoicePromptBuilder:
    global PROMPT_BUILDER_INSTANCE
    if PROMPT_BUILDER_INSTANCE is not None:
        return PROMPT_BUILDER_INSTANCE
    with PROMPT_BUILDER_LOCK:
        if PROMPT_BUILDER_INSTANCE is None:
            started = time.perf_counter()
            PROMPT_BUILDER_INSTANCE = VoicePromptBuilder(str(MODEL_DIR))
            structured_log(
                "voice_prompt_builder_ready",
                load_ms=round((time.perf_counter() - started) * 1000, 2),
            )
    return PROMPT_BUILDER_INSTANCE


def semantic_asr_validator() -> SemanticASRValidator:
    """Return the CPU-only validator backed by a pre-provisioned checkpoint."""

    global ASR_VALIDATOR_INSTANCE
    if ASR_VALIDATOR_INSTANCE is not None:
        return ASR_VALIDATOR_INSTANCE
    if ASR_MODEL_DIR is None:
        raise SemanticASRUnavailable("CLONE_ASR_MODEL_DIR is not configured")
    with ASR_VALIDATOR_LOCK:
        if ASR_VALIDATOR_INSTANCE is None:
            started = time.perf_counter()
            ASR_VALIDATOR_INSTANCE = SemanticASRValidator(ASR_MODEL_DIR)
            structured_log(
                "semantic_asr_validator_ready",
                model_revision=ASR_MODEL_DIR.name,
                load_ms=round((time.perf_counter() - started) * 1000, 2),
            )
    return ASR_VALIDATOR_INSTANCE


def request_priority(value: str | None) -> int:
    normalized = (value or "interactive").strip().lower()
    if normalized == "prefetch":
        return PRIORITY_PREFETCH
    if normalized in {"background", "clone"}:
        return PRIORITY_BACKGROUND
    return PRIORITY_INTERACTIVE


def schedule(
    execute,
    *,
    kind: str,
    priority: int,
    timeout_s: float,
    request_id: str | None,
) -> ScheduledResult:
    try:
        result = SCHEDULER.submit(
            execute,
            kind=kind,
            priority=priority,
            timeout_s=timeout_s,
            request_id=request_id,
        )
    except SchedulerOverloaded as error:
        raise HTTPException(
            429,
            "GPU request queue is full",
            headers={"Retry-After": "2", "X-TTS-Overload": "queue-full"},
        ) from error
    except SchedulerDeadlineExceeded as error:
        raise HTTPException(
            503,
            "GPU request deadline exceeded",
            headers={"Retry-After": "2", "X-TTS-Overload": "deadline"},
        ) from error
    structured_log(
        "gpu_job_completed",
        request_id=result.request_id,
        kind=kind,
        priority=priority,
        queue_wait_ms=round(result.queue_wait_s * 1000, 2),
        run_ms=round(result.run_s * 1000, 2),
    )
    return result


def timing_headers(result: ScheduledResult) -> dict[str, str]:
    return {
        "X-TTS-Request-ID": result.request_id,
        "X-TTS-Queue-Wait-Ms": f"{result.queue_wait_s * 1000:.2f}",
        "X-TTS-Run-Ms": f"{result.run_s * 1000:.2f}",
    }


def require_token(x_clone_token: str | None = Header(default=None)) -> None:
    try:
        expected = TOKEN_PATH.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise HTTPException(503, "worker token unavailable") from error
    if not x_clone_token or not hmac.compare_digest(x_clone_token, expected):
        raise HTTPException(401, "invalid clone token")


def voice_dir(voice_id: str) -> Path:
    if VOICE_ID_RE.fullmatch(voice_id) is None:
        raise HTTPException(422, "invalid voice_id")
    return VOICE_ROOT / voice_id


def voice_mutation_lock(voice_id: str) -> threading.RLock:
    """Return a stable, bounded lock for one voice's filesystem lifecycle."""

    digest = hashlib.sha256(voice_id.encode("utf-8")).digest()
    index = int.from_bytes(digest[:2], "big") % len(VOICE_MUTATION_LOCKS)
    return VOICE_MUTATION_LOCKS[index]


def register_voice_build(voice_id: str) -> threading.Event:
    with VOICE_BUILD_REGISTRY_LOCK:
        if voice_id in VOICE_BUILD_CANCEL_EVENTS:
            raise HTTPException(
                409,
                detail={
                    "code": "VOICE_BUILD_IN_PROGRESS",
                    "message": "Voice creation is already in progress",
                },
            )
        event = threading.Event()
        VOICE_BUILD_CANCEL_EVENTS[voice_id] = event
        return event


def unregister_voice_build(voice_id: str, event: threading.Event) -> None:
    with VOICE_BUILD_REGISTRY_LOCK:
        if VOICE_BUILD_CANCEL_EVENTS.get(voice_id) is event:
            VOICE_BUILD_CANCEL_EVENTS.pop(voice_id, None)


def cancel_voice_build(voice_id: str) -> bool:
    with VOICE_BUILD_REGISTRY_LOCK:
        event = VOICE_BUILD_CANCEL_EVENTS.get(voice_id)
        if event is None:
            return False
        event.set()
        return True


def xvector_writer_enabled() -> bool:
    """Gate the irreversible prompt-schema writer migration.

    Reader-compatible Worker and Nari code is deployed to every region first.
    Only then is this marker enabled in every region. Removing it blocks new
    voice creation while preserving reads of both legacy and x-vector prompts.
    """

    worker_path = Path(__file__).resolve()
    return marker_matches_current_release(
        XVECTOR_WRITER_MARKER,
        worker=worker_path,
        builder=worker_path.with_name("build_prompt.py"),
        activation_validator=worker_path.with_name("xvector_activation.py"),
    )


def normalize_language(value: str) -> str:
    code = value.strip().lower().replace("_", "-").split("-", 1)[0]
    try:
        return LANGUAGE_MAP[code]
    except KeyError as error:
        raise HTTPException(422, "unsupported language") from error


def prepare_reference(raw: bytes) -> ReferenceAudioResult:
    audio, sample_rate = decode_reference(raw)
    return prepare_decoded_reference(audio, sample_rate)


app = FastAPI(title="CastReader Nari Clone Worker", docs_url=None, redoc_url=None)


@app.on_event("startup")
def prepare_storage() -> None:
    VOICE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    # A prompt directory is published only by one atomic rename. Any private
    # build directory left across a process crash can never be a valid voice
    # and must not later be mistaken for one by cleanup or restore calls.
    for stale in VOICE_ROOT.glob(".vc_*.*.building"):
        if stale.is_dir():
            shutil.rmtree(stale)
    for temporary in VOICE_ROOT.glob(f"{PROBE_TEMP_PREFIX}*"):
        if temporary.is_dir() and (temporary / PROBE_TEMP_MARKER).is_file():
            shutil.rmtree(temporary)
    if CLONE_WARMUP:
        prompt_builder()
    if ASR_WARMUP:
        semantic_asr_validator().warmup()
    if DENOISE_WARMUP:
        # A failed enhancement dependency must not take existing-voice TTS
        # down. Creation still fails closed, and health exposes readiness.
        try:
            if not DEEPFILTER_RUNNER.status()["ready"]:
                raise AdaptiveDenoiseError("DeepFilter binary is not ready")
            SPEAKER_DIARIZER.warmup()
        except Exception as error:
            structured_log(
                "voice_denoise_warmup_unavailable",
                pipeline_version=DENOISE_PIPELINE_VERSION,
                error_type=type(error).__name__,
            )


@app.on_event("shutdown")
def stop_scheduler() -> None:
    SCHEDULER.close(wait=True)
    NARI_CLIENT.close()


@app.get("/health")
def health() -> dict[str, object]:
    try:
        response = httpx.get(f"{NARI_URL}/ready", timeout=2.0)
        nari_ready = response.status_code == 200 and response.json().get("ready") is True
    except Exception:
        nari_ready = False
    # ASR is deliberately not an online dependency.  A small CPU recognizer is
    # useful for offline audits, but it is not reliable enough to decide
    # whether a clean user recording may become a voice.  Keeping health and
    # creation independent from ASR also prevents a checkpoint outage or cold
    # load from taking the clone service down.
    asr_ready = ASR_MODEL_DIR is not None and ASR_MODEL_DIR.is_dir()
    validator = ASR_VALIDATOR_INSTANCE
    asr_loaded = validator.loaded if validator is not None else False
    denoise = denoise_health()
    writer_enabled = xvector_writer_enabled()
    with VOICE_BUILD_REGISTRY_LOCK:
        active_voice_tasks = len(VOICE_BUILD_CANCEL_EVENTS)
    return {
        "status": "healthy" if nari_ready else "degraded",
        "model": MODEL_NAME,
        "nari_ready": nari_ready,
        "semantic_asr_ready": asr_ready,
        "semantic_asr_loaded": asr_loaded,
        "semantic_asr_required": False,
        "voice_clone_generation_mode": "x-vector",
        "voice_creation_enabled": writer_enabled and bool(denoise["ready"]),
        "voice_creation_dependencies_ready": denoise["ready"],
        "active_voice_tasks": active_voice_tasks,
        "voice_prompt_writer_schema": (
            "xvector_v1" if writer_enabled else "disabled"
        ),
        "adaptive_denoise": denoise,
        **SCHEDULER.snapshot(),
    }


@app.post("/v1/voices", dependencies=[Depends(require_token)])
async def create_voice(
    reference: UploadFile = File(...),
    consent_confirmed: bool = Form(...),
    requested_voice_id: str | None = Form(default=None),
    reference_text: str = Form(default=""),
    reference_language: str = Form(default=""),
    x_request_id: str | None = Header(default=None),
) -> dict[str, object]:
    if not consent_confirmed:
        raise HTTPException(422, "voice-owner consent is required")
    if not xvector_writer_enabled():
        raise HTTPException(
            503,
            detail={
                "code": "VOICE_CREATION_TEMPORARILY_UNAVAILABLE",
                "message": "Voice creation is temporarily unavailable during a safe schema migration.",
            },
            headers={"Retry-After": "30", "X-Voice-Retryable": "true"},
        )
    transcript = reference_text.strip()
    if len(transcript) > 600:
        raise HTTPException(422, "reference_text must be at most 600 characters")
    reference_language_code = (
        reference_language.strip().lower().replace("_", "-").split("-", 1)[0]
    )
    # Recording language is descriptive only in speaker-only mode. It need not
    # be one of the ten synthesis languages (for example a Hindi speaker may
    # record naturally, then use the clone for supported output languages).
    if (
        reference_language_code
        and re.fullmatch(r"[a-z]{2,3}", reference_language_code) is None
    ):
        raise HTTPException(422, "unsupported reference_language")
    voice_id = requested_voice_id or f"vc_{uuid.uuid4().hex}"
    if voice_id.startswith(PROBE_TEMP_PREFIX):
        raise HTTPException(422, "requested_voice_id uses a reserved prefix")
    destination = voice_dir(voice_id)
    staging = VOICE_ROOT / f".{voice_id}.{uuid.uuid4().hex}.building"
    with voice_mutation_lock(voice_id):
        if (destination / "prompt.pt").is_file():
            raise HTTPException(
                409,
                detail={
                    "code": "VOICE_ALREADY_READY",
                    "message": "Voice is already registered",
                },
            )
        if destination.exists():
            raise HTTPException(
                409,
                detail={
                    "code": "VOICE_ID_CONFLICT",
                    "message": "Voice path is not a ready prompt",
                },
            )
        creation_cancelled = register_voice_build(voice_id)
    creation_deadline = time.monotonic() + VOICE_BUILD_TIMEOUT_SECONDS

    def remaining_creation_budget() -> float:
        return creation_deadline - time.monotonic()

    def raise_if_creation_cancelled() -> None:
        if creation_cancelled.is_set():
            raise HTTPException(503, "voice creation was cancelled")
        if remaining_creation_budget() <= 0:
            creation_cancelled.set()
            raise HTTPException(
                503,
                detail={
                    "code": "VOICE_BUILD_TIMEOUT",
                    "message": "Voice creation exceeded its deadline",
                },
                headers={"Retry-After": "2", "X-Voice-Retryable": "true"},
            )

    try:
        try:
            raw = await asyncio.wait_for(
                reference.read(MAX_UPLOAD_BYTES + 1),
                timeout=max(0.1, remaining_creation_budget()),
            )
        except TimeoutError as error:
            raise_if_creation_cancelled()
            raise HTTPException(503, "voice upload read timed out") from error
        if len(raw) > MAX_UPLOAD_BYTES:
            raise HTTPException(413, "reference file is too large")
        raise_if_creation_cancelled()
        try:
            source_audio, source_sample_rate = await asyncio.wait_for(
                asyncio.to_thread(decode_reference, raw),
                timeout=max(0.1, remaining_creation_budget()),
            )
        except TimeoutError as error:
            raise_if_creation_cancelled()
            raise HTTPException(503, "voice reference decoding timed out") from error
        try:
            reference_result = await asyncio.wait_for(
                asyncio.to_thread(
                    prepare_decoded_reference,
                    source_audio,
                    source_sample_rate,
                ),
                timeout=max(0.1, remaining_creation_budget()),
            )
        except TimeoutError as error:
            raise_if_creation_cancelled()
            raise HTTPException(503, "voice reference processing timed out") from error
        raise_if_creation_cancelled()

        try:
            diarization = await asyncio.wait_for(
                asyncio.to_thread(
                    SPEAKER_DIARIZER.inspect,
                    source_audio,
                    source_sample_rate,
                ),
                timeout=max(0.1, remaining_creation_budget()),
            )
        except (DiarizationUnavailable, TimeoutError) as error:
            increment_denoise_metric("diarization_unavailable")
            structured_log(
                "voice_reference_diarization_unavailable",
                voice_id=voice_id,
                error_type=type(error).__name__,
                pipeline_version=DENOISE_PIPELINE_VERSION,
            )
            raise HTTPException(
                503,
                detail={
                    "code": "VOICE_REFERENCE_DIARIZATION_UNAVAILABLE",
                    "message": "Voice safety validation is temporarily unavailable",
                },
                headers={
                    "Retry-After": "2",
                    "X-Voice-Retryable": "true",
                    "X-Voice-Error-Code": "VOICE_REFERENCE_DIARIZATION_UNAVAILABLE",
                },
            ) from error
        diarization_metrics = diarization.as_metrics()
        if diarization_metrics.get("competing_speech") is True:
            increment_denoise_metric("multiple_speaker_rejections")
            structured_log(
                "voice_reference_competing_speech_observed",
                voice_id=voice_id,
                diarization=diarization_metrics,
                pipeline_version=DENOISE_PIPELINE_VERSION,
            )
            raise HTTPException(
                422,
                detail={
                    "code": "VOICE_REFERENCE_MULTIPLE_SPEAKERS",
                    "message": "More than one voice is present. Record again with only one person speaking.",
                    "metrics": diarization_metrics,
                },
                headers={
                    "X-Voice-Retryable": "false",
                    "X-Voice-Error-Code": "VOICE_REFERENCE_MULTIPLE_SPEAKERS",
                },
            )

        transcript_metrics = observe_reference_transcript_duration(
            transcript,
            float(reference_result.metrics["speech_duration_s"]),
        )
        structured_log(
            "voice_reference_quality_passed",
            voice_id=voice_id,
            quality=reference_result.metrics,
            warnings=reference_result.warnings,
        )
        structured_log(
            "voice_reference_semantic_deferred",
            voice_id=voice_id,
            policy="offline-audit-only",
            runtime_generation_mode="x-vector",
            reference_language=reference_language_code or None,
            transcript_sha256=(
                hashlib.sha256(transcript.encode("utf-8")).hexdigest()
                if transcript
                else None
            ),
        )

        def build_voice() -> dict[str, object]:
            return build_voice_pipeline(
                voice_id=voice_id,
                destination=destination,
                staging=staging,
                raw_upload=raw,
                source_audio=source_audio,
                source_sample_rate=source_sample_rate,
                online_reference=reference_result,
                transcript=transcript,
                reference_language_code=reference_language_code,
                transcript_metrics=transcript_metrics,
                diarization_metrics=diarization_metrics,
                creation_deadline=creation_deadline,
                creation_cancelled=creation_cancelled,
                raise_if_creation_cancelled=raise_if_creation_cancelled,
                external_request_id=x_request_id,
            )

        def guarded_build_voice() -> dict[str, object]:
            try:
                return build_voice()
            except HTTPException:
                raise
            except Exception as error:
                raise HTTPException(503, "could not build voice prompt") from error

        return await asyncio.wait_for(
            asyncio.to_thread(guarded_build_voice),
            timeout=max(0.1, remaining_creation_budget()),
        )
    except TimeoutError as error:
        creation_cancelled.set()
        raise HTTPException(
            503,
            detail={
                "code": "VOICE_BUILD_TIMEOUT",
                "message": "Voice creation exceeded its deadline",
            },
            headers={"Retry-After": "2", "X-Voice-Retryable": "true"},
        ) from error
    except BaseException:
        creation_cancelled.set()
        raise
    finally:
        unregister_voice_build(voice_id, creation_cancelled)


def validate_prompt_structure(prompt: object) -> str:
    schema = prompt.get("schema") if isinstance(prompt, dict) else None
    if schema == "qwen3_tts_base_voice_clone_prompt_xvector_v1":
        speaker = prompt.get("ref_spk_embedding")
        forbidden = (
            "ref_text",
            "reference_codec_embeddings",
            "decoder_bootstrap_code",
            "decoder_reference_code",
        )
        if (
            not isinstance(speaker, torch.Tensor)
            or speaker.ndim != 1
            or speaker.numel() != VOICE_SPEAKER_EMBEDDING_SIZE
            or not speaker.is_floating_point()
            or not bool(torch.isfinite(speaker).all().item())
            or prompt.get("x_vector_only_mode") is not True
            or prompt.get("icl_mode") is not False
            or prompt.get("conditioning_contract_version") != 1
            or any(prompt.get(key) is not None for key in forbidden)
        ):
            raise HTTPException(422, "invalid x-vector voice prompt")
        return schema
    if (
        not isinstance(prompt, dict)
        or schema
        not in {
            "qwen3_tts_base_voice_clone_prompt_v2",
            "qwen3_tts_base_voice_clone_prompt_v3",
            "qwen3_tts_base_voice_clone_prompt_v4",
        }
        or not isinstance(prompt.get("ref_text"), str)
        or not prompt["ref_text"].strip()
        or not isinstance(prompt.get("ref_spk_embedding"), torch.Tensor)
        or not isinstance(prompt.get("reference_codec_embeddings"), torch.Tensor)
    ):
        raise HTTPException(422, "invalid voice prompt")
    if schema == "qwen3_tts_base_voice_clone_prompt_v3":
        ref_code = prompt.get("decoder_bootstrap_code")
        if (
            not isinstance(ref_code, torch.Tensor)
            or ref_code.ndim != 2
            or ref_code.shape[0] < 1
            or ref_code.shape[0] > 8
            or ref_code.dtype != torch.long
        ):
            raise HTTPException(422, "invalid voice prompt decoder bootstrap")
    if schema == "qwen3_tts_base_voice_clone_prompt_v4":
        ref_code = prompt.get("decoder_reference_code")
        if (
            not isinstance(ref_code, torch.Tensor)
            or ref_code.ndim != 2
            or ref_code.shape[0] < 1
            or ref_code.shape[0] > 512
            or ref_code.shape[1] != 16
            or ref_code.dtype != torch.long
            or prompt.get("decoder_bootstrap_code") is not None
        ):
            raise HTTPException(422, "invalid voice prompt decoder reference context")
    assert isinstance(schema, str)
    return schema


def validate_prompt_bytes(raw: bytes) -> str:
    try:
        prompt = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=True)
    except Exception as error:
        raise HTTPException(422, "invalid voice prompt") from error
    return validate_prompt_structure(prompt)


def _remaining_build_budget(deadline_at: float) -> float:
    return deadline_at - time.monotonic()


def _schedule_voice_build_step(
    execute,
    *,
    kind: str,
    deadline_at: float,
    cancelled: threading.Event,
    request_id: str | None = None,
):
    if cancelled.is_set() or _remaining_build_budget(deadline_at) <= 1.0:
        raise HTTPException(
            503,
            detail={
                "code": "VOICE_BUILD_TIMEOUT",
                "message": "Voice creation exceeded its deadline",
            },
            headers={"Retry-After": "2", "X-Voice-Retryable": "true"},
        )
    return schedule(
        execute,
        kind=kind,
        # Keep the one prompt build behind interactive TTS in the GPU queue.
        priority=PRIORITY_BACKGROUND,
        timeout_s=max(0.5, _remaining_build_budget(deadline_at) - 0.5),
        request_id=request_id,
    ).value


def _build_prompt_for_reference(
    reference: ReferenceAudioResult,
    *,
    reference_path: Path,
    prompt_path: Path,
    transcript: str,
    deadline_at: float,
    cancelled: threading.Event,
    request_id: str | None,
) -> None:
    sf.write(reference_path, reference.audio, SAMPLE_RATE, subtype="PCM_16")
    try:
        _schedule_voice_build_step(
            lambda: prompt_builder().save(
                str(reference_path),
                transcript,
                prompt_path,
                reference_speech_duration_s=float(
                    reference.metrics["speech_duration_s"]
                ),
                semantic_attested=False,
            ),
            kind="voice-denoise-prompt-build",
            deadline_at=deadline_at,
            cancelled=cancelled,
            request_id=request_id,
        )
    finally:
        reference_path.unlink(missing_ok=True)
    schema = validate_prompt_bytes(prompt_path.read_bytes())
    if schema != "qwen3_tts_base_voice_clone_prompt_xvector_v1":
        raise HTTPException(503, "voice prompt schema is unsafe")


def _relative_reference_speaker_guard(
    online: ReferenceAudioResult,
    candidate: ReferenceAudioResult,
) -> dict[str, object]:
    baseline = online.metrics.get("min_speaker_similarity")
    selected = candidate.metrics.get("min_speaker_similarity")
    comparable = all(
        isinstance(value, (float, int))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        for value in (baseline, selected)
    )
    # These are minima over each recording's own VAD-selected windows, not
    # aligned before/after identity scores. A relative drop is advisory only;
    # raw diarization and the candidate's input-quality gate remain mandatory.
    # Short valid references may not provide enough windows for this statistic.
    return {
        "backend": "campplus-window-consistency",
        "policy": REFERENCE_SPEAKER_POLICY,
        "action": "warn_only",
        "blocking": False,
        "comparable": comparable,
        "passed": (
            float(selected) >= float(baseline) - RELATIVE_SPEAKER_FLOOR
            if comparable
            else None
        ),
        "baseline_min_similarity": baseline,
        "candidate_min_similarity": selected,
        "maximum_relative_drop": RELATIVE_SPEAKER_FLOOR,
    }


def build_voice_pipeline(
    *,
    voice_id: str,
    destination: Path,
    staging: Path,
    raw_upload: bytes,
    source_audio: np.ndarray,
    source_sample_rate: int,
    online_reference: ReferenceAudioResult,
    transcript: str,
    reference_language_code: str,
    transcript_metrics: dict[str, float | int | bool | str],
    diarization_metrics: dict[str, object] | None,
    creation_deadline: float,
    creation_cancelled: threading.Event,
    raise_if_creation_cancelled,
    external_request_id: str | None,
) -> dict[str, object]:
    """Run exactly one atten24 enhancement, then publish one x-vector prompt.

    There is deliberately no clean/mechanical bypass, mode switch, generated
    probe, alternative attenuation, or fallback to an unenhanced reference.
    """
    with voice_mutation_lock(voice_id):
        raise_if_creation_cancelled()
        if destination.exists():
            code = (
                "VOICE_ALREADY_READY"
                if (destination / "prompt.pt").is_file()
                else "VOICE_ID_CONFLICT"
            )
            raise HTTPException(
                409,
                detail={"code": code, "message": "Voice ID already exists"},
            )
        try:
            staging.mkdir(mode=0o700, parents=False, exist_ok=False)
        except FileExistsError as error:
            raise HTTPException(409, "voice build already exists") from error

        started = time.perf_counter()
        final_prompt = staging / "prompt.pt"
        private_work = staging / ".denoise-work"
        try:
            try:
                private_work.mkdir(mode=0o700, parents=False, exist_ok=False)
                enhanced, enhanced_rate, elapsed = DEEPFILTER_RUNNER.enhance(
                    source_audio,
                    source_sample_rate,
                    attenuation_db=DENOISE_ATTENUATION_DB,
                    work_dir=private_work,
                    deadline_at=creation_deadline,
                    cancelled=creation_cancelled,
                )
                raise_if_creation_cancelled()
                selected_reference = process_reference_audio(
                    enhanced,
                    enhanced_rate,
                )
                reference_guard = _relative_reference_speaker_guard(
                    online_reference,
                    selected_reference,
                )
                if reference_guard["passed"] is False:
                    increment_denoise_metric("speaker_consistency_warnings")
                    selected_reference.warnings.append("speaker_consistency_relative_drop")
                    structured_log(
                        "voice_denoise_reference_warning",
                        voice_id=voice_id,
                        pipeline_version=DENOISE_PIPELINE_VERSION,
                        code="VOICE_REFERENCE_SPEAKER_CONSISTENCY_WARNING",
                        quality=reference_guard,
                        raw_fallback=False,
                    )
                raise_if_creation_cancelled()
            except ReferenceQualityError as error:
                increment_denoise_metric("denoise_reference_rejections")
                structured_log(
                    "voice_denoise_reference_rejected",
                    voice_id=voice_id,
                    pipeline_version=DENOISE_PIPELINE_VERSION,
                    code=error.code,
                    quality=error.metrics,
                    raw_fallback=False,
                )
                raise HTTPException(
                    422,
                    detail={
                        "code": error.code,
                        "message": error.message,
                        "metrics": error.metrics,
                    },
                    headers={
                        "X-Voice-Retryable": "false",
                        "X-Voice-Error-Code": error.code,
                    },
                ) from error
            except HTTPException:
                raise
            except Exception as error:
                raise_if_creation_cancelled()
                increment_denoise_metric("denoise_failures")
                structured_log(
                    "voice_denoise_failed",
                    voice_id=voice_id,
                    pipeline_version=DENOISE_PIPELINE_VERSION,
                    error_type=type(error).__name__,
                    raw_fallback=False,
                )
                raise denoise_unavailable() from error
            finally:
                shutil.rmtree(private_work, ignore_errors=True)

            selection: dict[str, object] = {
                "pipeline_version": DENOISE_PIPELINE_VERSION,
                "selector_version": DENOISE_PIPELINE_VERSION,
                "selected": "atten24",
                "reason": "fixed-deepfilter-atten24",
                "deepfilter_applied": True,
                "attenuation_db": DENOISE_ATTENUATION_DB,
                "deepfilter_elapsed_s": round(elapsed, 6),
                "deepfilter_passes": 1,
                "prompt_builds": 1,
                "probe_count": 0,
                "raw_fallback": False,
                "reference_speaker_guard": reference_guard,
            }
            _build_prompt_for_reference(
                selected_reference,
                reference_path=staging / "reference.atten24.wav",
                prompt_path=final_prompt,
                transcript=transcript,
                deadline_at=creation_deadline,
                cancelled=creation_cancelled,
                request_id=(
                    f"{external_request_id}-prompt"
                    if external_request_id
                    else None
                ),
            )
            raise_if_creation_cancelled()
            prompt_schema = validate_prompt_bytes(final_prompt.read_bytes())
            if prompt_schema != "qwen3_tts_base_voice_clone_prompt_xvector_v1":
                raise HTTPException(503, "voice prompt schema is unsafe")

            deepfilter_status = DEEPFILTER_RUNNER.status()
            metadata = {
                "voice_id": voice_id,
                "created_at": utc_now(),
                "consent_confirmed": True,
                "reference_duration_s": round(
                    selected_reference.duration_seconds,
                    3,
                ),
                "reference_sha256": hashlib.sha256(raw_upload).hexdigest(),
                "prompt_build_s": round(time.perf_counter() - started, 3),
                "model": MODEL_NAME,
                "supported_languages": sorted(LANGUAGE_MAP),
                "reference_quality": selected_reference.metrics,
                "reference_quality_warnings": selected_reference.warnings,
                # Historical field name retained for audit/API compatibility;
                # this is a quality baseline only, never a second prompt.
                "reference_quality_online": online_reference.metrics,
                "reference_transcript_contract": transcript_metrics,
                "reference_semantic_attested": False,
                "reference_semantic_policy": "offline-audit-only",
                "runtime_generation_mode": "x-vector",
                "reference_language": reference_language_code or None,
                "adaptive_denoise": {
                    **selection,
                    "mode": "on",
                    "mode_source": "fixed-policy",
                    "deepfilter_version": deepfilter_status["version"],
                    "deepfilter_sha256": deepfilter_status["sha256"],
                    "diarization": diarization_metrics,
                },
            }
            (staging / "metadata.json").write_text(
                json.dumps(metadata, indent=2),
                encoding="utf-8",
            )
            raise_if_creation_cancelled()
            if destination.exists():
                code = (
                    "VOICE_ALREADY_READY"
                    if (destination / "prompt.pt").is_file()
                    else "VOICE_ID_CONFLICT"
                )
                raise HTTPException(
                    409,
                    detail={"code": code, "message": "Voice ID already exists"},
                )
            leaked_references = tuple(staging.glob("reference*.wav"))
            if leaked_references or private_work.exists():
                raise HTTPException(503, "voice reference cleanup failed")
            staging.replace(destination)
            increment_denoise_metric("created_atten24")
            structured_log(
                "voice_denoise_selected",
                voice_id=voice_id,
                **selection,
                mode="on",
                prompt_build_s=metadata["prompt_build_s"],
            )
            return metadata
        finally:
            if staging.exists():
                shutil.rmtree(staging, ignore_errors=True)


def upgrade_prompt_bytes(raw: bytes) -> tuple[bytes, str]:
    schema = validate_prompt_bytes(raw)
    # Runtime cloned speech is x-vector-only. Legacy prompt schemas remain
    # immutable compatibility assets; upgrading their unused ICL decoder state
    # would add latency and can no longer improve the online result.
    return raw, schema


def install_prompt_bytes(voice_id: str, raw: bytes) -> None:
    with voice_mutation_lock(voice_id):
        destination = voice_dir(voice_id)
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = destination / f"prompt-{uuid.uuid4().hex}.tmp"
        temporary.write_bytes(raw)
        temporary.replace(destination / "prompt.pt")
        with PROMPT_SCHEMA_LOCK:
            PROMPT_METADATA_CACHE.pop(voice_id, None)


def _voice_prompt_metadata_unlocked(voice_id: str) -> VoicePromptMetadata:
    """Load immutable per-voice runtime fields once for each prompt mtime."""

    prompt_path = voice_dir(voice_id) / "prompt.pt"
    if not prompt_path.is_file():
        raise HTTPException(404, "voice not found")
    modified_ns = prompt_path.stat().st_mtime_ns
    with PROMPT_SCHEMA_LOCK:
        cached = PROMPT_METADATA_CACHE.get(voice_id)
        if cached is not None and cached[0] == modified_ns:
            return cached[1]
        try:
            prompt = torch.load(
                io.BytesIO(prompt_path.read_bytes()),
                map_location="cpu",
                weights_only=True,
            )
        except Exception as error:
            raise HTTPException(422, "invalid voice prompt") from error
        schema = validate_prompt_structure(prompt)
        assert isinstance(prompt, dict)
        reference_text = prompt.get("ref_text")
        speaker = prompt["ref_spk_embedding"]
        if schema != "qwen3_tts_base_voice_clone_prompt_xvector_v1":
            assert isinstance(reference_text, str)
        else:
            reference_text = None
        assert isinstance(speaker, torch.Tensor)
        semantic_error: dict[str, object] | None = None
        try:
            validate_prompt_semantic_contract(prompt)
        except HTTPException as error:
            detail = error.detail
            code = detail.get("code") if isinstance(detail, dict) else None
            if code != "VOICE_REFERENCE_TEXT_MISMATCH":
                raise
            semantic_error = dict(detail)
        metadata = VoicePromptMetadata(
            schema=schema,
            reference_text=reference_text,
            speaker_embedding=speaker.detach().cpu().clone(),
            semantic_contract_error=semantic_error,
            semantic_attested=(
                schema != "qwen3_tts_base_voice_clone_prompt_xvector_v1"
                and prompt.get("reference_contract_version") == 2
            ),
        )
        PROMPT_METADATA_CACHE[voice_id] = (modified_ns, metadata)
        return metadata


def voice_prompt_metadata(voice_id: str) -> VoicePromptMetadata:
    with voice_mutation_lock(voice_id):
        return _voice_prompt_metadata_unlocked(voice_id)


def ensure_voice_prompt_decoder_context(voice_id: str) -> None:
    metadata = voice_prompt_metadata(voice_id)
    if metadata.schema == "qwen3_tts_base_voice_clone_prompt_xvector_v1":
        return
    if metadata.semantic_contract_error is not None:
        raise HTTPException(422, detail=metadata.semantic_contract_error)
    current_schema = metadata.schema
    if current_schema in {
        "qwen3_tts_base_voice_clone_prompt_v2",
        "qwen3_tts_base_voice_clone_prompt_v3",
        "qwen3_tts_base_voice_clone_prompt_v4",
    }:
        return
    with PROMPT_UPGRADE_LOCK:
        current_schema = voice_prompt_schema(voice_id)
        if current_schema in {
            "qwen3_tts_base_voice_clone_prompt_v2",
            "qwen3_tts_base_voice_clone_prompt_v3",
            "qwen3_tts_base_voice_clone_prompt_v4",
        }:
            return
        prompt_path = voice_dir(voice_id) / "prompt.pt"
        compiled, schema = upgrade_prompt_bytes(prompt_path.read_bytes())
        if schema not in {
            "qwen3_tts_base_voice_clone_prompt_v3",
            "qwen3_tts_base_voice_clone_prompt_v4",
        }:
            raise HTTPException(503, "voice prompt upgrade failed")
        install_prompt_bytes(voice_id, compiled)


def voice_prompt_schema(voice_id: str) -> str:
    return voice_prompt_metadata(voice_id).schema


@app.get("/v1/voices/{voice_id}/prompt", dependencies=[Depends(require_token)])
def export_voice_prompt(voice_id: str) -> Response:
    with voice_mutation_lock(voice_id):
        prompt_path = voice_dir(voice_id) / "prompt.pt"
        if not prompt_path.is_file():
            raise HTTPException(404, "voice not found")
        raw = prompt_path.read_bytes()
        if not raw or len(raw) > MAX_PROMPT_BYTES:
            raise HTTPException(503, "voice prompt is invalid")
        return Response(raw, media_type="application/octet-stream")


@app.put("/v1/voices/{voice_id}/prompt", dependencies=[Depends(require_token)])
async def import_voice_prompt(voice_id: str, prompt: UploadFile = File(...)) -> dict[str, str]:
    voice_dir(voice_id)
    raw = await prompt.read(MAX_PROMPT_BYTES + 1)
    if not raw or len(raw) > MAX_PROMPT_BYTES:
        raise HTTPException(413, "voice prompt is too large")
    original_schema = await asyncio.to_thread(validate_prompt_bytes, raw)
    compiled, schema = await asyncio.to_thread(upgrade_prompt_bytes, raw)
    await asyncio.to_thread(install_prompt_bytes, voice_id, compiled)
    return {
        "status": "ready",
        "voice_id": voice_id,
        "prompt_schema": schema,
        "decoder_context": (
            "none"
            if schema == "qwen3_tts_base_voice_clone_prompt_xvector_v1"
            else (
                "reference"
                if schema == "qwen3_tts_base_voice_clone_prompt_v4"
                else "fixed-silence"
            )
        ),
        "upgraded_from": original_schema,
    }


@app.delete("/v1/voices/{voice_id}", dependencies=[Depends(require_token)])
def delete_voice(voice_id: str) -> dict[str, str]:
    destination = voice_dir(voice_id)
    build_was_inflight = cancel_voice_build(voice_id)

    def remove_voice() -> dict[str, str]:
        with voice_mutation_lock(voice_id):
            # Close the check/register race by checking the registry again
            # after acquiring the same lifecycle lock used by creation.
            inflight = cancel_voice_build(voice_id) or build_was_inflight
            removed = False
            if destination.exists():
                shutil.rmtree(destination)
                removed = True
            # Stale build directories are private implementation details and
            # safe to remove only while holding the same publication lock.
            for staging in VOICE_ROOT.glob(f".{voice_id}.*.building"):
                if staging.is_dir():
                    shutil.rmtree(staging)
                    removed = True
            with PROMPT_SCHEMA_LOCK:
                PROMPT_METADATA_CACHE.pop(voice_id, None)
            if removed:
                return {"status": "deleted", "voice_id": voice_id}
            if inflight:
                return {"status": "cancelling", "voice_id": voice_id}
            raise HTTPException(404, "voice not found")

    # Filesystem cleanup must not wait behind GPU synthesis. The per-voice
    # lock is the only ordering primitive it needs; an in-flight builder sees
    # its cancellation event before it can publish.
    return remove_voice()


def nari_request_payload(
    request: SpeechRequest,
    *,
    language: str,
    seed: int,
    voice_clone_mode: str = "icl",
    deterministic: bool = False,
) -> dict[str, object]:
    return {
        "input": request.text.strip(),
        "voice": "clone",
        "voice_prompt": request.voice_id,
        "voice_clone_mode": voice_clone_mode,
        "language": language,
        "seed": seed,
        "response_format": "wav",
        "stream": False,
        "non_streaming_mode": True,
        # Keep streaming/incremental decode. Prompt v4 starts at the exact
        # reference/generated decoder boundary; legacy v3 prompts retain the
        # four-frame fixed-silence compatibility bootstrap. Neither context is
        # emitted in the returned PCM.
        "defer_codec_until_terminal": False,
        # Bound pathological no-EOS generations to a conservative multiple of
        # the requested paragraph's speaking time. A 60-character Chinese
        # paragraph should never become a 327-second audio file merely because
        # the Talker missed EOS for one random seed.
        "max_new_tokens": maximum_generation_frames(request.text),
        "do_sample": not deterministic,
        "temperature": NARI_TEMPERATURE,
        "top_k": NARI_TOP_K,
        "top_p": NARI_TOP_P,
        "repetition_penalty": NARI_REPETITION_PENALTY,
        "subtalker_dosample": not deterministic,
        "subtalker_temperature": NARI_TEMPERATURE,
        "subtalker_top_k": NARI_TOP_K,
        "subtalker_top_p": NARI_TOP_P,
    }


def nari_streamed_wav(
    payload: dict[str, object],
    *,
    deadline_at: float,
) -> tuple[int, bytes]:
    """Collect PCM over a cancellable HTTP stream and return a complete WAV.

    Closing the HTTP stream before Nari reaches a terminal state executes its
    ``stream_bytes`` finalizer, which cancels the engine request. A worker or
    scheduler deadline therefore releases the GPU instead of merely abandoning
    a still-running non-streaming request.
    """

    remaining = deadline_at - time.monotonic()
    if remaining <= 0.25:
        raise TimeoutError("Nari request deadline expired before submission")
    transport_payload = {
        **payload,
        "response_format": "pcm",
        "stream": True,
    }
    with NARI_CLIENT.stream(
        "POST",
        f"{NARI_URL}/v1/audio/speech",
        json=transport_payload,
        timeout=max(0.25, min(NARI_REQUEST_TIMEOUT_SECONDS, remaining)),
    ) as response:
        if response.status_code != 200:
            return response.status_code, b""
        pcm = bytearray()
        for chunk in response.iter_bytes():
            if time.monotonic() >= deadline_at:
                raise TimeoutError("Nari streamed synthesis exceeded its deadline")
            pcm.extend(chunk)
    if not pcm or len(pcm) % 2:
        raise HTTPException(503, "Nari returned invalid PCM")
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm)
    return 200, output.getvalue()


def request_nari(request: SpeechRequest) -> bytes:
    destination = voice_dir(request.voice_id)
    if not (destination / "prompt.pt").is_file():
        raise HTTPException(404, "voice not found")
    ensure_voice_prompt_decoder_context(request.voice_id)
    language = normalize_language(request.language_id)
    voice_hash = hashlib.sha256(request.voice_id.encode()).hexdigest()[:12]
    seeds = (request.seed, (request.seed + 104_729) % 2_147_483_647)
    for attempt, seed in enumerate(seeds, start=1):
        try:
            response = NARI_CLIENT.post(
                f"{NARI_URL}/v1/audio/speech",
                json=nari_request_payload(request, language=language, seed=seed),
            )
        except httpx.HTTPError as error:
            raise HTTPException(503, "Nari is unavailable") from error
        if response.status_code == 422:
            raise HTTPException(422, "Nari rejected the speech request")
        if response.status_code == 429:
            raise HTTPException(429, "Nari is busy", headers={"Retry-After": "2"})
        if response.status_code != 200:
            raise HTTPException(503, "Nari synthesis failed")
        try:
            metrics = validate_generated_wav(response.content)
            expected_duration_limit = maximum_expected_output_duration_seconds(
                request.text
            )
            duration_limit = maximum_generation_duration_seconds(request.text)
            if metrics["duration_s"] > expected_duration_limit:
                raise GeneratedAudioQualityError(
                    "generated-text-duration-mismatch",
                    {
                        **metrics,
                        "expected_duration_limit_s": round(
                            expected_duration_limit, 3
                        ),
                        "generation_duration_limit_s": round(duration_limit, 3),
                    },
                    code="VOICE_OUTPUT_TEXT_MISMATCH",
                )
            # Audio ending at the calculated token budget means Talker never
            # emitted EOS. Reject the truncated/runaway candidate and retry a
            # second deterministic seed instead of returning it as success.
            if metrics["duration_s"] >= duration_limit - 0.25:
                raise GeneratedAudioQualityError(
                    "excessive-generated-duration",
                    {
                        **metrics,
                        "duration_limit_s": round(duration_limit, 3),
                    },
                )
        except GeneratedAudioQualityError as error:
            structured_log(
                "generated_audio_rejected",
                voice_hash=voice_hash,
                attempt=attempt,
                reason=str(error),
                code=error.code,
                **error.metrics,
            )
            if attempt < len(seeds):
                continue
            headers = (
                OUTPUT_TEXT_MISMATCH_HEADERS
                if error.code == "VOICE_OUTPUT_TEXT_MISMATCH"
                else GENERATED_AUDIO_REJECTION_HEADERS
            )
            raise HTTPException(
                503,
                detail={
                    "code": error.code,
                    "message": (
                        "Generated audio did not match the requested text"
                        if error.code == "VOICE_OUTPUT_TEXT_MISMATCH"
                        else "Nari returned unstable audio"
                    ),
                    "reason": str(error),
                },
                headers=headers,
            ) from error
        structured_log(
            "generated_audio_accepted",
            voice_hash=voice_hash,
            attempt=attempt,
            **metrics,
        )
        return response.content
    raise HTTPException(
        503,
        detail={
            "code": "VOICE_GENERATED_AUDIO_REJECTED",
            "message": "Nari returned unstable audio",
        },
        headers=GENERATED_AUDIO_REJECTION_HEADERS,
    )


def _voice_error_code(error: HTTPException) -> str | None:
    detail = error.detail
    if isinstance(detail, dict):
        code = detail.get("code")
        return code if isinstance(code, str) else None
    return None


def request_xvector_fallback(
    request: SpeechRequest,
    *,
    reason: str,
    deadline_at: float | None = None,
) -> bytes:
    """Use Nari's captured x-vector path when a legacy ICL prompt is unsafe.

    This mode receives only the immutable speaker embedding. It cannot prepend
    the recording guide, and unlike the former official-Qwen compatibility
    path it stays on Nari's sub-second CUDA executor.
    """

    # Load once here so malformed prompts fail before entering Nari's queue.
    voice_prompt_metadata(request.voice_id)

    language = normalize_language(request.language_id)
    voice_hash = hashlib.sha256(request.voice_id.encode()).hexdigest()[:12]
    deadline = time.monotonic() + NARI_XVECTOR_TOTAL_TIMEOUT_SECONDS
    if deadline_at is not None:
        deadline = min(deadline, deadline_at)
    attempts = (
        (request.seed, False),
        ((request.seed + 104_729) % 2_147_483_647, False),
        # A final greedy pass removes sampling variance. This is slower only on
        # the rare two-rejection path and prevents a transient bad pair from
        # making the selected cloned voice completely unusable.
        (request.seed, True),
    )
    for attempt, (seed, deterministic) in enumerate(attempts, start=1):
        remaining = deadline - time.monotonic()
        if remaining <= 0.25:
            break
        try:
            status_code, wav = nari_streamed_wav(
                nari_request_payload(
                    request,
                    language=language,
                    seed=seed,
                    voice_clone_mode="x_vector",
                    deterministic=deterministic,
                ),
                deadline_at=deadline,
            )
            if status_code == 422:
                raise HTTPException(422, "Nari rejected the x-vector request")
            if status_code == 429:
                raise HTTPException(
                    429,
                    "Nari is busy",
                    headers={"Retry-After": "2"},
                )
            if status_code != 200:
                raise HTTPException(503, "Nari x-vector synthesis failed")
            metrics = validate_generated_wav(wav)
            expected_duration_limit = maximum_expected_output_duration_seconds(
                request.text
            )
            if metrics["duration_s"] > expected_duration_limit:
                raise GeneratedAudioQualityError(
                    "generated-text-duration-mismatch",
                    {
                        **metrics,
                        "expected_duration_limit_s": round(
                            expected_duration_limit, 3
                        ),
                    },
                    code="VOICE_OUTPUT_TEXT_MISMATCH",
                )
        except GeneratedAudioQualityError as error:
            structured_log(
                "xvector_fallback_rejected",
                voice_hash=voice_hash,
                reason=reason,
                attempt=attempt,
                deterministic=deterministic,
                code=error.code,
                rejection=str(error),
                **error.metrics,
            )
            if attempt < len(attempts) and deadline - time.monotonic() > 0.25:
                continue
            headers = (
                OUTPUT_TEXT_MISMATCH_HEADERS
                if error.code == "VOICE_OUTPUT_TEXT_MISMATCH"
                else GENERATED_AUDIO_REJECTION_HEADERS
            )
            raise HTTPException(
                503,
                detail={
                    "code": error.code,
                    "message": (
                        "Generated audio did not match the requested text"
                        if error.code == "VOICE_OUTPUT_TEXT_MISMATCH"
                        else "Nari returned unstable audio"
                    ),
                    "reason": str(error),
                },
                headers=headers,
            ) from error
        except (httpx.HTTPError, TimeoutError) as error:
            structured_log(
                "xvector_fallback_failed",
                voice_hash=voice_hash,
                reason=reason,
                attempt=attempt,
                deterministic=deterministic,
                error_type=type(error).__name__,
            )
            if attempt < len(attempts) and deadline - time.monotonic() > 0.25:
                continue
            raise HTTPException(
                503,
                detail={
                    "code": "VOICE_XVECTOR_FALLBACK_FAILED",
                    "message": "Safe voice fallback failed",
                },
                headers={
                    "Retry-After": "2",
                    "X-Voice-Retryable": "true",
                    "X-Voice-Error-Code": "VOICE_XVECTOR_FALLBACK_FAILED",
                },
            ) from error
        except HTTPException:
            raise
        structured_log(
            "xvector_fallback_accepted",
            voice_hash=voice_hash,
            reason=reason,
            attempt=attempt,
            deterministic=deterministic,
            **metrics,
        )
        return wav
    raise HTTPException(
        503,
        detail={
            "code": "VOICE_XVECTOR_FALLBACK_FAILED",
            "message": "Safe voice fallback exceeded its total deadline",
        },
        headers={
            "Retry-After": "2",
            "X-Voice-Retryable": "true",
            "X-Voice-Error-Code": "VOICE_XVECTOR_FALLBACK_FAILED",
        },
    )


def request_voice_candidate(
    request: SpeechRequest,
    *,
    deadline_at: float | None = None,
) -> GeneratedVoiceCandidate:
    """Generate every cloned voice from the speaker embedding only.

    The ICL path couples reference audio/text to every paragraph and can leak a
    recording guide when that pair is imperfect.  X-vector conditioning keeps
    the cloned identity while making requested ``text`` the only speech
    content.  It is also the captured Nari sub-second path, so this single
    invariant protects correctness, timestamp alignment, and latency for old
    and new prompts alike.
    """

    metadata = voice_prompt_metadata(request.voice_id)
    reason = (
        "VOICE_FAST_XVECTOR"
        if metadata.semantic_attested
        else "VOICE_PROMPT_UNATTESTED"
    )
    if metadata.semantic_contract_error is not None:
        raw_code = metadata.semantic_contract_error.get("code")
        if isinstance(raw_code, str) and raw_code:
            reason = raw_code
    fallback_options: dict[str, object] = {"reason": reason}
    if deadline_at is not None:
        fallback_options["deadline_at"] = deadline_at
    return GeneratedVoiceCandidate(
        wav=request_xvector_fallback(request, **fallback_options),
        mode="x-vector",
    )


def request_voice(request: SpeechRequest) -> bytes:
    """Backward-compatible raw synthesis hook used by focused worker tests."""

    return request_voice_candidate(request).wav


def voice_reference_text(voice_id: str) -> str | None:
    return voice_prompt_metadata(voice_id).reference_text


def validate_voice_candidate(
    request: SpeechRequest,
    candidate: GeneratedVoiceCandidate,
) -> ValidatedVoiceAudio:
    voice_hash = hashlib.sha256(request.voice_id.encode("utf-8")).hexdigest()[:12]
    metadata = voice_prompt_metadata(request.voice_id)
    if candidate.mode == "x-vector" or metadata.semantic_attested:
        structured_log(
            "generated_audio_fast_path_accepted",
            voice_hash=voice_hash,
            generation_mode=candidate.mode,
            prompt_attested=metadata.semantic_attested,
        )
        return ValidatedVoiceAudio(wav=candidate.wav, asr=None)
    evidence = semantic_asr_validator().validate(
        candidate.wav,
        request.text,
        language=canonical_language_code(request.language_id),
        reference_text=metadata.reference_text,
    )
    structured_log(
        "generated_audio_semantic_accepted",
        voice_hash=voice_hash,
        generation_mode=candidate.mode,
        transcript_sha256=hashlib.sha256(
            evidence.transcript.encode("utf-8")
        ).hexdigest(),
        requested_word_count=len(evidence.requested_words),
        observed_word_count=len(evidence.words),
        similarity=round(evidence.similarity, 4),
        asr_ms=round(evidence.inference_seconds * 1000, 2),
    )
    return ValidatedVoiceAudio(wav=candidate.wav, asr=evidence)


def _raise_final_audio_validation_error(
    request: SpeechRequest,
    error: SemanticASRError,
) -> None:
    voice_hash = hashlib.sha256(request.voice_id.encode("utf-8")).hexdigest()[:12]
    if isinstance(error, SemanticAudioMismatch):
        structured_log(
            "generated_audio_semantic_rejected",
            voice_hash=voice_hash,
            reason=error.reason,
            **error.metrics,
        )
        raise HTTPException(
            503,
            detail={
                "code": "VOICE_OUTPUT_TEXT_MISMATCH",
                "message": "Generated audio did not match the requested text",
                "reason": error.reason,
            },
            headers=OUTPUT_TEXT_MISMATCH_HEADERS,
        ) from error
    structured_log(
        "generated_audio_semantic_validation_unavailable",
        voice_hash=voice_hash,
        error_type=type(error.__cause__ or error).__name__,
    )
    raise HTTPException(
        503,
        detail={
            "code": "VOICE_ASR_VALIDATION_UNAVAILABLE",
            "message": "Final audio validation is temporarily unavailable",
        },
        headers=ASR_UNAVAILABLE_HEADERS,
    ) from error


def request_validated_voice(request: SpeechRequest) -> ValidatedVoiceAudio:
    """Synchronous synthesis helper; production endpoints use scheduled form."""

    candidate = request_voice_candidate(request)
    try:
        return validate_voice_candidate(request, candidate)
    except SemanticAudioMismatch as first_error:
        if candidate.mode != "nari-icl":
            _raise_final_audio_validation_error(request, first_error)
        structured_log(
            "generated_audio_semantic_fallback",
            voice_hash=hashlib.sha256(
                request.voice_id.encode("utf-8")
            ).hexdigest()[:12],
            reason=first_error.reason,
        )
        fallback = GeneratedVoiceCandidate(
            wav=request_xvector_fallback(
                request,
                reason="VOICE_ASR_TEXT_MISMATCH",
            ),
            mode="x-vector",
        )
        try:
            return validate_voice_candidate(request, fallback)
        except SemanticASRError as final_error:
            _raise_final_audio_validation_error(request, final_error)
    except SemanticASRUnavailable as error:
        _raise_final_audio_validation_error(request, error)
    raise AssertionError("final-audio validation did not return or raise")


def schedule_validated_voice(
    request: SpeechRequest,
    *,
    kind: str,
    priority: int,
    request_id: str | None,
) -> ScheduledResult[ValidatedVoiceAudio]:
    """Keep CPU ASR outside the single-GPU lane and retry one safe mode."""

    started = time.monotonic()
    request_deadline = started + SYNTHESIS_TIMEOUT_SECONDS
    generated = schedule(
        lambda: request_voice_candidate(request, deadline_at=request_deadline),
        kind=kind,
        priority=priority,
        timeout_s=SYNTHESIS_TIMEOUT_SECONDS,
        request_id=request_id,
    )
    try:
        validated = validate_voice_candidate(request, generated.value)
        return ScheduledResult(
            value=validated,
            request_id=generated.request_id,
            queue_wait_s=generated.queue_wait_s,
            run_s=generated.run_s,
        )
    except SemanticASRUnavailable as error:
        _raise_final_audio_validation_error(request, error)
    except SemanticAudioMismatch as first_error:
        if generated.value.mode != "nari-icl":
            _raise_final_audio_validation_error(request, first_error)
        elapsed = time.monotonic() - started
        remaining = SYNTHESIS_TIMEOUT_SECONDS - elapsed
        if remaining <= 1.0:
            _raise_final_audio_validation_error(request, first_error)
        voice_hash = hashlib.sha256(
            request.voice_id.encode("utf-8")
        ).hexdigest()[:12]
        structured_log(
            "generated_audio_semantic_fallback",
            voice_hash=voice_hash,
            reason=first_error.reason,
        )
        fallback = schedule(
            lambda: GeneratedVoiceCandidate(
                wav=request_xvector_fallback(
                    request,
                    reason="VOICE_ASR_TEXT_MISMATCH",
                ),
                mode="x-vector",
            ),
            kind=f"{kind}-semantic-fallback",
            priority=priority,
            timeout_s=remaining,
            request_id=None,
        )
        try:
            validated = validate_voice_candidate(request, fallback.value)
        except SemanticASRError as final_error:
            _raise_final_audio_validation_error(request, final_error)
        return ScheduledResult(
            value=validated,
            request_id=generated.request_id,
            queue_wait_s=generated.queue_wait_s + fallback.queue_wait_s,
            run_s=generated.run_s + fallback.run_s,
        )
    raise AssertionError("scheduled final-audio validation did not return or raise")


def _prefix_spectral_metrics(
    mono: np.ndarray,
    sample_rate: int,
    offsets: np.ndarray,
    frame_size: int,
) -> tuple[float, float, float, float]:
    if offsets.size == 0:
        return 0.0, 0.0, 0.0, 0.0
    window = np.hanning(frame_size)
    frequencies = np.fft.rfftfreq(frame_size, 1 / sample_rate)
    speech_band = (frequencies >= 80) & (frequencies <= 11_500)
    high_band = frequencies >= 6_500
    flat_band = (frequencies >= 100) & (frequencies <= 10_000)
    high_ratios: list[float] = []
    flatness_values: list[float] = []
    for offset in offsets:
        frame = mono[int(offset) : int(offset) + frame_size]
        if frame.shape[0] < frame_size:
            frame = np.pad(frame, (0, frame_size - frame.shape[0]))
        power = np.abs(np.fft.rfft(frame * window)) ** 2 + 1e-18
        total_power = float(power[speech_band].sum()) + 1e-18
        high_ratios.append(float(power[high_band].sum()) / total_power)
        selected = power[flat_band]
        flatness_values.append(
            float(np.exp(np.mean(np.log(selected))) / np.mean(selected))
        )
    return (
        float(np.median(high_ratios)),
        float(np.quantile(high_ratios, 0.75)),
        float(np.median(flatness_values)),
        float(np.quantile(flatness_values, 0.75)),
    )


def _pitch_summary(
    mono: np.ndarray,
    sample_rate: int,
    offsets: np.ndarray,
) -> tuple[float, float, int]:
    if offsets.size == 0:
        return 0.0, 0.0, 0
    if offsets.size > 48:
        indexes = np.linspace(0, offsets.size - 1, num=48, dtype=np.int64)
        offsets = offsets[indexes]
    frame_size = round(0.05 * sample_rate)
    minimum_lag = max(1, round(sample_rate / 450))
    maximum_lag = min(frame_size - 2, round(sample_rate / 60))
    window = np.hanning(frame_size)
    pitches: list[float] = []
    for offset in offsets:
        frame = mono[int(offset) : int(offset) + frame_size]
        if frame.shape[0] < frame_size:
            continue
        frame = frame - np.mean(frame)
        if float(np.sqrt(np.mean(np.square(frame)))) < 0.008:
            continue
        frame = frame * window
        correlation = np.correlate(frame, frame, mode="full")[frame_size - 1 :]
        correlation /= float(correlation[0]) + 1e-18
        search = correlation[minimum_lag : maximum_lag + 1]
        lag = minimum_lag + int(np.argmax(search))
        confidence = float(correlation[lag])
        if confidence < 0.35:
            continue
        if 1 <= lag < correlation.shape[0] - 1:
            left, center, right = correlation[lag - 1 : lag + 2]
            denominator = float(left - 2 * center + right)
            if abs(denominator) > 1e-9:
                lag += float(0.5 * (left - right) / denominator)
        pitches.append(sample_rate / lag)
    if not pitches:
        return 0.0, 0.0, 0
    return float(np.median(pitches)), float(np.quantile(pitches, 0.90)), len(pitches)


def _generated_prefix_metrics(
    mono: np.ndarray,
    sample_rate: int,
) -> dict[str, float]:
    frame_size = round(0.08 * sample_rate)
    hop = round(0.02 * sample_rate)
    maximum_start = max(0, mono.shape[0] - frame_size)
    offsets = np.arange(0, maximum_start + 1, hop, dtype=np.int64)
    if offsets.size == 0:
        offsets = np.array([0], dtype=np.int64)
    rms_values_list: list[float] = []
    for offset in offsets:
        frame = mono[int(offset) : int(offset) + frame_size]
        if frame.shape[0] < frame_size:
            frame = np.pad(frame, (0, frame_size - frame.shape[0]))
        rms_values_list.append(float(np.sqrt(np.mean(np.square(frame)))))
    rms_values = np.asarray(rms_values_list, dtype=np.float64)
    active_threshold = max(0.004, float(np.quantile(rms_values, 0.75)) * 0.15)
    active_offsets = offsets[rms_values > active_threshold]
    first_active = int(active_offsets[0]) if active_offsets.size else 0
    prefix_end = first_active + round(2.16 * sample_rate)
    prefix_offsets = active_offsets[
        (active_offsets >= first_active) & (active_offsets < prefix_end)
    ]
    body_offsets = active_offsets[active_offsets >= prefix_end]
    prefix_high, prefix_high_p75, prefix_flat, prefix_flat_p75 = (
        _prefix_spectral_metrics(mono, sample_rate, prefix_offsets, frame_size)
    )
    prefix_pitch, prefix_pitch_p90, prefix_pitch_count = _pitch_summary(
        mono, sample_rate, prefix_offsets
    )
    body_pitch, body_pitch_p90, body_pitch_count = _pitch_summary(
        mono, sample_rate, body_offsets
    )
    pitch_ratio = prefix_pitch / body_pitch if body_pitch > 0 else 0.0
    pitch_p90_ratio = prefix_pitch_p90 / body_pitch_p90 if body_pitch_p90 > 0 else 0.0
    return {
        "first_active_s": round(first_active / sample_rate, 3),
        "prefix_high_frequency_ratio": round(prefix_high, 6),
        "prefix_high_frequency_p75": round(prefix_high_p75, 6),
        "prefix_spectral_flatness": round(prefix_flat, 6),
        "prefix_spectral_flatness_p75": round(prefix_flat_p75, 6),
        "prefix_pitch_median_hz": round(prefix_pitch, 2),
        "prefix_pitch_p90_hz": round(prefix_pitch_p90, 2),
        "prefix_pitch_frame_count": float(prefix_pitch_count),
        "body_pitch_median_hz": round(body_pitch, 2),
        "body_pitch_p90_hz": round(body_pitch_p90, 2),
        "body_pitch_frame_count": float(body_pitch_count),
        "prefix_body_pitch_ratio": round(pitch_ratio, 4),
        "prefix_body_pitch_p90_ratio": round(pitch_p90_ratio, 4),
    }


def validate_generated_wav(wav_bytes: bytes) -> dict[str, float]:
    """Require usable samples; acoustic quality scores never veto playback."""
    try:
        audio, sample_rate = sf.read(
            io.BytesIO(wav_bytes), dtype="float32", always_2d=True
        )
    except (RuntimeError, ValueError) as error:
        raise GeneratedAudioQualityError("invalid-container") from error
    if audio.size == 0 or sample_rate != SAMPLE_RATE or not np.isfinite(audio).all():
        raise GeneratedAudioQualityError("invalid-samples")
    mono = audio.mean(axis=1, dtype=np.float64)
    duration = mono.shape[0] / sample_rate
    rms = float(np.sqrt(np.mean(np.square(mono))))
    if duration < 0.2 or not math.isfinite(rms) or rms < 0.001:
        raise GeneratedAudioQualityError("empty-or-silent")
    peak = float(np.max(np.abs(mono)))
    clipping_ratio = float(np.mean(np.abs(mono) >= 0.999))
    dc_offset = float(abs(np.mean(mono)))
    silent_ratio = float(np.mean(np.abs(mono) < 0.0001))

    frame_size = 4096
    frame_count = min(32, max(1, mono.shape[0] // frame_size))
    offsets = np.linspace(
        0,
        max(0, mono.shape[0] - frame_size),
        num=frame_count,
        dtype=np.int64,
    )
    window = np.hanning(frame_size)
    frequencies = np.fft.rfftfreq(frame_size, 1 / sample_rate)
    speech_band = (frequencies >= 80) & (frequencies <= 11_500)
    high_band = frequencies >= 6_500
    flat_band = (frequencies >= 100) & (frequencies <= 10_000)
    high_ratios: list[float] = []
    flatness_values: list[float] = []
    for offset in offsets:
        frame = mono[offset : offset + frame_size]
        if frame.shape[0] < frame_size:
            frame = np.pad(frame, (0, frame_size - frame.shape[0]))
        power = np.abs(np.fft.rfft(frame * window)) ** 2
        total_power = float(power[speech_band].sum()) + 1e-18
        high_ratios.append(float(power[high_band].sum()) / total_power)
        selected = power[flat_band] + 1e-18
        flatness_values.append(
            float(np.exp(np.mean(np.log(selected))) / np.mean(selected))
        )
    high_frequency_ratio = float(np.median(high_ratios))
    spectral_flatness = float(np.median(flatness_values))
    prefix_metrics = _generated_prefix_metrics(mono, sample_rate)

    # These are acoustic heuristics, not proof that the model failed to speak.
    # In continuous reading a false positive discards a whole paragraph. Keep
    # the measurements for diagnosis without retrying or withholding its audio.
    warnings: list[str] = []
    if clipping_ratio > 0.03:
        warnings.append("excessive-clipping")
    if dc_offset > 0.10:
        warnings.append("dc-offset")
    if silent_ratio > 0.995:
        raise GeneratedAudioQualityError("mostly-silent")
    # Both whole-clip and prefix scores are advisory. Fricatives, breath and
    # sentence-initial pitch variation can overlap these empirical thresholds.
    if (
        spectral_flatness > 0.35
        or high_frequency_ratio > 0.12
        or (high_frequency_ratio > 0.04 and spectral_flatness > 0.08)
    ):
        warnings.append("noise-or-electronic-spectrum")
    if (
        prefix_metrics["prefix_spectral_flatness_p75"] > 0.10
        and prefix_metrics["prefix_high_frequency_p75"] > 0.02
    ):
        warnings.append("electronic-prefix-spectrum")
    if (
        prefix_metrics["prefix_pitch_frame_count"] >= 8
        and prefix_metrics["body_pitch_frame_count"] >= 8
        and prefix_metrics["prefix_body_pitch_ratio"] > 1.45
        and prefix_metrics["prefix_body_pitch_p90_ratio"] > 1.70
    ):
        warnings.append("unstable-prefix-pitch")
    metrics = {
        "duration_s": round(duration, 3),
        "rms": round(rms, 6),
        "peak": round(peak, 6),
        "clipping_ratio": round(clipping_ratio, 6),
        "silent_ratio": round(silent_ratio, 6),
        "high_frequency_ratio": round(high_frequency_ratio, 6),
        "spectral_flatness": round(spectral_flatness, 6),
        **prefix_metrics,
    }
    if warnings:
        structured_log(
            "generated_audio_quality_warning",
            policy="playback-first-v1",
            blocking=False,
            warnings=warnings,
            **metrics,
        )
    return metrics


def apply_speed(wav_bytes: bytes, speed: float) -> tuple[bytes, float]:
    process = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            "pipe:0",
            "-filter:a",
            f"atempo={speed:.4f}",
            "-ac",
            "1",
            "-ar",
            str(SAMPLE_RATE),
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "64k",
            "-f",
            "mp3",
            "pipe:1",
        ],
        input=wav_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        timeout=20,
    )
    audio, sample_rate = sf.read(io.BytesIO(wav_bytes), dtype="float32")
    duration = len(audio) / sample_rate / speed
    return process.stdout, duration


def timestamp_tokens(text: str) -> list[str]:
    return re.findall(
        r"\d+(?:[.,]\d+)?|[\u4e00-\u9fff]|[\u3040-\u30ff]+|[\uac00-\ud7af]+|[^\W\d_]+(?:['’][^\W\d_]+)?|[^\w\s]",
        text,
    )


WORD_TIMESTAMP_PATTERN = re.compile(
    r"\d+(?:[.,]\d+)?|[^\W\d_]+(?:['’][^\W\d_]+)?",
    re.UNICODE,
)
SEGMENT_TIMESTAMP_LANGUAGES = {"zh", "ja", "ko"}


def canonical_language_code(language: str) -> str:
    return (language or "").strip().lower().replace("_", "-").split("-", 1)[0]


def supports_word_timestamps(language: str) -> bool:
    """Return the product timing mode, independent of model capability."""
    return canonical_language_code(language) not in SEGMENT_TIMESTAMP_LANGUAGES


def word_timestamp_matches(text: str) -> list[re.Match[str]]:
    """Lexical tokens only; punctuation creates pauses, never fake words."""
    return list(WORD_TIMESTAMP_PATTERN.finditer(text))


def _mask_runs(mask: np.ndarray, value: bool) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    start: int | None = None
    for index, current in enumerate(mask):
        if bool(current) == value and start is None:
            start = index
        elif bool(current) != value and start is not None:
            runs.append((start, index))
            start = None
    if start is not None:
        runs.append((start, int(mask.shape[0])))
    return runs


def _speech_timing_profile(
    wav_bytes: bytes,
    speed: float,
    duration: float,
) -> dict[str, object] | None:
    """Cheap final-audio timing evidence; no ASR or second neural inference."""
    try:
        audio, sample_rate = sf.read(
            io.BytesIO(wav_bytes), dtype="float32", always_2d=True
        )
    except (RuntimeError, ValueError):
        return None
    if audio.size == 0 or sample_rate <= 0 or speed <= 0:
        return None
    mono = audio.mean(axis=1, dtype=np.float64)
    frame_size = max(1, round(0.020 * sample_rate))
    hop = max(1, round(0.010 * sample_rate))
    maximum_start = max(0, mono.shape[0] - frame_size)
    offsets = np.arange(0, maximum_start + 1, hop, dtype=np.int64)
    if offsets.size == 0:
        offsets = np.array([0], dtype=np.int64)
    squared = np.square(mono)
    cumulative_energy = np.concatenate(
        (np.zeros(1, dtype=np.float64), np.cumsum(squared, dtype=np.float64))
    )
    frame_ends = np.minimum(offsets + frame_size, mono.shape[0])
    frame_energy = cumulative_energy[frame_ends] - cumulative_energy[offsets]
    rms = np.sqrt(frame_energy / frame_size)
    floor = float(np.quantile(rms, 0.10))
    speech_level = float(np.quantile(rms, 0.90))
    dynamic_range = max(0.0, speech_level - floor)
    threshold = max(0.0015, floor * 1.8, floor + dynamic_range * 0.14)
    active = rms >= threshold

    # Bridge phoneme-sized gaps, then discard isolated clicks/bursts. Pauses
    # retained after this cleanup are meaningful enough to affect a word edge.
    maximum_bridge_frames = max(1, round(0.060 / (hop / sample_rate)))
    for start, end in _mask_runs(active, False):
        if start > 0 and end < active.shape[0] and end - start <= maximum_bridge_frames:
            active[start:end] = True
    minimum_active_frames = max(1, round(0.040 / (hop / sample_rate)))
    for start, end in _mask_runs(active, True):
        if end - start < minimum_active_frames:
            active[start:end] = False

    active_indexes = np.flatnonzero(active)
    if active_indexes.size == 0:
        return None
    time_scale = 1.0 / speed
    speech_start = float(offsets[int(active_indexes[0])]) / sample_rate * time_scale
    speech_end = (
        float(offsets[int(active_indexes[-1])] + frame_size)
        / sample_rate
        * time_scale
    )
    speech_start = min(duration, max(0.0, speech_start))
    speech_end = min(duration, max(speech_start, speech_end))

    pauses: list[tuple[float, float]] = []
    minimum_pause_frames = max(1, round(0.090 / (hop / sample_rate)))
    for start, end in _mask_runs(active, False):
        if (
            start <= int(active_indexes[0])
            or end > int(active_indexes[-1])
            or end - start < minimum_pause_frames
        ):
            continue
        pause_start = float(offsets[start]) / sample_rate * time_scale
        pause_end = (
            float(offsets[end - 1] + frame_size) / sample_rate * time_scale
        )
        if pause_end - pause_start >= 0.075:
            pauses.append((pause_start, min(duration, pause_end)))

    return {
        "speech_start": speech_start,
        "speech_end": speech_end,
        "pauses": pauses,
        "frame_times": offsets.astype(np.float64) / sample_rate * time_scale,
        "rms": rms,
    }


def _spoken_weight(token: str) -> float:
    letters = sum(character.isalpha() for character in token)
    digits = sum(character.isdigit() for character in token)
    # Sublinear grapheme duration is a better zero-cost proxy than raw length:
    # long words share phonemes, while every number still needs articulation.
    return max(1.0, letters**0.62 + digits * 0.55)


def _punctuation_strength(gap: str) -> int:
    if re.search(r"[.!?;:\n\r]", gap):
        return 2
    if re.search(r"[,\-–—]", gap):
        return 1
    return 0


def _allocate_word_group(
    indexes: range,
    weights: list[float],
    start_time: float,
    end_time: float,
    profile: dict[str, object] | None,
) -> dict[int, tuple[float, float]]:
    indexes_list = list(indexes)
    if not indexes_list:
        return {}
    available = max(0.001, end_time - start_time)
    group_weights = [weights[index] for index in indexes_list]
    total = sum(group_weights)
    boundaries = [start_time]
    cumulative = 0.0
    for weight in group_weights[:-1]:
        cumulative += weight
        predicted = start_time + available * cumulative / total
        boundaries.append(predicted)
    boundaries.append(end_time)

    # Snap internal predictions to a nearby low-energy valley. This follows
    # real consonant/vowel transitions without pretending to know word text
    # from the waveform, and costs only a few NumPy comparisons.
    if profile is not None and len(boundaries) > 2:
        frame_times = profile["frame_times"]
        rms = profile["rms"]
        assert isinstance(frame_times, np.ndarray)
        assert isinstance(rms, np.ndarray)
        for boundary_index in range(1, len(boundaries) - 1):
            predicted = boundaries[boundary_index]
            lower = max(boundaries[boundary_index - 1] + 0.035, predicted - 0.090)
            upper = min(boundaries[boundary_index + 1] - 0.035, predicted + 0.090)
            candidates = np.flatnonzero((frame_times >= lower) & (frame_times <= upper))
            if candidates.size:
                best = int(candidates[int(np.argmin(rms[candidates]))])
                boundaries[boundary_index] = float(frame_times[best])

    return {
        word_index: (boundaries[position], boundaries[position + 1])
        for position, word_index in enumerate(indexes_list)
    }


def maximum_expected_output_duration_seconds(text: str) -> float:
    tokens = timestamp_tokens(text)
    non_space = [character for character in text if not character.isspace()]
    cjk_count = sum(
        "\u3400" <= character <= "\u9fff"
        or "\u3040" <= character <= "\u30ff"
        or "\uac00" <= character <= "\ud7af"
        for character in non_space
    )
    cjk_dominant = cjk_count >= max(1, round(len(non_space) * 0.25))
    if cjk_dominant:
        estimated_seconds = max(1.0, cjk_count / 3.0)
    else:
        lexical_tokens = sum(
            re.search(r"[\w\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]", token)
            is not None
            for token in tokens
        )
        estimated_seconds = max(1.0, lexical_tokens / 2.2)
    # This is deliberately generous for natural pauses and slow speakers, but
    # unlike the former 12-second floor it cannot hide a 6-10 second leaked
    # reference sentence in a two-word target.
    return min(300.0, max(4.0, estimated_seconds * 1.8 + 1.8))


def maximum_generation_duration_seconds(text: str) -> float:
    # Give Talker room to emit EOS after the semantic acceptance boundary. If
    # it reaches this larger cap, the candidate is rejected and never receives
    # timestamps.
    return min(327.0, maximum_expected_output_duration_seconds(text) + 2.5)


def maximum_generated_duration_seconds(text: str) -> float:
    """Backward-compatible alias for operational probes and older tests."""
    return maximum_generation_duration_seconds(text)


def maximum_generation_frames(text: str) -> int:
    frames_per_second = SAMPLE_RATE / 1_920
    return min(
        4_096,
        max(64, math.ceil(maximum_generation_duration_seconds(text) * frames_per_second)),
    )


def estimated_timestamps(
    text: str,
    duration: float,
    *,
    language: str = "en",
    wav_bytes: bytes | None = None,
    speed: float = 1.0,
) -> list[dict[str, object]]:
    """Audio-aware, zero-neural-inference word timing for letter languages."""
    if duration <= 0 or not supports_word_timestamps(language):
        return []
    matches = word_timestamp_matches(text)
    if not matches:
        return []
    tokens = [match.group(0) for match in matches]
    weights = [_spoken_weight(token) for token in tokens]
    profile = (
        _speech_timing_profile(wav_bytes, speed, duration)
        if wav_bytes is not None
        else None
    )
    speech_start = float(profile["speech_start"]) if profile else 0.0
    speech_end = float(profile["speech_end"]) if profile else duration
    if speech_end <= speech_start:
        speech_start, speech_end = 0.0, duration

    # Pair each measured pause with the closest expected word boundary. Text
    # punctuation wins ties, but an audible unpunctuated pause is still kept.
    anchors: dict[int, tuple[float, float]] = {}
    if profile is not None and len(matches) > 1:
        pauses = profile["pauses"]
        assert isinstance(pauses, list)
        total_weight = sum(weights)
        cumulative = 0.0
        boundary_ratios: list[tuple[int, float, int]] = []
        for index in range(len(matches) - 1):
            cumulative += weights[index]
            gap = text[matches[index].end() : matches[index + 1].start()]
            boundary_ratios.append(
                (index, cumulative / total_weight, _punctuation_strength(gap))
            )
        span = max(0.001, speech_end - speech_start)
        last_boundary = -1
        for pause_start, pause_end in pauses:
            pause_ratio = ((pause_start + pause_end) * 0.5 - speech_start) / span
            candidates = [item for item in boundary_ratios if item[0] > last_boundary and item[0] not in anchors]
            if not candidates:
                break
            boundary, target_ratio, strength = min(
                candidates,
                key=lambda item: abs(item[1] - pause_ratio) - item[2] * 0.025,
            )
            if abs(target_ratio - pause_ratio) <= 0.20 + strength * 0.025:
                anchors[boundary] = (pause_start, pause_end)
                last_boundary = boundary

    allocated: dict[int, tuple[float, float]] = {}
    group_start_index = 0
    group_start_time = speech_start
    for boundary, (pause_start, pause_end) in sorted(anchors.items()):
        allocated.update(
            _allocate_word_group(
                range(group_start_index, boundary + 1),
                weights,
                group_start_time,
                max(group_start_time, pause_start),
                profile,
            )
        )
        group_start_index = boundary + 1
        group_start_time = max(group_start_time, pause_end)
    allocated.update(
        _allocate_word_group(
            range(group_start_index, len(tokens)),
            weights,
            group_start_time,
            max(group_start_time, speech_end),
            profile,
        )
    )

    result: list[dict[str, object]] = []
    previous_end = 0.0
    for index, token in enumerate(tokens):
        start, end = allocated[index]
        start = min(duration, max(previous_end, start))
        end = min(duration, max(start + 0.001, end))
        result.append(
            {
                "word": token,
                "start_time": round(start, 6),
                "end_time": round(end, 6),
            }
        )
        previous_end = end
    return result


@app.post("/v1/captioned-speech", dependencies=[Depends(require_token)])
def captioned_speech(
    request: CaptionedSpeechRequest,
    response: Response,
    x_tts_priority: str | None = Header(default=None),
    x_request_id: str | None = Header(default=None),
) -> dict[str, object]:
    if request.response_format != "mp3" or request.stream:
        raise HTTPException(422, "only non-streaming MP3 is supported")

    voice_request = SpeechRequest(
        text=request.input,
        voice_id=request.voice,
        language_id=request.language,
    )

    def synthesize(validated: ValidatedVoiceAudio) -> dict[str, object]:
        wav = validated.wav
        try:
            mp3, duration = apply_speed(wav, request.speed)
        except subprocess.SubprocessError as error:
            raise HTTPException(503, "audio conversion failed") from error
        timestamp_started = time.perf_counter()
        try:
            timestamps: list[dict[str, object]] = []
            timestamp_mode = "segment"
            if request.return_timestamps and supports_word_timestamps(request.language):
                if validated.asr is not None:
                    timestamps = measured_word_timestamps(
                        request.input,
                        validated.asr,
                        language=canonical_language_code(request.language),
                        speed=request.speed,
                        duration=duration,
                    )
                    timestamp_mode = "asr-word"
                else:
                    timestamps = estimated_timestamps(
                        request.input,
                        duration,
                        language=canonical_language_code(request.language),
                        wav_bytes=wav,
                        speed=request.speed,
                    )
                    timestamp_mode = "audio-estimated-word"
        except Exception as error:
            # Audio is already synthesized and encoded. Word alignment is
            # optional display metadata and cannot turn it into a failed TTS.
            timestamps = []
            timestamp_mode = "segment"
            structured_log(
                "captioned_word_timing_unavailable",
                policy="playback-first-v1",
                blocking=False,
                error_type=type(error).__name__,
            )
        structured_log(
            "captioned_timestamps_built",
            language=canonical_language_code(request.language),
            mode=timestamp_mode,
            count=len(timestamps),
            first_start_s=(timestamps[0]["start_time"] if timestamps else None),
            last_end_s=(timestamps[-1]["end_time"] if timestamps else None),
            audio_duration_s=round(duration, 6),
            timing_ms=round((time.perf_counter() - timestamp_started) * 1000, 3),
        )
        return {
            "audio": base64.b64encode(mp3).decode("ascii"),
            "audio_format": "audio/mpeg",
            "timestamps": timestamps,
            "voice_code": request.voice,
        }

    def scheduled_synthesis() -> ScheduledResult[dict[str, object]]:
        generated = schedule_validated_voice(
            voice_request,
            kind="captioned-speech",
            priority=request_priority(x_tts_priority),
            request_id=x_request_id,
        )
        return ScheduledResult(
            value=synthesize(generated.value),
            request_id=generated.request_id,
            queue_wait_s=generated.queue_wait_s,
            run_s=generated.run_s,
        )

    prompt_path = voice_dir(request.voice) / "prompt.pt"
    try:
        prompt_revision = prompt_path.stat().st_mtime_ns
    except FileNotFoundError as error:
        raise HTTPException(404, "voice not found") from error
    fingerprint = hashlib.sha256(
        (
            request.model_dump_json()
            + f"|prompt_revision={prompt_revision}"
        ).encode("utf-8")
    ).hexdigest()

    def content_cached_synthesis():
        return CONTENT_COALESCER.execute(
            fingerprint,
            fingerprint,
            scheduled_synthesis,
            wait_timeout_s=SYNTHESIS_TIMEOUT_SECONDS + 1.0,
        )

    idempotency_source = "disabled"
    if x_request_id:
        if len(x_request_id) > 128:
            raise HTTPException(422, "request ID is too long")
        try:
            coalesced = REQUEST_COALESCER.execute(
                x_request_id,
                fingerprint,
                content_cached_synthesis,
                wait_timeout_s=SYNTHESIS_TIMEOUT_SECONDS + 1.0,
            )
        except IdempotencyConflict as error:
            raise HTTPException(409, "request ID payload mismatch") from error
        except IdempotencyWaitTimeout as error:
            raise HTTPException(
                503,
                "original request is still running",
                headers={"Retry-After": "1"},
            ) from error
        content_result = coalesced.value
        result = content_result.value
        content_source = content_result.source
        idempotency_source = coalesced.source
    else:
        try:
            content_result = content_cached_synthesis()
        except IdempotencyWaitTimeout as error:
            raise HTTPException(
                503,
                "original content request is still running",
                headers={"Retry-After": "1"},
            ) from error
        result = content_result.value
        content_source = content_result.source
    for key, value in timing_headers(result).items():
        response.headers[key] = value
    response.headers["X-TTS-Idempotency"] = idempotency_source
    response.headers["X-TTS-Content-Cache"] = content_source
    return result.value


@app.post("/v1/speech", dependencies=[Depends(require_token)])
def speech(
    request: SpeechRequest,
    x_tts_priority: str | None = Header(default=None),
    x_request_id: str | None = Header(default=None),
) -> Response:
    result = schedule_validated_voice(
        request,
        kind="speech",
        priority=request_priority(x_tts_priority),
        request_id=x_request_id,
    )
    return Response(
        result.value.wav,
        media_type="audio/wav",
        headers=timing_headers(result),
    )
