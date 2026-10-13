"""Scoped Caddy-only release: immutable backups, CAS apply and readback.

Credentials are read only from the existing Global service configuration and
stay in memory. No runtime model, Node gateway or extension permission changes.
"""
from pathlib import Path
import base64
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
REPO = Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-extension-service-cors-20260914')
OLD = Path('/Users/xuxuheng/Documents/CastReader/reports/direct-gateway-parity-release-20260907')
SSH = ['ssh', '-F', str(OLD/'ssh-config'), 'castreader-direct-us-release']
REMOTE = '/var/lib/castreader-tts-release/20260914-extension-cors'
BASE_CONFIG = '243706a702274b86cea400b4ff0c627ddead335e2dfb457fe62303952b30bdd1'
BASE_GATEWAY = 'e83932e7e1a343795ab1d0735f76ab764a406e588f7b7c9118b1de7262c8a685'


def private_json(path, data):
    with path.open('x') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')
    path.chmod(0o600)


HOST = r'''
from pathlib import Path
import base64,hashlib,json,os,subprocess,tarfile,urllib.request
from datetime import datetime,timezone
root=Path(ROOT)
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(*a): return subprocess.check_output(a,stderr=subprocess.PIPE,text=True,timeout=20).strip()
def live():
 with urllib.request.urlopen('http://127.0.0.1:2019/config/',timeout=5) as r: return json.load(r)
def canonical(v): return hashlib.sha256(json.dumps(v,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def observe():
 return {'at':datetime.now(timezone.utc).isoformat(),'hostname':run('hostname'),
  'configSha256':sha('/etc/caddy/Caddyfile'),'gatewaySha256':sha('/opt/castreader-tts-gateway/gateway.mjs'),
  'caddyPid':run('systemctl','show','caddy','-p','MainPID','--value'),
  'gatewayPid':run('systemctl','show','castreader-tts-gateway','-p','MainPID','--value'),
  'quickreadSockets':run('ss','-ltnp','sport = :7777'),
  'activeConfigSha256':canonical(live()),'caddyVersion':run('/usr/bin/caddy','version')}
def write(p,v):
 with p.open('x') as s: json.dump(v,s,indent=2);s.write('\n')
 p.chmod(0o600)
if ACTION=='snapshot':
 before=observe()
 assert before['gatewaySha256']==BASE_GATEWAY,'gateway baseline changed'
 assert before['configSha256']==EXPECTED_CONFIG,'Caddy baseline changed'
 root.mkdir(mode=0o700,exist_ok=True)
 folder=root/PHASE;folder.mkdir(mode=0o700)
 sources=[Path('/etc/caddy/Caddyfile'),Path('/usr/bin/caddy'),Path('/usr/lib/systemd/system/caddy.service'),Path('/etc/os-release')]
 drops=run('systemctl','show','caddy','-p','DropInPaths','--value').split()
 sources += [Path(x) for x in drops]
 deps=subprocess.run(['ldd','/usr/bin/caddy'],text=True,capture_output=True)
 if deps.returncode==0:
  import re
  sources += [Path(p).resolve() for p in re.findall(r'(/[^\s()]+)',deps.stdout)]
 else: assert 'not a dynamic executable' in deps.stderr+deps.stdout,'unknown Caddy binary dependencies'
 files={str(p).lstrip('/'):p for p in sources}
 manifest={name:{'sha256':sha(p),'bytes':p.stat().st_size} for name,p in files.items()}
 write(folder/'active-config.json',live())
 write(folder/'manifest.json',{'phase':PHASE,'before':before,'files':manifest,'ldd':deps.stdout+deps.stderr,
   'scope':'Caddy config, binary, systemd unit/drop-ins and libraries. TLS state, Node/gateway, QuickRead, GPU and account services unchanged.'})
 (folder/'RESTORE.md').write_text('Verify archive and every manifest SHA. Extract to a new private directory. Restore only the reviewed Caddy configuration using compare-and-swap and caddy reload; validate active JSON and protected PIDs. Binary/unit/libraries are disaster recovery material, never overwrite a running OS. Existing TLS state and other service backups remain unchanged.\n')
 for name in ['active-config.json','manifest.json','RESTORE.md']: files['metadata/'+name]=folder/name
 archive=folder/'caddy-recovery.tar.gz'
 with tarfile.open(archive,'x:gz',dereference=True) as output:
  for name,p in files.items(): output.add(p,arcname=name,recursive=False)
 archive.chmod(0o600)
 with tarfile.open(archive) as f:
  assert sorted(f.getnames())==sorted(files)
  for name,p in files.items(): assert hashlib.sha256(f.extractfile(name).read()).hexdigest()==sha(p)
 after=observe()
 for key in ['configSha256','gatewaySha256','caddyPid','gatewayPid','activeConfigSha256']:
  assert before[key]==after[key],'live state changed during snapshot'
 result={'verifiedLocal':True,'phase':PHASE,'before':before,'archiveSha256':sha(archive),'archiveBytes':archive.stat().st_size,'members':len(files)}
 write(folder/'snapshot.json',result)
 print(json.dumps(result))
elif ACTION=='apply':
 baseline=json.loads((root/'baseline/snapshot.json').read_text())
 assert BACKUP['verified'] is True and BACKUP['archiveSha256']==baseline['archiveSha256'],'verified private backup missing'
 before=observe()
 for key in ['configSha256','gatewaySha256','caddyPid','gatewayPid','activeConfigSha256','quickreadSockets']:
  assert before[key]==baseline['before'][key],'concurrent change before apply: '+key
 current_adapted=json.loads(run('/usr/bin/caddy','adapt','--config','/etc/caddy/Caddyfile','--adapter','caddyfile'))
 assert canonical(current_adapted)==before['activeConfigSha256'],'active configuration differs from its managed file'
 candidate=root/'candidate.Caddyfile'
 data=base64.b64decode(CONFIG)
 assert hashlib.sha256(data).hexdigest()==EXPECTED_CONFIG
 if candidate.exists(): assert candidate.read_bytes()==data,'immutable candidate differs'
 else:
  with candidate.open('xb') as f:f.write(data)
  candidate.chmod(0o600)
 run('/usr/bin/caddy','validate','--config',str(candidate),'--adapter','caddyfile')
 old=Path('/etc/caddy/Caddyfile');saved=old.read_bytes();stat=old.stat()
 def install(payload):
  temp=old.with_name('Caddyfile.castreader-cors.tmp')
  with temp.open('xb') as f:f.write(payload);f.flush();os.fsync(f.fileno())
  os.chmod(temp,stat.st_mode & 0o777);os.chown(temp,stat.st_uid,stat.st_gid);os.replace(temp,old)
 assert sha(old)==before['configSha256'] and canonical(live())==before['activeConfigSha256']
 install(data)
 try:
  # Caddy file_server automatically hides the source Caddyfile's absolute
  # path. Adapt using the managed filename, exactly as reload does; a staging
  # filename produces a different hide entry in unrelated QuickRead routes.
  assert sha(old)==EXPECTED_CONFIG
  adapted=json.loads(run('/usr/bin/caddy','adapt','--config',str(old),'--adapter','caddyfile'))
  run('/usr/bin/caddy','reload','--config',str(old),'--adapter','caddyfile')
  after=observe()
  write(root/('apply-observation-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f')+'.json'),{'expected':adapted,'actual':live(),'before':before,'after':after})
  assert after['activeConfigSha256']==canonical(adapted),'active Caddy config mismatch'
  for key in ['caddyPid','gatewayPid','gatewaySha256','quickreadSockets']:
   assert after[key]==before[key],'protected runtime changed: '+key
 except Exception:
  if sha(old)==EXPECTED_CONFIG:
   install(saved);run('/usr/bin/caddy','reload','--config',str(old),'--adapter','caddyfile')
  raise
 result={'applied':True,'sourceCommit':COMMIT,'before':before,'after':after,'backup':BACKUP,'rollbackConfigSha256':before['configSha256']}
 write(root/'apply.json',result);print(json.dumps(result))
elif ACTION=='status': print(json.dumps(observe()))
'''


def remote(params):
    params.update(ROOT=REMOTE, BASE_GATEWAY=BASE_GATEWAY)
    program='\n'.join(k+'='+repr(v) for k,v in params.items())+'\n'+HOST
    result=subprocess.run(SSH+['python3','-B','-'],input=program,text=True,capture_output=True,timeout=90)
    if result.returncode:
        # Program contains no credentials; persist operational errors privately.
        (ROOT/'last-host-error.txt').write_text(result.stderr)
        (ROOT/'last-host-error.txt').chmod(0o600)
        raise RuntimeError('host operation failed; see private last-host-error.txt')
    return json.loads(result.stdout)


def backup(phase):
    snapshot=json.loads((ROOT/(phase+'-snapshot.json')).read_text())
    archive=ROOT/(phase+'-caddy-recovery.tar.gz')
    if not archive.exists():
        with archive.open('xb') as f:
            archive.chmod(0o600)
            subprocess.run(SSH+['cat',REMOTE+'/'+phase+'/caddy-recovery.tar.gz'],stdout=f,check=True,timeout=90)
    assert archive.stat().st_size==snapshot['archiveBytes']
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==snapshot['archiveSha256']
    value=os.environ.get('SUPABASE_SERVICE_ROLE_KEY')
    if not value:
        # Same fixed, documented local source as the previously reviewed
        # with-storage-environment.mjs. Parse literals; never execute/import it.
        source=Path('/Users/xuxuheng/Documents/MyProject/cast-reader-api/reader-service/supabase_storage.py').read_text()
        def assignment(name):
            match=re.search(r'^\s*'+name+r'\s*=\s*[\"\x27]([^\"\x27]+)[\"\x27]',source,re.M)
            return match.group(1) if match else None
        assert assignment('SUPABASE_URL')=='https://zqxgmqygirtpttnrvjpf.supabase.co'
        value=assignment('SUPABASE_KEY')
    assert value,'existing Global backup credential unavailable'
    assert value != '[SENSITIVE]' and len(value.split('.'))==3,'service-role credential unavailable'
    part=value.split('.')[1]
    claims=json.loads(base64.urlsafe_b64decode(part+'='*(-len(part)%4)))
    assert claims.get('role')=='service_role' and claims.get('ref')=='zqxgmqygirtpttnrvjpf'
    tool=OLD/'supabase_tus_backup.py'
    assert hashlib.sha256(tool.read_bytes()).hexdigest()=='7f91f35dab164aa138a1caf1fd7b324c3bc91b0f2dece931323e665a9c9439b1'
    spec=importlib.util.spec_from_file_location('backup_tool',tool)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    http=module.StorageHTTP(value)
    prefix='runtime-releases/us/20260914-extension-cors/'
    receipt=ROOT/(phase+'-private-readback.json')
    if receipt.exists(): data=json.loads(receipt.read_text())
    else:
        data=module.run_backup({'files':[{'path':str(archive),'object':prefix+archive.name,'part_bytes':32*1024*1024}]},ROOT/(phase+'-upload'),receipt,http)
    assert data['verified'] is True and data['files'][0]['sha256']==snapshot['archiveSha256']
    self_receipt=ROOT/(phase+'-receipt-readback.json')
    if self_receipt.exists(): own=json.loads(self_receipt.read_text())
    else:
        own=module.run_backup({'files':[{'path':str(receipt),'object':prefix+'metadata/'+receipt.name}]},ROOT/(phase+'-receipt-upload'),self_receipt,http)
    assert own['verified'] is True and own['files'][0]['sha256']==hashlib.sha256(receipt.read_bytes()).hexdigest()
    combined={'verified':True,'phase':phase,'archiveSha256':snapshot['archiveSha256'],
              'archiveBytes':snapshot['archiveBytes'],'archiveReceiptSha256':hashlib.sha256(receipt.read_bytes()).hexdigest(),
              'receiptReadbackSha256':hashlib.sha256(self_receipt.read_bytes()).hexdigest()}
    target=ROOT/(phase+'-backup-verified.json')
    if not target.exists(): private_json(target,combined)
    return combined


if __name__=='__main__':
    ROOT.chmod(0o700)
    action=sys.argv[1]
    try:
        config=(REPO/'ops/tts-direct-gateway/Caddyfile.production').read_bytes()
        digest=hashlib.sha256(config).hexdigest()
        if action in ['snapshot-baseline','snapshot-production']:
            phase=action.split('-')[1]
            result=remote({'ACTION':'snapshot','PHASE':phase,'EXPECTED_CONFIG':BASE_CONFIG if phase=='baseline' else digest})
            private_json(ROOT/(phase+'-snapshot.json'),result)
        elif action in ['backup-baseline','backup-production']:
            result=backup(action.split('-')[1])
        elif action=='apply':
            assert not subprocess.check_output(['git','status','--porcelain'],cwd=REPO,text=True).strip(),'candidate source must be clean'
            commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()
            result=remote({'ACTION':'apply','EXPECTED_CONFIG':digest,'CONFIG':base64.b64encode(config).decode(),
                'COMMIT':commit,'BACKUP':json.loads((ROOT/'baseline-backup-verified.json').read_text())})
            private_json(ROOT/'apply.json',result)
        elif action=='status':result=remote({'ACTION':'status'})
        else:raise ValueError('unknown action')
        print(json.dumps(result,indent=2))
    except Exception as error:
        print(json.dumps({'ok':False,'errorType':type(error).__name__}))
        raise SystemExit(1)
