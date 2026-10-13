"""Bounded hourly non-200 log read, independently of paid metrics."""
from pathlib import Path
from collections import Counter
from datetime import timedelta
from concurrent.futures import ThreadPoolExecutor,as_completed
import sys,json,urllib.request,urllib.parse,urllib.error,hashlib
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT/'reports/audio-playback-recovery-rollout-20260907/monitoring'))
sys.path.insert(0,str(ROOT/'reports/backend-audio-iteration-20260906/monitoring'))
import collect_vercel_preset_events as v
import collect_acceptance as c
import ssl
v.tls_context = ssl.create_default_context # system trust store; hostname and certificate verification remain enabled
project=json.loads((v.REPO/'.vercel/project.json').read_text())
credential=json.loads((Path.home()/'Library/Application Support/com.vercel.cli/auth.json').read_text())['token']
start=v.utc('2026-09-08T02:24:22Z');end=v.utc('2026-09-09T02:24:22Z')
def collect(task):
 mask,left,right=task;cursor=right;seen=set();core=[];other=Counter();pages=0;issues=[];more=True
 opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=v.tls_context()),v.NoRedirect())
 try:
  while pages<8 and more:
   q={'projectId':project['projectId'],'ownerId':project['orgId'],'page':0,'environment':'production','statusCode':mask,'startDate':int(left.timestamp()*1000),'endDate':int(cursor.timestamp()*1000)}
   req=urllib.request.Request('https://vercel.com/api/logs/request-logs?'+urllib.parse.urlencode(q),headers={'Authorization':'Bearer '+credential,'Accept':'application/json'})
   with opener.open(req,timeout=25)as response:raw=response.read(v.MAX_HTTP_BYTES+1)
   if len(raw)>v.MAX_HTTP_BYTES:raise ValueError('response_limit')
   data=json.loads(raw);batch=data['rows'];more=data.get('hasMoreRows') is True;pages+=1;times=[]
   for row in batch:
    t=v.utc(row['timestamp']);key=v.anonymous(row.get('requestId'))
    if not left<=t<right or key is None:continue
    times.append(t)
    if key in seen:continue
    seen.add(key);path,group=c.normalize_vercel_path(row.get('requestPath'));status=row.get('statusCode')
    if group=='other':other[str(status)]+=1;continue
    x=c.sanitize_vercel({**row,'id':row['requestId'],'timestamp':t.timestamp()*1000,'responseStatusCode':status},left,right)
    x['durationMs']=row.get('requestDurationMs') if v.number(row.get('requestDurationMs')) else None
    x['method']=row.get('requestMethod') if row.get('requestMethod') in {'GET','POST','OPTIONS','HEAD','DELETE'} else 'other'
    core.append(x)
   if more:
    new=min(times)+timedelta(milliseconds=1) if times else cursor
    if new>=cursor:issues.append('nonadvancing_cursor');break
    cursor=new
  if more:issues.append('pagination_incomplete')
 except Exception as e:
  issues.append(type(e).__name__+('_'+str(e.code) if isinstance(e,urllib.error.HTTPError) else ''))
 out={'statusQuery':mask,'startUTC':v.stamp(left),'endUTCExclusive':v.stamp(right),'pages':pages,'issues':issues,'completeReturnedPages':not issues,'uniqueRequests':len(seen),'coreRecords':core,'otherStatusCounts':dict(other)}
 with (HERE/'vercel-hourly'/f'{mask}-{left.strftime("%Y%m%dT%H%M%SZ")}.json').open('x') as f:json.dump(out,f,indent=2)
 return out
(HERE/'vercel-hourly').mkdir(exist_ok=True)
for mask in ['5xx','4xx','3xx']:
 tasks=[(mask,start+timedelta(hours=i),min(start+timedelta(hours=i+1),end)) for i in range(24)]
 results=[]
 with ThreadPoolExecutor(max_workers=2)as pool:
  for f in as_completed([pool.submit(collect,t) for t in tasks]):results.append(f.result())
 out={'readOnly':True,'productionModified':False,'rawContentExported':False,'statusQuery':mask,'window':{'startUTC':v.stamp(start),'endUTCExclusive':v.stamp(end)},'shards':sorted(results,key=lambda x:x['startUTC']),'allShardsComplete':all(r['completeReturnedPages'] for r in results),'coreRecords':[r for s in results for r in s['coreRecords']],'collectorSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'limitations':['Covers returned request logs, not complete provider ingestion or paid aggregate metrics.','No deployment filter; production events are grouped by their recorded deployment.']}
 with (HERE/f'vercel-hourly-{mask}.json').open('x') as f:json.dump(out,f,indent=2)
 print(json.dumps({'mask':mask,'complete':out['allShardsComplete'],'queries':sum(s['pages'] for s in results),'coreRecords':out['coreRecords'],'incompleteShards':sum(not s['completeReturnedPages'] for s in results)}),flush=True)
