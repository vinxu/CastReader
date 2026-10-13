"""Internal, opt-in PCM completion evidence; not an alignment contract.

Only an explicit EOS plus a complete ordered/digested stream is publishable.
This proves transport/model termination, not that every requested word was spoken.
The module deliberately has no model or serving dependencies so the worker and
Nari transport use the same wire validator.
"""

from __future__ import annotations

import base64
import hashlib
import json
from collections.abc import Iterable

PROTOCOL = "nari-pcm-completion-v1"
MEDIA_TYPE = "application/vnd.castreader.nari-completion+jsonl"
PCM_FRAME_BYTES = 32_768
MAX_LINE_BYTES = 65_536
MAX_PCM_BYTES = 32 * 1024 * 1024
SAMPLE_RATE = 24_000


class CompletionProtocolError(ValueError):
    """The internal stream cannot prove a complete EOS result."""


def request_fingerprint(payload: dict[str, object]) -> str:
    encoded = json.dumps(
        payload, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def event_bytes(event: dict[str, object]) -> bytes:
    return (json.dumps(event, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def start_event(request_id: str, fingerprint: str) -> bytes:
    return event_bytes({
        "type": "start", "protocol": PROTOCOL, "request_id": request_id,
        "request_sha256": fingerprint, "sample_rate": SAMPLE_RATE,
        "channels": 1, "sample_format": "pcm_s16le",
    })


def pcm_events(chunks: Iterable[bytes], *, request_id: str, stop_reason) -> Iterable[bytes]:
    """Frame one already-bound engine stream; stop_reason is read after EOF."""
    encoder = CompletionEncoder(request_id)
    for chunk in chunks:
        yield from encoder.push(chunk)
    yield encoder.finish(stop_reason())


class CompletionEncoder:
    def __init__(self, request_id: str) -> None:
        self.request_id = request_id
        self.digest = hashlib.sha256()
        self.size = 0
        self.sequence = 0

    def push(self, chunk: bytes) -> Iterable[bytes]:
        if not isinstance(chunk, bytes) or len(chunk) % 2:
            raise CompletionProtocolError("invalid_pcm")
        for offset in range(0, len(chunk), PCM_FRAME_BYTES):
            part = chunk[offset:offset + PCM_FRAME_BYTES]
            self.size += len(part)
            if self.size > MAX_PCM_BYTES:
                raise CompletionProtocolError("pcm_limit")
            self.digest.update(part)
            yield event_bytes({
                "type": "pcm", "sequence": self.sequence,
                "data": base64.b64encode(part).decode("ascii"),
            })
            self.sequence += 1

    def finish(self, reason: str | None) -> bytes:
        # Never infer EOS from a normal iterator/HTTP EOF.
        if reason not in {"eos", "max_tokens"}:
            raise CompletionProtocolError("missing_stop_reason")
        return event_bytes({
            "type": "complete", "request_id": self.request_id,
            "stop_reason": reason, "frames": self.sequence,
            "pcm_bytes": self.size, "pcm_sha256": self.digest.hexdigest(),
        })


def _unique_object(items):
    result = {}
    for key, value in items:
        if key in result:
            raise CompletionProtocolError("duplicate_field")
        result[key] = value
    return result


class CompletionDecoder:
    """Fail-atomic incremental decoder. PCM is accessible only after final EOF."""

    def __init__(self, expected_fingerprint: str) -> None:
        self.expected_fingerprint = expected_fingerprint
        self.buffer = bytearray()
        self.pcm = bytearray()
        self.digest = hashlib.sha256()
        self.sequence = 0
        self.request_id: str | None = None
        self.complete = False

    def feed(self, data: bytes) -> None:
        if self.complete and data:
            raise CompletionProtocolError("data_after_terminal")
        self.buffer.extend(data)
        while b"\n" in self.buffer:
            raw, _, remainder = self.buffer.partition(b"\n")
            self.buffer = bytearray(remainder)
            if self.complete:
                raise CompletionProtocolError("data_after_terminal")
            if not raw or len(raw) > MAX_LINE_BYTES:
                raise CompletionProtocolError("invalid_frame_size")
            try:
                event = json.loads(raw, object_pairs_hook=_unique_object)
            except (UnicodeError, json.JSONDecodeError) as error:
                raise CompletionProtocolError("invalid_json") from error
            self._event(event)
        if len(self.buffer) > MAX_LINE_BYTES or (self.complete and self.buffer):
            raise CompletionProtocolError("invalid_frame_tail")

    def _event(self, event: object) -> None:
        if not isinstance(event, dict):
            raise CompletionProtocolError("invalid_event")
        kind = event.get("type")
        if self.request_id is None:
            expected = {"type", "protocol", "request_id", "request_sha256", "sample_rate", "channels", "sample_format"}
            if (
                set(event) != expected or kind != "start"
                or event["protocol"] != PROTOCOL
                or not isinstance(event["request_id"], str) or not event["request_id"]
                or event["request_sha256"] != self.expected_fingerprint
                or type(event["sample_rate"]) is not int or event["sample_rate"] != SAMPLE_RATE
                or type(event["channels"]) is not int or event["channels"] != 1
                or event["sample_format"] != "pcm_s16le"
            ):
                raise CompletionProtocolError("invalid_start_binding")
            self.request_id = event["request_id"]
            return
        if kind == "pcm":
            if (
                set(event) != {"type", "sequence", "data"}
                or type(event["sequence"]) is not int or event["sequence"] != self.sequence
                or not isinstance(event["data"], str)
            ):
                raise CompletionProtocolError("invalid_pcm_sequence")
            try:
                chunk = base64.b64decode(event["data"], validate=True)
            except (ValueError, UnicodeError) as error:
                raise CompletionProtocolError("invalid_pcm_encoding") from error
            if not chunk or len(chunk) % 2 or len(chunk) > PCM_FRAME_BYTES:
                raise CompletionProtocolError("invalid_pcm_size")
            if len(self.pcm) + len(chunk) > MAX_PCM_BYTES:
                raise CompletionProtocolError("pcm_limit")
            self.pcm.extend(chunk)
            self.digest.update(chunk)
            self.sequence += 1
            return
        if kind == "error":
            # Deliberately do not include server error text/request content.
            raise CompletionProtocolError("upstream_terminal_error")
        expected = {"type", "request_id", "stop_reason", "frames", "pcm_bytes", "pcm_sha256"}
        if (
            kind != "complete" or set(event) != expected
            or event["request_id"] != self.request_id or event["stop_reason"] != "eos"
            or type(event["frames"]) is not int or event["frames"] != self.sequence
            or type(event["pcm_bytes"]) is not int or event["pcm_bytes"] != len(self.pcm)
            or not self.pcm or event["pcm_sha256"] != self.digest.hexdigest()
        ):
            raise CompletionProtocolError("invalid_completion_evidence")
        self.complete = True

    def finish(self) -> bytes:
        if not self.complete or self.buffer:
            raise CompletionProtocolError("missing_complete_eos")
        return bytes(self.pcm)
