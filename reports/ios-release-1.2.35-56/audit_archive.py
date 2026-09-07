"""Record the exact release artifact and confirm source/signing invariants."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parents[2]
report = Path(__file__).resolve().parent
archive = root / "build/CastReader-1.2.35-56.xcarchive"
app = archive / "Products/Applications/CastReader.app"
baseline = json.loads((root.parent / "CastReader-ios-release-1.2.34/reports/ios-release-1.2.34/archive-audit.json").read_text())
baseline_entitlements = {b["bundleID"]: b["entitlements"] for b in baseline["bundles"]}
manifest = json.loads((report / "source-hashes-before-archive.json").read_text())
for path, digest in manifest["files"].items():
    assert hashlib.sha256((root / path).read_bytes()).hexdigest() == digest, path
assert (root / "Secrets.xcconfig").read_bytes() == (root.parent / "CastReader-ios-release-1.2.34/Secrets.xcconfig").read_bytes()
log = (root / "build/kindle-release-review/archive.log").read_text()
assert "** ARCHIVE SUCCEEDED **" in log
assert not re.search(r"(?<!\S)-D\s*DEBUG(?:\s|$)", log)
bundles = []
for bundle in [app] + sorted((app / "PlugIns").glob("*.appex")):
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    assert info["CFBundleShortVersionString"] == "1.2.35"
    assert info["CFBundleVersion"] == "56"
    assert info["MinimumOSVersion"] == "17.6"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True, capture_output=True)
    entitlements = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(bundle)], stderr=subprocess.DEVNULL))
    assert entitlements == baseline_entitlements[info["CFBundleIdentifier"]]
    bundles.append({"bundle": bundle.name, "bundleID": info["CFBundleIdentifier"],
                    "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                    "minimumOS": info["MinimumOSVersion"], "signatureVerified": True,
                    "entitlements": entitlements})
assert {b["bundleID"] for b in bundles} == set(baseline_entitlements)
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["ITSAppUsesNonExemptEncryption"] is False
assert info["CastReaderInternalDistributionControlsEnabled"] in (False, "NO")
result = {"sourceCommit": manifest["commit"], "sourceFilesUnchanged": len(manifest["files"]),
          "localBuildConfigurationMatchesPreviousRelease": True,
          "archiveApplicationProperties": plistlib.loads((archive / "Info.plist").read_bytes())["ApplicationProperties"],
          "bundles": bundles, "usesNonExemptEncryption": False,
          "internalDistributionControls": False, "debugCompilationFlagPresent": False}
(report / "archive-audit.json").write_text(json.dumps(result, indent=2))
hashes = {str(p.relative_to(archive)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in archive.rglob("*") if p.is_file()}
(report / "archive-file-hashes.json").write_text(json.dumps(hashes, indent=2))
print(json.dumps(result, indent=2))
