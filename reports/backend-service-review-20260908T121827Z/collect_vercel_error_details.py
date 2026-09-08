"""Read fixed error metadata only; never export request payloads or exception text."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import sys,json,hashlib,re,urllib.request,urllib.parse
HERE=Path(__file__).resolve().parent; ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT/'reports/audio-playback-recovery-rollout-20260907/monitoring'))
import collect_vercel_preset_events as v
project=json.loads((v.REPO/'.vercel/project.json').read_text())
token=json.loads((Path.home()/'Library/Application Support/com.vercel.cli/auth.json').read_text())['token']
phrases=['FUNCTION_INVOCATION_TIMEOUT','EDGE_FUNCTION_INVOCATION_TIMEOUT','FUNCTION_INVOCATION_FAILED','MIDDLEWARE_INVOCATION_TIMEOUT','Request timed out','Task timed out','60 seconds','fetch failed','ECONNRESET','ETIMEDOUT','UND_ERR_SOCKET','quota','QUOTA','rate_limit','rate limit','Rate limit','RATE_LIMIT','daily_limit','limit_exceeded','TTS_REQUEST_CANCELLED','TTS_TOTAL_BUDGET_EXCEEDED','too_many_requests','member','free','pro','Redis','Upstash','database','connection','credential','denied','Unauthorized','not supported','Not Allowed','Method Not Allowed','budget','timeout','timed out','429','503','502','500']
def safe_path(raw):
 p=str(raw or '').split('?',1)[0]
 return p if re.fullmatch(r'/[A-Za-z_/-]{1,140}',p) else '[path-redacted]'
def one(task):
 mask,left,right=task
 q={'projectId':project['projectId'],'ownerId':project['orgId'],'page':0,'environment':'production','statusCode':mask,'startDate':int(v.utc(left).timestamp()*1000),'endDate':int(v.utc(right).timestamp()*1000)}
 req=urllib.request.Request('https://vercel.com/api/logs/request-logs?'+urllib.parse.urlencode(q),headers={'Authorization':'Bearer '+token,'Accept':'application/json'})
 opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=v.tls_context()),v.NoRedirect())
 with opener.open(req,timeout=30) as response: data=json.loads(response.read(v.MAX_HTTP_BYTES))
 rows=[]
 for r in data.get('rows',[]):
  logs=[]
  for l in r.get('logs',[]):
   s=str(l.get('message',''));events=[]
   for line in s.splitlines():
    try:e=v.safe_event(json.loads(line))
    except (ValueError,TypeError):continue
    if e:events.append(e)
   logs.append({'level':l.get('level'),'messageSha256':hashlib.sha256(s.encode()).hexdigest(),'messageBytes':len(s.encode()),'messageTruncated':l.get('messageTruncated'),'fixedFragments':[p for p in phrases if p in s],'events':events})
  meta=[]
  for e in r.get('events',[]):
   meta.append({k:e[k] for k in ['source','type','statusCode','region','duration','durationMs'] if k in e and (type(e[k]) in {int,float,bool} or re.fullmatch(r'[A-Za-z0-9_.-]{1,70}',str(e[k])))})
  rows.append({'key':v.anonymous(r.get('requestId')),'atUTC':r.get('timestamp'),'path':safe_path(r.get('requestPath')),'method':r.get('requestMethod'),'status':r.get('statusCode'),'durationMs':r.get('requestDurationMs'),'deploymentId':r.get('deploymentId'),'logs':logs,'eventsMetadata':meta,'recordFieldNames':sorted(r)})
 return {'query':task,'hasMoreRows':data.get('hasMoreRows'),'rows':rows}
tasks=[('5xx','2026-09-07T20:18:27Z','2026-09-07T21:18:27Z'),('5xx','2026-09-08T08:18:27Z','2026-09-08T09:18:27Z'),('5xx','2026-09-07T12:18:27Z','2026-09-07T13:18:27Z'),('429','2026-09-08T09:43:00Z','2026-09-08T09:45:00Z')]
with ThreadPoolExecutor(max_workers=2) as pool: values=list(pool.map(one,tasks))
out={'readOnly':True,'productionModified':False,'rawContentExported':False,'queries':values,'collectorSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
with (HERE/'vercel-error-details.json').open('x') as f:json.dump(out,f,indent=2)
print(json.dumps(out))
