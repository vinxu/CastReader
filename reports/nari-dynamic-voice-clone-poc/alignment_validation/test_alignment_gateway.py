import io
from pathlib import Path
import tempfile
import unittest

from fastapi.testclient import TestClient
import numpy as np
import soundfile as sf

from alignment_gateway import AlignmentGateway, CaptionRequest, build_app
from caption_pipeline import CaptionResult


class FakePipeline:
    reason = "qwen-word"
    closed = False

    def close(self):
        self.closed = True

    def caption(self, pcm, **kwargs):
        return CaptionResult({"audio": "fixture", "audio_format": "audio/mpeg",
                              "voice_code": kwargs["voice_code"],
                              "timestamps": [{"word": "Hello", "start_time": .1, "end_time": .3}]
                              if self.reason in {"qwen-word", "qwen-word-groups"} else []},
                             pcm.duration, self.reason, {})


class AlignmentGatewayTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.voices = Path(self.directory.name)
        (self.voices / "vc_test").mkdir()
        (self.voices / "vc_test/prompt.pt").touch()
        self.calls = 0
        stream = io.BytesIO()
        sf.write(stream, np.zeros(24000), 24000, format="WAV")
        self.wav = stream.getvalue()
        self.pipeline = FakePipeline()

        def synthesize(request, request_id, priority):
            self.calls += 1
            return self.wav, {"x-tts-run-ms": "10", "x-untrusted": "drop"}

        self.gateway = AlignmentGateway(pipeline=self.pipeline, voices=self.voices, synthesize=synthesize)
        self.client = TestClient(build_app(self.gateway, "test-token-not-a-real-secret"))

    def request(self, identity="one", **changes):
        return self.client.post("/v1/captioned-speech",
                                json={"input": "Hello", "voice": "vc_test", **changes},
                                headers={"X-Clone-Token": "test-token-not-a-real-secret",
                                         "X-Request-ID": identity})

    def test_four_fields_and_pcm_duration_not_final_word_end(self):
        result = self.request()
        self.assertEqual(result.status_code, 200)
        self.assertEqual(set(result.json()), {"audio", "audio_format", "voice_code", "timestamps"})
        self.assertEqual(result.headers["X-Voice-Audio-Duration-Ms"], "1008")
        self.assertNotIn("x-untrusted", result.headers)

    def test_request_and_content_retries_generate_once(self):
        for identity in ["one", "one", "two"]:
            self.assertEqual(self.request(identity).status_code, 200)
        self.assertEqual(self.calls, 1)

    def test_alignment_failure_keeps_audio_without_estimates_and_is_cached(self):
        self.pipeline.reason = "invalid-word-interval"
        for identity in ["one", "one", "two"]:
            result = self.request(identity)
            self.assertEqual(result.status_code, 200)
            self.assertEqual(result.headers["X-Voice-Alignment-Mode"], "invalid-word-interval")
            self.assertEqual(result.json()["timestamps"], [])
            self.assertEqual(result.json()["audio"], "fixture")
        self.assertEqual(self.calls, 1)

    def test_measured_groups_are_labeled_separately(self):
        self.pipeline.reason = "qwen-word-groups"
        result = self.request()
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.headers["X-Voice-Alignment-Mode"], "qwen-word-groups")

    def test_shutdown_closes_alignment_executor(self):
        with TestClient(build_app(self.gateway, "test-token-not-a-real-secret")) as client:
            self.assertEqual(client.get("/health").status_code, 200)
        self.assertTrue(self.pipeline.closed)

    def test_same_request_id_different_input_rejected(self):
        self.request()
        self.assertEqual(self.request(input="Goodbye").status_code, 409)
        self.assertEqual(self.calls, 1)

    def test_prompt_revision_invalidates_cache(self):
        self.request("one")
        (self.voices / "vc_test/prompt.pt").write_text("new")
        self.assertEqual(self.request("two").status_code, 200)
        self.assertEqual(self.calls, 2)

    def test_authorization_and_voice_path(self):
        result = self.client.post("/v1/captioned-speech", json={"input": "Hello", "voice": "vc_test"})
        self.assertEqual(result.status_code, 401)
        self.assertEqual(self.request(voice="../vc_test").status_code, 422)
        self.assertEqual(self.calls, 0)

    def test_invalid_options_never_synthesize(self):
        for changes in [{"speed": 0}, {"speed": 3}, {"stream": True}, {"input": "  "},
                        {"language": "unsupported"}, {"voice": "vc_missing"}]:
            self.assertIn(self.request(**changes).status_code, {404, 422})
        self.assertEqual(self.calls, 0)


if __name__ == "__main__":
    unittest.main()
