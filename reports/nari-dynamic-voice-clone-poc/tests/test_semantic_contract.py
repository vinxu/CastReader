from __future__ import annotations

import asyncio
import io
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import torch
from fastapi import HTTPException, UploadFile

import clone_worker
from semantic_asr import ASRWord, SemanticASREvidence, SemanticASRUnavailable, SemanticAudioMismatch


IOS_ENGLISH_GUIDE = (
    "My favorite thing is learning. I read every day, discover new ideas, "
    "and hope to understand the world a little better."
)


class VoiceCloneSemanticContractTests(unittest.TestCase):
    @staticmethod
    def _evidence() -> SemanticASREvidence:
        return SemanticASREvidence(
            transcript="Azure cactus.",
            words=(
                ASRWord("Azure", 0.0, 0.5),
                ASRWord("cactus", 0.5, 1.0),
            ),
            requested_words=("azure", "cactus"),
            similarity=1.0,
            inference_seconds=0.1,
        )

    def test_incomplete_fixed_english_guide_is_rejected(self) -> None:
        with self.assertRaises(HTTPException) as captured:
            clone_worker.validate_reference_transcript_duration(
                IOS_ENGLISH_GUIDE,
                4.224,
            )

        self.assertEqual(captured.exception.status_code, 422)
        self.assertEqual(
            captured.exception.detail["code"],
            "VOICE_REFERENCE_TEXT_MISMATCH",
        )

    def test_complete_fixed_english_guide_is_accepted(self) -> None:
        metrics = clone_worker.validate_reference_transcript_duration(
            IOS_ENGLISH_GUIDE,
            7.0,
        )

        self.assertEqual(metrics["latin_word_count"], 21)
        self.assertGreater(metrics["minimum_complete_speech_s"], 5.7)

    def test_arbitrary_or_fast_recording_text_is_advisory_only(self) -> None:
        metrics = clone_worker.observe_reference_transcript_duration(
            IOS_ENGLISH_GUIDE,
            3.0,
        )

        self.assertFalse(metrics["duration_plausible"])
        self.assertEqual(metrics["enforcement"], "advisory-only")

    def test_xvector_prompt_has_no_reference_content_contract(self) -> None:
        prompt = {
            "schema": "qwen3_tts_base_voice_clone_prompt_xvector_v1",
            "ref_spk_embedding": torch.zeros(1024),
            "x_vector_only_mode": True,
            "icl_mode": False,
            "conditioning_contract_version": 1,
            "reference_speech_duration_s": 4.5,
        }
        with tempfile.TemporaryDirectory() as directory:
            voice_path = Path(directory)
            torch.save(prompt, voice_path / "prompt.pt")
            clone_worker.PROMPT_METADATA_CACHE.clear()
            with patch.object(clone_worker, "voice_dir", return_value=voice_path):
                metadata = clone_worker.voice_prompt_metadata("vc_xvector_test")

        self.assertEqual(
            metadata.schema,
            "qwen3_tts_base_voice_clone_prompt_xvector_v1",
        )
        self.assertIsNone(metadata.reference_text)
        self.assertIsNone(metadata.semantic_contract_error)
        self.assertFalse(metadata.semantic_attested)
        clone_worker.PROMPT_METADATA_CACHE.clear()

    def test_xvector_prompt_rejects_malformed_embedding_contract(self) -> None:
        base = {
            "schema": "qwen3_tts_base_voice_clone_prompt_xvector_v1",
            "ref_spk_embedding": torch.zeros(1024),
            "x_vector_only_mode": True,
            "icl_mode": False,
            "conditioning_contract_version": 1,
        }
        invalid_variants = {
            "wrong contract version": {"conditioning_contract_version": 2},
            "wrong embedding size": {"ref_spk_embedding": torch.zeros(10)},
            "integer embedding": {
                "ref_spk_embedding": torch.zeros(1024, dtype=torch.long)
            },
            "nan embedding": {
                "ref_spk_embedding": torch.full((1024,), float("nan"))
            },
            "inf embedding": {
                "ref_spk_embedding": torch.full((1024,), float("inf"))
            },
        }

        for label, changes in invalid_variants.items():
            with self.subTest(label=label):
                prompt = dict(base)
                prompt.update(changes)
                with self.assertRaises(HTTPException) as captured:
                    clone_worker.validate_prompt_structure(prompt)
                self.assertEqual(captured.exception.status_code, 422)

    def test_creation_succeeds_without_online_asr_and_installs_atomically(self) -> None:
        class FakePromptBuilder:
            semantic_attested: bool | None = None

            def save(
                self,
                _reference_audio,
                _reference_text,
                output,
                *,
                reference_speech_duration_s,
                semantic_attested,
            ) -> None:
                self.semantic_attested = semantic_attested
                self.reference_speech_duration_s = reference_speech_duration_s
                torch.save(
                    {
                        "schema": "qwen3_tts_base_voice_clone_prompt_xvector_v1",
                        "ref_spk_embedding": torch.zeros(1024),
                        "x_vector_only_mode": True,
                        "icl_mode": False,
                        "conditioning_contract_version": 1,
                    },
                    output,
                )

        builder = FakePromptBuilder()
        reference_result = clone_worker.ReferenceAudioResult(
            audio=np.zeros(7 * clone_worker.SAMPLE_RATE, dtype=np.float32),
            sample_rate=clone_worker.SAMPLE_RATE,
            duration_seconds=7.0,
            metrics={"speech_duration_s": 7.0},
            warnings=[],
        )

        def run_immediately(execute, **_kwargs):
            return clone_worker.ScheduledResult(
                execute(),
                "creation-request",
                0.0,
                0.01,
            )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = UploadFile(
                file=io.BytesIO(b"normalized-by-test-double"),
                filename="reference.wav",
            )
            with (
                patch.object(clone_worker, "VOICE_ROOT", root),
                patch.object(
                    clone_worker,
                    "prepare_reference",
                    return_value=reference_result,
                ),
                patch.object(clone_worker, "prompt_builder", return_value=builder),
                patch.object(clone_worker, "schedule", side_effect=run_immediately),
                patch.object(clone_worker, "xvector_writer_enabled", return_value=True),
                patch.object(clone_worker, "semantic_asr_validator") as validator,
            ):
                result = asyncio.run(
                    clone_worker.create_voice(
                        reference=reference,
                        consent_confirmed=True,
                        requested_voice_id="vc_creation_contract_test",
                        reference_text=IOS_ENGLISH_GUIDE,
                        reference_language="en-US",
                        x_request_id="creation-request",
                    )
                )

            destination = root / "vc_creation_contract_test"
            self.assertTrue((destination / "prompt.pt").is_file())
            self.assertTrue((destination / "metadata.json").is_file())
            self.assertFalse((destination / "reference.wav").exists())
            self.assertEqual(tuple(root.glob(".*.building")), ())
            self.assertFalse(builder.semantic_attested)
            self.assertEqual(result["reference_language"], "en")
            self.assertFalse(result["reference_semantic_attested"])
            self.assertEqual(result["runtime_generation_mode"], "x-vector")
            validator.assert_not_called()

    def test_health_does_not_load_or_require_asr(self) -> None:
        class ReadyResponse:
            status_code = 200

            @staticmethod
            def json():
                return {"ready": True}

        with (
            patch.object(clone_worker.httpx, "get", return_value=ReadyResponse()),
            patch.object(clone_worker, "ASR_MODEL_DIR", None),
            patch.object(clone_worker, "ASR_VALIDATOR_INSTANCE", None),
            patch.object(clone_worker, "semantic_asr_validator") as validator,
        ):
            result = clone_worker.health()

        self.assertEqual(result["status"], "healthy")
        self.assertFalse(result["semantic_asr_required"])
        self.assertFalse(result["semantic_asr_ready"])
        self.assertEqual(result["voice_clone_generation_mode"], "x-vector")
        validator.assert_not_called()

    def test_creation_is_blocked_until_all_regions_accept_xvector_prompts(self) -> None:
        reference = UploadFile(file=io.BytesIO(b"unused"), filename="reference.wav")
        with patch.object(clone_worker, "xvector_writer_enabled", return_value=False):
            with self.assertRaises(HTTPException) as captured:
                asyncio.run(
                    clone_worker.create_voice(
                        reference=reference,
                        consent_confirmed=True,
                        requested_voice_id="vc_schema_gate",
                        reference_text="Any natural speech.",
                        reference_language="en",
                        x_request_id="schema-gate",
                    )
                )

        self.assertEqual(captured.exception.status_code, 503)
        self.assertEqual(
            captured.exception.detail["code"],
            "VOICE_CREATION_TEMPORARILY_UNAVAILABLE",
        )
        self.assertEqual(captured.exception.headers["Retry-After"], "30")

    def test_delete_cancels_build_before_staging_exists(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = clone_worker.register_voice_build("vc_cancel_test")
            try:
                with patch.object(clone_worker, "VOICE_ROOT", root):
                    result = clone_worker.delete_voice("vc_cancel_test")
            finally:
                clone_worker.unregister_voice_build("vc_cancel_test", event)

            self.assertEqual(result["status"], "cancelling")
            self.assertTrue(event.is_set())
            self.assertFalse((root / "vc_cancel_test").exists())

    def test_delete_during_prompt_build_never_publishes_or_leaks_reference(self) -> None:
        build_started = threading.Event()
        allow_builder_to_finish = threading.Event()

        class BlockingPromptBuilder:
            def save(self, _audio, _text, output, **_kwargs) -> None:
                build_started.set()
                if not allow_builder_to_finish.wait(2.0):
                    raise RuntimeError("test did not release prompt builder")
                torch.save(
                    {
                        "schema": "qwen3_tts_base_voice_clone_prompt_xvector_v1",
                        "ref_spk_embedding": torch.zeros(1024),
                        "x_vector_only_mode": True,
                        "icl_mode": False,
                        "conditioning_contract_version": 1,
                    },
                    output,
                )

        reference_result = clone_worker.ReferenceAudioResult(
            audio=np.zeros(4 * clone_worker.SAMPLE_RATE, dtype=np.float32),
            sample_rate=clone_worker.SAMPLE_RATE,
            duration_seconds=4.0,
            metrics={"speech_duration_s": 4.0},
            warnings=[],
        )

        def run_immediately(execute, **_kwargs):
            return clone_worker.ScheduledResult(
                execute(), "cancel-race", 0.0, 0.01
            )

        create_outcome: list[object] = []
        delete_outcome: list[object] = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def create() -> None:
                try:
                    create_outcome.append(
                        asyncio.run(
                            clone_worker.create_voice(
                                reference=UploadFile(
                                    file=io.BytesIO(b"reference"),
                                    filename="reference.wav",
                                ),
                                consent_confirmed=True,
                                requested_voice_id="vc_cancel_race",
                                reference_text="Anything at all.",
                                reference_language="en",
                                x_request_id="cancel-race",
                            )
                        )
                    )
                except BaseException as error:
                    create_outcome.append(error)

            def delete() -> None:
                try:
                    delete_outcome.append(clone_worker.delete_voice("vc_cancel_race"))
                except BaseException as error:
                    delete_outcome.append(error)

            with (
                patch.object(clone_worker, "VOICE_ROOT", root),
                patch.object(
                    clone_worker,
                    "prepare_reference",
                    return_value=reference_result,
                ),
                patch.object(
                    clone_worker,
                    "prompt_builder",
                    return_value=BlockingPromptBuilder(),
                ),
                patch.object(clone_worker, "schedule", side_effect=run_immediately),
                patch.object(clone_worker, "xvector_writer_enabled", return_value=True),
            ):
                creator = threading.Thread(target=create)
                creator.start()
                self.assertTrue(build_started.wait(1.0))
                with clone_worker.VOICE_BUILD_REGISTRY_LOCK:
                    cancellation = clone_worker.VOICE_BUILD_CANCEL_EVENTS[
                        "vc_cancel_race"
                    ]
                deleter = threading.Thread(target=delete)
                deleter.start()
                self.assertTrue(cancellation.wait(1.0))
                allow_builder_to_finish.set()
                creator.join(3.0)
                deleter.join(3.0)

            self.assertFalse(creator.is_alive())
            self.assertFalse(deleter.is_alive())
            self.assertIsInstance(create_outcome[0], HTTPException)
            self.assertEqual(delete_outcome[0]["status"], "cancelling")
            self.assertFalse((root / "vc_cancel_race").exists())
            self.assertEqual(tuple(root.glob(".*.building")), ())

    def test_legacy_prompt_uses_reference_frames_to_quarantine_mismatch(self) -> None:
        prompt = {
            "schema": "qwen3_tts_base_voice_clone_prompt_v4",
            "ref_text": IOS_ENGLISH_GUIDE,
            "ref_spk_embedding": torch.zeros(1024),
            "reference_codec_embeddings": torch.zeros((69, 1024)),
            "decoder_reference_code": torch.zeros((69, 16), dtype=torch.long),
            "x_vector_only_mode": False,
            "icl_mode": True,
        }
        with self.assertRaises(HTTPException) as captured:
            clone_worker.validate_prompt_semantic_contract(prompt)

        self.assertEqual(
            captured.exception.detail["code"],
            "VOICE_REFERENCE_TEXT_MISMATCH",
        )

    def test_prompt_runtime_metadata_loads_once_per_mtime(self) -> None:
        prompt = {
            "schema": "qwen3_tts_base_voice_clone_prompt_v4",
            "ref_text": "Azure cactus.",
            "ref_spk_embedding": torch.zeros(1024),
            "reference_codec_embeddings": torch.zeros((69, 1024)),
            "decoder_reference_code": torch.zeros((69, 16), dtype=torch.long),
            "x_vector_only_mode": False,
            "icl_mode": True,
        }
        with tempfile.TemporaryDirectory() as directory:
            voice_path = Path(directory)
            prompt_path = voice_path / "prompt.pt"
            torch.save(prompt, prompt_path)
            clone_worker.PROMPT_METADATA_CACHE.clear()
            with (
                patch.object(clone_worker, "voice_dir", return_value=voice_path),
                patch.object(
                    clone_worker.torch,
                    "load",
                    wraps=clone_worker.torch.load,
                ) as load,
            ):
                clone_worker.ensure_voice_prompt_decoder_context("vc_cache_test")
                self.assertEqual(
                    clone_worker.voice_reference_text("vc_cache_test"),
                    "Azure cactus.",
                )
                self.assertEqual(
                    clone_worker.voice_prompt_schema("vc_cache_test"),
                    "qwen3_tts_base_voice_clone_prompt_v4",
                )
                self.assertEqual(load.call_count, 1)

                prompt["ref_text"] = "Patient reader."
                torch.save(prompt, prompt_path)
                changed = prompt_path.stat().st_mtime_ns + 1_000_000
                os.utime(prompt_path, ns=(changed, changed))
                self.assertEqual(
                    clone_worker.voice_reference_text("vc_cache_test"),
                    "Patient reader.",
                )
                self.assertEqual(load.call_count, 2)
            clone_worker.PROMPT_METADATA_CACHE.clear()

    def test_quarantined_prompt_error_and_speaker_are_cached(self) -> None:
        prompt = {
            "schema": "qwen3_tts_base_voice_clone_prompt_v4",
            "ref_text": IOS_ENGLISH_GUIDE,
            "ref_spk_embedding": torch.zeros(1024),
            "reference_codec_embeddings": torch.zeros((69, 1024)),
            "decoder_reference_code": torch.zeros((69, 16), dtype=torch.long),
            "x_vector_only_mode": False,
            "icl_mode": True,
        }
        with tempfile.TemporaryDirectory() as directory:
            voice_path = Path(directory)
            torch.save(prompt, voice_path / "prompt.pt")
            clone_worker.PROMPT_METADATA_CACHE.clear()
            with (
                patch.object(clone_worker, "voice_dir", return_value=voice_path),
                patch.object(
                    clone_worker.torch,
                    "load",
                    wraps=clone_worker.torch.load,
                ) as load,
            ):
                for _ in range(2):
                    with self.assertRaises(HTTPException) as captured:
                        clone_worker.ensure_voice_prompt_decoder_context(
                            "vc_quarantined_cache_test"
                        )
                    self.assertEqual(
                        captured.exception.detail["code"],
                        "VOICE_REFERENCE_TEXT_MISMATCH",
                    )
                metadata = clone_worker.voice_prompt_metadata(
                    "vc_quarantined_cache_test"
                )
                self.assertEqual(metadata.reference_text, IOS_ENGLISH_GUIDE)
                self.assertEqual(tuple(metadata.speaker_embedding.shape), (1024,))
                self.assertEqual(load.call_count, 1)
            clone_worker.PROMPT_METADATA_CACHE.clear()

    def test_short_target_has_no_twelve_second_acceptance_floor(self) -> None:
        self.assertEqual(
            clone_worker.maximum_expected_output_duration_seconds("Azure cactus."),
            4.0,
        )
        self.assertLess(
            clone_worker.maximum_generation_duration_seconds("Azure cactus."),
            7.0,
        )

    def test_normal_paragraph_keeps_a_generous_duration_budget(self) -> None:
        text = " ".join(f"word{index}" for index in range(60))

        self.assertGreater(
            clone_worker.maximum_expected_output_duration_seconds(text),
            45.0,
        )

    def test_output_text_mismatch_is_explicitly_non_retryable(self) -> None:
        self.assertEqual(
            clone_worker.OUTPUT_TEXT_MISMATCH_HEADERS,
            {
                "X-Voice-Retryable": "false",
                "X-Voice-Error-Code": "VOICE_OUTPUT_TEXT_MISMATCH",
            },
        )

    def test_mismatched_audio_is_retried_then_rejected_before_timestamps(self) -> None:
        class FakeResponse:
            status_code = 200
            content = b"synthetic-wav"

        class FakeClient:
            def __init__(self) -> None:
                self.calls = 0

            def post(self, *_args, **_kwargs):
                self.calls += 1
                return FakeResponse()

        client = FakeClient()
        with tempfile.TemporaryDirectory() as directory:
            voice_path = Path(directory)
            (voice_path / "prompt.pt").write_bytes(b"prompt")
            with (
                patch.object(clone_worker, "voice_dir", return_value=voice_path),
                patch.object(
                    clone_worker,
                    "ensure_voice_prompt_decoder_context",
                    return_value=None,
                ),
                patch.object(clone_worker, "NARI_CLIENT", client),
                patch.object(
                    clone_worker,
                    "validate_generated_wav",
                    return_value={"duration_s": 9.04},
                ),
            ):
                with self.assertRaises(HTTPException) as captured:
                    clone_worker.request_nari(
                        clone_worker.SpeechRequest(
                            text="Azure cactus.",
                            voice_id="vc_semantic_test",
                            language_id="en",
                        )
                    )

        self.assertEqual(client.calls, 2)
        self.assertEqual(captured.exception.status_code, 503)
        self.assertEqual(
            captured.exception.detail["code"],
            "VOICE_OUTPUT_TEXT_MISMATCH",
        )
        self.assertEqual(
            captured.exception.headers["X-Voice-Error-Code"],
            "VOICE_OUTPUT_TEXT_MISMATCH",
        )

    def test_reference_mismatch_uses_safe_xvector_fallback(self) -> None:
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        metadata = clone_worker.VoicePromptMetadata(
            schema="qwen3_tts_base_voice_clone_prompt_v4",
            reference_text="Azure cactus.",
            speaker_embedding=torch.zeros(1024),
            semantic_contract_error={"code": "VOICE_REFERENCE_TEXT_MISMATCH"},
            semantic_attested=True,
        )
        with (
            patch.object(clone_worker, "voice_prompt_metadata", return_value=metadata),
            patch.object(clone_worker, "request_nari") as icl,
            patch.object(
                clone_worker,
                "request_xvector_fallback",
                return_value=b"safe-wav",
            ) as fallback,
        ):
            result = clone_worker.request_voice(request)

        self.assertEqual(result, b"safe-wav")
        icl.assert_not_called()
        fallback.assert_called_once_with(
            request,
            reason="VOICE_REFERENCE_TEXT_MISMATCH",
        )

    def test_unattested_legacy_prompt_uses_xvector_without_running_icl(self) -> None:
        metadata = clone_worker.VoicePromptMetadata(
            schema="qwen3_tts_base_voice_clone_prompt_v4",
            reference_text="Azure cactus.",
            speaker_embedding=torch.zeros(1024),
            semantic_contract_error=None,
            semantic_attested=False,
        )
        request = clone_worker.SpeechRequest(
            text="Patient reader.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        with (
            patch.object(clone_worker, "voice_prompt_metadata", return_value=metadata),
            patch.object(clone_worker, "request_nari") as icl,
            patch.object(
                clone_worker,
                "request_xvector_fallback",
                return_value=b"fast-wav",
            ) as xvector,
        ):
            result = clone_worker.request_voice_candidate(request)

        self.assertEqual(result.mode, "x-vector")
        self.assertEqual(result.wav, b"fast-wav")
        icl.assert_not_called()
        xvector.assert_called_once_with(request, reason="VOICE_PROMPT_UNATTESTED")

    def test_xvector_fallback_uses_nari_captured_mode(self) -> None:
        class FakeResponse:
            status_code = 200
            content = b"fast-wav"

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def iter_bytes(self):
                yield b"\x00\x00" * clone_worker.SAMPLE_RATE

        class FakeClient:
            def __init__(self) -> None:
                self.payload = None
                self.timeout = None

            def stream(self, _method, _url, *, json, timeout):
                self.payload = json
                self.timeout = timeout
                return FakeResponse()

        client = FakeClient()
        metadata = clone_worker.VoicePromptMetadata(
            schema="qwen3_tts_base_voice_clone_prompt_v4",
            reference_text=IOS_ENGLISH_GUIDE,
            speaker_embedding=torch.zeros(1024),
            semantic_contract_error={"code": "VOICE_REFERENCE_TEXT_MISMATCH"},
            semantic_attested=False,
        )
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        with (
            patch.object(clone_worker, "NARI_CLIENT", client),
            patch.object(clone_worker, "voice_prompt_metadata", return_value=metadata),
            patch.object(
                clone_worker,
                "validate_generated_wav",
                return_value={"duration_s": 1.0},
            ),
        ):
            result = clone_worker.request_xvector_fallback(
                request,
                reason="VOICE_REFERENCE_TEXT_MISMATCH",
            )

        self.assertTrue(result.startswith(b"RIFF"))
        self.assertEqual(client.payload["voice_clone_mode"], "x_vector")
        self.assertEqual(client.payload["response_format"], "pcm")
        self.assertTrue(client.payload["stream"])

    def test_two_sampled_rejections_use_one_deterministic_xvector_attempt(self) -> None:
        class FakeResponse:
            status_code = 200
            content = b"candidate"

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def iter_bytes(self):
                yield b"\x00\x00" * clone_worker.SAMPLE_RATE

        class FakeClient:
            def __init__(self) -> None:
                self.payloads = []

            def stream(self, _method, _url, *, json, timeout):
                self.payloads.append(json)
                return FakeResponse()

        client = FakeClient()
        metadata = clone_worker.VoicePromptMetadata(
            schema="qwen3_tts_base_voice_clone_prompt_xvector_v1",
            reference_text=None,
            speaker_embedding=torch.zeros(1024),
            semantic_contract_error=None,
            semantic_attested=False,
        )
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        rejection = clone_worker.GeneratedAudioQualityError(
            "electronic-prefix-spectrum",
            {"duration_s": 1.0},
        )
        with (
            patch.object(clone_worker, "NARI_CLIENT", client),
            patch.object(clone_worker, "voice_prompt_metadata", return_value=metadata),
            patch.object(
                clone_worker,
                "validate_generated_wav",
                side_effect=[rejection, rejection, {"duration_s": 1.0}],
            ),
        ):
            result = clone_worker.request_xvector_fallback(
                request,
                reason="VOICE_FAST_XVECTOR",
            )

        self.assertTrue(result.startswith(b"RIFF"))
        self.assertEqual(len(client.payloads), 3)
        self.assertTrue(client.payloads[0]["do_sample"])
        self.assertTrue(client.payloads[1]["do_sample"])
        self.assertFalse(client.payloads[2]["do_sample"])
        self.assertFalse(client.payloads[2]["subtalker_dosample"])

    def test_nari_xvector_skips_per_paragraph_asr(self) -> None:
        metadata = clone_worker.VoicePromptMetadata(
            schema="qwen3_tts_base_voice_clone_prompt_v4",
            reference_text=IOS_ENGLISH_GUIDE,
            speaker_embedding=torch.zeros(1024),
            semantic_contract_error={"code": "VOICE_REFERENCE_TEXT_MISMATCH"},
            semantic_attested=False,
        )
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        with (
            patch.object(clone_worker, "voice_prompt_metadata", return_value=metadata),
            patch.object(clone_worker, "semantic_asr_validator") as validator,
        ):
            result = clone_worker.validate_voice_candidate(
                request,
                clone_worker.GeneratedVoiceCandidate(b"fast-wav", "x-vector"),
            )

        self.assertEqual(result.wav, b"fast-wav")
        self.assertIsNone(result.asr)
        validator.assert_not_called()

    def test_attested_icl_skips_per_paragraph_asr(self) -> None:
        metadata = clone_worker.VoicePromptMetadata(
            schema="qwen3_tts_base_voice_clone_prompt_v4",
            reference_text="Azure cactus.",
            speaker_embedding=torch.zeros(1024),
            semantic_contract_error=None,
            semantic_attested=True,
        )
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        with (
            patch.object(clone_worker, "voice_prompt_metadata", return_value=metadata),
            patch.object(clone_worker, "semantic_asr_validator") as validator,
        ):
            result = clone_worker.validate_voice_candidate(
                request,
                clone_worker.GeneratedVoiceCandidate(b"fast-wav", "nari-icl"),
            )

        self.assertIsNone(result.asr)
        validator.assert_not_called()

    def test_attested_prompt_also_uses_fast_xvector(self) -> None:
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        metadata = clone_worker.VoicePromptMetadata(
            schema="qwen3_tts_base_voice_clone_prompt_v4",
            reference_text="Azure cactus.",
            speaker_embedding=torch.zeros(1024),
            semantic_contract_error=None,
            semantic_attested=True,
        )
        with (
            patch.object(clone_worker, "voice_prompt_metadata", return_value=metadata),
            patch.object(clone_worker, "request_nari") as icl,
            patch.object(
                clone_worker,
                "request_xvector_fallback",
                return_value=b"safe-wav",
            ) as fallback,
        ):
            result = clone_worker.request_voice(request)

        self.assertEqual(result, b"safe-wav")
        icl.assert_not_called()
        fallback.assert_called_once_with(
            request,
            reason="VOICE_FAST_XVECTOR",
        )

    def test_unrelated_worker_failure_never_changes_voice_mode(self) -> None:
        failure = HTTPException(503, detail={"code": "VOICE_WORKER_BUSY"})
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        metadata = clone_worker.VoicePromptMetadata(
            schema="qwen3_tts_base_voice_clone_prompt_v4",
            reference_text="Azure cactus.",
            speaker_embedding=torch.zeros(1024),
            semantic_contract_error=None,
            semantic_attested=True,
        )
        with (
            patch.object(clone_worker, "voice_prompt_metadata", return_value=metadata),
            patch.object(clone_worker, "request_nari") as icl,
            patch.object(
                clone_worker,
                "request_xvector_fallback",
                side_effect=failure,
            ) as fallback,
        ):
            with self.assertRaises(HTTPException) as captured:
                clone_worker.request_voice(request)

        self.assertIs(captured.exception, failure)
        icl.assert_not_called()
        fallback.assert_called_once_with(request, reason="VOICE_FAST_XVECTOR")

    def test_asr_mismatch_gets_one_safe_mode_then_is_validated_again(self) -> None:
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        first = clone_worker.GeneratedVoiceCandidate(b"nari", "nari-icl")
        fallback = clone_worker.GeneratedVoiceCandidate(b"safe", "x-vector")
        accepted = clone_worker.ValidatedVoiceAudio(b"safe", self._evidence())
        with (
            patch.object(clone_worker, "request_voice_candidate", return_value=first),
            patch.object(
                clone_worker,
                "validate_voice_candidate",
                side_effect=[
                    SemanticAudioMismatch("requested-text-mismatch", {}),
                    accepted,
                ],
            ) as validate,
            patch.object(
                clone_worker,
                "request_xvector_fallback",
                return_value=fallback.wav,
            ) as xvector,
        ):
            result = clone_worker.request_validated_voice(request)

        self.assertEqual(result.wav, b"safe")
        self.assertEqual(validate.call_count, 2)
        xvector.assert_called_once_with(request, reason="VOICE_ASR_TEXT_MISMATCH")

    def test_asr_unavailable_never_changes_generation_mode(self) -> None:
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        with (
            patch.object(
                clone_worker,
                "request_voice_candidate",
                return_value=clone_worker.GeneratedVoiceCandidate(b"nari", "nari-icl"),
            ),
            patch.object(
                clone_worker,
                "validate_voice_candidate",
                side_effect=SemanticASRUnavailable("offline model unavailable"),
            ),
            patch.object(clone_worker, "request_xvector_fallback") as xvector,
        ):
            with self.assertRaises(HTTPException) as captured:
                clone_worker.request_validated_voice(request)

        self.assertEqual(
            captured.exception.detail["code"],
            "VOICE_ASR_VALIDATION_UNAVAILABLE",
        )
        xvector.assert_not_called()

    def test_cpu_asr_runs_after_gpu_scheduler_releases_lane(self) -> None:
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        inside_gpu_lane = False

        def fake_schedule(execute, **_kwargs):
            nonlocal inside_gpu_lane
            inside_gpu_lane = True
            value = execute()
            inside_gpu_lane = False
            return clone_worker.ScheduledResult(value, "request", 0.1, 0.2)

        def validate(_request, candidate):
            self.assertFalse(inside_gpu_lane)
            return clone_worker.ValidatedVoiceAudio(candidate.wav, self._evidence())

        with (
            patch.object(clone_worker, "schedule", side_effect=fake_schedule),
            patch.object(
                clone_worker,
                "request_voice_candidate",
                return_value=clone_worker.GeneratedVoiceCandidate(b"nari", "nari-icl"),
            ),
            patch.object(clone_worker, "validate_voice_candidate", side_effect=validate),
        ):
            result = clone_worker.schedule_validated_voice(
                request,
                kind="speech",
                priority=clone_worker.PRIORITY_INTERACTIVE,
                request_id="request",
            )

        self.assertEqual(result.value.wav, b"nari")


if __name__ == "__main__":
    unittest.main()
