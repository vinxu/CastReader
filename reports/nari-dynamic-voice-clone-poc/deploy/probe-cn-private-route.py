from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, choices=[18890, 18893], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    process = subprocess.check_output(["systemctl", "show", "castreader.service", "-p", "MainPID", "--value"], text=True).strip()
    environment = dict(entry.split("=", 1) for entry in Path(f"/proc/{process}/environ").read_text().split("\0") if "=" in entry)
    assert environment["CASTREADER_SERVICE_ROUTE"] == "cn"
    assert environment["VOICE_CLONE_WORKER_URL"] == "http://127.0.0.1:18890"
    token = environment["VOICE_CLONE_WORKER_TOKEN"]
    prefix = f"http://127.0.0.1:{args.port}"
    results = []

    def request(path, *, method="GET", body=None, authenticated=True):
        headers = {"Content-Type": "application/json", "X-Request-ID": "cn-align-probe-" + uuid.uuid4().hex}
        if authenticated:
            headers["X-Clone-Token"] = token
        request = urllib.request.Request(prefix + path, data=json.dumps(body).encode() if body is not None else None,
                                         method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers), error.read()

    status, headers, raw = request("/health")
    health = json.loads(raw)
    assert status == 200 and health["status"] == "healthy"
    results.append({"case": "original-worker-health", "status": status})
    payload = {"input": "You can follow each word as it is spoken. The little train stopped beside the river. Nobody knew what would happen next.",
               "voice": "vc_e2e_generated_test", "language": "en", "speed": 1,
               "return_timestamps": True, "response_format": "mp3", "stream": False}
    for path, method, body in [("/v1/captioned-speech", "POST", payload),
                               ("/v1/voices/vc_e2e_generated_test/prompt", "GET", None),
                               ("/v1/voices/vc_alignment_nonexistent_probe", "DELETE", None)]:
        status, headers, raw = request(path, method=method, body=body, authenticated=False)
        assert status == 401, (path, status)
        results.append({"case": "auth-enforced:" + path, "status": status})
    status, headers, raw = request("/v1/voices/vc_e2e_generated_test/prompt")
    assert status == 200 and raw
    results.append({"case": "original-voice-prompt-read", "status": status,
                    "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
    started = time.perf_counter()
    status, headers, raw = request("/v1/captioned-speech", method="POST", body=payload)
    assert status == 200, status
    lowered = {key.lower(): value for key, value in headers.items()}
    assert lowered["x-voice-alignment-revision"] == "qwen-pcm-measured-groups-v3"
    assert lowered["x-voice-alignment-mode"] in {"qwen-word", "qwen-word-groups"}
    result = json.loads(raw)
    assert set(result) == {"audio", "audio_format", "timestamps", "voice_code"}
    assert result["voice_code"] == payload["voice"]
    assert len(base64.b64decode(result["audio"], validate=True)) > 1000
    assert result["timestamps"]
    previous = 0
    for stamp in result["timestamps"]:
        assert previous <= stamp["start_time"] < stamp["end_time"]
        previous = stamp["end_time"]
    results.append({"case": "new-caption-pipeline", "status": status,
                    "revision": lowered["x-voice-alignment-revision"],
                    "mode": lowered["x-voice-alignment-mode"], "timestamps": len(result["timestamps"]),
                    "request_id": lowered.get("x-tts-request-id"),
                    "elapsed_ms": (time.perf_counter() - started) * 1000})
    args.output.write_text(json.dumps({"port": args.port, "checks": results}, indent=2) + "\n")
    print(json.dumps({"port": args.port, "checks": results}))


if __name__ == "__main__":
    main()
