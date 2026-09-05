#!/usr/bin/env python3
"""Stage one exact immutable CN monitor release; never switch current."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile


ARTIFACT = Path("/tmp/castreader-core-audio-monitor-f6eb6691-7a2c0b1f.tar.gz")
MANIFEST = Path("/tmp/castreader-core-audio-monitor-f6eb6691-7a2c0b1f.manifest.json")
ROOT = Path("/opt/castreader-core-audio-monitor")
CURRENT = ROOT / "current"
OLD = ROOT / "releases/272d3148-5c085a61"
RELEASE = ROOT / "releases/f6eb6691-7a2c0b1f"
STAGING = ROOT / ".staging-f6eb6691-7a2c0b1f"
EXPECTED_ARTIFACT = "7ec7b782a08d5d287b7b6feba253ec4e2472dc104f1ed2d9f3d9d24d89290eeb"
EXPECTED_TREE = "7a2c0b1f0715d4db766a26fe84a5899a1c77b3107f2119d0907d766cef12236a"
HOST_TEST_PATTERN = (
    "CN|US|timestamp|changed or lost|one-response|response claiming|transient request|"
    "legacy omitted|local segment|endpoint pin|fixed US|ffmpeg progress|local lock|"
    "stale lock|supply failures|alignment degradation|retention|systemd contract|"
    "invalid region|production current"
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def file_hash(path):
    value = hashlib.sha256()
    size = 0
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
            size += len(block)
    return {"bytes": size, "sha256": value.hexdigest()}


def release_manifest(path):
    rows = []
    for file in sorted(Path(path).rglob("*")):
        if not file.is_file() or file.is_symlink():
            continue
        rows.append({"path": file.relative_to(path).as_posix(), **file_hash(file)})
    encoded = b"".join(
        row["path"].encode()
        + b"\0"
        + str(row["bytes"]).encode()
        + b"\0"
        + row["sha256"].encode()
        + b"\n"
        for row in rows
    )
    return rows, hashlib.sha256(encoded).hexdigest()


manifest = json.loads(MANIFEST.read_text())
expected = {row["path"]: row for row in manifest["files"]}
require(manifest["source_commit"] == "f6eb669178c665defff239fd8a60210b54894aeb", "source binding differs")
require(manifest["tree_sha256"] == EXPECTED_TREE, "tree binding differs")
require(file_hash(ARTIFACT)["sha256"] == EXPECTED_ARTIFACT == manifest["artifact"]["sha256"], "artifact differs")
require(CURRENT.resolve(strict=True) == OLD, "current monitor release changed before stage")
require(not RELEASE.exists() and not RELEASE.is_symlink(), "immutable release already exists")
require(not STAGING.exists() and not STAGING.is_symlink(), "staging path already exists")

try:
    STAGING.mkdir(mode=0o755)
    with tarfile.open(ARTIFACT, "r:gz") as archive:
        members = archive.getmembers()
        require(len(members) == len(expected), "artifact member count differs")
        seen = set()
        for member in members:
            require(member.isfile(), "artifact has a non-file member")
            require(member.name in expected and member.name not in seen, "artifact path differs")
            require(not member.name.startswith("/") and ".." not in Path(member.name).parts, "unsafe artifact path")
            raw = archive.extractfile(member).read()
            row = expected[member.name]
            require(len(raw) == row["bytes"] and hashlib.sha256(raw).hexdigest() == row["sha256"], "artifact member differs")
            target = STAGING / member.name
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            with target.open("xb") as output:
                output.write(raw)
            target.chmod(int(row["mode"], 8))
            seen.add(member.name)
    require(seen == set(expected), "artifact is incomplete")
    rows, tree = release_manifest(STAGING)
    require(tree == EXPECTED_TREE, "staged tree differs")
    tests = subprocess.run(
        [
            "/usr/bin/node",
            f"--test-name-pattern={HOST_TEST_PATTERN}",
            "--test",
            str(STAGING / "probe-core.test.mjs"),
            str(STAGING / "state-store.test.mjs"),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    require(
        tests.returncode == 0
        and "# pass 20" in tests.stdout
        and "# fail 0" in tests.stdout
        and "# cancelled 0" in tests.stdout,
        "host non-stalled contract tests failed",
    )
    timeout_smoke_source = f"""
import {{ runContinuityProbe }} from {json.dumps((STAGING / 'probe-core.mjs').as_uri())};
const keeper = setTimeout(() => {{}}, 500);
try {{
  const fetchImpl = async (_url, init) => await new Promise((_resolve, reject) => {{
    init.signal.addEventListener('abort', () => reject(new DOMException('timed out', 'AbortError')), {{ once: true }});
  }});
  const outcome = await runContinuityProbe({{
    region: 'cn', fetchImpl, decodeAudio: async () => ({{ durationSeconds: 1 }}),
    segmentTimeoutMs: 10, runTimeoutMs: 100, maxAttemptsPerSegment: 1, retryDelayMs: 0,
  }});
  if (outcome.status !== 'supply_failed' || outcome.failureCode !== 'request_timeout' || outcome.failedRequestContract !== 'stream_omitted') {{
    throw new Error('timeout smoke contract differs');
  }}
  console.log(JSON.stringify({{ ok: true, status: outcome.status, failureCode: outcome.failureCode, failedRequestContract: outcome.failedRequestContract }}));
}} finally {{
  clearTimeout(keeper);
}}
"""
    timeout_smoke = subprocess.run(
        ["/usr/bin/node", "--input-type=module", "-"],
        input=timeout_smoke_source,
        capture_output=True,
        text=True,
        timeout=5,
    )
    require(timeout_smoke.returncode == 0, "host timeout smoke failed")
    timeout_result = json.loads(timeout_smoke.stdout)
    require(timeout_result.get("ok") is True, "host timeout smoke result differs")
    require(CURRENT.resolve(strict=True) == OLD, "current monitor release changed during stage")
    STAGING.rename(RELEASE)
except Exception:
    if STAGING.exists() and not STAGING.is_symlink():
        shutil.rmtree(STAGING)
    raise

print(
    json.dumps(
        {
            "schema": "castreader.cn-monitor-stage.v1",
            "staged_at_utc": datetime.now(timezone.utc).isoformat(),
            "release": str(RELEASE),
            "source_commit": manifest["source_commit"],
            "artifact": {**file_hash(ARTIFACT), "path": str(ARTIFACT)},
            "files": len(expected),
            "tree_sha256": EXPECTED_TREE,
            "host_tests": {
                "non_stalled_passed": 20,
                "failed": 0,
                "cancelled": 0,
                "timeout_smoke": timeout_result,
                "full_suite_note": "Node 22 cancels the unref-only synthetic stall unless a referenced keeper exists; the old release has the same test-runner limitation",
            },
            "current_unchanged": CURRENT.resolve(strict=True) == OLD,
            "business_services_touched": False,
        },
        sort_keys=True,
    )
)
