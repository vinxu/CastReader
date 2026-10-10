#!/bin/bash
# Real, opt-in UI acceptance on an already-authorized simulator. Preserves its
# account and entitlements. Never install this harness on the user's phone.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
: "${CASTREADER_ACCEPTANCE_SIMULATOR:?Set the simulator UUID}"
: "${CASTREADER_ACCEPTANCE_REPORT:?Set a new persistent report directory}"
derived="${CASTREADER_ACCEPTANCE_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/CastReaderIOS28Acceptance}"
phase="${CASTREADER_ACCEPTANCE_PHASE:-long}"
case "$phase" in long|short|imports) ;; *) printf 'Unknown acceptance phase: %s\n' "$phase" >&2; exit 2 ;; esac
fixtures="${CASTREADER_ACCEPTANCE_FIXTURES:-$root/reports/ios-28-languages-20261008/long-fixtures}"
report="$CASTREADER_ACCEPTANCE_REPORT"
mkdir -p "$report"
if [[ "${CASTREADER_ACCEPTANCE_BUILD:-0}" == "1" ]]; then
  xcodebuild -workspace "$root/CastReader.xcworkspace" -scheme CastReader \
    -destination "platform=iOS Simulator,id=$CASTREADER_ACCEPTANCE_SIMULATOR" \
    -derivedDataPath "$derived" ONLY_ACTIVE_ARCH=YES build-for-testing > "$report/build.log" 2>&1
fi
run="$derived/Build/Products/LanguageAcceptance-$(basename "$report").xctestrun"
/usr/bin/python3 - "$derived" "$run" "$phase" "$fixtures" "$report" <<'PY'
import os,pathlib,plistlib,shutil,sys
root=pathlib.Path(sys.argv[1])/'Build/Products'
source=max(root.glob('CastReader_CastReader_*.xctestrun'),key=lambda p:p.stat().st_mtime)
d=plistlib.loads(source.read_bytes());phase=sys.argv[3];fixtures=pathlib.Path(sys.argv[4]);report=pathlib.Path(sys.argv[5])
fixture_name='manifest.json' if phase in ('long','imports') else 'short-manifest.json'
snapshot=report/'fixture-manifest.json'
shutil.copyfile(fixtures/fixture_name,snapshot)
for c in d['TestConfigurations']:
 c['TestTargets']=[t for t in c['TestTargets'] if t['BlueprintName']=='CastReaderUITests']
 for t in c['TestTargets']:
  env=t.setdefault('EnvironmentVariables',{})
  if phase in ('long','imports'):
   env.update(CASTREADER_LONG_MANIFEST=str(snapshot),CASTREADER_LONG_SECONDS=os.environ.get('CASTREADER_ACCEPTANCE_SECONDS','180'),CASTREADER_LONG_REPORT=str(report/'results.json'))
   if os.environ.get('CASTREADER_ACCEPTANCE_LANGUAGES'):env['CASTREADER_LONG_LANGUAGES']=os.environ['CASTREADER_ACCEPTANCE_LANGUAGES']
   if os.environ.get('CASTREADER_ACCEPTANCE_FORMATS'):env['CASTREADER_LONG_FORMATS']=os.environ['CASTREADER_ACCEPTANCE_FORMATS']
   if os.environ.get('CASTREADER_ACCEPTANCE_MODES'):env['CASTREADER_LONG_MODES']=os.environ['CASTREADER_ACCEPTANCE_MODES']
  else:
   env.update(CASTREADER_READER_ACCEPTANCE_MANIFEST=str(snapshot),CASTREADER_READER_ACCEPTANCE_EXPLAIN='1')
   if os.environ.get('CASTREADER_ACCEPTANCE_LANGUAGES'):env['CASTREADER_READER_ACCEPTANCE_LANGUAGES']=os.environ['CASTREADER_ACCEPTANCE_LANGUAGES']
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(d))
PY
method=testNewLanguagesWebPDFAndEPUBThreeMinutePlayback
if [[ "$phase" == "short" ]]; then method=testEveryLanguageReadAndExplainMainFlow; fi
if [[ "$phase" == "imports" ]]; then method=testNewLanguageWebImportsWithoutStartingSpeech; fi
status=0
xcodebuild -xctestrun "$run" \
  -destination "platform=iOS Simulator,id=$CASTREADER_ACCEPTANCE_SIMULATOR" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:"CastReaderUITests/MultilingualReaderLiveUITests/$method" \
  -resultBundlePath "$report/tests.xcresult" test-without-building > "$report/test.log" 2>&1 || status=$?
xcrun xcresulttool get test-results summary --path "$report/tests.xcresult" --format json > "$report/summary.json"
exit "$status"
