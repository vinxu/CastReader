#!/usr/bin/env python3
"""Isolated load and contract test for the clone captioned-speech worker."""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import math
import statistics
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

import httpx


TEXTS = (
    ("zh", "雨停以后，城市的灯光映在湿润的街道上，空气里有一种安静而清新的味道。"),
    ("zh", "请注意，下一站将在三分钟后到达；如果需要换乘，请提前做好准备。"),
    ("zh", "他停顿了一下，然后笑着说：别担心，我们会找到更好的办法。"),
    ("zh", "今天是二〇二六年八月二十六日，订单编号是 A-7-3-9，请逐字读清楚。"),
    ("zh", "“真的吗？”她惊讶地问，随后压低声音说，“这比我想象得更好。”"),
    ("zh", "百分之十二点五并不等于十二点五元；数字、单位和停顿都不能混在一起。"),
    ("zh", "先观察，再判断，最后行动。越是紧急的时候，越要保持稳定。"),
    ("zh", "从第一章到最后一页，这个声音应当保持一致，不突然变调，也不重复正文。"),
    ("en", "The quiet library felt warm and welcoming as the rain tapped against the windows."),
    ("en", "Please remember that careful preparation makes difficult work feel much easier."),
    ("en", "Really? She paused, laughed softly, and said, I never expected such wonderful news."),
    ("en", "At 7:45 p.m., flight CR-218 was delayed by twelve point five minutes."),
    ("en", "First observe, then decide, and finally act; urgency should never destroy clarity."),
    ("en", "The API returned HTTP 503, but the retry used the same request ID and completed safely."),
    ("en", "A cloned narrator must stay consistent across every paragraph without adding or repeating words."),
    ("en", "After a long silence, he whispered, We made it, and the whole room began to cheer."),
    ("fr", "Après la pluie, la ville semblait calme, lumineuse et pleine de possibilités."),
    ("de", "Bitte sprechen Sie ruhig und deutlich, auch wenn der nächste Satz viele Zahlen enthält."),
    ("es", "La lectura debe sonar natural, estable y clara desde la primera frase hasta la última."),
    ("it", "Una voce coerente rende più semplice seguire anche un testo lungo e complesso."),
    ("ja", "雨がやんだあと、静かな町にやわらかな光が広がりました。"),
    ("ko", "비가 그친 뒤, 조용한 거리에 따뜻한 불빛이 천천히 번졌습니다."),
    ("pt", "Depois da chuva, a cidade ficou silenciosa, clara e cheia de novas possibilidades."),
    ("ru", "После дождя город стал тихим, светлым и удивительно спокойным."),
)
EXPECTED_KEYS = {"audio", "audio_format", "timestamps", "voice_code"}


@dataclass
class Sample:
    priority: str
    status: int
    latency_s: float
    queue_wait_ms: float | None
    run_ms: float | None
    audio_duration_s: float | None
    audio_bytes: int
    contract_ok: bool
    error: str | None


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def mp3_duration(data: bytes) -> float | None:
    try:
        # ffprobe cannot reliably determine duration for every MP3 stream from
        # non-seekable stdin. A short-lived file keeps this validation strict.
        with tempfile.NamedTemporaryFile(suffix=".mp3") as audio_file:
            audio_file.write(data)
            audio_file.flush()
            process = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    audio_file.name,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
                timeout=10,
            )
        return float(process.stdout.strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def uses_word_timestamps(language: str) -> bool:
    return language.strip().lower().replace("_", "-").split("-", 1)[0] not in {
        "zh",
        "ja",
        "ko",
    }


def timestamps_valid(value: object, language: str) -> bool:
    if not isinstance(value, list):
        return False
    if not uses_word_timestamps(language):
        return value == []
    if not value:
        return False
    cursor = 0.0
    for item in value:
        if not isinstance(item, dict):
            return False
        try:
            start = float(item["start_time"])
            end = float(item["end_time"])
            word = item["word"]
        except (KeyError, TypeError, ValueError):
            return False
        if not isinstance(word, str) or not word or start < cursor - 0.001 or end < start:
            return False
        cursor = end
    return True


def timestamp_text_coverage_valid(text: str, value: object, language: str) -> bool:
    if not isinstance(value, list):
        return False
    if not uses_word_timestamps(language):
        return value == []
    expected = "".join(character.casefold() for character in text if character.isalnum())
    returned = "".join(
        character.casefold()
        for item in value
        if isinstance(item, dict) and isinstance(item.get("word"), str)
        for character in item["word"]
        if character.isalnum()
    )
    return bool(expected) and returned == expected


async def run(args: argparse.Namespace) -> dict[str, object]:
    parsed = urlparse(args.base_url)
    if parsed.hostname not in {"127.0.0.1", "localhost", "::1"} and not args.allow_remote:
        raise SystemExit("Refusing remote load test without --allow-remote")
    token = args.token
    if args.token_file:
        token = Path(args.token_file).read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit("--token or --token-file is required")

    semaphore = asyncio.Semaphore(args.concurrency)
    samples: list[Sample] = []
    started = time.perf_counter()
    async with httpx.AsyncClient(timeout=args.timeout) as client:
        async def one(index: int) -> None:
            language, text = TEXTS[index % len(TEXTS)]
            priority = "prefetch" if index % 5 == 4 else "interactive"
            request_id = f"load-{index}-{uuid.uuid4().hex[:10]}"
            async with semaphore:
                before = time.perf_counter()
                try:
                    response = await client.post(
                        f"{args.base_url.rstrip('/')}/v1/captioned-speech",
                        headers={
                            "X-Clone-Token": token,
                            "X-TTS-Priority": priority,
                            "X-Request-ID": request_id,
                        },
                        json={
                            "input": text,
                            "voice": args.voice_id,
                            "language": language,
                            "speed": 1.0,
                            "response_format": "mp3",
                            "return_timestamps": True,
                            "stream": False,
                        },
                    )
                    latency = time.perf_counter() - before
                    if response.status_code != 200:
                        samples.append(
                            Sample(
                                priority,
                                response.status_code,
                                latency,
                                None,
                                None,
                                None,
                                0,
                                False,
                                response.text[:160],
                            )
                        )
                        return
                    body = response.json()
                    exact_contract = set(body) == EXPECTED_KEYS
                    audio = base64.b64decode(body.get("audio", ""), validate=True)
                    audio_duration = mp3_duration(audio)
                    timestamps = body.get("timestamps")
                    timestamp_end = (
                        float(timestamps[-1]["end_time"])
                        if isinstance(timestamps, list) and timestamps
                        else None
                    )
                    contract_ok = (
                        exact_contract
                        and body.get("audio_format") == "audio/mpeg"
                        and body.get("voice_code") == args.voice_id
                        and timestamps_valid(timestamps, language)
                        and timestamp_text_coverage_valid(text, timestamps, language)
                        and len(audio) > 256
                        and audio_duration is not None
                        and audio_duration > 0.2
                        and (
                            (not uses_word_timestamps(language) and timestamp_end is None)
                            or (
                                uses_word_timestamps(language)
                                and timestamp_end is not None
                                and 0 < timestamp_end <= audio_duration + 0.05
                            )
                        )
                    )
                    samples.append(
                        Sample(
                            priority,
                            200,
                            latency,
                            float(response.headers["X-TTS-Queue-Wait-Ms"])
                            if "X-TTS-Queue-Wait-Ms" in response.headers
                            else None,
                            float(response.headers["X-TTS-Run-Ms"])
                            if "X-TTS-Run-Ms" in response.headers
                            else None,
                            audio_duration,
                            len(audio),
                            contract_ok,
                            None if contract_ok else "contract-or-audio-validation",
                        )
                    )
                except Exception as error:
                    samples.append(
                        Sample(
                            priority,
                            0,
                            time.perf_counter() - before,
                            None,
                            None,
                            None,
                            0,
                            False,
                            f"{type(error).__name__}: {error}"[:160],
                        )
                    )

        await asyncio.gather(*(one(index) for index in range(args.requests)))

    wall_s = time.perf_counter() - started
    successes = [sample for sample in samples if sample.status == 200 and sample.contract_ok]
    latencies = [sample.latency_s for sample in successes]
    queue_waits = [sample.queue_wait_ms for sample in successes if sample.queue_wait_ms is not None]
    run_times = [sample.run_ms for sample in successes if sample.run_ms is not None]
    audio_seconds = sum(sample.audio_duration_s or 0 for sample in successes)
    errors: dict[str, int] = {}
    for sample in samples:
        if sample.status == 200 and sample.contract_ok:
            continue
        key = f"status-{sample.status}:{sample.error or 'unknown'}"
        errors[key] = errors.get(key, 0) + 1
    by_priority: dict[str, object] = {}
    for priority in ("interactive", "prefetch"):
        priority_samples = [sample for sample in samples if sample.priority == priority]
        priority_successes = [
            sample
            for sample in priority_samples
            if sample.status == 200 and sample.contract_ok
        ]
        priority_latencies = [sample.latency_s for sample in priority_successes]
        priority_waits = [
            sample.queue_wait_ms
            for sample in priority_successes
            if sample.queue_wait_ms is not None
        ]
        by_priority[priority] = {
            "requests": len(priority_samples),
            "successes": len(priority_successes),
            "latency_p50_ms": round(percentile(priority_latencies, 0.50) * 1000, 2),
            "latency_p95_ms": round(percentile(priority_latencies, 0.95) * 1000, 2),
            "queue_wait_p95_ms": round(percentile(priority_waits, 0.95), 2),
        }
    return {
        "requests": len(samples),
        "concurrency": args.concurrency,
        "successes": len(successes),
        "failures": len(samples) - len(successes),
        "success_rate": round(len(successes) / max(1, len(samples)), 6),
        "wall_s": round(wall_s, 3),
        "requests_per_s": round(len(samples) / max(wall_s, 1e-9), 3),
        "generated_audio_s": round(audio_seconds, 3),
        "aggregate_rtf": round(wall_s / max(audio_seconds, 1e-9), 4),
        "latency_ms": {
            "mean": round(statistics.fmean(latencies) * 1000, 2) if latencies else 0,
            "p50": round(percentile(latencies, 0.50) * 1000, 2),
            "p95": round(percentile(latencies, 0.95) * 1000, 2),
            "p99": round(percentile(latencies, 0.99) * 1000, 2),
            "max": round(max(latencies, default=0) * 1000, 2),
        },
        "queue_wait_ms": {
            "p50": round(percentile(queue_waits, 0.50), 2),
            "p95": round(percentile(queue_waits, 0.95), 2),
            "max": round(max(queue_waits, default=0), 2),
        },
        "run_ms": {
            "p50": round(percentile(run_times, 0.50), 2),
            "p95": round(percentile(run_times, 0.95), 2),
            "max": round(max(run_times, default=0), 2),
        },
        "by_priority": by_priority,
        "errors": errors,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8890")
    parser.add_argument("--voice-id", required=True)
    parser.add_argument("--token", default="")
    parser.add_argument("--token-file")
    parser.add_argument("--requests", type=int, default=50)
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--allow-remote", action="store_true")
    args = parser.parse_args()
    if args.requests < 1 or args.concurrency < 1:
        raise SystemExit("requests and concurrency must be positive")
    print(json.dumps(asyncio.run(run(args)), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
