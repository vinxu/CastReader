#!/bin/bash
# Runs one explicitly authorized live bookshelf gate on the signed-in iPad.
# Does not boot a simulator, reset data, or run account-mutating payment tests.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
platform="${1:?google_books, kobo or weread required}"
case "$platform" in
  google_books) method=testGoogleBooksReadExplainRotation ;;
  kobo) method=testKoboReadExplainRotation ;;
  weread) method=testWeReadReadExplainRotation ;;
  *) printf 'Unsupported platform: %s\n' "$platform" >&2; exit 2 ;;
esac
if [ "${2:-core}" = "layout" ] && [ "$platform" = "google_books" ]; then
  method=testGoogleBooksShelfAccessibilitySearchAndNarrowWindow
fi
if [ "${2:-core}" = "layout" ] && [ "$platform" = "kobo" ]; then
  method=testKoboShelfAccessibilitySearchAndNarrowWindow
fi
if [ "${2:-core}" = "layout" ] && [ "$platform" = "weread" ]; then
  method=testWeReadShelfAccessibilitySearchAndNarrowWindow
fi
if [ "${2:-core}" = "contents" ] && [ "$platform" = "weread" ]; then
  method=testWeReadContentsAfterReflow
fi
if [ "${2:-core}" = "resume" ] && [ "$platform" = "weread" ]; then
  method=testWeReadCompactToWideColdResume
fi
if [ "${2:-core}" = "body" ] && [ "$platform" = "google_books" ]; then
  method=testGoogleBooksBodyReadExplainRotation
fi
if [ "${2:-core}" = "continuation" ]; then
  case "$platform" in
    google_books) method=testGoogleBooksNaturalContinuation ;;
    kobo) method=testKoboNaturalContinuation ;;
    weread) method=testWeReadNaturalContinuation ;;
  esac
fi
device=BFCF61DE-9C45-4467-8996-6F4E03AE7725
derived=/tmp/CastReader-iPad-Adaptation
report="$root/reports/ipad-adaptation-20260921/platform-$platform-${2:-core}-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$report"
cd "$root"
bash scripts/build-voice-toc-integration.sh --check > "$report/baseline.txt"
xcodebuild -disableAutomaticPackageResolution -skipPackageUpdates \
  -workspace CastReader.xcworkspace -scheme CastReader \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$derived" \
  build-for-testing > "$report/build.log" 2>&1

# Xcode does not inherit arbitrary shell variables into its XCTest runner.
# Keep the explicit opt-in in a generated run configuration, never the shared
# scheme or the installed user's preferences. Preserve __TESTROOT__ paths.
/usr/bin/python3 - "$derived" <<'PY'
import plistlib
from pathlib import Path
import sys
products = Path(sys.argv[1]) / 'Build/Products'
source = max(products.glob('CastReader_CastReader_*.xctestrun'), key=lambda p: p.stat().st_mtime)
run = plistlib.loads(source.read_bytes())
for config in run['TestConfigurations']:
    config['TestTargets'] = [t for t in config['TestTargets'] if t['BlueprintName'] == 'CastReaderUITests']
    for target in config['TestTargets']:
        target.setdefault('EnvironmentVariables', {})['CASTREADER_PLATFORM_LIVE_ACCEPTANCE'] = '1'
(products / 'CastReader-LivePlatforms.xctestrun').write_bytes(plistlib.dumps(run))
PY
status=0
xcodebuild -xctestrun "$derived/Build/Products/CastReader-LivePlatforms.xctestrun" \
  -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO \
  -only-testing:"CastReaderUITests/PlatformLiveIPadAcceptanceUITests/$method" \
  -resultBundlePath "$report/tests.xcresult" test-without-building > "$report/tests.log" 2>&1 || status=$?
xcrun xcresulttool get test-results summary --path "$report/tests.xcresult" --format json > "$report/summary.json"
xcrun xcresulttool export attachments --path "$report/tests.xcresult" --output-path "$report/attachments" > "$report/attachments-export.log"
if [ "$status" -eq 0 ]; then
  /usr/bin/python3 - "$report/summary.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary.get('passedTests') == 1 and summary.get('skippedTests') == 0 and summary.get('failedTests') == 0, 'Live acceptance requires one executed passing test, with no skips'
PY
fi
printf 'Live platform test exit=%s; review captures: %s\n' "$status" "$report"
exit "$status"
