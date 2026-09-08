"""Rebuild a local cumulative readback from complete, contiguous observation windows."""
from pathlib import Path
from collections import Counter
from datetime import datetime
import json
ROOT=Path(__file__).resolve().parent
parse=lambda s:datetime.fromisoformat(s.replace('Z','+00:00'))
state=json.loads((ROOT/'observation-state.json').read_text());cursor=parse(state['fixedObservationStartUTC']);selected=[];excluded=[]
for path in sorted((ROOT/'observations').glob('*/summary.json')):
 value=json.loads(path.read_text())
 if not value.get('collectionCompleteWithinAvailableSources'):excluded.append(str(path.relative_to(ROOT)));continue
 start,end=map(parse,[value['window']['startUTC'],value['window']['endUTCExclusive']])
 if start==cursor:selected.append((path,value));cursor=end
 elif end>cursor:raise RuntimeError('complete_windows_overlap_or_have_gap')
assert cursor==parse(state['lastCompleteEndUTC'])
out={'window':{'startUTC':state['fixedObservationStartUTC'],'endUTCExclusive':state['lastCompleteEndUTC'],'fixedObservationEndUTC':state['fixedObservationEndUTC']},'selectedSummaries':[str(p.relative_to(ROOT))for p,v in selected],'incompleteSummariesExcluded':excluded,'readOnly':True,'productionModified':False,'sources':{}}
for region in ['cn','us']:
 statuses=Counter();attempts=Counter();events=Counter();failures=Counter();ingress=Counter()
 for _,value in selected:
  s=value['sources'][region];statuses.update(s['monitorStatusCounts']);attempts.update(s['attemptOutcomeCounts']);events.update(s['quickreadProviderEvents']);failures.update(s['quickreadProviderFailureCodes'])
  for row in s.get('ingressCounts',[]):ingress[row['path'],row['method'],row['status']]+=row['count']
 out['sources'][region]={'monitorStatuses':dict(statuses),'attemptOutcomes':dict(attempts),'providerEvents':dict(events),'providerFailureCodes':dict(failures),'ingressStatuses':[{'path':k[0],'method':k[1],'status':k[2],'count':count}for k,count in ingress.items()]}
statuses=Counter();closed=[];join_files=[ROOT/'initial-disconnect-proxy-join.json'];vercel=[]
for path,value in selected:
 statuses.update(value['sources']['direct']['statusCounts']);closed.extend(value['sources']['direct']['non200Records']);vercel.extend(value['sources']['vercel']['coreRecords'])
 j=path.parent/'disconnect-proxy-join.json'
 if j.exists():join_files.append(j)
assert len({(x['key'],x['observedAt'],x['status'])for x in closed})==len(closed)
out['sources']['direct']={'statusCounts':dict(statuses),'downstreamClosedOccurrences':len(closed),'distinctClosedKeys':len({x['key']for x in closed}),'platforms':dict(Counter(x['clientPlatform']for x in closed)),'noResponseShareOfLoggedRequests':round(len(closed)/sum(statuses.values()),6)if sum(statuses.values())else None,'notUserPlaybackFailureRate':True}
out['sources']['vercel']={'returnedCoreErrorRecords':len({(x['requestKey'],x['observedAtUtc'],x['status'])for x in vercel}),'allReturnedPagesComplete':True,'notAllStatusDenominator':True}
# Distinct request keys are only for linkage coverage; never replace occurrence counts above.
joined={};outcomes=Counter();key_counts=Counter(x['key']for x in closed)
for path in join_files:
 value=json.loads(path.read_text())
 if not value.get('identityAndCoverageVerified'):continue
 for row in value['targetRequests']:
  identity=(row['requestKey'],row.get('attempt'),row.get('firstUTC'),row.get('lastUTC'))
  joined[identity]=row
closed_keys=set(key_counts);matched_keys={row['requestKey']for row in joined.values()}&closed_keys
for row in joined.values():
 if row['requestKey']in closed_keys:outcomes.update(row['outcomes'])
out['disconnectJoin']={'matched':len(matched_keys),'linkageUnit':'distinct anonymous request key; HTTP counts above retain separate occurrences','outcomes':dict(outcomes),'missingKeys':sorted(closed_keys-matched_keys),'repeatedDirectKeys':[key for key,count in key_counts.items()if count>1],'ambiguousProxyKeys':sorted({row['requestKey']for row in joined.values()if row.get('ambiguousRepeatedRequestKey')}),'firstCauseConfirmed':False}
text=json.dumps(out,indent=2,ensure_ascii=False)+'\n'
(ROOT/'cumulative-observation.json').write_text(text)
if selected:(selected[-1][0].parent/'cumulative.json').write_text(text)
print(json.dumps(out,ensure_ascii=False))
