"""Pinned candidate operator. plan is local; baseline/status read production.

stage creates a loopback candidate and uses fixed synthesis probes. apply changes
production only after exact candidate, baseline CAS, private backup and drain gates.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
SOURCE = Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-tts-direct-cancellation-20260907')
COMMIT = '1213fcd3f9f616e92e9fd3a8f1e817b5095986c5'
BASE = 'b9e7e9129e49f882398289511bbb90dbda8c6c08'
HOST_ROOT = '/var/lib/castreader-tts-release/20260907-abort-source'
TRANSACTION = 'castreader-direct-release-abort-source'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['plan', 'baseline', 'stage', 'apply', 'status'])
action = parser.parse_args().action
sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=SOURCE, text=True).strip()
if sha != COMMIT or subprocess.check_output(['git', 'status', '--porcelain'], cwd=SOURCE, text=True).strip():
    raise SystemExit('reviewed source worktree identity or cleanliness changed')
source = (SOURCE/'ops/tts-direct-gateway/gateway.mjs').read_bytes()
if source != subprocess.check_output(['git', 'show', COMMIT+':ops/tts-direct-gateway/gateway.mjs'], cwd=SOURCE):
    raise SystemExit('candidate differs from reviewed commit')
source_hash = hashlib.sha256(source).hexdigest()
old_source = subprocess.check_output(['git', 'show', BASE+':ops/tts-direct-gateway/gateway.mjs'], cwd=SOURCE)
old_hash = hashlib.sha256(old_source).hexdigest()
if action == 'plan':
    print(json.dumps({'status': 'local_plan_only', 'productionAccessed': False,
        'sourceCommit': COMMIT, 'sourceSha256': source_hash, 'expectedBaselineCommit': BASE,
        'expectedBaselineSourceSha256': old_hash, 'hostReleaseRoot': HOST_ROOT,
        'requiresFreshBaseline': True, 'requiresVerifiedPrivateBackup': True,
        'candidatePort': 17778, 'productionPort': 7778, 'preservesRegionAndIngress': True}, indent=2))
    raise SystemExit(0)
if action == 'baseline':
    if (ROOT/'pre-release-baseline.json').exists():
        raise SystemExit('immutable baseline already exists; inspect instead of overwriting')
    program = (ROOT/'read-baseline-host.py').read_text().replace('EXPECTED_SOURCE_SHA256', old_hash)
elif action == 'status':
    program = '''import json,subprocess
from pathlib import Path
root=Path(HOST_ROOT)
data={}
for name in ['stage.json','production.json','cleanup.json','cleanup-failure.json','failure.json','transaction.json']:
    if (root/name).is_file(): data[name]=json.loads((root/name).read_text())
raw=subprocess.check_output(['systemctl','show',TRANSACTION+'.service','-p','ActiveState','-p','SubState','-p','Result','-p','ExecMainStatus','--no-pager'],text=True)
data['transactionUnit']=dict(line.split('=',1) for line in raw.splitlines() if '=' in line)
print(json.dumps(data))
'''.replace('HOST_ROOT', repr(HOST_ROOT)).replace('TRANSACTION', repr(TRANSACTION))
else:
    baseline = json.loads((ROOT/'pre-release-baseline.json').read_text())
    if baseline['files'][0]['sha256'] != old_hash:
        raise SystemExit('baseline source differs from reviewed production base')
    payload = dict(action=action, sourceCommit=COMMIT, sourceSha256=source_hash,
        sourceBase64=base64.b64encode(source).decode(), baseline=baseline)
    program = 'import base64,json\nPAYLOAD=json.loads(base64.b64decode('+repr(base64.b64encode(json.dumps(payload).encode()).decode())+'))\n'+(ROOT/'release-host.py').read_text()
    if action == 'apply':
        host_sha = hashlib.sha256(program.encode()).hexdigest()
        program = '''import base64,json,subprocess
from pathlib import Path
root=Path(HOST_ROOT)
if (root/'production.json').exists() or (root/'failure.json').exists():
    raise SystemExit('Transaction has a terminal receipt; inspect status instead of reapplying')
script=root/('transaction-'+HOST_SHA+'.py')
with script.open('xb') as stream:
    stream.write(base64.b64decode(PROGRAM))
script.chmod(0o600)
subprocess.run(['systemd-run','--unit='+TRANSACTION,'--property=Type=oneshot','--property=TimeoutStartSec=900','/usr/bin/python3','-B',str(script)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
print(json.dumps({'status':'transaction_started','unit':TRANSACTION+'.service','hostProgramSha256':HOST_SHA}))
'''.replace('HOST_ROOT', repr(HOST_ROOT)).replace('HOST_SHA', repr(host_sha)).replace('TRANSACTION', repr(TRANSACTION)).replace('PROGRAM', repr(base64.b64encode(program.encode()).decode()))
result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'root@140.82.14.49', 'python3', '-'],
    input=program, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=900)
if result.stdout:
    data = json.loads(result.stdout)
    name = 'pre-release-baseline.json' if action == 'baseline' else action+'-receipt.json'
    with (ROOT/name).open('x' if action == 'baseline' else 'w') as stream:
        stream.write(json.dumps(data, indent=2)+'\n')
    print(json.dumps(data), flush=True)
if result.returncode:
    # Never export arbitrary service or subprocess exception contents.
    print('Direct release action failed; inspect on-host receipt. No raw stderr exported.', file=sys.stderr)
raise SystemExit(result.returncode)
