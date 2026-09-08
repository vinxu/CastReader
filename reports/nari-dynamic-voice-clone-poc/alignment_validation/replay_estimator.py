#!/usr/bin/env python3
"""Replay the actual worker's pure timing functions without starting a worker.

Inputs are locally retained phone MP3s. Decoding MP3 is not byte-equivalent to
the original worker WAV, so compare this reproduction with the captured JSON.
No model, voice prompt, credential or production endpoint is accessed.
"""
from __future__ import annotations

import ast
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import time

import numpy as np
import soundfile as sf


def load_estimator(worker: Path):
    names = {
        "WORD_TIMESTAMP_PATTERN", "SEGMENT_TIMESTAMP_LANGUAGES",
        "canonical_language_code", "supports_word_timestamps", "word_timestamp_matches",
        "_mask_runs", "_speech_timing_profile", "_spoken_weight", "_punctuation_strength",
        "_allocate_word_group", "estimated_timestamps",
    }
    nodes = []
    for node in ast.parse(worker.read_text()).body:
        if isinstance(node, ast.FunctionDef) and node.name in names:
            nodes.append(node)
        elif isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in names for t in node.targets):
            nodes.append(node)
    ns = {"np": np, "sf": sf, "io": io, "re": re}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(worker), "exec"), ns)
    return ns


def decode(path: Path, sample_rate=24000):
    raw = subprocess.check_output([
        "/usr/local/bin/ffmpeg", "-v", "error", "-i", str(path), "-ac", "1",
        "-ar", str(sample_rate), "-f", "f32le", "pipe:1",
    ])
    return np.frombuffer(raw, dtype=np.float32).copy(), sample_rate


def wav_bytes(audio, sr):
    out = io.BytesIO()
    sf.write(out, audio, sr, format="WAV", subtype="PCM_16")
    return out.getvalue()


def main():
    root = Path("build/alignment-evidence")
    worker = Path(__file__).resolve().parents[1] / "worker/clone_worker.py"
    ns = load_estimator(worker)
    allocator = ns["_allocate_word_group"]
    records = []
    for row in json.loads((root / "manifest.json").read_text()):
        audio, sr = decode(root / row["audio"])
        groups = []

        def observed_allocator(indexes, weights, start, end, profile):
            groups.append({"first": indexes.start, "stop": indexes.stop,
                           "start": start, "end": end, "seconds_per_word": (end-start)/max(1,len(indexes))})
            return allocator(indexes, weights, start, end, profile)

        ns["_allocate_word_group"] = observed_allocator
        wav = wav_bytes(audio, sr)
        started = time.perf_counter()
        timestamps = ns["estimated_timestamps"](row["text"], len(audio)/sr, wav_bytes=wav)
        elapsed = (time.perf_counter()-started)*1000
        profile = ns["_speech_timing_profile"](wav, 1.0, len(audio)/sr)
        rec = {"id": row["id"], "elapsed_ms": elapsed, "timestamps": timestamps,
               "speech_start": profile["speech_start"], "speech_end": profile["speech_end"],
               "pauses": profile["pauses"], "groups": groups,
               "original_sub_35ms": sum(t[2]-t[1]<.035 for t in row["original_timestamps"]),
               "replay_sub_35ms": sum(t["end_time"]-t["start_time"]<.035 for t in timestamps)}
        if row["id"] == "phone-14":
            # A diagnostic counterfactual only. Do not trim production audio based on ASR.
            cropped = audio[:int(33*sr)]
            rec["counterfactual_33sec"] = ns["estimated_timestamps"](
                row["text"], len(cropped)/sr, wav_bytes=wav_bytes(cropped, sr))
        records.append(rec)
        print(json.dumps({k:v for k,v in rec.items() if k not in {"timestamps","groups","pauses","counterfactual_33sec"}}), flush=True)
    (root / "estimator-replay.json").write_text(json.dumps({
        "worker_sha256": hashlib.sha256(worker.read_bytes()).hexdigest(), "results": records
    }, indent=2))


if __name__ == "__main__":
    main()
