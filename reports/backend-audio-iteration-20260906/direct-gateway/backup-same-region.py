"""Use the existing immutable private backup tool on the US host itself.

The approved Global credential stays in memory/SSH stdin. Backup bytes travel
directly between the US host and its existing private Global storage project.
"""
import base64
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parent
phase = sys.argv[1] if len(sys.argv)>1 else 'baseline'
if phase not in ('baseline','production'):
    raise SystemExit('baseline or production required')
legacy=Path('/Users/xuxuheng/Documents/MyProject/cast-reader-api/reader-service/supabase_storage.py').read_text()
def assignment(name):
    return re.search(r'^\s*'+name+r'''\s*=\s*["']([^"']+)["']''',legacy,re.M).group(1)
if assignment('SUPABASE_URL').rstrip('/') != 'https://zqxgmqygirtpttnrvjpf.supabase.co':
    raise SystemExit('Global storage authority mismatch')
key=assignment('SUPABASE_KEY')
part=key.split('.')[1]
claims=json.loads(base64.urlsafe_b64decode(part+'='*(-len(part)%4)))
if claims.get('role')!='service_role' or claims.get('ref') not in (None,'zqxgmqygirtpttnrvjpf'):
    raise SystemExit('Global credential scope mismatch')
tool=Path('/Users/xuxuheng/Documents/MyProject/castreader-tts-compatible-fix/verification/supabase_tus_backup.py').read_text()
program='import base64,json\nKEY='+repr(key)+'\nTOOL='+repr(tool)+'\nPHASE='+repr(phase)+'\n'+'''
from pathlib import Path
import hashlib,io,tarfile
try:
    module={'__name__':'castreader_backup_tool'}
    exec(TOOL,module)
    root=Path('/var/lib/castreader-tts-release/20260906-339a49fe')
    stage=json.loads((root/'stage.json').read_text())
    archive=root/('complete-'+PHASE+'.tar.gz')
    if PHASE=='production':
        production=json.loads((root/'production.json').read_text())
        cleanup=json.loads((root/'cleanup.json').read_text())
        if production.get('sourceCommit')!='339a49fe201609ca4aa51055e360607cc2eb0656' or cleanup.get('shadowStopped') is not True:
            raise RuntimeError('production release has not completed')
        paths={'gateway.mjs':Path('/opt/castreader-tts-gateway/gateway.mjs'),
               'service.unit':Path('/etc/systemd/system/castreader-tts-gateway.service'),
               'Caddyfile':Path('/etc/caddy/Caddyfile')}
        files={name:path.read_bytes() for name,path in paths.items()}
        if hashlib.sha256(files['gateway.mjs']).hexdigest()!=production['sourceSha256']:
            raise RuntimeError('production source changed')
        for name in ['service.unit','Caddyfile']:
            if files[name] != (root/name).read_bytes(): raise RuntimeError('production configuration changed')
        files['production.json']=(root/'production.json').read_bytes()
        files['cleanup.json']=(root/'cleanup.json').read_bytes()
        with tarfile.open(archive,'x:gz') as tar:
            for name,raw in files.items():
                member=tarfile.TarInfo(name);member.size=len(raw);member.mode=0o600
                tar.addfile(member,io.BytesIO(raw))
        archive.chmod(0o600)
        with tarfile.open(archive) as tar:
            if not all(tar.extractfile(name).read()==raw for name,raw in files.items()):
                raise RuntimeError('production archive readback mismatch')
        if not all(paths[name].read_bytes()==files[name] for name in paths):
            raise RuntimeError('production changed during capture')
    elif hashlib.sha256(archive.read_bytes()).hexdigest()!=stage['privateBackupSha256']:
        raise RuntimeError('backup archive changed')
    receipt_path=root/('offhost-readback.json' if PHASE=='baseline' else 'offhost-production-readback.json')
    if receipt_path.exists():
        raise RuntimeError('immutable receipt exists; inspect instead of overwriting')
    receipt=module['run_backup'](
        {'files':[{'path':str(archive),'object':'runtime-releases/us/20260906-direct-gateway-339a49fe/'+archive.name}]},
        root/('offhost-transfer-'+PHASE),receipt_path,module['StorageHTTP'](KEY))
    print(json.dumps(receipt))
except Exception as error:
    print(json.dumps({'status':'failed','errorType':type(error).__name__}))
    raise SystemExit(1)
'''
result=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3','-'],
    input=program,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180)
if result.stdout:
    receipt=json.loads(result.stdout)
    (ROOT/('offhost-readback.json' if phase=='baseline' else 'offhost-production-readback.json')).write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt))
if result.returncode:
    print('US backup transfer did not complete; no credential or raw server response emitted.')
raise SystemExit(result.returncode)
