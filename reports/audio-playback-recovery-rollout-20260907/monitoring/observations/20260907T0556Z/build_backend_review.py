"""Backend-only observation and exact-key attribution; local reports only."""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
MON = HERE.parent.parent
ROOT = MON.parents[2]
PREV = HERE.parent / '20260907T0455Z'
OLD = ROOT / 'reports/backend-audio-iteration-20260906/monitoring'
NOW = datetime.now(timezone.utc).isoformat()
TAG = HERE.name


def read(p):
    return json.loads(p.read_text())


def save(name, value):
    with (HERE / name).open('x') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def ref(p):
    return {'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}


def dist(v):
    x = sorted(v)
    return {'samples': len(x), 'p50': x[math.ceil(len(x) * .5) - 1] if x else None,
            'p95': x[math.ceil(len(x) * .95) - 1] if x else None, 'max': max(x) if x else None}


def snapshot(v):
    s = v['sources']
    return {'generatedAtUTC': v['generatedAtUtc'], 'window': v['window'],
            'directStatusCounts': s['direct_gateway']['aggregate']['statusCounts'],
            'globalCore5xx': s['vercel']['aggregate']['core5xxRecords'],
            'usProbeStatus': s['monitor_us']['aggregate']['statusCounts'],
            'cnProbeStatus': s['monitor_cn']['aggregate']['statusCounts'],
            'regionMismatchCycles': sum(s['monitor_' + r]['aggregate']['regionMismatchCycles'] for r in ('us', 'cn')),
            'rawCollectorCoverageGaps': v['evaluation']['dataOrCoverageGaps'],
            'observedSeconds': v['evaluation']['observationSeconds']}


current = read(HERE / 'latest-acceptance.json')
previous = read(PREV / 'latest-acceptance.json')
state = read(MON / 'notification-state.json')
frozen = (MON / 'acceptance-state.json').read_bytes()
old_state = (OLD / 'acceptance-state.json').read_bytes()
old_notification = (OLD / 'observations/notification-state.json').read_bytes()
assert json.loads(old_state)['cutoverState'] == 'window_complete'
proxy_path = MON / f'proxy-model-r134-{TAG}.json'
global_path = MON / f'vercel-preset-model-r134-{TAG}.json'
proxy, glob = read(proxy_path), read(global_path)
join = read(HERE / 'vercel-proxy-join.json')
direct = read(HERE / 'direct-version-requests.json')
diag = read(HERE / 'model-existing-diagnostics-v3.json')
incident_proxy = read(HERE / 'proxy-500-window.json')
cause_source = read(HERE / 'model-cause-source-evidence-v2.json')
clone_detail = read(HERE / 'clone-fixed-event-detail-v2.json')
supply = {r: read(HERE / 'backend-supply' / f'{r}-backend-supply.json')['result'] for r in ('us', 'cn', 'us-gpu')}
prior_supply = {r: read(PREV / 'backend-supply' / f'{r}-backend-supply.json')['result'] for r in supply}
save('backend-snapshot-comparison.json', {'schema': 'castreader.backend-snapshot-comparison.v5',
     'current': snapshot(current), 'previous': snapshot(previous), 'oldWindowCollectionStopped': True,
     'oldWindowArchive': state['oldWindowArchivePath'], 'originalAutomaticVerdictUsed': False})

assert glob['coverage']['completeForReturnedRequestCohort'] and proxy['identityAndCoverageVerified']
assert not proxy['anonymousRequestsTruncated'] and not incident_proxy['eventsTruncated']
assert join['counts'] == {'attempts': 2622, 'matched': 2622, 'ambiguous': 0, 'matchedProxyComplete': 2622}
assert Counter(r['status'] for r in glob['requests']) == {200: 2619, 500: 1}
bad = next(r for r in glob['requests'] if r['status'] == 500)
key = 'db01858dc3443217d896'
assert bad['applicationRequestKeys'] == [key]
assert bad['vercelRequestKey'] == '5bef6cbfd9c294282156'
assert bad['events'][-1]['elapsedMs'] == 3679 and bad['events'][-1]['code'] == 'TTS_UPSTREAM_HTTP'
attempts = []
for number in (1, 2, 3):
    pe = [e for e in incident_proxy['events'] if e.get('requestKey') == key and e.get('attempt') == number]
    flight = next(e for e in pe if e['stage'] == 'flight_created')['upstreamRequestKey']
    de = [e for e in diag['failureEvents'] if e['requestKey'] == flight]
    model_errors = [e for e in de if e['stage'] == 'model_generation_failed']
    assert len(model_errors) == 2
    for e in model_errors:
        assert e['causes'][0]['type'] == 'AssertionError' and e['causes'][0]['omittedFrames'] == 0
        assert e['causes'][0]['frames'][-1] == {'file': 'cutlet.py', 'line': 355, 'function': '_romaji_word'}
    model_end = next(e for e in de if e['stage'] == 'request_failed')
    upstream_end = next(e for e in pe if e['stage'] == 'upstream_complete')
    caller_end = next(e for e in pe if e['stage'] == 'request_finished')
    assert model_end['status'] == upstream_end['status'] == caller_end['status'] == 500
    attempts.append({'attempt': number, 'upstreamRequestKey': flight, 'proxyEvents': pe, 'modelEvents': de,
                     'modelElapsedMs': model_end['elapsed_ms'], 'proxyUpstreamCompleteMs': upstream_end['elapsedMs'],
                     'upstreamBytes': upstream_end['responseBytes'], 'httpStatus': 500,
                     'modelFrontendAssertionCount': len(model_errors), 'transportCompleteIsAudioSuccess': False})
assert len({r['upstreamRequestKey'] for r in attempts}) == 3
cutlet = next(s for s in cause_source['sources'] if s['path'].endswith('/misaki/cutlet.py'))
assert cutlet['found'] and next(r['code'] for r in cutlet['lines'] if r['line'] == 355).strip() == 'assert not surface.isdigit(), surface'
local_model = Path('/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-silent-separators-20260907/api/src/inference/kokoro_v1.py')
assert ref(local_model)['sha256'] == next(s['sha256'] for s in cause_source['sources'] if s['path'].endswith('/kokoro_v1.py'))
extra_model = [e for e in diag['failureEvents'] if e['requestKey'] not in {a['upstreamRequestKey'] for a in attempts}]
assert len(extra_model) == 1 and extra_model[0]['status'] == 404
assert not any(extra_model[0]['requestKey'] == r['requestKey'] for r in proxy['anonymousRequests'])
cause = {'schema': 'castreader.global-japanese-g2p-assertion-incident.v1', 'readOnly': True,
         'productionModified': False, 'synthesisStarted': False, 'rawContentExported': False,
         'applicationRequestKey': key, 'vercelRequestKey': bad['vercelRequestKey'],
         'requestStartUTC': bad['requestStartUTC'], 'globalTerminalStatus': 500,
         'globalElapsedMs': 3679, 'globalBudgetMs': 28000, 'globalProviderRequest': bad,
         'exactProxyAndModelAttempts': attempts, 'independentGlobalFailedRequests': 1,
         'upstreamFailedAttempts': 3, 'sameFrontendAssertionOccurrences': 6,
         'confirmedPhase': 'Japanese G2P before acoustic inference for the failing generation unit',
         'confirmedCodeCondition': 'misaki/cutlet.py:355 assert not surface.isdigit(), surface',
         'confirmedCause': 'A token reaching the Japanese romanization stage still satisfied str.isdigit(); this production assertion raised before phoneme generation completed. The same path failed twice per upstream request and on all three gateway attempts.',
         'excludedAsImmediateCause': ['28s gateway budget expiration', 'timestamp/highlight rejection', 'proxy connect timeout', 'deployment/process restart'],
         'notEstablished': ['Exact original numeric characters and surrounding content; no text or exception values were read.',
                            'Why normalization left that token unconverted: Unicode numeric category, tokenizer behavior and context remain unobserved.',
                            'Whether the initiating caller was a customer, existing monitor or independent validation.',
                            'Actual end-device playback outcome; this is a confirmed backend500.'],
         'unattributedModelHTTP404': {'record': extra_model[0], 'knownRoute': False,
                                      'matchingProxyRequestFound': False, 'validTtsGenerationFailureEstablished': False,
                                      'note': 'RequestDiagnosticsMiddleware observes all HTTP routes; this0ms404 has no correlated generation failure or route and is preserved separately.'},
         'followUpDirection': 'Investigate Japanese numeric normalization and a same-region, same-model frontend recovery that preserves every digit and the complete text. Repeating the same assertion path cannot recover this observed input. Do not drop content or replace readable text with silence.',
         'sources': [ref(global_path), ref(HERE / 'proxy-500-window.json'), ref(HERE / 'model-existing-diagnostics-v3.json'),
                     ref(HERE / 'model-cause-source-evidence-v2.json'), ref(local_model)]}
save('tts500-cause-review.json', cause)

good = [r for r in glob['requests'] if r['status'] == 200]
good_events = [e for r in good for e in r['events']]
times = {stage: dist([e['elapsedMs'] for e in good_events if e['event'] == stage])
         for stage in ('upstream_headers', 'upstream_body', 'request_finished')}
assert sum(e['event'] == 'upstream_body' and e.get('bodyBytes', 0) > 0 for e in good_events) == 2619
represented = {(r['requestKey'], r['attempt']) for r in join['attempts']}
rest = [r for r in proxy['anonymousRequests'] if r['receivedEvents'] and (r['requestKey'], r['attempt']) not in represented]
dm = {r['requestKey']: r for r in direct['requests']}
matches = [{'proxy': r, 'direct': dm[r['requestKey']]} for r in rest if r['requestKey'] in dm]
unattributed = [r for r in rest if r['requestKey'] not in dm]
proxy_keys = {r['requestKey'] for r in proxy['anonymousRequests']}
local_direct = [r for r in direct['requests'] if r['requestKey'] not in proxy_keys]
carryover = [r for r in proxy['anonymousRequests'] if not r['receivedEvents']]
pending = [r for r in proxy['anonymousRequests'] if r['receivedEvents'] and not r['outcomes']]
assert len(matches) == 913 and len(local_direct) == 23 and len(unattributed) == 20
assert all(r['attempts'] == 0 and r['status'] == 200 for r in local_direct)
assert len(carryover) == 1 and carryover[0]['requestKey'] == 'beb9876571056917852f' and carryover[0]['outcomes'] == {'complete': 1}
assert len(pending) == 1 and pending[0]['requestKey'] == '9d0bf89544b0f36c68d3'
join_summary = {'schema': 'castreader.backend-vercel-proxy-direct-join-summary.v4', 'window': proxy['window'],
                'coverage': join['coverage'], 'counts': join['counts'], 'globalStatusCounts': {'200': 2619, '500': 1},
                'successfulRequestElapsedMs': times, 'nonEmptySuccessfulBodySamples': 2619,
                'directMatchedGroups': len(matches), 'directMatches': matches, 'directWithoutProxyMatch': local_direct,
                'remainingUnattributedGroups': unattributed, 'resolvedPriorBoundaryGroups': carryover,
                'pendingProxyGroups': pending,
                'limitations': ['matchedProxyComplete means completed HTTP transport, including three500 responses; it does not mean2622 successful audio responses.',
                                'Twenty admissions remain unmatched to fixed Global request-start records and permanent Direct completions:19 transport-complete groups plus one boundary group. Their caller/deployment is unknown; attempt1 alone is insufficient.',
                                'The current pending group is retained for the next adjacent slice. Provider and proxy timestamps have different semantics.',
                                'Returned provider pagination is complete, but ingestion completeness is unverified.']}
save('vercel-proxy-join-summary.json', join_summary)

observed_direct = current['sources']['direct_gateway']
assert observed_direct['source']['sha256'] == state['latestDirectVersionReadback']['observedSha256']
assert observed_direct['systemd'] == state['latestDirectVersionReadback']['systemd']
version = {**state['latestDirectVersionReadback'], 'requestCountsByRecordedPID': direct['groups']}
save('direct-version-observation.json', version)
identity = {
    'usQuickreadUnchanged': supply['us']['quickreadExpectedProcess'] == prior_supply['us']['quickreadExpectedProcess'],
    'cnQuickreadUnchanged': supply['cn']['quickreadProcess'] == prior_supply['cn']['quickreadProcess'],
    'cnUnitsUnchanged': supply['cn']['units'] == prior_supply['cn']['units'],
    'usCloneUnchanged': supply['us-gpu']['expectedCloneProcess'] == prior_supply['us-gpu']['expectedCloneProcess'],
    'usNariUnchanged': supply['us-gpu']['expectedNariProcess'] == prior_supply['us-gpu']['expectedNariProcess'],
    'globalSourceAndDeploymentUnchanged': current['sources']['global_capabilities']['identity'] == previous['sources']['global_capabilities']['identity'],
    'usProxyModelFrozenIdentityVerified': proxy['identityAndCoverageVerified'],
    'directObservedVersionAndProcessUnchanged': True,
}
assert all(identity.values())
save('backend-identity-comparison.json', identity)
qr_new = [{'region': r, **e} for r in ('us', 'cn') for e in supply[r]['quickreadLogs']['fixedErrorRecords']
          if e not in prior_supply[r]['quickreadLogs']['fixedErrorRecords']]
assert not qr_new
assert {r['key'] for r in current['sources']['direct_gateway']['aggregate']['nonHttpRequests']} == {r['key'] for r in previous['sources']['direct_gateway']['aggregate']['nonHttpRequests']}
assert snapshot(current)['directStatusCounts'] == {'200': 6957, '400': 1, 'no_response': 12}
assert snapshot(current)['globalCore5xx'] == 1
clone_local = ROOT / 'reports/nari-dynamic-voice-clone-poc/worker/clone_worker.py'
assert ref(clone_local)['sha256'] == clone_detail['source']['sha256']
assert clone_detail['unknownEventCount'] == 0
assert len(clone_detail['durationWarnings']) == 5 and all(r['blocking'] is False for r in clone_detail['durationWarnings'])
assert len(clone_detail['referenceRejections']) == 1 and clone_detail['referenceRejections'][0]['code'] == 'VOICE_REFERENCE_MULTIPLE_SPEAKERS'
clone_review = {'schema': 'castreader.clone-supply-coverage-review.v1',
                'usGenerationJobSamples': {'captioned-speech': 171, 'speech': 2, 'voice-denoise-prompt-build': 3},
                'firstPositiveStructuredSynthesisWindow': True, 'generationCompletionEstablishedForObservedJobs': True,
                'completeHttpMediaDeliveryEstablished': False,
                'fiveDurationWarningsExplicitlyNonblocking': True, 'referenceRejections': clone_detail['referenceRejections'],
                'referenceRejectionClassification': 'Voice creation reference validation, fixed MULTIPLE_SPEAKERS code, source branch raises422; not an established interruption of existing-voice TTS playback. Accuracy of the classifier and actual HTTP delivery were not independently verified.',
                'sourceBranch': {'file': str(clone_local), 'eventLine': 1185, 'raiseHttp422Line': 1192},
                'healthCounterLimit': 'US362 completed is a post-cutoff cumulative health read, including events outside this fixed slice. Use173 timed audio-generation jobs for window supply, not362 or the189 counter delta.',
                'sources': [ref(HERE / 'clone-fixed-event-detail-v2.json'), ref(HERE / 'backend-supply/us-gpu-backend-supply.json'), ref(clone_local)]}
save('clone-supply-review.json', clone_review)

latency = read(PREV / 'latency-watch.json')
latency.update({'schema': 'castreader.backend-latency-trend.v6', 'classification': 'success_latency_within_recent_range_new_frontend_failure_separate',
                'sustainedRecoveryEstablished': False})
latency['windows'].append({'tag': TAG, 'window': glob['window'], 'globalRequestCount': len(glob['requests']),
                           'successfulRequestSamples': 2619, 'globalRequestFinishMs': times['request_finished'],
                           'timingCohort': 'HTTP200 requests only; one500 reported separately',
                           'proxyUpstreamHeadersElapsedMs': proxy['stageTimingMilliseconds']['upstream_headers.elapsedMs'],
                           'proxyUpstreamConnectMs': proxy['stageTimingMilliseconds']['upstream_connected.connectMs']})
save('latency-watch.json', latency)
cn_rows = read(HERE / 'cn-probe-timing-series.json')['rows']
assert len(cn_rows) == 12 and all(r['supplyOk'] and r['completeAudio'] and r['segmentAttempts'] == [1, 1, 1] and not r['regionMismatch'] for r in cn_rows)
cn_watch = {'schema': 'castreader.cn-probe-latency-watch.v4', 'probeElapsedMs': dist([r['elapsedMs'] for r in cn_rows]),
            'rows': cn_rows, 'overTenSeconds': [r for r in cn_rows if r['elapsedMs'] > 10000],
            'serverSlowStageEstablished': False,
            'limitations': ['Existing three-segment probe totals include HTTP and local decode, not model TTFB. Two new11.722/12.340s cycles completed and are retained alongside older slow cycles.']}
save('cn-latency-watch.json', cn_watch)

services = [
    {'region': 'global', 'service': 'kokoro_tts', 'backendVerdict': '存在异常', 'scope': '本小时可见供给与确证故障',
     'evidence': 'Global2620条中2619条200且非空完整，1条500。日语G2P数字断言导致3个上游500、6次前处理异常；最终3679ms失败。Direct936条均200。'},
    {'region': 'cn', 'service': 'kokoro_tts', 'backendVerdict': '证据不足', 'scope': '可见供给正常，慢探针及交付覆盖不足',
     'evidence': '累计已解析1032条TTS POST200、既有1条499；40行无法解析。131轮探针均供给及余文完整；本小时12轮中2轮耗时12.340/11.722秒，未定位分项。'},
    {'region': 'global', 'service': 'clone_tts', 'backendVerdict': '符合预期', 'scope': '本小时已观测到的音频生成任务，不含完整HTTP交付验收',
     'evidence': '171次captioned-speech与2次speech生成完成，captioned运行P95为1251.39ms、队列P95为0.05ms；5条时长提示均blocking=false。另1条建音色参考MULTIPLE_SPEAKERS校验拒绝单列。'},
    {'region': 'cn', 'service': 'clone_tts', 'backendVerdict': '证据不足', 'scope': '本窗口真实合成和交付',
     'evidence': '启动累计4完成、0失败/过期不变，当前健康不能代替窗口合成样本。'},
    {'region': 'global', 'service': 'quickread', 'backendVerdict': '证据不足', 'scope': '可见生成正常、HTTP交付覆盖不足',
     'evidence': '107份窗口修改任务均ready有首块，90份全块生成、17份partial-ready；本小时3条权益放行，无新增固定错误。既有2条断开保留。'},
    {'region': 'cn', 'service': 'quickread', 'backendVerdict': '证据不足', 'scope': '可见生成正常、HTTP交付覆盖不足',
     'evidence': '16份窗口修改任务均ready有首块，14份全块生成、2份partial-ready不变；本小时无新增固定错误，既有1条断开保留。'},
]
reason = '新增1条Global500，已精确归因到日语G2P数字词元断言；首次获得US克隆真实生成完成样本。'
sources = [HERE / 'latest-acceptance.json', proxy_path, global_path, HERE / 'tts500-cause-review.json',
           HERE / 'vercel-proxy-join-summary.json', HERE / 'direct-version-observation.json',
           HERE / 'backend-identity-comparison.json', HERE / 'clone-supply-review.json',
           HERE / 'latency-watch.json', HERE / 'cn-latency-watch.json',
           *[HERE / 'backend-supply' / f'{r}-backend-supply.json' for r in supply]]
review = {'schema': 'castreader.backend-audio-heartbeat-review.v6', 'automationId': '24', 'reviewedAtUTC': NOW,
          'decision': 'NOTIFY', 'decisionReason': reason, 'observationScope': 'backend_tts_clone_quickread_only',
          'backendVerdict': '存在异常', 'backendVerdictReason': 'Global日语G2P对纯数字词元的断言导致同一请求最终500，精确贯通网关、代理与生成层。其他服务覆盖边界单列。',
          'readOnly': True, 'productionModified': False, 'synthesisStarted': False, 'finalWindow': current['window'],
          'backendDetailWindow': proxy['window'], 'services': services, 'currentBackendSnapshot': snapshot(current),
          'newConfirmedValidTtsOrLlmSupplyFailures': [{'requestKey': key, 'providerRequestKey': bad['vercelRequestKey'], 'status': 500, 'stage': 'japanese_g2p_digit_assertion', 'evidence': str(HERE / 'tts500-cause-review.json')}],
          'newQuickreadDisconnectRecords': qr_new, 'newObservedDirectVersion': None,
          'newCloneReferenceValidationRejections': clone_detail['referenceRejections'],
          'unattributedModelHTTP404': cause['unattributedModelHTTP404'],
          'proxyPendingBoundaryGroups': pending, 'resolvedPriorProxyBoundaryGroups': carryover,
          'actualBackendWindowMixedVersions': True, 'originalFrozenDirectVersion24hCanBeCertified': False,
          'oldWindowStillArchived': state['oldWindowArchivePath'], 'oldWindowCollectedAgain': False,
          'latencyWatch': latency, 'cnLatencyWatch': cn_watch,
          'limitations': ['Current500 is counted once at Global, not3 or6 independent failures. HTTP transport completion includes error bodies.',
                          'No raw content was read. The numeric-token assertion condition is proven, but exact characters, normalization trigger and caller identity are unknown.',
                          'The unattributed0ms model404 has no request-route or TTS-generation association; preserve it without inventing a caller.',
                          'Voice creation reference rejection is separate from existing-voice speech generation; classifier accuracy and HTTP delivery remain unverified.',
                          'CN clone and all-request QuickRead/clone delivery coverage remain incomplete. Ready task files are not a complete HTTP ledger.',
                          'CN R134 remains undeployed. Regional metadata has no mismatch but does not certify every physical cross-border hop.',
                          'All known older no_response,400,502,504,499 and cancelled events remain preserved; no successful request cancels a failure.'],
          'sources': [ref(p) for p in sources]}
save('heartbeat-review.json', review)

state.update({'recordedAtUtc': NOW, 'lastDecision': 'NOTIFY', 'lastDecisionReason': reason,
              'latestBackendVerdict': '存在异常', 'latestBackendServiceVerdicts': services,
              'latestBackendObservationReview': str(HERE / 'heartbeat-review.json'), 'latestObservationReview': str(HERE / 'heartbeat-review.json'),
              'latestSnapshotDirectory': 'observations/' + TAG, 'latestProxyWindowEndUTC': proxy['window']['endUTCExclusive'],
              'latestProxyWindowPath': str(proxy_path), 'latestVercelCore5xxCount': 1,
              'latestBackendSupplySnapshotPaths': [str(HERE / 'backend-supply' / f'{r}-backend-supply.json') for r in supply],
              'latestDirectVersionReadback': version, 'latestBackendLatencyWatch': str(HERE / 'latency-watch.json'),
              'latestCNBackendLatencyWatch': str(HERE / 'cn-latency-watch.json'),
              'latestReverseProxyGlobalAttribution': {'globalMatchedGroups': 2622, 'globalProxyTransportCompleteGroups': 2622,
                                                     'globalFailedApplicationRequests': 1, 'upstreamHTTP500Attempts': 3,
                                                     'directExactMatchedGroups': 913, 'remainingUnattributedGroups': 20,
                                                     'pendingBoundaryGroups': pending, 'reviewPath': str(HERE / 'vercel-proxy-join-summary.json')},
              'latestBackendPerformanceObservation': {'observedThroughUTC': proxy['window']['endUTCExclusive'],
                                                     'successfulRequestFinishP95Ms': 1540, 'proxyHeadersP95Ms': 1353.983,
                                                     'sustainedGlobalRecoveryEstablished': False,
                                                     'cnSlowProbeCompletionUTCs': [r['observedAtUTC'] for r in cn_watch['overTenSeconds']],
                                                     'cnServerSlowStageEstablished': False},
              'latestBackendCauseFindings': {'globalTts500RequestKey': key, 'phase': 'japanese_g2p_digit_assertion',
                                            'modelBackendCauseProven': True, 'rootConditionSourceLine': 355,
                                            'evidence': str(HERE / 'tts500-cause-review.json')},
              'latestCloneSupplyReview': str(HERE / 'clone-supply-review.json')})
for field, values in {
    'vercelCoreRequestKeys': [bad['vercelRequestKey']],
    'knownGlobalTts500ApplicationRequestKeys': [key],
    'knownModelFrontend500RequestKeys': [a['upstreamRequestKey'] for a in attempts],
    'knownUnattributedModelHTTP404RequestKeys': [extra_model[0]['requestKey']],
    'knownCNLongProbeSourceSha256': [r['sourceSha256'] for r in cn_watch['overTenSeconds']],
}.items():
    state[field] = list(dict.fromkeys(state.get(field, []) + values))
state.setdefault('knownCloneReferenceValidationRejections', []).extend(clone_detail['referenceRejections'])
(MON / 'notification-state.json').write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')
assert (MON / 'acceptance-state.json').read_bytes() == frozen
assert (OLD / 'acceptance-state.json').read_bytes() == old_state
assert (OLD / 'observations/notification-state.json').read_bytes() == old_notification
print(json.dumps({'globalStatuses': {'200': 2619, '500': 1}, 'cause': cause['confirmedCodeCondition'],
                  'attempts': 3, 'frontendAssertions': 6, 'cloneSpeechCompletions': 173,
                  'backendVerdict': '存在异常', 'decision': 'NOTIFY'}, ensure_ascii=False))
