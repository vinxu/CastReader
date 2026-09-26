#!/bin/bash
# Unit tests may mutate auth, routing and account state. Use a separate signed
# application and private Keychain/app-group namespace on the existing simulator.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
device="${CASTREADER_TEST_SIMULATOR:-BFCF61DE-9C45-4467-8996-6F4E03AE7725}"
isolated="$(mktemp -d /tmp/CastReaderIsolatedTests.XXXXXX)"
derived="$isolated/DerivedData"
report="${CASTREADER_TEST_REPORT:-$root/reports/ios-release-1.2.43/isolated-$(date +%Y%m%dT%H%M%S)}"
mkdir -p "$report"
/usr/bin/python3 - "$root" "$isolated" "$report" <<'PY'
import pathlib, subprocess, sys, json, hashlib
root, dest, report=map(pathlib.Path,sys.argv[1:])
paths=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
# Local build settings stay local; never include their contents in evidence.
paths += ['Secrets.xcconfig']
manifest=[]
for name in paths:
 if not name or name.startswith(('AppStoreAssets/','reports/','.git/')): continue
 source=root/name
 if not source.is_file(): continue
 data=source.read_bytes(); copied=data
 try:
  text=data.decode('utf-8')
  text=text.replace('com.same.castreader','com.same.castreader.releasechecks')
  text=text.replace('com.same.CastReaderTests','com.same.CastReaderReleaseTests')
  text=text.replace('com.same.CastReaderUITests','com.same.CastReaderReleaseUITests')
  text=text.replace('ai.castreader.auth','ai.castreader.releasechecks.auth')
  text=text.replace('com.microsoft.adalcache','com.microsoft.releasechecks.adalcache')
  copied=text.encode('utf-8')
 except UnicodeDecodeError: pass
 target=dest/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(copied)
 if name=='Secrets.xcconfig': target.chmod(0o600)
 manifest.append({'path':name,'sourceSHA256':hashlib.sha256(data).hexdigest(),'namespaced':copied!=data})
(report/'source-manifest.json').write_text(json.dumps(manifest,indent=2))
(report/'workspace.txt').write_text(str(dest)+'\n')
PY
cd "$isolated"
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$derived" build-for-testing > "$report/build.log" 2>&1
/usr/bin/python3 - "$derived" <<'PY'
import pathlib,plistlib,subprocess,sys
products=pathlib.Path(sys.argv[1])/'Build/Products'
app=products/'Debug-iphonesimulator/CastReader.app'
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.same.castreader.releasechecks'
assert info['CastReaderPrivateKeychainAccessGroup'].endswith('.com.same.castreader.releasechecks')
signed=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True).stdout
# Simulator entitlements live in the Mach-O simulated entitlement section,
# while the outer ad-hoc signature may have an empty entitlement dictionary.
ent_path=pathlib.Path(sys.argv[1])/'Build/Intermediates.noindex/CastReader.build/Debug-iphonesimulator/CastReader.build/CastReader.app-Simulated.xcent'
ent=plistlib.loads(ent_path.read_bytes())
assert b'group.com.same.castreader.releasechecks' in (app/'CastReader').read_bytes()
assert ent['com.apple.security.application-groups']==['group.com.same.castreader.releasechecks']
allowed_keychain_suffixes = ('.com.same.castreader.releasechecks', '.com.same.castreader.releasechecks.safari')
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
xcodebuild -xctestrun "$derived/Build/Products/Isolated.xctestrun" -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO -only-testing:CastReaderTests -skip-testing:CastReaderTests/PaymentTests -resultBundlePath "$report/tests.xcresult" test-without-building > "$report/tests.log" 2>&1 || status=$?
xcrun xcresulttool get test-results summary --path "$report/tests.xcresult" --format json > "$report/summary.json"
printf 'Isolated unit tests exit=%s; report=%s\n' "$status" "$report"
exit "$status"
