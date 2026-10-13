from pathlib import Path
import sys,json,urllib.request,urllib.parse,hashlib
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT/'reports/backend-audio-iteration-20260906/monitoring'))
import collect_acceptance as c
config=json.loads((ROOT/'reports/backend-audio-iteration-20260906/monitoring/acceptance-state.json').read_text())
ref,key=c.mobile_credentials(config)
query={'select':'observed_at,window_started_at,window_ended_at,window_seconds,sample_count,metrics,collector_errors,received_at,release_id','instance_id':'eq.42998411','and':'(observed_at.gte.2026-09-08T17:40:00Z,observed_at.lt.2026-09-08T18:30:00Z)','order':'observed_at.asc','limit':'1000'}
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs):return None
opener=urllib.request.build_opener(NoRedirect())
r=urllib.request.Request('https://'+ref+'.supabase.co/rest/v1/tts_runtime_minute?'+urllib.parse.urlencode(query),headers={'apikey':key,'Authorization':'Bearer '+key,'Accept':'application/json','Prefer':'count=exact'})
try:
 with opener.open(r,timeout=25)as response:
  d=json.load(response);coverage=response.headers.get('Content-Range');status=response.status
 v={'readOnly':True,'credentialExported':False,'instanceId':'42998411','httpStatus':status,'contentRange':coverage,'window':{'startUTC':'2026-09-08T17:40:00Z','endUTCExclusive':'2026-09-08T18:30:00Z'},'rows':d,'collectorSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
except Exception as e:v={'collectionErrorClass':type(e).__name__,'httpStatus':getattr(e,'code',None)}
(HERE/'runtime-metrics.json').write_text(json.dumps(v,indent=2));print(json.dumps({'rowCount':len(v.get('rows',[])),'contentRange':v.get('contentRange'),'error':v.get('collectionErrorClass')}))
