from pathlib import Path
import subprocess,json,hashlib
HERE=Path(__file__).resolve().parent
REMOTE=r'''
from pathlib import Path
from datetime import datetime,timezone
import os,re,json,hashlib,urllib.parse,urllib.request,urllib.error
config=Path('/etc/supervisor/conf.d/castreader-tts-runtime-agent.conf');s=config.read_text();processes=[]
flags={'--public-api-host','--public-api-port','--tts-port','--primary-service','--release-link','--sample-interval','--report-interval','--command-timeout','--request-timeout','--replay-max-age'}
for p in Path('/proc').iterdir():
 if not p.name.isdigit():continue
 try:argv=(p/'cmdline').read_bytes().decode().split('\0')
 except (OSError,UnicodeError):continue
 scripts=[x for x in argv if x.startswith('/opt/castreader-ops/') and x.endswith('/tts_runtime_agent.py')]
 if not scripts:continue
 safe={argv[i]:argv[i+1] for i in range(len(argv)-1) if argv[i] in flags}
 src=Path(scripts[0]);processes.append({'pid':int(p.name),'sourcePath':str(src),'sourceSha256':hashlib.sha256(src.read_bytes()).hexdigest(),'startTicks':(p/'stat').read_text().rsplit(')',1)[1].split()[19],'flags':safe})
out={'readOnly':True,'capturedAtUTC':datetime.now(timezone.utc).isoformat(),'configSha256':hashlib.sha256(config.read_bytes()).hexdigest(),'processes':processes,'containerInstanceId':os.environ['CONTAINER_ID']}
req=urllib.request.Request('https://console.vast.ai/api/v0/instances/'+os.environ['CONTAINER_ID']+'/?owner=me',headers={'Authorization':'Bearer '+os.environ['CONTAINER_API_KEY']})
try:
 with urllib.request.urlopen(req,timeout=15)as r:d=json.load(r)['instances']
 out['providerInstance']={k:d.get(k) for k in ['id','machine_id','actual_status','intended_status','cur_state','start_date','uptime_mins','host_run_time','client_run_time']}
except Exception as e:out['providerReadError']={'class':type(e).__name__,'httpStatus':getattr(e,'code',None)}
print('SAFE='+json.dumps(out))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -'],input=REMOTE,text=True,capture_output=True,timeout=35)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('identity_read_failed')
v=json.loads(rows[0]);(HERE/'runtime-identity.json').write_text(json.dumps(v,indent=2));print(json.dumps(v))
