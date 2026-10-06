#!/bin/bash
# Never execute state-mutating unit tests in the user's signed-in Mac app.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
isolated="$(mktemp -d /tmp/CastReaderMacTests.XXXXXX)"
derived="$isolated/DerivedData"
report="${CASTREADER_TEST_REPORT:-$root/reports/mac-parity-$(date +%Y%m%d)/unit-$(date +%H%M%S)}"
mkdir -p "$report"
report="$(cd "$report" && pwd -P)"
/usr/bin/python3 - "$root" "$isolated" "$report" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
root, dest, report = map(pathlib.Path, sys.argv[1:])
paths = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
paths += ['Secrets.xcconfig']
manifest = []
for name in sorted(set(paths)):
    if not name or name.startswith(('AppStoreAssets/', 'reports/', '.git/')):
        continue
    source = root / name
    if not source.is_file():
        continue
    data = source.read_bytes()
    copied = data
    try:
        text = data.decode('utf-8')
        # Namespace storage identities, keeping the public YouTube Embed origin stable.
        text = re.sub(r'(?<!https://)(?<!https%3A%2F%2F)com\.same\.castreader', 'com.same.castreader.releasechecksmac', text)
        # macOS permits team-prefixed groups without registering a new shared
        # production capability. Keep every fixture's group private to tests.
        text = text.replace('group.com.same.castreader.releasechecksmac',
                            'KQW6UNZE8J.com.same.castreader.releasechecksmac')
        text = text.replace('ai.castreader.auth', 'ai.castreader.releasechecksmac.auth')
        text = text.replace('com.microsoft.adalcache', 'com.microsoft.releasechecksmac.adalcache')
        if name == 'CastReader/CastReaderApp.swift':
            # Do not construct RootAuthGate: its observed AuthService restores
            # identity before body is evaluated and can clear test audio.
            ready = 'if startup.isReady {'
            assert text.count(ready) == 1
            text = text.replace(ready, 'if startup.isReady && !ProcessInfo.processInfo.arguments.contains("-CastReaderPlatformContractAcceptance") {', 1)
            # Exact same isolation as iOS unit-host script. Production source
            # keeps its real startup, authentication and entitlement checks.
            gate = 'if ProcessInfo.processInfo.arguments.contains("-CastReaderCloneCreditFixture") {'
            assert text.count(gate) == 1
            text = text.replace(gate, 'if ProcessInfo.processInfo.arguments.contains("-CastReaderPlatformContractAcceptance") { Color.clear } else ' + gate, 1)
            startup = '        installLifecycleObservers()'
            assert text.count(startup) == 1
            text = text.replace(startup, '        if ProcessInfo.processInfo.arguments.contains("-CastReaderPlatformContractAcceptance") { finishIsolatedStartup(); return }\n' + startup, 1)
            helper = '    private func installLifecycleObservers()'
            assert text.count(helper) == 1
            text = text.replace(helper, '    private func finishIsolatedStartup() { isReady = true }\n\n' + helper, 1)
        copied = text.encode('utf-8')
    except UnicodeDecodeError:
        pass
    target = dest / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(copied)
    if name == 'Secrets.xcconfig':
        target.chmod(0o600)
    manifest.append({'path': name, 'sourceSHA256': hashlib.sha256(data).hexdigest(), 'isolated': data != copied})
(report / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))
(report / 'workspace.txt').write_text(str(dest) + '\n')
PY
cd "$isolated"
xcodebuild -workspace CastReader.xcworkspace -scheme CastReaderMac \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath "$derived" -allowProvisioningUpdates build-for-testing > "$report/build.log" 2>&1
/usr/bin/python3 - "$derived" <<'PY'
import pathlib, plistlib, subprocess, sys
products = pathlib.Path(sys.argv[1]) / 'Build/Products'
app = products / 'Debug-maccatalyst/CastReaderMac.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.same.castreader.releasechecksmac'
assert info['CastReaderPrivateKeychainAccessGroup'].endswith('.com.same.castreader.releasechecksmac')
ent = plistlib.loads(subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True).stdout)
assert ent['com.apple.security.application-groups'] == ['KQW6UNZE8J.com.same.castreader.releasechecksmac']
assert all(s.endswith('.com.same.castreader.releasechecksmac') for s in ent['keychain-access-groups'])
source = max(products.glob('CastReaderMac_*.xctestrun'), key=lambda p: p.stat().st_mtime)
run = plistlib.loads(source.read_bytes())
if 'TestConfigurations' in run:
    targets = [target for config in run['TestConfigurations'] for target in config['TestTargets']]
else:
    targets = [value for value in run.values() if isinstance(value, dict) and 'BlueprintName' in value]
assert targets and all(t['BlueprintName'] == 'CastReaderMacTests' for t in targets)
for target in targets:
    target.setdefault('CommandLineArguments', []).append('-CastReaderPlatformContractAcceptance')
(products / 'IsolatedMac.xctestrun').write_bytes(plistlib.dumps(run))
PY
status=0
test_filters=()
if [[ -n "${CASTREADER_TEST_ONLY:-}" ]]; then
  while IFS= read -r test_identifier; do
    [[ -n "$test_identifier" ]] && test_filters+=("-only-testing:CastReaderMacTests/$test_identifier")
  done <<< "$CASTREADER_TEST_ONLY"
fi
xcodebuild -xctestrun "$derived/Build/Products/IsolatedMac.xctestrun" \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -parallel-testing-enabled NO -resultBundlePath "$report/tests.xcresult" \
  "${test_filters[@]}" test-without-building > "$report/tests.log" 2>&1 || status=$?
xcrun xcresulttool get test-results summary --path "$report/tests.xcresult" --format json > "$report/summary.json"
printf 'Isolated Mac tests exit=%s; report=%s\n' "$status" "$report"
exit "$status"
