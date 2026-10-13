"""Create only an immutable private recovery snapshot; never edit runtime.

PAYLOAD supplies the exact baseline and phase. Archives include single-file
gateway/configuration plus the current Node executable and dynamic dependencies.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(data)
    return value.hexdigest()


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE, text=True, timeout=15)


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


phase = PAYLOAD['phase']
require(phase in ('baseline', 'production'), 'unknown snapshot phase')
root = Path('/var/lib/castreader-tts-release/20260907-preset-parity')
if phase == 'baseline':
    require(not root.exists(), 'immutable snapshot root exists; inspect instead')
else:
    require(root.is_dir() and not root.is_symlink(), 'snapshot root missing')
expected = PAYLOAD['baseline']
paths = {
    'gateway.mjs': Path('/opt/castreader-tts-gateway/gateway.mjs'),
    'service.unit': Path('/etc/systemd/system/castreader-tts-gateway.service'),
    'Caddyfile': Path('/etc/caddy/Caddyfile'),
}
target_sha = expected['files'][0]['sha256'] if phase == 'baseline' else PAYLOAD['sourceSha256']
for row in expected['files']:
    path = Path(row['path'])
    digest = target_sha if path == paths['gateway.mjs'] else row['sha256']
    require(sha(path) == digest, 'live material differs from reviewed snapshot')
if phase == 'baseline':
    require(run('systemctl', 'show', 'castreader-tts-gateway.service', '-p', 'MainPID', '--value').strip()
            == expected['service']['MainPID'], 'baseline PID changed')
else:
    production = json.loads((root / 'production.json').read_text())
    cleanup = json.loads((root / 'cleanup.json').read_text())
    require(production['sourceSha256'] == target_sha and production['sourceCommit'] == PAYLOAD['sourceCommit'],
            'production commit differs')
    require(cleanup.get('shadowStopped') is True, 'production cleanup has not completed')
    require(run('systemctl', 'show', 'castreader-tts-gateway.service', '-p', 'MainPID', '--value').strip()
            == production['mainPid'], 'production PID changed')

node = Path('/usr/bin/node').resolve()
require(sha(node) == expected['nodeExecutableSha256'], 'Node executable changed')
linker_output = run('ldd', str(node))
dependency_paths = sorted(set(re.findall(r'(/[^\s()]+)', linker_output)))
dependencies = [Path(value).resolve() for value in dependency_paths]
require(all(path.is_file() for path in dependencies), 'runtime dependency missing')
files = {f'runtime{node}': node, **{f'runtime{path}': path for path in dependencies},
         'metadata/os-release': Path('/etc/os-release')}
files.update(paths)
before = {name: {'sourcePath': str(path), 'sha256': sha(path), 'bytes': path.stat().st_size}
          for name, path in files.items()}

if phase == 'baseline':
    root.mkdir(parents=True, mode=0o700)
    root.chmod(0o700)
    for name, path in paths.items():
        with (root / name).open('xb') as stream:
            stream.write(path.read_bytes())
        (root / name).chmod(0o600)
folder = root / ('snapshot-' + phase)
folder.mkdir(mode=0o700)
manifest = {'schema': 'castreader.direct-recovery-manifest.v1', 'phase': phase,
            'createdAt': datetime.now(timezone.utc).isoformat(), 'hostname': run('hostname').strip(),
            'nodeVersion': run(str(node), '--version').strip(), 'nodeExecutable': str(node),
            'sourceSha256': target_sha, 'files': before,
            'baseline': expected, 'ldd': linker_output,
            'unchangedExternalServices': ['Caddy executable/TLS state', 'QuickRead', 'US stable proxy', 'Kokoro', 'clone', 'Nari']}
(folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(folder / 'RESTORE.md').write_text('''# Direct gateway recovery scope

This immutable bundle restores the standalone Node gateway, its systemd unit,
the exact Caddy configuration, Node executable and its dynamic dependencies.
It is not a VPS/GPU image and does not replace Caddy TLS state, QuickRead,
the stable proxy, models, cloned voices or Nari. Those services are unchanged.

Verify complete archive and every manifest member SHA before use. Extract only
into a fresh private recovery directory. On this existing host restore only the
gateway source after drain, preserving the unit/Caddy bytes through the reviewed
rollback transaction. Do not overwrite a running release or another operator's
configuration. For disaster recovery on a new compatible OS, use the archived
Node executable/dependency tree and explicit manifest to reconstruct a separate
runtime; do not blindly unpack runtime libraries over the system filesystem.
Both baseline and production archives and their private readback receipts must
remain available. No old release, model or object is deleted by this workflow.
''')
files['metadata/manifest.json'] = folder / 'manifest.json'
files['metadata/RESTORE.md'] = folder / 'RESTORE.md'
if phase == 'production':
    files['metadata/production.json'] = root / 'production.json'
    files['metadata/cleanup.json'] = root / 'cleanup.json'
archive = root / ('complete-' + phase + '.tar.gz')
with tarfile.open(archive, 'x:gz', dereference=True) as output:
    for name, path in files.items():
        output.add(path, arcname=name, recursive=False)
archive.chmod(0o600)
with tarfile.open(archive) as opened:
    require(sorted(opened.getnames()) == sorted(files), 'archive members differ')
    for name, path in files.items():
        value = hashlib.sha256()
        with opened.extractfile(name) as stream:
            for data in iter(lambda: stream.read(1024 * 1024), b''):
                value.update(data)
        require(value.hexdigest() == sha(path), 'archive member readback differs')
for name, identity in before.items():
    require(sha(files[name]) == identity['sha256'], 'live file changed during capture')
receipt = {'status': 'immutable_local_snapshot_verified', 'phase': phase,
           'sourceSha256': target_sha, 'archiveSha256': sha(archive),
           'archiveBytes': archive.stat().st_size, 'memberCount': len(files),
           'privateOffhostVerified': False, 'runtimeModified': False}
with (root / ('snapshot-' + phase + '.json')).open('x') as stream:
    stream.write(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
