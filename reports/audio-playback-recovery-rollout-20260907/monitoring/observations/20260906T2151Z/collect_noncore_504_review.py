"""Bounded request-metadata-only Vercel review; no raw content is exported."""
import sys,json,hashlib,subprocess,re,urllib.request,urllib.parse,datetime,math
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
import collect_vercel_preset_events as base
REPO=Path('/Users/xuxuheng/Documents/MyProject/readout-web')
PROJECT='prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK'
START='2026-09-06T20:51:42.476216Z'
END='2026-09-06T21:52:41.458505Z'
SOURCE='1f9a483c'
paths=subprocess.check_output(['git','ls-tree','-r','--name-only',SOURCE,'src/app'],cwd=REPO,text=True).splitlines()
routes=[]
static_segments=set()
for p in paths:
 if p.endswith(('/route.ts','/route.js','/page.tsx','/page.ts','/page.js')):
  route='/'+p.removeprefix('src/app/').rsplit('/',1)[0]
  if route=='/src/app':route='/'
  segments=[part for part in route.split('/') if part and not part.startswith('(')]
  route='/'+ '/'.join(segments)
  static_segments.update(part for part in segments if not part.startswith('['))
  parts=[]
  for part in segments:
   if part.startswith('[[...'):parts.append('.*')
   elif part.startswith('[...'):parts.append('.+')
   elif part.startswith('['):parts.append('[^/]+')
   else:parts.append(re.escape(part))
  routes.append((route,re.compile('^/'+'/'.join(parts)+'/?$')))
routes.sort(key=lambda x: (x[0].count('['),-len(x[0])))
def normalize(p):
 if not isinstance(p,str):return None
 if p.startswith(('https://','http://')):p=urllib.parse.urlsplit(p).path
 p=p.split('?',1)[0]
 # Reviewed locale middleware exposes an unprefixed alias; do not misread
 # '/blog/slug' as a generic locale/slug route.
 parts=p.strip('/').split('/')
 if len(parts)==2 and parts[0]=='blog':return '/blog/[slug]'
 if len(parts)==3 and parts[0] in {'en','zh'} and parts[1]=='blog':return '/[locale]/blog/[slug]'
 for route,pat in routes:
  if pat.fullmatch(p):return route
 return '[unmapped_route]'
def shape(p):
 if not isinstance(p,str):return None
 parts=p.split('?',1)[0].split('/')
 return {'isLeadingSlash':p.startswith('/'),'isAbsoluteURL':p.startswith(('https://','http://')),'segmentCount':len(parts),'normalizedStaticSegments':[part if part in static_segments or part in {'api','en','de','es','fr','hi','it','ja','pt','zh','zh-CN','pt-BR'} else '[dynamic_or_unknown]' for part in parts if part]}
def anon(v):return hashlib.sha256(v.encode()).hexdigest()[:20] if isinstance(v,str) and v else None
NUM={'requestDurationMs','functionDurationMs','durationMs','executionDurationMs','functionMaxDuration','functionMemorySize','functionMaxMemoryUsed','functionColdStartDurationMs','statusCode','responseStatusCode'}
ENUM={'region':{'iad1','sfo1','hkg1','sin1','pdx1','cle1','fra1','cdg1','lhr1','bom1','icn1','hnd1','syd1','gru1','dxb1'},'functionRegion':{'iad1','sfo1','hkg1','sin1','pdx1','cle1','fra1','cdg1','lhr1','bom1','icn1','hnd1','syd1','gru1','dxb1'},'errorCode':{'FUNCTION_INVOCATION_TIMEOUT','EDGE_FUNCTION_INVOCATION_TIMEOUT','MIDDLEWARE_INVOCATION_TIMEOUT','ROUTER_EXTERNAL_TARGET_CONNECTION_ERROR','ROUTER_EXTERNAL_TARGET_ERROR','FUNCTION_INVOCATION_FAILED','INTERNAL_FUNCTION_INVOCATION_TIMEOUT'},'functionRuntime':{'nodejs','edge','nodejs22.x','nodejs20.x','python'},'requestMethod':{'GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS'}}
def safe(v):
 out={}
 for k in NUM:
  if k in v:
   z=v[k]
   out[k]=z if type(z) in (int,float) and math.isfinite(z) else None
 for k,values in ENUM.items():
  if k in v:out[k]=v[k] if v[k] in values else '[unrecognized_or_missing]'
 for k in ['hasFunctionCrashed','coldStart','isColdStart']:
  if k in v:out[k]=v[k] if type(v[k]) is bool else None
 for k in ['timestamp','startTime','endTime']:
  if k in v:
   try:out[k]=base.stamp(base.utc(v[k]))
   except (ValueError,TypeError):out[k]=None
 for k in ['path','requestPath','functionName']:
  if k in v:out[k]=normalize(v[k])
 return out
project=json.loads((REPO/'.vercel/project.json').read_text())
assert project['projectId']==PROJECT,'project_mismatch'
credential=json.loads((Path.home()/'Library/Application Support/com.vercel.cli/auth.json').read_text())['token']
ctx=base.tls_context();opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),base.NoRedirect())
q={'projectId':PROJECT,'ownerId':project['orgId'],'page':0,'startDate':int(base.utc(START).timestamp()*1000),'endDate':int(base.utc(END).timestamp()*1000),'environment':'production','statusCode':'504'}
req=urllib.request.Request('https://vercel.com/api/logs/request-logs?'+urllib.parse.urlencode(q),headers={'Authorization':'Bearer '+credential,'Accept':'application/json'})
try:
 with opener.open(req,timeout=40) as response:raw=response.read(base.MAX_HTTP_BYTES+1)
 if len(raw)>base.MAX_HTTP_BYTES:raise RuntimeError('response_size_limit')
 data=json.loads(raw)
 assert isinstance(data.get('rows'),list),'invalid_response'
 rows=[];rejected=0
 for row in data['rows']:
  if row.get('statusCode')!=504:rejected+=1;continue
  try:t=base.utc(row.get('timestamp'))
  except (ValueError,TypeError):rejected+=1;continue
  if not base.utc(START)<=t<base.utc(END):rejected+=1;continue
  dep=row.get('deploymentId')
  x={'requestKey':anon(row.get('requestId')),'path':normalize(row.get('requestPath')),'deploymentId':dep if isinstance(dep,str) and re.fullmatch(r'dpl_[A-Za-z0-9]+',dep) else None,**safe(row)}
  x['events']={k:[safe(event) for event in row.get(k,[]) if isinstance(event,dict)] for k in ['events','proxyEvents','functionEvents'] if isinstance(row.get(k),list)}
  x['requestPathShape']=shape(row.get('requestPath'))
  x['nestedLogCount']=len(row.get('logs',[])) if isinstance(row.get('logs'),list) else None
  x['bodyOrMessagesInspected']=False
  rows.append(x)
 result={'schema':'castreader.noncore-504-metadata.v1','readOnly':True,'productionModified':False,'synthesisStarted':False,'rawIdentityExported':False,'rawContentExported':False,'TLSCertificateAndHostnameVerification':True,'query':{'projectId':PROJECT,'environment':'production','statusCode':504,'startInclusive':START,'endExclusive':END,'queriesUsed':1},'sourceRouteManifestCommit':subprocess.check_output(['git','rev-parse',SOURCE],cwd=REPO,text=True).strip(),'observedAtUtc':base.stamp(datetime.datetime.now(datetime.timezone.utc)),'coverage':{'returnedRows':len(data['rows']),'selectedRows':len(rows),'rejectedRows':rejected,'hasMoreRows':data.get('hasMoreRows'),'completePagination':data.get('hasMoreRows') is False,'providerIngestionComplete':None},'records':rows,'limitations':['Provider request-start cohort; completion may follow the end bound.','No body, audio, message or arbitrary nested log was inspected.','An unknown route stays unknown; other is not automatically non-audio.','No matching mobile TTS/LLM request or trace key has been established.']}
 (HERE/'noncore-504-review.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({'selected':len(rows),'hasMoreRows':data.get('hasMoreRows'),'paths':sorted({r['path'] for r in rows}),'durationMs':sorted({r.get('requestDurationMs') for r in rows},key=str),'status':sorted({r.get('statusCode') for r in rows},key=str),'deployments':sorted({r.get('deploymentId') for r in rows},key=str)},ensure_ascii=False))
except Exception as e:
 print(json.dumps({'readOnly':True,'errorClass':type(e).__name__,'httpStatus':getattr(e,'code',None)}))
 raise SystemExit(1)
