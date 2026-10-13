#!/usr/bin/env python3
"""Verify the signed normal Mac candidate, including each extension's profile.

A successful Xcode build is insufficient: incremental provisioning can leave
an embedded profile outside the existing signature, or a wildcard profile can
omit the group entitlement even when the executable declares it.
"""
import argparse
import datetime
import json
import plistlib
import subprocess
from pathlib import Path


def checked(command):
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def verify(app):
    checked(["codesign", "--verify", "--deep", "--strict", str(app)])
    bundles = [app, *sorted((app / "Contents/PlugIns").glob("*.appex"))]
    expected = {
        "com.same.castreader",
        "com.same.castreader.CastReaderMacShare",
        "com.same.castreader.CastReaderMacWidget",
    }
    seen = set()
    rows = []
    for bundle in bundles:
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        identifier = info["CFBundleIdentifier"]
        if identifier not in expected or identifier in seen:
            raise RuntimeError(f"Unexpected bundle: {identifier}")
        seen.add(identifier)
        entitlements = plistlib.loads(checked(["codesign", "-d", "--entitlements", ":-", str(bundle)]))
        profile = plistlib.loads(checked([
            "security", "cms", "-D", "-i", str(bundle / "Contents/embedded.provisionprofile")
        ]))
        grants = profile["Entitlements"]
        identity = "KQW6UNZE8J." + identifier
        if entitlements.get("com.apple.application-identifier") != identity or grants.get("com.apple.application-identifier") != identity:
            raise RuntimeError(f"Wrong application identity/profile: {identifier}")
        if entitlements.get("com.apple.security.app-sandbox") is not True:
            raise RuntimeError(f"Sandbox missing: {identifier}")
        groups = entitlements.get("com.apple.security.application-groups", [])
        if groups != ["group.com.same.castreader"] or not set(groups).issubset(grants.get("com.apple.security.application-groups", [])):
            raise RuntimeError(f"App Group not provisioned for process: {identifier}")
        expiry = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
        if expiry <= datetime.datetime.now(datetime.timezone.utc):
            raise RuntimeError(f"Profile expired: {identifier}")
        rows.append({"bundle": identifier, "sandbox": True, "provisionedAppGroups": groups})
    if seen != expected:
        raise RuntimeError("Missing Mac extension")
    return {"status": "PASS", "app": str(app), "strictDeepSignature": "PASS", "bundles": rows}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.app.resolve())
    except (RuntimeError, OSError, KeyError, plistlib.InvalidFileException) as error:
        result = {"status": "FAIL", "error": str(error)}
    encoded = json.dumps(result, indent=2) + "\n"
    if args.report:
        args.report.write_text(encoded)
    print(encoded, end="")
    raise SystemExit(0 if result["status"] == "PASS" else 1)
