"""One fixed CN-local fast-block0 release probe; credentials remain on host."""
from pathlib import Path
import subprocess,shlex,json
HERE=Path(__file__).resolve().parent
REMOTE=r'''import pathlib,json,urllib.request,time,hashlib
from datetime import datetime,timezone
env={}
for line in pathlib.Path('/etc/castreader/quickread-cn.env').read_text().splitlines():
 if '=' in line and not line.lstrip().startswith('#'):
  k,v=line.split('=',1);v=v.strip();env[k.strip()]=v[1:-1]if len(v)>=2 and v[0]==v[-1] and v[0]in "\"'" else v
assert env.get('QUICKREAD_REGION')=='cn'
body={'title':'发布核验：像素与界面','openingParas':[{'text':'屏幕上的物理像素和 CSS 像素不是同一个概念。'},{'text':'高像素密度设备上，一个 CSS 像素可以对应多个物理像素。界面需要适应用户设置的字号。'}],'lang':'zh','depth':'standard'}
req=urllib.request.Request('http://127.0.0.1:7777/api/quickread/fast-block0',data=json.dumps(body).encode(),headers={'Content-Type':'application/json','X-Api-Key':env['QUICKREAD_API_KEY']})
started=datetime.now(timezone.utc).isoformat();t=time.monotonic()
with urllib.request.urlopen(req,timeout=45)as r:status=r.status;raw=r.read(262145)
assert len(raw)<=262144
v=json.loads(raw);block=v.get('block_0') or {};narration=block.get('narration') or ''
assert status==200 and len(narration)>0,'fixed block0 contract failed'
print(json.dumps({'ok':True,'region':'cn','startedUTC':started,'finishedUTC':datetime.now(timezone.utc).isoformat(),'path':'/api/quickread/fast-block0','httpStatus':status,'elapsedMs':round((time.monotonic()-t)*1000),'narrationCharacters':len(narration),'responseSha256':hashlib.sha256(raw).hexdigest(),'userContent':False,'ttsRequested':False,'localHTTPOnly':True}))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'ubuntu@106.54.47.163','sudo -n python3 -B -c '+shlex.quote(REMOTE)],capture_output=True,text=True,timeout=60)
if r.returncode:raise SystemExit('fixed route probe failed; raw output withheld')
v=json.loads(r.stdout);(HERE/'cn-route-probe.json').write_text(json.dumps(v,indent=2));print(json.dumps(v))
