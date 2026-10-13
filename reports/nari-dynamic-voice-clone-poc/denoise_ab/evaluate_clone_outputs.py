#!/usr/bin/env python3
"""Measure speaker preservation and basic signal health in cloned A/B outputs."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal


def load_mono_16k(path: Path) -> np.ndarray:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    mono = np.mean(audio, axis=1, dtype=np.float32)
    if sample_rate != 16_000:
        divisor = math.gcd(sample_rate, 16_000)
        mono = signal.resample_poly(
            mono, 16_000 // divisor, sample_rate // divisor
        ).astype(np.float32)
    return mono


def signal_health(audio: np.ndarray) -> dict[str, float]:
    rms = float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    return {
        "rms_dbfs": round(20 * math.log10(max(rms, 1e-9)), 3),
        "peak_dbfs": round(20 * math.log10(max(peak, 1e-9)), 3),
        "clipping_ratio": round(float(np.mean(np.abs(audio) >= 0.999)), 8),
        "duration_s": round(audio.size / 16_000, 3),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("samples_manifest", type=Path)
    parser.add_argument("clone_result_dir", type=Path)
    parser.add_argument("--worker-dir", type=Path, required=True)
    parser.add_argument("--speaker-model", type=Path, required=True)
    args = parser.parse_args()

    os.environ["CLONE_SPEAKER_MODEL"] = str(args.speaker_model)
    sys.path.insert(0, str(args.worker_dir))
    from audio_quality import SpeakerConsistencyInspector

    inspector = SpeakerConsistencyInspector(str(args.speaker_model))
    samples = json.loads(args.samples_manifest.read_text(encoding="utf-8"))
    sample_root = args.samples_manifest.parent
    records: list[dict[str, object]] = []
    for sample in samples["records"]:
        sample_id = str(sample["sample_id"])
        paths = {
            "clean": sample_root / str(sample["reference_clean"]),
            "online": args.clone_result_dir / "labeled" / sample_id / "clone-online.wav",
            "deepfilter": args.clone_result_dir
            / "labeled"
            / sample_id
            / "clone-deepfilter.wav",
        }
        audio = {name: load_mono_16k(path) for name, path in paths.items()}
        embeddings = {name: inspector._embedding(value) for name, value in audio.items()}
        if any(value is None for value in embeddings.values()):
            raise RuntimeError(f"speaker embedding unavailable for {sample_id}")
        clean_online = float(np.dot(embeddings["clean"], embeddings["online"]))
        clean_deepfilter = float(np.dot(embeddings["clean"], embeddings["deepfilter"]))
        online_deepfilter = float(
            np.dot(embeddings["online"], embeddings["deepfilter"])
        )
        record = {
            "sample_id": sample_id,
            "category": sample["category"],
            "speaker_similarity_clean_online": round(clean_online, 6),
            "speaker_similarity_clean_deepfilter": round(clean_deepfilter, 6),
            "speaker_similarity_delta": round(clean_deepfilter - clean_online, 6),
            "speaker_similarity_online_deepfilter": round(online_deepfilter, 6),
            "online_signal": signal_health(audio["online"]),
            "deepfilter_signal": signal_health(audio["deepfilter"]),
        }
        records.append(record)
        print(
            f"clone_metric {sample_id} online={clean_online:.4f} "
            f"deepfilter={clean_deepfilter:.4f} delta={clean_deepfilter-clean_online:+.4f}",
            flush=True,
        )

    output = {
        "metric": "CampPlus cosine similarity on 16 kHz mono audio",
        "records": records,
    }
    (args.clone_result_dir / "clone-output-metrics.json").write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
