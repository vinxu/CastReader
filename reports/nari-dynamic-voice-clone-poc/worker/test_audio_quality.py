import unittest

import numpy as np

from audio_quality import (
    ReferenceQualityConfig,
    ReferenceQualityError,
    _is_severe_reverb,
    _reverb_tail_db,
    process_reference_audio,
)


SAMPLE_RATE = 24_000


def speech_like(seconds: float, amplitude: float = 0.12) -> np.ndarray:
    count = round(seconds * SAMPLE_RATE)
    time = np.arange(count, dtype=np.float32) / SAMPLE_RATE
    carrier = (
        np.sin(2 * np.pi * 137 * time)
        + 0.45 * np.sin(2 * np.pi * 274 * time)
        + 0.22 * np.sin(2 * np.pi * 548 * time)
        + 0.10 * np.sin(2 * np.pi * 1_420 * time)
    )
    syllables = 0.18 + 0.82 * np.square(np.sin(2 * np.pi * 2.7 * time))
    return (amplitude * carrier * syllables).astype(np.float32)


def guided_recording(
    speech_seconds: float = 6.0,
    lead_seconds: float = 0.8,
    tail_seconds: float = 0.9,
    noise_amplitude: float = 0.0007,
) -> np.ndarray:
    rng = np.random.default_rng(20260826)
    audio = np.concatenate(
        [
            np.zeros(round(lead_seconds * SAMPLE_RATE), dtype=np.float32),
            speech_like(speech_seconds),
            np.zeros(round(tail_seconds * SAMPLE_RATE), dtype=np.float32),
        ]
    )
    return audio + rng.normal(0, noise_amplitude, len(audio)).astype(np.float32)


class NoSpeakerModel:
    def inspect(self, audio, speech_mask, sample_rate):
        return None, 0, "unavailable"


class MultipleSpeakerModel:
    def inspect(self, audio, speech_mask, sample_rate):
        return 0.20, 3, "test"


class ReferenceAudioQualityTests(unittest.TestCase):
    def test_clean_guided_recording_is_trimmed_and_normalized(self):
        result = process_reference_audio(
            guided_recording(),
            SAMPLE_RATE,
            vad_backend="energy",
            speaker_inspector=NoSpeakerModel(),
        )

        self.assertEqual(result.sample_rate, SAMPLE_RATE)
        self.assertLess(result.duration_seconds, 7.0)
        self.assertGreater(result.duration_seconds, 5.5)
        self.assertGreater(result.metrics["snr_db"], 20)
        self.assertLessEqual(result.metrics["processed_peak_dbfs"], -0.95)
        self.assertIn("speaker_consistency_check_unavailable", result.warnings)

    def test_push_to_record_release_gets_full_settling_tail(self):
        audio = np.concatenate(
            [
                np.zeros(round(0.8 * SAMPLE_RATE), dtype=np.float32),
                speech_like(5.0),
            ]
        )

        result = process_reference_audio(
            audio,
            SAMPLE_RATE,
            vad_backend="energy",
            speaker_inspector=NoSpeakerModel(),
        )

        self.assertGreaterEqual(
            result.metrics["synthetic_tail_padding_ms"],
            150.0,
        )
        self.assertAlmostEqual(
            result.metrics["trim_end_s"]
            - result.metrics["last_speech_end_s"],
            0.20,
            places=2,
        )
        tail = result.audio[-round(0.15 * SAMPLE_RATE) :]
        self.assertLess(float(np.max(np.abs(tail))), 1e-6)

    def test_clean_continuous_speech_without_noise_floor_evidence_is_accepted(self):
        # Some languages and speaking styles fill almost the entire push-to-
        # record window. Quiet speech frames must not be relabelled as noise.
        audio = speech_like(6.0)

        result = process_reference_audio(
            audio,
            SAMPLE_RATE,
            vad_backend="energy",
            speaker_inspector=NoSpeakerModel(),
        )

        self.assertFalse(result.metrics["noise_estimate_reliable"])
        self.assertIsNone(result.metrics["snr_db"])
        self.assertLess(result.metrics["broadband_flatness"], 0.70)

    def test_continuous_broadband_noise_is_rejected_without_silence_evidence(self):
        rng = np.random.default_rng(20260827)
        audio = speech_like(6.0, amplitude=0.08)
        audio += rng.normal(0, 0.06, len(audio)).astype(np.float32)

        with self.assertRaises(ReferenceQualityError) as captured:
            process_reference_audio(
                audio,
                SAMPLE_RATE,
                vad_backend="energy",
                speaker_inspector=NoSpeakerModel(),
            )

        self.assertEqual(captured.exception.code, "VOICE_REFERENCE_TOO_NOISY")
        self.assertFalse(captured.exception.metrics["noise_estimate_reliable"])
        self.assertGreaterEqual(
            captured.exception.metrics["broadband_flatness"],
            0.70,
        )

    def test_silence_is_rejected_before_gpu_work(self):
        with self.assertRaises(ReferenceQualityError) as captured:
            process_reference_audio(
                np.zeros(6 * SAMPLE_RATE, dtype=np.float32),
                SAMPLE_RATE,
                vad_backend="energy",
                speaker_inspector=NoSpeakerModel(),
            )

        self.assertEqual(captured.exception.code, "VOICE_REFERENCE_NO_SPEECH")

    def test_short_spoken_content_is_rejected(self):
        with self.assertRaises(ReferenceQualityError) as captured:
            process_reference_audio(
                guided_recording(speech_seconds=1.0, lead_seconds=1.0, tail_seconds=3.0),
                SAMPLE_RATE,
                vad_backend="energy",
                speaker_inspector=NoSpeakerModel(),
            )

        self.assertEqual(captured.exception.code, "VOICE_REFERENCE_SPEECH_TOO_SHORT")

    def test_clipped_recording_is_rejected(self):
        audio = guided_recording(noise_amplitude=0)
        audio = np.clip(audio * 20, -1, 1)
        with self.assertRaises(ReferenceQualityError) as captured:
            process_reference_audio(
                audio,
                SAMPLE_RATE,
                vad_backend="energy",
                speaker_inspector=NoSpeakerModel(),
            )

        self.assertEqual(captured.exception.code, "VOICE_REFERENCE_CLIPPING")

    def test_multiple_speaker_signal_is_rejected_when_embedding_gate_confirms_it(self):
        with self.assertRaises(ReferenceQualityError) as captured:
            process_reference_audio(
                guided_recording(),
                SAMPLE_RATE,
                vad_backend="energy",
                speaker_inspector=MultipleSpeakerModel(),
            )

        self.assertEqual(
            captured.exception.code,
            "VOICE_REFERENCE_MULTIPLE_SPEAKERS",
        )

    def test_reverb_tail_metric_detects_long_energy_decay(self):
        audio = np.zeros(5 * SAMPLE_RATE, dtype=np.float32)
        speech = speech_like(1.0)
        first_begin = SAMPLE_RATE
        first_end = first_begin + len(speech)
        second_begin = 3 * SAMPLE_RATE
        second_end = second_begin + len(speech)
        audio[first_begin:first_end] = speech
        audio[second_begin:second_end] = speech
        decay = np.exp(-np.arange(round(0.35 * SAMPLE_RATE)) / (0.22 * SAMPLE_RATE))
        tail = 0.06 * decay * np.sin(2 * np.pi * 137 * np.arange(len(decay)) / SAMPLE_RATE)
        audio[first_end:first_end + len(tail)] += tail.astype(np.float32)
        audio[second_end:second_end + len(tail)] += tail.astype(np.float32)

        tail_db, count = _reverb_tail_db(
            audio,
            [(first_begin, first_end), (second_begin, second_end)],
            SAMPLE_RATE,
        )

        self.assertEqual(count, 2)
        self.assertIsNotNone(tail_db)
        self.assertGreater(tail_db, -20)

    def test_single_sentence_tail_never_hard_rejects_for_reverb(self):
        config = ReferenceQualityConfig()

        self.assertFalse(_is_severe_reverb(-1.0, 1, config))
        self.assertFalse(_is_severe_reverb(-6.0, 3, config))
        self.assertTrue(_is_severe_reverb(-3.0, 2, config))


if __name__ == "__main__":
    unittest.main()
