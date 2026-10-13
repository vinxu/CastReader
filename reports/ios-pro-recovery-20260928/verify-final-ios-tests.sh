#!/bin/bash
set -euo pipefail
isolated=/tmp/CastReaderIsolatedTests.IhYOtE
derived="$isolated/DerivedData"
report=/Users/xuxuheng/Documents/CastReader/reports/ios-pro-recovery-20260928/isolated-final
device=1B247FE9-6D08-40BE-83D1-7E6DF63654B3
cd "$isolated"
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$derived" build-for-testing > "$report/build-final.log" 2>&1
/usr/bin/python3 - "$derived" <<'PY'
import pathlib,plistlib,subprocess,sys
products=pathlib.Path(sys.argv[1])/'Build/Products'
app=products/'Debug-iphonesimulator/CastReader.app'
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.same.castreader.prorecovery20260928'
assert info['CastReaderPrivateKeychainAccessGroup'].endswith('.com.same.castreader.prorecovery20260928')
signed=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True).stdout
# Simulator entitlements live in the Mach-O simulated entitlement section,
# while the outer ad-hoc signature may have an empty entitlement dictionary.
ent_path=pathlib.Path(sys.argv[1])/'Build/Intermediates.noindex/CastReader.build/Debug-iphonesimulator/CastReader.build/CastReader.app-Simulated.xcent'
ent=plistlib.loads(ent_path.read_bytes())
assert b'group.com.same.castreader.prorecovery20260928' in (app/'CastReader').read_bytes()
assert ent['com.apple.security.application-groups']==['group.com.same.castreader.prorecovery20260928']
allowed_keychain_suffixes = ('.com.same.castreader.prorecovery20260928', '.com.same.castreader.prorecovery20260928.safari')
assert all(s.endswith(allowed_keychain_suffixes) for s in ent['keychain-access-groups'])
source=max(products.glob('CastReader_CastReader_*.xctestrun'),key=lambda p:p.stat().st_mtime)
run=plistlib.loads(source.read_bytes())
for config in run['TestConfigurations']:
 config['TestTargets']=[t for t in config['TestTargets'] if t['BlueprintName']=='CastReaderTests']
 for target in config['TestTargets']:
  target.setdefault('CommandLineArguments',[]).append('-CastReaderPlatformContractAcceptance')
(products/'Isolated.xctestrun').write_bytes(plistlib.dumps(run))
PY
status=0
xcodebuild -xctestrun "$derived/Build/Products/Isolated.xctestrun" -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO -only-testing:CastReaderTests/ProStatusSynchronizationTests -only-testing:CastReaderTests/ServiceRoutingTests -resultBundlePath "$report/tests-final.xcresult" test-without-building > "$report/tests-final.log" 2>&1 || status=$?
xcrun xcresulttool get test-results summary --path "$report/tests-final.xcresult" --format json > "$report/summary-final.json"
printf 'Isolated unit tests exit=%s; report=%s\n' "$status" "$report"
exit "$status"
