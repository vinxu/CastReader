#!/bin/bash
# Repeatable simulator gate. Invoke only after the preceding module is reviewed.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
module="${1:?module name required}"
test_identifier="${2:?XCTest identifier required}"
test_arguments=()
for identifier in "${@:2}"; do test_arguments+=("-only-testing:$identifier"); done
device="${CASTREADER_IPAD_SIMULATOR:-BFCF61DE-9C45-4467-8996-6F4E03AE7725}"
derived="${CASTREADER_IPAD_DERIVED_DATA:-/tmp/CastReader-iPad-Adaptation}"
run="$(date +%Y%m%dT%H%M%S)"
report="$root/reports/ipad-adaptation-20260921/$module-$run"
mkdir -p "$report"
cd "$root"
bash scripts/build-voice-toc-integration.sh --check > "$report/baseline.txt"
git diff --stat > "$report/changes.txt"
test_status=0
xcodebuild -disableAutomaticPackageResolution -skipPackageUpdates -workspace CastReader.xcworkspace -scheme CastReader \
  -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$derived" -parallel-testing-enabled NO \
  -resultBundlePath "$report/tests.xcresult" \
  "${test_arguments[@]}" test > "$report/tests.log" 2>&1 || test_status=$?
xcrun xcresulttool get test-results summary --path "$report/tests.xcresult" \
  --format json > "$report/summary.json"
xcrun xcresulttool export attachments --path "$report/tests.xcresult" \
  --output-path "$report/attachments" > "$report/attachments-export.log"
printf 'Simulator test exit=%s; inspect results and screenshots before continuing: %s\n' "$test_status" "$report"

exit "$test_status"
