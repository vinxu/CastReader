"""Fixed-projection, read-only failure delta and session joins for 2252Z."""
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('reviewed_mobile_projection',
    HERE.parent / '20260906T1949Z/inspect_mobile_new_failures.py')
mobile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mobile)
KNOWN = {'14826f73872753709911', '75181424100861e4d767', 'a6fbedfbaf4a619cc70c'}


def main():
    output = HERE / 'mobile-new-failures.json'
    assert not output.exists(), 'preserve_existing_evidence'
    snapshot = json.loads((HERE / 'latest-acceptance.json').read_text())
    assert snapshot['generatedAtUtc'] == '2026-09-06T22:54:02.578098Z'
    start = snapshot['window']['startInclusive']
    end = snapshot['window']['collectedThroughExclusive']
    context_end = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    state = json.loads((mobile.MONITOR / 'acceptance-state.json').read_text())
    ref, credential = mobile.mobile_credentials(state)
    query_count = 0

    def read(filters):
        nonlocal query_count
        rows, headers = mobile.postgrest_get(ref, credential,
            [('select', mobile.SELECT), *filters, ('order', 'received_at.asc,event_id.asc'), ('limit', '1000')], 25)
        query_count += 1
        total = headers.get('content-range', '').rsplit('/', 1)[-1]
        assert total.isdigit() and int(total) == len(rows), 'bounded_query_incomplete'
        assert len({row['event_id'] for row in rows}) == len(rows), 'duplicate_rows'
        return rows

    rows = read([('event_name', 'in.(read_end,explain_end)'),
        ('properties->>environment', 'eq.production'), ('properties->>result', 'eq.failed'),
        ('received_at', 'gte.' + start), ('received_at', 'lt.' + end)])
    observed = {mobile.key(row['event_id']) for row in rows}
    assert len(rows) == snapshot['sources']['mobile']['aggregate']['technicalFailureEvents'] == 4
    assert KNOWN.issubset(observed), 'known_failure_missing'
    incidents = []
    for target in rows:
        if mobile.key(target['event_id']) in KNOWN:
            continue
        chains, unique = [], {}
        for alias, property_name in (('readSession', 'read_session_id'),
                                     ('explainSession', 'explain_session_id'),
                                     ('contentSession', 'content_session_id')):
            value = target.get(alias)
            if not value:
                continue
            related = read([('properties->>' + property_name, 'eq.' + value),
                ('analytics_anonymous_id', 'eq.' + target['analytics_anonymous_id']),
                ('event_name', 'in.(' + ','.join(mobile.EVENTS) + ')'),
                ('received_at', 'gte.2026-09-05T00:00:00Z'), ('received_at', 'lt.' + context_end)])
            safe_rows = [mobile.safe(row) for row in related]
            chains.append({'type': alias, 'sessionKey': mobile.key(value),
                           'completeInsideBounds': True, 'events': safe_rows})
            unique.update({row['eventKey']: row for row in safe_rows})
        incidents.append({'failure': mobile.safe(target), 'sessionChains': chains,
            'chronologyByClientOccurredTime': sorted(unique.values(), key=lambda row:
                (row['occurredAtUtc'] or row['receivedAtUtc'], row['eventKey']))})
    result = {'schema': 'castreader.mobile-failure-delta.v1', 'readOnly': True,
        'productionModified': False, 'codeModified': False, 'notificationStateModified': False,
        'synthesisStarted': False, 'rawContentQueried': False, 'rawIdentityExported': False,
        'arbitraryMetadataQueried': False, 'snapshotGeneratedAtUtc': snapshot['generatedAtUtc'],
        'failureWindow': {'startInclusive': start, 'endExclusive': end},
        'sessionContextWindow': {'startInclusive': '2026-09-05T00:00:00Z', 'endExclusive': context_end},
        'queryStartedAtUtc': context_end,
        'queryCompletedAtUtc': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'queryCount': query_count, 'completeInsideBounds': True,
        'failureDedup': {'knownKeys': sorted(KNOWN), 'observedKeys': sorted(observed),
                        'newKeys': sorted(observed - KNOWN), 'missingKnownKeys': sorted(KNOWN - observed)},
        'currentWindowFailures': [mobile.safe(row) for row in rows], 'newIncidents': incidents,
        'limitations': [
            'Client occurred time and server received time have different clocks; no exact request attribution can be inferred from time proximity.',
            'Only fixed request_id/requestId/trace_id aliases are inspected; missing values do not prove all services lack correlation data.',
            'Session context is bounded; absence of later events is not proof that the user never recovered.',
            'A server 200 response cannot establish whether page advancement or client playback succeeded.',
        ]}
    output.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    print(json.dumps({'failureDedup': result['failureDedup'], 'incidents': [
        {'failure': entry['failure'], 'chronology': entry['chronologyByClientOccurredTime']}
        for entry in incidents]}, sort_keys=True))


if __name__ == '__main__':
    main()
