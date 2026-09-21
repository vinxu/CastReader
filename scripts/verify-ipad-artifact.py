#!/usr/bin/env python3
"""Audit a normally signed Release simulator candidate before installing it.

Usage: /usr/bin/python3 scripts/verify-ipad-artifact.py /path/to/CastReader.app
Prints resource metadata, never account or credential data.
"""

import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / "Info.plist").read_bytes())
identifier = info["CFBundleIdentifier"]
group = info.get("CastReaderPrivateKeychainAccessGroup", "")
assert re.fullmatch(r"[A-Z0-9]{10}\." + re.escape(identifier), group), (
    "Missing expanded private Keychain group. Rebuild with normal simulator "
    "signing; do not install a CODE_SIGNING_ALLOWED=NO audit build."
)
assert info["UIDeviceFamily"] == [1, 2]
assert info["MinimumOSVersion"] == "17.6"
assert set(info["UISupportedInterfaceOrientations~ipad"]) == {
    "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
}
assert not info.get("UIRequiresFullScreen", False)
assert info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"]
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)

binary = app / info["CFBundleExecutable"]
strings = subprocess.check_output(["strings", str(binary)], text=True, errors="replace")
markers = [marker for marker in (
    "Drag sample text", "CastReaderDropAcceptance", "CastReaderMultiWindowFixture",
    "CastReaderIPadAcceptance", "dropAcceptanceSource",
) if marker in strings]
assert not markers, "Debug fixture found in Release candidate"

extensions = []
for extension in sorted(app.glob("PlugIns/*.appex")):
    extension_info = plistlib.loads((extension / "Info.plist").read_bytes())
    assert extension_info["UIDeviceFamily"] == [1, 2]
    assert extension_info["MinimumOSVersion"] == "17.6"
    extensions.append({key: extension_info[key] for key in (
        "CFBundleIdentifier", "UIDeviceFamily", "MinimumOSVersion",
    )})
assert len(extensions) == 2
locales = sorted(path.name for path in app.glob("*.lproj"))
assert {locale + ".lproj" for locale in (
    "en", "zh-Hans", "ja", "es", "fr", "de", "pt-BR", "it", "hi",
)}.issubset(locales)

keys = (
    "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
    "MinimumOSVersion", "UIDeviceFamily", "UISupportedInterfaceOrientations~iphone",
    "UISupportedInterfaceOrientations~ipad", "UIApplicationSceneManifest",
    "CastReaderPrivateKeychainAccessGroup",
)
print(json.dumps({
    "application": {key: info.get(key) for key in keys},
    "binaryArchitectures": subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip(),
    "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "extensions": extensions,
    "locales": locales,
    "debugFixtureMarkersPresent": markers,
    "webBundles": [{
        "file": str(path.relative_to(app)), "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    } for path in sorted(app.rglob("*.js"))],
}, ensure_ascii=False, indent=2))
