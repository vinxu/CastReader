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
from datetime import datetime, timezone
from pathlib import Path

import httpx
import numpy as np
import soundfile as sf
import torch
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field

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
MODEL_DIR = Path(os.environ.get("NARI_MODEL_DIR", "/workspace/qwen3-tts-base/model-0.6b-base"))
NARI_URL = os.environ.get("NARI_URL", "http://127.0.0.1:8094").rstrip("/")
CLONE_WARMUP = os.environ.get("CLONE_WARMUP", "0").strip() == "1"
MAX_QUEUE_SIZE = int(os.environ.get("CLONE_MAX_QUEUE_SIZE", "64"))
SYNTHESIS_TIMEOUT_SECONDS = float(os.environ.get("CLONE_SYNTHESIS_TIMEOUT_SECONDS", "45"))
VOICE_BUILD_TIMEOUT_SECONDS = float(os.environ.get("CLONE_VOICE_BUILD_TIMEOUT_SECONDS", "90"))
NARI_REQUEST_TIMEOUT_SECONDS = float(os.environ.get("NARI_REQUEST_TIMEOUT_SECONDS", "30"))
NARI_TEMPERATURE = float(os.environ.get("NARI_TEMPERATURE", "0.9"))
NARI_TOP_K = int(os.environ.get("NARI_TOP_K", "50"))
NARI_TOP_P = float(os.environ.get("NARI_TOP_P", "1.0"))
NARI_REPETITION_PENALTY = float(os.environ.get("NARI_REPETITION_PENALTY", "1.05"))
SCHEDULER = InferenceScheduler(max_queue_size=MAX_QUEUE_SIZE)
REQUEST_COALESCER = RequestCoalescer(max_entries=64, ttl_s=90.0)
NARI_CLIENT = httpx.Client(timeout=NARI_REQUEST_TIMEOUT_SECONDS)
PROMPT_BUILDER_LOCK = threading.Lock()
PROMPT_BUILDER_INSTANCE: VoicePromptBuilder | None = None
PROMPT_SCHEMA_LOCK = threading.Lock()
PROMPT_UPGRADE_LOCK = threading.Lock()
PROMPT_SCHEMA_CACHE: dict[str, tuple[int, str]] = {}

GENERATED_AUDIO_REJECTION_HEADERS = {
    "X-Voice-Retryable": "false",
    "X-Voice-Error-Code": "VOICE_GENERATED_AUDIO_REJECTED",
}
OUTPUT_TEXT_MISMATCH_HEADERS = {
    "X-Voice-Retryable": "false",
    "X-Voice-Error-Code": "VOICE_OUTPUT_TEXT_MISMATCH",
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


def normalize_language(value: str) -> str:
    code = value.strip().lower().replace("_", "-").split("-", 1)[0]
    try:
        return LANGUAGE_MAP[code]
    except KeyError as error:
        raise HTTPException(422, "unsupported language") from error


def prepare_reference(raw: bytes) -> ReferenceAudioResult:
    try:
        audio, sample_rate = sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)
    except (RuntimeError, ValueError) as error:
        raise HTTPException(422, "reference must be valid WAV or FLAC") from error
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


app = FastAPI(title="CastReader Nari Clone Worker", docs_url=None, redoc_url=None)


@app.on_event("startup")
def prepare_storage() -> None:
    VOICE_ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if CLONE_WARMUP:
        prompt_builder()


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
    return {
        "status": "healthy" if nari_ready else "degraded",
        "model": MODEL_NAME,
        "nari_ready": nari_ready,
        **SCHEDULER.snapshot(),
    }


@app.post("/v1/voices", dependencies=[Depends(require_token)])
async def create_voice(
    reference: UploadFile = File(...),
    consent_confirmed: bool = Form(...),
    requested_voice_id: str | None = Form(default=None),
    reference_text: str = Form(...),
    x_request_id: str | None = Header(default=None),
) -> dict[str, object]:
    if not consent_confirmed:
        raise HTTPException(422, "voice-owner consent is required")
    transcript = reference_text.strip()
    if not transcript or len(transcript) > 600:
        raise HTTPException(422, "reference_text is required and must be at most 600 characters")
    raw = await reference.read(MAX_UPLOAD_BYTES + 1)
    if len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, "reference file is too large")
    reference_result = await asyncio.to_thread(prepare_reference, raw)
    normalized = reference_result.audio
    duration = reference_result.duration_seconds
    transcript_metrics = validate_reference_transcript_duration(
        transcript,
        float(reference_result.metrics["speech_duration_s"]),
    )
    voice_id = requested_voice_id or f"vc_{uuid.uuid4().hex}"
    destination = voice_dir(voice_id)
    structured_log(
        "voice_reference_quality_passed",
        voice_id=voice_id,
        quality=reference_result.metrics,
        warnings=reference_result.warnings,
    )

    def build_voice() -> dict[str, object]:
        if destination.exists() and not (destination / "prompt.pt").is_file():
            shutil.rmtree(destination)
        try:
            destination.mkdir(mode=0o700, parents=False, exist_ok=False)
        except FileExistsError as error:
            raise HTTPException(409, "voice_id already exists") from error
        reference_path = destination / "reference.wav"
        prompt_path = destination / "prompt.pt"
        sf.write(reference_path, normalized, SAMPLE_RATE, subtype="PCM_16")
        started = time.perf_counter()
        try:
            prompt_builder().save(
                str(reference_path),
                transcript,
                prompt_path,
                reference_speech_duration_s=float(
                    reference_result.metrics["speech_duration_s"]
                ),
            )
        finally:
            reference_path.unlink(missing_ok=True)
        metadata = {
            "voice_id": voice_id,
            "created_at": utc_now(),
            "consent_confirmed": True,
            "reference_duration_s": round(duration, 3),
            "reference_sha256": hashlib.sha256(raw).hexdigest(),
            "prompt_build_s": round(time.perf_counter() - started, 3),
            "model": MODEL_NAME,
            "supported_languages": sorted(LANGUAGE_MAP),
            "reference_quality": reference_result.metrics,
            "reference_quality_warnings": reference_result.warnings,
            "reference_transcript_contract": transcript_metrics,
        }
        (destination / "metadata.json").write_text(
            json.dumps(metadata, indent=2), encoding="utf-8"
        )
        return metadata

    def guarded_build_voice() -> dict[str, object]:
        try:
            return build_voice()
        except HTTPException:
            if destination.exists():
                shutil.rmtree(destination)
            raise
        except Exception as error:
            if destination.exists():
                shutil.rmtree(destination)
            raise HTTPException(503, "could not build voice prompt") from error

    result = await asyncio.to_thread(
        schedule,
        guarded_build_voice,
        kind="voice-build",
        priority=PRIORITY_BACKGROUND,
        timeout_s=VOICE_BUILD_TIMEOUT_SECONDS,
        request_id=x_request_id,
    )
    return result.value


def validate_prompt_bytes(raw: bytes) -> str:
    try:
        prompt = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=True)
    except Exception as error:
        raise HTTPException(422, "invalid voice prompt") from error
    schema = prompt.get("schema") if isinstance(prompt, dict) else None
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


def upgrade_prompt_bytes(raw: bytes) -> tuple[bytes, str]:
    schema = validate_prompt_bytes(raw)
    if schema in {
        "qwen3_tts_base_voice_clone_prompt_v3",
        "qwen3_tts_base_voice_clone_prompt_v4",
    }:
        return raw, schema
    prompt = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=True)
    assert isinstance(prompt, dict)
    upgraded = dict(prompt)
    upgraded["schema"] = "qwen3_tts_base_voice_clone_prompt_v3"
    upgraded["decoder_bootstrap_code"] = (
        prompt_builder().decoder_bootstrap_code.detach().cpu().clone()
    )
    output = io.BytesIO()
    torch.save(upgraded, output)
    compiled = output.getvalue()
    return compiled, validate_prompt_bytes(compiled)


def install_prompt_bytes(voice_id: str, raw: bytes) -> None:
    destination = voice_dir(voice_id)
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = destination / f"prompt-{uuid.uuid4().hex}.tmp"
    temporary.write_bytes(raw)
    temporary.replace(destination / "prompt.pt")
    with PROMPT_SCHEMA_LOCK:
        PROMPT_SCHEMA_CACHE.pop(voice_id, None)


def ensure_voice_prompt_decoder_context(voice_id: str) -> None:
    prompt_path = voice_dir(voice_id) / "prompt.pt"
    if not prompt_path.is_file():
        raise HTTPException(404, "voice not found")
    prompt = torch.load(
        io.BytesIO(prompt_path.read_bytes()),
        map_location="cpu",
        weights_only=True,
    )
    if not isinstance(prompt, dict):
        raise HTTPException(422, "invalid voice prompt")
    validate_prompt_semantic_contract(prompt)
    current_schema = voice_prompt_schema(voice_id)
    if current_schema in {
        "qwen3_tts_base_voice_clone_prompt_v3",
        "qwen3_tts_base_voice_clone_prompt_v4",
    }:
        return
    with PROMPT_UPGRADE_LOCK:
        current_schema = voice_prompt_schema(voice_id)
        if current_schema in {
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
    prompt_path = voice_dir(voice_id) / "prompt.pt"
    if not prompt_path.is_file():
        raise HTTPException(404, "voice not found")
    modified_ns = prompt_path.stat().st_mtime_ns
    with PROMPT_SCHEMA_LOCK:
        cached = PROMPT_SCHEMA_CACHE.get(voice_id)
        if cached is not None and cached[0] == modified_ns:
            return cached[1]
    schema = validate_prompt_bytes(prompt_path.read_bytes())
    with PROMPT_SCHEMA_LOCK:
        PROMPT_SCHEMA_CACHE[voice_id] = (modified_ns, schema)
    return schema


@app.get("/v1/voices/{voice_id}/prompt", dependencies=[Depends(require_token)])
def export_voice_prompt(voice_id: str) -> Response:
    prompt_path = voice_dir(voice_id) / "prompt.pt"
    if not prompt_path.is_file():
        raise HTTPException(404, "voice not found")
    raw = prompt_path.read_bytes()
    if not raw or len(raw) > MAX_PROMPT_BYTES:
        raise HTTPException(503, "voice prompt is invalid")
    return Response(raw, media_type="application/octet-stream")


@app.put("/v1/voices/{voice_id}/prompt", dependencies=[Depends(require_token)])
async def import_voice_prompt(voice_id: str, prompt: UploadFile = File(...)) -> dict[str, str]:
    destination = voice_dir(voice_id)
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
            "reference"
            if schema == "qwen3_tts_base_voice_clone_prompt_v4"
            else "fixed-silence"
        ),
        "upgraded_from": original_schema,
    }


@app.delete("/v1/voices/{voice_id}", dependencies=[Depends(require_token)])
def delete_voice(voice_id: str) -> dict[str, str]:
    destination = voice_dir(voice_id)
    if not (destination / "prompt.pt").is_file():
        raise HTTPException(404, "voice not found")

    def remove_voice() -> dict[str, str]:
        shutil.rmtree(destination)
        with PROMPT_SCHEMA_LOCK:
            PROMPT_SCHEMA_CACHE.pop(voice_id, None)
        return {"status": "deleted", "voice_id": voice_id}

    return schedule(
        remove_voice,
        kind="voice-delete",
        priority=PRIORITY_BACKGROUND,
        timeout_s=15.0,
        request_id=None,
    ).value


def nari_request_payload(
    request: SpeechRequest,
    *,
    language: str,
    seed: int,
) -> dict[str, object]:
    return {
        "input": request.text.strip(),
        "voice": "clone",
        "voice_prompt": request.voice_id,
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
        "do_sample": True,
        "temperature": NARI_TEMPERATURE,
        "top_k": NARI_TOP_K,
        "top_p": NARI_TOP_P,
        "repetition_penalty": NARI_REPETITION_PENALTY,
        "subtalker_dosample": True,
        "subtalker_temperature": NARI_TEMPERATURE,
        "subtalker_top_k": NARI_TOP_K,
        "subtalker_top_p": NARI_TOP_P,
    }


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


def request_xvector_fallback(request: SpeechRequest, *, reason: str) -> bytes:
    """Synthesize only from the speaker embedding when ICL is unsafe.

    The official Qwen Base x-vector path never receives reference text or
    reference codec tokens, so it cannot prepend the recording guide. It is a
    bounded compatibility path for quarantined legacy prompts and for a rare
    runtime ICL semantic failure; new incomplete recordings are still rejected
    during voice creation so normal voices keep full-fidelity ICL cloning.
    """

    prompt_path = voice_dir(request.voice_id) / "prompt.pt"
    if not prompt_path.is_file():
        raise HTTPException(404, "voice not found")
    try:
        prompt = torch.load(prompt_path, map_location="cpu", weights_only=True)
    except Exception as error:
        raise HTTPException(422, "invalid voice prompt") from error
    speaker = prompt.get("ref_spk_embedding") if isinstance(prompt, dict) else None
    if (
        not isinstance(speaker, torch.Tensor)
        or speaker.ndim != 1
        or not speaker.is_floating_point()
    ):
        raise HTTPException(422, "invalid voice prompt speaker embedding")

    language = normalize_language(request.language_id)
    voice_hash = hashlib.sha256(request.voice_id.encode()).hexdigest()[:12]
    seeds = (request.seed, (request.seed + 104_729) % 2_147_483_647)
    devices = [torch.cuda.current_device()] if torch.cuda.is_available() else []
    for attempt, seed in enumerate(seeds, start=1):
        try:
            with torch.random.fork_rng(devices=devices):
                torch.manual_seed(seed)
                if torch.cuda.is_available():
                    torch.cuda.manual_seed_all(seed)
                wavs, sample_rate = prompt_builder().model.generate_voice_clone(
                    text=request.text.strip(),
                    language=language,
                    voice_clone_prompt={
                        "ref_code": [None],
                        "ref_spk_embedding": [speaker],
                        "x_vector_only_mode": [True],
                        "icl_mode": [False],
                    },
                    non_streaming_mode=True,
                    max_new_tokens=maximum_generation_frames(request.text),
                    do_sample=True,
                    temperature=NARI_TEMPERATURE,
                    top_k=NARI_TOP_K,
                    top_p=NARI_TOP_P,
                    repetition_penalty=NARI_REPETITION_PENALTY,
                    subtalker_dosample=True,
                    subtalker_temperature=NARI_TEMPERATURE,
                    subtalker_top_k=NARI_TOP_K,
                    subtalker_top_p=NARI_TOP_P,
                )
            if sample_rate != SAMPLE_RATE or len(wavs) != 1:
                raise GeneratedAudioQualityError("invalid-xvector-result")
            output = io.BytesIO()
            sf.write(
                output,
                np.asarray(wavs[0], dtype=np.float32),
                SAMPLE_RATE,
                format="WAV",
                subtype="PCM_16",
            )
            wav = output.getvalue()
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
                code=error.code,
                rejection=str(error),
                **error.metrics,
            )
            if attempt < len(seeds):
                continue
            raise HTTPException(
                503,
                detail={
                    "code": error.code,
                    "message": "Generated audio did not match the requested text",
                    "reason": str(error),
                },
                headers=OUTPUT_TEXT_MISMATCH_HEADERS,
            ) from error
        except Exception as error:
            structured_log(
                "xvector_fallback_failed",
                voice_hash=voice_hash,
                reason=reason,
                attempt=attempt,
                error_type=type(error).__name__,
            )
            if attempt < len(seeds):
                continue
            raise HTTPException(
                503,
                detail={
                    "code": "VOICE_XVECTOR_FALLBACK_FAILED",
                    "message": "Safe voice fallback failed",
                },
                headers={
                    "X-Voice-Retryable": "false",
                    "X-Voice-Error-Code": "VOICE_XVECTOR_FALLBACK_FAILED",
                },
            ) from error
        structured_log(
            "xvector_fallback_accepted",
            voice_hash=voice_hash,
            reason=reason,
            attempt=attempt,
            **metrics,
        )
        return wav
    raise HTTPException(
        503,
        detail={
            "code": "VOICE_XVECTOR_FALLBACK_FAILED",
            "message": "Safe voice fallback failed",
        },
    )


def request_voice(request: SpeechRequest) -> bytes:
    try:
        return request_nari(request)
    except HTTPException as error:
        code = _voice_error_code(error)
        if code not in {
            "VOICE_REFERENCE_TEXT_MISMATCH",
            "VOICE_OUTPUT_TEXT_MISMATCH",
        }:
            raise
        return request_xvector_fallback(request, reason=code)


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

    if clipping_ratio > 0.03:
        raise GeneratedAudioQualityError("excessive-clipping")
    if dc_offset > 0.10:
        raise GeneratedAudioQualityError("dc-offset")
    if silent_ratio > 0.995:
        raise GeneratedAudioQualityError("mostly-silent")
    # Sustained broadband noise is substantially flatter than voiced speech.
    # Use the median across the utterance so a normal fricative or breath does
    # not reject an otherwise clean result, while white-noise/electronic bursts
    # that dominate the clip are caught before they reach playback.
    if (
        spectral_flatness > 0.35
        or high_frequency_ratio > 0.12
        or (high_frequency_ratio > 0.04 and spectral_flatness > 0.08)
    ):
        raise GeneratedAudioQualityError("noise-or-electronic-spectrum")
    if (
        prefix_metrics["prefix_spectral_flatness_p75"] > 0.10
        and prefix_metrics["prefix_high_frequency_p75"] > 0.02
    ):
        raise GeneratedAudioQualityError(
            "electronic-prefix-spectrum",
            prefix_metrics,
        )
    if (
        prefix_metrics["prefix_pitch_frame_count"] >= 8
        and prefix_metrics["body_pitch_frame_count"] >= 8
        and prefix_metrics["prefix_body_pitch_ratio"] > 1.45
        and prefix_metrics["prefix_body_pitch_p90_ratio"] > 1.70
    ):
        raise GeneratedAudioQualityError(
            "unstable-prefix-pitch",
            prefix_metrics,
        )
    return {
        "duration_s": round(duration, 3),
        "rms": round(rms, 6),
        "peak": round(peak, 6),
        "clipping_ratio": round(clipping_ratio, 6),
        "silent_ratio": round(silent_ratio, 6),
        "high_frequency_ratio": round(high_frequency_ratio, 6),
        "spectral_flatness": round(spectral_flatness, 6),
        **prefix_metrics,
    }


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

    def synthesize() -> dict[str, object]:
        wav = request_voice(
            SpeechRequest(
                text=request.input,
                voice_id=request.voice,
                language_id=request.language,
            )
        )
        try:
            mp3, duration = apply_speed(wav, request.speed)
        except subprocess.SubprocessError as error:
            raise HTTPException(503, "audio conversion failed") from error
        timestamp_started = time.perf_counter()
        timestamps = (
            estimated_timestamps(
                request.input,
                duration,
                language=request.language,
                wav_bytes=wav,
                speed=request.speed,
            )
            if request.return_timestamps
            else []
        )
        structured_log(
            "captioned_timestamps_built",
            language=canonical_language_code(request.language),
            mode=(
                "word"
                if request.return_timestamps
                and supports_word_timestamps(request.language)
                else "segment"
            ),
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
        return schedule(
            synthesize,
            kind="captioned-speech",
            priority=request_priority(x_tts_priority),
            timeout_s=SYNTHESIS_TIMEOUT_SECONDS,
            request_id=x_request_id,
        )

    idempotency_source = "disabled"
    if x_request_id:
        if len(x_request_id) > 128:
            raise HTTPException(422, "request ID is too long")
        fingerprint = hashlib.sha256(
            request.model_dump_json().encode("utf-8")
        ).hexdigest()
        try:
            coalesced = REQUEST_COALESCER.execute(
                x_request_id,
                fingerprint,
                scheduled_synthesis,
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
        result = coalesced.value
        idempotency_source = coalesced.source
    else:
        result = scheduled_synthesis()
    for key, value in timing_headers(result).items():
        response.headers[key] = value
    response.headers["X-TTS-Idempotency"] = idempotency_source
    return result.value


@app.post("/v1/speech", dependencies=[Depends(require_token)])
def speech(
    request: SpeechRequest,
    x_tts_priority: str | None = Header(default=None),
    x_request_id: str | None = Header(default=None),
) -> Response:
    result = schedule(
        lambda: request_voice(request),
        kind="speech",
        priority=request_priority(x_tts_priority),
        timeout_s=SYNTHESIS_TIMEOUT_SECONDS,
        request_id=x_request_id,
    )
    return Response(
        result.value,
        media_type="audio/wav",
        headers=timing_headers(result),
    )
