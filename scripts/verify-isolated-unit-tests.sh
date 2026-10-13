#!/bin/bash
# Unit tests may mutate auth, routing and account state. Use a separate signed
# application and private Keychain/app-group namespace on the existing simulator.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
device="${CASTREADER_TEST_DEVICE:-${CASTREADER_TEST_SIMULATOR:-BFCF61DE-9C45-4467-8996-6F4E03AE7725}}"
platform="iOS Simulator"
product_platform="iphonesimulator"
build_destination="platform=$platform,id=$device"
signing_args=()
if [[ -n "${CASTREADER_TEST_DEVICE:-}" ]]; then
  platform="iOS"
  product_platform="iphoneos"
  build_destination="generic/platform=iOS"
  signing_args=(-allowProvisioningUpdates DEVELOPMENT_TEAM=KQW6UNZE8J)
fi
isolated="$(mktemp -d /tmp/CastReaderIsolatedTests.XXXXXX)"
derived="$isolated/DerivedData"
report="${CASTREADER_TEST_REPORT:-$root/reports/ios-release-1.2.43/isolated-$(date +%Y%m%dT%H%M%S)}"
mkdir -p "$report"
report="$(cd "$report" && pwd -P)"
selection="${CASTREADER_TEST_SELECTION:-}"
if [[ -n "$selection" ]]; then
  selection="$(cd "$(dirname "$selection")" && pwd -P)/$(basename "$selection")"
fi
/usr/bin/python3 - "$root" "$isolated" "$report" "${CASTREADER_TEST_NAMESPACE:-releasechecks}" <<'PY'
import pathlib, re, subprocess, sys, json, hashlib
root, dest, report=map(pathlib.Path,sys.argv[1:4])
namespace=sys.argv[4]
assert namespace.isalnum() and namespace.startswith("releasechecks")
paths=subprocess.check_output(['git','ls-files','-co','--exclude-standard','-z'],cwd=root).decode().split('\0')
# Local build settings stay local; never include their contents in evidence.
paths += ['Secrets.xcconfig']
manifest=[]
for name in sorted(set(paths)):
 if name.startswith(('reports/', '.git/', 'AppStoreAssets/')): continue
 if not name or name.startswith(('AppStoreAssets/','reports/','.git/')): continue
 source=root/name
 if not source.is_file(): continue
 data=source.read_bytes(); copied=data
 try:
  text=data.decode('utf-8')
  # Namespace storage identities, keeping the public YouTube Embed origin stable.
  text = re.sub(r'(?<!https://)(?<!https%3A%2F%2F)com\.same\.castreader', 'com.same.castreader.releasechecks', text)
  text=text.replace('com.same.CastReaderTests','com.same.CastReaderReleaseTests')
  text=text.replace('com.same.CastReaderUITests','com.same.CastReaderReleaseUITests')
  text=text.replace('ai.castreader.auth','ai.castreader.releasechecks.auth')
  text=text.replace('com.microsoft.adalcache','com.microsoft.releasechecks.adalcache')
  text=text.replace('releasechecks',namespace)
  if name == 'scripts/bundle-test-repository.py':
   # Source-contract assertions inspect the production startup, not the
   # intentionally inert host adapter used only by isolated unit tests.
   text = text.replace('data = source.read_bytes()',
    "data = ((root / 'ProductionContractSource.swift').read_bytes() if str(relative) == 'CastReader/CastReaderApp.swift' else source.read_bytes())")
  if name == 'CastReader/CastReaderApp.swift':
   (dest/'ProductionContractSource.swift').write_bytes(data)
   # RootAuthGate initializes AuthService before evaluating its body.
   ready = 'if startup.isReady {'
   assert text.count(ready) == 1
   text = text.replace(ready, 'if startup.isReady && !ProcessInfo.processInfo.arguments.contains("-CastReaderPlatformContractAcceptance") {', 1)
   # The unit host must not run live account refreshes/StoreKit observers.
   # They can stop fixture playback or replace quota state mid-assertion.
   # Only this temporary copy changes; production and live UI builds do not.
   gate = 'if ProcessInfo.processInfo.arguments.contains("-CastReaderCloneCreditFixture") {'
   assert text.count(gate) == 1
   text = text.replace(gate, 'if ProcessInfo.processInfo.arguments.contains("-CastReaderPlatformContractAcceptance") { Color.clear } else ' + gate, 1)
   startup = '        installLifecycleObservers()'
   assert text.count(startup) == 1
   text = text.replace(startup, '        if ProcessInfo.processInfo.arguments.contains("-CastReaderPlatformContractAcceptance") { finishIsolatedStartup(); return }\n' + startup, 1)
   # Keep the production startup-order source assertion on the production
   # readiness assignment; the temporary host adapter follows that method.
   helper = '    private func installLifecycleObservers()'
   assert text.count(helper) == 1
   text = text.replace(helper, '    private func finishIsolatedStartup() { isReady = true }\n\n' + helper, 1)
  copied=text.encode('utf-8')
 except UnicodeDecodeError: pass
 target=dest/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(copied)
 if name=='Secrets.xcconfig': target.chmod(0o600)
 manifest.append({'path':name,'sourceSHA256':hashlib.sha256(data).hexdigest(),'namespaced':copied!=data})
(report/'source-manifest.json').write_text(json.dumps(manifest,indent=2))
(report/'workspace.txt').write_text(str(dest)+'\n')
PY
cd "$isolated"
if [[ -n "$selection" ]]; then
  # Some historical tests exist on disk without target membership. Register
  # selected source files only in this private copy so a missing test cannot
  # silently turn into a successful but incomplete parity run.
  ruby -rxcodeproj - "$selection" <<'RUBY'
selection = File.readlines(ARGV[0]).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
classes = selection.map { |line| line.split('/').first }.uniq
project = Xcodeproj::Project.open('CastReader.xcodeproj')
target = project.targets.find { |item| item.name == 'CastReaderTests' }
classes.each do |name|
  path = Dir.glob('CastReaderTests/*.swift').find { |file| File.read(file).match?(/\bclass\s+#{Regexp.escape(name)}\s*:/) }
  abort "Selected test class not found: #{name}" unless path
  ref = project.files.find { |file| file.real_path.to_s == File.expand_path(path) }
  unless ref
    group = project.main_group.find_subpath('CastReaderTests', true)
    group.path = 'CastReaderTests'
    ref = group.new_reference(File.basename(path))
  end
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
end
project.save
RUBY
fi
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination "$build_destination" -derivedDataPath "$derived" ${signing_args[@]+"${signing_args[@]}"} build-for-testing > "$report/build.log" 2>&1
/usr/bin/python3 - "$derived" "$product_platform" "${CASTREADER_TEST_NAMESPACE:-releasechecks}" "$selection" <<'PY'
import pathlib,plistlib,subprocess,sys
products=pathlib.Path(sys.argv[1])/'Build/Products'
platform=sys.argv[2]; namespace=sys.argv[3]
app=products/f'Debug-{platform}/CastReader.app'
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']==f'com.same.castreader.{namespace}'
assert info['CastReaderPrivateKeychainAccessGroup'].endswith(f'.com.same.castreader.{namespace}')
signed=subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True).stdout
# Simulator entitlements live in the Mach-O simulated entitlement section,
# while the outer ad-hoc signature may have an empty entitlement dictionary.
ent_path=pathlib.Path(sys.argv[1])/'Build/Intermediates.noindex/CastReader.build/Debug-iphonesimulator/CastReader.build/CastReader.app-Simulated.xcent'
ent=plistlib.loads(ent_path.read_bytes() if platform=='iphonesimulator' else signed)
assert f'group.com.same.castreader.{namespace}'.encode() in (app/'CastReader').read_bytes()
assert ent['com.apple.security.application-groups']==[f'group.com.same.castreader.{namespace}']
allowed_keychain_suffixes = (f'.com.same.castreader.{namespace}', f'.com.same.castreader.{namespace}.safari')
assert all(s.endswith(allowed_keychain_suffixes) for s in ent['keychain-access-groups'])
source=max(products.glob('CastReader_CastReader_*.xctestrun'),key=lambda p:p.stat().st_mtime)
run=plistlib.loads(source.read_bytes())
for config in run['TestConfigurations']:
 config['TestTargets']=[t for t in config['TestTargets'] if t['BlueprintName']=='CastReaderTests']
 for target in config['TestTargets']:
  target.setdefault('CommandLineArguments',[]).append('-CastReaderPlatformContractAcceptance')
  if sys.argv[4]:
   target['OnlyTestIdentifiers']=[line.strip().removesuffix('()') for line in pathlib.Path(sys.argv[4]).read_text().splitlines() if line.strip() and not line.lstrip().startswith('#')]
(products/'Isolated.xctestrun').write_bytes(plistlib.dumps(run))
PY
if [[ "${CASTREADER_TEST_BUILD_ONLY:-0}" == "1" ]]; then
  printf 'Isolated test build ready: %s\n' "$isolated"
  exit 0
fi
status=0
cleanup_test_app() {
  if [[ -n "${CASTREADER_TEST_DEVICE:-}" ]]; then
    xcrun devicectl device uninstall app --device "$device" "com.same.castreader.${CASTREADER_TEST_NAMESPACE:-releasechecks}" > "$report/cleanup.log" 2>&1 || true
  fi
}
trap cleanup_test_app EXIT
xcodebuild -xctestrun "$derived/Build/Products/Isolated.xctestrun" -destination "platform=$platform,id=$device" -collect-test-diagnostics never -parallel-testing-enabled NO -only-testing:CastReaderTests -skip-testing:CastReaderTests/PaymentTests -resultBundlePath "$report/tests.xcresult" test-without-building > "$report/tests.log" 2>&1 || status=$?
xcrun xcresulttool get test-results summary --path "$report/tests.xcresult" --format json > "$report/summary.json"
printf 'Isolated unit tests exit=%s; report=%s\n' "$status" "$report"
exit "$status"
