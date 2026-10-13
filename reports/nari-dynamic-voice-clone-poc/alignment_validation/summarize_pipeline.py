"""Reproducible aggregation of retained pipeline test evidence."""
import argparse
from collections import Counter
import json
from pathlib import Path
import statistics

import numpy as np
from scipy.signal import correlate, correlation_lags
import soundfile as sf

from analyze_results import distribution


def median(rows, key):
    return statistics.median(row[key] for row in rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--original", type=Path, required=True)
    args = parser.parse_args()
    result = {"latency": [], "live": {}, "clients": {}, "apple_clock": []}
    datasets = {}
    for mode in ["eager", "sdpa"]:
        data = json.loads((args.root / ("gpu-" + mode) / "results.json").read_text())
        datasets[mode] = data
        result[mode] = {key: data[key] for key in ["load_ms", "first_inference_ms", "summary",
                                                  "peak_allocated_bytes", "peak_reserved_bytes"]}
        for identity in ["phone-09", "phone-21", "phone-00", "phone-14"]:
            rows = [row for row in data["latency"] if row["id"] == identity]
            grouped = {kind: [row for row in rows if row["mode"] == kind]
                       for kind in ["baseline", "serial", "overlap"]}
            baselines = {row["repeat"]: row["postprocess_ms"] for row in grouped["baseline"]}
            result["latency"].append({"attention": mode, "id": identity,
                                      "duration": rows[0]["duration"],
                                      "alignment_ms": median(grouped["overlap"], "alignment_ms"),
                                      "baseline_ms": median(grouped["baseline"], "postprocess_ms"),
                                      "serial_ms": median(grouped["serial"], "postprocess_ms"),
                                      "overlap_ms": median(grouped["overlap"], "postprocess_ms"),
                                      "paired_increment_ms": distribution([row["postprocess_ms"] - baselines[row["repeat"]]
                                                                            for row in grouped["overlap"]])})
        result[mode]["concurrency"] = [{"callers": callers,
                                         "outcomes": dict(Counter(row["reason"] for row in data["concurrency"]
                                                                  if row["concurrency"] == callers)),
                                         "latency_ms": distribution([row["postprocess_ms"] for row in data["concurrency"]
                                                                     if row["concurrency"] == callers])}
                                        for callers in [1, 2, 4]]
    result["attention_exact_words_equal"] = [row["words"] for row in datasets["eager"]["diagnostics"]] == [
        row["words"] for row in datasets["sdpa"]["diagnostics"]]
    live = json.loads((args.root / "live-tts/results.json").read_text())
    result["live"]["first_segment"] = [{"mode": mode,
                                         "tts_ms": median([row for row in live["first_segment"] if row["mode"] == mode], "tts_ms"),
                                         "total_ms": median([row for row in live["first_segment"] if row["mode"] == mode], "total_ms"),
                                         "post_ms": median([row for row in live["first_segment"] if row["mode"] == mode], "postprocess_ms")}
                                        for mode in ["baseline", "serial", "overlap"]]
    alone = [row for row in live["next_segment"] if row["mode"] == "tts-alone"]
    together = [row for row in live["next_segment"] if row["mode"] == "tts-with-alignment"]
    result["live"]["next_segment"] = {"alone_tts_ms": median(alone, "tts_ms"),
                                      "overlap_tts_ms": median(together, "tts_ms"),
                                      "contended_alignment_ms": statistics.median(row["previous_alignment"]["alignment_ms"] for row in together),
                                      "paired_tts_increment_ms": distribution([row["tts_ms"] - next(
                                          base["tts_ms"] for base in alone if base["repeat"] == row["repeat"])
                                                                              for row in together])}
    for dataset in ["gpu-eager", "live-tts"]:
        result["clients"][dataset] = {}
        for client in ["extension", "ios", "android"]:
            path = args.root / dataset / (client + "-compatibility.json")
            if path.exists():
                rows = json.loads(path.read_text())
                result["clients"][dataset][client] = {"accepted": sum(row["accepted"] for row in rows),
                                                      "word_quality": sum(row.get("wordQuality", False) for row in rows),
                                                      "total": len(rows)}
    original = json.loads((args.original / "manifest.json").read_text())
    for row in original:
        apple_path = args.root / "gpu-eager" / ("apple-decoded-" + row["id"] + ".wav")
        if not apple_path.exists():
            continue
        expected, sample_rate = sf.read(args.original / row["audio"], dtype="float32")
        actual, actual_rate = sf.read(apple_path, dtype="float32")
        correlation = correlate(actual[:sample_rate * 5], expected[:sample_rate * 5], method="fft")
        lags = correlation_lags(min(len(actual), sample_rate * 5), min(len(expected), sample_rate * 5))
        lag = int(lags[np.argmax(correlation)])
        result["apple_clock"].append({"id": row["id"], "extra_frames": len(actual) - len(expected),
                                       "signal_offset_frames": lag, "signal_offset_ms": lag * 1000 / sample_rate})
    (args.root / "summary.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key not in {"eager", "sdpa", "apple_clock"}}, indent=2))
    print("Apple signal offsets (ms):", sorted({row["signal_offset_ms"] for row in result["apple_clock"]}))


if __name__ == "__main__":
    main()
