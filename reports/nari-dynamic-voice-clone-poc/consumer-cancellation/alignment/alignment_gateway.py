from __future__ import annotations

from dataclasses import dataclass
import hashlib
import hmac
import math
import os
from pathlib import Path
import threading
from contextlib import asynccontextmanager
import json
import logging

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from consumer_cancellation import ConsumerCancelled, check_cancelled, current_cancellation, run_on_disconnect, cancellable_post
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from caption_pipeline import CaptionPipeline, PCM, PIPELINE_REVISION, QwenPCMAligner, prepare_pcm
from request_coalescer import IdempotencyConflict, IdempotencyWaitTimeout, RequestCoalescer


class CaptionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    input: str = Field(min_length=1, max_length=600)
    voice: str = Field(pattern=r"^vc_[A-Za-z0-9_-]{1,61}$")
    language: str = Field(default="en", max_length=30)
    speed: float = Field(default=1, ge=.5, le=2)
    return_timestamps: bool = True
    response_format: str = "mp3"
    stream: bool = False
    model: str | None = None


@dataclass(frozen=True)
class WireResult:
    status: int
    body: dict
    headers: dict


def failure(code, message, status=422):
    return WireResult(status, {"detail": {"code": code, "message": message}},
                      {"X-Voice-Retryable": "false", "X-Voice-Error-Code": code,
                       "Cache-Control": "private, no-store"})


class AlignmentGateway:
    def __init__(self, *, pipeline, voices: Path, synthesize, capacity=4):
        self.pipeline = pipeline
        self.voices = voices
        self.synthesize = synthesize
        self.admission = threading.BoundedSemaphore(capacity)
        self.requests = RequestCoalescer(max_entries=64, ttl_s=90)
        self.contents = RequestCoalescer(max_entries=64, ttl_s=90)

    def generate(self, request, request_id, priority):
        if not request.input.strip() or request.response_format != "mp3" or request.stream:
            return failure("INVALID_SPEECH_REQUEST", "Nonempty text and non-streaming MP3 required")
        if request_id and len(request_id) > 128:
            return failure("INVALID_REQUEST_ID", "Request ID is too long")
        language = request.language.strip().lower().replace("_", "-").split("-", 1)[0]
        if language not in {"en", "de", "es", "fr", "it", "pt", "ru", "zh", "ja", "ko"}:
            return failure("UNSUPPORTED_LANGUAGE", "Unsupported clone language")
        try:
            revision = (self.voices / request.voice / "prompt.pt").stat().st_mtime_ns
        except FileNotFoundError:
            return failure("VOICE_NOT_FOUND", "Voice not found", 404)
        fingerprint = hashlib.sha256(
            (request.model_dump_json() + f"|{revision}|{PIPELINE_REVISION}").encode()).hexdigest()

        def execute():
            check_cancelled()
            if not self.admission.acquire(blocking=False):
                return failure("VOICE_PIPELINE_BUSY", "Caption pipeline is busy", 503)
            try:
                check_cancelled()
                audio = self.synthesize(request, request_id, priority)
                check_cancelled()
                if isinstance(audio, WireResult):
                    return audio
                wav, upstream_headers = audio
                pcm = prepare_pcm(wav, request.speed)
                caption = self.pipeline.caption(pcm, text=request.input, language=language,
                                                voice_code=request.voice,
                                                return_timestamps=request.return_timestamps,
                                                cancel=current_cancellation())
                logging.getLogger("alignment_gateway").info(json.dumps({
                    "event": "captioned_alignment_complete", "request_id": request_id,
                    "pipeline_revision": PIPELINE_REVISION, "mode": caption.reason,
                    "timestamp_count": len(caption.response["timestamps"]),
                    "audio_duration_ms": math.ceil(caption.duration * 1000),
                    "timings": caption.timings,
                }))
                headers = {name: value for name, value in upstream_headers.items()
                           if name.lower() in {"x-tts-queue-wait-ms", "x-tts-run-ms", "x-tts-request-id"}}
                headers.update({"Cache-Control": "private, no-store",
                                "X-Voice-Alignment-Revision": PIPELINE_REVISION,
                                "X-Voice-Alignment-Mode": caption.reason,
                                "X-Voice-Audio-Duration-Ms": str(math.ceil(caption.duration * 1000))})
                return WireResult(200, caption.response, headers)
            except ConsumerCancelled:
                raise
            except Exception as error:
                check_cancelled()
                logging.getLogger("alignment_gateway").error(json.dumps({
                    "event": "caption_pipeline_failed", "request_id": request_id,
                    "error_type": type(error).__name__,
                }))
                return failure("VOICE_CAPTION_PIPELINE_FAILED", "Caption pipeline unavailable", 503)
            finally:
                self.admission.release()

        def content_result():
            return self.contents.execute(fingerprint, fingerprint, execute, wait_timeout_s=65).value

        try:
            if request_id:
                coalesced = self.requests.execute(request_id, fingerprint, content_result, wait_timeout_s=65)
            else:
                coalesced = self.contents.execute(fingerprint, fingerprint, execute, wait_timeout_s=65)
            result = coalesced.value
            return WireResult(result.status, result.body,
                              dict(result.headers, **{"X-TTS-Idempotency": coalesced.source}))
        except IdempotencyConflict:
            return failure("REQUEST_ID_CONFLICT", "Request ID payload mismatch", 409)
        except IdempotencyWaitTimeout:
            return failure("VOICE_PIPELINE_PENDING", "Original caption request is still running", 503)


def build_app(gateway, token):
    if len(token) < 16:
        raise ValueError("invalid-service-token")
    @asynccontextmanager
    async def lifespan(app):
        try:
            yield
        finally:
            gateway.pipeline.close()

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)

    @app.get("/health")
    def health():
        return {"status": "ready", "pipeline_revision": PIPELINE_REVISION}

    @app.post("/v1/captioned-speech")
    async def caption(http_request: Request, request: CaptionRequest, x_clone_token: str | None = Header(default=None),
                x_request_id: str | None = Header(default=None),
                x_tts_priority: str | None = Header(default=None)):
        if not x_clone_token or not hmac.compare_digest(x_clone_token.encode(), token.encode()):
            raise HTTPException(401, "invalid token")
        result = await run_on_disconnect(http_request, lambda: gateway.generate(
            request, x_request_id, "prefetch" if x_tts_priority == "prefetch" else "interactive"))
        return JSONResponse(result.body, status_code=result.status, headers=result.headers)

    return app


def create_app():
    import numpy as np
    import torch

    logger = logging.getLogger("alignment_gateway")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    if not logger.handlers:
        logger.addHandler(logging.StreamHandler())
    token_path = Path(os.environ["CLONE_TOKEN_FILE"])
    token = token_path.read_text().strip()
    model_path = os.environ["CLONE_ALIGNER_MODEL"]
    upstream = os.environ.get("CLONE_ORIGINAL_WORKER", "http://127.0.0.1:18890")
    if upstream not in {"http://127.0.0.1:18890", "http://127.0.0.1:8890"}:
        raise ValueError("unapproved-upstream-origin")
    torch.set_num_threads(4)
    if torch.cuda.mem_get_info()[0] < 6 * 1024**3:
        raise RuntimeError("insufficient-gpu-headroom")
    torch.cuda.set_per_process_memory_fraction(.20)
    aligner = QwenPCMAligner("cuda:0", model_path)
    aligner(PCM(np.zeros(24000, dtype=np.float32), 24000), "Ready", "en")
    pipeline = CaptionPipeline(aligner, max_inflight=3, alignment_budget_s=2)

    def synthesize(request, request_id, priority):
        headers = {"X-Clone-Token": token, "X-TTS-Priority": priority}
        if request_id:
            headers["X-Request-ID"] = request_id
        response = cancellable_post(upstream + "/v1/speech", headers=headers,
                                    timeout=httpx.Timeout(60, connect=2),
                                    json={"text": request.input, "voice_id": request.voice,
                                          "language_id": request.language})
        if response.status_code != 200:
            return failure("VOICE_SYNTHESIS_FAILED", "Existing clone worker rejected synthesis",
                           response.status_code if response.status_code in {404, 422, 503} else 503)
        if len(response.content) > 12 * 1024**2:
            return failure("VOICE_AUDIO_TOO_LARGE", "Generated audio exceeds alignment budget")
        return response.content, dict(response.headers)

    gateway = AlignmentGateway(pipeline=pipeline, voices=Path(os.environ["CLONE_VOICE_ROOT"]),
                               synthesize=synthesize)
    return build_app(gateway, token)
