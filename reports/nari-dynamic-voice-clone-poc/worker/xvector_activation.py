#!/usr/bin/env python3
"""Fail-closed activation record for the x-vector prompt writer.

The marker is an attestation, not a boolean. It binds the deployed Worker,
prompt builder and Nari reader to one immutable release record and source SHA.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable


MARKER_VERSION = 1
PROMPT_SCHEMA = "qwen3_tts_base_voice_clone_prompt_xvector_v1"
SOURCE_COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
EXPECTED_DRY_RUN = {
    "schema": PROMPT_SCHEMA,
    "embedding_size": 1024,
    "storage": "temporary-only",
}


class ActivationError(RuntimeError):
    """The deployed release is not safe to enable for new voice writes."""


def sha256_file(path: Path) -> str:
    if not path.is_file():
        raise ActivationError(f"required activation file is missing: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json_object(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ActivationError(f"invalid JSON record: {path}") from error
    if not isinstance(value, dict):
        raise ActivationError(f"JSON record must be an object: {path}")
    return value


def _require_hash(mapping: object, name: str, expected: str) -> None:
    if not isinstance(mapping, dict) or mapping.get(name) != expected:
        raise ActivationError(f"release hash mismatch for {name}")


def validate_release_binding(
    *,
    source_commit: str,
    release_record: Path,
    releases_dir: Path,
    worker: Path,
    builder: Path,
    activation_validator: Path,
    reader: Path,
) -> dict[str, object]:
    if SOURCE_COMMIT_PATTERN.fullmatch(source_commit) is None:
        raise ActivationError("source commit must be a lowercase 40-character SHA")

    resolved_releases = releases_dir.resolve(strict=True)
    resolved_record = release_record.resolve(strict=True)
    if resolved_record.parent != resolved_releases:
        raise ActivationError("release record must be a direct child of releases_dir")
    if not resolved_record.name.startswith("fast-hotpath-") or resolved_record.suffix != ".json":
        raise ActivationError("x-vector activation requires a fast-hotpath release record")

    paths = {
        "clone_worker.py": worker.resolve(strict=True),
        "build_prompt.py": builder.resolve(strict=True),
        "xvector_activation.py": activation_validator.resolve(strict=True),
        "model/text.py": reader.resolve(strict=True),
    }
    hashes = {name: sha256_file(path) for name, path in paths.items()}
    record = load_json_object(resolved_record)
    if record.get("source_commit") != source_commit:
        raise ActivationError("release record source_commit does not match activation SHA")
    if record.get("hotpath") != "nari-x-vector-only":
        raise ActivationError("release record is not the x-vector-only hotpath")
    if record.get("writer_activation") != "requires-bound-release-marker-v1":
        raise ActivationError("release record does not require the bound writer marker")
    worker_hashes = record.get("worker_sha256")
    nari_hashes = record.get("nari_sha256")
    for name in ("clone_worker.py", "build_prompt.py", "xvector_activation.py"):
        _require_hash(worker_hashes, name, hashes[name])
    _require_hash(nari_hashes, "model/text.py", hashes["model/text.py"])

    return {
        "marker_version": MARKER_VERSION,
        "source_commit": source_commit,
        "release_record": str(resolved_record),
        "release_record_sha256": sha256_file(resolved_record),
        "worker_sha256": hashes["clone_worker.py"],
        "build_prompt_sha256": hashes["build_prompt.py"],
        "activation_validator_sha256": hashes["xvector_activation.py"],
        "reader_path": str(paths["model/text.py"]),
        "reader_sha256": hashes["model/text.py"],
        "prompt_schema": PROMPT_SCHEMA,
    }


def _default_schema_probe() -> dict[str, object]:
    from build_prompt import dry_run_xvector_prompt_schema

    return dry_run_xvector_prompt_schema()


def activate_xvector_writer(
    *,
    marker: Path,
    source_commit: str,
    release_record: Path,
    releases_dir: Path,
    worker: Path,
    builder: Path,
    activation_validator: Path,
    reader: Path,
    schema_probe: Callable[[], dict[str, object]] = _default_schema_probe,
) -> dict[str, object]:
    payload = validate_release_binding(
        source_commit=source_commit,
        release_record=release_record,
        releases_dir=releases_dir,
        worker=worker,
        builder=builder,
        activation_validator=activation_validator,
        reader=reader,
    )
    probe = schema_probe()
    if probe != EXPECTED_DRY_RUN:
        raise ActivationError("x-vector prompt schema dry-run failed")

    payload["dry_run"] = probe
    payload["activated_at"] = datetime.now(timezone.utc).isoformat()
    marker.parent.mkdir(parents=True, exist_ok=True)
    temporary = marker.with_name(f"{marker.name}.next")
    try:
        temporary.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        temporary.replace(marker)
    finally:
        temporary.unlink(missing_ok=True)
    return payload


def marker_matches_current_release(
    marker: Path,
    *,
    worker: Path,
    builder: Path,
    activation_validator: Path,
) -> bool:
    """Return false for legacy, stale, tampered or partially deployed markers."""

    try:
        marker_value = load_json_object(marker)
        source_commit = marker_value.get("source_commit")
        release_record_value = marker_value.get("release_record")
        reader_value = marker_value.get("reader_path")
        if (
            marker_value.get("marker_version") != MARKER_VERSION
            or not isinstance(source_commit, str)
            or not isinstance(release_record_value, str)
            or not isinstance(reader_value, str)
            or marker_value.get("prompt_schema") != PROMPT_SCHEMA
            or marker_value.get("dry_run") != EXPECTED_DRY_RUN
        ):
            return False
        release_record = Path(release_record_value)
        reader = Path(reader_value)
        if marker_value.get("release_record_sha256") != sha256_file(release_record):
            return False
        expected = validate_release_binding(
            source_commit=source_commit,
            release_record=release_record,
            releases_dir=release_record.parent,
            worker=worker,
            builder=builder,
            activation_validator=activation_validator,
            reader=reader,
        )
        return all(marker_value.get(key) == value for key, value in expected.items())
    except (ActivationError, OSError, RuntimeError, ValueError):
        return False


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--marker", required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--release-record", required=True, type=Path)
    parser.add_argument("--releases-dir", required=True, type=Path)
    parser.add_argument("--worker", required=True, type=Path)
    parser.add_argument("--builder", required=True, type=Path)
    parser.add_argument("--activation-validator", required=True, type=Path)
    parser.add_argument("--reader", required=True, type=Path)
    args = parser.parse_args()
    payload = activate_xvector_writer(
        marker=args.marker,
        source_commit=args.source_commit,
        release_record=args.release_record,
        releases_dir=args.releases_dir,
        worker=args.worker,
        builder=args.builder,
        activation_validator=args.activation_validator,
        reader=args.reader,
    )
    print(json.dumps(payload, sort_keys=True))


if __name__ == "__main__":
    main()
