"""Real-model GPU/MPS benchmark; never calls TTS or account endpoints."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path
import platform
import threading
import time

import soundfile as sf
import torch

from analyze_results import distribution, errors
from caption_pipeline import (
    CaptionPipeline, MODEL_REVISION, PIPELINE_REVISION, QwenPCMAligner,
    encode_gapless, prepare_pcm,
)


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", default="cuda:0")
    parser.add_argument("--model", required=True)
    parser.add_argument("--attention", default="eager")
    parser.add_argument("--repeats", type=int, default=6)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4)
    if args.device.startswith("cuda"):
        free, total = torch.cuda.mem_get_info()
        if free < 6 * 1024**3:
            raise RuntimeError("less-than-6GiB-free-before-test")
        torch.cuda.set_per_process_memory_fraction(.20)
    manifest = json.loads((args.evidence / "manifest.json").read_text())
    references = {row["id"]: [word for segment in row["reference"]["segments"]
                             for word in segment.get("words", [])]
                  for row in json.loads((args.evidence / "whisper-reference.json").read_text())}
    pcm_by_id = {}
    for row in manifest:
        data = (args.evidence / row["audio"]).read_bytes()
        audio, sample_rate = sf.read(io.BytesIO(data), dtype="float32")
        stream = io.BytesIO()
        sf.write(stream, audio, sample_rate, format="WAV", subtype="PCM_16")
        pcm_by_id[row["id"]] = prepare_pcm(stream.getvalue())
    started = time.perf_counter()
    aligner = QwenPCMAligner(args.device, args.model, args.attention)
    pipeline = CaptionPipeline(aligner, max_inflight=3, alignment_budget_s=5)
    result = {"model_revision": MODEL_REVISION, "pipeline_revision": PIPELINE_REVISION,
              "hardware": platform.platform(), "torch": torch.__version__,
              "device": args.device, "attention": args.attention,
              "load_ms": (time.perf_counter() - started) * 1000,
              "reference_limit": "Whisper Base corroboration, not human ground truth",
              "diagnostics": [], "latency": [], "concurrency": [], "speed": []}
    if args.device.startswith("cuda"):
        result["gpu"] = torch.cuda.get_device_name()
        torch.cuda.reset_peak_memory_stats()
    first = min(manifest, key=lambda row: row["duration"])
    started = time.perf_counter()
    aligner(pcm_by_id[first["id"]], first["text"], "en")
    result["first_inference_ms"] = (time.perf_counter() - started) * 1000
    fixtures = []
    try:
        for row in manifest:
            captured = {}
            processor = aligner.model.aligner_processor
            original = processor.parse_timestamp

            def capture(word_list, timestamp):
                captured["raw_ms"] = timestamp.tolist()
                return original(word_list, timestamp)

            processor.parse_timestamp = capture
            pcm = pcm_by_id[row["id"]]
            try:
                words = aligner(pcm, row["text"], "en")
            finally:
                processor.parse_timestamp = original
            raw = captured["raw_ms"]
            zeros = []
            for index, word in enumerate(words):
                if word["end_time"] <= word["start_time"]:
                    raw_start, raw_end = raw[index * 2:index * 2 + 2]
                    zeros.append({"index": index, "text": word["text"],
                                  "raw_start_ms": raw_start, "raw_end_ms": raw_end,
                                  "origin": "raw-zero" if raw_start == raw_end else
                                            "raw-reversed" if raw_start > raw_end else "postprocessing"})
            candidate = pipeline.caption(pcm, text=row["text"], language="en", voice_code="vc_alignment_fixture")
            reference_errors = errors([(word["text"], word["start_time"], word["end_time"])
                                      for word in words], references[row["id"]])
            result["diagnostics"].append({"id": row["id"], "duration": pcm.duration,
                                          "raw_ms": raw, "words": words, "zero_words": zeros,
                                          "reason": candidate.reason,
                                          "reference_errors": reference_errors,
                                          "audio_sha256": hashlib.sha256((args.evidence / row["audio"]).read_bytes()).hexdigest()})
            fixtures.append({"id": row["id"], "text": row["text"], "language": "en",
                             "duration": candidate.duration, "response": candidate.response})
            print(json.dumps({"phase": "accuracy", "id": row["id"], "zero_words": len(zeros),
                              "reason": candidate.reason}), flush=True)
            write_json(args.output / "results.json", result)
        selected_ids = ["phone-09", "phone-21", "phone-00", "phone-14"]
        for identity in selected_ids:
            row = next(row for row in manifest if row["id"] == identity)
            pcm = pcm_by_id[identity]
            for repeat in range(args.repeats):
                modes = ["baseline", "serial", "overlap"]
                modes = modes[repeat % 3:] + modes[:repeat % 3]
                for mode in modes:
                    started = time.perf_counter()
                    if mode == "baseline":
                        encoded = encode_gapless(pcm)
                        record = {"postprocess_ms": (time.perf_counter() - started) * 1000}
                        reason = "no-alignment"
                    else:
                        caption = pipeline.caption(pcm, text=row["text"], language="en",
                                                   voice_code="vc_alignment_fixture", overlap=mode == "overlap")
                        record = caption.timings
                        reason = caption.reason
                    result["latency"].append({"id": identity, "repeat": repeat, "mode": mode,
                                              "duration": pcm.duration, "reason": reason, **record})
            print(json.dumps({"phase": "latency", "id": identity}), flush=True)
            write_json(args.output / "results.json", result)
        row = next(row for row in manifest if row["id"] == "phone-21")
        pcm = pcm_by_id[row["id"]]
        for concurrency in [1, 2, 4]:
            for repeat in range(args.repeats):
                barrier = threading.Barrier(concurrency)

                def run(index):
                    barrier.wait()
                    caption = pipeline.caption(pcm, text=row["text"], language="en",
                                               voice_code="vc_alignment_fixture")
                    return {"concurrency": concurrency, "repeat": repeat, "index": index,
                            "reason": caption.reason, **caption.timings}

                with ThreadPoolExecutor(max_workers=concurrency) as callers:
                    result["concurrency"].extend(callers.map(run, range(concurrency)))
            print(json.dumps({"phase": "concurrency", "callers": concurrency}), flush=True)
        speed_row = next(row for row in manifest if row["id"] == "phone-09")
        original_pcm = pcm_by_id[speed_row["id"]]
        stream = io.BytesIO()
        sf.write(stream, original_pcm.samples, original_pcm.sample_rate, format="WAV")
        for speed in [.8, 1, 1.25, 2]:
            started = time.perf_counter()
            pcm = prepare_pcm(stream.getvalue(), speed)
            prepare_ms = (time.perf_counter() - started) * 1000
            caption = pipeline.caption(pcm, text=speed_row["text"], language="en", voice_code="vc_alignment_fixture")
            result["speed"].append({"speed": speed, "actual_duration": pcm.duration,
                                     "nominal_duration": original_pcm.duration / speed,
                                     "prepare_ms": prepare_ms, "reason": caption.reason,
                                     "timestamps": caption.response["timestamps"], **caption.timings})
        if args.device.startswith("cuda"):
            result["peak_allocated_bytes"] = torch.cuda.max_memory_allocated()
            result["peak_reserved_bytes"] = torch.cuda.max_memory_reserved()
        reference_errors = [error for record in result["diagnostics"] for error in record["reference_errors"]]
        result["summary"] = {
            "word_accepted": sum(record["reason"] == "qwen-word" for record in result["diagnostics"]),
            "samples": len(manifest),
            "zero_origins": {origin: sum(word["origin"] == origin for record in result["diagnostics"]
                                         for word in record["zero_words"])
                             for origin in ["raw-zero", "raw-reversed", "postprocessing"]},
            "start_difference_ms": distribution([error["start_error_ms"] for error in reference_errors]),
            "latency": [{"id": identity, "mode": mode,
                         **distribution([record["postprocess_ms"] for record in result["latency"]
                                         if record["id"] == identity and record["mode"] == mode])}
                        for identity in selected_ids for mode in ["baseline", "serial", "overlap"]],
        }
        write_json(args.output / "results.json", result)
        write_json(args.output / "client-fixtures.json", fixtures)
        print(json.dumps(result["summary"], indent=2), flush=True)
    finally:
        pipeline.close()


if __name__ == "__main__":
    main()
