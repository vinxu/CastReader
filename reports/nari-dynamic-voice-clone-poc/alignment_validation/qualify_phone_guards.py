from __future__ import annotations

import argparse
import base64
import io
import json
from pathlib import Path
import statistics
import time

import soundfile as sf
import torch

from caption_pipeline import (
    AlignmentRejected, PCM, PIPELINE_REVISION, QwenPCMAligner,
    measured_word_groups, project_words, reject_uncovered_zero_word_gaps,
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert torch.cuda.mem_get_info()[0] >= 6 * 1024**3
    torch.set_num_threads(2)
    torch.cuda.set_per_process_memory_fraction(.20)
    aligner = QwenPCMAligner(device="cuda", model_path=str(args.model))
    records = []
    for fixture in json.loads(args.fixtures.read_text()):
        if torch.cuda.mem_get_info()[0] < 4 * 1024**3:
            raise RuntimeError("qualification-memory-safety-floor")
        samples, rate = sf.read(io.BytesIO(base64.b64decode(fixture["response"]["audio"])), dtype="float32")
        pcm = PCM(samples, rate)
        assert pcm.duration <= 20, "Keep this co-resident qualification bounded to short captured audio"
        started = time.perf_counter()
        words = aligner(pcm, fixture["text"], fixture["language"])
        alignment_ms = (time.perf_counter() - started) * 1000
        reason, timestamps = "accepted", []
        validation_started = time.perf_counter()
        try:
            grouped = measured_word_groups(words, pcm.duration)
            candidate = project_words(fixture["text"], grouped, pcm.duration)
            reject_uncovered_zero_word_gaps(pcm, words)
            timestamps = candidate
        except AlignmentRejected as error:
            reason = str(error)
        validation_ms = (time.perf_counter() - validation_started) * 1000
        records.append({"id": fixture["id"], "text": fixture["text"], "reason": reason,
                        "words": words, "timestamps": timestamps, "alignment_ms": alignment_ms,
                        "validation_ms": validation_ms})
        args.output.write_text(json.dumps({"revision": PIPELINE_REVISION, "rows": records}, ensure_ascii=False, indent=2))
        print(json.dumps({"id": fixture["id"], "reason": reason, "alignment_ms": alignment_ms,
                          "validation_ms": validation_ms}), flush=True)
    timings = sorted(row["validation_ms"] for row in records)
    summary = {"samples": len(records), "rejected": [{"id": row["id"], "reason": row["reason"]}
                                                     for row in records if row["reason"] != "accepted"],
               "validation_median_ms": statistics.median(timings),
               "validation_p95_ms": timings[int(len(timings) * .95)],
               "validation_max_ms": max(timings),
               "peak_allocated_bytes": torch.cuda.max_memory_allocated(),
               "peak_reserved_bytes": torch.cuda.max_memory_reserved()}
    args.output.write_text(json.dumps({"revision": PIPELINE_REVISION, "summary": summary, "rows": records}, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
