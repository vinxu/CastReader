import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parent
SOURCE=Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-direct-tts-complete-audio-20260906')
COMMIT='339a49fe201609ca4aa51055e360607cc2eb0656'
action=sys.argv[1]
if action not in ('stage','apply','status'):
    raise SystemExit('stage, apply or status required')
sha=subprocess.check_output(['git','rev-parse',COMMIT],cwd=SOURCE,text=True).strip()
if subprocess.check_output(['git','status','--porcelain'],cwd=SOURCE,text=True).strip():
    raise SystemExit('source worktree is not clean')
source=(SOURCE/'ops/tts-direct-gateway/gateway.mjs').read_bytes()
if source != subprocess.check_output(['git','show',sha+':ops/tts-direct-gateway/gateway.mjs'],cwd=SOURCE):
    raise SystemExit('source differs from reviewed commit')
payload=dict(action=action,sourceCommit=sha,sourceSha256=hashlib.sha256(source).hexdigest(),
    sourceBase64=base64.b64encode(source).decode(),baseline=json.loads((ROOT/'pre-release-baseline.json').read_text()))
program='import base64,json\nPAYLOAD=json.loads(base64.b64decode('+repr(base64.b64encode(json.dumps(payload).encode()).decode())+'))\n'+(ROOT/'release-host.py').read_text()
if action == 'apply':
    host_sha=hashlib.sha256(program.encode()).hexdigest()
    program='''import base64,json,subprocess,os
from pathlib import Path
root=Path('/var/lib/castreader-tts-release/20260906-339a49fe')
if (root/'production.json').exists() or (root/'failure.json').exists():
    raise SystemExit('Transaction has a terminal receipt; inspect status instead of reapplying')
script=root/'transaction-HOSTSHA.py'
with script.open('xb') as stream:
    stream.write(base64.b64decode(PROGRAM))
script.chmod(0o600)
subprocess.run(['systemd-run','--unit=castreader-direct-release-339a49fe',
    '--property=Type=oneshot','--property=TimeoutStartSec=900',
    '/usr/bin/python3','-B',str(script)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
print(json.dumps({'status':'transaction_started','unit':'castreader-direct-release-339a49fe.service','hostProgramSha256':'HOSTSHA'}))
'''.replace('HOSTSHA',host_sha).replace('PROGRAM',repr(base64.b64encode(program.encode()).decode()))
elif action == 'status':
    program='''import json,subprocess
from pathlib import Path
root=Path('/var/lib/castreader-tts-release/20260906-339a49fe')
data={}
for name in ['production.json','cleanup.json','cleanup-failure.json','failure.json','transaction.json']:
    if (root/name).is_file(): data[name]=json.loads((root/name).read_text())
raw=subprocess.check_output(['systemctl','show','castreader-direct-release-339a49fe.service','-p','ActiveState','-p','SubState','-p','Result','-p','ExecMainStatus','--no-pager'],text=True)
data['transactionUnit']=dict(l.split('=',1) for l in raw.splitlines() if '=' in l)
print(json.dumps(data))
'''
result=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3','-'],
    input=program,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=900)
if result.stdout:
    data=json.loads(result.stdout)
    (ROOT/(action+'-receipt.json')).write_text(json.dumps(data,indent=2)+'\n')
    print(json.dumps(data),flush=True)
if result.returncode:
    print(result.stderr[-2000:],file=sys.stderr)
raise SystemExit(result.returncode)
