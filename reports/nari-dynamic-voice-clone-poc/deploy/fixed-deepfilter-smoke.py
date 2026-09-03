#!/usr/bin/env python3
"""Create/synthesize/delete test-owned voices on a loopback clone worker.

Run on the worker host so credentials never leave it. Only use the supplied,
consented canary fixtures. This script never deletes a voice ID supplied by a
caller or returned by the server: IDs are randomly generated for this run.

Example (candidate or production, changing only port/root as appropriate):
  CLONE_TOKEN_FILE=/path/to/.api-token python fixed-deepfilter-smoke.py \
    --url http://127.0.0.1:8890 --voice-root /path/to/voices \
    --input-dir /path/to/us-canary-inputs

Prints a credential-free JSON result; does not save reference/output audio.
"""

from __future__ import annotations

import argparse
from array import array
import hashlib
import io
import json
import math
import os
from pathlib import Path
import signal
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
import uuid
import wave


FIXTURES = {
    "clean": "00-clean.wav",
    "kitchen": "01-kitchen.wav",
    "washing-machine": "03-washing-machine.wav",
    "meeting-room": "04-meeting-room.wav",
    "short": "short-4s.wav",
}
POLICY = "fixed-deepfilter-atten24-v1"
REFERENCE_SPEAKER_POLICY = "warn-only-v1"
TEST_PREFIX = "vc_smokedf_"
PREVIEW_TEXT = "你好，这是我在 CastReader 中创建的声音。现在让我们一起清晰、自然、稳定地读完这段内容。"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # A loopback worker must not redirect a credential-bearing request.
        return None


LOCAL_HTTP = build_opener(ProxyHandler({}), NoRedirect())


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def request(url: str, token: str, method: str, payload: bytes | None = None,
            content_type: str | None = None, *, timeout: float = 95.0,
            request_id: str | None = None) -> tuple[int, bytes, dict[str, str], float]:
    headers = {"X-Clone-Token": token, "X-TTS-Priority": "background"}
    if content_type:
        headers["Content-Type"] = content_type
    if request_id:
        headers["X-Request-ID"] = request_id
    started = time.monotonic()
    try:
        with LOCAL_HTTP.open(Request(url, data=payload, headers=headers, method=method),
                             timeout=timeout) as response:
            return response.status, response.read(), dict(response.headers), time.monotonic() - started
    except HTTPError as error:
        return error.code, error.read(), dict(error.headers), time.monotonic() - started


def status_message(status: int, raw: bytes) -> str:
    """Never echo a server body, request headers, or credentials on failure."""
    try:
        detail = json.loads(raw).get("detail", {})
        code = detail.get("code", "") if isinstance(detail, dict) else ""
    except (ValueError, AttributeError):
        code = ""
    return f"HTTP {status}" + (f" ({code})" if code else "")


def multipart(voice_id: str, reference: bytes) -> tuple[bytes, str]:
    boundary = f"smoke-{uuid.uuid4().hex}"
    parts = []
    for key, value in {"consent_confirmed": "true", "requested_voice_id": voice_id,
                       "reference_language": "zh"}.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="reference"; filename="canary.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + reference + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def denoise_proof(metadata: dict, voice_id: str) -> dict:
    check(metadata.get("voice_id") == voice_id, "voice ID mismatch")
    proof = metadata.get("adaptive_denoise", {})
    check(proof.get("selected") == "atten24", "DeepFilter atten24 was not selected")
    check(proof.get("deepfilter_applied") is True, "DeepFilter execution not attested")
    check(proof.get("selector_version", proof.get("pipeline_version")) == POLICY,
          "fixed DeepFilter policy version mismatch")
    check(proof.get("deepfilter_passes") == 1 and proof.get("prompt_builds") == 1
          and proof.get("probe_count") == 0, "single-pass pipeline contract changed")
    elapsed = proof.get("deepfilter_elapsed_s")
    check(isinstance(elapsed, (float, int)) and not isinstance(elapsed, bool)
          and math.isfinite(elapsed) and elapsed > 0, "DeepFilter elapsed time missing or invalid")
    check(metadata.get("runtime_generation_mode") == "x-vector", "generation mode changed")
    check(float(metadata.get("reference_duration_s", 0)) > 0, "invalid reference duration")
    guard = proof.get("reference_speaker_guard")
    check(isinstance(guard, dict), "reference speaker guard evidence missing")
    check(guard.get("policy") == REFERENCE_SPEAKER_POLICY
          and guard.get("action") == "warn_only" and guard.get("blocking") is False,
          "reference speaker guard is not warn-only")
    check("passed" in guard and any(guard["passed"] is value for value in (True, False, None)),
          "reference speaker guard result missing or invalid")
    warnings = metadata.get("reference_quality_warnings")
    check(isinstance(warnings, list) and all(isinstance(item, str) for item in warnings),
          "reference quality warnings missing or invalid")
    check(guard["passed"] is not False or "speaker_consistency_relative_drop" in warnings,
          "relative speaker drop was not recorded as a warning")
    return {"selected": proof["selected"], "deepfilter_applied": True,
            "policy": POLICY, "deepfilter_elapsed_s": elapsed,
            "prompt_build_s": metadata.get("prompt_build_s"),
            "reference_duration_s": metadata["reference_duration_s"],
            "reference_speaker_guard": {key: guard.get(key) for key in (
                "backend", "policy", "action", "blocking", "comparable", "passed",
                "baseline_min_similarity", "candidate_min_similarity", "maximum_relative_drop")},
            "reference_quality_warnings": warnings}


def health_proof(health: dict) -> None:
    check(health.get("status") == "healthy", "worker is not healthy")
    check(health.get("voice_creation_enabled") is True, "voice creation disabled")
    policy = health.get("adaptive_denoise", {})
    check(policy.get("pipeline_version", policy.get("selector_version")) == POLICY
          and policy.get("all_recordings") is True and policy.get("raw_fallback") is False,
          "worker health does not attest the fixed policy")
    check(policy.get("reference_speaker_policy") == REFERENCE_SPEAKER_POLICY,
          "worker health does not attest the warn-only reference speaker policy")


def wav_proof(raw: bytes) -> dict:
    with wave.open(io.BytesIO(raw), "rb") as wav:
        check(wav.getnchannels() == 1, "speech output is not mono")
        check(wav.getsampwidth() == 2, "speech output is not PCM16")
        check(wav.getframerate() == 24000, "speech sample rate changed")
        duration = wav.getnframes() / wav.getframerate()
        check(1 <= duration <= 30, "speech duration outside canary limits")
        samples = array("h", wav.readframes(wav.getnframes()))
        if sys.byteorder != "little":
            samples.byteswap()
    check(bool(samples), "empty speech output")
    rms = math.sqrt(sum(float(value) ** 2 for value in samples) / len(samples)) / 32768
    peak = max(abs(value) for value in samples) / 32768
    check(rms > 0.001, "silent or nearly silent speech output")
    return {"duration_s": round(duration, 3), "bytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "rms_dbfs": round(20 * math.log10(rms), 2), "peak": round(peak, 5)}


def run_case(args: argparse.Namespace, token: str, case: str) -> dict:
    voice_id = TEST_PREFIX + uuid.uuid4().hex
    destination = args.voice_root / voice_id
    check(not destination.exists(), "generated test ID unexpectedly already exists")
    result = {"case": case, "test_voice_id": voice_id, "ok": False, "cleanup_ok": False}
    cleanup_required = False
    try:
        payload, content_type = multipart(voice_id, (args.input_dir / FIXTURES[case]).read_bytes())
        cleanup_required = True  # Also clean up a timed-out or failed creation.
        status, raw, _, elapsed = request(args.url + "/v1/voices", token, "POST", payload,
                                          content_type, timeout=args.timeout,
                                          request_id=voice_id + ":create")
        result.update(create_status=status, create_elapsed_s=round(elapsed, 3))
        if status == 409:
            cleanup_required = False  # Never delete a pre-existing server voice.
        check(status in (200, 201), "creation failed: " + status_message(status, raw))
        result["denoise"] = denoise_proof(json.loads(raw), voice_id)
        persisted = json.loads((destination / "metadata.json").read_text())
        check(denoise_proof(persisted, voice_id) == result["denoise"], "persisted metadata differs")
        check((destination / "prompt.pt").is_file(), "prompt was not published")
        check(not list(destination.glob("reference*")), "reference audio was not cleaned up")
        speech = json.dumps({"voice_id": voice_id, "text": PREVIEW_TEXT,
                             "language_id": "zh", "seed": 20260825}).encode()
        status, raw, headers, elapsed = request(args.url + "/v1/speech", token, "POST", speech,
                                                "application/json", timeout=args.timeout,
                                                request_id=voice_id + ":speech")
        result.update(speech_status=status, speech_elapsed_s=round(elapsed, 3))
        check(status == 200, "speech failed: " + status_message(status, raw))
        result["audio"] = wav_proof(raw)
        result["speech_queue_wait_ms"] = next((value for key, value in headers.items()
                                                if key.lower() == "x-tts-queue-wait-ms"), None)
        result["ok"] = True
    except Exception as error:
        # Deliberately do not stringify transport errors, which may carry URLs.
        result["error"] = str(error) if isinstance(error, AssertionError) else type(error).__name__
    finally:
        if cleanup_required:
            try:
                status, raw, _, _ = request(args.url + "/v1/voices/" + voice_id, token, "DELETE", timeout=args.timeout)
                check(status in (200, 404), "test cleanup failed: " + status_message(status, raw))
                check(not destination.exists(), "test voice directory remains")
                check(not list(args.voice_root.glob(f".{voice_id}.*.building")), "test staging directory remains")
                result["cleanup_ok"] = True
            except Exception as error:
                result["cleanup_error"] = str(error) if isinstance(error, AssertionError) else type(error).__name__
                result["ok"] = False
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8890")
    parser.add_argument("--token-file", type=Path, default=os.environ.get("CLONE_TOKEN_FILE"))
    parser.add_argument("--voice-root", type=Path, required=True)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--case", action="append", choices=FIXTURES)
    parser.add_argument("--timeout", type=float, default=95.0)
    args = parser.parse_args()
    args.url = args.url.rstrip("/")
    parsed = urlparse(args.url)
    check(parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")
          and not parsed.username and not parsed.password and not parsed.path
          and not parsed.query and not parsed.fragment, "only a loopback HTTP worker URL is allowed")
    check(args.token_file is not None, "provide --token-file or CLONE_TOKEN_FILE")
    check(args.voice_root.is_dir() and not args.voice_root.is_symlink(), "voice root must be a real directory")
    token = args.token_file.read_text().strip()
    check(bool(token), "worker token file is empty")
    cases = args.case or list(FIXTURES)
    for case in cases:
        check((args.input_dir / FIXTURES[case]).is_file(), f"missing {case} fixture")
    status, raw, _, _ = request(args.url + "/health", token, "GET", timeout=5)
    check(status == 200, "worker health endpoint unavailable")
    health = json.loads(raw)
    health_proof(health)
    # SIGTERM runs the same narrow finally cleanup as Ctrl-C.
    def interrupted(*_):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    results = [run_case(args, token, case) for case in cases]
    passed = all(item["ok"] and item["cleanup_ok"] for item in results)
    print(json.dumps({"policy": POLICY, "reference_speaker_policy": REFERENCE_SPEAKER_POLICY,
                      "ok": passed, "cases": results}, indent=2), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
