"""Read existing CN core ingress and classify monitor/QuickRead errors remotely."""
from pathlib import Path
import hashlib,json,subprocess
HERE=Path(__file__).resolve().parent
REMOTE=r'''
from pathlib import Path
from datetime import datetime,timezone
import collections,hashlib,json,re,subprocess
start=datetime.fromisoformat('2026-09-07T12:18:27+00:00');end=datetime.fromisoformat('2026-09-08T12:18:27+00:00')
known={'fetch failed','AbortError','TimeoutError','ConnectTimeoutError','HeadersTimeoutError','UND_ERR_CONNECT_TIMEOUT','UND_ERR_HEADERS_TIMEOUT','UND_ERR_SOCKET','ECONNRESET','ECONNREFUSED','EAI_AGAIN','ENOTFOUND','ETIMEDOUT','budget_exceeded','deadline_exceeded','request_disconnected','Unexpected end of JSON input','Unexpected token','JSON Parse error','timed out','timeout','cancelled','invalid_api_key','insufficient_quota','quota_exceeded','rate_limit','502','503','504','429','400','missing_openingParas'}
def classify(s):return sorted(k for k in known if k in s)
def stamp(s):
 try:return datetime.fromisoformat(s.replace('Z','+00:00')).astimezone(timezone.utc)
 except (TypeError,ValueError,AttributeError):return None
counts=collections.Counter();non200=[];sources=[];unparsed_core=0
pat=re.compile(r'^\S+ \S+ \S+ \[([^]]+)\] "([A-Z]+) ([^ ]+) HTTP/[^\"]+" (\d{3}) ')
def group(path):
 if path in {'/api/captioned_speech_partly','/api/captioned_speech','/api/tts/generate','/api/tts/tts_and_transcribe','/api/markdown-tts/generate'}:return 'tts',path
 if path.startswith('/api/quickread/') or path.startswith('/quickread/') or path in {'/extract-plan','/extract-block','/compose-block','/fast-block0','/extract','/compose','/resume-plan'}:
  tail=path.rsplit('/',1)[-1]
  return 'quickread','/api/quickread/'+(tail if tail in {'extract-plan','extract-block','compose-block','extract','compose','fast-block0','resume-plan','health'} else '[other]')
 if path.startswith('/api/voice-clone/'):
  tail=path.rsplit('/',1)[-1]
  return 'clone','/api/voice-clone/'+(tail if tail in {'captioned-speech','speech','voices','quota','create','health','denoise','upload','reference'} else '[other]')
 return None,None
for name in ['access.log.1','access.log']:
 p=Path('/var/log/nginx')/name;raw=p.read_bytes();first=last=None;bad=0
 for line in raw.decode(errors='replace').splitlines():
  m=pat.match(line)
  if not m:
   bad+=1;unparsed_core+=any(k in line for k in ['/api/quickread/','/api/voice-clone/','/api/captioned_speech','/api/tts/']);continue
  t=datetime.strptime(m[1],'%d/%b/%Y:%H:%M:%S %z').astimezone(timezone.utc);first=t if first is None else min(first,t);last=t if last is None else max(last,t)
  g,path=group(m[3].split('?',1)[0])
  if not g or not start<=t<end:continue
  status=int(m[4]);method=m[2] if m[2] in ['POST','GET','OPTIONS','HEAD','DELETE'] else 'other';counts[g,path,method,status]+=1
  if status!=200:non200.append({'atUTC':t.isoformat(),'group':g,'path':path,'method':method,'status':status,'lineKey':hashlib.sha256(line.encode()).hexdigest()[:20]})
 sources.append({'path':str(p),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'unparsedLines':bad,'firstUTC':first.isoformat() if first else None,'lastUTC':last.isoformat() if last else None})
fail=[]
for p in Path('/var/lib/castreader-core-audio-monitor/cn/results').glob('*.json'):
 v=json.loads(p.read_bytes());t=stamp(v.get('observedAt'))
 if not t or not start<=t<end or v.get('supplyOk') is True:continue
 row={'observedAtUTC':t.isoformat(),'filename':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'elapsedMs':v.get('elapsedMs'),'status':v.get('status'),'failureCode':v.get('failureCode'),'failedRequestContract':v.get('failedRequestContract'),'segmentCount':v.get('segmentCount'),'errorFieldTypes':{},'errorMatches':{}}
 for k,val in v.items():
  if 'error' in k.lower() or 'failure' in k.lower():row['errorFieldTypes'][k]=type(val).__name__;row['errorMatches'][k]=classify(json.dumps(val))
 row['segments']=[{k:s.get(k) for k in ['index','attempts','requestContract','processedCharacters','remainingCharacters','audioBytes','upstreamNode']} for s in v.get('segments',[])]
 fail.append(row)
j=subprocess.run(['journalctl','-u','castreader-quickread-cn.service','--since',start.strftime('%Y-%m-%d %H:%M:%S UTC'),'--until',end.strftime('%Y-%m-%d %H:%M:%S UTC'),'-o','json','--no-pager'],capture_output=True,text=True,check=True,timeout=20)
errors=[]
for line in j.stdout.splitlines():
 v=json.loads(line);msg=str(v.get('MESSAGE',''));t=datetime.fromtimestamp(int(v['__REALTIME_TIMESTAMP'])/1000000,timezone.utc)
 if not start<=t<end or ' error:' not in msg:continue
 tag=next((s for s in ['fast-block0 error:','extract-plan error:','extract-block error:','compose-block error:'] if s in msg),None)
 if not tag:continue
 message=msg.split(tag,1)[1].strip();matches=[]
 root=Path('/opt/castreader-quickread-cn/releases/20260906-quickread-playback-continuity-3d68d82-cn')
 for src in root.rglob('*.mjs'):
  if 'node_modules' in src.parts or src.stat().st_size>2000000:continue
  content=src.read_text(errors='replace')
  if message and message in content:matches.append({'file':str(src.relative_to(root)),'line':content[:content.index(message)].count('\n')+1,'sourceSha256':hashlib.sha256(src.read_bytes()).hexdigest()})
 errors.append({'atUTC':t.isoformat(),'tag':tag,'messageSha256':hashlib.sha256(message.encode()).hexdigest(),'classifiedFragments':classify(message),'matchingSourceLiterals':matches})
print('SAFE='+json.dumps({'readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'window':{'startUTC':start.isoformat(),'endUTCExclusive':end.isoformat()},'ingress':{'sources':sources,'unparsedLinesContainingCoreRoute':unparsed_core,'counts':[{'group':k[0],'path':k[1],'method':k[2],'status':k[3],'count':v} for k,v in sorted(counts.items())],'non200Rows':non200},'monitorFailures':fail,'quickreadErrors':errors}))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'ubuntu@106.54.47.163','sudo -n python3 -B -'],input=REMOTE,text=True,capture_output=True,timeout=55)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('sanitized_cn_details_failed')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with (HERE/'cn-details-aliases.json').open('x')as f:json.dump(v,f,indent=2)
print(json.dumps({'ingressCounts':v['ingress']['counts'],'monitorFailures':v['monitorFailures'],'quickreadErrors':v['quickreadErrors'],'unparsedCore':v['ingress']['unparsedLinesContainingCoreRoute']}))
