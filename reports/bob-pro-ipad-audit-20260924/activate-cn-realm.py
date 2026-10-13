from pathlib import Path
import json,subprocess,hashlib,tarfile
p=Path(__file__).parent;receipt=json.loads((p/'cn-backup-receipt.json').read_text());assert receipt['verified']
assert hashlib.sha256((p/'cn-pre-release-private.tar.gz').read_bytes()).hexdigest()==receipt['sha256']
with tarfile.open(p/'cn-pre-release-private.tar.gz') as tf:
 oldsite=tf.extractfile('etc/nginx/sites-available/castreader').read();oldsha=hashlib.sha256(oldsite).hexdigest()
code=r'''
from pathlib import Path
import os,subprocess,hashlib,json,time,urllib.request,re
root=Path('/opt/castreader-quickread-cn');old=root/'releases/20260908-cn-response-recovery-1660a11';new=root/'releases/20260924-pro-account-realm';site=Path('/etc/nginx/sites-available/castreader')
assert (root/'current').resolve()==old
assert hashlib.sha256(site.read_bytes()).hexdigest()==expected_site_sha
assert hashlib.sha256((new/'server/server.mjs').read_bytes()).hexdigest()=='09ae929d443dc884a3d7c03021876a8a5609889cc61ccac30fd46b83c9a25776'
original=site.read_text();cfg=dict(line.split('=',1) for line in Path('/etc/castreader/quickread-pro-realm.env').read_text().splitlines() if '=' in line);token=cfg['PRO_GLOBAL_INGRESS_SECRET'];assert len(token)==64
# Only worker/QuickRead locations get the overwritten private marker. The cms_
# proxy reconstructs its upstream headers; a caller's marker never reaches it.
lines=original.splitlines();edited=[];n=0
for line in lines:
 edited.append(line)
 if 'proxy_pass http://127.0.0.1:7777;' in line or 'proxy_pass $qr_upstream;' in line:
  edited.append('        proxy_set_header X-CastReader-Global-Ingress '+token+';');n+=1
assert n==3,n
final='\n'.join(edited)+'\n'
pause='map $uri $qr_pro_admission_pause { default 0; /api/quickread 1; /api/quickread/extract 1; /api/quickread/extract-plan 1; /api/quickread/fast-block0 1; }\n'+final
pause=pause.replace('location = /api/quickread {','location = /api/quickread {\n        if ($qr_pro_admission_pause) { return 503; }')
pause=pause.replace('location ^~ /api/quickread/ {','location ^~ /api/quickread/ {\n        if ($qr_pro_admission_pause) { return 503; }')
def nginx(content):
 site.write_text(content);site.chmod(0o600)
 result=subprocess.run(['nginx','-t'],capture_output=True)
 if result.returncode:
  site.write_text(original);raise RuntimeError('nginx config validation failed')
 subprocess.run(['systemctl','reload','nginx'],check=True)
def health(port=7777):
 with urllib.request.urlopen('http://127.0.0.1:'+str(port)+'/health',timeout=3) as r:return json.load(r)
def api_pid():return subprocess.check_output(['systemctl','show','castreader','-p','MainPID','--value'],text=True).strip()
def active_connections():
 return len(subprocess.check_output(['ss','-Htn','state','established','( sport = :7777 )'],text=True).splitlines())
def switch(path):
 t=root/'pro-realm-next';t.unlink(missing_ok=True);t.symlink_to(path);os.replace(t,root/'current')
drop=Path('/etc/systemd/system/castreader-quickread-cn.service.d/pro-realm.conf');assert not drop.exists()
api_before=api_pid();worker_before=subprocess.check_output(['systemctl','show','castreader-quickread-cn','-p','MainPID','--value'],text=True).strip()
assert health(17777)['ok'];start=time.time();nginx(pause);changed=False
try:
 stable=0
 for _ in range(60):
  h=health();stable=stable+1 if h['active']==0 and h['queue']==0 and active_connections()==0 else 0
  if stable>=2:break
  time.sleep(.5)
 else:raise RuntimeError('QuickRead not drained; retain old release')
 drop.parent.mkdir(exist_ok=True);drop.write_text('[Service]\nEnvironmentFile=/etc/castreader/quickread-pro-realm.env\n');drop.chmod(0o600)
 switch(new);changed=True;subprocess.run(['systemctl','daemon-reload'],check=True);subprocess.run(['systemctl','restart','castreader-quickread-cn'],check=True)
 for _ in range(30):
  try:
   if health()['ok']:break
  except Exception:pass
  time.sleep(.2)
 else:raise RuntimeError('New QuickRead unhealthy')
 nginx(final);assert api_pid()==api_before
 print(json.dumps({'passed':True,'release':str(new),'previous':str(old),'admissionPauseSeconds':round(time.time()-start,2),'apiPidUnchanged':True,'queueDrained':True,'health':health(),'siteSHA':hashlib.sha256(site.read_bytes()).hexdigest()}))
except Exception:
 if changed:
  switch(old);drop.unlink(missing_ok=True);subprocess.run(['systemctl','daemon-reload'],check=True);subprocess.run(['systemctl','restart','castreader-quickread-cn'],check=True)
 nginx(original);raise
'''
code=code.replace(chr(92)*2+'n',chr(92)+'n')
code='expected_site_sha='+repr(oldsha)+'\n'+code
r=subprocess.run(['ssh','-i','/Users/xuxuheng/.ssh/castreader_cn_deploy','-o','BatchMode=yes','ubuntu@106.54.47.163','sudo python3 -'],input=code,text=True,capture_output=True,timeout=60)
if r.returncode:print(r.stderr);raise SystemExit(r.returncode)
print(r.stdout);(p/'cn-activation.json').write_text(r.stdout)
