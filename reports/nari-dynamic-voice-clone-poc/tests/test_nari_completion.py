"""CPU protocol/actual ASGI transport tests; these do not run a TTS model."""

from __future__ import annotations

import asyncio
import io
import json
import time
import unittest
import wave
from types import SimpleNamespace

import httpx
import torch
from fastapi import HTTPException
from fastapi.testclient import TestClient

from nari_qwen3_tts.api.app import create_app
from nari_qwen3_tts.api.http import completion_stream_bytes
from nari_qwen3_tts.completion_protocol import (
    CompletionDecoder,
    CompletionProtocolError,
    MEDIA_TYPE,
    PROTOCOL,
    event_bytes,
    pcm_events,
    request_fingerprint,
    start_event,
)
from nari_qwen3_tts.contract.errors import RequestCancelled
from nari_qwen3_tts.contract.stage import SynthesisStage
from nari_qwen3_tts.contract.result import KVPublication
from nari_qwen3_tts.contract.stream import PCMStream
from nari_qwen3_tts.contract.work import StageBatchRow, TALKER_DECODE_COMPATIBILITY
from nari_qwen3_tts.engine.commit import Committer
from nari_qwen3_tts.engine.state import GenerationPhase, RequestState
from nari_completion_client import collect_completed_wav


PCM = b"\x01\x00\xff\xff" * 128
PAYLOAD = {
    "input": "In 2026, read this 🎧 paragraph.",
    "voice": "clone", "voice_prompt": "vc_protocol_test",
    "voice_clone_mode": "x_vector", "language": "english", "seed": 1,
    "response_format": "pcm", "stream": True,
}


def encoded(payload=None, *, reason="eos", pcm=PCM):
    return start_event("unit-request", request_fingerprint(payload or PAYLOAD)) + b"".join(
        pcm_events([pcm], request_id="unit-request", stop_reason=lambda: reason)
    )


def decode(data, payload=None):
    decoder = CompletionDecoder(request_fingerprint(payload or PAYLOAD))
    decoder.feed(data)
    return decoder.finish()


class ProtocolTests(unittest.TestCase):
    def test_valid_eos(self):
        self.assertEqual(decode(encoded()), PCM)

    def test_transport_fragmentation_is_not_pcm_sequence(self):
        raw = encoded()
        decoder = CompletionDecoder(request_fingerprint(PAYLOAD))
        for byte in raw:
            decoder.feed(bytes([byte]))
        self.assertEqual(decoder.finish(), PCM)

    def test_large_chunks_are_split_into_bounded_frames(self):
        pcm = PCM * 200
        self.assertEqual(decode(encoded(pcm=pcm)), pcm)

    def test_plain_http_eof_is_not_completion(self):
        with self.assertRaises(CompletionProtocolError):
            decode(b"\n".join(encoded().split(b"\n")[:-2]) + b"\n")

    def test_limit_is_not_eos(self):
        with self.assertRaises(CompletionProtocolError):
            decode(encoded(reason="max_tokens"))

    def test_unknown_legacy_close_is_not_eos(self):
        with self.assertRaises(CompletionProtocolError):
            encoded(reason=None)

    def test_rejects_empty_pcm_even_with_eos(self):
        with self.assertRaises(CompletionProtocolError):
            decode(encoded(pcm=b""))

    def test_binds_text_voice_language_and_seed(self):
        for key, value in {"input": "other text", "voice_prompt": "vc_other", "language": "chinese", "seed": 2}.items():
            with self.subTest(key=key), self.assertRaises(CompletionProtocolError):
                decode(encoded(), {**PAYLOAD, key: value})

    def test_rejects_corrupt_order_count_hash_identity_and_format(self):
        mutations = [
            (0, "protocol", "old"), (0, "sample_rate", 48000),
            (0, "channels", True), (0, "sample_format", "float32"),
            (1, "sequence", 1), (1, "sequence", False), (1, "data", "%%%"),
            (1, "data", "AQ=="), (2, "frames", 2), (2, "pcm_bytes", 2),
            (2, "pcm_sha256", "0" * 64), (2, "request_id", "other"),
        ]
        for index, key, value in mutations:
            with self.subTest(key=key, value=value), self.assertRaises(CompletionProtocolError):
                events = [json.loads(line) for line in encoded().splitlines()]
                events[index][key] = value
                decode(b"".join(event_bytes(item) for item in events))

    def test_duplicate_or_post_terminal_events_are_rejected(self):
        for suffix in [b"x", b"\n", encoded().splitlines()[-1] + b"\n"]:
            with self.subTest(suffix=suffix[:10]), self.assertRaises(CompletionProtocolError):
                decode(encoded() + suffix)
        with self.assertRaises(CompletionProtocolError):
            decode(encoded().replace(b'"sequence":0', b'"sequence":0,"sequence":0'))

    def test_half_final_frame_is_rejected(self):
        with self.assertRaises(CompletionProtocolError):
            decode(encoded()[:-1])

    def test_terminal_error_cannot_publish_prefix(self):
        prefix = b"\n".join(encoded().split(b"\n")[:2]) + b"\n"
        for reason in ["cancelled", "backpressure", "incomplete_generation"]:
            with self.subTest(reason=reason), self.assertRaises(CompletionProtocolError):
                decode(prefix + event_bytes({"type": "error", "code": reason}))

    def test_stream_keeps_legacy_close_but_requires_explicit_evidence(self):
        stream = PCMStream(max_buffered_bytes=1024)
        stream.publish(PCM)
        stream.close()
        self.assertEqual(b"".join(stream.iter_bytes()), PCM)
        self.assertIsNone(stream.stop_reason)
        with self.assertRaises(RuntimeError):
            stream.publish(PCM)

    def test_atomic_talker_commit_retains_terminal_reason(self):
        for reason in ("eos", "max_tokens", None):
            state = RequestState.for_testing("unit")
            delta = SimpleNamespace(token=torch.tensor(1), hidden=None, logits=None,
                                    next_seen_token_mask=None, next_sampling_offset=16)
            Committer._apply_talker(state, SynthesisStage.TALKER_DECODE, delta,
                                   terminal=True, stop_reason=reason)
            self.assertEqual(state.generation.stop_reason, reason)
            self.assertIs(state.generation.phase, GenerationPhase.DONE)


class TestEngine:
    def __init__(self, reason="eos"):
        self.reason = reason
        self.config = SimpleNamespace(max_active_requests=1)
        self.submissions = []
        self.cancelled = []

    def submit(self, request_id, request, **kwargs):
        self.submissions.append(request)
        stream = PCMStream(max_buffered_bytes=4096)
        stream.publish(PCM)
        stream.close(stop_reason=self.reason)
        return stream

    def cancel(self, request_id, **kwargs):
        self.cancelled.append(request_id)


class NativeCompletionMethodTests(unittest.TestCase):
    """Real CPU completion/engine methods, with controlled Talker output tensors."""

    def test_actual_pipeline_distinguishes_eos_limit_and_nonterminal(self):
        from nari_qwen3_tts.engine.pipeline import SynthesisPipeline

        cases = [
            (99, 10, True, False, False, "eos"),
            (1, 4, True, False, False, "max_tokens"),
            (99, 4, True, False, False, "max_tokens"),
            (1, 10, True, False, False, None),
            (99, 10, False, False, False, None),
            (99, 10, True, True, False, None),
            (99, 10, True, False, True, None),
        ]
        for token, limit, decode_step, suppressed, ignore_eos, reason in cases:
            with self.subTest(token=token, limit=limit, decode=decode_step, reason=reason):
                pipeline = object.__new__(SynthesisPipeline)
                pipeline.model_config = SimpleNamespace(codec_eos_token_id=99)
                pipeline._admitted_input = lambda state: SimpleNamespace(request=SimpleNamespace(
                    effective_max_output_tokens=limit, ignore_eos=ignore_eos))
                pipeline._suppress_decode_eos = lambda state: suppressed
                state = RequestState.for_testing("unit")
                state.generation.generation_step = 3
                row = StageBatchRow(0, "unit", 0, 3, TALKER_DECODE_COMPATIBILITY)
                batch = SimpleNamespace(logical_rows=1, batch_id=1,
                                        stage=SynthesisStage.TALKER_DECODE, rows=(row,))
                output = SimpleNamespace(
                    result=SimpleNamespace(tokens=torch.tensor([token]),
                                           last_hidden=torch.zeros((1, 4)), logits=torch.zeros((1, 4))),
                    next_seen_token_masks=torch.zeros((1, 4), dtype=torch.bool),
                    kv_publications=(SimpleNamespace(proposal=lambda: KVPublication("unit", (), 0)),),
                )
                envelope = pipeline._talker_completion(batch, output, (state,), decode=decode_step)
                self.assertEqual(envelope.talker_stop_reasons, (reason,))
                self.assertEqual(envelope.talker_terminal, (reason is not None,))

    def test_actual_engine_closes_pcm_only_after_final_delivery_with_same_reason(self):
        from nari_qwen3_tts.engine.engine import Engine
        from nari_qwen3_tts.engine.output import PcmDelivery

        for reason in ("eos", "max_tokens", None):
            with self.subTest(reason=reason):
                engine = object.__new__(Engine)
                state = RequestState.for_testing("unit")
                state.generation.stop_reason = reason
                state.codec.pending_outputs = 1
                stream = PCMStream(max_buffered_bytes=4096)
                record = SimpleNamespace(request_id="unit", stream=stream,
                                         cancel_sent=False, internal_probe=False)
                engine._records = {"unit": record}
                def delivered(*args, **kwargs):
                    state.codec.pending_outputs -= 1
                engine.pipeline = SimpleNamespace(request=lambda request_id: state,
                                                  complete_pcm_output=delivered)
                engine._deliver_pcm(PcmDelivery("unit", torch.tensor([], dtype=torch.int16), PCM, True))
                self.assertTrue(stream.terminal)
                self.assertEqual(stream.stop_reason, reason)
                self.assertEqual(b"".join(stream.iter_bytes()), PCM)


class TransportTests(unittest.TestCase):
    def client(self, reason="eos"):
        engine = TestEngine(reason)
        app = create_app(engine, text_frontend=SimpleNamespace(streaming_tokenizer_concurrency=1))
        return TestClient(app), engine

    def collect(self, client, payload=None):
        return collect_completed_wav(client, "http://testserver", payload or PAYLOAD,
                                     deadline_at=time.monotonic() + 10, request_timeout=10)

    def test_actual_route_and_worker_adapter_roundtrip(self):
        client, engine = self.client()
        with client:
            status, raw = self.collect(client)
        self.assertEqual(status, 200)
        with wave.open(io.BytesIO(raw), "rb") as wav:
            self.assertEqual((wav.getframerate(), wav.getnchannels(), wav.getsampwidth()), (24000, 1, 2))
            self.assertEqual(wav.readframes(wav.getnframes()), PCM)
        self.assertEqual(engine.submissions[0].voice_prompt, "vc_protocol_test")
        self.assertEqual(len(engine.submissions), 1)

    def test_request_with_real_worker_controls_keeps_exact_fingerprint(self):
        client, _ = self.client()
        payload = {**PAYLOAD, "non_streaming_mode": True, "defer_codec_until_terminal": False,
                   "max_new_tokens": 128, "do_sample": True, "temperature": 0.9,
                   "top_k": 50, "top_p": 1.0, "repetition_penalty": 1.05,
                   "subtalker_dosample": True, "subtalker_temperature": 0.9,
                   "subtalker_top_k": 50, "subtalker_top_p": 1.0}
        with client:
            self.assertEqual(self.collect(client, payload)[0], 200)

    def test_negotiation_is_required_before_model_submission(self):
        client, engine = self.client()
        with client:
            result = client.post("/internal/v1/audio/speech-complete", json=PAYLOAD)
            self.assertEqual(result.status_code, 406)
        self.assertFalse(engine.submissions)

    def test_nonstream_or_ignore_eos_requests_rejected_before_submission(self):
        for changes in [{"stream": False}, {"response_format": "wav"}, {"ignore_eos": True}]:
            client, engine = self.client()
            with client:
                result = client.post("/internal/v1/audio/speech-complete", json={**PAYLOAD, **changes},
                                     headers={"Accept": MEDIA_TYPE})
            self.assertEqual(result.status_code, 422)
            self.assertFalse(engine.submissions)

    def test_max_tokens_or_legacy_close_produces_no_worker_audio(self):
        for reason in ["max_tokens", None]:
            client, engine = self.client(reason)
            with client, self.assertRaises(HTTPException) as caught:
                self.collect(client)
            self.assertEqual(caught.exception.status_code, 503)
            self.assertEqual(caught.exception.detail["code"], "VOICE_GENERATED_AUDIO_REJECTED")
            self.assertEqual(caught.exception.detail["reason"], "incomplete-nari-generation")
            self.assertEqual(caught.exception.headers["X-Voice-Retryable"], "false")
            self.assertEqual(len(engine.submissions), 1)

    def test_old_raw_pcm_and_wav_consumers_are_unchanged(self):
        client, _ = self.client("max_tokens")
        with client:
            pcm = client.post("/v1/audio/speech", json=PAYLOAD)
            wav = client.post("/v1/audio/speech", json={**PAYLOAD, "stream": False, "response_format": "wav"})
        self.assertEqual(pcm.status_code, 200)
        self.assertEqual(pcm.content, PCM)
        self.assertNotIn("x-nari-completion-protocol", pcm.headers)
        with wave.open(io.BytesIO(wav.content), "rb") as audio:
            self.assertEqual(audio.readframes(audio.getnframes()), PCM)

    def test_missing_endpoint_never_falls_back_to_raw_pcm(self):
        calls = []
        def handle(request):
            calls.append(request.url.path)
            return httpx.Response(404)
        with httpx.Client(transport=httpx.MockTransport(handle)) as client:
            self.assertEqual(self.collect(client), (404, b""))
        self.assertEqual(calls, ["/internal/v1/audio/speech-complete"])

    def test_truncated_and_mislabelled_http_success_are_not_audio(self):
        for body, headers in [
            (PCM, {"content-type": "audio/pcm"}),
            (encoded()[:-30], {"content-type": MEDIA_TYPE, "x-nari-completion-protocol": PROTOCOL}),
        ]:
            with self.subTest(headers=headers), httpx.Client(transport=httpx.MockTransport(
                lambda request: httpx.Response(200, content=body, headers=headers)
            )) as client, self.assertRaises(HTTPException):
                self.collect(client)


class CancellationTests(unittest.IsolatedAsyncioTestCase):
    async def test_disconnect_while_no_pcm_cancels_engine_without_unbounded_wait(self):
        engine = TestEngine()
        stream = PCMStream(max_buffered_bytes=4096)
        generator = completion_stream_bytes(engine, "cancel-me", stream, fingerprint=request_fingerprint(PAYLOAD))
        await anext(generator)
        waiting = asyncio.create_task(anext(generator))
        await asyncio.sleep(0.01)
        began = time.monotonic()
        waiting.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await waiting
        self.assertEqual(engine.cancelled, ["cancel-me"])
        self.assertLess(time.monotonic() - began, 2)

    async def test_engine_cancellation_emits_terminal_error(self):
        engine = TestEngine()
        stream = PCMStream(max_buffered_bytes=4096)
        stream.fail(RequestCancelled("unit"))
        raw = b"".join([part async for part in completion_stream_bytes(
            engine, "cancelled", stream, fingerprint=request_fingerprint(PAYLOAD))])
        self.assertEqual(json.loads(raw.splitlines()[-1])["code"], "cancelled")
        with self.assertRaises(CompletionProtocolError):
            decode(raw)


if __name__ == "__main__":
    unittest.main()
