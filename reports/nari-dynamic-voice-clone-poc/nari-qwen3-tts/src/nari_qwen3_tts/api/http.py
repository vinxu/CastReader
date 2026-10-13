"""HTTP streaming and error translation helpers."""

from __future__ import annotations

from collections.abc import Iterator
from typing import TYPE_CHECKING

import anyio

from fastapi import HTTPException

from nari_qwen3_tts.api.wav import wav_header
from nari_qwen3_tts.contract.errors import (
    BackpressureExceeded,
    RequestCancelled,
    RequestRejected,
    ServiceCapacityExceeded,
    ServiceUnavailable,
    SynthesisError,
)
from nari_qwen3_tts.contract.stream import PCMStream
from nari_qwen3_tts.completion_protocol import CompletionEncoder, event_bytes, start_event

if TYPE_CHECKING:
    from nari_qwen3_tts.engine.engine import Engine


def stream_bytes(
    engine: Engine,
    request_id: str,
    stream: PCMStream,
    *,
    response_format: str,
    command_timeout_s: float = 10.0,
) -> Iterator[bytes]:
    try:
        if response_format == "wav":
            yield wav_header(pcm_bytes=None)
        yield from stream.iter_bytes(timeout_s=None)
    finally:
        if not stream.terminal:
            try:
                engine.cancel(request_id, timeout_s=command_timeout_s)
            except SynthesisError:
                pass


def error_response(error: BaseException) -> HTTPException:
    if isinstance(error, ServiceUnavailable):
        return HTTPException(503, str(error))
    if isinstance(error, ServiceCapacityExceeded):
        return HTTPException(429, str(error))
    if isinstance(error, RequestRejected):
        return HTTPException(422, str(error))
    if isinstance(error, RequestCancelled):
        return HTTPException(499, str(error))
    if isinstance(error, BackpressureExceeded):
        return HTTPException(503, str(error))
    return HTTPException(500, "Qwen3-TTS serving request failed")


async def completion_stream_bytes(
    engine: Engine,
    request_id: str,
    stream: PCMStream,
    *,
    fingerprint: str,
    command_timeout_s: float = 10.0,
):
    """Opt-in evidence stream with bounded, disconnect-cancellable PCM reads."""
    encoder = CompletionEncoder(request_id)
    try:
        yield start_event(request_id, fingerprint)
        while True:
            try:
                # Unlike an unbounded thread read, this gives disconnects a
                # cancellation boundary even when no more PCM is being emitted.
                chunk = await anyio.to_thread.run_sync(lambda: stream.read(timeout_s=0.25))
            except TimeoutError:
                continue
            if chunk is None:
                break
            for frame in encoder.push(chunk):
                yield frame
        yield encoder.finish(stream.stop_reason)
    except RequestCancelled:
        yield event_bytes({"type": "error", "code": "cancelled"})
    except BackpressureExceeded:
        yield event_bytes({"type": "error", "code": "backpressure"})
    except Exception:
        yield event_bytes({"type": "error", "code": "incomplete_generation"})
    finally:
        if not stream.terminal:
            # ASGI cancels the response task on disconnect. Shield only this
            # bounded cleanup so its cancellation still reaches the GPU owner.
            with anyio.CancelScope(shield=True):
                try:
                    await anyio.to_thread.run_sync(
                        lambda: engine.cancel(request_id, timeout_s=command_timeout_s)
                    )
                except SynthesisError:
                    pass


__all__ = ["completion_stream_bytes", "error_response", "stream_bytes"]
