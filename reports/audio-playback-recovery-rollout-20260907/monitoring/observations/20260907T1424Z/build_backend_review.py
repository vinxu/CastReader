"""Review the 14:24 UTC backend-only window using preserved, sanitized evidence."""
import collections,hashlib,json,math
from datetime import datetime,timezone
from pathlib import Path
O=Path(__file__).resolve().parent;M=O.parent.parent;P=O.parent/'20260907T1340Z'
read=lambda f:json.loads(f.read_text())
def write(path,value):
 with path.open('x') as f:json.dump(value,f,ensure_ascii=False,indent=2);f.write('\n')
a=read(O/'latest-acceptance.json');p=read(O/'proxy-window.json');v=read(O/'vercel-preset.json');j=read(O/'vercel-proxy-join.json');d=read(O/'direct-version-requests.json');dc=read(O/'direct-complete-cumulative.json');old=read(P/'backend-review.json')
s={r:read(O/'backend-supply'/f'{r}-backend-supply.json')['result'] for r in ['us','cn','us-gpu']};ps={r:read(P/'backend-supply'/f'{r}-backend-supply.json')['result'] for r in s};models={r:read(O/f'{r}-r135-model.json') for r in ['us','cn']}
finish=[e for q in v['requests'] for e in q['events'] if e['event']=='request_finished'];times=sorted(e['elapsedMs'] for e in finish if e.get('status')==200);perf={'samples':len(times),'p95Ms':times[math.ceil(len(times)*.95)-1] if times else None,'maxMs':max(times) if times else None}
index=collections.defaultdict(list)
for r in p['anonymousRequests']:index[r['requestKey']].append(r)
dj=[]
for r in d['requests']:
 hits=index[r['requestKey']];dj.append({'requestKey':r['requestKey'],'directStatus':r['status'],'directElapsedMs':r['elapsedMs'],'directCompletionUTC':r['observedAtUTC'],'matchCount':len(hits),'ambiguous':len(hits)>1 or any(h['ambiguousRepeatedRequestKey'] for h in hits),'proxyOutcomes':[h['outcomes'] for h in hits]})
gk={r['requestKey'] for r in j['attempts'] if r['matchCount']==1 and not r['ambiguous']};dk={r['requestKey'] for r in dj if r['matchCount']==1 and not r['ambiguous']};remaining=[r for r in p['anonymousRequests'] if r['requestKey'] not in gk|dk]
# Previously open requests can complete in this event window; bind by key and flight, never by counts.
previous_open=[q for q in read(P/'proxy-window.json')['anonymousRequests'] if not q['outcomes']]
boundary=[]
for q in previous_open:
 for now in index[q['requestKey']]:
  if not now['receivedEvents'] and set(q['flightKeys'])&set(now['flightKeys']):boundary.append({'priorGroup':q,'currentGroup':now,'sameAnonymousCallerAndFlight':True,'priorSource':str(P/'proxy-window.json')})
reverse={'schema':'castreader.backend-reverse-attribution.v1','readOnly':True,'global':j['counts'],'direct':{'requests':len(dj),'exactMatched':len(dk),'records':dj},'remainingUnattributedProxyGroups':remaining,'priorWindowCompletions':boundary,'cancelledProxyGroups':[r for r in p['anonymousRequests'] if r['outcomes'].get('cancelled')],'limitations':['Repeated caller keys and attempts remain ambiguous even when all grouped outcomes are complete.','Vercel request-start and proxy event/completion windows differ. A previous-window completion is reported separately.','No request body, audio or client telemetry was read.']}
boundary_keys={b['currentGroup']['requestKey'] for b in boundary}
remaining_classification={'priorWindowCompletionGroups':sum(q['requestKey'] in boundary_keys for q in remaining),'repeatedCallerKeyGroups':sum(q['ambiguousRepeatedRequestKey'] for q in remaining),'otherwiseUnattributedGroups':sum(not q['ambiguousRepeatedRequestKey'] and q['requestKey'] not in boundary_keys for q in remaining)}
reverse['remainingGroupClassification']=remaining_classification
write(O/'reverse-attribution.json',reverse)
cn={r['status']:r['count'] for r in s['cn']['ttsIngress']['routeMethodStatuses'] if r['path']=='/api/captioned_speech_partly' and r['method']=='POST'};delta={k:n-old['cnTts']['parsedCumulativeStatuses'].get(k,0) for k,n in cn.items()};cnseries=read(O/'cn-probe-timing-series.json');cn499=read(O/'cn-tts-499-ingress.json');warnings=read(O/'clone-warning-detail.json');frontend=read(O/'frontend-recovery-attribution.json')
probes={}
for r in ['us','cn']:
 m=a['sources']['monitor_'+r];prev=old['existingProbes'][r]
 probes[r]={'cycles':m['aggregate']['cycles'],'statusCounts':m['aggregate']['statusCounts'],'newHealthyCycles':m['aggregate']['statusCounts'].get('healthy',0)-prev['statusCounts'].get('healthy',0),'newSupplyFailedCycles':m['aggregate']['statusCounts'].get('supply_failed',0)-prev['statusCounts'].get('supply_failed',0),'regionMismatchCycles':m['aggregate']['regionMismatchCycles'],'lastCompletedUTC':m['source']['lastSelectedObservedAt'],'currentConsecutiveFailures':m['aggregate']['supplyFailureSequence']['currentConsecutiveCycles']}
newqr={r:[e for e in s[r]['quickreadLogs']['fixedErrorRecords'] if e not in old['quickread'][r]['knownFixedErrorRecords']] for r in ['us','cn']}
identity={'usQuickreadUnchanged':s['us']['quickreadExpectedProcess']==ps['us']['quickreadExpectedProcess'],'cnQuickreadUnchanged':s['cn']['quickreadProcess']==ps['cn']['quickreadProcess'],'cnServiceUnitsUnchanged':s['cn']['units']==ps['cn']['units'],'usCloneProcessUnchanged':s['us-gpu']['expectedCloneProcess']==ps['us-gpu']['expectedCloneProcess'],'usNariProcessUnchanged':s['us-gpu']['expectedNariProcess']==ps['us-gpu']['expectedNariProcess'],'directSourceUnchanged':dc['source']==read(P/'direct-complete-cumulative.json')['source'],'directProcessUnchanged':dc['systemd']==read(P/'direct-complete-cumulative.json')['systemd'],'globalDeploymentUnchanged':a['sources']['global_capabilities']['identity']==read(P/'latest-acceptance.json')['sources']['global_capabilities']['identity']}
assert all(identity.values()) and not any(newqr.values()) and all(m['identity']['verified'] and not m['failureEvents'] for m in models.values())
assert p['identityAndCoverageVerified'] and not p['failureEvents'] and v['coverage']['completeForReturnedRequestCohort'] and dc['coverage']['complete']
assert all(e.get('status')==200 for e in finish) and a['sources']['vercel']['aggregate']['core5xxRecords']==1
assert delta.get('502',0)==0 and all(q['newSupplyFailedCycles']==0 and q['regionMismatchCycles']==0 for q in probes.values())
assert dc['aggregate']['statusCounts']['no_response']==20 and dc['aggregate']['statusCounts']['400']==1
assert all(r['allMatchingGroupsOnlyHaveCompleteOutcomes'] for r in frontend['rows']) and all(w['blocking'] is False for w in warnings['warnings'])
clone_completed=sum(e['count'] for e in s['us-gpu']['cloneStructuredLog']['incrementalEvents'] if e['event']=='gpu_job_completed' and e['kind']=='captioned-speech')
newcn499=cn499['rows'];now=datetime.now(timezone.utc).isoformat()
review={'schema':'castreader.backend-heartbeat-review.v1','automationId':'24','readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'reviewedAtUTC':now,'snapshotDirectory':str(O),'fixedWindow':a['window'],'incrementalWindow':p['window'],'backendVerdict':'存在异常（历史故障保留）；本轮未见新增确证供给失败，解读/克隆完整交付仍证据不足','decision':'DONT_NOTIFY','newActionableChange':False,'reason':'当前身份、供给和既有探针稳定。新增CN入口499结果未知；非阻断声学提示和可选前处理降级无供给终止证据。已知慢探针及交付缺口继续保留，无新用户操作需求。',
'globalTts':{'requests':len(v['requests']),'finished200':len(times),'allAttempt1':all(e['attempt']==1 for e in finish),'globalElapsedMs':perf,'proxyCounts':p['counts'],'coalescing':p['coalescing'],'proxyTimingsMs':p['stageTimingMilliseconds'],'globalJoin':j['counts'],'proxyIdentityAndCoverageVerified':True,'cumulativeCore5xx':1,'historicalJapanese500Preserved':True},
'direct':{'cumulativeStatusCounts':dc['aggregate']['statusCounts'],'source':dc['source'],'incrementalExactWindow':dict(collections.Counter(str(r['status']) for r in d['requests'])),'newDownstreamDisconnects':[],'knownFrozenVersionMismatchPreserved':True,'cumulativeCoverage':dc['coverage'],'cumulativeSource':str(O/'direct-complete-cumulative.json'),'legacyAcceptanceSnapshotTruncated':True,'journalRows':dc['aggregate']['journalRowsRead']},
'cnTts':{'parsedCumulativeStatuses':cn,'incrementalStatuses':delta,'newLogged499':newcn499,'logged499Meaning':'Ingress log outcome only; caller intent, root cause, actual delivered status and audio result unknown.','baseline':str(P/'backend-supply/cn-backend-supply.json'),'unparsedFileLines':s['cn']['ttsIngress']['unparsedLines'],'knownMaintenance502Count':2,'new502':0,'publicationAvailabilityGapClosed':False,'existingProbeSeries':cnseries,'wholeProbeIsModelTTFB':False},
'proxyAttribution':{'globalExactMatched':len(gk),'directExactMatched':len(dk),'remainingUnattributedGroups':len(remaining),'priorWindowCompletionCount':len(boundary),'remainingGroupClassification':remaining_classification,'source':str(O/'reverse-attribution.json')},'runtimeComparisonsToPreviousSnapshot':identity,
'models':{r:{'release':m['release'],'identityVerified':m['identity']['verified'],'diagnosticWindow':m['window'],'fixedStageCounts':m['fixedStageCounts'],'failureEvents':m['failureEvents'],'successLedgerComplete':False} for r,m in models.items()},'optionalFrontendReview':str(O/'frontend-recovery-attribution.json'),'existingProbes':probes,
'quickread':{r:{'incrementalFixedTagCounts':s[r]['quickreadLogs']['incrementalFixedTagCounts'],'knownFixedErrorRecords':s[r]['quickreadLogs']['fixedErrorRecords'],'newFixedErrorRecords':newqr[r],'readyFileOutcomes':{'modifiedFiles':s[r]['quickreadJobs']['filesModifiedInWindow'],'allBlocks':s[r]['quickreadJobs']['allServerBlocksGenerated'],'partialReady':s[r]['quickreadJobs']['partialButReady']},'backendVerdict':'有新增ready结果，无新固定错误；完整HTTP交付仍缺证据'} for r in ['us','cn']},
'clone':{'us':{'incrementalEvents':s['us-gpu']['cloneStructuredLog']['incrementalEvents'],'startupHealthCounters':s['us-gpu']['cloneHealthAfterCutoff']['fields'],'nonblockingWarningReview':str(O/'clone-warning-detail.json'),'backendVerdict':f'{clone_completed}条已观测captioned-speech任务完成；两条非阻断声学提示保留，完整HTTP交付不足'},'cn':{'startupHealthCounters':s['cn']['cloneHealthAfterCutoff']['fields'],'backendVerdict':'证据不足：本轮无新生产样本'}},'preservedIssues':old['preservedIssues'],
'limitations':['Complete HTTP output, ready blocks and generated audio tasks do not establish full user playback.','CN499 is not a delivered HTTP error, proven model failure or intentional user cancellation.','Repeated application keys remain ambiguous and are not forced into unique request attribution.','The previous window open proxy request completed in this event window; do not re-count it as a new start.','QuickRead known disconnect records remain US2/CN3; no new root cause or complete delivery ledger.','Provider pagination completeness does not prove ingestion completeness.','Cumulative probes are selected through collector time, later than the exact window; the CN exact-window series and cumulative deltas are different cohorts.','The original 250k-row Direct snapshot is retained; the bounded 500k supplement restores journal parsing coverage.','Known slow CN probes and historical errors are not cleared by later success. Original fixed window and frozen expectations remain unchanged.'],
'sources':[{'path':str(f),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in sorted(O.rglob('*.json'))]}
write(O/'backend-review.json',review)
md=f'''# 后端观察：2026-09-07 14:24 UTC

本轮没有新增确证供给失败或需要用户处理的变化，保持静默。历史故障、已知慢探针、请求归属歧义及完整交付缺口全部保留。

- 精确增量窗口：13:40:22.326–14:24:51.334 UTC。国际区 Global {len(v['requests']):,} 个可见请求均返回200，应用耗时P95={perf['p95Ms']}ms。US代理记录2,958个完整响应，20次共享已有生成任务；其中1个响应属于上一窗口已开始的请求。
- Direct新增743个200，无新增无响应/4xx/5xx。固定窗完整补采累计11,040个200、1个既知400、20个无响应；250,000行旧采集上限仍会截断，单独500,000行有界补采覆盖342,036行，原始截断快照保留。
- 中国区新增177个已解析200，14:09:46 UTC另有1条入口499；实际音频结果及初始断开原因未知，不认定为模型失败或用户主动取消。无新增502，维护期2条502保留。
- 既有探针US229/229、CN228/229健康，唯一失败仍是已知维护轮次；无新增地区不一致。CN精确窗口9轮均完整，其中15,205ms和13,197ms两轮耗时偏长，沿用已知慢探针问题，不把整轮耗时当单请求模型TTFB。
- 两区模型、QuickRead、克隆/Nari、Direct及Global身份未变。US固定诊断有6次英文恢复、6次可选源文本准备降级、10次分隔符推进；CN有2次分隔符推进。所有相关代理组仅含complete结果，但部分调用方键重复，不能强行逐请求归属。
- 国际区解读新增11条放行，ready文件151→161；中国区新增2条放行，ready文件20→22。固定断开仍US2/CN3，无新增；ready文件不是完整HTTP交付证明。
- US克隆新增95条captioned-speech任务完成，新增音高和时长提示各1条，均明确blocking=false；不据此认定播放失败，也不忽略声学质量提示。CN克隆无新生产样本。
- 精确无歧义关联Global {len(gk)}个、Direct {len(dk)}个；剩余{len(remaining)}个代理组中，{remaining_classification['priorWindowCompletionGroups']}个是已精确关联的上窗完成、{remaining_classification['repeatedCallerKeyGroups']}个存在重复调用方键，另外{remaining_classification['otherwiseUnattributedGroups']}个仍未归属，不按计数或attempt头补齐。

[后端评估](backend-review.json) · [关联和窗口边界](reverse-attribution.json) · [CN499](cn-tts-499-ingress.json) · [可选前处理降级](frontend-recovery-attribution.json) · [非阻断声学提示](clone-warning-detail.json)。固定观察仍于2026-09-07 18:37:52 UTC截止，不重置或延长。
'''
(O/'README.md').write_text(md)
path=M/'notification-state.json';state=read(path)
state.update({'latestSnapshotDirectory':str(O),'latestObservationReview':str(O/'backend-review.json'),'latestBackendObservationReview':str(O/'backend-review.json'),'latestCollectionAttemptDirectory':str(O),'latestCollectionAttemptReview':str(O/'backend-review.json'),'latestProxyWindowPath':str(O/'proxy-window.json'),'latestProxyWindowEndUTC':p['window']['endUTCExclusive'],'latestVercelCore5xxCount':1,'latestDirect5xxCount':0,'latestDirectNoResponseCount':20,'latestDirectHttp400Count':1,'latestBackendVerdict':review['backendVerdict'],'latestBackendSupplySnapshotPaths':[str(O/'backend-supply'/f'{r}-backend-supply.json') for r in s],'latestBackendHeartbeatDecision':{'decision':'DONT_NOTIFY','reason':review['reason'],'reviewedAtUTC':now},'latestReverseProxyGlobalAttribution':review['proxyAttribution'],'latestBackendPerformanceObservation':{'observedThroughUTC':p['window']['endUTCExclusive'],'successfulRequestFinishP95Ms':perf['p95Ms'],'proxyHeadersP95Ms':p['stageTimingMilliseconds']['upstream_headers.elapsedMs']['p95'],'sustainedGlobalRecoveryEstablished':False,'cnServerSlowStageEstablished':False},'latestCNBackendLatencyWatch':str(O/'cn-probe-timing-series.json'),'latestBackendDisconnectReview':str(O/'reverse-attribution.json'),'latestCloneWarningReview':str(O/'clone-warning-detail.json'),'latestOptionalFrontendGroupReview':str(O/'frontend-recovery-attribution.json'),'currentBackendCollectionStatus':'available','latestCompleteDirectSupplement':str(O/'direct-complete-cumulative.json'),'recordedAtUtc':now,'lastDecision':'DONT_NOTIFY','lastDecisionReason':review['reason']})
state.setdefault('knownCNIngressLogged499',[]).extend({'observedAtUTC':e['atUTC'],'path':e['path'],'method':e['method'],'loggedStatus':e['loggedStatus'],'lineFingerprint':e['lineFingerprint']} for e in newcn499)
state.setdefault('knownCloneNonblockingWarningEvents',[]).extend({'atUTC':w['atUTC'],'event':w['event'],'blocking':w['blocking'],'warnings':w.get('warnings',[])} for w in warnings['warnings'])
state['knownCNLongProbeSourceSha256']=sorted(set(state.get('knownCNLongProbeSourceSha256',[]))|{r['sourceSha256'] for r in cnseries['rows'] if r['elapsedMs']>10000})
state['latestBackendServiceVerdicts']=[{'region':'global','service':'kokoro_tts','backendVerdict':'本轮可见供给正常；重复键歧义和历史异常保留','evidence':f'{len(times)}个Global完整200，无新终止失败'},{'region':'cn','service':'kokoro_tts','backendVerdict':'本轮177个已解析200，无新增502；1条入口499结果未知，旧慢阶段未关闭'},{'region':'global','service':'quickread','backendVerdict':'有新增ready结果，无新增固定错误；完整交付不足'},{'region':'cn','service':'quickread','backendVerdict':'有新增ready结果，无新增固定错误；完整交付不足'},{'region':'global','service':'clone_tts','backendVerdict':f'{clone_completed}条已观测生成完成、2条非阻断声学提示；完整交付不足'},{'region':'cn','service':'clone_tts','backendVerdict':'证据不足：本轮无新生成样本'}]
path.write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'decision':review['decision'],'globalRequests':len(v['requests']),'p95Ms':perf['p95Ms'],'remainingProxyGroups':len(remaining),'newCN499':len(newcn499),'newConfirmedSupplyFailures':0},ensure_ascii=False))
