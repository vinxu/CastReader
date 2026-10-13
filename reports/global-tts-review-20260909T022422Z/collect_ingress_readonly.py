"""Read the existing Direct ingress configuration and sanitized Caddy journal."""
from pathlib import Path
import hashlib,json,subprocess
code=r'''
import collections,hashlib,json,re,subprocess,urllib.request
from pathlib import Path
from datetime import datetime,timezone
start=datetime.fromisoformat('2026-09-08T02:24:22+00:00');end=datetime.fromisoformat('2026-09-09T02:24:22+00:00')
def get_json(url):
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
 with opener.open(url,timeout=5) as r:return json.loads(r.read(2000000))
c=get_json('http://127.0.0.1:2019/config/')
def walk(v):
 if isinstance(v,dict):
  yield v
  for x in v.values():yield from walk(x)
 elif isinstance(v,list):
  for x in v:yield from walk(x)
routes=[]
for v in walk(c.get('apps',{}).get('http',{})):
 if any('tts.castreader.ai' in m.get('host',[]) for m in v.get('match',[]) if isinstance(m,dict)):
  for h in walk(v.get('handle',[])):
   if h.get('handler')=='reverse_proxy':
    routes.append({'upstreams':[u.get('dial') if re.fullmatch(r'127\.0\.0\.1:\d+',str(u.get('dial',''))) else 'nonloopback_redacted' for u in h.get('upstreams',[])],'transport':{k:value for k,value in h.get('transport',{}).items() if k in {'protocol','dial_timeout','response_header_timeout','read_timeout','write_timeout','versions','keep_alive'}},'flushInterval':h.get('flush_interval'),'streamTimeout':h.get('stream_timeout')})
servers=[]
for name,v in c.get('apps',{}).get('http',{}).get('servers',{}).items():
 servers.append({'name':name,'timeouts':{k:v[k] for k in ['read_timeout','read_header_timeout','write_timeout','idle_timeout','keep_alive_interval'] if k in v},'accessLoggerConfigured':'logs' in v})
logs=[]
for name,v in c.get('logging',{}).get('logs',{}).items():
 w=v.get('writer',{});filename=w.get('filename')
 logs.append({'name':name,'writerOutput':w.get('output'),'filename':filename if isinstance(filename,str) and re.fullmatch('/[A-Za-z0-9_./-]{1,200}',filename) else None,'level':v.get('level')})
r=subprocess.run(['journalctl','-u','caddy','--since',start.isoformat(),'--until',end.isoformat(),'-o','json','--no-pager'],capture_output=True,text=True,timeout=30,check=True)
lines=r.stdout.splitlines();assert len(lines)<50000
rows=[];counts=collections.Counter();shapes=collections.Counter();bad=0
for line in lines:
 try:x=json.loads(line);t=datetime.fromtimestamp(int(x['__REALTIME_TIMESTAMP'])/1e6,timezone.utc)
 except (ValueError,TypeError,KeyError):bad+=1;continue
 if not start<=t<end:continue
 try:v=json.loads(x.get('MESSAGE',''))
 except (ValueError,TypeError):counts['non_json']+=1;continue
 if not isinstance(v,dict):continue
 req=v.get('request',{});host=req.get('host');uri=str(req.get('uri','')).split('?',1)[0]
 shapes[str(bool(req))]+=1
 if host!='tts.castreader.ai' or uri!='/api/captioned_speech_partly':continue
 msg=' '.join(str(v.get(k,'')) for k in ['msg','error','err_trace','err_id'])
 kinds=[label for needle,label in [('context canceled','context_cancelled'),('context deadline exceeded','deadline_exceeded'),('i/o timeout','io_timeout'),('connection reset','connection_reset'),('stream error','http2_stream_error'),('CANCEL','stream_cancel'),('EOF','eof'),('broken pipe','broken_pipe')] if needle in msg]
 hdr=req.get('headers',{});request_id=next(iter(hdr.get('X-Request-Id',[]) or []),None)
 peer=req.get('client_ip') or req.get('remote_ip')
 rows.append({'timestampUTC':t.isoformat(),'httpProtocol':req.get('proto') if req.get('proto') in {'HTTP/1.1','HTTP/2.0','HTTP/3.0'} else 'other','method':req.get('method') if req.get('method') in {'POST','HEAD','GET'} else 'other','status':v.get('status') if type(v.get('status')) is int else None,'durationSeconds':v.get('duration') if type(v.get('duration')) in {int,float} else None,'errorClasses':kinds or ['unclassified'],'requestKey':hashlib.sha256(request_id.encode()).hexdigest()[:20] if isinstance(request_id,str) else None,'peerKey':hashlib.sha256(str(peer).encode()).hexdigest()[:20] if peer else None})
 counts.update(kinds or ['unclassified'])
def unit(name):
 s=subprocess.check_output(['systemctl','show',name,'--property=MainPID,NRestarts,ActiveState,SubState,ExecMainStartTimestamp'],text=True)
 return dict(l.split('=',1) for l in s.splitlines() if '=' in l)
files={}
for name in ['/etc/caddy/Caddyfile','/opt/castreader-tts-gateway/gateway.mjs']:
 raw=Path(name).read_bytes();files[name]={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
print('SAFE='+json.dumps({'readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'observedAtUTC':datetime.now(timezone.utc).isoformat(),'fixedWindow':{'startUTC':start.isoformat(),'endUTCExclusive':end.isoformat()},'files':files,'caddyRuntimeConfigSha256':hashlib.sha256(json.dumps(c,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'directRoutes':routes,'httpServers':servers,'logWriters':logs,'units':{n:unit(n) for n in ['caddy','castreader-tts-gateway.service']},'journal':{'rowsRead':len(lines),'parseErrors':bad,'targetRecords':rows,'fixedErrorClassCounts':dict(counts),'withRequestObjectCounts':dict(shapes)},'limitations':['Only existing logs and localhost configuration were read; no access logging was enabled.','Request keys exist only if the caller supplied a request ID that Caddy retained. Peer hashes are not account or user counts.','No text, credentials, raw identifiers, user agents or raw error messages exported.']}))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3 -B -'],input=code,text=True,capture_output=True,timeout=60)
rows=[line[5:] for line in r.stdout.splitlines() if line.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('ingress_read_failed')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with Path(__file__).with_name('ingress-readback.json').open('x') as f:json.dump(v,f,indent=2);f.write('\n')
print(json.dumps(v))
