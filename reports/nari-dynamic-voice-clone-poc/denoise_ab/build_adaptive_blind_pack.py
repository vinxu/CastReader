#!/usr/bin/env python3
"""Build an active-speech gain-matched adaptive-vs-online blind pack."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import shutil
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_mono(path: Path) -> tuple[np.ndarray, int]:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    return np.mean(audio, axis=1, dtype=np.float32), sample_rate


def resample(audio: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate == target_rate:
        return audio
    divisor = math.gcd(source_rate, target_rate)
    return signal.resample_poly(
        audio, target_rate // divisor, source_rate // divisor
    ).astype(np.float32)


def active_rms_dbfs(
    audio: np.ndarray, sample_rate: int, model: object
) -> tuple[float, int, str]:
    import torch
    from silero_vad import get_speech_timestamps

    audio_16k = resample(audio, sample_rate, 16_000)
    timestamps = get_speech_timestamps(
        torch.from_numpy(audio_16k),
        model,
        sampling_rate=16_000,
        threshold=0.50,
        min_speech_duration_ms=180,
        min_silence_duration_ms=250,
        speech_pad_ms=80,
        return_seconds=False,
    )
    chunks = []
    for item in timestamps:
        begin = round(int(item["start"]) * sample_rate / 16_000)
        end = round(int(item["end"]) * sample_rate / 16_000)
        chunks.append(audio[max(0, begin) : min(audio.size, end)])
    chunks = [item for item in chunks if item.size]
    if chunks:
        selected = np.concatenate(chunks)
        method = "silero-vad"
    else:
        selected = audio
        method = "overall-rms-fallback"
    rms = float(np.sqrt(np.mean(np.square(selected, dtype=np.float64))))
    return 20 * math.log10(max(rms, 1e-12)), int(selected.size), method


def write_gain_matched(
    source: Path, destination: Path, gain_db: float
) -> dict[str, float | int | str]:
    audio, sample_rate = load_mono(source)
    gain = 10 ** (gain_db / 20.0)
    processed = np.clip(audio.astype(np.float64) * gain, -1.0, 1.0).astype(np.float32)
    destination.parent.mkdir(parents=True, exist_ok=True)
    sf.write(destination, processed, sample_rate, subtype="PCM_16")
    return {
        "gain_db": round(gain_db, 4),
        "sample_rate": sample_rate,
        "peak_after": round(float(np.max(np.abs(processed))), 6),
        "clipping_ratio_after": round(float(np.mean(np.abs(processed) >= 0.999)), 8),
        "sha256": sha256(destination),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("selection", type=Path)
    parser.add_argument("clone_24_dir", type=Path)
    parser.add_argument("clone_100_dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--blind-seed", default="adaptive-24-100-20260903")
    args = parser.parse_args()

    from silero_vad import load_silero_vad

    model = load_silero_vad(onnx=True)
    selection = json.loads(args.selection.read_text(encoding="utf-8"))
    selection_records = selection["records"]
    blind_assignments: dict[str, list[str]] = {}
    for record in selection_records:
        sample_id = str(record["sample_id"])
        labels = ["online", "adaptive"]
        random.Random(f"{args.blind_seed}:{sample_id}").shuffle(labels)
        blind_assignments[sample_id] = labels

    # Pairwise shuffling can be globally lopsided by chance.  Keep the process
    # deterministic while forcing an even pack to have exactly half of its
    # adaptive files under A and half under B.
    target_adaptive_in_a = len(blind_assignments) // 2
    adaptive_in_a = sum(labels[0] == "adaptive" for labels in blind_assignments.values())
    if adaptive_in_a != target_adaptive_in_a:
        branch_to_flip = "adaptive" if adaptive_in_a > target_adaptive_in_a else "online"
        flip_count = abs(adaptive_in_a - target_adaptive_in_a)
        pool = sorted(
            (
                sample_id
                for sample_id, labels in blind_assignments.items()
                if labels[0] == branch_to_flip
            ),
            key=lambda sample_id: hashlib.sha256(
                f"balance:{args.blind_seed}:{sample_id}".encode("utf-8")
            ).hexdigest(),
        )
        for sample_id in pool[:flip_count]:
            blind_assignments[sample_id].reverse()
    adaptive_in_a = sum(labels[0] == "adaptive" for labels in blind_assignments.values())
    if adaptive_in_a != target_adaptive_in_a:
        raise RuntimeError(
            f"could not balance blind labels: {adaptive_in_a=} {target_adaptive_in_a=}"
        )

    labeled_root = args.output_dir / "labeled-raw"
    blind_root = args.output_dir / "blind-gain-matched"
    records = []
    answer_key = {}
    for record in selection_records:
        sample_id = str(record["sample_id"])
        selected = str(record["selected"])
        online = args.clone_24_dir / "labeled" / sample_id / "clone-online.wav"
        if selected == "atten24":
            adaptive = (
                args.clone_24_dir / "labeled" / sample_id / "clone-deepfilter.wav"
            )
        elif selected == "atten100":
            adaptive = (
                args.clone_100_dir / "labeled" / sample_id / "clone-deepfilter.wav"
            )
        elif selected == "online":
            adaptive = online
        else:
            raise RuntimeError(f"unsupported selection {selected!r}")

        labeled_dir = labeled_root / sample_id
        labeled_dir.mkdir(parents=True, exist_ok=True)
        raw_paths = {
            "online": labeled_dir / "online.wav",
            "adaptive": labeled_dir / "adaptive.wav",
        }
        shutil.copy2(online, raw_paths["online"])
        shutil.copy2(adaptive, raw_paths["adaptive"])

        online_audio, online_rate = load_mono(online)
        adaptive_audio, adaptive_rate = load_mono(adaptive)
        online_rms, online_active_samples, online_method = active_rms_dbfs(
            online_audio, online_rate, model
        )
        adaptive_rms, adaptive_active_samples, adaptive_method = active_rms_dbfs(
            adaptive_audio, adaptive_rate, model
        )
        target_rms = min(online_rms, adaptive_rms)
        gains = {
            "online": target_rms - online_rms,
            "adaptive": target_rms - adaptive_rms,
        }

        matched_dir = args.output_dir / "gain-matched-labeled" / sample_id
        matched_paths = {
            branch: matched_dir / f"{branch}.wav" for branch in ("online", "adaptive")
        }
        outputs = {
            branch: write_gain_matched(raw_paths[branch], matched_paths[branch], gains[branch])
            for branch in ("online", "adaptive")
        }
        post_rms = {}
        for branch in ("online", "adaptive"):
            audio, rate = load_mono(matched_paths[branch])
            value, count, method = active_rms_dbfs(audio, rate, model)
            post_rms[branch] = {
                "active_rms_dbfs": round(value, 4),
                "active_sample_count": count,
                "method": method,
            }
        difference = abs(
            post_rms["online"]["active_rms_dbfs"]
            - post_rms["adaptive"]["active_rms_dbfs"]
        )
        if difference > 0.2:
            raise RuntimeError(
                f"active RMS mismatch {difference:.3f} dB for {sample_id}"
            )

        labels = blind_assignments[sample_id]
        blind_dir = blind_root / sample_id
        blind_dir.mkdir(parents=True, exist_ok=True)
        sample_key = {}
        blind_outputs = {}
        for blind_label, branch in zip(("A", "B"), labels):
            destination = blind_dir / f"{blind_label}.wav"
            shutil.copy2(matched_paths[branch], destination)
            sample_key[blind_label] = branch
            blind_outputs[blind_label] = {
                "branch": branch,
                "path": str(destination.relative_to(args.output_dir)),
                "sha256": sha256(destination),
            }
        answer_key[sample_id] = sample_key
        records.append(
            {
                "sample_id": sample_id,
                "selected_adaptive_branch": selected,
                "raw": {
                    branch: {
                        "path": str(raw_paths[branch].relative_to(args.output_dir)),
                        "sha256": sha256(raw_paths[branch]),
                    }
                    for branch in ("online", "adaptive")
                },
                "pre_match": {
                    "online_active_rms_dbfs": round(online_rms, 4),
                    "adaptive_active_rms_dbfs": round(adaptive_rms, 4),
                    "online_active_sample_count": online_active_samples,
                    "adaptive_active_sample_count": adaptive_active_samples,
                    "online_method": online_method,
                    "adaptive_method": adaptive_method,
                },
                "applied": outputs,
                "post_match": {
                    **post_rms,
                    "absolute_difference_db": round(difference, 4),
                },
                "blind": blind_outputs,
            }
        )
        print(
            f"blind_pack {sample_id} selected={selected} "
            f"gain_online={gains['online']:+.3f}dB "
            f"gain_adaptive={gains['adaptive']:+.3f}dB "
            f"post_diff={difference:.3f}dB",
            flush=True,
        )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "answer-key.json").write_text(
        json.dumps(answer_key, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (args.output_dir / "gain-manifest.json").write_text(
        json.dumps(
            {
                "fixed_synthesis_seed": selection["fixed_seed"],
                "active_speech_gain_matching": True,
                "target": "quieter side in each pair; attenuation only",
                "blind_randomization": {
                    "seed": args.blind_seed,
                    "method": "pairwise deterministic shuffle, then deterministic global rebalance",
                    "adaptive_in_A": adaptive_in_a,
                    "adaptive_in_B": len(blind_assignments) - adaptive_in_a,
                },
                "records": records,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
