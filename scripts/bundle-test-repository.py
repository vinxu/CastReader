#!/usr/bin/env python3
"""Bundle an allowlisted source snapshot only into CastReaderTests.xctest."""
import hashlib
import json
import os
from pathlib import Path
import shutil

root = Path(os.environ["SRCROOT"])
product = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
assert product.name == "CastReaderTests.xctest", "Never embed source fixtures in the app"
destination = product / "RepositorySnapshot"
if destination.exists():
    shutil.rmtree(destination)
allowed_roots = (
    "CastReader", "CastReader Share Extension", "CastReader Widget",
    "CastReader Safari Extension", "CastReader.xcodeproj",
    "CastReaderTests/Fixtures", "docs/contracts", "docs/analytics",
)
allowed_extensions = {".swift", ".xcstrings", ".json", ".plist", ".pbxproj"}
manifest = []
for name in allowed_roots:
    for source in sorted((root / name).rglob("*")):
        if not source.is_file() or source.is_symlink():
            continue
        relative = source.relative_to(root)
        if "xcuserdata" in relative.parts or "project.xcworkspace" in relative.parts:
            continue
        is_invite_image = "HomeVoiceInviteIllustration.imageset" in relative.parts and source.suffix == ".png"
        if source.suffix not in allowed_extensions and not is_invite_image:
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        target.write_bytes(data)
        manifest.append({"path": str(relative), "sha256": hashlib.sha256(data).hexdigest()})
(destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Bundled {len(manifest)} source-contract inputs into the test bundle")
