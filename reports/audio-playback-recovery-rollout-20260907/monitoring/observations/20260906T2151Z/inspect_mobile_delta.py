"""Read-only fixed-field joins for the new failure and slow first-audio sample."""
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('reviewed_mobile_projection',
    HERE.parent / '20260906T1949Z/inspect_mobile_new_failures.py')
mobile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mobile)
KNOWN_FAILURES = {'14826f73872753709911', '75181424100861e4d767'}


def main():
    output = HERE / 'mobile-new-failures.json'
    assert not output.exists(), 'preserve_existing_evidence'
    snapshot = json.loads((HERE / 'latest-acceptance.json').read_text())
    assert snapshot['generatedAtUtc'] == '2026-09-06T21:52:41.458505Z'
    start = snapshot['window']['startInclusive']
    end = snapshot['window']['collectedThroughExclusive']
    context_end = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    state = json.loads((mobile.MONITOR / 'acceptance-state.json').read_text())
    ref, credential = mobile.mobile_credentials(state)
    query_count = 0

    def read(filters):
        nonlocal query_count
        rows, headers = mobile.postgrest_get(ref, credential, [('select', mobile.SELECT), *filters,
            ('order', 'received_at.asc,event_id.asc'), ('limit', '1000')], 25)
        query_count += 1
        total = headers.get('content-range', '').rsplit('/', 1)[-1]
        assert total.isdigit() and int(total) == len(rows), 'bounded_query_incomplete'
        assert len({row['event_id'] for row in rows}) == len(rows), 'duplicate_rows'
        return rows

    rows = read([('event_name', 'in.(read_end,explain_end,read_first_audio,explain_first_block)'),
        ('properties->>environment', 'eq.production'),
        ('received_at', 'gte.' + start), ('received_at', 'lt.' + end)])
    failures = [row for row in rows if row.get('result') == 'failed']
    failure_keys = {mobile.key(row['event_id']) for row in failures}
    assert len(failures) == snapshot['sources']['mobile']['aggregate']['technicalFailureEvents'] == 3
    assert KNOWN_FAILURES.issubset(failure_keys), 'known_failure_missing'
    new_failures = [row for row in failures if mobile.key(row['event_id']) not in KNOWN_FAILURES]
    slow = [row for row in rows if row.get('event_name') in ('read_first_audio', 'explain_first_block')
            and (mobile.number(row.get('latencyMs')) or 0) >= 30_000]
    maximum = snapshot['sources']['mobile']['aggregate']['firstOutputLatencyMs']['android']['max']
    assert maximum == 39719 and any(mobile.number(row.get('latencyMs')) == maximum for row in slow)
    cache = {}

    def join(target):
        chains = []
        related_by_key = {}
        for alias, property_name in (('readSession', 'read_session_id'),
                                     ('explainSession', 'explain_session_id'),
                                     ('contentSession', 'content_session_id')):
            value = target.get(alias)
            if not value:
                continue
            cache_key = (alias, mobile.key(value), mobile.key(target['analytics_anonymous_id']))
            if cache_key not in cache:
                cache[cache_key] = read([('properties->>' + property_name, 'eq.' + value),
                    ('analytics_anonymous_id', 'eq.' + target['analytics_anonymous_id']),
                    ('event_name', 'in.(' + ','.join(mobile.EVENTS) + ')'),
                    ('received_at', 'gte.2026-09-05T00:00:00Z'), ('received_at', 'lt.' + context_end)])
            safe_rows = [mobile.safe(row) for row in cache[cache_key]]
            chains.append({'type': alias, 'sessionKey': mobile.key(value),
                           'completeInsideBounds': True, 'events': safe_rows})
            related_by_key.update({row['eventKey']: row for row in safe_rows})
        ordered = sorted(related_by_key.values(), key=lambda row:
            (row['occurredAtUtc'] or row['receivedAtUtc'], row['eventKey']))
        return {'target': mobile.safe(target), 'sessionChains': chains,
                'chronologyByClientOccurredTime': ordered}

    result = {'schema': 'castreader.mobile-failure-and-latency-delta.v1',
        'readOnly': True, 'productionModified': False, 'synthesisStarted': False,
        'codeModified': False, 'notificationStateModified': False,
        'rawContentQueried': False, 'rawIdentityExported': False, 'arbitraryMetadataQueried': False,
        'snapshotGeneratedAtUtc': snapshot['generatedAtUtc'],
        'queryStartedAtUtc': context_end,
        'failureWindow': {'startInclusive': start, 'endExclusive': end},
        'contextWindow': {'startInclusive': '2026-09-05T00:00:00Z', 'endExclusive': context_end},
        'failureDedup': {'knownKeys': sorted(KNOWN_FAILURES), 'observedKeys': sorted(failure_keys),
                        'newKeys': sorted(failure_keys - KNOWN_FAILURES),
                        'missingKnownKeys': sorted(KNOWN_FAILURES - failure_keys)},
        'currentWindowFailures': [mobile.safe(row) for row in failures],
        'newFailures': [join(row) for row in new_failures],
        'slowFirstOutputThresholdMs': 30_000, 'slowFirstOutputSamples': [join(row) for row in slow],
        'limitations': [
            'Client-reported occurred time and server received time differ; temporal proximity alone cannot establish the same upstream request.',
            'Only the explicitly selected request_id/requestId/trace_id aliases are inspected; missing values cannot establish cross-system request identity.',
            'The snapshot firstOutputLatencyMs metric includes read_first_audio and explain_first_block; preserve the actual event type when attributing a slow sample.',
            'Session chains are bounded to the reported context window and contain no source text, audio, account identity or arbitrary metadata.',
        ]}
    result.update(queryCount=query_count, completeInsideBounds=True,
                  queryCompletedAtUtc=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
    output.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    print(json.dumps({'failureDedup': result['failureDedup'],
        'newFailures': [{'target': entry['target'], 'chronology': entry['chronologyByClientOccurredTime']}
                        for entry in result['newFailures']],
        'slowFirstOutput': [{'target': entry['target'], 'chronology': entry['chronologyByClientOccurredTime']}
                           for entry in result['slowFirstOutputSamples']]}, sort_keys=True))


if __name__ == '__main__':
    main()
