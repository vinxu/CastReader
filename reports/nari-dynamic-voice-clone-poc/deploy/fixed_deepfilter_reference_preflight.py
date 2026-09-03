#!/usr/bin/env python3
"""Exercise fixed DeepFilter preprocessing without writing production voices."""

from __future__ import annotations

import argparse
import json
import tempfile
import threading
import time
from pathlib import Path

import soundfile as sf

from adaptive_denoise import (
    DEFAULT_DEEPFILTER_SHA256,
    DEFAULT_DIARIZATION_SHA256,
    DEFAULT_SPEAKER_SHA256,
    RELATIVE_SPEAKER_FLOOR,
    DeepFilterRunner,
    SpeakerDiarizer,
)
from audio_quality import SpeakerConsistencyInspector, process_reference_audio


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--segmentation-model", required=True, type=Path)
    parser.add_argument("--speaker-model", required=True, type=Path)
    parser.add_argument("samples", nargs="+", type=Path)
    args = parser.parse_args()
    speaker_inspector = SpeakerConsistencyInspector(str(args.speaker_model))
    runner = DeepFilterRunner(args.binary, DEFAULT_DEEPFILTER_SHA256)
    diarizer = SpeakerDiarizer(
        args.segmentation_model,
        args.speaker_model,
        cluster_threshold=0.30,
        expected_segmentation_sha256=DEFAULT_DIARIZATION_SHA256,
        expected_embedding_sha256=DEFAULT_SPEAKER_SHA256,
    )
    if not runner.status()["ready"]:
        raise RuntimeError("DeepFilter dependency is not ready")
    diarizer.warmup()
    records = []
    for sample in args.samples:
        audio, rate = sf.read(sample, dtype="float32", always_2d=True)
        started = time.monotonic()
        original = process_reference_audio(audio, rate, speaker_inspector=speaker_inspector)
        diarization = diarizer.inspect(audio, rate).as_metrics()
        if diarization.get("competing_speech") is True:
            raise RuntimeError(f"{sample.name}: multiple speakers detected")
        with tempfile.TemporaryDirectory(prefix="fixed-df-preflight-") as work:
            enhanced, enhanced_rate, elapsed = runner.enhance(
                audio,
                rate,
                attenuation_db=24,
                work_dir=Path(work),
                deadline_at=time.monotonic() + 30,
                cancelled=threading.Event(),
            )
            cleaned = process_reference_audio(
                enhanced, enhanced_rate, speaker_inspector=speaker_inspector
            )
        baseline = original.metrics.get("min_speaker_similarity")
        candidate = cleaned.metrics.get("min_speaker_similarity")
        comparable = baseline is not None and candidate is not None
        guard_passed = not comparable or candidate >= baseline - RELATIVE_SPEAKER_FLOOR
        if not guard_passed:
            raise RuntimeError(f"{sample.name}: relative speaker guard failed")
        record = {
            "sample": sample.name,
            "selected": "atten24",
            "deepfilter_applied": True,
            "deepfilter_elapsed_s": round(elapsed, 4),
            "total_preprocess_s": round(time.monotonic() - started, 4),
            "reference_duration_s": round(cleaned.duration_seconds, 4),
            "original_snr_db": original.metrics.get("snr_db"),
            "cleaned_snr_db": cleaned.metrics.get("snr_db"),
            "speaker_guard_comparable": comparable,
            "speaker_guard_passed": guard_passed,
            "original_min_speaker_similarity": baseline,
            "cleaned_min_speaker_similarity": candidate,
            "diarization": diarization,
        }
        records.append(record)
        print(json.dumps(record, ensure_ascii=False), flush=True)
    print(json.dumps({"status": "passed", "samples": len(records)}), flush=True)


if __name__ == "__main__":
    main()
