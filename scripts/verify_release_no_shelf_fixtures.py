#!/usr/bin/env python3
"""Reject synthetic shelf payloads and launch switches in the distributed app."""
import argparse
import json
from pathlib import Path
import plistlib

MARKERS = [
    "GBFIX", "Google 合成测试书", "Kobo 合成测试书", "100 本合成书目",
    "synthetic-googlebooks@example.invalid", "synthetic-kobo@example.invalid",
    "Synthetic Book ", "Kobo shelf · test fixture", "Local Kobo login fixture",
    "Local Kobo popup fixture", "__castreaderGoogleBooksHundredFixture",
    "debugHundredBookShelfFixture", "debugShelfFixture", "GoogleBooksDebugFixtures",
    "-CastReaderKoboShelfFixture", "-CastReaderKoboHundredShelfFixture",
    "-CastReaderResetKoboHundredFixture", "-CastReaderKoboLoginFixture",
    "-CastReaderKoboBlankFixture", "-CastReaderKoboPopupFixture",
    "-CastReaderKoboHomeValidation", "-CastReaderGoogleBooksHomeValidation",
    "-CastReaderGoogleBooksOpenConnection", "-CastReaderGoogleBooksHundredShelfFixture",
    "-CastReaderResetGoogleBooksHundredFixture", "-CastReaderGoogleBooksLoginFixture",
    "-CastReaderGoogleBooksBlankFixture", "-CastReaderGoogleBooksPopupFixture",
    "castreader.kobo.hundred-shelf-fixture.v1",
    "castreader.googlebooks.hundred-shelf-fixture.v1",
    "-CastReaderKindleSettingsFixture", "KindleReadingSettingsFixtureView",
    "-CastReaderFixtureAppearance", "kindleFixtureColorScheme",
    "-CastReaderShowDebugPanels", "kindleOfflineDiagnostics",
    "kindleOfflineImageBenchmarkLibrary", "kindleOfflineSavedPages",
    "KindleOfflineDiagnosticsView", "KindleOfflinePageFixture",
    "KindleOfflineFlowFixture", "KindleBackgroundProbeSheet",
    "WeReadDesktopProbeView", "-CastReaderOfflineFlowFixture",
    "-CastReaderOfflineFixturePartial", "-CastReaderOfflineFixtureChinese",
    "-CastReaderOfflineFixtureJapanese", "-CastReaderOfflineFixtureFailure",
    "-CastReaderOfflineFixtureResumeViewport", "-CastReaderKindleFontDiagnostics",
    "-CastReaderVoiceExploreFixture", "-CastReaderFamiliarVoicesFixture",
    "-CastReaderVoicePreviewDiagnostics", "CASTREADER_VOICE_FIXTURE_DIRECTORY",
]

def inspect(root):
    hits = []
    files = [p for p in root.rglob("*") if p.is_file()]
    for path in files:
        payload = path.read_bytes()
        for marker in MARKERS:
            if any(marker.encode(encoding) in payload for encoding in ("utf-8", "utf-16-le", "utf-16-be")):
                hits.append({"file": str(path.relative_to(root)), "marker": marker})
        if "fixture" in path.name.lower() or path.suffix in (".xctest", ".xctestrun"):
            hits.append({"file": str(path.relative_to(root)), "marker": "fixture/test resource filename"})
    return files, hits

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--debug-control", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    _, controls = inspect(args.debug_control)
    assert any(h["marker"] == "GBFIX" for h in controls), "Debug positive control must contain Google fake books"
    assert any(h["marker"] == "Synthetic Book " for h in controls), "Debug positive control must contain Kobo fake books"
    files, hits = inspect(args.app)
    assert info.get("CastReaderInternalDistributionControlsEnabled") in (False, "NO"), "Internal controls enabled"
    result = {"app": str(args.app.resolve()), "version": info["CFBundleShortVersionString"],
              "build": info["CFBundleVersion"], "filesScanned": len(files), "markersChecked": len(MARKERS),
              "debugPositiveControlsPassed": True, "releaseMatches": hits, "passed": not hits}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(1 if hits else 0)

if __name__ == "__main__":
    main()
