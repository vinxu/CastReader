from __future__ import annotations

import hashlib
import os
import tempfile
import unittest
from pathlib import Path

from adaptive_denoise import (
    DiarizationEvidence,
    DeepFilterRunner,
    SpeakerDiarizer,
    canary_selected,
    configured_mode,
    raw_bypass_reason,
    runtime_mode,
    select_branch,
    should_apply,
)


def probe(online: float, atten24: float, atten100: float) -> dict[str, float | int]:
    return {
        "online_e": online,
        "atten24_e": atten24,
        "atten100_e": atten100,
        "online_low_frames": 40,
        "atten24_low_frames": 40,
        "atten100_low_frames": 40,
    }


class AdaptiveDenoisePolicyTests(unittest.TestCase):
    def test_runtime_override_is_hot_and_invalid_value_fails_off(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            override = Path(directory) / "mode"
            self.assertEqual(runtime_mode("on", override), ("on", "environment"))
            override.write_text("shadow\n", encoding="utf-8")
            self.assertEqual(runtime_mode("on", override), ("shadow", "override-file"))
            override.write_text("surprise\n", encoding="utf-8")
            self.assertEqual(runtime_mode("on", override), ("off", "override-invalid"))
        self.assertEqual(configured_mode("surprise"), "off")

    def test_canary_assignment_is_deterministic_and_mode_aware(self) -> None:
        first = canary_selected("vc_example", 10)
        self.assertEqual(first, canary_selected("vc_example", 10))
        self.assertFalse(should_apply("off", "vc_example", 100))
        self.assertTrue(should_apply("shadow", "vc_example", 0))
        self.assertTrue(should_apply("on", "vc_example", 0))
        self.assertFalse(should_apply("canary", "vc_example", 0))

    def test_only_clean_or_periodic_mechanical_audio_bypasses(self) -> None:
        self.assertEqual(
            raw_bypass_reason(
                {
                    "snr_db": 25.0,
                    "noise_estimate_reliable": True,
                    "broadband_flatness": 0.1,
                },
                [],
            ),
            "clean-reliable-snr",
        )
        self.assertEqual(
            raw_bypass_reason(
                {
                    "snr_db": 15.0,
                    "noise_estimate_reliable": True,
                    "broadband_flatness": 0.03,
                },
                ["background_noise_detected"],
            ),
            "periodic-mechanical-noise-conservative-bypass",
        )
        self.assertIsNone(
            raw_bypass_reason(
                {
                    "snr_db": None,
                    "noise_estimate_reliable": False,
                    "broadband_flatness": 0.18,
                },
                [],
            )
        )
        self.assertEqual(
            raw_bypass_reason(
                {
                    "snr_db": None,
                    "noise_estimate_reliable": False,
                    "broadband_flatness": 0.05,
                },
                [],
            ),
            "clean-spectral-backstop",
        )

    def test_selector_promotes_100_only_with_repeatable_evidence(self) -> None:
        decision = select_branch(
            [
                probe(0.10, 0.08, 0.04),
                probe(0.11, 0.09, 0.05),
                probe(0.09, 0.08, 0.06),
            ],
            atten24_eligible=True,
            atten100_eligible=True,
        )
        self.assertEqual(decision.selected, "atten100")

    def test_selector_falls_back_to_raw_on_repeatable_regression(self) -> None:
        decision = select_branch(
            [
                probe(0.01, 0.06, 0.08),
                probe(0.02, 0.07, 0.09),
                probe(0.02, 0.03, 0.04),
            ],
            atten24_eligible=True,
            atten100_eligible=True,
        )
        self.assertEqual(decision.selected, "online")

    def test_selector_uses_raw_for_identity_failure_and_24_for_sparse_evidence(self) -> None:
        identity = select_branch(
            [probe(0.1, 0.01, 0.0)] * 3,
            atten24_eligible=False,
            atten100_eligible=True,
        )
        incomplete = select_branch(
            [probe(0.1, 0.01, 0.0)] * 2,
            atten24_eligible=True,
            atten100_eligible=True,
        )
        self.assertEqual(identity.selected, "online")
        self.assertEqual(incomplete.selected, "atten24")

    def test_deepfilter_and_diarizer_assets_are_hash_pinned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "deep-filter"
            executable.write_bytes(b"trusted executable")
            executable.chmod(0o700)
            executable_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
            runner = DeepFilterRunner(executable, executable_hash)
            self.assertTrue(runner.status()["ready"])

            segmentation = root / "segmentation.onnx"
            embedding = root / "embedding.onnx"
            segmentation.write_bytes(b"segmentation")
            embedding.write_bytes(b"embedding")
            diarizer = SpeakerDiarizer(
                segmentation,
                embedding,
                expected_segmentation_sha256=hashlib.sha256(
                    segmentation.read_bytes()
                ).hexdigest(),
                expected_embedding_sha256=hashlib.sha256(
                    embedding.read_bytes()
                ).hexdigest(),
            )
            self.assertTrue(diarizer.model_status()["ready"])
            embedding.write_bytes(b"tampered")
            os.utime(embedding, None)
            self.assertFalse(diarizer.model_status()["ready"])

    def test_competing_speech_requires_meaningful_second_speaker(self) -> None:
        brief = DiarizationEvidence(
            speaker_count=2,
            segments=(),
            speaker_durations_s=(5.0, 0.2),
            overlap_duration_s=0.2,
            second_speaker_duration_s=0.2,
            elapsed_s=0.01,
        )
        clear = DiarizationEvidence(
            speaker_count=2,
            segments=(),
            speaker_durations_s=(5.0, 1.0),
            overlap_duration_s=0.0,
            second_speaker_duration_s=1.0,
            elapsed_s=0.01,
        )
        self.assertFalse(brief.competing_speech)
        self.assertTrue(clear.competing_speech)


if __name__ == "__main__":
    unittest.main()
