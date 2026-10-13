#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import time

import torch

from train_distilled_head import smoothed_word_embeddings
from train_timestamp_head import TimestampHead, forced_ctc_path, load_samples


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sample = next(item for item in load_samples(args.data, args.model_dir) if item.split == "demo")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    device = torch.device("cuda")
    head = TimestampHead(checkpoint["hidden_size"], checkpoint["width"]).to(device)
    head.load_state_dict(checkpoint["state_dict"])
    head.eval()
    hidden = sample.hidden.to(device)
    words = smoothed_word_embeddings(sample.word_embeddings).to(device)
    with torch.inference_mode():
        for _ in range(30):
            logits = head(hidden, words)
        torch.cuda.synchronize()
        head_times: list[float] = []
        for _ in range(300):
            started = time.perf_counter()
            logits = head(hidden, words)
            torch.cuda.synchronize()
            head_times.append((time.perf_counter() - started) * 1000)
        logits_cpu = logits.cpu()
        for _ in range(10):
            forced_ctc_path(logits_cpu, len(sample.words))
        decode_times: list[float] = []
        for _ in range(100):
            started = time.perf_counter()
            forced_ctc_path(logits_cpu, len(sample.words))
            decode_times.append((time.perf_counter() - started) * 1000)
    manifest = json.loads((args.data / "manifest.json").read_text())
    generation_seconds = next(
        float(item["generation_seconds"]) for item in manifest if item["id"] == sample.sample_id
    )
    head_median = statistics.median(head_times)
    decode_median = statistics.median(decode_times)
    total_ms = head_median + decode_median
    result = {
        "parameters": sum(parameter.numel() for parameter in head.parameters()),
        "checkpoint_bytes": args.checkpoint.stat().st_size,
        "audio_seconds": sample.audio_seconds,
        "frames": sample.hidden.shape[0],
        "words": len(sample.words),
        "tts_generation_ms": generation_seconds * 1000,
        "head_gpu_median_ms": head_median,
        "head_gpu_p95_ms": sorted(head_times)[int(len(head_times) * 0.95)],
        "monotonic_decode_cpu_median_ms": decode_median,
        "monotonic_decode_cpu_p95_ms": sorted(decode_times)[int(len(decode_times) * 0.95)],
        "total_timestamp_median_ms": total_ms,
        "overhead_percent_of_tts": total_ms / (generation_seconds * 10),
    }
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
