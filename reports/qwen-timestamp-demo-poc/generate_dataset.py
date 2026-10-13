#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import time
import wave

import httpx


def load_rows(path: Path) -> list[dict[str, str]]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def write_wav(path: Path, pcm: bytes) -> float:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24_000)
        output.writeframes(pcm)
    return len(pcm) / 48_000


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8095/v1/audio/speech")
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    rows = load_rows(args.dataset)
    manifest: list[dict[str, object]] = []
    with httpx.Client(timeout=300) as client:
        for index, row in enumerate(rows):
            started = time.perf_counter()
            response = client.post(
                args.url,
                json={
                    "input": row["text"],
                    "voice": "clone",
                    "language": "english",
                    "seed": 20260825 + index,
                    "response_format": "pcm",
                    "stream": False,
                    "non_streaming_mode": True,
                    "max_new_tokens": 4096,
                    "defer_codec_until_terminal": True,
                },
            )
            response.raise_for_status()
            elapsed = time.perf_counter() - started
            request_id = response.headers["x-nari-request-id"]
            capture_source = args.capture_dir / f"{request_id}.pt"
            deadline = time.monotonic() + 10
            while not capture_source.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            if not capture_source.exists():
                raise RuntimeError(f"hidden-state capture missing for {request_id}")
            capture_path = args.output_dir / f"{row['id']}.pt"
            capture_source.replace(capture_path)
            wav_path = args.output_dir / f"{row['id']}.wav"
            audio_seconds = write_wav(wav_path, response.content)
            item = {
                **row,
                "request_id": request_id,
                "capture": capture_path.name,
                "audio": wav_path.name,
                "generation_seconds": elapsed,
                "audio_seconds": audio_seconds,
                "rtf": elapsed / audio_seconds,
            }
            manifest.append(item)
            print(json.dumps(item), flush=True)
    (args.output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )


if __name__ == "__main__":
    main()

