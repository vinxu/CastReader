"""Pinned Direct parity operator. No mutation runs while release-plan is pending.

plan is local; baseline/status are read-only. snapshot writes a private backup
only. stage/apply require exact candidate pins and private full readbacks.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
PLAN = json.loads((ROOT / 'release-plan.json').read_text())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['plan', 'baseline', 'snapshot-baseline', 'stage', 'apply', 'status', 'snapshot-production'])
action = parser.parse_args().action


def require(ok, message):
    if not ok:
        raise SystemExit(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def candidate():
    commit, digest = PLAN.get('candidateCommit'), PLAN.get('candidateSha256')
    require(isinstance(commit, str) and re.fullmatch('[a-f0-9]{40}', commit), 'pending reviewed candidate commit')
    require(isinstance(digest, str) and re.fullmatch('[a-f0-9]{64}', digest), 'pending reviewed candidate SHA')
    path = Path(PLAN['candidateWorktree'])
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=path, text=True).strip()
    require(actual == commit, 'candidate HEAD changed')
    require(not subprocess.check_output(['git', 'status', '--porcelain'], cwd=path, text=True).strip(), 'candidate worktree is not clean')
    source = (path / 'ops/tts-direct-gateway/gateway.mjs').read_bytes()
    require(source == subprocess.check_output(['git', 'show', commit + ':ops/tts-direct-gateway/gateway.mjs'], cwd=path), 'candidate differs from commit')
    require(sha(source) == digest, 'candidate SHA changed')
    return source


if action == 'plan':
    print(json.dumps({**PLAN, 'productionAccessed': False}, indent=2))
    raise SystemExit(0)
if action == 'baseline':
    require(not (ROOT / 'pre-release-baseline.json').exists(), 'immutable baseline exists; inspect it')
    program = (ROOT / 'read-baseline-host.py').read_text()
elif action == 'status':
    program = '''import json
from pathlib import Path
root=Path('/var/lib/castreader-tts-release/20260907-preset-parity')
names=['snapshot-baseline.json','stage.json','production.json','cleanup.json','cleanup-failure.json','failure.json','transaction.json','snapshot-production.json']
print(json.dumps({name:json.loads((root/name).read_text()) for name in names if (root/name).is_file()}))
'''
else:
    source = None if action == 'snapshot-baseline' else candidate()
    if action in ('stage', 'apply'):
        upstream_check = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'castreader-us4090', 'python3', '-B', '-'],
            input=(ROOT/'read-proxy-baseline-host.py').read_text(), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
        require(upstream_check.returncode == 0, 'protected upstream identity could not be reread')
        actual_upstream = json.loads(upstream_check.stdout)
        expected_upstream = json.loads((ROOT/'protected-upstream-baseline.json').read_text())
        actual_upstream.pop('capturedAtUtc', None)
        expected_upstream.pop('capturedAtUtc', None)
        require(actual_upstream == expected_upstream, 'protected upstream identity changed; review instead of using stale regression')
    baseline = json.loads((ROOT / 'pre-release-baseline.json').read_text())
    require(baseline['files'][0]['sha256'] == PLAN['expectedBaselineSha256'], 'baseline source differs from plan')
    payload = {'action': action, 'sourceCommit': PLAN['expectedBaselineCommit'] if source is None else PLAN['candidateCommit'],
               'sourceSha256': PLAN['expectedBaselineSha256'] if source is None else sha(source),
               'sourceBase64': base64.b64encode(source).decode() if source is not None else None, 'baseline': baseline}
    if action.startswith('snapshot-'):
        payload['phase'] = action.split('-', 1)[1]
        host = (ROOT / 'snapshot-host.py').read_text()
    else:
        host = (ROOT / 'release-host.py').read_text()
    if action == 'apply':
        require(PLAN.get('applyReady') is True, 'apply remains pending final review and cross-client regression')
        path, digest = PLAN.get('crossClientRegressionReceipt'), PLAN.get('crossClientRegressionReceiptSha256')
        require(isinstance(path, str) and isinstance(digest, str), 'pending cross-client regression receipt')
        raw = Path(path).read_bytes()
        require(sha(raw) == digest, 'cross-client regression receipt changed')
        regression = json.loads(raw)
        require(regression.get('passed') is True and regression.get('candidateSha256') == sha(source), 'cross-client regression not passed for exact candidate')
        require(regression.get('upstreamBaselineSha256') == sha((ROOT/'protected-upstream-baseline.json').read_bytes()), 'cross-client upstream identity differs')
        require(regression.get('browserContractPassed') is True and regression.get('iosContractPassed') is True
                and regression.get('androidContractPassed') is True, 'cross-client contracts incomplete')
    program = 'import base64,json\nPAYLOAD=json.loads(base64.b64decode(' + repr(base64.b64encode(json.dumps(payload).encode()).decode()) + '))\n' + host
    if action == 'apply':
        payload_sha = sha(program.encode())
        program = '''import base64,json,subprocess
from pathlib import Path
root=Path('/var/lib/castreader-tts-release/20260907-preset-parity')
if (root/'production.json').exists() or (root/'failure.json').exists():
    raise SystemExit('terminal transaction receipt exists; inspect status')
script=root/('transaction-'+DIGEST+'.py')
with script.open('xb') as stream: stream.write(base64.b64decode(PROGRAM))
script.chmod(0o600)
subprocess.run(['systemd-run','--no-block','--unit=castreader-direct-release-preset-parity','--property=Type=oneshot','--property=TimeoutStartSec=900','/usr/bin/python3','-B',str(script)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
print(json.dumps({'status':'transaction_started','unit':'castreader-direct-release-preset-parity.service','hostProgramSha256':DIGEST}))
'''.replace('DIGEST', repr(payload_sha)).replace('PROGRAM', repr(base64.b64encode(program.encode()).decode()))

result = subprocess.run(['ssh', '-F', str(ROOT / 'ssh-config'), PLAN['hostAlias'], 'python3', '-B', '-'],
                        input=program, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        timeout=300 if action.startswith('snapshot-') else 900)
if result.stdout:
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise SystemExit('remote output was not a sanitized receipt; raw output withheld')
    name = 'pre-release-baseline.json' if action == 'baseline' else action + '-receipt.json'
    target = ROOT / name
    with target.open('x' if action != 'status' else 'w') as stream:
        stream.write(json.dumps(data, indent=2) + '\n')
    print(json.dumps(data))
if result.returncode:
    print('Direct release action failed. Inspect sanitized on-host receipts; raw stderr withheld.', file=sys.stderr)
raise SystemExit(result.returncode)
