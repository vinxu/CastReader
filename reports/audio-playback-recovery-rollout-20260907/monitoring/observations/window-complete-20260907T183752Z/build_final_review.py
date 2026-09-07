"""Close the fixed observation window without changing production or expectations."""
import collections
import hashlib
import json
import math
import shutil
from datetime import datetime, timezone
from pathlib import Path

O = Path(__file__).resolve().parent
M = O.parent.parent
B = M.parent
P = O.parent / '20260907T1726Z'
read = lambda p: json.loads(p.read_text())
utc = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))

def write(name, value):
    with (O / name).open('x') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write('\n')

a = read(O / 'latest-acceptance.json')
p = read(O / 'proxy-window.json')
v = read(O / 'vercel-preset.json')
j = read(O / 'vercel-proxy-join.json')
d = read(O / 'direct-version-requests.json')
dc = read(O / 'direct-complete-cumulative-final.json')
cn = read(O / 'cn-rotated-ingress.json')
old = read(P / 'backend-review.json')
state_before = read(O / 'before-acceptance-state.json')
notify_before = read(O / 'before-notification-state.json')
end = utc(state_before['window']['endUtc'])
start = utc(state_before['window']['startUtc'])
s = {r: read(O / 'backend-supply' / f'{r}-backend-supply.json')['result'] for r in ['us', 'cn', 'us-gpu']}
ps = {r: read(P / 'backend-supply' / f'{r}-backend-supply.json')['result'] for r in s}
models = {r: read(O / f'{r}-r135-cumulative-diagnostics.json') for r in ['us', 'cn']}
recent_models = {r: read(O / f'{r}-r135-model.json') for r in ['us', 'cn']}
creation = read(O / 'clone-fixed-creation-events.json')
finish = [e for q in v['requests'] for e in q['events'] if e['event'] == 'request_finished']
times = sorted(e['elapsedMs'] for e in finish if e.get('status') == 200)
perf = {'samples': len(times), 'p95Ms': times[math.ceil(len(times) * .95) - 1], 'maxMs': max(times), 'cohort': 'Provider requests whose start is inside the final incremental window; one response spans the fixed cutoff.'}
index = collections.defaultdict(list)
for q in p['anonymousRequests']:
    index[q['requestKey']].append(q)
dj = []
for q in d['requests']:
    hits = index[q['requestKey']]
    dj.append({'direct': q, 'matchingProxyGroups': hits, 'ambiguous': len(hits) > 1 or any(h['ambiguousRepeatedRequestKey'] for h in hits)})
gk = {q['requestKey'] for q in j['attempts'] if q['matchCount'] == 1 and not q['ambiguous']}
dk = {q['direct']['requestKey'] for q in dj if len(q['matchingProxyGroups']) == 1 and not q['ambiguous']}
remaining = [q for q in p['anonymousRequests'] if q['requestKey'] not in gk | dk]
no_proxy = [q['direct'] for q in dj if not q['matchingProxyGroups']]
boundary = [q for q in p['anonymousRequests'] if not q['outcomes']]
boundary_keys = {q['requestKey'] for q in boundary}
reverse = {'schema': 'castreader.backend-reverse-attribution.v1', 'readOnly': True, 'global': j['counts'], 'direct': {'requests': len(dj), 'exactMatched': len(dk), 'records': dj}, 'remainingUnattributedProxyGroups': remaining, 'directWithoutProxyGroup': no_proxy, 'cutoffCensoredProxyGroups': boundary, 'limitations': ['Zero-attempt Direct200 records are consistent with the reviewed local punctuation-response branch; no input or noop header was read to prove each branch.', 'One Global request starts before cutoff, remains unfinished in the half-open proxy window, and has a completed provider request record collected later. It is censored at cutoff, not a backend timeout.', 'HTTP200 is not complete playback; request keys alone do not prove user identity or intent.']}
write('reverse-attribution.json', reverse)
write('cutoff-boundary.json', {'readOnly': True, 'fixedCutoffUTC': end.isoformat(), 'proxyGroupsAtCutoff': boundary, 'providerRequestCohortRecords': [q for q in v['requests'] if set(q['applicationRequestKeys']) & boundary_keys], 'diagnosis': 'Boundary truncation: the proxy request began0.516s before the fixed cutoff. Provider-level completed record is supplementary evidence and does not extend the fixed proxy window.', 'newBackendFailureEstablished': False})
new_keys = {q['requestKey'] for q in d['requests'] if q['status'] is None}
new_disconnects = [q for q in dc['aggregate']['nonHttpRequests'] if q['key'] in new_keys]
disconnect = {'schema': 'castreader.backend-disconnection-followup.v1', 'readOnly': True, 'window': p['window'], 'newNoResponse': len(new_disconnects), 'cumulativeNoResponse': dc['aggregate']['statusCounts']['no_response'], 'records': [{'direct': q, 'matchingProxyGroups': index[q['key']]} for q in new_disconnects], 'initialDisconnectCauseKnown': False, 'incidentClosed': False, 'previousIncrementalNoResponse': 7, 'previousWindowSeconds': (utc(old['incrementalWindow']['endUTCExclusive']) - utc(old['incrementalWindow']['startUTC'])).total_seconds(), 'currentWindowSeconds': (end - utc(p['window']['startUTC'])).total_seconds(), 'globalP95Ms': perf['p95Ms'], 'proxyHeadersP95Ms': p['stageTimingMilliseconds']['upstream_headers.elapsedMs']['p95'], 'assessment': 'Fourteen additional downstream_closed/upstream_headers records match fourteen proxy cancellations. No new HTTP5xx or terminal model failure is established. Different window durations and traffic mixes preclude treating14 versus7 as a controlled regression measurement.'}
write('disconnect-followup.json', disconnect)

diag_rows = []
for row in read(O / 'us-frontend-recovery-detail.json')['rows']:
    hits = [q for q in p['anonymousRequests'] if row['requestKey'] in q['flightKeys']]
    diag_rows.append({'diagnostic': row, 'matchingProxyGroups': hits, 'allGroupsComplete': bool(hits) and all(q['outcomes'] == {'complete': 1} and not q['ambiguousRepeatedRequestKey'] for q in hits)})
write('frontend-recovery-attribution.json', {'readOnly': True, 'productionModified': False, 'rows': diag_rows, 'allDiagnosticsMatchedComplete': all(q['allGroupsComplete'] for q in diag_rows), 'limitations': ['Only the final incremental recovery diagnostics are individually joined here; cumulative diagnostics are not a complete HTTP outcome ledger.']})

identity = {'usQuickreadUnchanged': s['us']['quickreadExpectedProcess'] == ps['us']['quickreadExpectedProcess'], 'cnQuickreadUnchanged': s['cn']['quickreadProcess'] == ps['cn']['quickreadProcess'], 'cnServiceUnitsUnchanged': s['cn']['units'] == ps['cn']['units'], 'usCloneProcessUnchanged': s['us-gpu']['expectedCloneProcess'] == ps['us-gpu']['expectedCloneProcess'], 'usNariProcessUnchanged': s['us-gpu']['expectedNariProcess'] == ps['us-gpu']['expectedNariProcess'], 'directSourceUnchanged': dc['source'] == read(P / 'direct-complete-cumulative.json')['source'], 'directProcessUnchanged': dc['systemd'] == read(P / 'direct-complete-cumulative.json')['systemd'], 'globalDeploymentUnchanged': a['sources']['global_capabilities']['identity'] == read(P / 'latest-acceptance.json')['sources']['global_capabilities']['identity']}
probes = {}
quickread = {}
for r in ['us', 'cn']:
    m = a['sources']['monitor_' + r]
    g = m['aggregate']
    prev = old['existingProbes'][r]
    probes[r] = {'cycles': g['cycles'], 'statusCounts': g['statusCounts'], 'newHealthyCycles': g['statusCounts'].get('healthy', 0) - prev['statusCounts'].get('healthy', 0), 'newSupplyFailedCycles': g['statusCounts'].get('supply_failed', 0) - prev['statusCounts'].get('supply_failed', 0), 'regionMismatchCycles': g['regionMismatchCycles'], 'lastCompletedUTC': m['source']['lastSelectedObservedAt']}
    logs = s[r]['quickreadLogs']
    jobs = s[r]['quickreadJobs']
    quickread[r] = {'incrementalFixedTagCounts': logs['incrementalFixedTagCounts'], 'knownFixedErrorRecords': logs['fixedErrorRecords'], 'newFixedErrorRecords': [e for e in logs['fixedErrorRecords'] if e not in old['quickread'][r]['knownFixedErrorRecords']], 'readyFileOutcomes': {'modifiedFiles': jobs['filesModifiedInWindow'], 'allBlocks': jobs['allServerBlocksGenerated'], 'partialReady': jobs['partialButReady']}, 'outcomeCohort': jobs['outcomeCohort'], 'backendVerdict': '证据不足：有服务端生成结果，完整HTTP与音频交付未贯通；固定断开原因未闭环'}

assert (end - start).total_seconds() == 86400
assert utc(a['window']['collectedThroughExclusive']) == end and utc(dc['query']['endExclusive']) == end
assert dc['coverage']['complete'] and not dc['aggregate']['nonHttpRequestsTruncated']
assert dc['aggregate']['statusCounts'] == {'200': 21252, '400': 1, 'no_response': 74}
assert dc['aggregate']['duplicateRequestLogBlocks'] == 1
assert p['identityAndCoverageVerified'] and not p['failureEvents'] and v['coverage']['completeForReturnedRequestCohort']
assert len(finish) == len(times) == 635 and all(e['attempt'] == 1 for e in finish)
assert a['sources']['vercel']['aggregate']['core5xxRecords'] == 1
assert cn['incrementalStatuses'] == {'200': 161} and cn['cumulativeStatuses'] == {'200': 3539, '499': 2, '502': 2}
assert len(new_disconnects) == 14 and all(q['abortSource'] == 'downstream_closed' and q['abortStage'] == 'upstream_headers' for q in new_disconnects)
assert all(len(index[q['key']]) == 1 and index[q['key']][0]['outcomes'] == {'cancelled': 1} for q in new_disconnects)
assert all(identity.values()) and all(m['identity']['verified'] and not m['failureEvents'] and m['unclassifiedEvents'] == 0 for m in models.values())
assert not remaining and len(no_proxy) == 17 and all(q['status'] == 200 and q['attempts'] == 0 for q in no_proxy)
assert len(boundary) == 1 and boundary[0]['requestKey'] in gk
assert len(diag_rows) == 9 and all(q['allGroupsComplete'] for q in diag_rows)
assert not any(q['newFixedErrorRecords'] for q in quickread.values())
assert sum(creation['fixedCreationEventCounts'].values()) == s['us-gpu']['cloneStructuredLog']['unclassifiedEventCounts']['otherStructuredEvents']

versions = {
    'globalGateway': {'version': '1f9a483c7f75c9acee30129c984ea9bc622c5ea1', 'deployment': 'dpl_EYb2UAVcLJvk7qaYchgmPhYoHYC5', 'wholeFixedWindowIdentityExpected': True, 'core5xx': 1},
    'directGateway': {'frozenOriginalVersion': '1213fcd3f9f616e92e9fd3a8f1e817b5095986c5', 'observedIndependentVersion': '7d0a22ce8169fb6b6fe8aa3e80a08ae3804ee161', 'firstNewTrafficAtUTC': '2026-09-07T03:21:22.184392Z', 'actualSource': dc['source'], 'originalFrozenExpectationRetained': True, 'singleVersion24hCertified': False},
    'globalKokoro': {'initialWindowVersion': 'R134', 'currentVersion': 'R135', 'sourceCommit': '8d4e18bd82c75e0c13c94cc0074da62f9c0f9a5e', 'activeFromUTC': '2026-09-07T06:37:55.624577Z', 'activeUntilFixedEndSeconds': (end - utc('2026-09-07T06:37:55.624577Z')).total_seconds(), 'independentlyVerifiedFromUTC': models['us']['window']['startUTC'], 'diagnosticObservationSeconds': (end - utc(models['us']['window']['startUTC'])).total_seconds(), 'singleVersion24hCertified': False},
    'cnKokoro': {'initialWindowVersion': 'r131b', 'currentVersion': 'R135', 'sourceCommit': '8d4e18bd82c75e0c13c94cc0074da62f9c0f9a5e', 'primaryAudioValidatedUTC': '2026-09-07T06:55:56.613912Z', 'validatedUntilFixedEndSeconds': (end - utc('2026-09-07T06:55:56.613912Z')).total_seconds(), 'independentlyVerifiedFromUTC': models['cn']['window']['startUTC'], 'diagnosticObservationSeconds': (end - utc(models['cn']['window']['startUTC'])).total_seconds(), 'singleVersion24hCertified': False},
    'quickreadAndClone': {'latestReadbackComparedToPrevious': identity, 'newReleaseByThisObservation': False, 'readbackAfterDeadlineIsNotProofOfEveryInstantDuringWindow': True}}
write('version-periods.json', versions)

now = datetime.now(timezone.utc).isoformat()
review = {'schema': 'castreader.backend-window-final-review.v1', 'automationId': '24', 'readOnly': True, 'productionModified': False, 'synthesisStarted': False, 'rawContentExported': False, 'reviewedAtUTC': now, 'snapshotDirectory': str(O), 'fixedWindow': {'startUTC': start.isoformat(), 'endUTCExclusive': end.isoformat(), 'seconds': 86400, 'complete': True, 'extendedOrRestarted': False, 'mixedVersions': True, 'singleVersion24hCertified': False}, 'incrementalWindow': p['window'], 'backendVerdict': '存在异常：固定24小时观察完成，但不能验收为全链路稳定；R135已修复已定位前处理问题，断开、发布空窗及完整交付证据缺口仍未关闭', 'decision': 'NOTIFY', 'reason': '固定观察窗口到期，提交分地区及版本的后端结论并停止本轮自动观察。',
    'globalTts': {'requests': len(v['requests']), 'finished200InReturnedStartCohort': len(times), 'proxyCompleteBeforeCutoff': j['counts']['matchedProxyComplete'], 'cutoffCensoredRequests': len(boundary), 'allAttempt1': True, 'globalElapsedMs': perf, 'proxyCounts': p['counts'], 'coalescing': p['coalescing'], 'proxyTimingsMs': p['stageTimingMilliseconds'], 'globalJoin': j['counts'], 'cumulativeCore5xx': 1, 'historicalJapanese500Preserved': True, 'newCore5xx': 0},
    'direct': {'cumulativeStatusCounts': dc['aggregate']['statusCounts'], 'incrementalExactWindow': dict(collections.Counter(str(q['status']) for q in d['requests'])), 'newDownstreamDisconnects': new_disconnects, 'source': dc['source'], 'cumulativeSource': str(O / 'direct-complete-cumulative-final.json'), 'cumulativeCoverage': dc['coverage'], 'journalRows': dc['aggregate']['journalRowsRead'], 'cumulativeDuplicateRequestLogBlocks': 1, 'historicalDuplicateKeyOccurrenceSupplement': str(P.parent / '20260907T1625Z/direct-terminal-occurrences.json'), 'countsUseOriginalKeyDedupSemantics': True, 'knownFrozenVersionMismatchPreserved': True},
    'cnTts': {'parsedCumulativeStatuses': cn['cumulativeStatuses'], 'incrementalStatuses': cn['incrementalStatuses'], 'rotationCoverageSupplement': str(O / 'cn-rotated-ingress.json'), 'unparsedFileLines': sum(q['unparsedLines'] for q in cn['sources']), 'knownMaintenance502Count': 2, 'new502': 0, 'publicationAvailabilityGapClosed': False},
    'models': {r: {'release': m['release'], 'identityVerified': m['identity']['verified'], 'diagnosticWindow': m['window'], 'fixedStageCounts': m['fixedStageCounts'], 'newFinalIntervalFixedStageCounts': recent_models[r]['fixedStageCounts'], 'failureEvents': m['failureEvents'], 'remainingUnclassifiedEvents': m['unclassifiedEvents'], 'successLedgerComplete': False} for r, m in models.items()}, 'existingProbes': probes, 'quickread': quickread,
    'clone': {'us': {'fixedWindowStructuredEvents': s['us-gpu']['cloneStructuredLog']['windowEvents'], 'incrementalEvents': s['us-gpu']['cloneStructuredLog']['incrementalEvents'], 'startupHealthCountersReadAfterCutoff': s['us-gpu']['cloneHealthAfterCutoff'], 'fixedCreationEventSupplement': creation, 'backendVerdict': '已观测生成供给符合预期；完整HTTP音频交付证据不足'}, 'cn': {'startupHealthCountersReadAfterCutoff': s['cn']['cloneHealthAfterCutoff'], 'backendVerdict': '证据不足：无本窗新增生成样本，不能由启动以来4次成功推算本窗成功率'}},
    'runtimeComparisonsToPreviousSnapshot': identity, 'proxyAttribution': {'globalExactMatched': len(gk), 'directExactMatched': len(dk), 'remainingUnattributedGroups': len(remaining), 'source': str(O / 'reverse-attribution.json')}, 'versionPeriods': versions,
    'preservedIssues': ['当前窗口Global1条日语500，已修复但历史不清零；同请求3次上游/6次模型异常不能算6名用户', '当前窗口Direct74次downstream_closed，无HTTP响应，最初原因与交付结果仍未知', '当前窗口CN2条维护502、2条499及发布备用入口预检缺陷', 'QuickRead US2/CN4固定断开及完整交付日志缺口', '旧窗口Global4条504、Direct4条旧分类504和维护502、模型3条400及其归因限制', '1条旧克隆参考音色创建拒绝，不等同已有克隆音色TTS失败', 'Direct独立版本更换、代理切换区间覆盖不足，不能认证单一版本24小时'],
    'acceptanceGaps': ['国际区连接断开的最初原因尚未确证，最新71分钟仍新增14次', '中国区发布尚无经完整入口及权限预检验证的无间断切换', '两区解读与克隆缺少生成到完整HTTP/音频交付的统一记录，CN克隆缺新样本', '探针地区元数据无不匹配仅证明已覆盖路径，不能认证项目所有历史入口无跨境', 'R135只有约12小时生效时间及11小时38分独立身份后的诊断观察，未满24小时'],
    'nextIterationPriorities': ['按匿名请求键补齐Direct、代理与上游在取消前的阶段耗时及交付终止原因，区分请求关闭与真正上游超时；不把未知结果写成功', '先验证中国区同区备用完整入口和已有转发权限，再实现可预检与排空的发布切换', '补QuickRead与克隆完整输出、余文结束、HTTP交付和同区路由的最小固定字段日志；保持音频优先，时间戳降级不设播放门槛'],
    'limitations': ['All collection is read-only and uses existing logs/probes; no new synthesis or production modifications.', 'Final collection occurred after the fixed deadline; event filters stop at the original deadline. Post-cutoff process/health readbacks remain separately labelled.', 'HTTP200, ready files and GPU job completion are different stages and do not prove complete user playback.', 'QuickRead outcomes are retained files whose last modification is inside the window, not all HTTP requests; files modified after cutoff cannot reconstruct earlier states.', 'The original250k collector and the final3h truncated shard are preserved. Final cumulative Direct evidence uses10 adjacent bounded shards reassembled before console parsing; a timed-out24-shard read is recorded as a collector failure, not production outage.', 'Cumulative Direct counts deduplicate keys; one previously documented repeated key also has a later200 occurrence retained separately.', 'Provider pagination completion does not certify log ingestion completeness.', 'Existing probe success ratios are sample ratios, not time-based uptime.', 'Original automaticVerdict includes client events and is retained only as an attachment, not the backend acceptance conclusion.'],
    'sources': [{'path': str(f), 'sha256': hashlib.sha256(f.read_bytes()).hexdigest()} for f in sorted(O.rglob('*.json'))]}
write('backend-final-review.json', review)
write('backend-review.json', review)
(O / 'README.md').write_text('''# 核心音频后端：固定24小时观察结论

**观察已完成，但不能验收为全链路稳定。** 已定位的日语数字前处理问题已在两区修复，R135诊断中未见新的模型终止错误；国际区连接断开、中国区发布空窗，以及解读和克隆完整交付的证据缺口仍未关闭。

固定窗口为2026-09-06 18:37:52.522573至2026-09-07 18:37:52.522573 UTC，即北京时间9月7日02:37至9月8日02:37。没有延期或重启计时。最后一次采集实际在截止之后进行，所有事件统计仍过滤到原截止；当前健康和进程回读单独标注，不倒推为截止时刻状态。

| 后端范围 | 固定窗口证据 | 结论 |
|---|---|---|
| Global TTS网关 | 核心5xx累计1条，为05:35的日语前处理500；同一请求3次上游、6次内部异常。最后一个71分钟窗口635个开始于窗口内的请求记录均200，其中634个代理完成发生在截止前，1个跨截止边界 | 已定位缺陷修复；全窗历史失败保留 |
| 国际区Direct TTS | 按既有匿名键口径21252个200、1个本地无效请求400、74次无HTTP响应、0个5xx。最后71分钟新增3720个200和14次断开，14次均在等待上游响应头阶段关闭，并精确对应代理取消 | 连接断开原因未闭环，不能算成功或模型超时 |
| 中国区TTS | 合并轮转日志后3539个200、2个499、2个维护502；最后71分钟新增161个200，无新增499/502 | 当前供给恢复；发布过程中断问题仍存在 |
| 国际区解读 | 固定放行223条；保留的223个ready状态文件中186个生成全部服务端块、37个部分ready；固定断开2条 | 生成有证据，完整HTTP及音频交付不足 |
| 中国区解读 | 固定放行33条；29个ready文件，24个全部块、5个部分ready；固定断开4条 | 断开原因、完整交付仍证据不足 |
| 国际区克隆 | 固定窗口GPU完成493次captioned-speech、3次speech、4次参考音色处理；未见新增固定生成失败。最后窗口新增1次speech和1次参考音色处理完成 | 已观测生成供给正常；完整交付仍缺证据 |
| 中国区克隆 | 回读进程健康、启动以来4次完成；本窗没有新增可用于验证的生成样本 | 证据不足，不能宣称100%成功 |

这些是日志、请求或任务数，不是用户数，也不是完整播放次数。Direct累计保留原按键去重口径；历史1个重复键还存在后续200记录，原始两次终止证据单列，没有抹去断开。

最后窗口Global请求耗时P95为1508ms，前两轮为2680ms、1229ms；代理响应头P95为1536.702ms。耗时已从较慢一轮回落，但窗口时长及流量构成不同，尚不能确认持续恢复或最初断开原因。最后17个Direct200请求上游尝试为0，与本地标点静音响应分支一致；没有读取正文来逐条确认分支。其余Global635个、Direct3717个请求均无歧义关联，无未归属代理组；1个Global请求在截止前0.516秒进入代理，截止时尚未完成，单列边界而非超时。

两区既有连续音频探针各277轮：US277/277健康，CN276/277健康，CN唯一失败仍为发布维护时那一轮。已覆盖探针的地区元数据不匹配为0；这些结果不构成项目全部历史入口与存储链路无跨境的证明，也不是按时间计算的可用率。

**按版本看，R135没有观察满24小时。** Global应用保持1f9a483c；Direct在03:21被独立发布为7d0a22ce，原冻结1213fcd3期望及不匹配保留。US模型由R134切至R135，06:37:55起生效，到截止约12小时；CN由r131b更新R135，06:55:56主入口音频验证后到截止约11小时42分。两区独立身份确认后的诊断观察均约11小时38分。

在上述R135诊断窗口内，US记录76次英文恢复、10次可选前处理降级、2次日语数字恢复、23次纯分隔段跳过和69次保留完整PCM；CN分别有2次英文恢复、3次可选前处理降级、7次分隔段跳过和3次保留完整PCM。未见固定模型终止错误，补充分类后无剩余未知阶段；这仍不是逐个请求的完整音频成功账本。最后9条英文恢复均能对应完整代理响应。时间戳与裁剪降级没有因此被计作有效音频失败。

克隆日志中原未分类的15条事件已匹配为5次参考质量通过、5次语义延后、4次降噪选择和1次旧参考音色拒绝；最后新增的3条均是成功准备路径。历史参考录音拒绝不等同已有音色朗读失败。没有读取录音或正文。

仍需推进的后端问题：国际区取消前的逐阶段归因与完整交付记录；中国区同区备用完整入口、权限预检和无间断发布；QuickRead及克隆生成结果到HTTP音频交付的统一可验证记录。时间戳对齐继续服从音频供给优先，不能作为新的停止播放条件。本轮只做观察与归档，没有部署、重启或修改生产。

[完整后端结论](backend-final-review.json) · [分版本时段](version-periods.json) · [最新14次断开](disconnect-followup.json) · [完整Direct累计](direct-complete-cumulative-final.json) · [截止边界](cutoff-boundary.json) · [归档索引](archive.json)。
''')

assert (M / 'acceptance-state.json').read_bytes() == (O / 'before-acceptance-state.json').read_bytes()
assert (M / 'notification-state.json').read_bytes() == (O / 'before-notification-state.json').read_bytes()
state_after = dict(state_before)
state_after['cutoverState'] = 'window_complete'
assert {k: v for k, v in state_after.items() if k != 'cutoverState'} == {k: v for k, v in state_before.items() if k != 'cutoverState'}
(M / 'acceptance-state.json').write_text(json.dumps(state_after, ensure_ascii=False, indent=2) + '\n')
write('final-acceptance-state.json', state_after)
notify = dict(notify_before)
notify.update({'latestSnapshotDirectory': str(O), 'latestObservationReview': str(O / 'backend-final-review.json'), 'latestBackendObservationReview': str(O / 'backend-final-review.json'), 'latestCollectionAttemptDirectory': str(O), 'latestCollectionAttemptReview': str(O / 'backend-final-review.json'), 'latestProxyWindowPath': str(O / 'proxy-window.json'), 'latestProxyWindowEndUTC': end.isoformat(), 'latestVercelCore5xxCount': 1, 'latestDirect5xxCount': 0, 'latestDirectNoResponseCount': 74, 'latestDirectHttp400Count': 1, 'latestBackendVerdict': review['backendVerdict'], 'latestBackendPerformanceObservation': {'observedThroughUTC': end.isoformat(), 'successfulRequestFinishP95Ms': perf['p95Ms'], 'proxyHeadersP95Ms': p['stageTimingMilliseconds']['upstream_headers.elapsedMs']['p95'], 'sustainedGlobalRecoveryEstablished': False}, 'latestBackendHeartbeatDecision': {'decision': 'NOTIFY', 'reason': review['reason'], 'reviewedAtUTC': now}, 'latestBackendSupplySnapshotPaths': [str(O / 'backend-supply' / f'{r}-backend-supply.json') for r in s], 'latestReverseProxyGlobalAttribution': review['proxyAttribution'], 'latestBackendDisconnectReview': str(O / 'disconnect-followup.json'), 'latestCompleteDirectSupplement': str(O / 'direct-complete-cumulative-final.json'), 'currentBackendCollectionStatus': 'window_complete', 'backendWindowComplete': True, 'backendWindowCompletedAtUTC': now, 'backendWindowFinalReviewPath': str(O / 'backend-final-review.json'), 'backendWindowArchivePath': str(O / 'archive.json'), 'stopFurtherFixedWindowCollection': True, 'recordedAtUtc': now, 'lastDecision': 'NOTIFY', 'lastDecisionReason': review['reason']})
notify['knownDirectNoResponseKeys'] = sorted(set(notify.get('knownDirectNoResponseKeys', [])) | {q['key'] for q in dc['aggregate']['nonHttpRequests']})
notify['knownProxyCancellationKeys'] = sorted(set(notify.get('knownProxyCancellationKeys', [])) | new_keys)
notify.setdefault('backendWindowCompletionNotifications', []).append({'windowEndUTC': end.isoformat(), 'reviewPath': str(O / 'backend-final-review.json'), 'atUTC': now})
notify['latestBackendServiceVerdicts'] = [{'region': 'global', 'service': 'kokoro_tts', 'backendVerdict': '已修复已定位前处理问题；Direct74次无响应原因未关闭，未通过全部稳定验收'}, {'region': 'cn', 'service': 'kokoro_tts', 'backendVerdict': '供给恢复，历史维护502及发布空窗未关闭'}] + [{'region': r, 'service': 'quickread', 'backendVerdict': quickread['us' if r == 'global' else r]['backendVerdict']} for r in ['global', 'cn']] + [{'region': r, 'service': 'clone_tts', 'backendVerdict': review['clone']['us' if r == 'global' else r]['backendVerdict']} for r in ['global', 'cn']]
notify['nextCollectionNotes'] = ['Fixed24h window completed at2026-09-07T18:37:52.522573UTC. Do not collect more events for this window or restart/extend it.', 'Original faults, version changes, classification limits, before/after state and observation evidence are archived. R135 did not have24h observation.', 'The final hourly Direct3h shard truncated at250k; use direct-complete-cumulative-final.json with10 complete adjacent shards. Keep both failed attempts as collector evidence.']
(M / 'notification-state.json').write_text(json.dumps(notify, ensure_ascii=False, indent=2) + '\n')
write('final-notification-state.json', notify)
automation_path = Path.home() / '.codex/automations/24/automation.toml'
shutil.copyfile(automation_path, O / 'automation-before.toml')
print(json.dumps({'windowComplete': True, 'backendVerdict': review['backendVerdict'], 'direct': dc['aggregate']['statusCounts'], 'global5xx': 1, 'cn': cn['cumulativeStatuses'], 'productionModified': False}, ensure_ascii=False))
