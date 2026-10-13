#!/usr/bin/env python3
"""Run the pinned DeepFilterNet3 binary and measure reference preservation."""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal


TARGET_SAMPLE_RATE = 48_000


def load_mono(path: Path) -> np.ndarray:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    mono = np.mean(audio, axis=1, dtype=np.float32)
    if sample_rate != TARGET_SAMPLE_RATE:
        divisor = math.gcd(sample_rate, TARGET_SAMPLE_RATE)
        mono = signal.resample_poly(
            mono,
            TARGET_SAMPLE_RATE // divisor,
            sample_rate // divisor,
        ).astype(np.float32)
    return mono


def align_length(audio: np.ndarray, length: int) -> np.ndarray:
    if audio.size < length:
        return np.pad(audio, (0, length - audio.size))
    return audio[:length]


def si_sdr(estimate: np.ndarray, target: np.ndarray) -> float:
    estimate = estimate.astype(np.float64) - float(np.mean(estimate))
    target = target.astype(np.float64) - float(np.mean(target))
    scale = float(np.dot(estimate, target)) / max(float(np.dot(target, target)), 1e-12)
    projected = scale * target
    residual = estimate - projected
    return 10 * math.log10(
        max(float(np.dot(projected, projected)), 1e-12)
        / max(float(np.dot(residual, residual)), 1e-12)
    )


def correlation(left: np.ndarray, right: np.ndarray) -> float:
    left = left.astype(np.float64) - float(np.mean(left))
    right = right.astype(np.float64) - float(np.mean(right))
    denominator = math.sqrt(float(np.dot(left, left)) * float(np.dot(right, right)))
    return float(np.dot(left, right) / max(denominator, 1e-12))


def speaker_embedding_similarity(
    clean: np.ndarray,
    enhanced: np.ndarray,
    worker_dir: Path | None,
    speaker_model: Path | None,
) -> float | None:
    if worker_dir is None or speaker_model is None or not speaker_model.is_file():
        return None
    sys.path.insert(0, str(worker_dir))
    try:
        from audio_quality import SpeakerConsistencyInspector, _resample

        inspector = SpeakerConsistencyInspector(str(speaker_model))
        clean_16k = _resample(clean, TARGET_SAMPLE_RATE, 16_000)
        enhanced_16k = _resample(enhanced, TARGET_SAMPLE_RATE, 16_000)
        clean_embedding = inspector._embedding(clean_16k)
        enhanced_embedding = inspector._embedding(enhanced_16k)
        if clean_embedding is None or enhanced_embedding is None:
            return None
        return float(np.dot(clean_embedding, enhanced_embedding))
    except Exception:
        return None


def current_quality_gate(
    audio: np.ndarray,
    worker_dir: Path | None,
    speaker_model: Path | None,
) -> dict[str, object]:
    if worker_dir is None:
        return {"status": "unavailable"}
    if speaker_model is not None:
        os.environ["CLONE_SPEAKER_MODEL"] = str(speaker_model)
    sys.path.insert(0, str(worker_dir))
    try:
        from audio_quality import ReferenceQualityError, process_reference_audio

        result = process_reference_audio(audio, TARGET_SAMPLE_RATE)
        return {
            "status": "pass",
            "metrics": result.metrics,
            "warnings": result.warnings,
        }
    except ReferenceQualityError as error:
        return {
            "status": "reject",
            "code": error.code,
            "message": error.message,
            "metrics": error.metrics,
        }
    except Exception as error:
        return {
            "status": "error",
            "error": f"{type(error).__name__}: {error}"[:300],
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("samples_manifest", type=Path)
    parser.add_argument("--deep-filter", type=Path, required=True)
    parser.add_argument("--attenuation-limit-db", type=float, default=12.0)
    parser.add_argument("--worker-dir", type=Path)
    parser.add_argument("--speaker-model", type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.samples_manifest.read_text(encoding="utf-8"))
    root = args.samples_manifest.parent
    results: list[dict[str, object]] = []
    for record in manifest["records"]:
        sample_id = record["sample_id"]
        sample_dir = root / sample_id
        noisy_path = root / record["reference_noisy"]
        clean_path = root / record["reference_clean"]
        candidate_dir = sample_dir / "deepfilter-output"
        candidate_dir.mkdir(parents=True, exist_ok=True)
        started = time.perf_counter()
        completed = subprocess.run(
            [
                str(args.deep_filter),
                "-a",
                str(args.attenuation_limit_db),
                "-D",
                "-o",
                str(candidate_dir),
                str(noisy_path),
            ],
            check=True,
            capture_output=True,
            text=True,
            env={**os.environ, "RUST_LOG": "info"},
        )
        elapsed = time.perf_counter() - started
        generated = candidate_dir / noisy_path.name
        enhanced_path = sample_dir / "reference-deepfilter.wav"
        generated.replace(enhanced_path)
        candidate_dir.rmdir()

        clean = load_mono(clean_path)
        noisy = align_length(load_mono(noisy_path), len(clean))
        enhanced = align_length(load_mono(enhanced_path), len(clean))
        input_si_sdr = si_sdr(noisy, clean)
        output_si_sdr = si_sdr(enhanced, clean)
        embedding_similarity = speaker_embedding_similarity(
            clean, enhanced, args.worker_dir, args.speaker_model
        )
        online_quality = current_quality_gate(noisy, args.worker_dir, args.speaker_model)
        deepfilter_quality = current_quality_gate(
            enhanced, args.worker_dir, args.speaker_model
        )
        result = {
            "sample_id": sample_id,
            "reference_deepfilter": f"{sample_id}/reference-deepfilter.wav",
            "attenuation_limit_db": args.attenuation_limit_db,
            "elapsed_s": round(elapsed, 3),
            "rtf": round(elapsed / max(float(record["duration_s"]), 0.001), 4),
            "input_si_sdr_db": round(input_si_sdr, 3),
            "output_si_sdr_db": round(output_si_sdr, 3),
            "si_sdr_improvement_db": round(output_si_sdr - input_si_sdr, 3),
            "waveform_correlation_clean": round(correlation(enhanced, clean), 6),
            "speaker_embedding_similarity_clean": (
                None if embedding_similarity is None else round(embedding_similarity, 6)
            ),
            "online_quality_gate": online_quality,
            "deepfilter_quality_gate": deepfilter_quality,
            "deepfilter_log_tail": completed.stderr.strip().splitlines()[-3:],
        }
        results.append(result)
        print(
            f"enhanced {sample_id} rtf={result['rtf']} "
            f"si_sdr_delta={result['si_sdr_improvement_db']} "
            f"speaker_similarity={result['speaker_embedding_similarity_clean']}",
            flush=True,
        )

    output = {
        "pipeline": "deepfilternet3-shadow-v1",
        "deep_filter_version": "0.5.6",
        "model": "deepfilternet3 (embedded in official static binary)",
        "attenuation_limit_db": args.attenuation_limit_db,
        "delay_compensated": True,
        "post_filter": False,
        "records": results,
    }
    destination = root / "deepfilter-results.json"
    destination.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
