#!/usr/bin/env python3
"""Read selected incident events and export only bounded, content-free metadata."""
import json,hashlib,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT.parent/'backend-audio-iteration-20260906/monitoring'))
from collect_acceptance import mobile_credentials,postgrest_get
state=json.loads((ROOT.parent/'backend-audio-iteration-20260906/monitoring/acceptance-state.json').read_text())
ref,key=mobile_credentials(state)
TARGET={'f8dc697edd4e3c44aa6c','db06d2cbb1dc6da992ab'}
ALLOWED=['result','surface','entry_point','client_version','client_build','occurred_at','received_at','endReason','errorCode','errorStage','playbackSeconds','completionBucket','contentSource','contentFormat','language','voiceId','speed','resume','latencyMs','client_service_route','ingress_service_route','environment']
hashid=lambda value:hashlib.sha256(value.encode()).hexdigest()[:20] if isinstance(value,str) else None

def safe(row):
 p=row.get('properties') or {}
 result={'eventKey':hashid(row.get('event_id')),'deviceKey':hashid(row.get('analytics_anonymous_id')),'event':row.get('event_name'),'receivedAtUtc':row.get('received_at'),'properties':{k:p[k] for k in ALLOWED if k in p},'propertyKeys':sorted(p)}
 result['hasRequestCorrelation']=any('request' in k.lower() or 'trace' in k.lower() for k in p)
 return result
rows,headers=postgrest_get(ref,key,[('select','event_id,event_name,analytics_anonymous_id,received_at,properties'),('event_name','eq.read_end'),('received_at','gte.2026-09-06T13:28:17Z'),('received_at','lt.2026-09-06T14:22:22.032377Z'),('limit','1000')],25)
results=[]
for row in rows:
 if hashid(row['event_id']) not in TARGET:continue
 p=row['properties'];entry={'failure':safe(row)}
 for field in ['read_session_id','content_session_id']:
  value=p.get(field)
  if not value:continue
  related,h=postgrest_get(ref,key,[('select','event_id,event_name,analytics_anonymous_id,received_at,properties'),('properties->>'+field,'eq.'+value),('received_at','gte.2026-09-05T00:00:00Z'),('received_at','lt.2026-09-06T14:25:00Z'),('order','received_at.asc'),('limit','1000')],25)
  expected=h.get('content-range','').rsplit('/',1)[-1]
  entry[field]={'complete':expected.isdigit() and int(expected)==len(related),'rows':[safe(r) for r in related]}
 results.append(entry)
out={'readOnly':True,'rawContentExported':False,'incidents':results}
Path(__file__).with_name('session-evidence.json').write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(out,ensure_ascii=False))
