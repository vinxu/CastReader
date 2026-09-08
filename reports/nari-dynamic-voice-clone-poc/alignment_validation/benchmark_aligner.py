#!/usr/bin/env python3
"""Offline forced-alignment evaluation; never rewrites input audio or calls TTS."""
from __future__ import annotations

import argparse
from dataclasses import asdict
import importlib.metadata
import json
from pathlib import Path
import platform
import time

import torch
from qwen_asr import Qwen3ForcedAligner

from replay_estimator import decode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", default="mps")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--ids", nargs="*")
    args = parser.parse_args()
    torch.set_num_threads(4)
    root = Path("build/alignment-evidence")
    rows = json.loads((root / "manifest.json").read_text())
    if args.ids:
        rows = [r for r in rows if r["id"] in args.ids]
    # Run a short sample first; separately retain initialization and first-call cost.
    rows.sort(key=lambda r: r["duration"])
    start = time.perf_counter()
    aligner = Qwen3ForcedAligner.from_pretrained(
        "Qwen/Qwen3-ForcedAligner-0.6B",
        revision="c7cbfc2048c462b0d63a45797104fc9db3ad62b7",
        dtype=torch.float16 if args.device == "mps" else torch.float32,
        device_map=args.device,
        attn_implementation="eager",
    )
    if args.device == "mps": torch.mps.synchronize()
    result = {"hardware": platform.platform(), "device": args.device,
              "threads": torch.get_num_threads(), "model": "Qwen/Qwen3-ForcedAligner-0.6B",
              "revision": "c7cbfc2048c462b0d63a45797104fc9db3ad62b7",
              "torch": torch.__version__, "qwen_asr": importlib.metadata.version("qwen-asr"),
              "load_ms_including_download": (time.perf_counter()-start)*1000,
              "parameter_bytes": sum(p.numel()*p.element_size() for p in aligner.model.parameters()),
              "rows": []}
    print(json.dumps({k:v for k,v in result.items() if k != "rows"}), flush=True)
    for row in rows:
        audio, sr = decode(root / row["audio"], 16000)
        for repeat in range(args.repeats):
            start = time.perf_counter()
            try:
                output = aligner.align(audio=(audio,sr), text=row["text"], language=row["language"])[0]
                if args.device == "mps": torch.mps.synchronize()
                words = [asdict(w) for w in output.items]
                item = {"id": row["id"], "repeat": repeat, "audio_seconds": len(audio)/sr,
                        "elapsed_ms": (time.perf_counter()-start)*1000, "words": words,
                        "zero_or_negative": sum(w["end_time"]<=w["start_time"] for w in words),
                        "regressions": sum(b["start_time"]<a["start_time"] for a,b in zip(words,words[1:]))}
                if args.device == "mps":
                    item['mps_current_allocated_bytes'] = torch.mps.current_allocated_memory()
                    item['mps_driver_allocated_bytes'] = torch.mps.driver_allocated_memory()
            except Exception as e:
                item = {"id":row["id"],"repeat":repeat,"error":type(e).__name__+": "+str(e)}
            result["rows"].append(item)
            (root / f"forced-{args.device}-{args.repeats}.json").write_text(json.dumps(result,ensure_ascii=False,indent=2))
            print(json.dumps({k:v for k,v in item.items() if k != "words"}), flush=True)


if __name__ == "__main__":
    main()
