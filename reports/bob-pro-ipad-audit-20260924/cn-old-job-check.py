from pathlib import Path
import subprocess,json
p=Path(__file__).parent
code=r'''
from pathlib import Path
import json,urllib.request,hashlib,subprocess
cfg={}
for line in Path('/etc/castreader/quickread-cn.env').read_text().splitlines():
 if '=' in line and not line.startswith('#'):
  k,v=line.split('=',1);cfg[k]=v.strip().strip('"').strip("'")
dir=Path('/var/lib/castreader-quickread-cn/.url-video-agent/jobs/quickread-state')
files=sorted(dir.glob('qr_*.json'),key=lambda p:p.stat().st_mtime,reverse=True)
old=None
for p in files:
 j=json.loads(p.read_text());s=j.get('spec',{})
 if s.get('_streamState',{}).get('status')=='ready' and not s.get('source_url','').startswith('https://example.invalid/') and s.get('sections'):
  old=(p,j);break
assert old
p,j=old;before=hashlib.sha256(p.read_bytes()).hexdigest()
body={'job_id':j['spec']['job_id']}
req=urllib.request.Request('http://127.0.0.1:7777/api/quickread/resume-plan',data=json.dumps(body).encode(),headers={'Content-Type':'application/json','x-api-key':cfg['QUICKREAD_API_KEY']})
with urllib.request.urlopen(req,timeout=15) as r:result=json.load(r);assert r.status==200
assert result['block_0']['text']==j['spec']['sections'][0]['text'];assert hashlib.sha256(p.read_bytes()).hexdigest()==before
statuses=[]
for host in ['https://api.castreader.cn','https://quickread.castreader.cn']:
 req=urllib.request.Request(host+'/api/quickread/extract-plan',data=b'{}',headers={'Content-Type':'application/json','x-castreader-global-ingress':'client-forged'})
 try:urllib.request.urlopen(req,timeout=15);raise RuntimeError('anonymous request bypassed CN authentication')
 except urllib.error.HTTPError as e:statuses.append(e.code);assert e.code==401
log=subprocess.check_output(['journalctl','-u','castreader-quickread-cn','--since','15 minutes ago','--no-pager'],text=True)
print(json.dumps({'oldJobResumed':True,'sameNarration':True,'persistedStateUnchanged':True,'nativeUnauthorizedStatuses':statuses,'paidGlobalGateObserved':'allow realm=global' in log and 'pro=Y' in log,'gateFailures':log.count('entitlement check failed'),'passed':True}))
'''
r=subprocess.run(['ssh','-i','/Users/xuxuheng/.ssh/castreader_cn_deploy','-o','BatchMode=yes','ubuntu@106.54.47.163','sudo python3 -'],input=code,text=True,capture_output=True,timeout=60)
if r.returncode:print(r.stderr);raise SystemExit(r.returncode)
print(r.stdout);(p/'cn-old-job-verification.json').write_text(r.stdout)
