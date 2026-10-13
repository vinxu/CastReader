"""Worker-side atomic consumer of Nari's negotiated internal PCM protocol."""

from __future__ import annotations

import io
import hashlib
import time
import wave
from dataclasses import dataclass

from fastapi import HTTPException
from nari_qwen3_tts.completion_protocol import (
    CompletionDecoder,
    CompletionProtocolError,
    MEDIA_TYPE,
    PROTOCOL,
    SAMPLE_RATE,
    request_fingerprint,
)


CLONE_COMPLETION_PROTOCOL = "eos-v1"
CLONE_COMPLETION_HEADER = "X-CastReader-Clone-Completion"


def speech_binding(input_text: str, voice_prompt: str, language: str) -> str:
    return request_fingerprint({
        "input": input_text.strip(), "voice_prompt": voice_prompt, "language": language,
    })


@dataclass(frozen=True, slots=True)
class CompletionEvidence:
    request_sha256: str
    speech_sha256: str
    wav_sha256: str


class CompletedWav(bytes):
    """Bytes-compatible, immutable result minted only after verified stream EOF.

    The in-process evidence follows these same bytes through existing quality
    validation. It is not a public field, an acoustic identity claim, or ASR.
    Converting this value to ordinary bytes deliberately drops the evidence.
    """

    def __new__(cls, wav: bytes, evidence: CompletionEvidence):
        result = super().__new__(cls, wav)
        object.__setattr__(result, "evidence", evidence)
        return result

    def __setattr__(self, name, value):
        raise AttributeError("completed audio evidence is immutable")


def require_completed_wav(wav: bytes, *, input_text: str, voice_prompt: str, language: str) -> None:
    if (
        not isinstance(wav, CompletedWav)
        or wav.evidence.speech_sha256 != speech_binding(input_text, voice_prompt, language)
        or wav.evidence.wav_sha256 != hashlib.sha256(wav).hexdigest()
    ):
        raise HTTPException(
            503,
            detail={
                "code": "VOICE_GENERATED_AUDIO_REJECTED",
                "message": "Cloned speech did not complete safely",
                "reason": "missing-nari-completion-evidence",
            },
            headers={"X-Voice-Retryable": "false", "X-Voice-Error-Code": "VOICE_GENERATED_AUDIO_REJECTED"},
        )


def collect_completed_wav(
    client,
    base_url: str,
    payload: dict[str, object],
    *,
    deadline_at: float,
    request_timeout: float,
) -> tuple[int, bytes]:
    remaining = deadline_at - time.monotonic()
    if remaining <= 0.25:
        raise TimeoutError("Nari request deadline expired before submission")
    transport_payload = {**payload, "response_format": "pcm", "stream": True}
    decoder = CompletionDecoder(request_fingerprint(transport_payload))
    try:
        with client.stream(
            "POST",
            f"{base_url}/internal/v1/audio/speech-complete",
            json=transport_payload,
            headers={"Accept": MEDIA_TYPE},
            timeout=max(0.25, min(request_timeout, remaining)),
        ) as response:
            if response.status_code != 200:
                return response.status_code, b""
            if (
                response.headers.get("content-type", "").split(";", 1)[0] != MEDIA_TYPE
                or response.headers.get("x-nari-completion-protocol") != PROTOCOL
            ):
                raise CompletionProtocolError("unsupported_completion_protocol")
            for chunk in response.iter_bytes():
                if time.monotonic() >= deadline_at:
                    raise TimeoutError("Nari streamed synthesis exceeded its deadline")
                decoder.feed(chunk)
        pcm = decoder.finish()
    except CompletionProtocolError as error:
        raise HTTPException(
            503,
            detail={
                "code": "VOICE_GENERATED_AUDIO_REJECTED",
                "message": "Cloned speech did not complete safely",
                "reason": "incomplete-nari-generation",
            },
            headers={"X-Voice-Retryable": "false", "X-Voice-Error-Code": "VOICE_GENERATED_AUDIO_REJECTED"},
        ) from error
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm)
    wav = output.getvalue()
    return 200, CompletedWav(wav, CompletionEvidence(
        request_sha256=request_fingerprint(transport_payload),
        speech_sha256=speech_binding(
            str(transport_payload["input"]),
            str(transport_payload["voice_prompt"]),
            str(transport_payload["language"]),
        ),
        wav_sha256=hashlib.sha256(wav).hexdigest(),
    ))
