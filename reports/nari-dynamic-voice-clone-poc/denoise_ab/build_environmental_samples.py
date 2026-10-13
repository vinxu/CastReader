#!/usr/bin/env python3
"""Mix clean reference speech with real DEMAND noise at controlled SNRs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal


TARGET_SAMPLE_RATE = 48_000
ZH_REFERENCE = "今天我们继续测试声音克隆。请保持自然、清晰和稳定的语气，让每一个字都容易听懂。"
EN_REFERENCE = "Today we are testing voice cloning with a clear, natural, and steady speaking style for every sentence."


@dataclass(frozen=True)
class SampleSpec:
    category: str
    clean_file: str
    language: str
    target_snr_db: float


SPECS = (
    SampleSpec("indoor-kitchen", "zh_tingting_clean.wav", "zh", 15.0),
    SampleSpec("indoor-living-room", "en_daniel_clean.wav", "en", 12.0),
    SampleSpec("indoor-washing-machine", "zh_eddy_clean.wav", "zh", 12.0),
    SampleSpec("indoor-meeting-room", "en_samantha_clean.wav", "en", 15.0),
    SampleSpec("indoor-office", "zh_grandma_clean.wav", "zh", 12.0),
    SampleSpec("public-cafeteria", "en_karen_clean.wav", "en", 15.0),
    SampleSpec("outdoor-field", "zh_tingting_clean.wav", "zh", 12.0),
    SampleSpec("outdoor-park", "en_daniel_clean.wav", "en", 12.0),
    SampleSpec("public-station", "zh_eddy_clean.wav", "zh", 15.0),
    SampleSpec("outdoor-public-square", "en_samantha_clean.wav", "en", 15.0),
    SampleSpec("outdoor-traffic", "zh_grandma_clean.wav", "zh", 12.0),
    SampleSpec("transport-metro", "en_karen_clean.wav", "en", 12.0),
)


def mono_resample(path: Path) -> np.ndarray:
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


def active_mask(audio: np.ndarray) -> np.ndarray:
    frame = round(0.02 * TARGET_SAMPLE_RATE)
    hop = round(0.01 * TARGET_SAMPLE_RATE)
    squared = np.square(audio, dtype=np.float64)
    kernel = np.ones(frame, dtype=np.float64) / frame
    envelope = np.sqrt(np.convolve(squared, kernel, mode="same"))
    peak_db = 20 * math.log10(max(float(np.max(envelope)), 1e-9))
    threshold = 10 ** (max(-48.0, peak_db - 32.0) / 20.0)
    mask = envelope >= threshold
    if np.count_nonzero(mask) < hop:
        raise ValueError("clean reference contains too little active speech")
    return mask


def deterministic_noise_segment(noise: np.ndarray, length: int, seed: int) -> np.ndarray:
    if noise.size < length:
        repeats = math.ceil(length / max(1, noise.size))
        noise = np.tile(noise, repeats)
    available = noise.size - length
    start = 0 if available <= 0 else seed % (available + 1)
    segment = np.asarray(noise[start : start + length], dtype=np.float32).copy()
    segment -= float(np.mean(segment))
    return segment


def rms(audio: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("noise_dir", type=Path)
    parser.add_argument("clean_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    records: list[dict[str, object]] = []
    for index, spec in enumerate(SPECS, start=1):
        clean_path = args.clean_dir / spec.clean_file
        noise_path = args.noise_dir / f"{spec.category}.wav"
        clean = mono_resample(clean_path)
        noise = deterministic_noise_segment(
            mono_resample(noise_path), len(clean), seed=20260902 + index * 7919
        )
        mask = active_mask(clean)
        clean_rms = rms(clean[mask])
        noise_rms = rms(noise[mask])
        if noise_rms <= 1e-9:
            raise ValueError(f"noise is silent: {noise_path}")
        scale = clean_rms / (noise_rms * 10 ** (spec.target_snr_db / 20.0))
        noise_component = noise * scale
        mixed = clean + noise_component
        peak = float(np.max(np.abs(mixed)))
        peak_scale = min(1.0, 0.97 / max(peak, 1e-9))
        clean *= peak_scale
        noise_component *= peak_scale
        mixed *= peak_scale

        actual_snr_db = 20 * math.log10(
            max(rms(clean[mask]), 1e-9) / max(rms(noise_component[mask]), 1e-9)
        )
        sample_id = f"{index:02d}-{spec.category}"
        sample_dir = args.output_dir / sample_id
        sample_dir.mkdir(parents=True, exist_ok=True)
        sf.write(sample_dir / "reference-clean.wav", clean, TARGET_SAMPLE_RATE, subtype="PCM_16")
        sf.write(sample_dir / "reference-noisy.wav", mixed, TARGET_SAMPLE_RATE, subtype="PCM_16")
        sf.write(sample_dir / "noise-only.wav", noise_component, TARGET_SAMPLE_RATE, subtype="PCM_16")
        noisy_bytes = (sample_dir / "reference-noisy.wav").read_bytes()
        records.append(
            {
                "sample_id": sample_id,
                "category": spec.category,
                "clean_source": spec.clean_file,
                "noise_source": noise_path.name,
                "language": spec.language,
                "reference_text": ZH_REFERENCE if spec.language == "zh" else EN_REFERENCE,
                "target_snr_db": spec.target_snr_db,
                "actual_active_snr_db": round(actual_snr_db, 3),
                "duration_s": round(len(mixed) / TARGET_SAMPLE_RATE, 3),
                "peak_scale": round(peak_scale, 6),
                "reference_noisy_sha256": hashlib.sha256(noisy_bytes).hexdigest(),
                "reference_noisy": f"{sample_id}/reference-noisy.wav",
                "reference_clean": f"{sample_id}/reference-clean.wav",
                "noise_only": f"{sample_id}/noise-only.wav",
            }
        )
        print(
            f"mixed {sample_id} target_snr={spec.target_snr_db:.1f} "
            f"actual_snr={actual_snr_db:.2f}",
            flush=True,
        )

    manifest = {
        "pipeline": "castreader-environmental-noise-ab-v1",
        "sample_rate_hz": TARGET_SAMPLE_RATE,
        "source_dataset_manifest": str(args.noise_dir / "manifest.json"),
        "records": records,
    }
    (args.output_dir / "samples.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
