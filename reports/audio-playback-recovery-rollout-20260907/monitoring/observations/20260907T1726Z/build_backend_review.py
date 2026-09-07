"""Assemble this observation from immutable, sanitized backend evidence only."""
import collections
import hashlib
import json
import math
from datetime import datetime, timezone
from pathlib import Path

O = Path(__file__).resolve().parent
M = O.parent.parent
P = O.parent / '20260907T1625Z'
read = lambda f: json.loads(f.read_text())

def write(name, value):
    with (O / name).open('x') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write('\n')

a = read(O / 'latest-acceptance.json')
p = read(O / 'proxy-window.json')
v = read(O / 'vercel-preset.json')
j = read(O / 'vercel-proxy-join.json')
d = read(O / 'direct-version-requests.json')
dc = read(O / 'direct-complete-cumulative.json')
occ = read(O / 'direct-terminal-occurrences.json')
cr = read(O / 'cn-rotated-ingress.json')
series = read(O / 'cn-probe-timing-series.json')
old = read(P / 'backend-review.json')
s = {r: read(O / 'backend-supply' / f'{r}-backend-supply.json')['result'] for r in ['us', 'cn', 'us-gpu']}
ps = {r: read(P / 'backend-supply' / f'{r}-backend-supply.json')['result'] for r in s}
models = {r: read(O / f'{r}-r135-model.json') for r in ['us', 'cn']}
finish = [e for q in v['requests'] for e in q['events'] if e['event'] == 'request_finished']
times = sorted(e['elapsedMs'] for e in finish if e.get('status') == 200)
perf = {'samples': len(times), 'p95Ms': times[math.ceil(len(times) * .95) - 1], 'maxMs': max(times)}
index = collections.defaultdict(list)
for q in p['anonymousRequests']:
    index[q['requestKey']].append(q)
dj = []
for q in d['requests']:
    hits = index[q['requestKey']]
    dj.append({'requestKey': q['requestKey'], 'directStatus': q['status'], 'directElapsedMs': q['elapsedMs'], 'directAttempts': q['attempts'], 'matchCount': len(hits), 'ambiguous': len(hits) > 1 or any(h['ambiguousRepeatedRequestKey'] for h in hits), 'proxyOutcomes': [h['outcomes'] for h in hits]})
gk = {q['requestKey'] for q in j['attempts'] if q['matchCount'] == 1 and not q['ambiguous']}
dk = {q['requestKey'] for q in dj if q['matchCount'] == 1 and not q['ambiguous']}
remaining = [q for q in p['anonymousRequests'] if q['requestKey'] not in gk | dk]
no_proxy = [q for q in dj if q['matchCount'] == 0]
reverse = {'schema': 'castreader.backend-reverse-attribution.v1', 'readOnly': True, 'global': j['counts'], 'direct': {'requests': len(dj), 'exactMatched': len(dk), 'records': dj}, 'remainingUnattributedProxyGroups': remaining, 'directWithoutProxyGroup': no_proxy, 'cancelledProxyGroups': [q for q in p['anonymousRequests'] if q['outcomes'].get('cancelled')], 'limitations': ['No-proxy Direct records all have attempts=0 and HTTP200; reviewed source has a local punctuation-only silence response. This supports a local-response inference; request bodies and noop response headers were not read.', 'HTTP200 and proxy complete do not prove full user playback.', 'Keys alone do not establish region, caller identity or user intent.']}
write('reverse-attribution.json', reverse)

diag = read(O / 'us-frontend-recovery-detail.json')['rows'] + read(O / 'us-optional-diagnostic-detail.json')['rows']
diag_rows = []
for row in diag:
    hits = [q for q in p['anonymousRequests'] if row['requestKey'] in q['flightKeys']]
    diag_rows.append({'diagnostic': row, 'matchingProxyGroups': hits, 'allGroupsComplete': bool(hits) and all(q['outcomes'] == {'complete': 1} and not q['ambiguousRepeatedRequestKey'] for q in hits)})
frontend = {'schema': 'castreader.optional-frontend-window-attribution.v1', 'readOnly': True, 'productionModified': False, 'us': {'rows': diag_rows, 'allDiagnosticsMatchedComplete': all(q['allGroupsComplete'] for q in diag_rows)}, 'originalUnclassifiedDiagnostic': {'count': models['us']['unclassifiedEvents'], 'fixedStageMatched': 'trim_preserved_complete_pcm', 'sourceMeaning': 'Optional trimming would leave invalid word cues; source retains the complete original PCM. Matching proxy finished complete.', 'notTerminalAudioFailure': True}, 'limitations': ['Fixed recovery diagnostics are not a complete synthesis success ledger.', 'Proxy completion does not certify subjective quality or client playback.']}
write('frontend-recovery-attribution.json', frontend)

new_disconnects = [q for q in dc['aggregate']['nonHttpRequests'] if q['key'] in {r['requestKey'] for r in d['requests'] if r['status'] is None}]
disconnect = {'schema': 'castreader.backend-disconnection-followup.v1', 'readOnly': True, 'window': p['window'], 'previousNewNoResponse': len(old['direct']['newDownstreamDisconnects']), 'newNoResponse': len(new_disconnects), 'cumulativeNoResponse': dc['aggregate']['statusCounts']['no_response'], 'records': [{'direct': q, 'matchingProxyGroups': index[q['key']]} for q in new_disconnects], 'globalP95Ms': perf['p95Ms'], 'priorGlobalP95Ms': old['globalTts']['globalElapsedMs']['p95Ms'], 'proxyHeadersP95Ms': p['stageTimingMilliseconds']['upstream_headers.elapsedMs']['p95'], 'priorProxyHeadersP95Ms': old['globalTts']['proxyTimingsMs']['upstream_headers.elapsedMs']['p95'], 'initialDisconnectCauseKnown': False, 'sustainedRecoveryEstablished': False, 'assessment': 'Hourly latency and disconnection count fell, but the seven no-response outcomes remain unknown. Six match proxy cancellation; one proxy completed while Direct recorded a downstream disconnect before sending response headers. Completion at an upstream hop cannot turn a downstream no-response into success.', 'limitations': ['Adjacent windows have different traffic composition and slightly different durations.', 'downstream_closed does not prove user cancellation, a model timeout or the initial transport failure.']}
write('disconnect-followup.json', disconnect)

identities = {'usQuickreadUnchanged': s['us']['quickreadExpectedProcess'] == ps['us']['quickreadExpectedProcess'], 'cnQuickreadUnchanged': s['cn']['quickreadProcess'] == ps['cn']['quickreadProcess'], 'cnServiceUnitsUnchanged': s['cn']['units'] == ps['cn']['units'], 'usCloneProcessUnchanged': s['us-gpu']['expectedCloneProcess'] == ps['us-gpu']['expectedCloneProcess'], 'usNariProcessUnchanged': s['us-gpu']['expectedNariProcess'] == ps['us-gpu']['expectedNariProcess'], 'directSourceUnchanged': dc['source'] == read(P / 'direct-complete-cumulative.json')['source'], 'directProcessUnchanged': dc['systemd'] == read(P / 'direct-complete-cumulative.json')['systemd'], 'globalDeploymentUnchanged': a['sources']['global_capabilities']['identity'] == read(P / 'latest-acceptance.json')['sources']['global_capabilities']['identity']}
probes = {}
for r in ['us', 'cn']:
    m = a['sources']['monitor_' + r]
    g = m['aggregate']
    prev = old['existingProbes'][r]
    probes[r] = {'cycles': g['cycles'], 'statusCounts': g['statusCounts'], 'newHealthyCycles': g['statusCounts'].get('healthy', 0) - prev['statusCounts'].get('healthy', 0), 'newSupplyFailedCycles': g['statusCounts'].get('supply_failed', 0) - prev['statusCounts'].get('supply_failed', 0), 'regionMismatchCycles': g['regionMismatchCycles'], 'lastCompletedUTC': m['source']['lastSelectedObservedAt'], 'currentConsecutiveFailures': g['supplyFailureSequence']['currentConsecutiveCycles']}
quickread = {}
for r in ['us', 'cn']:
    logs = s[r]['quickreadLogs']
    jobs = s[r]['quickreadJobs']
    new_errors = [e for e in logs['fixedErrorRecords'] if e not in old['quickread'][r]['knownFixedErrorRecords']]
    quickread[r] = {'incrementalFixedTagCounts': logs['incrementalFixedTagCounts'], 'knownFixedErrorRecords': logs['fixedErrorRecords'], 'newFixedErrorRecords': new_errors, 'readyFileOutcomes': {'modifiedFiles': jobs['filesModifiedInWindow'], 'allBlocks': jobs['allServerBlocksGenerated'], 'partialReady': jobs['partialButReady']}, 'backendVerdict': '新增13个ready文件，无新固定错误；完整HTTP交付仍缺证据' if r == 'us' else '无新增放行、ready或固定错误，历史ready29；完整HTTP交付证据不足'}
assert all(identities.values()) and all(m['identity']['verified'] and not m['failureEvents'] for m in models.values())
assert p['identityAndCoverageVerified'] and not p['failureEvents'] and v['coverage']['completeForReturnedRequestCohort'] and dc['coverage']['complete']
assert len(finish) == len(times) == 961 and all(e['attempt'] == 1 for e in finish)
assert a['sources']['vercel']['aggregate']['core5xxRecords'] == 1
assert dc['aggregate']['statusCounts'] == {'200': 17532, '400': 1, 'no_response': 60}
assert occ['statusCountsByOccurrence'] == {'200': 2547, 'None': 7}
assert cr['incrementalStatuses'] == {'200': 171} and cr['cumulativeStatuses'] == {'200': 3378, '499': 2, '502': 2}
assert len(remaining) == 0 and len(no_proxy) == 13 and all(q['directStatus'] == 200 and q['directAttempts'] == 0 for q in no_proxy)
assert len(diag_rows) == 6 and frontend['us']['allDiagnosticsMatchedComplete']
assert all(q['newSupplyFailedCycles'] == 0 and q['regionMismatchCycles'] == 0 for q in probes.values())
assert not any(q['newFixedErrorRecords'] for q in quickread.values())
assert len(new_disconnects) == 7 and all(q['abortSource'] == 'downstream_closed' and q['abortStage'] == 'upstream_headers' for q in new_disconnects)

now = datetime.now(timezone.utc).isoformat()
access = {'schema': 'castreader.monitor-access-readback.v1', 'checkedAtUTC': now, 'additionalAuthorizationRequired': False, 'cnBackendReadSucceeded': True, 'usBackendReadSucceeded': True, 'vercelDetailedReadSucceeded': True, 'vercelPagesRead': v['coverage']['pagesRead'], 'productionModified': False, 'credentialsExported': False, 'existingAutomationId': '24', 'automationViewSucceeded': True, 'windowUnchanged': True, 'history': 'Previously recorded local network and saved-login refresh blocks remain archived; current successful reads establish access has recovered, not a production-service recovery.'}
write('access-readback.json', access)
reason = '国际区耗时P95从2680ms回落至1229ms，Direct新增断开由33降至7；仅确认本窗回落，未证明持续恢复或断开原因。当前用户询问授权，已确认全部采集入口可用，无需新授权。'
review = {'schema': 'castreader.backend-heartbeat-review.v1', 'automationId': '24', 'readOnly': True, 'productionModified': False, 'synthesisStarted': False, 'rawContentExported': False, 'reviewedAtUTC': now, 'snapshotDirectory': str(O), 'fixedWindow': a['window'], 'incrementalWindow': p['window'], 'backendVerdict': '存在异常：国际区延迟和断开次数回落，但仍有7次无响应；未见新增5xx或模型终止错误，完整交付证据仍不足', 'decision': 'NOTIFY', 'newActionableChange': True, 'reason': reason,
    'globalTts': {'requests': len(v['requests']), 'finished200': len(times), 'allAttempt1': True, 'globalElapsedMs': perf, 'proxyCounts': p['counts'], 'coalescing': p['coalescing'], 'proxyTimingsMs': p['stageTimingMilliseconds'], 'globalJoin': j['counts'], 'proxyIdentityAndCoverageVerified': True, 'cumulativeCore5xx': 1, 'historicalJapanese500Preserved': True},
    'direct': {'cumulativeStatusCounts': dc['aggregate']['statusCounts'], 'source': dc['source'], 'incrementalExactWindow': dict(collections.Counter(str(q['status']) for q in d['requests'])), 'newDownstreamDisconnects': new_disconnects, 'disconnectionFollowup': str(O / 'disconnect-followup.json'), 'terminalOccurrenceSupplement': str(O / 'direct-terminal-occurrences.json'), 'knownFrozenVersionMismatchPreserved': True, 'cumulativeCoverage': dc['coverage'], 'cumulativeSource': str(O / 'direct-complete-cumulative.json'), 'legacyAcceptanceSnapshotTruncated': True, 'journalRows': dc['aggregate']['journalRowsRead'], 'cumulativeDuplicateRequestLogBlocks': dc['aggregate']['duplicateRequestLogBlocks'], 'originalKeyDedupSemanticsPreserved': True, 'noProxyZeroAttempt200Count': len(no_proxy)},
    'cnTts': {'parsedCumulativeStatuses': cr['cumulativeStatuses'], 'incrementalStatuses': cr['incrementalStatuses'], 'baseline': str(P / 'cn-rotated-ingress.json'), 'unparsedFileLines': sum(q['unparsedLines'] for q in cr['sources']), 'rotationCoverageSupplement': str(O / 'cn-rotated-ingress.json'), 'knownMaintenance502Count': 2, 'new502': 0, 'publicationAvailabilityGapClosed': False, 'existingProbeSeries': series, 'wholeProbeIsModelTTFB': False},
    'proxyAttribution': {'globalExactMatched': len(gk), 'directExactMatched': len(dk), 'remainingUnattributedGroups': len(remaining), 'source': str(O / 'reverse-attribution.json')}, 'runtimeComparisonsToPreviousSnapshot': identities,
    'models': {r: {'release': m['release'], 'identityVerified': m['identity']['verified'], 'diagnosticWindow': m['window'], 'fixedStageCounts': m['fixedStageCounts'], 'failureEvents': m['failureEvents'], 'unclassifiedEventsInOriginalCollector': m['unclassifiedEvents'], 'successLedgerComplete': False} for r, m in models.items()}, 'optionalFrontendReview': str(O / 'frontend-recovery-attribution.json'), 'existingProbes': probes, 'quickread': quickread,
    'clone': {'us': {'incrementalEvents': s['us-gpu']['cloneStructuredLog']['incrementalEvents'], 'startupHealthCounters': s['us-gpu']['cloneHealthAfterCutoff']['fields'], 'backendVerdict': '新增1个captioned-speech生成完成，未见新失败；完整HTTP交付证据不足'}, 'cn': {'startupHealthCounters': s['cn']['cloneHealthAfterCutoff']['fields'], 'backendVerdict': '证据不足：本轮无新生成样本'}}, 'preservedIssues': old['preservedIssues'], 'accessReadback': str(O / 'access-readback.json'),
    'limitations': ['HTTP200, ready files and model job completion do not certify full user playback or complete QuickRead/clone delivery.', 'Seven downstream disconnections remain unknown outcomes, including one completed upstream response that did not become a sent Direct response.', 'The original single-file CN ingress and 250k Direct collector snapshots are preserved; use rotated-file and sharded supplements for cumulative counts.', 'Original cumulative Direct parser deduplicates request keys; the previously documented repeated key and its later200 occurrence remain preserved.', 'Provider pagination does not prove complete log ingestion.', 'Cumulative probe/readback cutoffs differ from the exact incremental request window.', 'CN has one whole-probe10.129s result with all three segments complete; this does not isolate one slow backend stage or establish user TTFB.', 'All historical faults, incomplete cross-region proofs, the CN publishing availability gap and mixed-version window are retained. R135 has not had24h observation.'],
    'sources': [{'path': str(f), 'sha256': hashlib.sha256(f.read_bytes()).hexdigest()} for f in sorted(O.rglob('*.json'))]}
write('backend-review.json', review)
(O / 'README.md').write_text('''# 后端观察：2026-09-07 17:26 UTC

现有授权可用：中国区、国际区服务器及 Vercel 日志均采集成功，无需新增授权。本轮只读，没有发布或修改生产。

观察窗口16:25:51.808–17:26:52.003 UTC（北京时间9月8日00:25–01:26）。国际区延迟和连接断开次数回落，但尚不能认定问题已解决。

- Global可见961个请求均200、attempt1，并各自关联到代理完成结果。应用耗时P95从2680ms降至1229ms；代理响应头P95从2913.054ms降至1197.919ms。相邻窗口流量构成不同，不能由此确认根因或持续恢复。
- Direct新增2547个200、7次无HTTP响应，未见新4xx/5xx。7次均记录downstream_closed/upstream_headers，耗时280–1736ms；6次对应代理取消，1次代理已经完成，但Direct尚未发出响应，仍保留未知交付结果。不能认定用户主动取消或模型报错。
- 13个Direct200请求的上游尝试次数为0，没有代理组。已核对固定生产源码存在标点片段本地静音响应分支；这是支持本地响应的推断，没有读取输入或响应头来确认每条正文。其余2541个Direct请求和961个Global请求均无歧义关联，代理无剩余未归属组。
- 中国区新增171个已解析200，无新499/502。合并轮转前后日志后累计3378个200、2个历史499、2个维护502。历史发布空窗保留。
- Global核心5xx累计仍为此前那1条日语数字前处理失败。两区R135未见新模型终止错误；US有5次英文前处理恢复和1次保留完整PCM的裁剪降级，6条均关联到完整代理结果。另有2条纯分隔段跳过诊断；不以时间戳提示否定有效音频。
- 既有探针US264/264健康，CN263/264健康，唯一失败仍为旧维护轮次。无新增地区不一致。CN一轮完整三段探针耗时10.129秒，不能当作单个模型首字节耗时；下一轮2.861秒。
- 国际区解读新增13条放行，ready文件191→204，其中168个已生成全部服务端块、36个部分ready。中国区仍29个ready。固定断开仍US2/CN4，无新增。ready文件不证明完整HTTP交付。
- 国际区克隆新增1次captioned-speech生成完成，启动以来完成数670→671，failed/expired仍0；中国区仍4次完成且无新样本。任务完成不等于用户完整收到音频。
- 两区模型、QuickRead、克隆/Nari、Global及Direct运行身份未变。Direct固定期望与独立发布版本的不一致、历史异常及证据缺口均保留。累计Direct按原匿名键口径17532个200、1个400、60次无响应，历史重复键不清零。

[后端评估](backend-review.json) · [断开与耗时跟踪](disconnect-followup.json) · [授权可用性回读](access-readback.json)。固定截止仍为2026-09-07 18:37:52 UTC（北京时间9月8日02:37），不重启或延长观察窗口。
''')

f = M / 'notification-state.json'
state = read(f)
assert state['latestSnapshotDirectory'] == str(P), 'Do not overwrite a concurrently advanced cursor'
state.update({'latestSnapshotDirectory': str(O), 'latestObservationReview': str(O / 'backend-review.json'), 'latestBackendObservationReview': str(O / 'backend-review.json'), 'latestCollectionAttemptDirectory': str(O), 'latestCollectionAttemptReview': str(O / 'backend-review.json'), 'latestProxyWindowPath': str(O / 'proxy-window.json'), 'latestProxyWindowEndUTC': p['window']['endUTCExclusive'], 'latestVercelCore5xxCount': 1, 'latestDirect5xxCount': 0, 'latestDirectNoResponseCount': 60, 'latestDirectHttp400Count': 1, 'latestBackendVerdict': review['backendVerdict'], 'latestBackendSupplySnapshotPaths': [str(O / 'backend-supply' / f'{r}-backend-supply.json') for r in s], 'latestBackendHeartbeatDecision': {'decision': 'NOTIFY', 'reason': reason, 'reviewedAtUTC': now, 'deliveredDuringNormalUserTurn': True}, 'latestReverseProxyGlobalAttribution': review['proxyAttribution'], 'latestBackendPerformanceObservation': {'observedThroughUTC': p['window']['endUTCExclusive'], 'successfulRequestFinishP95Ms': perf['p95Ms'], 'proxyHeadersP95Ms': p['stageTimingMilliseconds']['upstream_headers.elapsedMs']['p95'], 'sustainedGlobalRecoveryEstablished': False, 'cnServerSlowStageEstablished': False}, 'latestCNBackendLatencyWatch': str(O / 'cn-probe-timing-series.json'), 'latestBackendDisconnectReview': str(O / 'disconnect-followup.json'), 'latestOptionalFrontendGroupReview': str(O / 'frontend-recovery-attribution.json'), 'currentBackendCollectionStatus': 'available', 'latestCompleteDirectSupplement': str(O / 'direct-complete-cumulative.json'), 'latestAccessReadback': str(O / 'access-readback.json'), 'recordedAtUtc': now, 'lastDecision': 'NOTIFY', 'lastDecisionReason': reason})
state['knownDirectNoResponseKeys'] = sorted(set(state.get('knownDirectNoResponseKeys', [])) | {q['key'] for q in new_disconnects})
state['knownProxyCancellationKeys'] = sorted(set(state.get('knownProxyCancellationKeys', [])) | {q['requestKey'] for q in reverse['cancelledProxyGroups']})
state['knownCNLongProbeSourceSha256'] = sorted(set(state.get('knownCNLongProbeSourceSha256', [])) | {q['sourceSha256'] for q in series['rows'] if q['elapsedMs'] > 10000})
state['latestBackendPerformanceRecoveryObservation'] = {'atUTC': now, 'reviewPath': str(O / 'disconnect-followup.json'), 'previousAlertPreserved': state['latestBackendPerformanceAlert']['eventKey'], 'hourlyImprovementObserved': True, 'incidentClosed': False, 'sustainedRecoveryEstablished': False}
state.setdefault('backendPerformanceRecoveryObservationHistory', []).append(state['latestBackendPerformanceRecoveryObservation'])
state['latestBackendServiceVerdicts'] = [{'region': 'global', 'service': 'kokoro_tts', 'backendVerdict': '耗时与断开回落，但仍7次无响应；无新5xx或模型终止错误，断开原因未明'}, {'region': 'cn', 'service': 'kokoro_tts', 'backendVerdict': '本窗171个已解析200，无新499/502，历史问题保留'}] + [{'region': r, 'service': 'quickread', 'backendVerdict': quickread['us' if r == 'global' else r]['backendVerdict']} for r in ['global', 'cn']] + [{'region': r, 'service': 'clone_tts', 'backendVerdict': review['clone']['us' if r == 'global' else r]['backendVerdict']} for r in ['global', 'cn']]
state['nextCollectionNotes'] = ['Reuse bounded3h Direct journal shards and reassemble before parsing; cumulative rows now628872. Preserve original key-dedup and historical repeated-key occurrence evidence.', 'Continue reading CN access.log.1 plus access.log; retain current-file-only original snapshots.', 'The17:26 hourly latency/disconnect decrease was reported in the normal user turn. It does not close the prior incident; seven new disconnects remain unknown.', 'Access was verified for both regions and Vercel; no additional user authorization is needed. Keep the fixed deadline18:37:52.522573UTC.']
f.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'globalRequests': len(times), 'globalP95Ms': perf['p95Ms'], 'directNewNoResponse': len(new_disconnects), 'remainingProxyGroups': len(remaining), 'authorizationRequired': False, 'productionModified': False}))
