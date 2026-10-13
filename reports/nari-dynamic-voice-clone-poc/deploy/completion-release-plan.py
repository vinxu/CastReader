#!/usr/bin/env python3
"""Source manifest and isolated launch plan; NEVER installs or deploys.

stdout is a plan, not an authorization receipt. The caller must separately bind
verified pre/post off-host backups, dependency digests, capacity admission and
the reviewed immutable source commit. No SSH, subprocess or network is used.
Default is read-only; --archive explicitly creates a new local source/test tar.
Source/data/caches are isolated; existing runtime assets are read-only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import io
import tarfile
from pathlib import Path, PurePosixPath


REGIONS = {
    "us": {
        "base": "/workspace/castreader-clone",
        "nari": "/workspace/nari-qwen3-tts-clean",
        "model": "/workspace/qwen3-tts-base/model-0.6b-base",
        "python": "/workspace/nari-qwen3-tts-clean/venv/bin/python",
        "old_worker": 8890, "old_nari": 8094, "worker": 18990, "new_nari": 18095,
        "source_config": "/workspace/nari-qwen3-tts-clean/rtx4090-single.yaml",
        "private_base": "/workspace/castreader-clone-completion",
        "queue": "64", "synthesis_timeout": "45", "nari_timeout": "30",
    },
    "cn": {
        "base": "/root/autodl-tmp/nari-staging",
        "nari": "/root/autodl-tmp/nari-staging/nari-qwen3-tts",
        "model": "/root/autodl-tmp/nari-staging/model-0.6b-base",
        "python": "/root/autodl-tmp/nari-staging/venv/bin/python",
        "old_worker": 18890, "old_nari": 18094, "worker": 28890, "new_nari": 28095,
        "source_config": "/root/autodl-tmp/nari-staging/deploy/rtx4090-single.yaml",
        "private_base": "/root/autodl-tmp/clone-completion",
        "queue": "32", "synthesis_timeout": "60", "nari_timeout": "45",
    },
}
CONFIG_SHA256 = "9ba01129b7f083572bd66feb07b476d3ef1075076c291b6fcd64fd4df703d89e"


def source_manifest(source_root: Path) -> dict[str, str]:
    source_root = source_root.resolve(strict=True)
    selected = sorted([
        *source_root.joinpath("worker").glob("*.py"),
        *source_root.joinpath("worker").glob("requirements*.txt"),
        *source_root.joinpath("nari-qwen3-tts/src").rglob("*.py"),
        *source_root.joinpath("nari-qwen3-tts/src").rglob("*.yaml"),
        source_root / "nari-qwen3-tts/pyproject.toml",
    ])
    result = {}
    for path in selected:
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(source_root):
            raise ValueError("source manifest cannot include symlinks, missing files or outside paths")
        relative = path.relative_to(source_root).as_posix()
        if "__pycache__" in path.parts:
            continue
        result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    for required in [
        "worker/clone_worker.py", "worker/nari_completion_client.py",
        "worker/inference_scheduler.py", "worker/request_coalescer.py",
        "worker/adaptive_denoise.py", "worker/audio_quality.py", "worker/build_prompt.py",
        "worker/semantic_asr.py", "worker/xvector_activation.py",
        "nari-qwen3-tts/src/nari_qwen3_tts/completion_protocol.py",
        "nari-qwen3-tts/src/nari_qwen3_tts/api/app.py",
    ]:
        if required not in result:
            raise ValueError("incomplete coordinated worker/Nari source tree: " + required)
    return result


def build_plan(source_root: Path, region: str, release_id: str) -> dict[str, object]:
    if region not in REGIONS:
        raise ValueError("unsupported region")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{5,79}", release_id):
        raise ValueError("invalid immutable release ID")
    config = REGIONS[region]
    private = PurePosixPath(config["private_base"])
    release = private / "releases" / release_id
    state = private / "state" / release_id
    base = PurePosixPath(config["base"])
    quality = base / "quality"
    source = source_manifest(source_root)
    source_hash = hashlib.sha256(json.dumps(source, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    common_env = {
        "PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
        "HF_HOME": str(state / "cache/huggingface"),
        "TORCH_HOME": str(state / "cache/torch"),
        "TORCHINDUCTOR_CACHE_DIR": str(state / "cache/torchinductor"),
        "TRITON_CACHE_DIR": str(state / "cache/triton"),
        "NARI_VOICE_PROMPT_ROOT": str(state / "voices"),
    }
    worker_env = {
        **common_env,
        "CLONE_DATA_ROOT": str(state), "CLONE_TOKEN_FILE": str(state / ".api-token"),
        "CLONE_XVECTOR_WRITER_MARKER": str(state / ".xvector-writer-v1-enabled"),
        "NARI_MODEL_DIR": config["model"], "NARI_URL": f"http://127.0.0.1:{config['new_nari']}",
        "PYTHONPATH": f"{release}/worker:{release}/nari-qwen3-tts/src:{quality}/deps",
        "LD_LIBRARY_PATH": str(quality / "lib"),
        "CLONE_SPEAKER_MODEL": str(quality / "models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"),
        "CLONE_DIARIZATION_MODEL": str(quality / "models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"),
        "CLONE_DEEPFILTER_BIN": str(base / "denoise/bin/deep-filter"),
        "CLONE_DEEPFILTER_SHA256": "70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da",
        "CLONE_DIARIZATION_SHA256": "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
        "CLONE_SPEAKER_MODEL_SHA256": "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11",
        "CLONE_MAX_QUEUE_SIZE": config["queue"],
        "CLONE_SYNTHESIS_TIMEOUT_SECONDS": config["synthesis_timeout"],
        "NARI_REQUEST_TIMEOUT_SECONDS": config["nari_timeout"],
        "CLONE_VOICE_BUILD_TIMEOUT_SECONDS": "75",
        "CLONE_WARMUP": "0", "CLONE_DENOISE_WARMUP": "0", "CLONE_ASR_WARMUP": "0",
    }
    return {
        "schema": "clone-completion-isolated-plan-v1",
        "region": region, "release_id": release_id,
        "production_mutation_allowed": False,
        "source_files_sha256": source, "source_tree_sha256": source_hash,
        "release_root": str(release), "state_root": str(state),
        "protected": {
            "worker_port": config["old_worker"], "nari_port": config["old_nari"], "kokoro_port": 8880,
            "worker_root": str(base / ("app" if region == "us" else "worker")),
            "nari_root": config["nari"],
            "prompt_root": str(base / ("voices" if region == "us" else "clone/voices")),
            "do_not_restart": ["castreader-clone", "castreader-nari-base", "castreader-tts", "caddy", "CN existing watchdog"],
        },
        "required_read_only_assets": {
            "model": config["model"], "quality": str(quality), "deepfilter": str(base / "denoise"),
            "python": config["python"],
            "engine_config_source": config["source_config"], "engine_config_sha256": CONFIG_SHA256,
            "engine_config_candidate_copy": str(release / "config/rtx4090-single.yaml"),
        },
        "worker": {
            "environment": worker_env,
            "argv": [config["python"], "-m", "uvicorn", "clone_worker:app", "--app-dir", str(release / "worker"),
                     "--host", "127.0.0.1", "--port", str(config["worker"]), "--workers", "1", "--log-level", "info"],
        },
        "nari": {
            "environment": {**common_env, "PYTHONPATH": str(release / "nari-qwen3-tts/src")},
            "argv": [config["python"], "-m", "nari_qwen3_tts.serve", "--model", config["model"],
                     "--local-files-only", "--allow-non-h100", "--engine-config", str(release / "config/rtx4090-single.yaml"),
                     "--max-active-requests", "1", "--host", "127.0.0.1", "--port", str(config["new_nari"])],
        },
        "gates": [
            "root-approved exact source commit plus source tree SHA (dirty local plan is not publishable)",
            "region-specific full pre-change off-host private backup with complete SHA readback verified=true",
            "bind actual dependency/environment/native-library/model/config digests; never pip install pyproject into old venv",
            "candidate ports still free and state/cache roots fresh; no shared voice directory or old writer marker",
            "capacity admission: two Nari processes must not exceed GPU budget or trigger old CN 2500-MiB watchdog",
            "managed candidate-only processes; US uses new Supervisor names, CN never reuses old watchdog PID files",
            "same-region controlled prompt import + read compatibility before candidate writer marker activation",
            "real GPU EOS/max_tokens/transport-cut/disconnect and two-voice ten-language/media/client acceptance",
            "fixed private authenticated ingress bound to candidate only; no Caddy/old ingress restart",
            "opt-in only gateway config with ACK validation and target-bound cold recovery; no old-worker/preset fallback",
            "post-change off-host/readback verified=true before declaring protected completion",
        ],
    }


def package_candidate(source_root: Path, plans: list[dict], destination: Path) -> dict:
    source_root = source_root.resolve(strict=True)
    if not destination.name.endswith(".tar.gz"):
        raise ValueError("local source package must end in .tar.gz")
    files = dict(plans[0]["source_files_sha256"])
    for plan in plans:
        if plan["source_files_sha256"] != files:
            raise ValueError("regional plans refer to different source trees")
    for path in sorted([*source_root.joinpath("tests").glob("*.py"),
                        source_root / "deploy/completion-release-plan.py",
                        source_root / "deploy/probe-completion-candidate.py",
                        source_root / "deploy/CLONE-COMPLETION-ISOLATED-RELEASE.md"]):
        if path.is_symlink() or not path.is_file():
            raise ValueError("missing or unsafe acceptance file")
        files[path.relative_to(source_root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    # This function is a local artifact builder, never a remote deployment path.
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("xb") as archive_file:
        with tarfile.open(fileobj=archive_file, mode="w:gz") as archive:
            def add(name, raw):
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = len(raw), 0o644, 0
                archive.addfile(info, io.BytesIO(raw))
            for relative, expected_hash in sorted(files.items()):
                path = source_root / relative
                if path.is_symlink() or not path.resolve().is_relative_to(source_root):
                    raise ValueError("source path changed before packaging")
                raw = path.read_bytes()
                if hashlib.sha256(raw).hexdigest() != expected_hash:
                    raise ValueError("source changed before packaging")
                add(relative, raw)
            add("clone-completion-manifest.json", json.dumps({
                "schema": "clone-completion-source-package-v1", "production_mutation_allowed": False,
                "models_dependencies_secrets_and_private_prompts_included": False,
                "files_sha256": files, "plans": plans,
            }, indent=2, sort_keys=True).encode())
    return {"path": str(destination.resolve()), "bytes": destination.stat().st_size,
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(), "production_mutation_allowed": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--region", choices=sorted(REGIONS), required=True)
    parser.add_argument("--release-id", required=True)
    parser.add_argument("--archive", type=Path, help="create-only local source/test package for BOTH regions")
    args = parser.parse_args()
    if args.archive:
        result = package_candidate(args.source_root, [build_plan(args.source_root, region, args.release_id)
                                                     for region in sorted(REGIONS)], args.archive)
    else:
        result = build_plan(args.source_root, args.region, args.release_id)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
