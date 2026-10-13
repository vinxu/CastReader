from pathlib import Path
import json,subprocess,hashlib
HERE=Path(__file__).resolve().parent
REMOTE=r'''
from pathlib import Path
from datetime import datetime,timezone
from collections import Counter
import json,re,hashlib,urllib.parse
start='2026-09-08T17:40';end='2026-09-08T18:30';agent=[];tunnels=[]
p=Path('/var/log/castreader-tts-runtime-agent.log')
for line in p.read_text().splitlines():
 try:v=json.loads(line)
 except ValueError:continue
 if not start<=v.get('at','')<end:continue
 r={k:x for k,x in v.items() if k in ['at','collector_error_count','sample_count','spool_depth','dropped_invalid','dropped_stale','sent'] and isinstance(x,(str,int,float,bool))}
 for k in ['event','reason','failure']:
  x=v.get(k)
  if isinstance(x,str) and re.fullmatch(r'[A-Za-z0-9_.:-]{1,120}',x):r[k]=x
 agent.append(r)
q=Path('/var/log/tunnel_manager.log')
patterns={'Lost connection with the edge':'edge_lost','Registered tunnel connection':'edge_registered','Unable to establish connection with Cloudflare edge':'edge_connect_failed','Serve tunnel error':'serve_error','Connection terminated':'connection_terminated','Retrying connection':'retry_scheduled'}
for line in q.read_text().splitlines():
 t=re.search(r'2026-09-08T\d\d:\d\d:\d\dZ',line)
 if not t or not start<=t[0]<end:continue
 event=next((v for k,v in patterns.items() if k in line),None)
 if not event:continue
 prefix=line[:t.start()];r={'atUTC':t[0],'event':event,'tunnelKey':hashlib.sha256(prefix.encode()).hexdigest()[:20]}
 r['errorClass']='tcp_connect_timeout' if 'dial tcp' in line and 'i/o timeout' in line else 'edge_connection_closed' if 'connection with edge closed' in line else 'control_stream_cancelled' if 'control stream: context canceled' in line else None
 m=re.search(r'dial tcp (\d+\.\d+\.\d+\.\d+):(\d+)',line)
 if m:r['remotePeerKey']=hashlib.sha256(m[1].encode()).hexdigest()[:20];r['remotePort']=int(m[2])
 if 'protocol=http2' in line:r['protocol']='http2'
 tunnels.append(r)
conf=Path('/etc/supervisor/conf.d/castreader-tts-runtime-agent.conf');text=conf.read_text();domains=sorted({urllib.parse.urlsplit(x).hostname for x in re.findall(r'https?://[^\s,\"\']+',text)})
print('SAFE='+json.dumps({'readOnly':True,'window':{'startUTC':start+':00Z','endUTCExclusive':end+':00Z'},'capturedAtUTC':datetime.now(timezone.utc).isoformat(),'agent':{'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'events':agent,'configSha256':hashlib.sha256(conf.read_bytes()).hexdigest(),'reportDomains':domains},'tunnels':{'path':str(q),'sha256':hashlib.sha256(q.read_bytes()).hexdigest(),'events':tunnels},'limitations':['Tunnel log lines can repeat the same connection failure; counts are log events, not independent outages.','collector_error_count is a metric field; report_accepted with nonzero collector errors does not mean upload failed.']}))
'''
r=subprocess.run(['ssh','-C','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -'],input=REMOTE,text=True,capture_output=True,timeout=40)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('read_failed')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest();(HERE/'cross-channel-evidence.json').write_text(json.dumps(v,indent=2))
print(json.dumps({'agentEvents':len(v['agent']['events']),'tunnelEvents':len(v['tunnels']['events']),'reportDomains':v['agent']['reportDomains']}))
