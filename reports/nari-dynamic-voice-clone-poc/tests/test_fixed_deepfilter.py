from __future__ import annotations

import asyncio
import io
import os
import tempfile
import unittest
from contextlib import ExitStack, contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np
import torch
from fastapi import HTTPException, UploadFile

import clone_worker


class FixedDeepFilterTests(unittest.TestCase):
    @staticmethod
    def _reference(**metrics):
        return clone_worker.ReferenceAudioResult(
            audio=np.full(4 * clone_worker.SAMPLE_RATE, 0.1, dtype=np.float32),
            sample_rate=clone_worker.SAMPLE_RATE,
            duration_seconds=4.0,
            metrics={"speech_duration_s": 4.0, "min_speaker_similarity": 0.9, **metrics},
            warnings=[],
        )

    @contextmanager
    def _harness(self, root: Path, *, baseline=None, candidate=None):
        baseline = baseline or self._reference()
        candidate = candidate or self._reference()
        candidate.audio[:] = 0.2
        enhanced = np.full(4 * 48_000, 0.3, dtype=np.float32)

        def save(reference_audio, _text, output, **_kwargs):
            audio, rate = clone_worker.sf.read(reference_audio, dtype="float32")
            self.assertEqual(rate, clone_worker.SAMPLE_RATE)
            np.testing.assert_allclose(audio, candidate.audio, atol=1 / 32768)
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

        builder = SimpleNamespace(save=Mock(side_effect=save))

        def schedule(execute, **_kwargs):
            return clone_worker.ScheduledResult(execute(), "fixed-denoise-test", 0, 0.01)

        with ExitStack() as stack:
            for name, value in (
                ("VOICE_ROOT", root),
                ("NARI_CLIENT", Mock()),
            ):
                stack.enter_context(patch.object(clone_worker, name, value))
            stack.enter_context(patch.object(clone_worker, "xvector_writer_enabled", return_value=True))
            stack.enter_context(patch.object(clone_worker, "decode_reference", return_value=(baseline.audio, baseline.sample_rate)))
            stack.enter_context(patch.object(clone_worker, "prepare_decoded_reference", return_value=baseline))
            quality = stack.enter_context(patch.object(clone_worker, "process_reference_audio", return_value=candidate))
            enhance = stack.enter_context(patch.object(clone_worker.DEEPFILTER_RUNNER, "enhance", return_value=(enhanced, 48_000, 0.125)))
            stack.enter_context(patch.object(clone_worker.DEEPFILTER_RUNNER, "status", return_value={"ready": True, "version": "0.5.6", "sha256": "test-hash"}))
            diarization = stack.enter_context(patch.object(clone_worker.SPEAKER_DIARIZER, "inspect", return_value=SimpleNamespace(as_metrics=lambda: {"competing_speech": False, "speaker_count": 1})))
            stack.enter_context(patch.object(clone_worker, "prompt_builder", return_value=builder))
            scheduled = stack.enter_context(patch.object(clone_worker, "schedule", side_effect=schedule))
            yield SimpleNamespace(
                baseline=baseline,
                candidate=candidate,
                enhanced=enhanced,
                enhance=enhance,
                quality=quality,
                builder=builder,
                scheduled=scheduled,
                diarization=diarization,
                nari=clone_worker.NARI_CLIENT,
            )

    @staticmethod
    def _create(voice_id="vc_fixed_test"):
        return asyncio.run(
            clone_worker.create_voice(
                reference=UploadFile(file=io.BytesIO(b"reference"), filename="reference.wav"),
                consent_confirmed=True,
                requested_voice_id=voice_id,
                reference_text="Natural speech is sufficient.",
                reference_language="en",
                x_request_id="fixed-denoise-test",
            )
        )

    def test_clean_mechanical_and_noisy_recordings_always_use_one_atten24_pass(self):
        cases = (
            ("off", {"snr_db": 25.0, "noise_estimate_reliable": True, "broadband_flatness": 0.03}),
            ("shadow", {"snr_db": 12.0, "noise_estimate_reliable": True, "broadband_flatness": 0.03}),
            ("canary", {"snr_db": None, "noise_estimate_reliable": False, "broadband_flatness": 0.2}),
        )
        for legacy_mode, metrics in cases:
            with self.subTest(legacy_mode=legacy_mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                obsolete_mode_file = root / ".adaptive-denoise-mode"
                obsolete_mode_file.write_text(legacy_mode, encoding="utf-8")
                with (
                    patch.dict(os.environ, {"CLONE_DENOISE_MODE": legacy_mode, "CLONE_DENOISE_MODE_FILE": str(obsolete_mode_file), "CLONE_DENOISE_CANARY_PERCENT": "0"}),
                    self._harness(root, baseline=self._reference(**metrics)) as harness,
                ):
                    result = self._create()

                harness.enhance.assert_called_once()
                self.assertIs(harness.enhance.call_args.args[0], harness.baseline.audio)
                self.assertEqual(harness.enhance.call_args.kwargs["attenuation_db"], 24)
                harness.quality.assert_called_once()
                self.assertIs(harness.quality.call_args.args[0], harness.enhanced)
                harness.builder.save.assert_called_once()
                harness.diarization.assert_called_once()
                harness.scheduled.assert_called_once()
                self.assertEqual(harness.scheduled.call_args.kwargs["kind"], "voice-denoise-prompt-build")
                self.assertEqual(harness.nari.mock_calls, [])
                denoise = result["adaptive_denoise"]
                self.assertEqual(denoise["selected"], "atten24")
                self.assertEqual(denoise["pipeline_version"], "fixed-deepfilter-atten24-v1")
                self.assertTrue(denoise["deepfilter_applied"])
                self.assertGreater(denoise["deepfilter_elapsed_s"], 0)
                self.assertEqual(denoise["deepfilter_passes"], 1)
                self.assertEqual(denoise["prompt_builds"], 1)
                self.assertEqual(denoise["probe_count"], 0)
                self.assertFalse(denoise["raw_fallback"])
                self.assertEqual(denoise["mode_source"], "fixed-policy")
                self.assertEqual({path.name for path in (root / "vc_fixed_test").iterdir()}, {"prompt.pt", "metadata.json"})
                self.assertEqual(tuple(root.glob(".*.building")), ())

    def test_deepfilter_missing_or_failed_never_builds_or_publishes_a_raw_prompt(self):
        for failure in (
            clone_worker.AdaptiveDenoiseError("unavailable"),
            RuntimeError("invalid enhanced output"),
            OSError("binary could not start"),
        ):
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self._harness(root) as harness:
                    harness.enhance.side_effect = failure
                    with self.assertRaises(HTTPException) as captured:
                        self._create()
                self.assertEqual(captured.exception.status_code, 503)
                self.assertEqual(captured.exception.detail["code"], "VOICE_DENOISE_UNAVAILABLE")
                self.assertEqual(captured.exception.headers["X-Voice-Retryable"], "true")
                harness.builder.save.assert_not_called()
                harness.scheduled.assert_not_called()
                self.assertEqual(tuple(root.iterdir()), ())

    def test_actual_missing_deepfilter_binary_fails_before_prompt_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            missing = clone_worker.DeepFilterRunner(root / "missing-deep-filter", "0" * 64)
            with self._harness(root) as harness, patch.object(clone_worker, "DEEPFILTER_RUNNER", missing):
                with self.assertRaises(HTTPException) as captured:
                    self._create()
            self.assertEqual(captured.exception.detail["code"], "VOICE_DENOISE_UNAVAILABLE")
            harness.builder.save.assert_not_called()
            self.assertEqual(tuple(root.iterdir()), ())

    def test_candidate_quality_or_relative_identity_failure_is_nonretryable_without_fallback(self):
        for failure in ("quality", "identity"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self._harness(root, candidate=self._reference(min_speaker_similarity=0.7)) as harness:
                    if failure == "quality":
                        harness.quality.side_effect = clone_worker.ReferenceQualityError("VOICE_REFERENCE_NO_SPEECH", "No speech", {"speech_duration_s": 0.0})
                    with self.assertRaises(HTTPException) as captured:
                        self._create()
                self.assertEqual(captured.exception.status_code, 422)
                code = (
                    "VOICE_REFERENCE_NO_SPEECH"
                    if failure == "quality"
                    else "VOICE_REFERENCE_DENOISE_REJECTED"
                )
                self.assertEqual(captured.exception.detail["code"], code)
                self.assertEqual(captured.exception.headers["X-Voice-Retryable"], "false")
                self.assertEqual(captured.exception.headers["X-Voice-Error-Code"], code)
                if failure == "quality":
                    self.assertEqual(captured.exception.detail["message"], "No speech")
                    self.assertEqual(captured.exception.detail["metrics"], {"speech_duration_s": 0.0})
                else:
                    self.assertIn("quieter", captured.exception.detail["message"])
                    self.assertFalse(captured.exception.detail["metrics"]["passed"])
                harness.enhance.assert_called_once()
                harness.builder.save.assert_not_called()
                self.assertEqual(tuple(root.iterdir()), ())

    def test_short_recording_without_comparable_speaker_windows_still_creates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self._harness(root, baseline=self._reference(min_speaker_similarity=None), candidate=self._reference(min_speaker_similarity=None)) as harness:
                result = self._create()
            guard = result["adaptive_denoise"]["reference_speaker_guard"]
            self.assertFalse(guard["comparable"])
            self.assertIsNone(guard["passed"])
            harness.enhance.assert_called_once()
            harness.builder.save.assert_called_once()

    def test_competing_speech_is_rejected_before_deepfilter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self._harness(root) as harness:
                harness.diarization.return_value = SimpleNamespace(as_metrics=lambda: {"competing_speech": True, "speaker_count": 2})
                with self.assertRaises(HTTPException) as captured:
                    self._create()
            self.assertEqual(captured.exception.status_code, 422)
            self.assertEqual(captured.exception.detail["code"], "VOICE_REFERENCE_MULTIPLE_SPEAKERS")
            harness.enhance.assert_not_called()
            harness.builder.save.assert_not_called()
            self.assertEqual(tuple(root.iterdir()), ())

    def test_cancellation_during_deepfilter_never_builds_or_publishes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self._harness(root) as harness:
                def cancel(*_args, **kwargs):
                    kwargs["cancelled"].set()
                    return harness.enhanced, 48_000, 0.1
                harness.enhance.side_effect = cancel
                with self.assertRaises(HTTPException):
                    self._create()
            harness.builder.save.assert_not_called()
            self.assertEqual(tuple(root.iterdir()), ())

    def test_health_reports_fixed_policy_and_tracks_prescheduler_voice_tasks(self):
        response = SimpleNamespace(status_code=200, json=lambda: {"ready": True})
        event = clone_worker.register_voice_build("vc_health_active")
        try:
            with (
                patch.object(clone_worker.httpx, "get", return_value=response),
                patch.object(clone_worker, "xvector_writer_enabled", return_value=True),
                patch.object(clone_worker.DEEPFILTER_RUNNER, "status", return_value={"ready": True}),
                patch.object(clone_worker.SPEAKER_DIARIZER, "model_status", return_value={"ready": True}),
            ):
                ready = clone_worker.health()
                with patch.object(clone_worker.DEEPFILTER_RUNNER, "status", return_value={"ready": False}):
                    missing = clone_worker.health()
            self.assertGreaterEqual(ready["active_voice_tasks"], 1)
            self.assertTrue(ready["voice_creation_enabled"])
            self.assertEqual(ready["adaptive_denoise"]["pipeline_version"], "fixed-deepfilter-atten24-v1")
            self.assertFalse(missing["voice_creation_enabled"])
            self.assertFalse(missing["voice_creation_dependencies_ready"])
            self.assertEqual(missing["status"], "healthy")
            self.assertTrue(missing["nari_ready"])
        finally:
            clone_worker.unregister_voice_build("vc_health_active", event)

    def test_denoise_warmup_failure_does_not_take_existing_voice_service_down(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(clone_worker, "VOICE_ROOT", Path(directory)),
            patch.object(clone_worker, "CLONE_WARMUP", False),
            patch.object(clone_worker, "ASR_WARMUP", False),
            patch.object(clone_worker, "DENOISE_WARMUP", True),
            patch.object(clone_worker.DEEPFILTER_RUNNER, "status", return_value={"ready": False}),
        ):
            clone_worker.prepare_storage()


if __name__ == "__main__":
    unittest.main()
