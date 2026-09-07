"""Complete the oldest 20 seconds left by a bounded pagination cap, retaining both reads."""
from pathlib import Path
from datetime import datetime,timedelta,timezone
from collections import Counter
import hashlib,json
P=Path(__file__).resolve().parent
paths=[P/'vercel-part2-retry.json',P/'vercel-part2-prefix.json']
a,b=[json.loads(p.read_text()) for p in paths]
utc=lambda s:datetime.fromisoformat(s.replace('Z','+00:00'))
assert a['coverage']['issues']==['pagination_incomplete'] and a['coverage']['providerHasMoreRows'] is True
assert b['coverage']['completeForReturnedRequestCohort'] and not b['coverage']['providerHasMoreRows']
assert a['expectedDeployment']==b['expectedDeployment'] and a['schema']==b['schema']
oldest=min(utc(r['requestStartUTC']) for r in a['requests'])
assert utc(b['window']['requestStartExclusiveUTC'])==oldest+timedelta(milliseconds=1)
assert utc(a['window']['requestStartInclusiveUTC'])==utc(b['window']['requestStartInclusiveUTC'])
rows={r['vercelRequestKey']:r for r in a['requests']};overlap=0
for r in b['requests']:
 key=r['vercelRequestKey']
 if key in rows:
  assert rows[key]==r,'overlap_record_changed_requires_review'
  overlap+=1
 else:rows[key]=r
assert overlap>0
r=dict(a);r['requests']=sorted(rows.values(),key=lambda v:(v['requestStartUTC'],v['vercelRequestKey']))
r['collectedAtUTC']=b['collectedAtUTC'];r['mergedAtUTC']=datetime.now(timezone.utc).isoformat()
c=dict(a['coverage']);pc=Counter(a['coverage']['parserCounts']);pc.update(b['coverage']['parserCounts']);pc['overlapAcrossContinuationReads']=overlap
c.update({'completeForReturnedRequestCohort':True,'providerHasMoreRows':False,'issues':[],'pagesRead':a['coverage']['pagesRead']+b['coverage']['pagesRead'],'providerRowsRead':a['coverage']['providerRowsRead']+b['coverage']['providerRowsRead'],'uniqueProviderRequests':len(rows),'parserCounts':dict(pc),'paginationMode':'capped_backward_walk_completed_by_exact_overlapping_prefix','ingestionCompletenessVerified':False})
r['coverage']=c;r['sourceSnapshots']=[{'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths]
r['continuationProof']={'originalPageCap':60,'oldestRetainedRequestUTC':oldest.isoformat(),'prefixWindow':b['window'],'identicalOverlappingRequests':overlap,'noRequestStartWindowGap':True}
events=[e for q in r['requests'] for e in q['events']]
r['counts']={'events':dict(Counter(e['event'] for e in events)),'failureCodes':dict(Counter(e['code'] for e in events if 'code' in e)),'terminalCodes':dict(Counter(e['code'] for e in events if e['event']=='request_finished' and 'code' in e)),'attemptStarts':dict(Counter(str(e['attempt']) for e in events if e['event']=='attempt_start'))}
out=P/'vercel-part2-complete.json'
with out.open('x') as f:json.dump(r,f,indent=2)
print(json.dumps({'requests':len(rows),'overlap':overlap,'coverage':c}))
