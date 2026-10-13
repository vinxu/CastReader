"""Capture immutable gateway recovery set, private upload, full hash readback."""
from pathlib import Path
import base64, json, re, subprocess, sys

HERE = Path(__file__).resolve().parent
phase = sys.argv[1]
assert phase in ('baseline', 'production')
legacy = Path('/Users/xuxuheng/Documents/MyProject/cast-reader-api/reader-service/supabase_storage.py').read_text()
def assignment(name):
    return re.search(r'^\s*'+name+r'''\s*=\s*["']([^"']+)["']''', legacy, re.M).group(1)
assert assignment('SUPABASE_URL').rstrip('/') == 'https://zqxgmqygirtpttnrvjpf.supabase.co'
key = assignment('SUPABASE_KEY')
claims = json.loads(base64.urlsafe_b64decode(key.split('.')[1]+'='*(-len(key.split('.')[1])%4)))
assert claims.get('role') == 'service_role'
tool = Path('/Users/xuxuheng/Documents/MyProject/castreader-tts-compatible-fix/verification/supabase_tus_backup.py').read_text()
remote = 'KEY='+repr(key)+'\nTOOL='+repr(tool)+'\nPHASE='+repr(phase)+'\n'+r'''
from pathlib import Path
import hashlib,io,tarfile,json,subprocess
root=Path('/var/lib/castreader-tts-release/20261012-public-ip-change')
root.mkdir(mode=0o700,parents=True,exist_ok=True)
module={'__name__':'backup_tool'}
exec(TOOL,module)
source=Path('/opt/castreader-tts-gateway/gateway.mjs') if PHASE=='baseline' else Path('/opt/castreader-tts-gateway/releases/20261012-public-ip-change/gateway.mjs')
paths={'gateway.mjs':source,'service.unit':Path('/etc/systemd/system/castreader-tts-gateway.service'),'Caddyfile':Path('/etc/caddy/Caddyfile')}
files={name:path.read_bytes() for name,path in paths.items()}
manifest={name:{'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw),'source':str(paths[name])} for name,raw in files.items()}
files['manifest.json']=json.dumps(manifest,indent=2).encode()
files['RESTORE.txt']=b'Restore service.unit to /etc/systemd/system/castreader-tts-gateway.service; restore gateway.mjs to source path recorded in manifest; preserve Caddyfile unless its restoration is needed; systemctl daemon-reload; systemctl restart castreader-tts-gateway. GPU code/models unchanged. Node runtime uses built-in modules only.\n'
files['runtime.json']=json.dumps({'node':subprocess.check_output(['node','--version'],text=True).strip()}).encode()
archive=root/('complete-'+PHASE+'.tar.gz')
with tarfile.open(archive,'x:gz') as tar:
 for name,raw in files.items():
  item=tarfile.TarInfo(name);item.size=len(raw);item.mode=0o600;tar.addfile(item,io.BytesIO(raw))
archive.chmod(0o600)
with tarfile.open(archive) as tar:
 assert all(tar.extractfile(name).read()==raw for name,raw in files.items())
assert all(path.read_bytes()==files[name] for name,path in paths.items())
receipt_path=root/('offhost-'+PHASE+'.json')
http=module['StorageHTTP'](KEY)
receipt=module['run_backup']({'files':[{'path':str(archive),'object':'runtime-releases/us/20261012-public-ip-change/'+archive.name}]},root/('transfer-'+PHASE),receipt_path,http)
receipt_receipt=module['run_backup']({'files':[{'path':str(receipt_path),'object':'runtime-releases/us/20261012-public-ip-change/'+receipt_path.name}]},root/('receipt-transfer-'+PHASE),root/('receipt-readback-'+PHASE+'.json'),http)
print(json.dumps({'phase':PHASE,'manifest':manifest,'receipt':receipt,'receiptReadback':receipt_receipt}))
'''
r = subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8','root@140.82.14.49','python3','-'],input=remote,text=True,capture_output=True,timeout=160)
if r.returncode:
    print(json.dumps({'phase':phase,'failed':True,'returnCode':r.returncode,'rawOutputWithheld':True}))
    raise SystemExit(1)
v=json.loads(r.stdout)
(HERE/('backup-'+phase+'.json')).write_text(json.dumps(v,indent=2)+'\n')
print(json.dumps({'phase':phase,'verified':v['receipt']['verified'],'receiptVerified':v['receiptReadback']['verified'],'manifest':v['manifest']}))
