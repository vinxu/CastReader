import hashlib,json,math
from pathlib import Path
from datetime import datetime,timezone
BASE=Path('/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907')
OUT=Path(__file__).resolve().parent
read=lambda p:json.loads(p.read_text())
a=read(OUT/'latest-acceptance.json');p=read(OUT/'proxy-window.json');v=read(OUT/'vercel-preset.json');j=read(OUT/'vercel-proxy-join.json')
supply={r:read(OUT/'backend-supply'/f'{r}-backend-supply.json')['result'] for r in ['us','cn','us-gpu']}
models={r:read(OUT/f'{r}-r135-model.json') for r in ['us','cn']}
oldcn=read(BASE/'model-r135/observation/backend-supply/cn-backend-supply.json')['result']['ttsIngress']['routeMethodStatuses']
def count(rows):return {str(row['status']):row['count'] for row in rows if row['path']=='/api/captioned_speech_partly' and row['method']=='POST'}
cncounts=count(supply['cn']['ttsIngress']['routeMethodStatuses']);prevcount=count(oldcn)
cnnew={key:value-prevcount.get(key,0) for key,value in cncounts.items()}
finished=[e for r in v['requests'] for e in r['events'] if e['event']=='request_finished']
times=sorted(e['elapsedMs'] for e in finished)
metrics={'samples':len(times),'p95Ms':times[math.ceil(len(times)*.95)-1],'maxMs':max(times)}
probes={}
for r in ['us','cn']:
 m=a['sources']['monitor_'+r]
 probes[r]={'cycles':m['aggregate']['cycles'],'statusCounts':m['aggregate']['statusCounts'],'failureCodeCounts':m['aggregate']['failureCodeCounts'],'regionMismatchCycles':m['aggregate']['regionMismatchCycles'],'latestCompletedUTC':m['source']['lastSelectedObservedAt'],'currentConsecutiveSupplyFailures':m['aggregate']['supplyFailureSequence']['currentConsecutiveCycles']}
new_failure=any(x.get('status',200)>=400 for x in finished) or any(m['failureEvents'] or not m['identity']['verified'] for m in models.values()) or any(value>0 and int(key)>=500 for key,value in cnnew.items()) or a['sources']['vercel']['aggregate']['core5xxRecords']>1
assert not new_failure
assert j['counts']=={'attempts':204,'matched':204,'ambiguous':0,'matchedProxyComplete':204}
review={
 'schema':'castreader.backend-heartbeat-review.v1','automationId':'24','readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,
 'reviewedAtUTC':datetime.now(timezone.utc).isoformat(),'snapshotDirectory':str(OUT),'fixedWindow':a['window'],
 'incrementalProxyWindow':p['window'],'backendVerdict':'存在异常（历史故障保留）；本次增量未见新增后端技术失败，解读及克隆交付证据仍不足',
 'newActionableChange':False,'decision':'DONT_NOTIFY','reason':'R135修复及中国区维护故障已在正常任务说明；本轮身份一致、无新增后端错误，既有供给恢复持续。',
 'globalTts':{'returnedGlobalRequests':len(v['requests']),'globalFinished200':sum(e.get('status')==200 for e in finished),'globalFinishedNon200':sum(e.get('status')!=200 for e in finished),'allAttempt1':all(e['attempt']==1 for e in finished),'globalElapsedMs':metrics,'proxyCounts':p['counts'],'proxyTimingsMs':p['stageTimingMilliseconds'],'joinCounts':j['counts'],'proxyIdentityAndCoverageVerified':p['identityAndCoverageVerified'],'reverseUnattributedGroups':len(p['anonymousRequests'])-j['counts']['matched'],'globalCumulativeCore5xx':a['sources']['vercel']['aggregate']['core5xxRecords'],'originalJapanese500Preserved':True},
 'direct':{'cumulativeStatusCounts':a['sources']['direct_gateway']['aggregate']['statusCounts'],'source':a['sources']['direct_gateway']['source'],'newRequestsSincePreviousSnapshot':0,'knownMixedVersionMismatchPreserved':True,'noResponseIsSuccessOrHttpFailure':False},
 'cnTts':{'parsedCumulativeStatuses':cncounts,'deltaFromPreviousSupplySnapshot':cnnew,'comparisonBaseline':str(BASE/'model-r135/observation/backend-supply/cn-backend-supply.json'),'unparsedFileLines':supply['cn']['ttsIngress']['unparsedLines'],'knownMaintenance502Count':2,'newMaintenance502Count':cnnew.get('502',0),'releaseIdentityVerified':models['cn']['identity']['verified'],'cnPublicationAvailabilityGapClosed':False},
 'models':{r:{'release':m['release'],'identityVerified':m['identity']['verified'],'diagnosticWindow':m['window'],'fixedStageCounts':m['fixedStageCounts'],'failureEvents':m['failureEvents'],'successLedgerComplete':False} for r,m in models.items()},
 'existingProbes':probes,
 'quickread':{r:{'incrementalFixedTagCounts':supply[r]['quickreadLogs']['incrementalFixedTagCounts'],'knownFixedErrorRecords':supply[r]['quickreadLogs']['fixedErrorRecords'],'readyFileOutcomes':{'modifiedFiles':supply[r]['quickreadJobs']['filesModifiedInWindow'],'allBlocks':supply[r]['quickreadJobs']['allServerBlocksGenerated'],'partialReady':supply[r]['quickreadJobs']['partialButReady']},'healthStatus':supply[r]['quickreadHealthAfterCutoff']['httpStatus'],'backendVerdict':'证据不足：无增量请求/故障，已存生成结果不是完整HTTP交付'} for r in ['us','cn']},
 'clone':{'us':{'incrementalEvents':supply['us-gpu']['cloneStructuredLog']['incrementalEvents'],'startupHealthCounters':supply['us-gpu']['cloneHealthAfterCutoff']['fields'],'backendVerdict':'证据不足：无增量生成样本；已观察历史供给无新增故障'},'cn':{'startupHealthCounters':supply['cn']['cloneHealthAfterCutoff']['fields'],'backendVerdict':'证据不足：无本轮真实生成样本'}},
 'preservedIssues':['历史Global504的逐阶段归因与持续恢复','中国区慢探针分项耗时证据','QuickRead US2/CN1 request_disconnected及交付日志缺口','中国区模型发布空窗','Direct独立版本变更、旧代理过渡区间覆盖缺口'],
 'limitations':['HTTP200和已存ready块不是用户完成播放的证明。','Vercel分页覆盖完整仅针对已返回请求；日志写入完整性仍未认证。','数字、语言或文本样本分布未读取，本窗无日语专属真实请求覆盖证明。','CN解析统计可能包含发布验证和探针，不能换算用户数。','本轮没有执行额外合成，也没有更改生产代码、进程、路由或权益。','固定窗口包含多版本及历史失败，不重置或延长，不认证R135已运行24小时。'],
 'sources':[{ 'path':str(f),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in sorted(OUT.rglob('*.json'))]
}
with (OUT/'backend-review.json').open('x') as f:json.dump(review,f,ensure_ascii=False,indent=2);f.write('\n')
md=f'''# 后端 R135 上线后观察：2026-09-07 07:18 UTC\n\n本轮没有新增需要通知的后端变化，继续静默观察。历史 Global 日语500及中国区维护502保留；全窗口不能判为全部符合预期。\n\n- 国际区07:02:32—07:18:20：204个Global请求均200、attempt1，并逐条关联到204个完整US代理响应；没有重复关联、未归属或新错误。应用耗时P95为{metrics['p95Ms']}ms；代理响应头P95为963.884ms。这只是本轮请求分布，不能证明旧慢请求根因已解决。\n- 中国区现有解析入口累计{cncounts}，相对上一份供给快照增量{cnnew}；2条502仍是已知维护记录。既有探针已恢复且本轮无再次失败。\n- US探针147/147健康，CN146/147健康，CN唯一失败是已说明的06:55维护轮次。地区元数据不匹配均0。\n- 两区R135固定进程和源码身份回读一致；07:05:17—07:18:20模型保留诊断无新failureEvents，没有额外发测试请求。\n- Direct计数不变，仍为7816个200、1个本地校验400、12个无响应断开；本次没有新的Direct流量。已知独立版本变更保持原证据。\n- QuickRead与克隆均无本轮新增生成样本或固定错误；进程健康。历史QuickRead US2/CN1断开、完整HTTP交付覆盖不足仍未关闭。\n\n中国区发布空窗、旧超时与慢探针分项归因仍待解决。探针及HTTP200不代表用户完整听完；本窗也没有日语专属真实请求覆盖证明。原固定截止仍为2026-09-07 18:37:52 UTC，不延长、不清除历史、不把混合版本观察写成R135的24小时验证。\n\n完整字段与来源见 [后端评估](backend-review.json)、[Global/US精确关联](vercel-proxy-join.json)、[两区供给](backend-supply/cn-backend-supply.json)。\n'''
with (OUT/'README.md').open('x') as f:f.write(md)
statefile=BASE/'monitoring/notification-state.json';state=read(statefile)
state.update({'latestSnapshotDirectory':str(OUT),'latestObservationReview':str(OUT/'backend-review.json'),'latestBackendObservationReview':str(OUT/'backend-review.json'),'latestProxyWindowPath':str(OUT/'proxy-window.json'),'latestProxyWindowEndUTC':p['window']['endUTCExclusive'],'latestVercelCore5xxCount':1,'latestDirect5xxCount':0,'latestDirectNoResponseCount':12,'latestDirectHttp400Count':1,'latestBackendVerdict':review['backendVerdict'],'latestBackendSupplySnapshotPaths':[str(OUT/'backend-supply'/f'{r}-backend-supply.json') for r in ['us','cn','us-gpu']],'latestBackendHeartbeatDecision':{'decision':'DONT_NOTIFY','reason':review['reason'],'reviewedAtUTC':review['reviewedAtUTC']},'latestBackendPerformanceObservation':{'observedThroughUTC':p['window']['endUTCExclusive'],'successfulRequestFinishP95Ms':metrics['p95Ms'],'proxyHeadersP95Ms':p['stageTimingMilliseconds']['upstream_headers.elapsedMs']['p95'],'sustainedGlobalRecoveryEstablished':False,'cnServerSlowStageEstablished':False},'latestBackendServiceVerdicts':[{'region':'global','service':'kokoro_tts','backendVerdict':'本轮供给符合预期；全窗历史异常保留','evidence':'204个完整200，身份与匿名关联通过'},{'region':'cn','service':'kokoro_tts','backendVerdict':'本轮供给符合预期；历史维护故障保留','evidence':'无新增502，探针恢复持续，R135身份一致'}]+[{'region':r,'service':'quickread','backendVerdict':'证据不足','evidence':'无新增固定错误或生成样本；完整交付覆盖不足'} for r in ['global','cn']]+[{'region':r,'service':'clone_tts','backendVerdict':'证据不足','evidence':'健康检查正常，无本轮新增生成样本'} for r in ['global','cn']]})
statefile.write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'decision':review['decision'],'newActionableChange':False,'globalRequests':204,'globalP95Ms':metrics['p95Ms'],'cnDelta':cnnew,'review':str(OUT/'backend-review.json')},ensure_ascii=False))
