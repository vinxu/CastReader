#!/usr/bin/env python3
"""Run the CastReader reference-audio quality matrix on real WAV fixtures."""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
from scipy.io import wavfile

from audio_quality import ReferenceQualityError, process_reference_audio


EXPECTED = {
    "samantha.wav": "pass",
    "daniel.wav": "pass",
    "moderate-noise.wav": "pass",
    "heavy-noise.wav": "VOICE_REFERENCE_TOO_NOISY",
    "quiet.wav": "VOICE_REFERENCE_TOO_QUIET",
    "clipped.wav": "VOICE_REFERENCE_CLIPPING",
    "strong-reverb.wav": "pass",
    # Reverb is deliberately warning-first for guided iPhone recording. The
    # metric remains visible, while only repeated near-direct-level tails can
    # hard reject; this fixture should therefore create with room_echo_detected.
    "severe-reverb.wav": "pass",
    "two-speakers.wav": "VOICE_REFERENCE_MULTIPLE_SPEAKERS",
}


def read_audio(path: Path) -> tuple[np.ndarray, int]:
    sample_rate, audio = wavfile.read(path)
    if np.issubdtype(audio.dtype, np.integer):
        maximum = max(abs(np.iinfo(audio.dtype).min), np.iinfo(audio.dtype).max)
        audio = audio.astype(np.float32) / float(maximum)
    else:
        audio = audio.astype(np.float32)
    if audio.ndim == 2:
        audio = np.mean(audio, axis=1)
    return audio, int(sample_rate)


def validate(path: Path) -> dict[str, object]:
    audio, sample_rate = read_audio(path)
    started = time.perf_counter()
    try:
        result = process_reference_audio(audio, sample_rate)
        outcome = "pass"
        metrics = result.metrics
        warnings = result.warnings
    except ReferenceQualityError as error:
        outcome = error.code
        metrics = error.metrics
        warnings = []
    return {
        "fixture": path.name,
        "outcome": outcome,
        "expected": EXPECTED.get(path.name),
        "matches": outcome == EXPECTED.get(path.name),
        "elapsed_ms": round((time.perf_counter() - started) * 1000, 1),
        "warnings": warnings,
        "metrics": metrics,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture_dir", type=Path)
    args = parser.parse_args()
    results = [validate(args.fixture_dir / name) for name in EXPECTED]
    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0 if all(result["matches"] for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
