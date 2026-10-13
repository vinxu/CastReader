#!/usr/bin/env python3
"""Select raw/DeepFilterNet 24/100 without using a clean-reference oracle."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf
from scipy import signal

from analyze_electrical_artifacts import low_energy_artifact_metrics


def load_mono_16k(path: Path) -> np.ndarray:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    mono = np.mean(audio, axis=1, dtype=np.float32)
    if sample_rate != 16_000:
        divisor = math.gcd(sample_rate, 16_000)
        mono = signal.resample_poly(
            mono, 16_000 // divisor, sample_rate // divisor
        ).astype(np.float32)
    return mono


def load_native(path: Path) -> tuple[np.ndarray, int]:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    return np.mean(audio, axis=1, dtype=np.float32), sample_rate


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("samples_manifest", type=Path)
    parser.add_argument("clone_24_dir", type=Path)
    parser.add_argument("clone_100_dir", type=Path)
    parser.add_argument("prompt_metrics", type=Path)
    parser.add_argument("--worker-dir", type=Path, required=True)
    parser.add_argument("--speaker-model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    os.environ["CLONE_SPEAKER_MODEL"] = str(args.speaker_model)
    sys.path.insert(0, str(args.worker_dir))
    from audio_quality import SpeakerConsistencyInspector
    from clone_worker import validate_generated_wav

    inspector = SpeakerConsistencyInspector(str(args.speaker_model))
    manifest = json.loads(args.samples_manifest.read_text(encoding="utf-8"))
    samples_root = args.samples_manifest.parent
    run24 = json.loads((args.clone_24_dir / "clone-ab-results.json").read_text())
    run100 = json.loads((args.clone_100_dir / "clone-ab-results.json").read_text())
    result24 = {item["sample_id"]: item for item in run24["records"]}
    result100 = {item["sample_id"]: item for item in run100["records"]}
    prompt = json.loads(args.prompt_metrics.read_text(encoding="utf-8"))
    prompt_by_id = {item["sample_id"]: item for item in prompt["records"]}

    records: list[dict[str, Any]] = []
    for sample in manifest["records"]:
        sample_id = str(sample["sample_id"])
        raw_reference = samples_root / str(sample["reference_noisy"])
        paths = {
            "online": args.clone_24_dir / "labeled" / sample_id / "clone-online.wav",
            "atten24": (
                args.clone_24_dir / "labeled" / sample_id / "clone-deepfilter.wav"
            ),
            "atten100": (
                args.clone_100_dir / "labeled" / sample_id / "clone-deepfilter.wav"
            ),
        }
        online_other = (
            args.clone_100_dir / "labeled" / sample_id / "clone-online.wav"
        )
        online_hash_match = sha256(paths["online"]) == sha256(online_other)

        raw_embedding = inspector._embedding(load_mono_16k(raw_reference))
        embeddings = {
            name: inspector._embedding(load_mono_16k(path))
            for name, path in paths.items()
        }
        if raw_embedding is None or any(value is None for value in embeddings.values()):
            raise RuntimeError(f"CampPlus embedding unavailable for {sample_id}")
        identity = {
            name: round(float(np.dot(raw_embedding, embedding)), 6)
            for name, embedding in embeddings.items()
        }

        electrical = {}
        validators = {}
        for name, path in paths.items():
            audio, sample_rate = load_native(path)
            electrical[name] = low_energy_artifact_metrics(audio, sample_rate)
            validators[name] = validate_generated_wav(path.read_bytes())

        raw_quality = result24[sample_id]["branches"]["online"][
            "reference_quality"
        ]
        quality24 = result24[sample_id]["branches"]["deepfilter"][
            "reference_quality"
        ]
        quality100 = result100[sample_id]["branches"]["deepfilter"][
            "reference_quality"
        ]
        prompt_variants = prompt_by_id[sample_id]["variants"]

        raw_min_speaker = raw_quality.get("min_speaker_similarity")
        baseline_identity = identity["online"]
        eligibility = {}
        for name, quality in (("atten24", quality24), ("atten100", quality100)):
            candidate_min_speaker = quality.get("min_speaker_similarity")
            prompt_similarity = float(
                prompt_variants[name]["cosine_to_online_prompt"]
            )
            electrical_confident = (
                int(electrical[name]["low_energy_frame_count"]) >= 30
            )
            prompt_guard = prompt_similarity >= 0.90
            reference_speaker_guard = (
                raw_min_speaker is not None
                and candidate_min_speaker is not None
                and float(candidate_min_speaker) >= float(raw_min_speaker) - 0.05
            )
            campplus_guard = identity[name] >= baseline_identity - 0.05
            eligibility[name] = {
                "eligible": bool(
                    electrical_confident
                    and prompt_guard
                    and reference_speaker_guard
                    and campplus_guard
                ),
                "electrical_confident": electrical_confident,
                "prompt_guard": prompt_guard,
                "reference_speaker_guard": reference_speaker_guard,
                "probe_campplus_guard": campplus_guard,
                "qwen_prompt_cosine_to_online": prompt_similarity,
                "reference_min_speaker_similarity": candidate_min_speaker,
                "probe_campplus_to_raw_reference": identity[name],
            }

        score = {
            name: float(values["suspicious_fraction_all_frames"])
            for name, values in electrical.items()
        }
        reasons = []
        if eligibility["atten24"]["eligible"]:
            selected = "atten24"
            reasons.append("default-atten24")
            if (
                eligibility["atten100"]["eligible"]
                and score["atten100"] <= score["atten24"] - 0.020
            ):
                selected = "atten100"
                reasons.append("atten100-electrical-improvement-at-least-0.020")
        elif eligibility["atten100"]["eligible"]:
            selected = "atten100"
            reasons.append("atten24-ineligible-atten100-eligible")
        else:
            selected = "online"
            reasons.append("both-enhanced-candidates-ineligible")

        if selected != "online" and score[selected] >= score["online"] + 0.020:
            reasons.append("enhanced-electrical-score-worse-than-raw-by-0.020")
            selected = "online"

        records.append(
            {
                "sample_id": sample_id,
                "selected": selected,
                "reasons": reasons,
                "online_hash_match_between_runs": online_hash_match,
                "electrical": electrical,
                "probe_campplus_to_raw_reference": identity,
                "reference_quality": {
                    "online": raw_quality,
                    "atten24": quality24,
                    "atten100": quality100,
                },
                "eligibility": eligibility,
                "production_output_validator": validators,
                "source_paths": {name: str(path) for name, path in paths.items()},
                "source_sha256": {name: sha256(path) for name, path in paths.items()},
            }
        )
        print(
            f"adaptive {sample_id} selected={selected} "
            f"Eraw={score['online']:.4f} E24={score['atten24']:.4f} "
            f"E100={score['atten100']:.4f} low="
            f"{electrical['online']['low_energy_frame_count']}/"
            f"{electrical['atten24']['low_energy_frame_count']}/"
            f"{electrical['atten100']['low_energy_frame_count']} "
            f"I={identity['online']:.4f}/{identity['atten24']:.4f}/"
            f"{identity['atten100']:.4f}",
            flush=True,
        )

    output = {
        "selector": {
            "version": "adaptive-24-100-shadow-v1",
            "oracle_free": True,
            "default_enhanced_candidate": "atten24",
            "atten100_upgrade_rule": "E100 <= E24 - 0.020",
            "raw_fallback_rule": "Eselected >= Eraw + 0.020",
            "minimum_low_energy_frames": 30,
            "qwen_prompt_cosine_floor": 0.90,
            "reference_min_speaker_relative_floor": "candidate >= online - 0.05",
            "probe_campplus_relative_floor": "candidate >= online - 0.05",
            "clean_oracle_used": False,
        },
        "fixed_seed": run24["fixed_seed"],
        "records": records,
    }
    args.output.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
