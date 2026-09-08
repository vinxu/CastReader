"""Read existing regional monitor and backend logs; export allowlisted fields only."""
import sys,json,types,pathlib,hashlib,collections,re,subprocess,urllib.request
from datetime import datetime,timezone,timedelta
P=json.load(sys.stdin);region=P['region'];assert region in {'cn','us'}
def stamp(s):return datetime.fromisoformat(s.replace('Z','+00:00')).astimezone(timezone.utc)
start,end=map(stamp,[P['start'],P['end']])
def iso(t):return t.isoformat().replace('+00:00','Z')
def sha(b):return hashlib.sha256(b).hexdigest()
def in_window(t):return start<=t<end
m=types.ModuleType('monitor_snapshot');exec(compile(P['monitorSource'],'monitor_snapshot.py','exec'),m.__dict__)
monitor=m.aggregate(region,start,end)
monitor_root=pathlib.Path('/opt/castreader-core-audio-monitor/current').resolve()
monitor['sourceHashes']={str(p.relative_to(monitor_root)):sha(p.read_bytes())for p in monitor_root.rglob('*')if p.is_file()and not p.is_symlink()}
monitor['attempts']=[];monitor['cyclesWithMissingAttempts']=0
for path in sorted(pathlib.Path(f'/var/lib/castreader-core-audio-monitor/{region}/results').glob('*.json')):
 try:v=json.loads(path.read_bytes());t=stamp(v['observedAt'])
 except (ValueError,KeyError,TypeError):continue
 if not in_window(t):continue
 if not v.get('attemptRecords'):monitor['cyclesWithMissingAttempts']+=1
 for record in v.get('attemptRecords',[]):
  row={k:record[k]for k in ['segmentIndex','attempt','elapsedMs','httpStatus']if type(record.get(k))in {int,float}}
  for k,allowed in {'stage':{'headers','body','parse','validation','decode'},'outcome':{'complete','failed'},'errorName':{'Error','TypeError','SyntaxError','AbortError','TimeoutError','ConnectTimeoutError','HeadersTimeoutError','BodyTimeoutError','SocketError'},'transportCode':{'ECONNRESET','ECONNREFUSED','ENOTFOUND','EAI_AGAIN','ETIMEDOUT','UND_ERR_SOCKET','UND_ERR_CONNECT_TIMEOUT','UND_ERR_HEADERS_TIMEOUT','UND_ERR_BODY_TIMEOUT'}}.items():
   if record.get(k)in allowed:row[k]=record[k]
  for k,pattern in [('requestKey',r'[a-f0-9]{20}'),('code',r'[a-z][a-z0-9_]{0,70}'),('requestContract',r'[a-z][a-z0-9_-]{0,50}')]:
   if isinstance(record.get(k),str)and re.fullmatch(pattern,record[k]):row[k]=record[k]
  row['observedAt']=v['observedAt'];row['cycleSupplyOk']=v.get('supplyOk')is True;monitor['attempts'].append(row)
monitor['attemptOutcomeCounts']=dict(collections.Counter(x.get('outcome','other')for x in monitor['attempts']))
monitor['attemptCodeCounts']=dict(collections.Counter(x['code']for x in monitor['attempts']if x.get('code')))
monitor['attemptsRecoveredInHealthyCycle']=sum(x.get('outcome')=='failed' and x['cycleSupplyOk']for x in monitor['attempts'])
health={}
try:
 with urllib.request.urlopen('http://127.0.0.1:7777/health',timeout=5)as response:v=json.loads(response.read(20000));health={'status':response.status,**{k:v.get(k)for k in ['ok','queue','active','concurrency']}}
except Exception as e:health={'collectionErrorClass':type(e).__name__}
provider=[];errors=[];coverage={'rows':0,'parseErrors':0};fixed={'request_disconnected','LLM_DEADLINE_EXCEEDED','REQUEST_DISCONNECTED','DEEPSEEK_BODY_READ_FAILED','DEEPSEEK_BODY_TIMEOUT','DEEPSEEK_BODY_ABORTED','DEEPSEEK_INVALID_JSON','deadline_exceeded','budget_exceeded','kuaidao_error','server_busy','fetch failed','invalid JSON envelope','Explanation is temporarily unavailable','UND_ERR_SOCKET','ECONNRESET'}
def consume(t,msg):
 if not in_window(t):return
 if '"source":"quickread-provider"'in msg or '"source": "quickread-provider"'in msg:
  try:v=json.loads(msg[msg.index('{'):])
  except (ValueError,TypeError):coverage['parseErrors']+=1;return
  if v.get('source')!='quickread-provider':return
  row={'atUTC':iso(t)}
  for k,allowed in {'source':{'quickread-provider'},'region':{'cn','global'},'provider':{'deepseek'},'event':{'attempt_start','attempt_failed','request_finished'},'stage':{'headers','body','parse','validation'},'errorName':{'Error','TypeError','SyntaxError','AbortError','TimeoutError','ConnectTimeoutError','HeadersTimeoutError','BodyTimeoutError','SocketError'},'transportCode':{'ECONNRESET','ECONNREFUSED','ENOTFOUND','EAI_AGAIN','ETIMEDOUT','UND_ERR_SOCKET','UND_ERR_CONNECT_TIMEOUT','UND_ERR_HEADERS_TIMEOUT','UND_ERR_BODY_TIMEOUT'}}.items():
   if v.get(k)in allowed:row[k]=v[k]
  for k in ['elapsedMs','attempt','httpStatus']:
   if type(v.get(k))in {int,float}:row[k]=v[k]
  for k in ['recovered','recoveryScheduled']:
   if type(v.get(k))is bool:row[k]=v[k]
  for k,pat in [('requestKey',r'[a-f0-9]{20}'),('code',r'[A-Z][A-Z0-9_]{0,70}')]:
   if isinstance(v.get(k),str)and re.fullmatch(pat,v[k]):row[k]=v[k]
  provider.append(row)
 elif re.search(r'\berror\b|\bfailed\b|request_disconnected|deadline_exceeded',msg,re.I):
  errors.append({'atUTC':iso(t),'lineKey':sha(msg.encode())[:20],'classes':sorted(k for k in fixed if k in msg)or ['unclassified_error_line']})
if region=='cn':
 proc=subprocess.Popen(['journalctl','-u','castreader-quickread-cn.service','--since',start.strftime('%Y-%m-%d %H:%M:%S UTC'),'--until',(end+timedelta(seconds=1)).strftime('%Y-%m-%d %H:%M:%S UTC'),'-o','json','--no-pager','--quiet'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 for line in proc.stdout:
  coverage['rows']+=1
  if coverage['rows']>200000:proc.terminate();raise RuntimeError('journal_row_bound')
  try:v=json.loads(line);t=datetime.fromtimestamp(int(v['__REALTIME_TIMESTAMP'])/1000000,timezone.utc);msg=v.get('MESSAGE','')
  except (ValueError,KeyError,TypeError):coverage['parseErrors']+=1;continue
  if isinstance(msg,str):consume(t,msg)
 if proc.wait()!=0:raise RuntimeError('journal_read_failed')
 current=pathlib.Path('/opt/castreader-quickread-cn/current').resolve();source={'current':str(current),'providerSha256':sha((current/'tools/llm-provider.mjs').read_bytes()),'serverSha256':sha((current/'server/server.mjs').read_bytes())}
else:
 source={'files':[]}
 for p in [pathlib.Path('/root/.pm2/logs/quickread-out.log'),pathlib.Path('/root/.pm2/logs/quickread-error.log')]:
  assert p.stat().st_size<32000000
  raw=p.read_bytes();source['files'].append({'path':str(p),'bytes':len(raw),'sha256':sha(raw)})
  for line in raw.decode(errors='replace').splitlines():
   coverage['rows']+=1;match=re.search(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+]00:00)',line)
   if match:
    consume(stamp(match[0]),line)
   elif re.search(r'\berror\b|\bfailed\b',line,re.I):coverage['undatedErrorLines']=coverage.get('undatedErrorLines',0)+1
clone_health=None
if region=='cn':
 try:
  with urllib.request.urlopen('http://127.0.0.1:18890/health',timeout=5)as response:
   cv=json.loads(response.read(20000));clone_health={'httpStatus':response.status,**{k:cv.get(k)for k in ['status','nari_ready','accepting','busy','queue_depth','submitted','completed','failed','expired']},'counterScope':'since worker startup, not this window'}
 except Exception as e:clone_health={'collectionErrorClass':type(e).__name__}
quickread={'health':health,'source':source,'coverage':coverage,'providerEvents':provider,'providerEventCounts':dict(collections.Counter(x.get('event','unknown')for x in provider)),'providerFailureCodes':dict(collections.Counter(x.get('code','unknown')for x in provider if x.get('event')=='attempt_failed')),'providerRecoveredRequests':sum(x.get('event')=='request_finished'and x.get('recovered')is True for x in provider),'fixedErrorLines':errors}
ingress=None
if region=='cn':
 counts=collections.Counter();rows=[];sources=[];bad=0
 pattern=re.compile(r'^\S+ \S+ \S+ \[([^]]+)\] "([A-Z]+) ([^ ]+) HTTP/[^\"]+" (\d{3}) ')
 paths={'/api/captioned_speech_partly','/api/captioned_speech','/api/tts/generate','/api/tts/tts_and_transcribe','/api/markdown-tts/generate','/api/voice-clone/captioned-speech','/api/voice-clone/speech','/api/quickread/fast-block0','/api/quickread/extract-plan','/api/quickread/extract-block','/api/quickread/compose-block','/api/quickread/resume-plan'}
 for name in ['access.log.1','access.log']:
  p=pathlib.Path('/var/log/nginx')/name
  if not p.exists():sources.append({'path':str(p),'missing':True});continue
  assert p.stat().st_size<64000000
  raw=p.read_bytes();source={'path':str(p),'bytes':len(raw),'sha256':sha(raw),'firstUTC':None,'lastUTC':None}
  for line in raw.decode(errors='replace').splitlines():
   m=pattern.match(line)
   if not m:
    bad+=any(x in line for x in ['/api/tts/','/api/captioned_speech','/api/voice-clone/','/api/quickread/']);continue
   t=datetime.strptime(m[1],'%d/%b/%Y:%H:%M:%S %z').astimezone(timezone.utc)
   if source['firstUTC']is None:source['firstUTC']=iso(t)
   source['lastUTC']=iso(t);path=m[3].split('?',1)[0]
   if not in_window(t)or path not in paths:continue
   status=int(m[4]);method=m[2]if m[2]in {'GET','POST','OPTIONS','HEAD'}else 'other';counts[path,method,status]+=1
   if status!=200:rows.append({'atUTC':iso(t),'path':path,'method':method,'status':status,'lineKey':sha(line.encode())[:20]})
  sources.append(source)
 ingress={'counts':[{'path':k[0],'method':k[1],'status':k[2],'count':v}for k,v in sorted(counts.items())],'non200':rows,'sources':sources,'unparsedCoreLines':bad,'limitations':['CN QuickRead dedicated ingress has access_log off; its HTTP status totals are not covered.','HTTP 200 does not prove complete playback; 499 is a logged downstream disconnect.']}
print(json.dumps({'readOnly':True,'synthesisStarted':False,'rawContentExported':False,'region':region,'window':{'startUTC':P['start'],'endUTCExclusive':P['end']},'monitor':monitor,'quickread':quickread,'cloneHealth':clone_health,'ingress':ingress}))
