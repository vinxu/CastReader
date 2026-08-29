from __future__ import annotations

import io
import unittest

import numpy as np
import soundfile as sf

import clone_worker


class EstimatedTimestampTests(unittest.TestCase):
    def test_generated_quality_rejection_is_explicitly_non_retryable(self) -> None:
        self.assertEqual(
            clone_worker.GENERATED_AUDIO_REJECTION_HEADERS,
            {
                "X-Voice-Retryable": "false",
                "X-Voice-Error-Code": "VOICE_GENERATED_AUDIO_REJECTED",
            },
        )

    def test_keeps_accented_latin_and_cyrillic_words(self) -> None:
        self.assertEqual(
            clone_worker.timestamp_tokens("Après déjà. После дождя."),
            ["Après", "déjà", ".", "После", "дождя", "."],
        )

    def test_keeps_chinese_as_character_level_tokens(self) -> None:
        self.assertEqual(
            clone_worker.timestamp_tokens("先观察，再行动。"),
            ["先", "观", "察", "，", "再", "行", "动", "。"],
        )

    def test_word_timestamps_exclude_punctuation(self) -> None:
        self.assertEqual(
            [match.group(0) for match in clone_worker.word_timestamp_matches("Wait, really?")],
            ["Wait", "really"],
        )

    def test_block_script_languages_return_segment_timing(self) -> None:
        for language in ("zh", "zh-Hans", "ja-JP", "ko_KR"):
            self.assertFalse(clone_worker.supports_word_timestamps(language))
            self.assertEqual(
                clone_worker.estimated_timestamps(
                    "方块字不应生成伪单词时间戳", 4.0, language=language
                ),
                [],
            )

    def test_estimate_finishes_at_audio_duration(self) -> None:
        timestamps = clone_worker.estimated_timestamps("Stable words.", 3.25)
        self.assertEqual(timestamps[-1]["end_time"], 3.25)
        self.assertTrue(
            all(
                current["end_time"] <= following["start_time"] + 1e-6
                for current, following in zip(timestamps, timestamps[1:])
            )
        )

    def test_audio_activity_excludes_edges_and_preserves_measured_pause(self) -> None:
        sample_rate = clone_worker.SAMPLE_RATE

        def tone(seconds: float, frequency: float) -> np.ndarray:
            samples = round(seconds * sample_rate)
            time = np.arange(samples, dtype=np.float32) / sample_rate
            return (0.12 * np.sin(2 * np.pi * frequency * time)).astype(np.float32)

        audio = np.concatenate(
            [
                np.zeros(round(0.30 * sample_rate), dtype=np.float32),
                tone(0.50, 190.0),
                np.zeros(round(0.25 * sample_rate), dtype=np.float32),
                tone(0.60, 220.0),
                np.zeros(round(0.30 * sample_rate), dtype=np.float32),
            ]
        )
        output = io.BytesIO()
        sf.write(output, audio, sample_rate, format="WAV", subtype="PCM_16")
        timestamps = clone_worker.estimated_timestamps(
            "Hello, world.",
            len(audio) / sample_rate,
            language="en",
            wav_bytes=output.getvalue(),
            speed=1.0,
        )

        self.assertEqual([item["word"] for item in timestamps], ["Hello", "world"])
        self.assertGreaterEqual(timestamps[0]["start_time"], 0.25)
        self.assertLessEqual(timestamps[0]["end_time"], 0.86)
        self.assertGreaterEqual(timestamps[1]["start_time"], 0.98)
        self.assertLessEqual(timestamps[1]["end_time"], 1.72)


if __name__ == "__main__":
    unittest.main()
