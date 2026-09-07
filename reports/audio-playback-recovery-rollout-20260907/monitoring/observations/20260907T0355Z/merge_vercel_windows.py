"""Combine two adjacent, already sanitized log windows; retain both originals."""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
paths = [ROOT / f'vercel-preset-model-r134-20260907T0355Z-part{i}-retry1.json' for i in (1, 2)]
parts = [json.loads(path.read_text()) for path in paths]
schema = 'castreader.vercel-preset-event-window.v1'
deployment = 'dpl_EYb2UAVcLJvk7qaYchgmPhYoHYC5'
start, middle, end = '2026-09-07T02:55:18.766Z', '2026-09-07T03:25:18.927Z', '2026-09-07T03:55:19.088Z'
expected = [(start, middle), (middle, end)]
def utc(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    assert parsed.tzinfo is not None and parsed.utcoffset().total_seconds() == 0
    return parsed

issues, requests = [], []
parser_counts = Counter()
for index, (part, bounds) in enumerate(zip(parts, expected), 1):
    assert part['schema'] == schema and part['expectedDeployment'] == deployment
    assert set(part['window']) == {'requestStartInclusiveUTC', 'requestStartExclusiveUTC'}
    assert utc(part['window']['requestStartInclusiveUTC']) == utc(bounds[0])
    assert utc(part['window']['requestStartExclusiveUTC']) == utc(bounds[1])
    assert part['readOnly'] and not part['productionModified'] and not part['synthesisStarted']
    coverage = part['coverage']
    if not coverage['completeForReturnedRequestCohort']:
        issues.append(f'part{index}_incomplete')
    issues += [f'part{index}:{issue}' for issue in coverage.get('issues', [])]
    parser_counts.update(coverage.get('parserCounts', {}))
    for request in part.get('requests', []):
        assert utc(bounds[0]) <= utc(request['requestStartUTC']) < utc(bounds[1])
        requests.append(request)
assert len({request['vercelRequestKey'] for request in requests}) == len(requests)
events = [event for request in requests for event in request['events']]
report = {
    'schema': schema, 'readOnly': True, 'productionModified': False,
    'synthesisStarted': False, 'rawContentExported': False, 'expectedDeployment': deployment,
    'window': {'requestStartInclusiveUTC': start, 'requestStartExclusiveUTC': end},
    'query': {'production': True, 'deploymentPinned': True, 'search': 'tts-preset', 'adjacentShards': 2},
    'collectionStartedUTC': min(part['collectionStartedUTC'] for part in parts),
    'collectedAtUTC': max(part['collectedAtUTC'] for part in parts),
    'mergedAtUTC': datetime.now(timezone.utc).isoformat(),
    'coverage': {
        'pagesRead': sum(part['coverage'].get('pagesRead', 0) for part in parts),
        'providerHasMoreRows': any(part['coverage'].get('providerHasMoreRows', True) for part in parts),
        'issues': issues, 'completeForReturnedRequestCohort': not issues,
        'paginationMode': 'two_adjacent_half_open_windows_with_independent_backward_pagination',
        'tlsCertificateAndHostnameVerified': all(part['coverage'].get('tlsCertificateAndHostnameVerified') for part in parts),
        'providerRowsRead': sum(part['coverage'].get('providerRowsRead', 0) for part in parts),
        'uniqueProviderRequests': len(requests), 'parserCounts': dict(parser_counts),
        'requestsMissingStartOrFinish': sum(not row['hasRequestStart'] or not row['hasRequestFinished'] for row in requests),
        'structuredEventsObserved': bool(events), 'ingestionCompletenessVerified': False,
    },
    'requests': sorted(requests, key=lambda row: (row['requestStartUTC'], row['vercelRequestKey'])),
    'counts': {
        'events': dict(Counter(event['event'] for event in events)),
        'failureCodes': dict(Counter(event['code'] for event in events if 'code' in event)),
        'terminalCodes': dict(Counter(event['code'] for event in events if event['event'] == 'request_finished' and 'code' in event)),
        'attemptStarts': dict(Counter(str(event['attempt']) for event in events if event['event'] == 'attempt_start')),
    },
    'sourceSnapshots': [{'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in paths],
    'limitations': list(dict.fromkeys(value for part in parts for value in part['limitations'])) + [
        'The two original request-start windows are exactly adjacent; no inference about provider ingestion completeness is added.',
    ],
}
output = ROOT / 'vercel-preset-model-r134-20260907T0355Z.json'
with output.open('x') as stream:
    json.dump(report, stream, indent=2)
    stream.write('\n')
print(json.dumps({'output': str(output), 'coverage': report['coverage'], 'counts': report['counts']}))
