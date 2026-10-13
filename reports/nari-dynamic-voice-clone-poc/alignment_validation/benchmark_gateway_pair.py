from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import statistics
import time
import uuid

import httpx


PASSAGES = {
    "short": "The sea monster was near the ship.",
    "medium": "The little train stopped beside the river. The conductor counted the tickets, then quietly closed the door. Nobody knew what would happen next.",
    "long": "The little train stopped beside the river. The conductor counted the tickets, then quietly closed the door. Nobody knew what would happen next. Beyond the mountains, the quiet village was waiting for the morning post. An old man stood by the station with a wooden box in his hands. He looked down the empty road and listened carefully. Somewhere in the distance, a bell began to ring. We decided to stay together until the rain had stopped.",
}
NUMBERS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]


def distribution(values):
    ordered = sorted(values)
    return {"n": len(ordered), "median_ms": statistics.median(ordered),
            "p95_ms": ordered[min(len(ordered) - 1, int(len(ordered) * .95))], "max_ms": ordered[-1]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=8, choices=range(2, 13))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    token = args.token_file.read_text().strip()
    client = httpx.Client(headers={"X-Clone-Token": token, "X-TTS-Priority": "prefetch"},
                          trust_env=False, timeout=65)
    rows = []
    try:
        for length, passage in PASSAGES.items():
            for repeat in range(args.repeats):
                health = client.get("http://127.0.0.1:18890/health").raise_for_status().json()
                if health["busy"] or health["queue_depth"]:
                    raise RuntimeError("unrelated-worker-traffic-abort")
                text = "Chapter " + NUMBERS[repeat] + ". " + passage
                modes = ["old", "new"] if repeat % 2 == 0 else ["new", "old"]
                for mode in modes:
                    port = 18890 if mode == "old" else 18891
                    started = time.perf_counter()
                    response = client.post(f"http://127.0.0.1:{port}/v1/captioned-speech",
                        headers={"X-Request-ID": "pair-" + uuid.uuid4().hex}, json={
                            "input": text, "voice": "vc_e2e_generated_test", "language": "en",
                            "speed": 1, "response_format": "mp3", "return_timestamps": True, "stream": False})
                    elapsed = (time.perf_counter() - started) * 1000
                    response.raise_for_status()
                    body = response.json()
                    assert body["timestamps"], (mode, length, repeat, response.headers.get("x-voice-alignment-mode"))
                    assert response.headers.get("x-tts-idempotency") == "owner"
                    assert response.headers.get("x-tts-content-cache", "owner") == "owner"
                    identity = f"{length}-{repeat}-{mode}"
                    (args.output / (identity + ".mp3")).write_bytes(base64.b64decode(body.pop("audio")))
                    rows.append({"id": identity, "length": length, "repeat": repeat, "mode": mode,
                                 "text": text, "elapsed_ms": elapsed, "response": body,
                                 "headers": {key: value for key, value in response.headers.items()
                                             if key.startswith(("x-tts-", "x-voice-"))}})
                    (args.output / "results.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2))
                    print(json.dumps({"id": identity, "elapsed_ms": elapsed,
                                      "alignment": response.headers.get("x-voice-alignment-mode")}), flush=True)
        summary = {}
        for length in PASSAGES:
            selected = [row for row in rows if row["length"] == length]
            by_key = {(row["repeat"], row["mode"]): row for row in selected}
            summary[length] = {mode: distribution([row["elapsed_ms"] for row in selected if row["mode"] == mode])
                               for mode in ["old", "new"]}
            summary[length]["paired_new_minus_old"] = distribution([
                by_key[repeat, "new"]["elapsed_ms"] - by_key[repeat, "old"]["elapsed_ms"]
                for repeat in range(args.repeats)])
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        client.close()


if __name__ == "__main__":
    main()
