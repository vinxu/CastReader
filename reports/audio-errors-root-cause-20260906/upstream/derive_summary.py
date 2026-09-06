#!/usr/bin/env python3
"""Derive an aggregate stage balance; never treat it as exact request latency."""
from pathlib import Path
from datetime import datetime
import collections
import json
import statistics

root=Path(__file__).resolve().parent
o=json.loads((root/'upstream-window-evidence.json').read_text())
events=o['modelEvents'];balance=0;peak=0;peak_at=None;pending=collections.deque();delays=[];seconds={};unmatched=0
for e in events:
    if e['stage']=='chunk_yielded':
        balance+=1;pending.append(e)
    elif e['source']=='kokoro_v1:909':
        balance-=1
        if pending:
            a=pending.popleft();delays.append((datetime.fromisoformat(e['atUTC'])-datetime.fromisoformat(a['atUTC'])).total_seconds())
        else:unmatched+=1
    else:continue
    if balance>peak:peak=balance;peak_at=e['atUTC']
    seconds[e['atUTC']]=balance
split_ms=sorted(e['elapsedMs'] for e in events if e['stage']=='split_iteration_completed')
out={
 'schema':'castreader.upstream-aggregate-stage-analysis.v1',
 'window':o['window'],
 'streamGenerationStarts':sum(e['stage']=='audio_stream_started'for e in events),
 'chunksPrepared':sum(e['stage']=='chunk_yielded'for e in events),
 'modelRouteStages':sum(e['source']=='kokoro_v1:909'for e in events),
 'warningErrorCriticalRecords':sum(e.get('level')in('WARNING','ERROR','CRITICAL')for e in events),
 'modelFailureDiagnosticRecords':sum(e['stage']!='english_g2p_recovered'for e in o['diagnostics']),
 'splitOnlyMilliseconds':{'n':len(split_ms),'median':statistics.median(split_ms),'p95':split_ms[int(len(split_ms)*.95)],'max':max(split_ms),'interpretation':'Plan construction only. _split_for_generation exhausts smart_split before GPU processing; these are NOT request or synthesis latencies.'},
 'preparedMinusRoutedBalance':{'maximum':peak,'maximumAtUTC':peak_at,'final':balance,'unmatchedRouteStages':unmatched,'remainingPreparedChunks':len(pending),'secondEndBalances':{k:v for k,v in seconds.items()if'2026-09-06T13:29:15'<=k<='2026-09-06T13:30:25'},'interpretation':'Observed cumulative prepared-chunk versus route-stage imbalance; includes future chunks of multi-chunk requests. It is NOT an instrumented queue-depth gauge.'},
 'illustrativeFIFOStageGap':{'maximumSeconds':max(delays),'pairs':len(delays),'interpretation':'Assumes globally FIFO ordering across mixed requests/processes/languages. Shows order-of-magnitude stage lag only; cannot establish individual request latency or account for the full28s timeout.'},
 'supportedConclusion':'Elevated and repeated-prefix traffic coincided with an aggregate backlog before the model route stage. No model-failure/OOM/restart evidence was found in the targetwindow. Exact four failures cannot be joined, and network/connect/response-transfer time cannot be isolated.',
 'unknowns':['Four gateway requests versus upstream request identifiers','Per-request upstream receipt and completion timestamps','Per-request semaphore/language-lock/adapter wait','Historical event-loop lag and GPU/CPU utilization','Identity or intent behind repeated-prefix requests','Separate R132/R133 attribution of timestamp-only successful-stage logs']
}
(root/'aggregate-stage-analysis.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps({k:v for k,v in out.items()if k not in('preparedMinusRoutedBalance','illustrativeFIFOStageGap')},indent=2))
