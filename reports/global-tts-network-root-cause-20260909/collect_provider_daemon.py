from pathlib import Path
import subprocess,json
HERE=Path(__file__).resolve().parent
REMOTE=r'''
import os,json,urllib.request,urllib.error,urllib.parse,time,re,hashlib
from datetime import datetime,timezone
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args,**kwargs):return None
opener=urllib.request.build_opener(NoRedirect())
id=os.environ['CONTAINER_ID'];headers={'Authorization':'Bearer '+os.environ['CONTAINER_API_KEY'],'Content-Type':'application/json'}
result={'operation':'provider_instance_daemon_log_read','instanceId':id,'capturedAtUTC':datetime.now(timezone.utc).isoformat(),'synthesisStarted':False,'serviceConfigurationModified':False}
try:
 req=urllib.request.Request('https://console.vast.ai/api/v0/instances/request_logs/'+id+'/',data=json.dumps({'daemon_logs':'true','tail':'20000','filter':'2026-09-08'}).encode(),headers=headers,method='PUT')
 with opener.open(req,timeout=20)as r:response=json.load(r);result['requestHTTPStatus']=r.status
 result['providerSuccess']=response.get('success');url=response.get('result_url','');parsed=urllib.parse.urlsplit(url)
 if parsed.scheme!='https' or not (parsed.hostname=='s3.amazonaws.com' or parsed.hostname.endswith('.amazonaws.com')):raise ValueError('unexpected_provider_log_destination')
 raw=None
 for i in range(12):
  try:
   with opener.open(urllib.request.Request(url),timeout=8)as r:raw=r.read(16*1024*1024+1);result['logHTTPStatus']=r.status
   break
  except urllib.error.HTTPError as e:
   result['logHTTPStatus']=e.code
   if e.code!=404:break
   time.sleep(1)
 if raw is not None:
  if len(raw)>16*1024*1024:raise ValueError('provider_log_budget_exceeded')
  result['bytes']=len(raw);result['sha256']=hashlib.sha256(raw).hexdigest();result['lineCount']=len(raw.splitlines());events=[];dates=[]
  terms=['network','offline','online','heartbeat','timeout','timed out','connection refused','connection reset','reconnect','unreachable','iptables','conntrack','docker','pause','unpause','restart','reboot','NAT','failed','error','oom','out of memory','link down','link up']
  for line in raw.decode(errors='replace').splitlines():
   m=re.search(r'2026-09-08[T ]\d\d:\d\d:\d\d(?:[.,]\d+)?',line)
   if not m:continue
   stamp=m[0].replace(' ','T').replace(',','.');dates.append(stamp)
   if '2026-09-08T17:40'<=stamp<'2026-09-08T18:30':
    ev={'atUTC':stamp,'fixedFragments':[t for t in terms if t.lower() in line.lower()],'mentionsTargetInstance':id in line,'messageSha256':hashlib.sha256(line.encode()).hexdigest()}
    events.append(ev)
  result['firstTimestamp']=min(dates) if dates else None;result['lastTimestamp']=max(dates) if dates else None;result['incidentEvents']=events[:2000];result['eventsTruncated']=len(events)>2000
except Exception as e:
 result['collectionErrorClass']=type(e).__name__;result['httpStatus']=getattr(e,'code',None)
print('SAFE='+json.dumps(result))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -'],input=REMOTE,text=True,capture_output=True,timeout=55)
rows=[x[5:] for x in r.stdout.splitlines() if x.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('provider_read_failed')
v=json.loads(rows[0]);(HERE/'provider-daemon-read.json').write_text(json.dumps(v,indent=2));print(json.dumps(v))
