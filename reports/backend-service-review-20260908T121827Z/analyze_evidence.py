"""Reproducible aggregation of sanitized, fixed-window backend evidence."""
from pathlib import Path
from collections import Counter
import json, hashlib

HERE = Path(__file__).resolve().parent
def read(name): return json.loads((HERE / name).read_text())
def save(name, value): (HERE / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')

d = read('direct-streaming.json')
p = read('proxy-day.json')
targets = {r['requestKey']: r for r in p['targetRequests']}
joins = Counter()
for r in d['non200Records']:
    outcomes = targets.get(r['key'], {}).get('outcomes', {})
    kind = ('missing' if not outcomes else 'cancel_and_complete_same_key'
            if 'cancelled' in outcomes and 'complete' in outcomes else
            'cancelled' if 'cancelled' in outcomes else 'complete')
    joins[kind] += 1
assert d['requests'] == 46521 and len(d['non200Records']) == 343
assert sum(joins.values()) == 343
assert joins == {'cancelled': 327, 'complete': 14, 'cancel_and_complete_same_key': 1, 'missing': 1}

versions = {}
for r in d['clientStatuses']:
    item = versions.setdefault((r['platform'], r['version']), Counter())
    item[r['status']] += r['count']
version_rows = []
for (platform, version), counts in sorted(versions.items()):
    total = sum(counts.values())
    version_rows.append({'platform': platform, 'version': version, 'requests': total,
        'http200': counts['200'], 'closedBeforeResponse': counts['no_response'],
        'closedPercent': round(100 * counts['no_response'] / total, 4)})

errors = {}
for name in ['vercel-hourly-5xx.json', 'vercel-hourly-4xx.json']:
    for r in read(name)['coreRecords']: errors[r['requestKey']] = r
for q in read('vercel-core-4xx-targeted.json')['queries']:
    for r in q['rows']:
        if r['path'] in {'/api/captioned_speech_partly', '/api/voice-clone/captioned-speech'}:
            errors.setdefault(r['key'], r)
assert Counter(r['status'] for r in errors.values()) == {500: 2, 429: 2}
vercel5xx = []
for q in read('vercel-error-platform-details.json')['queries']:
    for r in q['rows']:
        if r['status'] != 500 or r['path'] != '/api/captioned_speech_partly': continue
        finish = [e for l in r['logs'] for e in l['events'] if e['event'] == 'request_finished']
        assert len(finish) == 1 and finish[0]['status'] == 200
        vercel5xx.append({'requestKey': r['key'], 'atUTC': r['atUTC'],
            'recordedMethod': r['method'], 'httpStatus': r['status'], 'outerDurationMs': r['durationMs'],
            'platformErrorCode': r['platformMetadata']['errorCode'],
            'hasFunctionCrashed': r['platformMetadata']['hasFunctionCrashed'],
            'attachedPresetCompletionElapsedMs': finish[0]['elapsedMs'],
            'attachedPresetCompletionStatus': finish[0]['status'],
            'functionDurationsMs': [e['durationMs'] for e in r['platformMetadata']['functionEvents']]})

monitors = {region: read(f'monitor-{region}.json')['aggregate'] for region in ['us', 'cn']}
assert monitors['us']['supplyOkCycles'] == 278 and monitors['us']['cycles'] == 278
assert monitors['cn']['supplyOkCycles'] == 274 and monitors['cn']['cycles'] == 277
assert read('offline-error-classification.json')['passed'] == 5
for region in ['us', 'cn']:
    m = read(f'{region}-r135-full-model.json')
    assert m['identity']['verified'] and not m['failureEvents'] and m['unclassifiedEvents'] == 0

out = {
    'readOnly': True, 'productionModified': False, 'newProductionSynthesis': False,
    'window': {'startUTC': '2026-09-07T12:18:27Z', 'endUTCExclusive': '2026-09-08T12:18:27Z'},
    'direct': {'requests': d['requests'], 'statusCounts': d['statusCounts'],
        'closedPercent': round(100 * 343 / 46521, 4), 'versions': version_rows,
        'abortStageCounts': dict(Counter(r['abortStage'] for r in d['non200Records'])),
        'closedElapsedMs': {'min': min(r['elapsedMs'] for r in d['non200Records']),
            'max': max(r['elapsedMs'] for r in d['non200Records'])},
        'proxyJoinByDirectOccurrence': dict(joins), 'elapsedMs': d['elapsedMs']},
    'proxy': {'counts': p['counts'], 'timingsMs': p['stageTimingMilliseconds'],
        'identityAndCoverageVerified': p['identityAndCoverageVerified'],
        'boundaryCaveat': 'received and finished count events by their own timestamps; difference of one is not automatically a failed request'},
    'vercel': {'coreNon200': list(errors.values()), 'core500Details': vercel5xx,
        'http3xxCoreRecords': read('vercel-hourly-3xx.json')['coreRecords'],
        'fiveHundredPaginationComplete': read('vercel-hourly-5xx.json')['allShardsComplete'],
        'fourHundredPaginationComplete': read('vercel-hourly-4xx.json')['allShardsComplete'],
        'targetedCore4xxHasMore': [q['hasMoreRows'] for q in read('vercel-core-4xx-targeted.json')['queries']],
        'completeGlobalIngressDenominatorAvailable': False,
        'limitations': ['Runtime request logs are not full aggregate metrics or verified ingestion.',
            'Vercel records may age out during collection; early fixed-window shards are preserved.',
            'GET metadata conflicts with attached POST-only synthesis handler events; do not infer a deliberate unsupported GET or a model timeout.']},
    'cnIngress': read('cn-details-aliases.json')['ingress']['counts'],
    'monitors': {region: {'cycles': m['cycles'], 'healthy': m['supplyOkCycles'],
        'healthyPercent': round(100 * m['supplyOkCycles'] / m['cycles'], 4),
        'failureCodeCounts': m['failureCodeCounts'], 'regionMismatch': m['regionMismatchCycles'],
        'elapsedMs': m['probeElapsedMs']} for region, m in monitors.items()},
    'confirmedClassificationGaps': read('offline-error-classification.json')['results'],
    'unresolved': ['Initial caller reason for 343 Direct downstream closures and CN 12 HTTP 499',
        'Exact Vercel internal fault behind 2 outer HTTP 500',
        'Business quota versus technical worker-busy origin of 2 HTTP 429',
        'Original exception for 3 CN probe failures',
        'Body truncation/abort versus malformed JSON for CN DeepSeek first-block failure',
        'Complete QuickRead ingress HTTP ledger and complete 24-hour clone model event retention'],
    'aggregateChecksPassed': True,
}
save('summary.json', out)
print(json.dumps({'directRequests': 46521, 'directClosed': 343,
    'globalCoreHttp500': 2, 'globalCoreHttp429': 2, 'cnProbeFailures': 3,
    'checksPassed': True}))
