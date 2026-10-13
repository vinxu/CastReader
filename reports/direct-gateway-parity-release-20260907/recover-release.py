"""Prepare or execute the reviewed post-release rollback; plan is the default.

Execution requires the stable and new versions' complete private readbacks.
It keeps the reviewed candidate available as a bridge until the old source and
exact routes are restored, then drains the bridge before stopping it.
"""
import argparse
import ast
import base64
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parent
PLAN=json.loads((ROOT/'release-plan.json').read_text())
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('action',choices=['plan','execute'],default='plan',nargs='?')
action=parser.parse_args().action
if action=='plan':
    print(json.dumps({'action':'restore exact pre-release gateway source after both versions have verified private full readbacks',
        'baselineSha256':PLAN['expectedBaselineSha256'],'candidateSha256':PLAN['candidateSha256'],
        'runtimeAccessed':False,'protectedServices':PLAN['protectedServices']},indent=2))
    raise SystemExit(0)
if not PLAN.get('candidateCommit') or not PLAN.get('candidateSha256'):
    raise SystemExit('candidate identity is pending')
source=subprocess.check_output(['git','show',PLAN['candidateCommit']+':ops/tts-direct-gateway/gateway.mjs'],cwd=PLAN['candidateWorktree'])
if hashlib.sha256(source).hexdigest()!=PLAN['candidateSha256']:raise SystemExit('reviewed candidate changed')
payload={'sourceCommit':PLAN['candidateCommit'],'sourceSha256':PLAN['candidateSha256'],
    'sourceBase64':base64.b64encode(source).decode(),'baseline':json.loads((ROOT/'pre-release-baseline.json').read_text())}
reviewed=(ROOT/'release-host.py').read_text()
protected=next(ast.get_source_segment(reviewed,node) for node in ast.parse(reviewed).body
    if isinstance(node,ast.FunctionDef) and node.name=='protected_pids')
program='import json,base64\nPAYLOAD=json.loads(base64.b64decode('+repr(base64.b64encode(json.dumps(payload).encode()).decode())+'))\n'
program+=reviewed.split("action = PAYLOAD['action']",1)[0]+'\n'+protected+'\n'+'''
lock=open('/var/lock/castreader-direct-tts-release.lock','a')
fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
require(not (backup/'manual-rollback.json').exists(),'immutable rollback receipt already exists')
staged=json.loads((backup/'stage.json').read_text())
production=json.loads((backup/'production.json').read_text())
cleanup=json.loads((backup/'cleanup.json').read_text())
require(production['sourceSha256']==digest(new_source) and production['sourceCommit']==PAYLOAD['sourceCommit'],'production identity differs')
require(cleanup.get('shadowStopped') is True,'production cleanup is incomplete')
require(pid('castreader-tts-gateway.service')==production['mainPid'],'production PID changed independently')
require(protected_pids()==staged['protectedPids'],'protected VPS services changed independently')
require(digest(unit.read_bytes())==expected['files'][1]['sha256'],'production unit changed independently')
require(digest(caddy.read_bytes())==expected['files'][2]['sha256'],'Caddy file changed independently')
check_offhost_backup(staged)
snapshot=json.loads((backup/'snapshot-production.json').read_text())
require(snapshot['sourceSha256']==digest(new_source),'production snapshot differs')
check_offhost_backup({'privateBackupSha256':snapshot['archiveSha256'],'privateBackupBytes':snapshot['archiveBytes']},phase='production')
require(digest(shadow_unit.read_bytes())==staged['shadowUnitSha256'],'candidate unit changed independently')
require(digest((release/'gateway.mjs').read_bytes())==digest(new_source),'bridge candidate source changed')
old_caddy=(backup/'Caddyfile').read_bytes()
require(old_caddy.count(b'reverse_proxy 127.0.0.1:7778')==2,'unexpected Caddy routes')
shadow_caddy=old_caddy.replace(b'reverse_proxy 127.0.0.1:7778',b'reverse_proxy 127.0.0.1:17778')
caddy_ready(old_caddy)
caddy_runtime_matches(old_caddy)
gateway_identity('castreader-tts-gateway.service',7778,live,digest(new_source))
require(not run('ss','-H','-lntp','sport = :17778').strip(),'rollback bridge port is occupied; inspect first')
run('systemctl','enable','--now',shadow_name)
wait_health(17778)
gateway_identity(shadow_name,17778,release/'gateway.mjs',digest(new_source))
try:
    restored=restore_original(old_caddy,shadow_caddy,staged,True)
    result={'status':'manual_rollback_verified','verifiedAt':now(),'sourceSha256':expected['files'][0]['sha256'],
        'mainPid':restored['MainPID'],'bothVersionsPrivateReadbackVerified':True,'shadowStoppedAfterSocketDrain':True}
    persist('manual-rollback.json',result)
    print(json.dumps(result),flush=True)
except BaseException as error:
    result={'status':'manual_rollback_incomplete','errorType':type(error).__name__,
        'observedAt':now(),'bridgeKeptAvailable':True}
    persist('manual-rollback-failure.json',result)
    print(json.dumps(result),flush=True)
    raise
'''
digest=hashlib.sha256(program.encode()).hexdigest()
launch='''import base64,json,subprocess
from pathlib import Path
root=Path('/var/lib/castreader-tts-release/20260907-preset-parity')
script=root/('rollback-transaction-'+DIGEST+'.py')
with script.open('xb') as stream:stream.write(base64.b64decode(PROGRAM))
script.chmod(0o600)
subprocess.run(['systemd-run','--no-block','--unit=castreader-direct-release-preset-parity-rollback','--property=Type=oneshot','--property=TimeoutStartSec=900','/usr/bin/python3','-B',str(script)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
print(json.dumps({'status':'rollback_transaction_started','hostProgramSha256':DIGEST}))
'''.replace('DIGEST',repr(digest)).replace('PROGRAM',repr(base64.b64encode(program.encode()).decode()))
result=subprocess.run(['ssh','-F',str(ROOT/'ssh-config'),PLAN['hostAlias'],'python3','-B','-'],input=launch,
    text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
if result.returncode:raise SystemExit('Rollback could not start; raw stderr withheld. Inspect sanitized receipts.')
receipt=json.loads(result.stdout)
with (ROOT/'rollback-dispatch-receipt.json').open('x') as stream:stream.write(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
