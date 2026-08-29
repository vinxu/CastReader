from __future__ import annotations

import io
import tempfile
import unittest
from pathlib import Path

import numpy as np
import soundfile as sf

from semantic_asr import (
    ASRWord,
    REQUIRED_MODEL_FILES,
    SemanticASREvidence,
    SemanticASRUnavailable,
    SemanticASRValidator,
    SemanticAudioMismatch,
    measured_word_timestamps,
    validate_transcript,
)


GUIDE = (
    "My favorite thing is learning. I read every day, discover new ideas, "
    "and hope to understand the world a little better."
)


class SemanticASRContractTests(unittest.TestCase):
    def test_exact_requested_text_is_accepted(self) -> None:
        metrics = validate_transcript(
            "Azure cactus.",
            " Azure Cactus.",
            reference_text=GUIDE,
        )

        self.assertEqual(metrics["similarity"], 1.0)
        self.assertEqual(metrics["extra_word_count"], 0)

    def test_reference_prefix_before_target_is_rejected(self) -> None:
        with self.assertRaises(SemanticAudioMismatch) as captured:
            validate_transcript(
                "Azure cactus.",
                "My favorite thing is learning. Azure cactus.",
                reference_text=GUIDE,
            )

        self.assertEqual(captured.exception.reason, "reference-prefix-leak")

    def test_unrelated_or_partial_audio_is_rejected(self) -> None:
        for transcript in ("Financial news one two.", "The patient reader."):
            with self.subTest(transcript=transcript):
                with self.assertRaises(SemanticAudioMismatch):
                    validate_transcript(
                        "The patient reader notices every subtle change.",
                        transcript,
                        reference_text=GUIDE,
                    )

    def test_minor_asr_spelling_substitution_is_accepted(self) -> None:
        metrics = validate_transcript(
            "The color is gray.",
            "The colour is grey.",
        )

        self.assertGreaterEqual(metrics["similarity"], 0.78)

    def test_word_timestamps_are_measured_and_scaled_without_interpolation(self) -> None:
        evidence = SemanticASREvidence(
            transcript="Hello world",
            words=(
                ASRWord("Hello", 0.24, 0.72),
                ASRWord("world", 0.94, 1.48),
            ),
            requested_words=("hello", "world"),
            similarity=1.0,
            inference_seconds=0.5,
        )

        timestamps = measured_word_timestamps(
            "Hello, world.", evidence, language="en", speed=2.0, duration=0.8
        )

        self.assertEqual(
            timestamps,
            [
                {"word": "Hello", "start_time": 0.12, "end_time": 0.36},
                {"word": "world", "start_time": 0.47, "end_time": 0.74},
            ],
        )

    def test_incomplete_word_alignment_fails_closed(self) -> None:
        evidence = SemanticASREvidence(
            transcript="Twenty six",
            words=(ASRWord("Twenty", 0.0, 0.3), ASRWord("six", 0.3, 0.6)),
            requested_words=("26",),
            similarity=0.8,
            inference_seconds=0.5,
        )

        with self.assertRaises(SemanticAudioMismatch) as captured:
            measured_word_timestamps(
                "Two separate words",
                evidence,
                language="en",
                speed=1.0,
                duration=0.7,
            )

        self.assertEqual(captured.exception.reason, "word-alignment-incomplete")

    def test_spoken_number_words_share_one_measured_request_boundary(self) -> None:
        evidence = SemanticASREvidence(
            transcript="Twenty six",
            words=(ASRWord("Twenty", 0.0, 0.3), ASRWord("six", 0.3, 0.6)),
            requested_words=("twentysix",),
            similarity=0.95,
            inference_seconds=0.5,
        )

        timestamps = measured_word_timestamps(
            "26", evidence, language="en", speed=1.0, duration=0.7
        )

        self.assertEqual(
            timestamps,
            [{"word": "26", "start_time": 0.0, "end_time": 0.6}],
        )
        metrics = validate_transcript(
            "26", "twenty six", language="en"
        )
        self.assertGreaterEqual(metrics["similarity"], 0.90)

    def test_validator_uses_final_wav_and_preserves_whisper_boundaries(self) -> None:
        class FakeRecognizer:
            def __call__(self, audio, **kwargs):
                self.audio = audio
                self.kwargs = kwargs
                return {
                    "text": " Azure cactus.",
                    "chunks": [
                        {"text": " Azure", "timestamp": (0.10, 0.52)},
                        {"text": " cactus.", "timestamp": (0.52, 1.10)},
                    ],
                }

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in REQUIRED_MODEL_FILES:
                (root / name).touch()
            validator = SemanticASRValidator(root)
            recognizer = FakeRecognizer()
            validator._pipeline = recognizer
            output = io.BytesIO()
            stereo = np.zeros((48_000, 2), dtype=np.float32)
            stereo[:, 1] = 0.001
            sf.write(
                output,
                stereo,
                48_000,
                format="WAV",
            )

            evidence = validator.validate(
                output.getvalue(),
                "Azure cactus.",
                language="en",
                reference_text=GUIDE,
            )

        self.assertEqual(len(evidence.words), 2)
        self.assertEqual(evidence.words[0].start, 0.10)
        self.assertEqual(recognizer.audio["sampling_rate"], 16_000)
        self.assertEqual(recognizer.audio["array"].shape, (16_000,))
        self.assertEqual(recognizer.kwargs["return_timestamps"], "word")

    def test_missing_pinned_checkpoint_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SemanticASRUnavailable):
                SemanticASRValidator(directory)


if __name__ == "__main__":
    unittest.main()
