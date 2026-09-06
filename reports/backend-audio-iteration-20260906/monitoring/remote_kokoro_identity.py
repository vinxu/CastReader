#!/usr/bin/env python3
"""Read the immutable US Kokoro release identity without loading a model."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path


CURRENT = Path("/workspace/castreader-runtime/current")
RELEASES = Path("/workspace/castreader-runtime/releases")
SOURCE_RELATIVE = Path("api/src/inference/english_g2p_recovery.py")


def iso(value):
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def main():
    release = CURRENT.resolve(strict=True)
    releases_root = RELEASES.resolve(strict=True)
    release.relative_to(releases_root)
    source = release / SOURCE_RELATIVE
    source.resolve(strict=True).relative_to(release)
    raw = source.read_bytes()
    print(
        json.dumps(
            {
                "schema": "castreader.kokoro-runtime-identity.v1",
                "readOnly": True,
                "productionModified": False,
                "modelLoaded": False,
                "diagnosticFunctionExecuted": False,
                "readAtUtc": iso(datetime.now(timezone.utc)),
                "coverage": {"complete": True},
                "identity": {
                    "currentLink": str(CURRENT),
                    "runtimeReleasePath": str(release),
                    "runtimeSourceRelativePath": SOURCE_RELATIVE.as_posix(),
                    "runtimeSourceBytes": len(raw),
                    "runtimeSourceSha256": hashlib.sha256(raw).hexdigest(),
                },
                "limitations": [
                    "This read verifies the current symlink target and one release-critical source file; it does not execute G2P or load the model.",
                    "Release-directory immutability remains an operational requirement.",
                ],
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
