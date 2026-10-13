"""CPU ASGI tests of the real worker route with GPU/encoder boundaries controlled.

The selected product definitions are compiled from the worker AST so these tests
do not import qwen_tts, create a scheduler thread, load a model, or touch a GPU.
Nari protocol decoding and the worker's two coalescers are real. These are not a
substitute for full-environment worker/GPU acceptance.
"""

from __future__ import annotations

import ast
import base64
import hashlib
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Literal

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Response
from fastapi.testclient import TestClient
from pydantic import BaseModel, Field

from inference_scheduler import ScheduledResult
from nari_completion_client import (
    CLONE_COMPLETION_HEADER,
    CLONE_COMPLETION_PROTOCOL,
    CompletedWav,
    collect_completed_wav,
    require_completed_wav,
)
from nari_qwen3_tts.completion_protocol import (
    MEDIA_TYPE, PROTOCOL, pcm_events, request_fingerprint, start_event,
)
from request_coalescer import IdempotencyConflict, IdempotencyWaitTimeout, RequestCoalescer


class AlignmentFailure(Exception):
    pass


class CloneCompletionAckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "prompt.pt").write_bytes(b"test-only-prompt-not-a-model")
        self.calls = []
        self.mode = "eos"
        self.app = FastAPI()
        self.scope = {
            "__name__": __name__, "BaseModel": BaseModel, "Field": Field,
            "Literal": Literal, "app": self.app, "Depends": Depends,
            "require_token": lambda: None, "Header": Header, "Response": Response,
            "HTTPException": HTTPException, "ScheduledResult": ScheduledResult,
            "ValidatedVoiceAudio": SimpleNamespace, "hashlib": hashlib,
            "subprocess": subprocess, "time": time, "base64": base64,
            "CLONE_COMPLETION_PROTOCOL": CLONE_COMPLETION_PROTOCOL,
            "CLONE_COMPLETION_HEADER": CLONE_COMPLETION_HEADER,
            "require_completed_wav": require_completed_wav,
            "normalize_language": lambda value: {"en": "english", "zh": "chinese"}.get(value, value),
            "canonical_language_code": lambda value: value,
            "supports_word_timestamps": lambda value: value != "zh",
            "estimated_timestamps": lambda *args, **kwargs: [{"word": "fixture", "start_time": 0.0, "end_time": 0.01}],
            "apply_speed": self.encode,
            "structured_log": lambda *args, **kwargs: None,
            "SemanticAudioMismatch": AlignmentFailure,
            "schedule_validated_voice": self.schedule,
            "request_priority": lambda value: 0,
            "voice_dir": lambda value: self.root,
            "SYNTHESIS_TIMEOUT_SECONDS": 10,
            "CONTENT_COALESCER": RequestCoalescer(),
            "REQUEST_COALESCER": RequestCoalescer(),
            "IdempotencyConflict": IdempotencyConflict,
            "IdempotencyWaitTimeout": IdempotencyWaitTimeout,
            "timing_headers": lambda value: {},
        }
        source = Path(__file__).resolve().parents[1] / "worker/clone_worker.py"
        tree = ast.parse(source.read_text())
        selected = [node for node in tree.body if getattr(node, "name", None) in {
            "SpeechRequest", "CaptionedSpeechRequest", "captioned_speech",
        }]
        self.assertEqual(len(selected), 3)
        exec(compile(ast.Module(body=selected, type_ignores=[]), str(source), "exec"), self.scope)
        self.client = TestClient(self.app)

    def tearDown(self):
        self.client.close()
        self.temp.cleanup()

    def encode(self, wav, speed):
        if self.mode == "encoder_error":
            raise subprocess.SubprocessError("fixture conversion failure")
        return b"fixture-mp3", 0.02

    def schedule(self, request, **kwargs):
        self.calls.append(request)
        payload = {
            "input": request.text.strip(), "voice_prompt": request.voice_id,
            "language": self.scope["normalize_language"](request.language_id),
            "response_format": "pcm", "stream": True,
        }
        if self.mode == "wrong_voice":
            payload["voice_prompt"] = "vc_other"
        if self.mode == "wrong_text":
            payload["input"] = "Different requested paragraph."
        if self.mode == "wrong_language":
            payload["language"] = "chinese"
        raw = start_event("fixture-request", request_fingerprint(payload)) + b"".join(pcm_events(
            [b"\x01\x00\xff\xff" * 128], request_id="fixture-request",
            stop_reason=lambda: "max_tokens" if self.mode == "max_tokens" else "eos",
        ))
        if self.mode == "cut":
            raw = raw[:-20]
        if self.mode == "trailing":
            raw += b'{"event":"unexpected"}\n'
        if self.mode == "hash":
            raw = raw.replace(b'"pcm_sha256":"', b'"pcm_sha256":"bad')
        with httpx.Client(transport=httpx.MockTransport(lambda _: httpx.Response(
            200, content=raw, headers={"Content-Type": MEDIA_TYPE, "X-Nari-Completion-Protocol": PROTOCOL},
        ))) as transport:
            _, wav = collect_completed_wav(
                transport, "http://fixture", payload,
                deadline_at=time.monotonic() + 10, request_timeout=10,
            )
        self.assertIsInstance(wav, CompletedWav)
        if self.mode == "raw":
            wav = bytes(wav)
        return ScheduledResult(SimpleNamespace(wav=wav, asr=None), "fixture", 0, 0)

    def post(self, *, negotiate=True, request_id=None, **changes):
        body = {"input": "A fixture paragraph.", "voice": "vc_fixture", "language": "en"}
        if negotiate:
            body["required_clone_completion"] = "eos-v1"
        body.update(changes)
        headers = {"X-Request-ID": request_id} if request_id else {}
        return self.client.post("/v1/captioned-speech", json=body, headers=headers)

    def test_eos_success_ack_and_exact_four_fields(self):
        response = self.post()
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers.get(CLONE_COMPLETION_HEADER), "eos-v1")
        self.assertEqual(set(response.json()), {"audio", "audio_format", "timestamps", "voice_code"})

    def test_no_opt_in_is_not_acknowledged(self):
        self.mode = "raw"
        response = self.post(negotiate=False)
        self.assertEqual(response.status_code, 200)
        self.assertNotIn(CLONE_COMPLETION_HEADER, response.headers)
        self.assertEqual(len(response.json()), 4)

    def test_unknown_protocol_rejected_before_generation(self):
        for value in ["eos-v2", "", True, 1, {}]:
            with self.subTest(value=value):
                response = self.post(required_clone_completion=value)
                self.assertEqual(response.status_code, 422)
                self.assertNotIn(CLONE_COMPLETION_HEADER, response.headers)
        self.assertEqual(self.calls, [])

    def test_raw_evidence_mismatch_truncation_and_encoder_failure_never_ack(self):
        for mode in ["raw", "wrong_voice", "wrong_text", "wrong_language", "max_tokens", "cut", "trailing", "hash", "encoder_error"]:
            with self.subTest(mode=mode):
                self.mode = mode
                response = self.post(input="Different fixture " + mode)
                self.assertEqual(response.status_code, 503, response.text)
                self.assertNotIn(CLONE_COMPLETION_HEADER, response.headers)
                self.assertNotIn("audio", response.json())

    def test_cached_success_keeps_proof_and_does_not_generate_again(self):
        first = self.post(request_id="same-id")
        self.mode = "raw"
        cached = self.post(request_id="same-id")
        self.assertEqual(first.status_code, 200)
        self.assertEqual(cached.status_code, 200)
        self.assertEqual(cached.headers.get(CLONE_COMPLETION_HEADER), "eos-v1")
        self.assertEqual(cached.json(), first.json())
        self.assertEqual(len(self.calls), 1)

    def test_old_content_cannot_satisfy_new_negotiation_cache(self):
        self.mode = "raw"
        self.assertEqual(self.post(negotiate=False).status_code, 200)
        response = self.post()
        self.assertEqual(response.status_code, 503)
        self.assertNotIn(CLONE_COMPLETION_HEADER, response.headers)
        self.assertEqual(len(self.calls), 2)

    def test_same_id_old_to_new_protocol_is_conflict(self):
        self.assertEqual(self.post(negotiate=False, request_id="same-id").status_code, 200)
        response = self.post(request_id="same-id")
        self.assertEqual(response.status_code, 409)
        self.assertNotIn(CLONE_COMPLETION_HEADER, response.headers)
        self.assertEqual(len(self.calls), 1)

    def test_cjk_segment_and_speed_preserve_completion_ack(self):
        response = self.post(language="zh", input="这是测试段落。", speed=2.0)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers.get(CLONE_COMPLETION_HEADER), "eos-v1")
        self.assertEqual(response.json()["timestamps"], [])


if __name__ == "__main__":
    unittest.main()
