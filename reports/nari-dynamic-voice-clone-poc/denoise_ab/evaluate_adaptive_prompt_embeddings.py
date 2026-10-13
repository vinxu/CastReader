#!/usr/bin/env python3
"""Measure raw/24/100 Qwen speaker-prompt consistency without a clean oracle."""

from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

import httpx

from evaluate_prompt_embeddings import cosine, create_prompt, wait_until_idle


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("samples_manifest", type=Path)
    parser.add_argument("candidate_root", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:18890")
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    token = args.token_file.read_text(encoding="utf-8").strip()
    if not token:
        raise RuntimeError("clone token file is empty")
    manifest = json.loads(args.samples_manifest.read_text(encoding="utf-8"))
    samples_root = args.samples_manifest.parent
    records: list[dict[str, object]] = []
    with httpx.Client(timeout=180.0) as client:
        health_before = wait_until_idle(client, args.base_url)
        for index, sample in enumerate(manifest["records"], start=1):
            sample_id = str(sample["sample_id"])
            references = {
                "online": samples_root / str(sample["reference_noisy"]),
                "atten24": (
                    args.candidate_root
                    / sample_id
                    / "atten-24"
                    / "reference-noisy.wav"
                ),
                "atten100": (
                    args.candidate_root
                    / sample_id
                    / "atten-100"
                    / "reference-noisy.wav"
                ),
            }
            vectors = {}
            metadata = {}
            for variant_index, (variant, reference) in enumerate(
                references.items(), start=1
            ):
                wait_until_idle(client, args.base_url)
                voice_id = (
                    f"vc_daps_{uuid.uuid4().hex[:8]}_{index:02d}_{variant_index:02d}"
                )
                vector, voice_metadata, prompt_hash = create_prompt(
                    client,
                    args.base_url,
                    token,
                    voice_id,
                    reference,
                    str(sample["reference_text"]),
                    str(sample["language"]),
                )
                vectors[variant] = vector
                metadata[variant] = {
                    "prompt_sha256": prompt_hash,
                    "reference_quality": voice_metadata.get("reference_quality", {}),
                }
            variants = {}
            for variant, vector in vectors.items():
                variants[variant] = {
                    "cosine_to_online_prompt": round(
                        cosine(vector, vectors["online"]), 6
                    ),
                    **metadata[variant],
                }
            records.append({"sample_id": sample_id, "variants": variants})
            print(
                f"prompt_metric {index}/{len(manifest['records'])} "
                f"sample={sample_id} "
                f"atten24={variants['atten24']['cosine_to_online_prompt']:.6f} "
                f"atten100={variants['atten100']['cosine_to_online_prompt']:.6f}",
                flush=True,
            )
        health_after = wait_until_idle(client, args.base_url)

    args.output.write_text(
        json.dumps(
            {
                "metric": "cosine similarity of normalized 1024-D Qwen ref_spk_embedding",
                "oracle_free": True,
                "worker_before": health_before,
                "worker_after": health_after,
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
