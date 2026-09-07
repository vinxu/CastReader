"""Review already sanitized snapshots only; no network or production mutations."""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
MON = HERE.parent.parent
ROOT = MON.parents[2]
OLD = ROOT / 'reports/backend-audio-iteration-20260906/monitoring'
PREV = HERE.parent / '20260907T0155Z'
TAG = HERE.name

def read(path):
    return json.loads(path.read_text())

def save(name, value):
    with (HERE / name).open('x') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')

def evidence(path):
    return {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}

def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {'samples': 0, 'p50': None, 'p95': None, 'max': None}
    return {'samples': len(ordered), 'p50': ordered[math.ceil(len(ordered)*.5)-1],
            'p95': ordered[math.ceil(len(ordered)*.95)-1], 'max': ordered[-1]}

def stamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))

current = read(HERE/'latest-acceptance.json')
previous = read(PREV/'latest-acceptance.json')
historical = read(OLD/'observations'/TAG/'latest-acceptance.json')
cn_recovery = read(HERE/'monitor-cn-recovery.json')
assert cn_recovery['query']['startInclusive'] == current['window']['startInclusive']
assert cn_recovery['query']['endExclusive'] == current['window']['collectedThroughExclusive']
assert cn_recovery['coverage']['completeRead'] and not cn_recovery['source']['invalidResults']

def snapshot(value, supplemental=None):
    sources = value['sources']
    cn = supplemental or sources['monitor_cn']
    return {
        'generatedAtUTC': value['generatedAtUtc'],
        'directStatusCounts': sources['direct_gateway']['aggregate']['statusCounts'],
        'directElapsedMsMixedOutcomes': sources['direct_gateway']['aggregate']['elapsedMs'],
        'globalCore5xx': sources['vercel']['aggregate']['core5xxRecords'],
        'usProbeStatus': sources['monitor_us']['aggregate']['statusCounts'],
        'cnProbeStatus': cn['aggregate']['statusCounts'],
        'regionMismatchCycles': sources['monitor_us']['aggregate']['regionMismatchCycles'] + cn['aggregate']['regionMismatchCycles'],
        'rawCollectorCoverageGaps': value['evaluation']['dataOrCoverageGaps'],
        'supplementalCNRecoveryUsed': supplemental is not None,
        'observedSeconds': value['evaluation']['observationSeconds'],
    }

comparison = {'schema': 'castreader.backend-snapshot-comparison.v2',
    'current': snapshot(current, cn_recovery), 'previous': snapshot(previous),
    'historicalWindow': snapshot(historical), 'originalAutomaticVerdictPreserved': True,
    'excludedFromBackendVerdict': ['mobile', 'blog', 'payment'],
    'collectionRecovery': {'source': 'monitor_cn', 'originalError': current['sources']['monitor_cn'],
        'sameExactWindowRecovery': evidence(HERE/'monitor-cn-recovery.json'),
        'originalSnapshotUnchanged': True, 'unresolvedBackendCoverageErrors': []}}
save('backend-snapshot-comparison.json', comparison)

vpath = MON/f'vercel-preset-model-r134-{TAG}.json'
ppath = MON/f'proxy-model-r134-{TAG}.json'
vercel, proxy = read(vpath), read(ppath)
join = read(HERE/'vercel-proxy-join.json')
events = [e for r in vercel['requests'] for e in r['events']]
elapsed = {stage: distribution([e['elapsedMs'] for e in events if e['event'] == stage])
           for stage in ('upstream_headers', 'upstream_body', 'request_finished')}
assert vercel['coverage']['completeForReturnedRequestCohort'] and proxy['identityAndCoverageVerified']
assert join['counts'] == {'attempts': 3259, 'matched': 3259, 'ambiguous': 0, 'matchedProxyComplete': 3259}
represented = {(a['requestKey'], a['attempt']) for a in join['attempts']}
unrepresented = [r for r in proxy['anonymousRequests'] if r['receivedEvents'] and (r['requestKey'], r['attempt']) not in represented]
carryover = [r for r in proxy['anonymousRequests'] if not r['receivedEvents']]
pending = [r for r in proxy['anonymousRequests'] if r['receivedEvents'] and not r['outcomes']]
prior_proxy = read(MON/'proxy-model-r134-20260907T0155Z.json')
prior_pending = {r['requestKey']: r for r in prior_proxy['anonymousRequests'] if r['receivedEvents'] and not r['outcomes']}
resolved = [r for r in carryover if r['requestKey'] in prior_pending and r['outcomes'].get('complete') == 1
            and r['flightKeys'] == prior_pending[r['requestKey']]['flightKeys']]
assert len(resolved) == 2 and not pending
summary = {'schema': 'castreader.backend-vercel-proxy-join-summary.v1', 'window': vercel['window'],
    'coverage': join['coverage'], 'counts': join['counts'],
    'vercelStatusCounts': dict(Counter(str(r['vercelStatus']) for r in join['attempts'])),
    'events': vercel['counts'], 'elapsedMsFromRequestStart': elapsed,
    'bodySamples': sum(e['event']=='upstream_body' for e in events),
    'nonEmptyBodySamples': sum(e['event']=='upstream_body' and e.get('bodyBytes', 0)>0 for e in events),
    'ambiguousMatches': [r for r in join['attempts'] if r['ambiguous']],
    'boundaryRequests': [r for r in join['attempts'] if not r['ambiguous'] and not any(p['outcomes'].get('complete') for p in r['proxy'])],
    'carryoverProxyCompletions': carryover, 'previousPendingResolvedWithFlightKey': resolved,
    'pendingProxyGroups': pending,
    'unrepresentedProxyGroupsByAttempt': dict(Counter(str(r['attempt']) for r in unrepresented)),
    'unrepresentedProxyAdmissionsByAttempt': {str(a): sum(r['receivedEvents'] for r in unrepresented if r['attempt']==a) for a in {r['attempt'] for r in unrepresented}},
    'unrepresentedAttempt1Groups': [r for r in unrepresented if r['attempt']==1],
    'limitations': ['Attempt headers cannot identify caller or deployment. Unrepresented requests do not prove a different route or cross-border traffic.',
        'Complete returned provider pagination is not provider ingestion completeness.',
        'Provider start timestamps and application elapsedMs cannot be added to infer exact application event wall time.']}
save('vercel-proxy-join-summary.json', summary)

windows, buckets = [], []
for tag in ('20260906T2353Z', '20260907T0053Z', '20260907T0155Z', TAG):
    v = read(MON/f'vercel-preset-model-r134-{tag}.json')
    p = read(MON/f'proxy-model-r134-{tag}.json')
    ev = [e for r in v['requests'] for e in r['events']]
    windows.append({'tag': tag, 'window': v['window'], 'globalRequestCount': len(v['requests']),
        'globalRequestFinishMs': distribution([e['elapsedMs'] for e in ev if e['event']=='request_finished']),
        'proxyUpstreamHeadersElapsedMs': p['stageTimingMilliseconds']['upstream_headers.elapsedMs'],
        'proxyUpstreamConnectMs': p['stageTimingMilliseconds']['upstream_connected.connectMs']})
    row = {'tag': tag, 'sizeBuckets': []}
    for label, low, high in [('<64KiB',0,65536),('64-128KiB',65536,131072),('128-256KiB',131072,262144),('>=256KiB',262144,float('inf'))]:
        times = []
        for r in v['requests']:
            body = next((e for e in r['events'] if e['event']=='upstream_body'), None)
            finish = next((e for e in r['events'] if e['event']=='request_finished'), None)
            if body and finish and low <= body.get('bodyBytes',-1) < high:
                times.append(finish['elapsedMs'])
        row['sizeBuckets'].append({'outputBodySize':label, 'requestFinishMs':distribution(times)})
    buckets.append(row)
save('latency-size-buckets.json', {'windows': buckets, 'limitation': 'Output response size is not input length, audio duration or model cost; coarse buckets do not isolate workload composition.'})
latency = {'schema':'castreader.backend-latency-trend.v3', 'classification':'partial_improvement_after_reported_regression',
    'windows':windows, 'relativeToPriorObservedBaseline':True, 'absoluteProductLatencySloSpecified':False,
    'exceededExistingTimeoutBudget':False, 'requestFinishP95ChangeFromPriorPercent':round((2065/2697-1)*100,2),
    'requestFinishP95ChangeFromBaselinePercent':round((2065/1570-1)*100,2),
    'boundedFinding':'One hour improved: Global P95 2697 to 2065 ms; US model-header wait P95 2543.123 to 1959.630 ms. Both remain above the earlier observed baseline.',
    'fullRecoveryEstablished':False, 'internalCauseResolved':False,
    'unresolvedCause':['queue/concurrency','frontend/inference','encoding','request mix'],
    'sizeBucketEvidence': evidence(HERE/'latency-size-buckets.json'), 'keepObservingTrend':True}
save('latency-watch.json', latency)

series = read(HERE/'cn-probe-timing-series.json')
cn_windows = []
for w in windows:
    a,b=map(stamp,(w['window']['requestStartInclusiveUTC'],w['window']['requestStartExclusiveUTC']))
    rows=[r for r in series['rows'] if a<=stamp(r['observedAtUTC'])<b]
    cn_windows.append({'tag':w['tag'], 'probeElapsedMs':distribution([r['elapsedMs']for r in rows]),
        'allComplete':all(r['completeAudio'] and r['supplyOk'] for r in rows),
        'allSegmentsFirstAttempt':all(r['segmentAttempts']==[1,1,1] for r in rows),
        'overTenSeconds': [r for r in rows if r['elapsedMs']>10000]})
cn_watch={'schema':'castreader.cn-probe-latency-watch.v1','classification':'intermittent_probe_path_latency_unattributed',
    'windows':cn_windows,'serverInternalCauseEstablished':False,'requestOrModelTTFBAvailable':False,
    'limitation':'Whole three-segment probe elapsed includes HTTP, local decode and validation. All successful; it cannot identify which portion slowed or establish user playback interruption.',
    'source':evidence(HERE/'cn-probe-timing-series.json')}
save('cn-latency-watch.json', cn_watch)

supply={r:read(HERE/'backend-supply'/f'{r}-backend-supply.json')['result'] for r in ('us','cn','us-gpu')}
psupply={r:read(PREV/'backend-supply'/f'{r}-backend-supply.json')['result'] for r in ('us','cn','us-gpu')}
identities={}
for region, key in [('us','quickreadExpectedProcess'),('cn','quickreadProcess')]:
    prior=read(PREV/'quickread-identity-comparison.json')[region]
    identities[region]={'current':supply[region][key], 'unchangedFromPriorVerifiedIdentity':supply[region][key]==prior['current'],
        'serverShaMatchesReviewedRelease':supply[region][key]['serverSourceSha256']==prior['current']['serverSourceSha256'],
        'releaseEvidence':prior['releaseEvidence'], 'localLifecycleSource':prior['localLifecycleSource']}
    for ref in [prior['releaseEvidence'],prior['localLifecycleSource']]:
        assert evidence(Path(ref['path'])) == ref
    assert identities[region]['unchangedFromPriorVerifiedIdentity']
save('quickread-identity-comparison.json',identities)
delta={'quickreadIdentityUnchanged':{r:x['unchangedFromPriorVerifiedIdentity']for r,x in identities.items()},
    'usCloneProcessUnchanged':supply['us-gpu']['expectedCloneProcess']==psupply['us-gpu']['expectedCloneProcess'],
    'usNariProcessUnchanged':supply['us-gpu']['expectedNariProcess']==psupply['us-gpu']['expectedNariProcess'],
    'cnUnitsUnchanged':supply['cn']['units']==psupply['cn']['units'],
    'cloneHealthCounterChanges':{r:{k:supply[role]['cloneHealthAfterCutoff']['fields'][k]-psupply[role]['cloneHealthAfterCutoff']['fields'][k]for k in ('submitted','completed','failed','expired')}for r,role in [('us','us-gpu'),('cn','cn')]},
    'quickreadIncrementalFixedTags':{r:supply[r]['quickreadLogs']['incrementalFixedTagCounts']for r in ('us','cn')},
    'knownDirectDisconnectKeySetUnchanged':{r['key']for r in current['sources']['direct_gateway']['aggregate']['nonHttpRequests']}=={r['key']for r in previous['sources']['direct_gateway']['aggregate']['nonHttpRequests']}}
save('backend-service-delta.json',delta)

direct=read(HERE/'direct400.json')
assert direct['coverage']['complete'] and direct['currentIdentity']['sourceMatchesRelease']
assert direct['status400Count']==1
rejection=direct['requests'][0]
assert (rejection['key'],rejection['status'],rejection['requestBytes'],rejection['stage'],rejection['elapsedMs'])==('a6d6b93dc8a10d1b9fc3',400,2,'request_validation',0)
source=Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-tts-direct-cancellation-20260907/ops/tts-direct-gateway/gateway.mjs')
assert evidence(source)['sha256']==direct['currentIdentity']['sourceSha256']
rejection_analysis={'schema':'castreader.direct-request-validation-attribution.v1','request':rejection,
    'classification':'invalid_request_rejected_locally_before_upstream', 'http400Preserved':True,
    'validTtsSupplyFailureEstablished':False,'modelInvokedForThisRequest':False,
    'confirmedEvidence':['Logged terminal stage=request_validation, HTTP400, 2-byte body and 0ms elapsed.',
        'Frozen running-source SHA matches reviewed local source. All status400 exits at that stage are JSON parse/type/input validation; fetch begins only after stage becomes upstream_headers.',
        'No matching anonymous request key in the complete proxy scan. This supports the static control-flow evidence; absence alone would not prove non-invocation.'],
    'possibleSubtypes':['malformed JSON','non-object or array JSON','missing or empty string input'],
    'exactSubtypeAndCallerKnown':False,'bodyReadForInvestigation':False,
    'source':evidence(source),'lineReferences':{'payloadValidation':76,'jsonParseValidation':273,'upstreamStarts':293,'safeTerminalLog':382},
    'sources':[evidence(HERE/'direct400.json'),evidence(ppath)]}
save('direct400-attribution.json',rejection_analysis)

model=read(HERE/'model-existing-diagnostics-v2.json')
for ref in model['sourceDigests']:
    relative=ref['path'].split('/'+model['releaseId']+'/')[1]
    local=Path('/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-silent-separators-20260907')/relative
    assert evidence(local)['sha256']==ref['sha256']
assert model['unrecognizedStageRows']==0 and not model['failureEvents']
model_note={'schema':'castreader.model-diagnostic-coverage-review.v1','source':evidence(HERE/'model-existing-diagnostics-v2.json'),
    'fixedFailureEvents':[], 'allReturnedStageNamesClassified':True,
    'queueInferenceEncodingTimingsAvailable':False,
    'diagnosticSourceMatchesReviewedLocalSource':True,
    'finding':'Existing R134 diagnostics log failure/degradation/recovery counters, without successful request queue/inference/encoding stage times. This read-only evidence cannot split the previously observed upstream-header wait.',
    'degradationAndRecoveryCounters':model['fixedStageCounts'],
    'limitation':'source_frontend_unavailable is a recovery-path marker, not by itself a terminal model/HTTP failure; no terminal failure events were captured in this retained window.'}
save('model-diagnostic-coverage-review.json',model_note)

services=[
 {'region':'global','service':'kokoro_tts','backendVerdict':'存在异常','scope':'先前时延退化本小时部分改善；有效HTTP供给正常',
  'evidence':'3259条Global均200、非空body并完成，全部精确关联代理完成；P95由2697降至2065ms，仍高于1570ms基线。Direct新增1条400在网关本地参数校验拒绝，未请求模型；无新增模型/HTTP5xx。'},
 {'region':'cn','service':'kokoro_tts','backendVerdict':'证据不足','scope':'可见供给正常，但探针耗时波动尚无服务端阶段证据归因',
  'evidence':'422条可解析TTS POST均200（包含监控），96轮合同完整成功。新增三段探针总耗时21.883、22.466和11.260秒；均一次完成，可能包含HTTP或本地解码等待，不能认定模型慢或用户停播。'},
 {'region':'global','service':'clone_tts','backendVerdict':'证据不足','scope':'本窗口真实合成',
  'evidence':'结构化合成事件仍0；健康、无队列，累计173完成/0失败/0过期不变。'},
 {'region':'cn','service':'clone_tts','backendVerdict':'证据不足','scope':'本窗口真实合成',
  'evidence':'健康、无队列，累计4完成/0失败/0过期不变，不能替代窗口验证。'},
 {'region':'global','service':'quickread','backendVerdict':'符合预期','scope':'可见讲解生成与持久续块',
  'evidence':'窗口85条权益放行，本小时增加27；86份窗口修改任务均ready、有首块，73份全块生成、13份可续。无新增固定错误，旧request_disconnected保留。仍非完整HTTP账本。'},
 {'region':'cn','service':'quickread','backendVerdict':'证据不足','scope':'窗口任务与HTTP结果',
  'evidence':'journal及任务修改仍0；当前健康、无队列不等于实际请求成功率。'}]
reason='新增1条Direct400确认为请求参数校验本地拒绝，并非模型供给失败；国际区时延部分改善，中国区既有探针出现新的约22秒总耗时波动，需保留阶段归因不足。'
review={'schema':'castreader.backend-audio-heartbeat-review.v3','automationId':'24','reviewedAtUTC':datetime.now(timezone.utc).isoformat(),
    'decision':'NOTIFY','decisionReason':reason,'observationScope':'backend_tts_clone_quickread_only','backendVerdict':'存在异常',
    'backendVerdictReason':'Global已报时延退化尚未证明完整恢复；CN探针耗时波动、克隆/CN解读样本不足。',
    'readOnly':True,'productionModified':False,'synthesisStarted':False,'services':services,
    'finalWindow':current['window'],'backendDetailWindow':proxy['window'],
    'currentBackendSnapshot':comparison['current'],'historicalBackendSnapshot':comparison['historicalWindow'],
    'newConfirmedBackendHttpRejections':[rejection_analysis], 'newConfirmedValidTtsSupplyFailures':[],
    'latencyWatch':latency,'cnLatencyWatch':cn_watch,
    'knownDisconnectedRequestsPreserved':{'directFinalWindow':12,'quickreadFixedDisconnectLogs':supply['us']['quickreadLogs']['fixedErrorRecords']},
    'quickreadVersionIdentity':identities,'collectionRecovery':comparison['collectionRecovery'],
    'localProxyCollectionInitialFailure':{'errorClass':'ValueError','cause':'noncanonical identity receipt path containing .. was rejected locally','resolvedBy':'passing the same frozen receipt using its canonical absolute path','productionFailure':False},
    'limitations':['No client event drilldown, client code or user content inspected. HTTP200 is not full playback.',
        'CN ingress has 24 unparsed log lines; 422 successes cover parsed known routes, not all possible records or per-voice outcomes.',
        'Probe elapsed measures multiple requests and local checks, not model TTFB. No absolute product latency SLO supplied.',
        'Direct400 subtype and caller remain unknown. Invalid-request rejection is preserved separately from business refusal and valid-audio supply failure.',
        'Model diagnostics do not supply queue/inference/encoding timings. Do not infer internal root cause from absent measurements.',
        'Unrepresented proxy attempt headers do not establish caller/deployment/region. Provider ingestion completeness is unknown.',
        'Prior errors remain retained; both fixed windows are still observing, CN R134 was not deployed.',
        'Frozen regional identities and node labels do not certify every physical path has no cross-border behavior.'],
    'sources':[evidence(p) for p in [HERE/'latest-acceptance.json',OLD/'observations'/TAG/'latest-acceptance.json',HERE/'backend-snapshot-comparison.json',vpath,ppath,
        HERE/'vercel-proxy-join-summary.json',HERE/'direct400-attribution.json',HERE/'model-diagnostic-coverage-review.json',HERE/'monitor-cn-recovery.json',HERE/'cn-probe-timing-series.json',
        *[HERE/'backend-supply'/f'{r}-backend-supply.json'for r in ('us','cn','us-gpu')]]]}
save('heartbeat-review.json',review)

for path in [MON/'notification-state.json',OLD/'observations/notification-state.json']:
    state=read(path)
    state.update({'lastDecision':'NOTIFY','lastDecisionReason':reason,'recordedAtUtc':review['reviewedAtUTC'],
        'latestBackendVerdict':review['backendVerdict'],'latestBackendServiceVerdicts':services,
        'latestBackendObservationReview':str(HERE/'heartbeat-review.json'),'latestObservationReview':str(HERE/'heartbeat-review.json'),
        'latestSnapshotDirectory':'observations/'+TAG,'latestProxyWindowEndUTC':proxy['window']['endUTCExclusive'],
        'latestProxyWindowPath':str(ppath),'latestBackendSupplySnapshotPaths':[str(HERE/'backend-supply'/f'{r}-backend-supply.json')for r in ('us','cn','us-gpu')],
        'latestBackendLatencyWatch':str(HERE/'latency-watch.json'),'latestCNBackendLatencyWatch':str(HERE/'cn-latency-watch.json'),
        'latestBackendCollectionRecovery':comparison['collectionRecovery'],
        'latestReverseProxyGlobalAttribution':{'unrepresentedAttempt1CompleteGroups':sum(r['attempt']==1 and r['outcomes'].get('complete',0)==r['receivedEvents']for r in unrepresented),
            'attempt1Admissions':sum(r['receivedEvents'] for r in unrepresented if r['attempt']==1),
            'missingAttemptAdmissions':sum(r['receivedEvents']for r in unrepresented if r['attempt'] is None),
            'ambiguousProviderRequests':0,'reviewPath':str(HERE/'vercel-proxy-join-summary.json'),'callerOrDeploymentIdentityEstablished':False},
        'latestBackendPerformanceObservation':{'observedThroughUTC':proxy['window']['endUTCExclusive'],'requestFinishP95Ms':2065,
            'proxyHeadersP95Ms':1959.63,'globalPartialImprovement':True,'fullGlobalRecoveryEstablished':False,
            'cnSlowProbeCompletionUTCs':[r['observedAtUTC']for r in cn_windows[-1]['overTenSeconds']], 'cnServerSlowStageEstablished':False}})
    keys=state.setdefault('knownBackendValidationRejectionKeys',[])
    if rejection['key'] not in keys: keys.append(rejection['key'])
    state['latestBackendValidationRejection']=rejection_analysis
    state['latestKnownQuickreadDisconnectedLogs']=supply['us']['quickreadLogs']['fixedErrorRecords']
    with path.open('w')as f:json.dump(state,f,ensure_ascii=False,indent=2);f.write('\n')

save('validation.json',{'schema':'castreader.backend-observation-validation.v1','passed':True,
    'referencedSourcesShaVerified':all(evidence(Path(r['path']))==r for r in review['sources']),
    'globalProxyExactMatches':3259,'previousPendingResolved':2,'proxyPendingAtCutoff':0,
    'rawInitialCNFailureRetained':True,'sameWindowCNReadRecovery':True,
    'fixedWindowStartAndEndUnchanged':True,'liveTestsOrSynthesisStarted':False,
    'modelDiagnosticUnknownStageRows':0,'direct400AttributedWithoutBodyRead':True})
print(json.dumps({'comparison':comparison,'latency':elapsed,'join':join['counts'],
    'unrepresented':summary['unrepresentedProxyGroupsByAttempt'],'admissions':summary['unrepresentedProxyAdmissionsByAttempt'],
    'cnProbeWindows':cn_windows,'decision':'NOTIFY'},ensure_ascii=False))
