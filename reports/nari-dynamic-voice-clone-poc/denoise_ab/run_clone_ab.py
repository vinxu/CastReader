#!/usr/bin/env python3
"""Create paired temporary voices from online and DeepFilterNet references."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import time
import uuid
from pathlib import Path
from typing import Any

import httpx


ZH_PREVIEW = "这是一段声音克隆降噪对比。请仔细听声音是否清晰自然，音色是否真实稳定，以及背景噪音有没有被带入克隆结果。"
EN_PREVIEW = "This is a voice cloning noise reduction comparison. Please listen for clarity, naturalness, speaker identity, stability, and any background noise carried into the cloned result."
FIXED_SEED = 20260902


def wait_until_idle(client: httpx.Client, base_url: str) -> dict[str, Any]:
    for _ in range(120):
        response = client.get(f"{base_url}/health")
        response.raise_for_status()
        body = response.json()
        if not body.get("busy") and int(body.get("queue_depth", 0)) == 0:
            return body
        time.sleep(1)
    raise RuntimeError("clone worker did not become idle")


def create_voice(
    client: httpx.Client,
    base_url: str,
    token: str,
    voice_id: str,
    reference: Path,
    reference_text: str,
    language: str,
) -> dict[str, Any]:
    with reference.open("rb") as source:
        response = client.post(
            f"{base_url}/v1/voices",
            headers={
                "X-Clone-Token": token,
                "X-TTS-Priority": "background",
                "X-Request-ID": f"denoise-ab-create-{uuid.uuid4().hex}",
            },
            data={
                "consent_confirmed": "true",
                "requested_voice_id": voice_id,
                "reference_text": reference_text,
                "reference_language": language,
            },
            files={"reference": (reference.name, source, "audio/wav")},
        )
    if response.status_code != 200:
        detail: object
        try:
            detail = response.json()
        except ValueError:
            detail = response.text[:300]
        raise RuntimeError(f"create failed status={response.status_code} detail={detail}")
    return response.json()


def synthesize(
    client: httpx.Client,
    base_url: str,
    token: str,
    voice_id: str,
    language: str,
    seed: int,
) -> bytes:
    response = client.post(
        f"{base_url}/v1/speech",
        headers={
            "X-Clone-Token": token,
            "X-TTS-Priority": "background",
            "X-Request-ID": f"denoise-ab-speech-{uuid.uuid4().hex}",
        },
        json={
            "voice_id": voice_id,
            "text": ZH_PREVIEW if language == "zh" else EN_PREVIEW,
            "language_id": language,
            "seed": seed,
        },
    )
    response.raise_for_status()
    if len(response.content) < 1_000 or response.content[:4] != b"RIFF":
        raise RuntimeError("worker returned an invalid WAV response")
    return response.content


def delete_voice(client: httpx.Client, base_url: str, token: str, voice_id: str) -> None:
    response = client.delete(
        f"{base_url}/v1/voices/{voice_id}", headers={"X-Clone-Token": token}
    )
    if response.status_code not in {200, 204, 404}:
        response.raise_for_status()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("samples_manifest", type=Path)
    parser.add_argument("--deepfilter-results", type=Path, required=True)
    parser.add_argument("--base-url", default="http://127.0.0.1:18890")
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--pause-seconds", type=float, default=1.0)
    parser.add_argument("--fixed-seed", type=int, default=FIXED_SEED)
    args = parser.parse_args()

    token = args.token_file.read_text(encoding="utf-8").strip()
    if not token:
        raise RuntimeError("clone token file is empty")
    samples = json.loads(args.samples_manifest.read_text(encoding="utf-8"))
    deepfilter = json.loads(args.deepfilter_results.read_text(encoding="utf-8"))
    enhanced_by_id = {record["sample_id"]: record for record in deepfilter["records"]}
    sample_root = args.samples_manifest.parent
    args.output_dir.mkdir(parents=True, exist_ok=True)
    labeled_root = args.output_dir / "labeled"
    blind_root = args.output_dir / "blind"
    labeled_root.mkdir(exist_ok=True)
    blind_root.mkdir(exist_ok=True)

    run_id = uuid.uuid4().hex[:8]
    results: list[dict[str, object]] = []
    answer_key: dict[str, dict[str, str]] = {}
    with httpx.Client(timeout=180.0) as client:
        health_before = wait_until_idle(client, args.base_url)
        for index, record in enumerate(samples["records"], start=1):
            sample_id = str(record["sample_id"])
            enhanced_record = enhanced_by_id[sample_id]
            references = {
                "online": sample_root / str(record["reference_noisy"]),
                "deepfilter": sample_root / str(enhanced_record["reference_deepfilter"]),
            }
            labeled_dir = labeled_root / sample_id
            blind_dir = blind_root / sample_id
            labeled_dir.mkdir(parents=True, exist_ok=True)
            blind_dir.mkdir(parents=True, exist_ok=True)
            branch_results: dict[str, dict[str, object]] = {}
            for branch, reference in references.items():
                wait_until_idle(client, args.base_url)
                voice_id = f"vc_dab_{run_id}_{index:02d}_{branch[:2]}"
                created = False
                started = time.perf_counter()
                try:
                    metadata = create_voice(
                        client,
                        args.base_url,
                        token,
                        voice_id,
                        reference,
                        str(record["reference_text"]),
                        str(record["language"]),
                    )
                    created = True
                    wav = synthesize(
                        client,
                        args.base_url,
                        token,
                        voice_id,
                        str(record["language"]),
                        args.fixed_seed,
                    )
                    output_name = f"clone-{branch}.wav"
                    (labeled_dir / output_name).write_bytes(wav)
                    branch_results[branch] = {
                        "status": "ok",
                        "elapsed_s": round(time.perf_counter() - started, 3),
                        "audio": f"labeled/{sample_id}/{output_name}",
                        "audio_sha256": hashlib.sha256(wav).hexdigest(),
                        "reference_quality": metadata.get("reference_quality", {}),
                        "reference_quality_warnings": metadata.get(
                            "reference_quality_warnings", []
                        ),
                    }
                except Exception as error:
                    branch_results[branch] = {
                        "status": "failed",
                        "elapsed_s": round(time.perf_counter() - started, 3),
                        "error": f"{type(error).__name__}: {error}"[:500],
                    }
                finally:
                    if created:
                        delete_voice(client, args.base_url, token, voice_id)
                time.sleep(args.pause_seconds)

            if all(item["status"] == "ok" for item in branch_results.values()):
                labels = ["online", "deepfilter"]
                random.Random(f"{run_id}:{sample_id}").shuffle(labels)
                for blind_name, branch in zip(("A.wav", "B.wav"), labels):
                    source = labeled_dir / f"clone-{branch}.wav"
                    (blind_dir / blind_name).write_bytes(source.read_bytes())
                answer_key[sample_id] = {"A": labels[0], "B": labels[1]}
            results.append(
                {
                    "sample_id": sample_id,
                    "category": record["category"],
                    "language": record["language"],
                    "target_snr_db": record["target_snr_db"],
                    "branches": branch_results,
                }
            )
            print(
                f"ab_progress {index}/{len(samples['records'])} sample={sample_id} "
                f"online={branch_results['online']['status']} "
                f"deepfilter={branch_results['deepfilter']['status']}",
                flush=True,
            )
        health_after = wait_until_idle(client, args.base_url)

    (args.output_dir / "answer-key.json").write_text(
        json.dumps(answer_key, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    report = {
        "run_id": run_id,
        "fixed_seed": args.fixed_seed,
        "samples": len(results),
        "complete_pairs": sum(
            all(item["status"] == "ok" for item in result["branches"].values())
            for result in results
        ),
        "worker_before": health_before,
        "worker_after": health_after,
        "records": results,
    }
    (args.output_dir / "clone-ab-results.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return 0 if report["complete_pairs"] == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
