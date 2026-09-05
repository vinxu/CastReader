import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';

const directory = resolve(
  new URL('.', import.meta.url).pathname
);
const readyScript = join(directory, 'activate-cn-release-ready-rollback.sh.txt');
const previousScript = join(
  directory,
  'activate-cn-release-preserve-rollback.sh.txt'
);
const release = 'release-20260906014729';
const source = '9d652ec87d48a65d05e088d4655e806777dead12';

function section(script, name, nextName) {
  const start = script.indexOf(`\n${name}() {`);
  const end = script.indexOf(`\n${nextName}() {`, start + 1);
  assert.notEqual(start, -1, name);
  assert.notEqual(end, -1, nextName);
  return script.slice(start, end);
}

test('all application, schema, route, auth, clone and TTS gates remain byte-identical', () => {
  const previous = readFileSync(previousScript, 'utf8');
  const ready = readFileSync(readyScript, 'utf8');
  const boundaries = [
    ['cn_verify_voice_gift_schema', 'cn_verify_public_health'],
    ['cn_verify_public_health', 'cn_verify_quickread_public_health'],
    ['cn_verify_quickread_public_health', 'cn_verify_staged_tts_routes'],
    ['cn_verify_staged_tts_routes', 'cn_verify_staged_voice_gift_routes'],
    ['cn_verify_staged_voice_gift_routes', 'cn_verify_tts_public_health'],
    ['cn_verify_tts_public_health', 'cn_verify_voice_clone_contract'],
    ['cn_verify_voice_clone_contract', 'cn_release_manifest_source'],
    ['cn_release_manifest_source', 'activate_cn_release'],
  ];
  for (const [name, nextName] of boundaries) {
    assert.equal(section(ready, name, nextName), section(previous, name, nextName));
  }
});

test('semantic readiness ignores stale responses and accepts only the same exact Node process', () => {
  const root = mkdtempSync(join(tmpdir(), 'castreader-ready-gate-'));
  const command = String.raw`
source "$1"
calls=0
systemctl() { printf '4242\n'; }
readlink() {
  case "$*" in
    *'/4242/exe') printf '/usr/bin/node\n' ;;
    *'/4242/cwd') printf '%s\n' "$2" ;;
    *) return 1 ;;
  esac
}
stat() { printf '128\n'; }
sleep() { :; }
curl() {
  calls=$((calls + 1))
  local output='' previous=''
  for argument in "$@"; do
    if [ "$previous" = '--output' ]; then output=$argument; fi
    previous=$argument
  done
  if [ "$calls" = 1 ]; then
    printf '{"releaseId":"stale","commitSha":"stale","voiceClone":{"serviceRoute":"cn"},"voiceGift":{"serviceRoute":"cn"}}' > "$output"
  else
    printf '{"releaseId":"%s","commitSha":"%s","voiceClone":{"serviceRoute":"cn"},"voiceGift":{"serviceRoute":"cn"}}' "$3" "$4" > "$output"
  fi
  printf '200'
}
CN_RUNTIME_MAIN_PID=''
CN_READINESS_BODY_FILE=''
cn_wait_release_ready "$3" "$4" "$2" /fake-proc
test "$calls" = 2
test "$CN_RUNTIME_MAIN_PID" = 4242
test "$CN_READINESS_MATCHED" = true
rm -f -- "$CN_READINESS_BODY_FILE"
`;
  const result = spawnSync(
    'bash',
    ['-c', command, 'ready-test', readyScript, root, release, source],
    { encoding: 'utf8' }
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});

test('readiness rejects a stable process serving a wrong release', () => {
  const root = mkdtempSync(join(tmpdir(), 'castreader-stale-gate-'));
  const command = String.raw`
source "$1"
systemctl() { printf '4242\n'; }
readlink() {
  case "$*" in
    *'/4242/exe') printf '/usr/bin/node\n' ;;
    *'/4242/cwd') printf '%s\n' "$2" ;;
    *) return 1 ;;
  esac
}
stat() { printf '128\n'; }
sleep() { :; }
curl() {
  local output='' previous=''
  for argument in "$@"; do
    if [ "$previous" = '--output' ]; then output=$argument; fi
    previous=$argument
  done
  printf '{"releaseId":"wrong","commitSha":"%s","voiceClone":{"serviceRoute":"cn"},"voiceGift":{"serviceRoute":"cn"}}' "$4" > "$output"
  printf '200'
}
CN_RUNTIME_MAIN_PID=''
CN_READINESS_BODY_FILE=''
if cn_wait_release_ready "$3" "$4" "$2" /fake-proc; then exit 9; fi
test "$CN_READINESS_ATTEMPTS" = 30
test "$CN_READINESS_MATCHED" = false
rm -f -- "$CN_READINESS_BODY_FILE"
`;
  const result = spawnSync(
    'bash',
    ['-c', command, 'stale-test', readyScript, root, release, source],
    { encoding: 'utf8' }
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});

test('failure receipts are unique, atomic, mode-safe and contain no secret values or exact lengths', () => {
  const root = mkdtempSync(join(tmpdir(), 'castreader-ready-receipt-'));
  const procRoot = join(root, 'proc');
  const processRoot = join(procRoot, '5252');
  const cwd = join(root, release);
  mkdirSync(processRoot, { recursive: true });
  mkdirSync(cwd, { recursive: true });
  symlinkSync(cwd, join(processRoot, 'cwd'));
  symlinkSync('/bin/sh', join(processRoot, 'exe'));
  const secrets = {
    admin: 'admin-secret-do-not-log-123456789012345',
    invitation: 'invitation-secret-do-not-log-123456789',
    bridge: 'bridge-secret-do-not-log-1234567890123',
    encryption: 'encryption-secret-do-not-log-123456789',
  };
  writeFileSync(
    join(processRoot, 'environ'),
    Buffer.from(
      [
        `MOBILE_ROUTING_ADMIN_SECRET=${secrets.admin}`,
        `VOICE_GIFT_CN_INVITATION_SECRET=${secrets.invitation}`,
        `VOICE_CLONE_WEB_BRIDGE_SECRET=${secrets.bridge}`,
        `VOICE_CLONE_ENCRYPTION_KEY=${secrets.encryption}`,
        'CASTREADER_SERVICE_ROUTE=cn',
        `CASTREADER_RELEASE_ID=${release}`,
        'VOICE_GIFT_CN_MINIMAL_ENABLED=true',
        'VOICE_GIFT_CN_MINIMAL_SCHEMA_READY=true',
        'VOICE_GIFT_CN_DRAFT_SCHEMA_READY=true',
        '',
      ].join('\0')
    )
  );
  const body = join(root, 'capabilities.json');
  writeFileSync(
    body,
    JSON.stringify({
      releaseId: release,
      commitSha: source,
      voiceClone: { serviceRoute: 'cn' },
      voiceGift: { serviceRoute: 'cn' },
    })
  );
  const command = String.raw`
source "$1"
systemctl() { printf '5252\n'; }
TMPDIR=$2
CN_RUNTIME_GATE_INVOCATION_ID=fixture
CN_READINESS_BODY_FILE=$4
CN_READINESS_HTTP_CODE=200
CN_READINESS_ATTEMPTS=3
CN_READINESS_MAIN_PID_BEFORE=5252
CN_READINESS_MAIN_PID_AFTER=5252
CN_READINESS_EXE_BEFORE=/usr/bin/node
CN_READINESS_EXE_AFTER=/usr/bin/node
CN_READINESS_CWD_BEFORE=$5
CN_READINESS_CWD_AFTER=$5
CN_READINESS_MATCHED=true
cn_write_runtime_gate_receipt first "$6" "$7" "$5" "$3"
cn_write_runtime_gate_receipt second "$6" "$7" "$5" "$3"
`;
  const result = spawnSync(
    'bash',
    [
      '-c',
      command,
      'receipt-test',
      readyScript,
      root,
      procRoot,
      body,
      cwd,
      release,
      source,
    ],
    { encoding: 'utf8' }
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  const receipts = readdirSync(root).filter((name) =>
    name.startsWith(`castreader-cn-runtime-gate-${release}-fixture.`)
  );
  assert.equal(receipts.length, 2);
  const combined = receipts
    .map((name) => readFileSync(join(root, name), 'utf8'))
    .join('\n');
  for (const secret of Object.values(secrets)) assert.doesNotMatch(combined, new RegExp(secret));
  assert.doesNotMatch(combined, /"length"\s*:/);
  assert.match(combined, /"lengthAtLeast32": true/);
  assert.deepEqual(
    receipts.map((name) => JSON.parse(readFileSync(join(root, name), 'utf8')).reason).sort(),
    ['first', 'second']
  );
});

test('release readiness precedes every original runtime and service gate and rollback assets survive rollback failure', () => {
  const script = readFileSync(readyScript, 'utf8');
  const activation = section(script, 'activate_cn_release', 'main');
  const restart = activation.indexOf('systemctl restart castreader');
  const readiness = activation.lastIndexOf('cn_wait_release_ready "$release"');
  const authority = activation.indexOf('cn_verify_runtime_authority');
  const schema = activation.indexOf('cn_verify_voice_gift_schema', authority);
  const publicHealth = activation.indexOf('cn_verify_public_health', schema);
  const quickRead = activation.indexOf('cn_verify_quickread_public_health', publicHealth);
  const clone = activation.indexOf('cn_verify_voice_clone_contract', quickRead);
  const tts = activation.indexOf('cn_verify_tts_public_health', clone);
  const commit = activation.indexOf('rollback_pending=0');
  assert.ok(
    restart < readiness &&
      readiness < authority &&
      authority < schema &&
      schema < publicHealth &&
      publicHealth < quickRead &&
      quickRead < clone &&
      clone < tts &&
      tts < commit
  );
  const rollback = activation.slice(
    activation.indexOf('cn_rollback_current_activation()'),
    activation.indexOf('cn_activation_failure()')
  );
  assert.match(rollback, /if \[ "\$rollback_ok" = "0" \]; then\n\s+rm -rf -- "\$backup_dir"/);
  assert.match(rollback, /chmod 0700 "\$backup_dir"/);
  assert.match(rollback, /cn_wait_release_ready "\$previous_release"/);
});
