from pathlib import Path
import subprocess,json,hashlib
HERE=Path(__file__).resolve().parent
REMOTE=r'''
from pathlib import Path
from datetime import datetime,timezone
from collections import Counter,defaultdict
import json,re,hashlib,os
start='2026-09-08T17:40:00';end='2026-09-08T18:30:00'
paths=[Path('/var/log')/n for n in ['ssh_proxy.log','castreader-tts-runtime-agent.log','castreader-tts-runtime-agent.err.log','instance_portal.log','tunnel_manager.log','caddy.log']]
paths+=[Path('/var/log/portal')/n for n in ['instance_portal.log','tunnel_manager.log','syncthing.log','castreader-clone-error.log','castreader-clone-tls-error.log','castreader-clone-cloudflare-error.log']]
paths+=[Path('/var/log/supervisor/supervisord.log')]
terms=['connection refused','connection reset','network is unreachable','no route to host','i/o timeout','timeout','timed out','connection closed','reconnect','reconnected','connected','disconnected','failed to dial','TLS handshake','quic','TCP','udp','Unable to reach','failed','error','spawned','exited','stopped','SIGKILL','SIGTERM','OOM','out of memory','restart','heartbeat','healthy','unhealthy','poll','health','200','502','503','504']
def stamp(line,value):
 for key in ['time_unix','ts','timestamp','at','observedAt','checkedAt','time']:
  v=value.get(key) if isinstance(value,dict) else None
  if isinstance(v,(int,float)) and 1700000000<v<1900000000:return datetime.fromtimestamp(v,timezone.utc).isoformat()[:26]
  if isinstance(v,str):
   m=re.search(r'2026-09-\d\d[T ]\d\d:\d\d:\d\d(?:[.,]\d+)?',v)
   if m:return m[0].replace(' ','T').replace(',','.')
 m=re.search(r'2026-09-\d\d[T ]\d\d:\d\d:\d\d(?:[.,]\d+)?',line)
 return m[0].replace(' ','T').replace(',','.') if m else None
out=[]
for p in paths:
 if not p.exists():continue
 raw=p.read_bytes();stat=p.stat();entries=[];minutes=Counter();fields=Counter();first=last=None;matched=0;without=0;codes=Counter()
 for line in raw.decode(errors='replace').splitlines():
  try:v=json.loads(line[line.index('{'):])
  except (ValueError,TypeError):v=None
  t=stamp(line,v)
  if not t:without+=1;continue
  first=t if first is None else min(first,t);last=t if last is None else max(last,t)
  if not start<=t<end:continue
  matched+=1;minutes[t[:16]]+=1
  if isinstance(v,dict):fields.update(v.keys())
  fragments=[s for s in terms if s.lower() in line.lower()];codes.update(fragments)
  item={'atUTC':t,'fixedFragments':fragments}
  if isinstance(v,dict):
   item['safeScalars']={k:x for k,x in v.items() if k.lower() in ['status','statuscode','ok','healthy','elapsedms','durationms','uptime','revision','pid','active','queued'] and isinstance(x,(int,float,bool))}
  if len(entries)<1000:entries.append(item)
 out.append({'path':str(p),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'mtimeUnix':stat.st_mtime,'firstTimestamp':first,'lastTimestamp':last,'linesWithoutRecognizedTimestamp':without,'selectedLines':matched,'minuteCounts':dict(minutes),'fixedFragmentCounts':dict(codes),'jsonFieldNames':list(fields),'events':entries,'eventsTruncated':matched>len(entries)})
print('SAFE='+json.dumps({'readOnly':True,'synthesisStarted':False,'window':{'startUTC':start+'Z','endUTC':end+'Z'},'sources':out}))
'''
r=subprocess.run(['ssh','-C','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -'],input=REMOTE,text=True,capture_output=True,timeout=45)
lines=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(lines)!=1:raise RuntimeError('host_log_read_failed')
v=json.loads(lines[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest();(HERE/'host-logs.json').write_text(json.dumps(v,indent=2))
print(json.dumps([{k:x[k] for k in ['path','selectedLines','firstTimestamp','lastTimestamp','fixedFragmentCounts','jsonFieldNames']} for x in v['sources']]))
