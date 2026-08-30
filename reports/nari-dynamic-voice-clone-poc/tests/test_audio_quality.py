from __future__ import annotations

import io
import unittest

import numpy as np
import soundfile as sf
import torch

import clone_worker


class GeneratedAudioQualityTests(unittest.TestCase):
    @staticmethod
    def wav_bytes(audio: np.ndarray) -> bytes:
        output = io.BytesIO()
        sf.write(output, audio, clone_worker.SAMPLE_RATE, format="WAV", subtype="PCM_16")
        return output.getvalue()

    def test_accepts_clean_speech_shaped_signal(self) -> None:
        seconds = 2.0
        samples = int(clone_worker.SAMPLE_RATE * seconds)
        time = np.arange(samples, dtype=np.float64) / clone_worker.SAMPLE_RATE
        envelope = 0.45 + 0.35 * np.sin(2 * np.pi * 3.2 * time) ** 2
        audio = envelope * (
            0.28 * np.sin(2 * np.pi * 180 * time)
            + 0.12 * np.sin(2 * np.pi * 360 * time)
            + 0.05 * np.sin(2 * np.pi * 720 * time)
        )
        metrics = clone_worker.validate_generated_wav(
            self.wav_bytes(audio.astype(np.float32))
        )
        self.assertGreater(metrics["duration_s"], 1.9)
        self.assertLess(metrics["high_frequency_ratio"], 0.1)

    def test_rejects_obvious_electronic_noise(self) -> None:
        rng = np.random.default_rng(20260826)
        noise = rng.normal(
            0,
            0.2,
            size=clone_worker.SAMPLE_RATE * 2,
        ).astype(np.float32)
        with self.assertRaises(clone_worker.GeneratedAudioQualityError):
            clone_worker.validate_generated_wav(self.wav_bytes(noise))

    def test_accepts_brief_noise_inside_clean_speech(self) -> None:
        rng = np.random.default_rng(20260826)
        samples = clone_worker.SAMPLE_RATE * 2
        time = np.arange(samples, dtype=np.float64) / clone_worker.SAMPLE_RATE
        audio = 0.25 * np.sin(2 * np.pi * 190 * time)
        # A short consonant/breath-like broadband interval must not make the
        # whole utterance fail the median-based quality gate.
        burst_start = clone_worker.SAMPLE_RATE // 2
        burst_end = burst_start + clone_worker.SAMPLE_RATE // 20
        audio[burst_start:burst_end] += rng.normal(
            0, 0.08, size=burst_end - burst_start
        )
        metrics = clone_worker.validate_generated_wav(
            self.wav_bytes(audio.astype(np.float32))
        )
        self.assertLess(metrics["spectral_flatness"], 0.5)

    def test_rejects_heavily_clipped_audio(self) -> None:
        time = np.arange(clone_worker.SAMPLE_RATE * 2) / clone_worker.SAMPLE_RATE
        clipped = np.sign(np.sin(2 * np.pi * 220 * time)).astype(np.float32)
        with self.assertRaises(clone_worker.GeneratedAudioQualityError):
            clone_worker.validate_generated_wav(self.wav_bytes(clipped))

    def test_rejects_persistent_high_frequency_tone(self) -> None:
        time = np.arange(clone_worker.SAMPLE_RATE * 2) / clone_worker.SAMPLE_RATE
        electronic_tone = (0.2 * np.sin(2 * np.pi * 9_000 * time)).astype(
            np.float32
        )
        with self.assertRaises(clone_worker.GeneratedAudioQualityError):
            clone_worker.validate_generated_wav(self.wav_bytes(electronic_tone))

    def test_request_payload_keeps_full_audio_non_streaming_contract(self) -> None:
        request = clone_worker.SpeechRequest(
            text="  A clean paragraph.  ",
            voice_id="vc_test",
            language_id="en",
            seed=17,
        )

        payload = clone_worker.nari_request_payload(
            request,
            language="english",
            seed=23,
        )

        self.assertEqual(payload["input"], "A clean paragraph.")
        self.assertNotIn("stream_chunk_schedule", payload)
        self.assertFalse(payload["defer_codec_until_terminal"])
        self.assertFalse(payload["stream"])
        self.assertTrue(payload["non_streaming_mode"])
        self.assertEqual(payload["voice_clone_mode"], "icl")
        self.assertLess(payload["max_new_tokens"], 4096)

        xvector = clone_worker.nari_request_payload(
            request,
            language="english",
            seed=23,
            voice_clone_mode="x_vector",
        )
        self.assertEqual(xvector["voice_clone_mode"], "x_vector")

    def test_generation_cap_scales_with_requested_text(self) -> None:
        short = clone_worker.maximum_generation_frames("今天我们继续学习。")
        medium = clone_worker.maximum_generation_frames("这是一个更长的段落。" * 20)

        self.assertGreaterEqual(short, 64)
        self.assertGreater(medium, short)
        self.assertLess(medium, 4096)

    def test_v2_prompt_stays_immutable_when_runtime_is_xvector_only(self) -> None:
        prompt = {
            "schema": "qwen3_tts_base_voice_clone_prompt_v2",
            "ref_text": "Reference text.",
            "ref_spk_embedding": torch.zeros(8, dtype=torch.float32),
            "reference_codec_embeddings": torch.zeros(3, 8, dtype=torch.bfloat16),
        }
        raw = io.BytesIO()
        torch.save(prompt, raw)
        compiled, schema = clone_worker.upgrade_prompt_bytes(raw.getvalue())

        upgraded = torch.load(io.BytesIO(compiled), map_location="cpu", weights_only=True)
        self.assertEqual(schema, "qwen3_tts_base_voice_clone_prompt_v2")
        self.assertEqual(compiled, raw.getvalue())
        self.assertNotIn("decoder_bootstrap_code", upgraded)

    def test_v4_prompt_preserves_full_reference_decoder_context(self) -> None:
        prompt = {
            "schema": "qwen3_tts_base_voice_clone_prompt_v4",
            "ref_text": "Reference text.",
            "ref_spk_embedding": torch.zeros(8, dtype=torch.float32),
            "reference_codec_embeddings": torch.zeros(3, 8, dtype=torch.bfloat16),
            "decoder_reference_code": torch.zeros((71, 16), dtype=torch.long),
        }
        raw = io.BytesIO()
        torch.save(prompt, raw)

        compiled, schema = clone_worker.upgrade_prompt_bytes(raw.getvalue())

        self.assertEqual(schema, "qwen3_tts_base_voice_clone_prompt_v4")
        self.assertEqual(compiled, raw.getvalue())

    def test_v4_prompt_rejects_conflicting_silence_bootstrap(self) -> None:
        prompt = {
            "schema": "qwen3_tts_base_voice_clone_prompt_v4",
            "ref_text": "Reference text.",
            "ref_spk_embedding": torch.zeros(8, dtype=torch.float32),
            "reference_codec_embeddings": torch.zeros(3, 8, dtype=torch.bfloat16),
            "decoder_reference_code": torch.zeros((71, 16), dtype=torch.long),
            "decoder_bootstrap_code": torch.zeros((4, 16), dtype=torch.long),
        }
        raw = io.BytesIO()
        torch.save(prompt, raw)

        with self.assertRaises(clone_worker.HTTPException):
            clone_worker.validate_prompt_bytes(raw.getvalue())

    def test_rejects_electronic_noise_limited_to_first_words(self) -> None:
        rng = np.random.default_rng(20260826)
        samples = clone_worker.SAMPLE_RATE * 4
        time = np.arange(samples, dtype=np.float64) / clone_worker.SAMPLE_RATE
        audio = (
            0.24 * np.sin(2 * np.pi * 145 * time)
            + 0.08 * np.sin(2 * np.pi * 290 * time)
        )
        prefix_samples = round(0.9 * clone_worker.SAMPLE_RATE)
        audio[:prefix_samples] = rng.normal(0, 0.16, prefix_samples)

        with self.assertRaises(clone_worker.GeneratedAudioQualityError) as captured:
            clone_worker.validate_generated_wav(
                self.wav_bytes(audio.astype(np.float32))
            )

        self.assertEqual(str(captured.exception), "electronic-prefix-spectrum")
        self.assertGreater(
            captured.exception.metrics["prefix_spectral_flatness_p75"],
            0.10,
        )

    def test_rejects_large_prefix_pitch_excursion(self) -> None:
        seconds = 5.0
        samples = round(seconds * clone_worker.SAMPLE_RATE)
        time = np.arange(samples, dtype=np.float64) / clone_worker.SAMPLE_RATE
        frequency = np.where(time < 2.2, 320.0, 125.0)
        phase = 2 * np.pi * np.cumsum(frequency) / clone_worker.SAMPLE_RATE
        audio = 0.22 * np.sin(phase) + 0.08 * np.sin(2 * phase)

        with self.assertRaises(clone_worker.GeneratedAudioQualityError) as captured:
            clone_worker.validate_generated_wav(
                self.wav_bytes(audio.astype(np.float32))
            )

        self.assertEqual(str(captured.exception), "unstable-prefix-pitch")
        self.assertGreater(
            captured.exception.metrics["prefix_body_pitch_ratio"],
            1.45,
        )

    def test_accepts_modest_sentence_initial_pitch_lift(self) -> None:
        seconds = 5.0
        samples = round(seconds * clone_worker.SAMPLE_RATE)
        time = np.arange(samples, dtype=np.float64) / clone_worker.SAMPLE_RATE
        frequency = np.where(time < 0.9, 180.0, 140.0)
        phase = 2 * np.pi * np.cumsum(frequency) / clone_worker.SAMPLE_RATE
        audio = 0.22 * np.sin(phase) + 0.08 * np.sin(2 * phase)

        metrics = clone_worker.validate_generated_wav(
            self.wav_bytes(audio.astype(np.float32))
        )

        self.assertLess(metrics["prefix_body_pitch_ratio"], 1.45)


if __name__ == "__main__":
    unittest.main()
