from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
from pathlib import Path

from alignment_contract import lexical_key
from replay_estimator import decode, load_estimator, wav_bytes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--captures", type=Path, required=True)
    parser.add_argument("--gateway-log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reference-model", type=Path)
    parser.add_argument("--expected-revision", default="qwen-pcm-measured-groups-v2")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    worker = Path(__file__).resolve().parents[1] / "worker/clone_worker.py"
    worker_hash = hashlib.sha256(worker.read_bytes()).hexdigest()
    assert worker_hash == "97cb920eadf2c467faa284d910d9ea2e1a35540d0e189de4a4cbbb9ff8e21ab6"
    estimator = load_estimator(worker)["estimated_timestamps"]
    gateway = {row["request_id"]: row for line in args.gateway_log.read_text().splitlines()
               if (row := json.loads(line)).get("request_id")}
    captures = sorted((json.loads(path.read_text()) for path in args.captures.glob("*.json")),
                      key=lambda row: (row["received_at"], row["request_id"]))
    fixtures, manifest, audit, references = [], [], [], []
    reference_path = args.output / "whisper-reference.json"
    prior = {row["id"]: row for row in json.loads(reference_path.read_text())} if reference_path.exists() else {}
    for capture in captures:
        identity = capture["request_id"]
        response = capture["response"]
        raw = base64.b64decode(response["audio"], validate=True)
        audio_hash = hashlib.sha256(raw).hexdigest()
        path = args.output / (identity + ".mp3")
        path.write_bytes(raw)
        audio, sample_rate = decode(path)
        duration = len(audio) / sample_rate
        timestamps = response["timestamps"]
        issues = []
        previous_end = 0.0
        for stamp in timestamps:
            start, end = stamp["start_time"], stamp["end_time"]
            if not (math.isfinite(start) and math.isfinite(end) and
                    start >= previous_end - .001 and end > start and end <= duration + .001):
                issues.append("invalid_boundary")
            previous_end = end
        if timestamps and lexical_key(capture["text"]) != "".join(lexical_key(stamp["word"]) for stamp in timestamps):
            issues.append("text_coverage")
        served = gateway.get(identity, {})
        if served.get("status") != "200" or served.get("revision") != args.expected_revision:
            issues.append("new_pipeline_not_proven")
        if capture["endpoint"] != "https://api.castreader.cn/api/voice-clone/captioned-speech":
            issues.append("unexpected_endpoint")
        audit.append({"id": identity, "received_at": capture["received_at"], "language": capture["language"],
                      "audio_sha256": audio_hash, "duration": duration, "timestamps": len(timestamps),
                      "revision": served.get("revision"), "mode": served.get("mode"),
                      "gateway_seconds": served.get("seconds"), "issues": issues})
        fixture = {"id": identity, "text": capture["text"], "language": capture["language"],
                   "duration": duration, "response": response}
        fixtures.append(fixture)
        if capture["language"] != "en" or not timestamps:
            continue
        estimated = estimator(capture["text"], duration, wav_bytes=wav_bytes(audio, sample_rate))
        manifest.append({"id": identity, "audio": path.name, "audio_sha256": audio_hash,
                         "text": capture["text"], "original_timestamps": [
                             [stamp["word"], stamp["start_time"], stamp["end_time"]] for stamp in estimated]})
        if args.reference_model:
            assert args.reference_model.is_dir(), "Use an existing local model only"
            cached = prior.get(identity)
            if cached and cached.get("audio_sha256") == audio_hash:
                reference = cached
            else:
                import mlx_whisper

                result = mlx_whisper.transcribe(str(path), path_or_hf_repo=str(args.reference_model),
                                                language="en", word_timestamps=True,
                                                condition_on_previous_text=False)
                reference = {"id": identity, "audio_sha256": audio_hash, "reference": result}
            references.append(reference)
            reference_path.write_text(json.dumps(references, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"id": identity, "language": capture["language"], "timestamps": len(timestamps),
                          "issues": issues}), flush=True)
    summary = {"captures": len(audit), "expected_revision": args.expected_revision,
               "issue_count": sum(bool(row["issues"]) for row in audit),
               "languages": {language: {"captures": sum(row["language"] == language for row in audit),
                                         "empty": sum(row["language"] == language and row["timestamps"] == 0 for row in audit)}
                             for language in sorted({row["language"] for row in audit})},
               "worker_sha256": worker_hash,
               "baseline_limit": "Old estimator replayed on the same captured MP3 decoded PCM, not an original pre-encode WAV or a second live TTS response.",
               "reference_limit": "Whisper Base independent corroboration, not manual ground truth."}
    for name, value in [("audit.json", {"summary": summary, "rows": audit}),
                        ("manifest.json", manifest), ("all-fixtures.json", fixtures),
                        ("fixtures.json", [row for row in fixtures if row["language"] == "en" and row["response"]["timestamps"]])]:
        (args.output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
