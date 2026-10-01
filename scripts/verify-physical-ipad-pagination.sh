#!/bin/bash
# Reuse a frozen device build for one explicitly selected live iPad gate.
# Keeps the user's authentication, library and provider data intact.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
platform="${1:?kindle, google_books, kobo or weread required}"
scope="${2:-rotation}"
device="${CASTREADER_IPAD_UDID:?Set the connected physical iPad UDID}"
derived="${CASTREADER_DEVICE_DERIVED_DATA:?Set the already built device DerivedData path}"
manifest="${CASTREADER_CANDIDATE_MANIFEST:?Set the frozen candidate manifest}"
report="${CASTREADER_ACCEPTANCE_REPORT:-/tmp/castreader-ipad-$platform-$scope-$(date +%Y%m%dT%H%M%S)}"
case "$platform:$scope" in
  kindle:rotation) suite=KindleLiveAcceptanceUITests; method=testAuthorizedIPadReadExplainAndRotation ;;
  kindle:continuation) suite=KindleLiveAcceptanceUITests; method=testAuthorizedKindleEightPageContinuousRead ;;
  google_books:rotation) suite=PlatformLiveIPadAcceptanceUITests; method=testGoogleBooksReadExplainRotation ;;
  google_books:body-rotation) suite=PlatformLiveIPadAcceptanceUITests; method=testGoogleBooksBodyReadExplainRotation ;;
  kobo:rotation) suite=PlatformLiveIPadAcceptanceUITests; method=testKoboReadExplainRotation ;;
  weread:rotation) suite=PlatformLiveIPadAcceptanceUITests; method=testWeReadReadExplainRotation ;;
  google_books:continuation) suite=PlatformLiveIPadAcceptanceUITests; method=testGoogleBooksNaturalContinuation ;;
  google_books:book-end) suite=PlatformLiveIPadAcceptanceUITests; method=testGoogleBooksNaturalBookEnd ;;
  kobo:continuation) suite=PlatformLiveIPadAcceptanceUITests; method=testKoboNaturalContinuation ;;
  weread:continuation) suite=PlatformLiveIPadAcceptanceUITests; method=testWeReadNaturalContinuation ;;
  google_books:sustained|kobo:sustained|weread:sustained)
    suite=PlatformLiveIPadAcceptanceUITests; method=testAuthorizedSustainedPlayback
    export CASTREADER_SUSTAINED_PLATFORM="$platform" ;;
  *) printf 'Unsupported platform/scope: %s/%s\n' "$platform" "$scope" >&2; exit 2 ;;
esac
mkdir -p "$report"
cd "$root"
bash scripts/build-voice-toc-integration.sh --check > "$report/baseline.txt"
/usr/bin/python3 - "$derived" "$manifest" "$report" <<'PY'
import hashlib, json, os, pathlib, plistlib, sys
products = pathlib.Path(sys.argv[1]) / 'Build/Products'
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
app = products / 'Debug-iphoneos/CastReader.app'
assert hashlib.sha256((app/'CastReader.debug.dylib').read_bytes()).hexdigest() == manifest['binary_sha256'], 'Frozen app binary changed'
for resource in ('bundle.js', 'play-books-native.js', 'weread-native.js'):
    source = 'CastReader/WebAssets/' + resource
    matches = list(app.rglob(resource))
    assert len(matches) == 1, f'Expected exactly one packaged {resource}'
    assert hashlib.sha256(matches[0].read_bytes()).hexdigest() == manifest['source_files'][source], f'Frozen web resource changed: {resource}'
assert 2 in plistlib.loads((app/'Info.plist').read_bytes())['UIDeviceFamily'], 'Build does not support iPad'
sources = list(products.glob('CastReader_CastReader_iphoneos*.xctestrun'))
assert len(sources) == 1, 'Expected one physical iOS test configuration'
run = plistlib.loads(sources[0].read_bytes())
for config in run['TestConfigurations']:
    config['TestTargets'] = [t for t in config['TestTargets'] if t['BlueprintName'] == 'CastReaderUITests']
    assert len(config['TestTargets']) == 1, 'UI test bundle missing'
    config['TestTargets'][0].setdefault('EnvironmentVariables', {}).update(
        CASTREADER_KINDLE_LIVE_ACCEPTANCE='1', CASTREADER_PLATFORM_LIVE_ACCEPTANCE='1',
        CASTREADER_KINDLE_REFLOW_CONTINUATION='1', CASTREADER_KINDLE_EXPLAIN_REFLOW_CONTINUATION='1')
    for key in ('CASTREADER_PLATFORM_LIVE_BOOK_ID', 'CASTREADER_WEREAD_LIVE_CHAPTER_LABEL',
                'CASTREADER_SUSTAINED_PLATFORM', 'CASTREADER_SUSTAINED_MODE',
                'CASTREADER_SUSTAINED_SECONDS', 'CASTREADER_GOOGLE_LIVE_URL',
                'CASTREADER_GOOGLE_LAYOUT_DIAGNOSTICS', 'CASTREADER_SUSTAINED_ORIENTATION'):
        if os.environ.get(key): config['TestTargets'][0]['EnvironmentVariables'][key] = os.environ[key]
(products/'CastReader-PhysicalIPadLive.xctestrun').write_bytes(plistlib.dumps(run))
(pathlib.Path(sys.argv[3])/'candidate.json').write_text(json.dumps(manifest, indent=2)+'\n')
PY
status=0
xcodebuild test-without-building -xctestrun "$derived/Build/Products/CastReader-PhysicalIPadLive.xctestrun" \
  -destination "platform=iOS,id=$device" -parallel-testing-enabled NO \
  -maximum-test-execution-time-allowance 7800 \
  -only-testing:"CastReaderUITests/$suite/$method" \
  -resultBundlePath "$report/tests.xcresult" > "$report/tests.log" 2>&1 || status=$?
if [ -d "$report/tests.xcresult" ]; then
  xcrun xcresulttool get test-results summary --path "$report/tests.xcresult" --format json > "$report/summary.json" || true
  xcrun xcresulttool export attachments --path "$report/tests.xcresult" --output-path "$report/attachments" > "$report/attachments-export.log" || true
fi
if [ "$status" -eq 0 ]; then
  /usr/bin/python3 - "$report/summary.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary.get('passedTests') == 1 and summary.get('skippedTests') == 0 and summary.get('failedTests') == 0, 'A live gate must execute and pass, not skip'
PY
fi
printf 'Physical iPad gate exit=%s. Evidence: %s\n' "$status" "$report"
exit "$status"
