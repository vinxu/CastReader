from __future__ import annotations

import argparse
import importlib.util
import io
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
import wave


SCRIPT = Path(__file__).resolve().parents[1] / "deploy" / "fixed-deepfilter-smoke.py"
SPEC = importlib.util.spec_from_file_location("fixed_deepfilter_smoke", SCRIPT)
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


def metadata(voice_id):
    return {"voice_id": voice_id, "runtime_generation_mode": "x-vector",
            "reference_duration_s": 9, "prompt_build_s": 1.1,
            "adaptive_denoise": {"selected": "atten24", "deepfilter_applied": True,
                                 "selector_version": smoke.POLICY, "deepfilter_elapsed_s": 0.5,
                                 "deepfilter_passes": 1, "prompt_builds": 1, "probe_count": 0}}


def valid_wav():
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(24000)
        wav.writeframes(b"\x00\x10" * 48000)
    return buffer.getvalue()


class FixedDeepFilterSmokeTests(unittest.TestCase):
    def test_proof_rejects_bypass_false_execution_and_extra_work(self):
        for key, value in [("selected", "online"), ("deepfilter_applied", False),
                           ("deepfilter_elapsed_s", 0), ("deepfilter_elapsed_s", float("nan")),
                           ("selector_version", "adaptive"), ("deepfilter_passes", 2),
                           ("prompt_builds", 3), ("probe_count", 9)]:
            with self.subTest(key=key):
                meta = metadata("vc_test")
                meta["adaptive_denoise"][key] = value
                with self.assertRaises(AssertionError):
                    smoke.denoise_proof(meta, "vc_test")

    def test_wav_contract(self):
        self.assertEqual(smoke.wav_proof(valid_wav())["duration_s"], 2)
        with self.assertRaises((wave.Error, EOFError)):
            smoke.wav_proof(b"not audio")

    def exercise_case(self, create_status=200, speech_status=200):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "00-clean.wav").write_bytes(valid_wav())
            args = argparse.Namespace(url="http://127.0.0.1:8890", input_dir=root,
                                      voice_root=root, timeout=95)
            calls = []
            created_id = None

            def request(url, token, method, payload=None, content_type=None, **kwargs):
                nonlocal created_id
                self.assertEqual(token, "test-token")
                calls.append((method, url))
                if url.endswith("/v1/voices"):
                    created_id = re.search(rb"vc_smokedf_[0-9a-f]{32}", payload).group().decode()
                    if create_status == 200:
                        destination = root / created_id
                        destination.mkdir()
                        (destination / "metadata.json").write_text(json.dumps(metadata(created_id)))
                        (destination / "prompt.pt").write_bytes(b"test prompt")
                    return create_status, json.dumps(metadata(created_id)).encode(), {}, 1.2
                if url.endswith("/v1/speech"):
                    self.assertEqual(json.loads(payload)["voice_id"], created_id)
                    return speech_status, valid_wav(), {"X-TTS-Queue-Wait-Ms": "0"}, 1.4
                self.assertEqual(method, "DELETE")
                self.assertTrue(url.endswith("/" + created_id))
                destination = root / created_id
                if destination.exists():
                    (destination / "metadata.json").unlink()
                    (destination / "prompt.pt").unlink()
                    destination.rmdir()
                return 200, b"{}", {}, 0.1

            with patch.object(smoke, "request", request):
                result = smoke.run_case(args, "test-token", "clean")
            return result, calls

    def test_create_speech_delete_and_metadata_roundtrip(self):
        result, calls = self.exercise_case()
        self.assertTrue(result["ok"])
        self.assertTrue(result["cleanup_ok"])
        self.assertEqual([method for method, _ in calls], ["POST", "POST", "DELETE"])

    def test_failed_creation_still_cleans_own_id(self):
        result, calls = self.exercise_case(create_status=503)
        self.assertFalse(result["ok"])
        self.assertTrue(result["cleanup_ok"])
        self.assertEqual([method for method, _ in calls], ["POST", "DELETE"])

    def test_failed_speech_still_cleans_own_id(self):
        result, calls = self.exercise_case(speech_status=503)
        self.assertFalse(result["ok"])
        self.assertTrue(result["cleanup_ok"])
        self.assertEqual([method for method, _ in calls], ["POST", "POST", "DELETE"])

    def test_server_collision_is_never_deleted(self):
        result, calls = self.exercise_case(create_status=409)
        self.assertFalse(result["ok"])
        self.assertFalse(result["cleanup_ok"])
        self.assertEqual([method for method, _ in calls], ["POST"])


if __name__ == "__main__":
    unittest.main()
