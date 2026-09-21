#!/bin/bash
# Account-preserving regression set for live bookshelf reflow and continuation.
set -euo pipefail
# Authentication/routing suites mutate the real app's Keychain. They belong
# in the separately namespaced host, even when a test restores its own keys.
for selected in "$@"; do
  case "${selected#CastReaderTests/}" in
    ServiceRoutingTests|PaymentTests|AuthServiceTests|AccountContentIsolationTests)
      printf 'Use scripts/verify-isolated-unit-tests.sh for account-mutating suite %s\n' "$selected" >&2
      exit 2
      ;;
  esac
done
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
device=BFCF61DE-9C45-4467-8996-6F4E03AE7725
derived=/tmp/CastReader-iPad-Adaptation
report="$root/reports/ipad-adaptation-20260921/platform-contracts-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$report"
cd "$root"
bash scripts/build-voice-toc-integration.sh --check > "$report/baseline.txt"
xcodebuild -disableAutomaticPackageResolution -skipPackageUpdates \
  -workspace CastReader.xcworkspace -scheme CastReader \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$derived" \
  build-for-testing > "$report/build.log" 2>&1
/usr/bin/python3 - "$derived" <<'PY'
import plistlib
from pathlib import Path
import sys
products = Path(sys.argv[1]) / 'Build/Products'
source = max(products.glob('CastReader_CastReader_*.xctestrun'), key=lambda p: p.stat().st_mtime)
run = plistlib.loads(source.read_bytes())
for config in run['TestConfigurations']:
    config['TestTargets'] = [t for t in config['TestTargets'] if t['BlueprintName'] == 'CastReaderTests']
    for target in config['TestTargets']:
        # Prevent the ordinary app host from restoring/advancing a real book
        # behind an isolated unit fixture. Authentication stays intact.
        target.setdefault('CommandLineArguments', []).append('-CastReaderPlatformContractAcceptance')
(products / 'CastReader-PlatformContracts.xctestrun').write_bytes(plistlib.dumps(run))
PY
test_filters=(
  -only-testing:CastReaderTests/GoogleBooksContractTests
  -only-testing:CastReaderTests/GoogleBooksWebBridgeTests
  -only-testing:CastReaderTests/KoboContractTests
  -only-testing:CastReaderTests/ReadingResumeTests
  -only-testing:CastReaderTests/WeReadOpeningPlaybackTests
)
if [ "$#" -gt 0 ]; then
  test_filters=()
  for selected in "$@"; do test_filters+=("-only-testing:CastReaderTests/${selected#CastReaderTests/}"); done
fi
status=0
xcodebuild -xctestrun "$derived/Build/Products/CastReader-PlatformContracts.xctestrun" \
  -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO \
  "${test_filters[@]}" \
  -skip-testing:CastReaderTests/GoogleBooksWebBridgeTests/testRealPlayBooksShellInstallsRelayOnly \
  -resultBundlePath "$report/tests.xcresult" test-without-building > "$report/tests.log" 2>&1 || status=$?
xcrun xcresulttool get test-results summary --path "$report/tests.xcresult" --format json > "$report/summary.json"
xcrun xcresulttool export attachments --path "$report/tests.xcresult" --output-path "$report/attachments" > "$report/attachments-export.log"
if [ "$status" -eq 0 ]; then
  /usr/bin/python3 - "$report/summary.json" <<'PYVALIDATE'
import json, sys
result = json.load(open(sys.argv[1]))
assert result.get('passedTests', 0) > 0 and result.get('failedTests', 0) == 0, 'Contract validation must execute passing tests'
PYVALIDATE
fi
printf 'Platform contract tests exit=%s; report: %s\n' "$status" "$report"
exit "$status"
