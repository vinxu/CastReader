"""Derive backend-only findings and close the elapsed old fixed window.

All production inputs were collected read-only. This script writes local reports
and observation state only; frozen release expectations remain unchanged.
"""
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
PREV = HERE.parent / '20260907T0355Z'
ARCHIVE = OLD / 'observations/window-complete-20260907T050125Z'
TAG = HERE.name
NOW = datetime.now(timezone.utc).isoformat()


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def ref(path):
    return {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def dist(values):
    x = sorted(values)
    return {'samples': len(x), 'p50': x[math.ceil(len(x) * .5) - 1] if x else None,
            'p95': x[math.ceil(len(x) * .95) - 1] if x else None, 'max': max(x) if x else None}


def snapshot(value):
    s = value['sources']
    return {'generatedAtUTC': value['generatedAtUtc'], 'window': value['window'],
            'directStatusCounts': s['direct_gateway']['aggregate']['statusCounts'],
            'globalCore5xx': s['vercel']['aggregate']['core5xxRecords'],
            'usProbeStatus': s['monitor_us']['aggregate']['statusCounts'],
            'cnProbeStatus': s['monitor_cn']['aggregate']['statusCounts'],
            'regionMismatchCycles': sum(s['monitor_' + r]['aggregate']['regionMismatchCycles'] for r in ('us', 'cn')),
            'rawCollectorCoverageGaps': value['evaluation']['dataOrCoverageGaps'],
            'observedSeconds': value['evaluation']['observationSeconds']}


current = read(HERE / 'latest-acceptance.json')
previous = read(PREV / 'latest-acceptance.json')
historical = read(OLD / 'observations' / TAG / 'latest-acceptance.json')
old_final = read(ARCHIVE / 'latest-acceptance.json')
proxy_path = MON / f'proxy-model-r134-{TAG}.json'
global_path = MON / f'vercel-preset-model-r134-{TAG}.json'
proxy, glob = read(proxy_path), read(global_path)
join = read(HERE / 'vercel-proxy-join.json')
direct = read(HERE / 'direct-version-requests.json')
supply = {r: read(HERE / 'backend-supply' / f'{r}-backend-supply.json')['result'] for r in ('us', 'cn', 'us-gpu')}
prior_supply = {r: read(PREV / 'backend-supply' / f'{r}-backend-supply.json')['result'] for r in supply}
prior_state = read(MON / 'notification-state.json')
expected = read(MON / 'acceptance-state.json')
comparison = {'schema': 'castreader.backend-snapshot-comparison.v4',
              'current': snapshot(current), 'previous': snapshot(previous),
              'historicalWindowBeforeEnd': snapshot(historical), 'historicalWindowFinal': snapshot(old_final),
              'excludedFromBackendVerdict': ['mobile', 'blog', 'payment'], 'originalAutomaticVerdictPreserved': True}
save(HERE / 'backend-snapshot-comparison.json', comparison)

assert proxy['identityAndCoverageVerified'] and glob['coverage']['completeForReturnedRequestCohort']
assert not proxy['anonymousRequestsTruncated']
assert join['counts'] == {'attempts': 2062, 'matched': 2062, 'ambiguous': 0, 'matchedProxyComplete': 2061}
events = [e for r in glob['requests'] for e in r['events']]
times = {stage: dist([e['elapsedMs'] for e in events if e['event'] == stage])
         for stage in ('upstream_headers', 'upstream_body', 'request_finished')}
nonempty = sum(e['event'] == 'upstream_body' and e.get('bodyBytes', 0) > 0 for e in events)
assert nonempty == len(glob['requests']) == 2062
assert all(r['status'] == 200 for r in glob['requests'])
assert glob['counts']['attemptStarts'] == {'1': 2062} and not glob['counts']['failureCodes']
represented = {(r['requestKey'], r['attempt']) for r in join['attempts']}
remaining = [r for r in proxy['anonymousRequests'] if r['receivedEvents'] and (r['requestKey'], r['attempt']) not in represented]
direct_map = {r['requestKey']: r for r in direct['requests']}
assert len(direct_map) == len(direct['requests'])
matches = [{'proxy': r, 'direct': direct_map[r['requestKey']]} for r in remaining if r['requestKey'] in direct_map]
unattributed = [r for r in remaining if r['requestKey'] not in direct_map]
proxy_keys = {r['requestKey'] for r in proxy['anonymousRequests']}
direct_local = [r for r in direct['requests'] if r['requestKey'] not in proxy_keys]
pending = [r for r in proxy['anonymousRequests'] if r['receivedEvents'] and not r['outcomes']]
assert len(matches) == 773 and not unattributed and len(direct_local) == 16
assert all(r['status'] == 200 and r['attempts'] == 0 for r in direct_local)
assert all(r['proxy']['outcomes'] == {'complete': 1} and r['direct']['status'] == 200 for r in matches)
assert len(pending) == 1 and pending[0]['requestKey'] == 'beb9876571056917852f'
boundary_global = [r for r in glob['requests'] if pending[0]['requestKey'] in r['applicationRequestKeys']]
assert len(boundary_global) == 1 and boundary_global[0]['status'] == 200
summary = {'schema': 'castreader.backend-vercel-proxy-direct-join-summary.v3', 'window': proxy['window'],
           'coverage': join['coverage'], 'counts': join['counts'], 'events': glob['counts'],
           'globalStatusCounts': dict(Counter(str(r['status']) for r in glob['requests'])),
           'elapsedMsFromRequestStart': times, 'nonEmptyBodySamples': nonempty,
           'directMatchedGroups': len(matches), 'directMatches': matches,
           'remainingUnattributedGroups': unattributed, 'directWithoutProxyMatch': direct_local,
           'pendingProxyGroups': pending, 'boundaryProviderCompletionEvidence': boundary_global,
           'limitations': ['The proxy event-time window ends during one request; matching Global records show 200 and complete nonempty body. Its proxy completion timestamp remains outside this slice and must be reconciled with the next slice.',
                          'Provider requestStartUTC plus application elapsedMs is not a verified absolute event timestamp.',
                          'Direct matching uses exact anonymous keys in the version/PID-bound permanent unit ledger. Sixteen other Direct200 rows explicitly report zero upstream attempts; their content or semantic subtype was not read.',
                          'Complete returned pagination does not prove provider ingestion completeness; HTTP completion is not full audio playback.']}
save(HERE / 'vercel-proxy-join-summary.json', summary)

version_prior = read(PREV / 'direct-version-transition.json')
live_direct = current['sources']['direct_gateway']
assert live_direct['source']['sha256'] == version_prior['observedSha256']
assert live_direct['systemd'] == version_prior['systemd']
assert expected['requiredComponents']['directGateway']['runtimeSourceSha256'] == version_prior['frozenExpectedSha256']
version = {'schema': 'castreader.direct-version-observation.v1', 'observedCommit': version_prior['observedCommit'],
           'observedSha256': live_direct['source']['sha256'], 'systemd': live_direct['systemd'],
           'unchangedSincePreviousObservation': True, 'frozenExpectedSha256': version_prior['frozenExpectedSha256'],
           'originalFrozenExpectationMatches': False, 'originalAcceptanceStateUpdated': False,
           'actualBackendWindowMixedVersions': True, 'originalFrozenDirectVersion24hCanBeCertified': False,
           'requestCountsByRecordedPID': direct['groups'], 'priorReleaseEvidence': ref(PREV / 'direct-version-transition.json')}
save(HERE / 'direct-version-observation.json', version)

identity = {
    'usQuickreadUnchanged': supply['us']['quickreadExpectedProcess'] == prior_supply['us']['quickreadExpectedProcess'],
    'cnQuickreadUnchanged': supply['cn']['quickreadProcess'] == prior_supply['cn']['quickreadProcess'],
    'cnUnitsUnchanged': supply['cn']['units'] == prior_supply['cn']['units'],
    'usCloneUnchanged': supply['us-gpu']['expectedCloneProcess'] == prior_supply['us-gpu']['expectedCloneProcess'],
    'usNariUnchanged': supply['us-gpu']['expectedNariProcess'] == prior_supply['us-gpu']['expectedNariProcess'],
    'globalDeploymentMatchesFrozen': current['sources']['global_capabilities']['identity']['deploymentId'] == expected['requiredComponents']['globalGateway']['version'],
    'globalSourceMatchesFrozen': current['sources']['global_capabilities']['identity']['commitSha'] == expected['requiredComponents']['globalGateway']['sourceCommit'],
    'usProxyModelFrozenIdentityAndCoverageVerified': proxy['identityAndCoverageVerified'],
}
assert all(identity.values())
save(HERE / 'backend-identity-comparison.json', identity)

new_qr = []
service_delta = {}
for region in ('us', 'cn'):
    rows = supply[region]['quickreadLogs']['fixedErrorRecords']
    prev_rows = prior_supply[region]['quickreadLogs']['fixedErrorRecords']
    new_qr += [{'region': region, **r} for r in rows if r not in prev_rows]
    service_delta[region] = {'quickreadIncrementalTags': supply[region]['quickreadLogs']['incrementalFixedTagCounts'],
                             'quickreadJobs': supply[region]['quickreadJobs'], 'newFixedErrorRecords': [r for r in rows if r not in prev_rows]}
assert not new_qr
for region, role in (('us', 'us-gpu'), ('cn', 'cn')):
    fields = supply[role]['cloneHealthAfterCutoff']['fields']
    before = prior_supply[role]['cloneHealthAfterCutoff']['fields']
    service_delta[region]['cloneCurrentCumulativeCounters'] = {k: fields[k] for k in ('submitted', 'completed', 'failed', 'expired')}
    service_delta[region]['cloneCounterDelta'] = {k: fields[k] - before[k] for k in ('submitted', 'completed', 'failed', 'expired')}
    assert all(v == 0 for v in service_delta[region]['cloneCounterDelta'].values())
cn_ingress = supply['cn']['ttsIngress']
service_delta['cn']['ttsIngress'] = cn_ingress
save(HERE / 'backend-service-delta.json', service_delta)

latency = read(PREV / 'latency-watch.json')
latency.update({'schema': 'castreader.backend-latency-trend.v5', 'classification': 'current_window_below_previous_reference_after_three_improving_windows',
                'absoluteLatencySloSpecified': False, 'sustainedRecoveryEstablished': False})
latency['windows'].append({'tag': TAG, 'window': glob['window'], 'globalRequestCount': len(glob['requests']),
                           'globalRequestFinishMs': times['request_finished'],
                           'proxyUpstreamHeadersElapsedMs': proxy['stageTimingMilliseconds']['upstream_headers.elapsedMs'],
                           'proxyUpstreamConnectMs': proxy['stageTimingMilliseconds']['upstream_connected.connectMs']})
# Prior qualitative annotations remain in the immutable prior report, not in the new observation.
latency = {k: latency[k] for k in ('schema', 'classification', 'windows', 'absoluteLatencySloSpecified', 'sustainedRecoveryEstablished')}
latency['limitations'] = ['The request mix and output sizes vary. Lower latency is observed, not proof of a specific model/queue fix or an absolute product SLO.',
                          'The current P95 is below the 23:53Z reference in this window; longer lasting recovery remains under observation.']
save(HERE / 'latency-watch.json', latency)
cn_rows = read(HERE / 'cn-probe-timing-series.json')['rows']
assert len(cn_rows) == 11 and all(r['supplyOk'] and r['completeAudio'] and r['segmentAttempts'] == [1, 1, 1] and not r['regionMismatch'] for r in cn_rows)
cn_watch = {'schema': 'castreader.cn-probe-latency-watch.v3', 'probeElapsedMs': dist([r['elapsedMs'] for r in cn_rows]),
            'rows': cn_rows, 'overTenSeconds': [r for r in cn_rows if r['elapsedMs'] > 10000],
            'classification': 'no_new_over_10s_cycle_in_current_slice', 'serverSlowStageEstablished': False,
            'limitations': ['These are existing three-segment probe cycles, including HTTP and local decode; elapsed time is not model TTFB.',
                           'Older 31.702s, 21.883s, 22.466s and other slow cycles remain retained and not fully attributed.']}
save(HERE / 'cn-latency-watch.json', cn_watch)

def keys(value):
    return {r['key'] for r in value['sources']['direct_gateway']['aggregate']['nonHttpRequests']}

assert keys(current) == keys(previous)
assert current['sources']['direct_gateway']['aggregate']['statusCounts']['400'] == previous['sources']['direct_gateway']['aggregate']['statusCounts']['400'] == 1
assert comparison['current']['globalCore5xx'] == comparison['previous']['globalCore5xx'] == 0
assert comparison['historicalWindowFinal']['globalCore5xx'] == 4
assert comparison['historicalWindowFinal']['directStatusCounts'] == {'200': 12063, '400': 4, '502': 1, '504': 4, 'no_response': 15}

services = [
    {'region': 'global', 'service': 'kokoro_tts', 'backendVerdict': '符合预期', 'scope': '本小时可见HTTP供给',
     'evidence': 'Global2062条均200、非空响应体并完成、单次尝试，P95为1339ms。2061条代理完成，另1条处于代理切片边界、匹配Global已完成。Direct当前PID789条均200，其中773条精确关联代理完成、16条上游尝试数0。'},
    {'region': 'cn', 'service': 'kokoro_tts', 'backendVerdict': '证据不足', 'scope': '可见供给正常，历史断开和慢探针尚未完全归因',
     'evidence': '累计已解析890条TTS POST200，既有1条nginx499未增加；另35行无法解析不能假定与TTS无关。120轮探针均供给和完整余文解码成功；本小时11轮均完整、最大9735ms。'},
    {'region': 'global', 'service': 'clone_tts', 'backendVerdict': '证据不足', 'scope': '本窗口真实合成和交付',
     'evidence': '当前健康，启动累计173完成、0失败/过期不变，本窗口结构化合成样本仍为0；不以健康计数代替成功率。'},
    {'region': 'cn', 'service': 'clone_tts', 'backendVerdict': '证据不足', 'scope': '本窗口真实合成和交付',
     'evidence': '当前健康，启动累计4完成、0失败/过期不变，缺本窗口逐次合成和完整HTTP交付样本。'},
    {'region': 'global', 'service': 'quickread', 'backendVerdict': '证据不足', 'scope': '可见生成正常，完整HTTP交付覆盖不足',
     'evidence': '104份窗口修改任务均ready有首块，88份全块生成、16份partial-ready；本小时2条权益放行，无新增固定错误。既有2条request_disconnected结果未知。'},
    {'region': 'cn', 'service': 'quickread', 'backendVerdict': '证据不足', 'scope': '可见生成正常，完整HTTP交付覆盖不足',
     'evidence': '16份窗口修改任务均ready有首块，14份全块生成、2份partial-ready；本小时1条权益放行，无新增固定错误。既有1条request_disconnected结果未知。'},
]

old_before, old_after = read(ARCHIVE / 'acceptance-state-before.json'), read(ARCHIVE / 'acceptance-state.json')
assert old_before['cutoverState'] == 'observing' and old_after['cutoverState'] == 'window_complete'
assert {k: v for k, v in old_before.items() if k != 'cutoverState'} == {k: v for k, v in old_after.items() if k != 'cutoverState'}
assert old_final['window']['collectedThroughExclusive'] == old_after['window']['endUtc']
assert old_final['evaluation']['observationSeconds'] == 86400
archive_review = {'schema': 'castreader.backend-fixed-window-completion.v1', 'automationId': '24',
                  'archivedAtUTC': NOW, 'window': old_final['window'], 'cutoverState': 'window_complete',
                  'backendVerdict': '存在异常', 'backendVerdictReason': '整个旧窗保留真实HTTP错误及版本切换，不能认定无故障通过。收尾未发现新增已确认供给失败。',
                  'backendFinalSnapshot': comparison['historicalWindowFinal'],
                  'originalAutomaticVerdictUsedAsBackendConclusion': False, 'historicalFailuresPreserved': True,
                  'retainedFindings': ['Global4条504、Direct4条504及1条维护阶段502均保留，不把两个入口计数相加为独立用户故障数。',
                                       'Direct400共4条：既有3条旧模型拒绝、1条本地请求校验拒绝；本地校验拒绝不算有效TTS模型供给失败。',
                                       'Direct15条无HTTP响应，最终交付与取消原因未知；不改写为成功、模型超时或用户主动取消。',
                                       'US278轮、CN277轮既有探针完整供给及余文解码正常、地区元数据不匹配0，但不覆盖所有真实请求及物理跨境路径。',
                                       '本旧窗存在多次Global/Direct/代理/模型版本切换。Direct最新独立发布的证据单列，冻结期望未用实时值覆盖。',
                                       'QuickRead和克隆完整HTTP交付仍缺覆盖；后续细分供给证据从最终R134窗口采集，不能冒充整个旧窗的样本。'],
                  'readOnlyProduction': True, 'productionModified': False, 'synthesisStarted': False,
                  'stopFurtherOldWindowCollection': True, 'finalWindowStillActive': expected['window'],
                  'finalWindowExtendedOrRestarted': False, 'automationPaused': False,
                  'sources': [ref(ARCHIVE / 'latest-acceptance.json'), ref(ARCHIVE / 'acceptance-state-before.json'),
                              ref(ARCHIVE / 'acceptance-state.json'), ref(PREV / 'direct-version-transition.json')]}
save(ARCHIVE / 'backend-final-review.json', archive_review)
save(ARCHIVE / 'archive.json', {'schema': 'castreader.fixed-window-archive.v1', 'archivedAtUTC': NOW,
                              'window': old_after['window'], 'stopFurtherCollection': True,
                              'finalSnapshot': ref(ARCHIVE / 'latest-acceptance.json'), 'backendReview': ref(ARCHIVE / 'backend-final-review.json')})

reason = '旧固定24小时窗口到期归档；新窗口继续。当前无新增已确认供给失败，Global时延继续改善，克隆和解读完整交付证据仍不足。'
sources = [HERE / 'latest-acceptance.json', OLD / 'observations' / TAG / 'latest-acceptance.json',
           proxy_path, global_path, HERE / 'vercel-proxy-join-summary.json', HERE / 'direct-version-requests.json',
           HERE / 'direct-version-observation.json', HERE / 'backend-identity-comparison.json', HERE / 'backend-service-delta.json',
           HERE / 'latency-watch.json', HERE / 'cn-latency-watch.json', ARCHIVE / 'backend-final-review.json',
           *[HERE / 'backend-supply' / f'{r}-backend-supply.json' for r in supply]]
review = {'schema': 'castreader.backend-audio-heartbeat-review.v5', 'automationId': '24', 'reviewedAtUTC': NOW,
          'decision': 'NOTIFY', 'decisionReason': reason, 'observationScope': 'backend_tts_clone_quickread_only',
          'backendVerdict': '证据不足', 'backendVerdictReason': '可见有效供给本小时正常，整体仍缺克隆/解读完整交付覆盖及未决慢请求归因，且Direct窗内变更版本。',
          'readOnly': True, 'productionModified': False, 'synthesisStarted': False, 'finalWindow': current['window'],
          'backendDetailWindow': proxy['window'], 'services': services, 'currentBackendSnapshot': comparison['current'],
          'historicalBackendSnapshot': comparison['historicalWindowFinal'], 'historicalWindowArchived': ref(ARCHIVE / 'archive.json'),
          'newConfirmedValidTtsOrLlmSupplyFailures': [], 'newObservedDirectVersion': None, 'newQuickreadDisconnectRecords': [],
          'newProxyCancellation': None, 'newCNIngressLoggedNon200': [], 'latestDirectVersionObservation': version,
          'proxyPendingBoundaryGroups': pending, 'boundaryProviderCompletionEvidence': boundary_global,
          'latencyWatch': latency, 'cnLatencyWatch': cn_watch, 'actualBackendWindowMixedVersions': True,
          'originalFrozenDirectVersion24hCanBeCertified': False,
          'limitations': ['Original automaticVerdict includes out-of-scope clients and is not used for this backend conclusion.',
                          'No new confirmed supply failures is limited to returned backend data; clone/QuickRead request ledgers and provider ingestion completeness are not established.',
                          'Historical request_disconnected, no_response,499 and cancelled outcomes remain unresolved unless individually matched; none proves model failure or requester intent.',
                          'Task-file ready/all-block counters are modified-file cohorts, not complete HTTP or downstream TTS outcomes.',
                          'Source/node labels and sampled regional contracts do not certify every physical hop stays in-region. CN R134 is not deployed.',
                          'The final window retains its original deadline. The observed Direct version change does not restart or extend it.'],
          'sources': [ref(p) for p in sources]}
save(HERE / 'heartbeat-review.json', review)

for path in (MON / 'notification-state.json', OLD / 'observations/notification-state.json'):
    state = read(path)
    final_for_state = current if path.parent == MON else old_final
    state.update({'lastDecision': 'NOTIFY', 'lastDecisionReason': reason, 'recordedAtUtc': NOW,
                  'latestBackendVerdict': review['backendVerdict'] if path.parent == MON else archive_review['backendVerdict'],
                  'latestBackendServiceVerdicts': services, 'latestBackendObservationReview': str(HERE / 'heartbeat-review.json'),
                  'latestObservationReview': str(HERE / 'heartbeat-review.json'), 'latestSnapshotDirectory': 'observations/' + TAG,
                  'latestProxyWindowEndUTC': proxy['window']['endUTCExclusive'], 'latestProxyWindowPath': str(proxy_path),
                  'latestBackendSupplySnapshotPaths': [str(HERE / 'backend-supply' / f'{r}-backend-supply.json') for r in supply],
                  'latestBackendLatencyWatch': str(HERE / 'latency-watch.json'), 'latestCNBackendLatencyWatch': str(HERE / 'cn-latency-watch.json'),
                  'latestDirectVersionReadback': version, 'latestDirectNoResponseCount': snapshot(final_for_state)['directStatusCounts']['no_response'],
                  'latestDirectHttp400Count': snapshot(final_for_state)['directStatusCounts']['400'],
                  'latestBackendPerformanceObservation': {'observedThroughUTC': proxy['window']['endUTCExclusive'],
                                                        'requestFinishP95Ms': 1339, 'proxyHeadersP95Ms': 1214.769,
                                                        'currentWindowBelowPriorReference': True, 'sustainedGlobalRecoveryEstablished': False,
                                                        'cnSlowProbeCompletionUTCs': [], 'cnServerSlowStageEstablished': False},
                  'latestReverseProxyGlobalAttribution': {'globalMatchedGroups': 2062, 'globalProxyCompleteGroups': 2061,
                                                        'directExactMatchedGroups': 773, 'remainingUnattributedGroups': 0,
                                                        'pendingBoundaryGroups': pending, 'reviewPath': str(HERE / 'vercel-proxy-join-summary.json')},
                  'oldWindowArchivePath': str(ARCHIVE / 'archive.json'), 'stopFurtherOldWindowCollection': True,
                  'actualBackendWindowMixedVersions': True, 'originalFrozenDirectVersion24hCanBeCertified': False})
    if path.parent != MON:
        state.update({'windowArchivedAtUtc': NOW, 'windowComplete': True,
                      'latestSnapshotDirectory': 'observations/' + ARCHIVE.name,
                      'backendWindowFinalReview': str(ARCHIVE / 'backend-final-review.json')})
    state.setdefault('backendWindowCompletionNotifications', []).append({'windowEndUTC': old_after['window']['endUtc'],
                                                                       'reviewPath': str(ARCHIVE / 'backend-final-review.json'), 'atUTC': NOW})
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')

assert read(MON / 'acceptance-state.json') == expected
print(json.dumps({'global': len(glob['requests']), 'globalFinishMs': times['request_finished'],
                  'direct': direct['groups'], 'oldWindowArchived': True,
                  'backendVerdict': review['backendVerdict'], 'decision': 'NOTIFY'}, ensure_ascii=False))
