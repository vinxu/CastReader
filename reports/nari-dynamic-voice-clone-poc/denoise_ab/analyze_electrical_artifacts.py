#!/usr/bin/env python3
"""Measure low-energy electronic-noise indicators for denoise A/B outputs."""

from __future__ import annotations

import argparse
import io
import json
import math
import sys
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf
from scipy import signal


SAMPLES = {
    "01-kitchen": "01-indoor-kitchen",
    "04-meeting": "04-indoor-meeting-room",
}


def load_mono(path: Path) -> tuple[np.ndarray, int]:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    return np.mean(audio, axis=1, dtype=np.float32), sample_rate


def si_sdr(estimate: np.ndarray, target: np.ndarray) -> float:
    length = min(estimate.size, target.size)
    estimate = estimate[:length].astype(np.float64)
    target = target[:length].astype(np.float64)
    estimate -= float(np.mean(estimate))
    target -= float(np.mean(target))
    scale = float(np.dot(estimate, target)) / max(float(np.dot(target, target)), 1e-12)
    projected = scale * target
    residual = estimate - projected
    return 10 * math.log10(
        max(float(np.dot(projected, projected)), 1e-12)
        / max(float(np.dot(residual, residual)), 1e-12)
    )


def correlation(left: np.ndarray, right: np.ndarray) -> float:
    length = min(left.size, right.size)
    left = left[:length].astype(np.float64)
    right = right[:length].astype(np.float64)
    left -= float(np.mean(left))
    right -= float(np.mean(right))
    denominator = math.sqrt(float(np.dot(left, left)) * float(np.dot(right, right)))
    return float(np.dot(left, right) / max(denominator, 1e-12))


def signal_health(audio: np.ndarray, sample_rate: int) -> dict[str, float]:
    rms = float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    return {
        "duration_s": round(audio.size / sample_rate, 3),
        "rms_dbfs": round(20 * math.log10(max(rms, 1e-12)), 3),
        "peak_dbfs": round(20 * math.log10(max(peak, 1e-12)), 3),
        "clipping_ratio": round(float(np.mean(np.abs(audio) >= 0.999)), 8),
    }


def low_energy_artifact_metrics(
    audio: np.ndarray, sample_rate: int
) -> dict[str, float | int | None]:
    frame_length = round(0.080 * sample_rate)
    hop = round(0.020 * sample_rate)
    window = np.hanning(frame_length)
    frequencies = np.fft.rfftfreq(frame_length, 1 / sample_rate)
    speech_band = (frequencies >= 80) & (frequencies <= min(11_500, sample_rate / 2))
    high_band = frequencies >= min(6_500, sample_rate / 2)
    flat_band = (frequencies >= 100) & (
        frequencies <= min(10_000, sample_rate / 2)
    )
    rows: list[tuple[float, float, float]] = []
    for offset in range(0, max(1, audio.size - frame_length + 1), hop):
        frame = audio[offset : offset + frame_length]
        if frame.size < frame_length:
            frame = np.pad(frame, (0, frame_length - frame.size))
        rms = float(np.sqrt(np.mean(np.square(frame, dtype=np.float64))))
        rms_dbfs = 20 * math.log10(max(rms, 1e-12))
        power = np.abs(np.fft.rfft(frame * window)) ** 2
        total_power = float(np.sum(power[speech_band])) + 1e-18
        high_ratio = float(np.sum(power[high_band])) / total_power
        selected = power[flat_band] + 1e-18
        flatness = float(np.exp(np.mean(np.log(selected))) / np.mean(selected))
        rows.append((rms_dbfs, flatness, high_ratio))

    values = np.asarray(rows, dtype=np.float64)
    low_energy = (values[:, 0] > -60) & (values[:, 0] < -30)
    suspicious = low_energy & (values[:, 1] > 0.10) & (values[:, 2] > 0.04)
    low_count = int(np.sum(low_energy))
    return {
        "frame_count": int(values.shape[0]),
        "low_energy_frame_count": low_count,
        "low_energy_median_flatness": (
            round(float(np.median(values[low_energy, 1])), 6)
            if low_count
            else None
        ),
        "low_energy_median_high_frequency_ratio": (
            round(float(np.median(values[low_energy, 2])), 6)
            if low_count
            else None
        ),
        "suspicious_fraction_all_frames": round(float(np.mean(suspicious)), 6),
        "suspicious_fraction_low_energy_frames": round(
            float(np.sum(suspicious)) / max(low_count, 1), 6
        ),
    }


def residual_tonality(
    candidate: np.ndarray, clean: np.ndarray, sample_rate: int
) -> dict[str, float]:
    length = min(candidate.size, clean.size)
    residual = candidate[:length].astype(np.float64) - clean[:length].astype(np.float64)
    frequencies, power = signal.welch(
        residual,
        sample_rate,
        nperseg=min(65_536, max(256, residual.size)),
        scaling="spectrum",
    )
    analysis_band = (frequencies >= 20) & (frequencies <= 2_000)
    harmonic_band = np.zeros_like(frequencies, dtype=bool)
    for fundamental in (50, 60):
        for harmonic in range(1, math.floor(2_000 / fundamental) + 1):
            harmonic_band |= np.abs(frequencies - fundamental * harmonic) <= 2
    denominator = float(np.sum(power[analysis_band])) + 1e-18
    hum_ratio = float(np.sum(power[analysis_band & harmonic_band])) / denominator
    selected = power[analysis_band] + 1e-24
    flatness = float(np.exp(np.mean(np.log(selected))) / np.mean(selected))
    return {
        "residual_rms_dbfs": round(
            20
            * math.log10(
                max(float(np.sqrt(np.mean(np.square(residual)))), 1e-12)
            ),
            3,
        ),
        "residual_50_60hz_harmonic_ratio": round(hum_ratio, 6),
        "residual_spectral_flatness_20_2000hz": round(flatness, 6),
    }


def reference_paths(
    experiment_root: Path, source_sample: str
) -> dict[str, Path]:
    prefix = experiment_root / "reference-candidates" / source_sample
    return {
        "atten6": prefix / "atten-6" / "reference-noisy.wav",
        "atten9": prefix / "atten-9" / "reference-noisy.wav",
        "atten9-pf002": prefix / "atten-9-pf002" / "reference-noisy.wav",
        "atten12": prefix / "atten-12" / "reference-noisy.wav",
        "atten18": prefix / "atten-18" / "reference-noisy.wav",
        "atten24": prefix / "atten-24" / "reference-noisy.wav",
        "atten100": prefix / "atten-100" / "reference-noisy.wav",
        "atten12-df-thresh-neg15": (
            prefix / "atten-12-df-thresh-neg15" / "reference-noisy.wav"
        ),
    }


def clone_paths(experiment_root: Path, sample: str) -> dict[str, Path]:
    short_name = "01-kitchen" if sample.startswith("01") else "04-meeting"
    first = experiment_root / "clone-candidates" / "labeled"
    extra = experiment_root / "clone-candidates-extra" / "labeled"
    return {
        "online": first / f"{short_name}-atten12" / "clone-online.wav",
        "clean": (
            experiment_root
            / "clone-clean-control-seed20260902"
            / "labeled"
            / short_name
            / "clone-deepfilter.wav"
        ),
        "atten6": first / f"{short_name}-atten6" / "clone-deepfilter.wav",
        "atten9": first / f"{short_name}-atten9" / "clone-deepfilter.wav",
        "atten9-pf002": (
            first / f"{short_name}-atten9-pf002" / "clone-deepfilter.wav"
        ),
        "atten12": first / f"{short_name}-atten12" / "clone-deepfilter.wav",
        "atten18": extra / f"{short_name}-atten18" / "clone-deepfilter.wav",
        "atten24": extra / f"{short_name}-atten24" / "clone-deepfilter.wav",
        "atten100": extra / f"{short_name}-atten100" / "clone-deepfilter.wav",
        "atten12-df-thresh-neg15": (
            extra / f"{short_name}-atten12-erb-only" / "clone-deepfilter.wav"
        ),
        "atten12-seed20365631": (
            experiment_root
            / "clone-atten12-seed20365631"
            / "labeled"
            / short_name
            / "clone-deepfilter.wav"
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment_root", type=Path)
    parser.add_argument("samples_root", type=Path)
    parser.add_argument("--worker-dir", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    validate_generated_wav = None
    if args.worker_dir:
        sys.path.insert(0, str(args.worker_dir))
        from clone_worker import validate_generated_wav as production_validator

        validate_generated_wav = production_validator

    records: list[dict[str, Any]] = []
    for short_name, source_sample in SAMPLES.items():
        source_dir = args.samples_root / source_sample
        clean, clean_rate = load_mono(source_dir / "reference-clean.wav")
        noisy, noisy_rate = load_mono(source_dir / "reference-noisy.wav")
        if clean_rate != noisy_rate:
            raise RuntimeError(f"sample-rate mismatch for {source_sample}")
        input_si_sdr = si_sdr(noisy, clean)
        references: dict[str, Any] = {
            "online": {
                "si_sdr_db": round(input_si_sdr, 3),
                "correlation_clean": round(correlation(noisy, clean), 6),
                **residual_tonality(noisy, clean, clean_rate),
            }
        }
        for variant, path in reference_paths(args.experiment_root, source_sample).items():
            audio, sample_rate = load_mono(path)
            output_si_sdr = si_sdr(audio, clean)
            references[variant] = {
                "si_sdr_db": round(output_si_sdr, 3),
                "si_sdr_improvement_db": round(output_si_sdr - input_si_sdr, 3),
                "correlation_clean": round(correlation(audio, clean), 6),
                **residual_tonality(audio, clean, sample_rate),
            }

        clones: dict[str, Any] = {}
        for variant, path in clone_paths(args.experiment_root, source_sample).items():
            audio, sample_rate = load_mono(path)
            item: dict[str, Any] = {
                "path": str(path.relative_to(args.experiment_root)),
                **signal_health(audio, sample_rate),
                **low_energy_artifact_metrics(audio, sample_rate),
            }
            if validate_generated_wav is not None:
                item["production_validator"] = validate_generated_wav(path.read_bytes())
            clones[variant] = item

        records.append(
            {
                "sample": short_name,
                "source_sample": source_sample,
                "references": references,
                "clones": clones,
            }
        )

    output = {
        "description": (
            "DeepFilterNet3 attenuation, stage and seed diagnostics for the two "
            "subjective electrical-noise regressions"
        ),
        "low_energy_definition": "80 ms window, 20 ms hop, -60 < RMS < -30 dBFS",
        "suspicious_frame_definition": (
            "low-energy frame with spectral flatness > 0.10 and >=6.5 kHz "
            "power ratio > 0.04"
        ),
        "records": records,
    }
    destination = args.output or args.experiment_root / "electrical-artifact-metrics.json"
    destination.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    for record in records:
        print(record["sample"])
        for variant, metrics in record["clones"].items():
            print(
                f"  {variant:28s} "
                f"flat={metrics['low_energy_median_flatness']} "
                f"high={metrics['low_energy_median_high_frequency_ratio']} "
                f"suspicious={100 * metrics['suspicious_fraction_all_frames']:.2f}%"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
