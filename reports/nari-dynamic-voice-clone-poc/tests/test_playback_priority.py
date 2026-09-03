from __future__ import annotations

import base64
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import Response
import clone_worker as worker


class CaptionedPlaybackPriorityTests(unittest.TestCase):
    def test_natural_duration_over_estimate_keeps_first_candidate(self) -> None:
        with (
            patch.object(worker, "voice_prompt_metadata"),
            patch.object(worker, "nari_streamed_wav", return_value=(200, b"spoken-audio")) as generate,
            patch.object(worker, "validate_generated_wav", return_value={"duration_s": 5.5}),
            patch.object(worker, "structured_log") as log,
        ):
            result = worker.request_xvector_fallback(
                worker.SpeechRequest(text="Azure cactus.", voice_id="vc_test"),
                reason="VOICE_FAST_XVECTOR",
            )
        self.assertEqual(result, b"spoken-audio")
        self.assertEqual(generate.call_count, 1)
        warning = next(call for call in log.call_args_list if call.args[0] == "generated_audio_duration_warning")
        self.assertFalse(warning.kwargs["blocking"])

    def test_timing_failure_preserves_encoded_audio_and_voice(self) -> None:
        for error in [worker.SemanticAudioMismatch("incomplete-alignment", {}),
                      ValueError("invalid alignment values")]:
            for measured in [False, True]:
                with self.subTest(error=type(error).__name__, measured=measured), tempfile.TemporaryDirectory() as tmp:
                    voice = Path(tmp)
                    (voice / "prompt.pt").write_bytes(b"fixture")
                    scheduled = worker.ScheduledResult(
                        value=worker.ValidatedVoiceAudio(wav=b"source-wav", asr=object() if measured else None),
                        request_id="priority-test", queue_wait_s=0, run_s=0.1,
                    )
                    with (
                        patch.object(worker, "voice_dir", return_value=voice),
                        patch.object(worker, "CONTENT_COALESCER", worker.RequestCoalescer(max_entries=8, ttl_s=1)),
                        patch.object(worker, "schedule_validated_voice", return_value=scheduled),
                        patch.object(worker, "apply_speed", return_value=(b"encoded-audio", 2.0)),
                        patch.object(worker, "measured_word_timestamps", side_effect=error),
                        patch.object(worker, "estimated_timestamps", side_effect=error),
                    ):
                        result = worker.captioned_speech(
                            worker.CaptionedSpeechRequest(input="Keep reading.", voice="vc_test", language="en"),
                            Response(), x_tts_priority="interactive", x_request_id=None,
                        )
                    self.assertEqual(base64.b64decode(result["audio"]), b"encoded-audio")
                    self.assertEqual(result["voice_code"], "vc_test")
                    self.assertEqual(result["timestamps"], [])
                    self.assertEqual(set(result), {"audio", "audio_format", "voice_code", "timestamps"})


if __name__ == "__main__":
    unittest.main()
