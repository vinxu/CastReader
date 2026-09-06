"""Fixed-window read-only event delta; only selected metadata is queried/exported."""
from pathlib import Path
from datetime import datetime, timezone
import certifi
import hashlib
import json
import os
import sys

ROOT=Path('/Users/xuxuheng/Documents/CastReader/reports')
HERE=Path(__file__).resolve().parent
MONITOR=ROOT/'backend-audio-iteration-20260906/monitoring'
sys.path.insert(0,str(MONITOR))
# Existing helper uses create_default_context; supplement its trusted CA input.
os.environ['SSL_CERT_FILE']=certifi.where()
from collect_acceptance import mobile_credentials, postgrest_get
from acceptance_core import canonical_mobile_row, is_technical_failure, safe_code, safe_version, safe_platform, safe_route, safe_source, safe_language, number, parse_utc
state=json.loads((MONITOR/'acceptance-state.json').read_text())
report=json.loads((MONITOR/'latest-acceptance.json').read_text())
known=json.loads((MONITOR/'observations/notification-state.json').read_text())
assert report['generatedAtUtc']=='2026-09-06T17:05:27.598373Z', 'unexpected_snapshot'
start=report['window']['startInclusive'];end=report['window']['collectedThroughExclusive']
ref,credential=mobile_credentials(state)
hash_id=lambda value:hashlib.sha256(value.encode()).hexdigest()[:20] if isinstance(value,str) and value else None
fields=['event_id','event_name','analytics_anonymous_id','client_platform','received_at']
aliases={'environment':'environment','occurredAt':'occurred_at','clientVersion':'client_version','clientBuild':'client_build','result':'result','endReason':'endReason','errorCode':'errorCode','errorStage':'errorStage','contentSource':'contentSource','contentFormat':'contentFormat','language':'language','latencyMs':'latencyMs','playbackSeconds':'playbackSeconds','durationSec':'duration_sec','completionBucket':'completionBucket','clientRoute':'client_service_route','ingressRoute':'ingress_service_route','readSession':'read_session_id','explainSession':'explain_session_id','contentSession':'content_session_id','requestId':'request_id','camelRequestId':'requestId','traceId':'trace_id','errorDomain':'errorDomain','errorNumericCode':'errorNumericCode','httpStatus':'httpStatus','resume':'resume'}
select=','.join(fields+[alias+':properties->>'+prop for alias,prop in aliases.items()])
cutovers={
 'global':json.loads((ROOT/'audio-playback-recovery-rollout-20260907/global-identity-readback.json').read_text())['readAtUTC'],
 'proxy':json.loads((ROOT/'audio-playback-recovery-rollout-20260907/us-proxy-status.json').read_text())['verifiedAtUTC'],
}
direct=json.loads((ROOT/'audio-errors-root-cause-20260906/direct-gateway-release-20260907/status-receipt.json').read_text())
cutovers['directFirstNewTraffic']=direct.get('production.json',{}).get('firstNewTrafficAt')
cutovers['directVerified']=direct.get('production.json',{}).get('verifiedAt')

def relative(value):
 if not value:return None
 try:dt=parse_utc(value)
 except (TypeError,ValueError):return None
 return {name: ('before' if dt<parse_utc(at) else 'at_or_after') if at else 'unavailable' for name,at in cutovers.items()}

def safe(row):
 out={'eventKey':hash_id(row.get('event_id')),'deviceKey':hash_id(row.get('analytics_anonymous_id')),
      'event':safe_code(row.get('event_name')),'platform':safe_platform(row.get('client_platform')),
      'receivedAtUtc':row.get('received_at'),'receivedRelativeToCutovers':relative(row.get('received_at')),
      'clientVersion':safe_version(row.get('clientVersion')),'clientBuild':number(row.get('clientBuild')),
      'contentSource':safe_source(row.get('contentSource')),'language':safe_language(row.get('language')),
      'clientRoute':safe_route(row.get('clientRoute')),'ingressRoute':safe_route(row.get('ingressRoute'))}
 for name in ['environment','result','endReason','errorCode','errorStage','contentFormat','completionBucket','errorDomain']:
  if row.get(name) is not None:out[name]=safe_code(row[name])
 for name in ['latencyMs','playbackSeconds','durationSec','errorNumericCode','httpStatus']:
  if row.get(name) is not None:out[name]=number(row[name])
 for name in ['readSession','explainSession','contentSession','requestId','camelRequestId','traceId']:
  if row.get(name):out[name+'Key']=hash_id(row[name])
 if row.get('resume') in ('true','false'):out['resume']=row['resume']=='true'
 if row.get('occurredAt') and relative(row['occurredAt']) is not None:
  out['occurredAtUtc']=row['occurredAt'];out['occurredRelativeToCutovers']=relative(row['occurredAt'])
 return out

rows,headers=postgrest_get(ref,credential,[('select',select),('event_name','in.(read_end,explain_end)'),('received_at','gte.'+start),('received_at','lt.'+end),('order','received_at.asc,event_id.asc'),('limit','1000')],25)
expected=headers.get('content-range','').rsplit('/',1)[-1]
complete=expected.isdigit() and int(expected)==len(rows)
assert complete,'end_event_read_incomplete'
failures=[];new=[]
for row in rows:
 canonical=canonical_mobile_row(row)
 if not canonical or canonical['environment']!='production' or not is_technical_failure(canonical):continue
 item=safe(row);failures.append(item)
 if item['eventKey'] in known['alertEventKeys']:continue
 entry={'failure':item,'sessionChains':[]}
 for alias,field in [('readSession','read_session_id'),('explainSession','explain_session_id'),('contentSession','content_session_id')]:
  value=row.get(alias)
  if not value:continue
  related,h=postgrest_get(ref,credential,[('select',select),('properties->>'+field,'eq.'+value),('received_at','gte.2026-09-05T00:00:00Z'),('received_at','lt.'+end),('order','received_at.asc,event_id.asc'),('limit','1000')],25)
  total=h.get('content-range','').rsplit('/',1)[-1]
  entry['sessionChains'].append({'type':alias,'sessionKey':hash_id(value),'complete':total.isdigit() and int(total)==len(related),'rows':[safe(r) for r in related]})
 new.append(entry)
output={'schema':'castreader.client-failure-delta.v1','readOnly':True,'productionModified':False,'rawContentExported':False,
 'snapshotGeneratedAtUtc':report['generatedAtUtc'],'query':{'startInclusive':start,'endExclusive':end},
 'cutovers':cutovers,'completeRead':complete,'selectedEndRows':len(rows),'knownFailureCount':len(known['alertEventKeys']),
 'cumulativeFailureCount':len(failures),'newFailureCount':len(new),'counterMatchesSnapshot':len(failures)==report['sources']['mobile']['aggregate']['technicalFailureEvents'],
 'newEventKeys':[entry['failure']['eventKey'] for entry in new], 'newIncidents':new,
 'limitations':['Received time is server-clocked; occurred time is client-supplied. A post-cutover receipt alone does not prove the request used that deployment.', 'Only explicitly selected request/trace property names were queried; absence does not prove no correlation metadata exists anywhere.', 'Session and device keys are anonymous correlation handles, not verified identities.']}
(HERE/'client-delta.json').write_text(json.dumps(output,indent=2)+'\n')
print(json.dumps({name:output[name] for name in ['completeRead','cumulativeFailureCount','newFailureCount','counterMatchesSnapshot','newEventKeys']} | {'failures':[entry['failure'] for entry in new]}))
