#!/usr/bin/env python3
"""Compare the exact 1024-D Qwen speaker prompts produced by denoise variants."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import time
import uuid
from pathlib import Path
from typing import Any

import httpx
import numpy as np
import torch


SAMPLES = {
    "01-kitchen": {
        "source": "01-indoor-kitchen",
        "language": "zh",
        "text": "今天我们继续测试声音克隆。请保持自然、清晰和稳定的语气，让每一个字都容易听懂。",
    },
    "04-meeting": {
        "source": "04-indoor-meeting-room",
        "language": "en",
        "text": "Today we are testing voice cloning with a clear, natural, and steady speaking style for every sentence.",
    },
}


def reference_paths(
    experiment_root: Path, samples_root: Path, source: str
) -> dict[str, Path]:
    candidate = experiment_root / "reference-candidates" / source
    source_root = samples_root / source
    return {
        "online": source_root / "reference-noisy.wav",
        "clean": source_root / "reference-clean.wav",
        "atten6": candidate / "atten-6" / "reference-noisy.wav",
        "atten9": candidate / "atten-9" / "reference-noisy.wav",
        "atten9-pf002": candidate / "atten-9-pf002" / "reference-noisy.wav",
        "atten12": candidate / "atten-12" / "reference-noisy.wav",
        "atten18": candidate / "atten-18" / "reference-noisy.wav",
        "atten24": candidate / "atten-24" / "reference-noisy.wav",
        "atten100": candidate / "atten-100" / "reference-noisy.wav",
        "atten12-df-thresh-neg15": (
            candidate / "atten-12-df-thresh-neg15" / "reference-noisy.wav"
        ),
    }


def wait_until_idle(client: httpx.Client, base_url: str) -> dict[str, Any]:
    for _ in range(120):
        response = client.get(f"{base_url}/health")
        response.raise_for_status()
        body = response.json()
        if not body.get("busy") and int(body.get("queue_depth", 0)) == 0:
            return body
        time.sleep(0.25)
    raise RuntimeError("clone worker did not become idle")


def create_prompt(
    client: httpx.Client,
    base_url: str,
    token: str,
    voice_id: str,
    reference: Path,
    reference_text: str,
    language: str,
) -> tuple[np.ndarray, dict[str, Any], str]:
    created = False
    try:
        with reference.open("rb") as source:
            response = client.post(
                f"{base_url}/v1/voices",
                headers={
                    "X-Clone-Token": token,
                    "X-TTS-Priority": "background",
                    "X-Request-ID": f"denoise-prompt-create-{uuid.uuid4().hex}",
                },
                data={
                    "consent_confirmed": "true",
                    "requested_voice_id": voice_id,
                    "reference_text": reference_text,
                    "reference_language": language,
                },
                files={"reference": (reference.name, source, "audio/wav")},
            )
        response.raise_for_status()
        metadata = response.json()
        created = True
        prompt_response = client.get(
            f"{base_url}/v1/voices/{voice_id}/prompt",
            headers={"X-Clone-Token": token},
        )
        prompt_response.raise_for_status()
        prompt_bytes = prompt_response.content
        prompt = torch.load(io.BytesIO(prompt_bytes), map_location="cpu", weights_only=True)
        embedding = prompt.get("ref_spk_embedding") if isinstance(prompt, dict) else None
        if not isinstance(embedding, torch.Tensor) or embedding.numel() != 1024:
            raise RuntimeError("exported prompt did not contain a 1024-D speaker embedding")
        vector = embedding.detach().float().reshape(-1).numpy().astype(np.float64)
        norm = float(np.linalg.norm(vector))
        if not np.isfinite(vector).all() or norm <= 0:
            raise RuntimeError("exported speaker embedding was invalid")
        return vector / norm, metadata, hashlib.sha256(prompt_bytes).hexdigest()
    finally:
        if created:
            response = client.delete(
                f"{base_url}/v1/voices/{voice_id}",
                headers={"X-Clone-Token": token},
            )
            if response.status_code not in {200, 204, 404}:
                response.raise_for_status()


def cosine(left: np.ndarray, right: np.ndarray) -> float:
    return float(np.dot(left, right))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment_root", type=Path)
    parser.add_argument("samples_root", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:18890")
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    token = args.token_file.read_text(encoding="utf-8").strip()
    if not token:
        raise RuntimeError("clone token file is empty")
    all_records: list[dict[str, Any]] = []
    with httpx.Client(timeout=180.0) as client:
        health_before = wait_until_idle(client, args.base_url)
        for sample_index, (sample, config) in enumerate(SAMPLES.items(), start=1):
            vectors: dict[str, np.ndarray] = {}
            metadata: dict[str, Any] = {}
            hashes: dict[str, str] = {}
            for variant_index, (variant, reference) in enumerate(
                reference_paths(
                    args.experiment_root, args.samples_root, str(config["source"])
                ).items(),
                start=1,
            ):
                wait_until_idle(client, args.base_url)
                voice_id = (
                    f"vc_dpe_{uuid.uuid4().hex[:8]}_{sample_index:02d}_{variant_index:02d}"
                )
                vector, voice_metadata, prompt_hash = create_prompt(
                    client,
                    args.base_url,
                    token,
                    voice_id,
                    reference,
                    str(config["text"]),
                    str(config["language"]),
                )
                vectors[variant] = vector
                metadata[variant] = {
                    "reference_quality": voice_metadata.get("reference_quality", {}),
                    "prompt_sha256": prompt_hash,
                }

            comparisons: dict[str, Any] = {}
            for variant, vector in vectors.items():
                comparisons[variant] = {
                    "cosine_to_online": round(cosine(vector, vectors["online"]), 6),
                    "cosine_to_clean": round(cosine(vector, vectors["clean"]), 6),
                    "cosine_to_atten12": round(cosine(vector, vectors["atten12"]), 6),
                    **metadata[variant],
                }
            all_records.append({"sample": sample, "variants": comparisons})
        health_after = wait_until_idle(client, args.base_url)

    output = {
        "metric": "cosine similarity of exact normalized 1024-D Qwen ref_spk_embedding",
        "worker_before": health_before,
        "worker_after": health_after,
        "records": all_records,
    }
    destination = args.output or args.experiment_root / "prompt-embedding-metrics.json"
    destination.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    for record in all_records:
        print(record["sample"])
        for variant, metrics in record["variants"].items():
            print(
                f"  {variant:28s} "
                f"online={metrics['cosine_to_online']:.6f} "
                f"clean={metrics['cosine_to_clean']:.6f}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
