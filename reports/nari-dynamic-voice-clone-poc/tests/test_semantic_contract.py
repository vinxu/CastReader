from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import torch
from fastapi import HTTPException

import clone_worker


IOS_ENGLISH_GUIDE = (
    "My favorite thing is learning. I read every day, discover new ideas, "
    "and hope to understand the world a little better."
)


class VoiceCloneSemanticContractTests(unittest.TestCase):
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
        mismatch = HTTPException(
            422,
            detail={"code": "VOICE_REFERENCE_TEXT_MISMATCH"},
        )
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        with (
            patch.object(clone_worker, "request_nari", side_effect=mismatch),
            patch.object(
                clone_worker,
                "request_xvector_fallback",
                return_value=b"safe-wav",
            ) as fallback,
        ):
            result = clone_worker.request_voice(request)

        self.assertEqual(result, b"safe-wav")
        fallback.assert_called_once_with(
            request,
            reason="VOICE_REFERENCE_TEXT_MISMATCH",
        )

    def test_unrelated_worker_failure_never_changes_voice_mode(self) -> None:
        failure = HTTPException(503, detail={"code": "VOICE_WORKER_BUSY"})
        request = clone_worker.SpeechRequest(
            text="Azure cactus.",
            voice_id="vc_semantic_test",
            language_id="en",
        )
        with (
            patch.object(clone_worker, "request_nari", side_effect=failure),
            patch.object(clone_worker, "request_xvector_fallback") as fallback,
        ):
            with self.assertRaises(HTTPException) as captured:
                clone_worker.request_voice(request)

        self.assertIs(captured.exception, failure)
        fallback.assert_not_called()


if __name__ == "__main__":
    unittest.main()
