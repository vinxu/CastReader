"""Derive backend-only findings from sanitized read-only snapshots."""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
MON = HERE.parent.parent
ROOT = MON.parents[2]
OLD = ROOT/'reports/backend-audio-iteration-20260906/monitoring'
PREV = HERE.parent/'20260907T0255Z'
TAG = HERE.name

def read(p):
    return json.loads(p.read_text())

def save(name, value):
    with (HERE/name).open('x') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')

def ref(p):
    return {'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}

def dist(values):
    x=sorted(values)
    return {'samples':len(x),'p50':x[math.ceil(len(x)*.5)-1] if x else None,
        'p95':x[math.ceil(len(x)*.95)-1] if x else None,'max':max(x) if x else None}

def stamp(value):
    return datetime.fromisoformat(value.replace('Z','+00:00'))

current=read(HERE/'latest-acceptance.json')
historical=read(OLD/'observations'/TAG/'latest-acceptance.json')
previous=read(PREV/'latest-acceptance.json')
prior_review=read(PREV/'heartbeat-review.json')
proxy_path=MON/f'proxy-model-r134-{TAG}.json'
global_path=MON/f'vercel-preset-model-r134-{TAG}.json'
proxy,glob,join=read(proxy_path),read(global_path),read(HERE/'vercel-proxy-join.json')
supply={r:read(HERE/'backend-supply'/f'{r}-backend-supply.json')['result'] for r in ('us','cn','us-gpu')}
prior_supply={r:read(PREV/'backend-supply'/f'{r}-backend-supply.json')['result'] for r in ('us','cn','us-gpu')}

def snapshot(v):
    s=v['sources']
    return {'generatedAtUTC':v['generatedAtUtc'],'directStatusCounts':s['direct_gateway']['aggregate']['statusCounts'],
        'directElapsedMsMixedOutcomes':s['direct_gateway']['aggregate']['elapsedMs'],
        'globalCore5xx':s['vercel']['aggregate']['core5xxRecords'],
        'usProbeStatus':s['monitor_us']['aggregate']['statusCounts'],'cnProbeStatus':s['monitor_cn']['aggregate']['statusCounts'],
        'regionMismatchCycles':sum(s['monitor_'+r]['aggregate']['regionMismatchCycles']for r in ('us','cn')),
        'rawCollectorCoverageGaps':v['evaluation']['dataOrCoverageGaps'],'observedSeconds':v['evaluation']['observationSeconds']}

comparison={'schema':'castreader.backend-snapshot-comparison.v3','current':snapshot(current),
    'previous':prior_review['currentBackendSnapshot'],'historicalWindow':snapshot(historical),
    'excludedFromBackendVerdict':['mobile','blog','payment'],'originalAutomaticVerdictPreserved':True}
save('backend-snapshot-comparison.json',comparison)

release_dir=ROOT/'reports/direct-gateway-parity-release-20260907'
release=read(release_dir/'production-combined-receipt.json')
status=read(release_dir/'production-status-at-public-gate.json')
new_source=Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-direct-tts-text-parity-20260907/ops/tts-direct-gateway/gateway.mjs')
direct=current['sources']['direct_gateway']
assert direct['source']['sha256']==release['candidateSha256']==ref(new_source)['sha256']
assert direct['systemd']['MainPID']==release['productionMainPid']=='596392'
assert read(HERE/'direct-new-release-receipt-check.json')['allMatches']
direct_rows=read(HERE/'direct-version-requests.json')
version={'schema':'castreader.observed-direct-version-transition.v1','readOnly':True,'productionModified':False,
    'frozenExpectedCommit':'1213fcd3f9f616e92e9fd3a8f1e817b5095986c5',
    'frozenExpectedSha256':'2ca971e8f61fd004cb638a9740a6dcd459423fbcdb16956261154ed580ec282d',
    'observedCommit':release['candidateCommit'],'observedSha256':direct['source']['sha256'],
    'observedSourcePath':direct['source']['path'],'observedSourceBytes':direct['source']['bytes'],
    'systemd':direct['systemd'],'productionTransaction':{k:status['production.json'][k]for k in ('firstNewTrafficAt','verifiedAt','mainPid','sourceCommit','sourceSha256')},
    'cleanup':status['cleanup.json'],'actualMatchesIndependentReleaseReceipt':True,
    'originalFrozenExpectationMatches':False,'originalAcceptanceStateUpdated':False,'fixedWindowExtendedOrRestarted':False,
    'oneUnchangedVersionForOriginal24hCanBeCertified':False,
    'changeSummary':'Standalone Direct gateway text preprocessing parity, explicit legacy120s and extension-v1 total28s/attempt20s policies; fixed US stable origin alias normalization retained.',
    'requestCountsByRecordedPID':direct_rows['groups'],
    'sources':[ref(release_dir/'production-combined-receipt.json'),ref(release_dir/'production-status-at-public-gate.json'),ref(HERE/'direct-new-release-receipt-check.json'),ref(HERE/'direct-version-requests.json'),ref(new_source)],
    'limitations':['An independent release changed Direct during this fixed observation window. Do not replace frozen expectations from live values or certify 24h for a single Direct version.',
        'The permanent unit ledger excludes the separate candidate unit during the brief handoff; those requests remain an attribution gap.',
        'Counts include unclassified callers, existing probes and independent release validation; they are not user counts.']}
save('direct-version-transition.json',version)

assert glob['coverage']['completeForReturnedRequestCohort'] and proxy['identityAndCoverageVerified']
assert join['counts']=={'attempts':2658,'matched':2658,'ambiguous':0,'matchedProxyComplete':2658}
events=[e for r in glob['requests']for e in r['events']]
times={stage:dist([e['elapsedMs']for e in events if e['event']==stage])for stage in ('upstream_headers','upstream_body','request_finished')}
assert sum(e['event']=='upstream_body' and e.get('bodyBytes',0)>0 for e in events)==2658
represented={(r['requestKey'],r['attempt'])for r in join['attempts']}
unrepresented=[r for r in proxy['anonymousRequests']if r['receivedEvents'] and (r['requestKey'],r['attempt'])not in represented]
direct_map={r['requestKey']:r for r in direct_rows['requests']}
assert len(direct_map)==len(direct_rows['requests'])
direct_matches=[{'proxy':r,'direct':direct_map[r['requestKey']]}for r in unrepresented if r['requestKey']in direct_map]
unattributed=[r for r in unrepresented if r['requestKey']not in direct_map]
assert len(direct_matches)==707
assert all(x['proxy']['outcomes']=={'complete':1} and x['direct']['status']==200 for x in direct_matches)
summary={'schema':'castreader.backend-vercel-proxy-direct-join-summary.v2','window':proxy['window'],'coverage':join['coverage'],
    'counts':join['counts'],'globalStatusCounts':dict(Counter(str(r['vercelStatus'])for r in join['attempts'])),
    'events':glob['counts'],'elapsedMsFromRequestStart':times,'nonEmptyBodySamples':2658,
    'unrepresentedProxyGroupsByAttempt':dict(Counter(str(r['attempt'])for r in unrepresented)),
    'directMatchedGroups':len(direct_matches),'directMatchedByPIDAndAttempt':[{'pid':pid,'attempt':attempt,'count':n}for (pid,attempt),n in Counter((v['direct']['pid'],v['proxy']['attempt'])for v in direct_matches).items()],
    'directMatches':direct_matches,'remainingUnattributedGroupsByAttempt':dict(Counter(str(r['attempt'])for r in unattributed)),
    'remainingUnattributedGroups':unattributed,
    'directWithoutProxyMatch':[r for r in direct_rows['requests']if not any(p['requestKey']==r['requestKey']for p in proxy['anonymousRequests'])],
    'pendingProxyGroups':[r for r in proxy['anonymousRequests']if r['receivedEvents'] and not r['outcomes']],
    'limitations':['Direct attribution uses matching anonymized keys in PID-bound gateway journals, not attempt headers alone.',
        'The remaining89 proxy attempts cannot be assigned to Global, Direct candidate or a caller without matching evidence.',
        'Complete provider pagination does not prove ingestion completeness. HTTP200 does not prove full audio playback.']}
save('vercel-proxy-join-summary.json',summary)

incident=read(HERE/'proxy-retry-incident.json')
key='26c6fdb440baafb8efdc'
rows=[e for e in incident['events']if e.get('requestKey')==key]
attempts=[]
for number in (1,2):
    ev=[e for e in rows if e['attempt']==number]
    up=next(e for e in ev if e['stage']=='upstream_complete')
    done=next(e for e in ev if e['stage']=='request_finished')
    attempts.append({'attempt':number,'upstreamCompleteUTC':up['atUTC'],'upstreamCompleteMs':up['elapsedMs'],'upstreamBytes':up['responseBytes'],
        'upstreamStatus':up['status'],'proxyRequestFinishedUTC':done['atUTC'],'proxyElapsedMs':done['elapsedMs'],'proxyOutcome':done['outcome'],
        'afterUpstreamCompleteUntilCallerFinishedMs':round((stamp(done['atUTC'])-stamp(up['atUTC'])).total_seconds()*1000,3)})
retry={'schema':'castreader.proxy-retry-attribution.v1','requestKey':key,'attempts':attempts,
    'matchingFixedGlobalProviderRequests':sum(key in r['applicationRequestKeys']for r in glob['requests']),
    'matchingPermanentDirectRequests':sum(r['requestKey']==key for r in direct_rows['requests']),
    'callerAndDeploymentEstablished':False,'terminalCallerDeliveryEstablished':False,'modelFailureEstablished':False,
    'boundedFinding':'Both model responses completed with200 and bytes in about1.0s/1.6s. Remaining observed time is after upstream completion, in caller response/cleanup; the second handler ended cancelled. No queue/inference timeout is established for this key.',
    'unresolved':['which caller issued the attempts','why a second attempt was issued','where response/cleanup waited','what caused handler cancellation','what the requester finally received'],
    'sources':[ref(HERE/'proxy-retry-incident.json'),ref(global_path),ref(HERE/'direct-version-requests.json')],
    'correction':'Initial commentary called this a Global retry before the join completed. The completed join does not establish a Global caller; retain this correction.'}
save('proxy-retry-attribution.json',retry)

prior_keys={(r['timestampUTC'],r['tag'],r['messageSha256'])for r in prior_supply['us']['quickreadLogs']['fixedErrorRecords']}
new_qr=[{'region':region,**r}for region in ('us','cn')for r in supply[region]['quickreadLogs']['fixedErrorRecords']if (region=='cn' or (r['timestampUTC'],r['tag'],r['messageSha256'])not in prior_keys)]
identities={}
for region,name in [('us','quickreadExpectedProcess'),('cn','quickreadProcess')]:
    old_identity=read(PREV/'quickread-identity-comparison.json')[region]
    identities[region]={'current':supply[region][name],'unchangedFromPriorVerifiedIdentity':supply[region][name]==old_identity['current'],
        'releaseEvidence':old_identity['releaseEvidence'],'localLifecycleSource':old_identity['localLifecycleSource']}
    assert identities[region]['unchangedFromPriorVerifiedIdentity']
save('quickread-identity-comparison.json',identities)
qr={'schema':'castreader.quickread-disconnect-window.v1','newFixedDisconnectRecords':new_qr,'actualHttpStatusesAvailable':False,
    'callerIntentOrInitialDisconnectCauseKnown':False,'generationFaultEstablished':False,'unchangedRuntimeIdentities':identities,
    'knownSourceBehavior':'The bound request-lifecycle source signals request_disconnected on request abort or response close before completion; ordinary request close is excluded.',
    'scope':'These records demonstrate detected disconnected requests; do not turn them into HTTP502, model/LLM failure or intentional user cancellation.',
    'persistedJobCohorts':{r:supply[r]['quickreadJobs']for r in ('us','cn')},
    'sources':[ref(HERE/'backend-supply'/f'{r}-backend-supply.json')for r in ('us','cn')]}
save('quickread-disconnect-review.json',qr)

latency=read(PREV/'latency-watch.json')
latency['schema']='castreader.backend-latency-trend.v4'
latency['windows'].append({'tag':TAG,'window':glob['window'],'globalRequestCount':2658,'globalRequestFinishMs':times['request_finished'],
    'proxyUpstreamHeadersElapsedMs':proxy['stageTimingMilliseconds']['upstream_headers.elapsedMs'],
    'proxyUpstreamConnectMs':proxy['stageTimingMilliseconds']['upstream_connected.connectMs']})
latency.update({'classification':'continued_partial_improvement','boundedFinding':'GlobalP95 continues2065 to1755ms; proxy header wait1959.630 to1663.523ms. Two improving hours still do not prove an entire-window recovery or all-service performance.',
    'requestFinishP95ChangeFromPriorPercent':round((1755/2065-1)*100,2),'requestFinishP95ChangeFromBaselinePercent':round((1755/1570-1)*100,2),
    'fullRecoveryEstablished':False,'internalCauseResolved':False})
latency.pop('sizeBucketEvidence',None)
save('latency-watch.json',latency)
cn_series=read(HERE/'cn-probe-timing-series.json')
cn_rows=[r for r in cn_series['rows']if stamp(proxy['window']['startUTC'])<=stamp(r['observedAtUTC'])<stamp(proxy['window']['endUTCExclusive'])]
cn_watch={'schema':'castreader.cn-probe-latency-watch.v2','window':proxy['window'],'samples':len(cn_rows),
    'probeElapsedMs':dist([r['elapsedMs']for r in cn_rows]),'overTenSeconds':[r for r in cn_rows if r['elapsedMs']>10000],
    'allComplete':all(r['completeAudio'] and r['supplyOk']for r in cn_rows),'allFirstAttempt':all(r['segmentAttempts']==[1,1,1]for r in cn_rows),
    'modelOrHttpTtfbEstablished':False,'internalCauseResolved':False,
    'limitations':['Whole three-segment probe duration includes HTTP, local decode and validation. It is not model latency or a user playback outcome.'],
    'source':ref(HERE/'cn-probe-timing-series.json')}
save('cn-latency-watch.json',cn_watch)

delta={'schema':'castreader.backend-service-delta.v2','quickreadIdentityUnchanged':{r:v['unchangedFromPriorVerifiedIdentity']for r,v in identities.items()},
    'usCloneProcessUnchanged':supply['us-gpu']['expectedCloneProcess']==prior_supply['us-gpu']['expectedCloneProcess'],
    'usNariProcessUnchanged':supply['us-gpu']['expectedNariProcess']==prior_supply['us-gpu']['expectedNariProcess'],
    'cnUnitsUnchanged':supply['cn']['units']==prior_supply['cn']['units'],
    'cloneCounterChanges':{region:{k:supply[role]['cloneHealthAfterCutoff']['fields'][k]-prior_supply[role]['cloneHealthAfterCutoff']['fields'][k]for k in ('submitted','completed','failed','expired')}for region,role in [('us','us-gpu'),('cn','cn')]},
    'newCNQuickreadReadyModifiedFiles':supply['cn']['quickreadJobs']['filesModifiedInWindow']-prior_supply['cn']['quickreadJobs']['filesModifiedInWindow'],
    'newQuickreadDisconnectRecords':new_qr,
    'directKnownNoResponseKeysUnchanged':{r['key']for r in current['sources']['direct_gateway']['aggregate']['nonHttpRequests']}=={r['key']for r in previous['sources']['direct_gateway']['aggregate']['nonHttpRequests']}}
save('backend-service-delta.json',delta)

collection={'schema':'castreader.vercel-read-recovery.v1','initialFailures':[ref(MON/f'vercel-preset-model-r134-{TAG}-part{i}.json')for i in (1,2)],
    'initialHttpStatuses':[403,403],'readOnlyCliIdentityCheckSucceeded':True,'sameFixedWindowsRetried':True,
    'retrySources':[ref(MON/f'vercel-preset-model-r134-{TAG}-part{i}-retry1.json')for i in (1,2)],
    'recoveredReturnedPaginationComplete':True,'ingestionCompletenessVerified':False,'precise403CauseEstablished':False,
    'credentialValuesExported':False,'productionModified':False,'synthesisStarted':False,
    'note':'Original403 responses preserved. An authorized CLI account read succeeded, followed by a200 logs diagnostic and successful unchanged-window retries; this is collection recovery, not a productionTTS outage.'}
save('vercel-collection-recovery.json',collection)

services=[
 {'region':'global','service':'kokoro_tts','backendVerdict':'符合预期','scope':'本小时可见Global有效HTTP供给；既往时延退化继续观察',
  'evidence':'2658条Global均200、非空body并完成、单次尝试，全部精确关联代理完成；P95降至1755ms。Direct新PID472条、旧PID245条均200；观察窗包含两个Direct版本，原固定版本24h不能成立。'},
 {'region':'cn','service':'kokoro_tts','backendVerdict':'证据不足','scope':'可见供给成功，断开及整轮校验时延仍未归因',
  'evidence':'844条已解析TTS POST200，另1条nginx记录499、交付未知。108轮合同健康；本小时12轮完整，仍有11.039和12.337秒整轮耗时，缺HTTP/解码分项。'},
 {'region':'global','service':'clone_tts','backendVerdict':'证据不足','scope':'本窗口真实合成','evidence':'健康、累计173完成、0失败/过期不变，仍无窗口结构化合成样本。'},
 {'region':'cn','service':'clone_tts','backendVerdict':'证据不足','scope':'本窗口真实合成','evidence':'健康、累计4完成、0失败/过期不变，不能替代窗口合成结果。'},
 {'region':'global','service':'quickread','backendVerdict':'证据不足','scope':'可见生成正常，新增断开交付结果未知',
  'evidence':'102份窗口修改任务均ready有首块，87份全块生成、15份可续；本小时17条权益放行，新增1条request_disconnected，无实际HTTP结果或LLM故障证据。'},
 {'region':'cn','service':'quickread','backendVerdict':'证据不足','scope':'首次获得任务正向样本，完整HTTP交付仍有缺口',
  'evidence':'新增16条权益放行和15份ready首块任务，14份全块生成、1份可续；另1条request_disconnected，无法与持久任务或HTTP交付逐条贯通。'}]
reason='Direct已被独立发布更换版本并有完整回执；需保留新旧版本边界。中国区解读首次有正向任务样本；新断开/取消仍未证实模型或LLM供给失败。'
review={'schema':'castreader.backend-audio-heartbeat-review.v4','automationId':'24','reviewedAtUTC':datetime.now(timezone.utc).isoformat(),
    'decision':'NOTIFY','decisionReason':reason,'observationScope':'backend_tts_clone_quickread_only','backendVerdict':'证据不足',
    'backendVerdictReason':'有效供给未出现新增已确认故障，但Direct固定版本被独立发布改变，克隆及部分交付/时延归因仍不足。',
    'readOnly':True,'productionModified':False,'synthesisStarted':False,'finalWindow':current['window'],'backendDetailWindow':proxy['window'],
    'services':services,'currentBackendSnapshot':comparison['current'],'historicalBackendSnapshot':comparison['historicalWindow'],
    'newConfirmedValidTtsOrLlmSupplyFailures':[],'newObservedDirectVersion':version,'newQuickreadDisconnectRecords':new_qr,
    'newProxyCancellation':retry,'newCNIngressLoggedNon200':read(HERE/'cn-ingress-non200.json'),
    'latencyWatch':latency,'cnLatencyWatch':cn_watch,'collectionRecovery':collection,
    'limitations':['Original acceptance verdict includes out-of-scope clients; backend conclusion is independent and never rewrites history.',
        'Existing Direct400 parameter rejection and older model400/502/504 remain retained; no_response and cancellation do not establish success, model timeout or user intent.',
        'Frozen Direct expectation is deliberately not replaced with live values. Independent rollout evidence explains the mismatch but cannot restore a single-version24h observation.',
        'CN499 is a recorded ingress status with unknown requester delivery; no full HTTP response or downstream intent is proven.',
        'QuickRead task-file outcomes are modified-file cohorts, not complete new-request or HTTP ledgers.',
        'Node/source identity and approved same-region routing do not certify every physical path has no cross-border behavior.',
        'Prior attribution to Global for the proxy retry was provisional and is corrected: no fixed-deployment match or permanent Direct journal match.'],
    'sources':[ref(p)for p in [HERE/'latest-acceptance.json',OLD/'observations'/TAG/'latest-acceptance.json',proxy_path,global_path,
        HERE/'direct-version-transition.json',HERE/'vercel-proxy-join-summary.json',HERE/'proxy-retry-attribution.json',HERE/'quickread-disconnect-review.json',
        HERE/'cn-ingress-non200.json',HERE/'cn-latency-watch.json',HERE/'vercel-collection-recovery.json',*[HERE/'backend-supply'/f'{r}-backend-supply.json'for r in ('us','cn','us-gpu')]]]}
save('heartbeat-review.json',review)
for path in [MON/'notification-state.json',OLD/'observations/notification-state.json']:
    state=read(path)
    state.update({'lastDecision':'NOTIFY','lastDecisionReason':reason,'recordedAtUtc':review['reviewedAtUTC'],'latestBackendVerdict':'证据不足',
        'latestBackendServiceVerdicts':services,'latestBackendObservationReview':str(HERE/'heartbeat-review.json'),'latestObservationReview':str(HERE/'heartbeat-review.json'),
        'latestSnapshotDirectory':'observations/'+TAG,'latestProxyWindowEndUTC':proxy['window']['endUTCExclusive'],'latestProxyWindowPath':str(proxy_path),
        'latestBackendSupplySnapshotPaths':[str(HERE/'backend-supply'/f'{r}-backend-supply.json')for r in ('us','cn','us-gpu')],
        'latestBackendLatencyWatch':str(HERE/'latency-watch.json'),'latestCNBackendLatencyWatch':str(HERE/'cn-latency-watch.json'),
        'latestObservedDirectVersion':version,'latestBackendCollectionRecovery':collection,
        'latestKnownQuickreadDisconnectedLogs':[{'region':region,**r}for region in ('us','cn')for r in supply[region]['quickreadLogs']['fixedErrorRecords']],
        'latestReverseProxyGlobalAttribution':{'unrepresentedAttempt1CompleteGroups':550,'missingAttemptGroups':245,'attempt2CancelledGroups':1,
            'directExactMatchedGroups':707,'remainingUnattributedAttempt1Groups':88,'remainingUnattributedAttempt2Groups':1,
            'reviewPath':str(HERE/'vercel-proxy-join-summary.json'),'remainingCallerOrDeploymentIdentityEstablished':False},
        'latestBackendPerformanceObservation':{'observedThroughUTC':proxy['window']['endUTCExclusive'],'requestFinishP95Ms':1755,'proxyHeadersP95Ms':1663.523,
            'globalPartialImprovement':True,'fullGlobalRecoveryEstablished':False,'cnSlowProbeCompletionUTCs':[r['observedAtUTC']for r in cn_watch['overTenSeconds']],'cnServerSlowStageEstablished':False}})
    state['knownObservedDirectVersionSha256']=list(dict.fromkeys(state.get('knownObservedDirectVersionSha256',[])+[version['observedSha256']]))
    state['knownProxyCancellationKeys']=list(dict.fromkeys(state.get('knownProxyCancellationKeys',[])+[key]))
    state['knownCNIngressLogged499']=read(HERE/'cn-ingress-non200.json')['non200Rows']
    state['knownCNLongProbeSourceSha256']=list(dict.fromkeys(state.get('knownCNLongProbeSourceSha256',[])+[r['sourceSha256']for r in cn_watch['overTenSeconds']]))
    path.write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'globalElapsedMs':times,'directVersion':version['observedCommit'],'directRequests':direct_rows['groups'],
    'reverseAttribution':summary['remainingUnattributedGroupsByAttempt'],'cnProbeElapsedMs':cn_watch['probeElapsedMs'],
    'backendVerdict':'证据不足','decision':'NOTIFY'},ensure_ascii=False))
