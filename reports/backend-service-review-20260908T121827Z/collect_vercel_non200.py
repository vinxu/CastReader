"""Read Vercel request logs with official CLI parameters; save only sanitized data."""
from pathlib import Path
from collections import Counter
import sys,json,hashlib
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT/'reports/audio-playback-recovery-rollout-20260907/monitoring'))
sys.path.insert(0,str(ROOT/'reports/backend-audio-iteration-20260906/monitoring'))
import collect_vercel_preset_events as v
import collect_acceptance as c
start=v.utc('2026-09-07T12:18:27Z');end=v.utc('2026-09-08T12:18:27Z')
original=v.query_parameters
for mask in ['5xx','4xx','3xx']:
 def params(project,start,end,deployment,page):
  out=original(project,start,end,deployment,page);out.pop('deploymentId');out.pop('search');out['statusCode']=mask;return out
 v.query_parameters=params
 try:
  rows,coverage=v.collect_pages(start,end,None,100,10000)
  seen=set();core=[];other=Counter();invalid=0;duplicates=0
  for row in rows:
   try:t=v.utc(row.get('timestamp'));key=v.anonymous(row.get('requestId'))
   except (ValueError,TypeError,AttributeError):invalid+=1;continue
   if not start<=t<end or key is None:continue
   if key in seen:duplicates+=1;continue
   seen.add(key)
   path,group=c.normalize_vercel_path(row.get('requestPath'))
   status=row.get('statusCode')
   if type(status) is not int or not 100<=status<=599:invalid+=1;continue
   if group=='other':other[status]+=1;continue
   converted={**row,'id':row.get('requestId'),'timestamp':t.timestamp()*1000,'responseStatusCode':status}
   safe=c.sanitize_vercel(converted,start,end)
   safe['method']=row.get('requestMethod') if row.get('requestMethod') in ['GET','POST','OPTIONS','HEAD','DELETE'] else 'other'
   safe['durationMs']=row.get('requestDurationMs') if v.number(row.get('requestDurationMs')) else None
   safe['applicationEvents']=[]
   for log in row.get('logs') or []:
    for line in str(log.get('message','')).splitlines():
     try:e=v.safe_event(json.loads(line))
     except (ValueError,TypeError):continue
     if e:safe['applicationEvents'].append(e)
   core.append(safe)
  value={'readOnly':True,'productionModified':False,'rawContentExported':False,'window':{'startUTC':v.stamp(start),'endUTCExclusive':v.stamp(end)},'queryStatus':mask,'deploymentPinned':False,'coverage':{**coverage,'invalidRows':invalid,'duplicateProviderRows':duplicates},'uniqueReturnedRequests':len(seen),'coreRecords':core,'nonCoreStatusCounts':dict(other),'limitations':['Provider pagination completeness is not proof of complete ingestion or retention.','Includes all returned production deployments; non-core page failures are excluded from audio service records.']}
 except Exception as e:value={'collectionFailed':True,'errorClass':type(e).__name__,'queryStatus':mask}
 value['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
 with (HERE/f'vercel-{mask}.json').open('x') as f:json.dump(value,f,indent=2)
 print(json.dumps({'mask':mask,'failed':value.get('collectionFailed',False),'coverage':value.get('coverage'),'coreRequests':len(value.get('coreRecords',[])),'nonCore':value.get('nonCoreStatusCounts')}),flush=True)
