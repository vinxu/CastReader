"""Recompute report aggregates from sanitized local evidence; no network access."""
from pathlib import Path
from collections import Counter,defaultdict
from datetime import datetime
import json,hashlib
P=Path(__file__).resolve().parent
def read(n):return json.loads((P/n).read_text())
direct=read('direct-streaming.json');proxy=read('proxy-all-revisions.json');vercel=read('vercel-hourly-5xx.json');details=read('vercel-error-platform-details-complete.json')
rows=[r for q in details['queries'] for r in q['rows'] if r['path']=='/api/captioned_speech_partly' and r['status']>=500]
assert len(rows)==len({r['key'] for r in rows})==90
assert {r['key'] for r in rows}=={r['requestKey'] for r in vercel['coreRecords']}
assert all(q['hasMoreRows'] is False for q in details['queries'])
assert sum(direct['statusCounts'].values())==direct['requests']
assert not proxy['anonymousRequestsTruncated']
assert proxy['coverage']['issues']==['unexpected_proxy_routing_identity_events_in_window']
assert proxy['runtime']['issues']==['revision_mismatch','health_revision_mismatch']
by=defaultdict(list)
for r in proxy['allAnonymousRequests']:by[r['requestKey']].append(r)
failures=[r for r in direct['non200Records'] if r['status'] is not None and r['status']>=500]
closed=[r for r in direct['non200Records'] if r['status'] is None]
events=[e for r in rows for l in r['logs'] for e in l['events']]
connection_failures=[r for r in rows if any(e.get('transportCode')=='UND_ERR_CONNECT_TIMEOUT' for l in r['logs'] for e in l['events'])]
received=sorted(r['firstUTC'] for r in proxy['allAnonymousRequests'] if r['receivedEvents'])
before=max(t for t in received if t<'2026-09-08T18:00');after=min(t for t in received if t>='2026-09-08T18:00')
summary={'window':read('manifest.json'),'direct':{'requests':direct['requests'],'statuses':direct['statusCounts'],'latencyMs':direct['elapsedMs'],'http5xxRecordedRate':len(failures)/direct['requests'],'preResponseCloseRate':len(closed)/direct['requests'],'clients':direct['clientStatuses'],'closedStages':dict(Counter(r['abortStage'] for r in closed)),'closedProxyOutcomes':dict(Counter('|'.join(sorted({o for x in by[r['key']] for o in x['outcomes']})) or 'unmatched' for r in closed)),'http5xxMatchedProxyKeys':sum(bool(by[r['key']]) for r in failures)},'vercel':{'core5xx':len(rows),'all5xxShardsComplete':vercel['allShardsComplete'],'httpStatuses':dict(Counter(r['status'] for r in rows)),'firstRequestUTC':min(r['atUTC'] for r in rows),'lastRequestUTC':max(r['atUTC'] for r in rows),'userAgentClasses':dict(Counter(r['uaClass'] for r in rows)),'requestsWithConnectTimeout':len(connection_failures),'connectTimeoutEvents':sum(e.get('transportCode')=='UND_ERR_CONNECT_TIMEOUT' for e in events),'attemptStarts':sum(e['event']=='attempt_start' for e in events),'retryScheduled':sum(e['event']=='retry_scheduled' for e in events),'proxyMatches':proxy['vercelMatches'],'deploymentIds':sorted({r['deploymentId'] for r in rows})},'proxy':{'counts':proxy['counts'],'revisions':proxy['versionGroups'],'baselineIdentityMatches':False,'logWindowScanHasOnlyRevisionMismatch':True,'noNewReceivedInterval':{'lastBeforeUTC':before,'firstAfterUTC':after,'separationSeconds':(datetime.fromisoformat(after)-datetime.fromisoformat(before)).total_seconds(),'isExactOutageDuration':False},'stageTimingsMs':proxy['stageTimingMilliseconds']},'monitor':read('monitor-us.json')['aggregate'],'caveats':['Request observations across layers are not additive unique user failures.','Provider request-log collection completeness does not prove zero ingestion loss.','Routing baseline mismatch remains visible; all observed revisions are included separately.','No current client playback cohort or full clone-model success ledger was collected.']}
(P/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
evidence={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in P.glob('*.json') if f.name not in {'evidence-hashes.json'}}
(P/'evidence-hashes.json').write_text(json.dumps(evidence,indent=2)+'\n')
print(json.dumps({'directStatuses':summary['direct']['statuses'],'vercel5xx':len(rows),'connectTimeoutRequests':len(connection_failures),'proxyGap':summary['proxy']['noNewReceivedInterval'],'checks':'passed'},ensure_ascii=False))
