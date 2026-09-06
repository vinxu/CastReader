"""Fixed-window read-only incident deduplication; raw identifiers stay in memory."""
from pathlib import Path
import hashlib
import json
import sys

HERE = Path(__file__).resolve().parent
MONITOR = HERE.parents[1]
sys.path.insert(0, str(MONITOR))
from collect_acceptance import mobile_credentials, postgrest_get
from acceptance_core import canonical_mobile_row, is_technical_failure, safe_code, safe_version, number

state = json.loads((MONITOR / 'acceptance-state.json').read_text())
report = json.loads((HERE / 'acceptance.json').read_text())
known = json.loads((HERE / 'notification-before.json').read_text())
ref, credential = mobile_credentials(state)
hash_id = lambda value: hashlib.sha256(value.encode()).hexdigest()[:20] if isinstance(value, str) else None
start = state['window']['startUtc']
end = report['window']['collectedThroughExclusive']

def safe(row):
    p = row.get('properties') or {}
    result = {
        'eventKey': hash_id(row.get('event_id')),
        'event': row.get('event_name'),
        'platform': row.get('client_platform'),
        'receivedAtUtc': row.get('received_at'),
        'occurredAtUtc': p.get('occurred_at'),
    }
    for field in ['client_version', 'client_build', 'result', 'endReason', 'errorCode', 'errorStage', 'contentSource', 'contentFormat', 'language', 'voiceId', 'resume', 'client_service_route', 'ingress_service_route']:
        if field in p:
            result[field] = p[field] if isinstance(p[field], (int, float, bool)) else safe_code(p[field])
    for field in ['playbackSeconds', 'latencyMs']:
        if field in p:
            result[field] = number(p[field])
    result['client_version'] = safe_version(p.get('client_version'))
    if str(p.get('client_build', '')).isdigit():
        result['client_build'] = int(p['client_build'])
    return result

rows, headers = postgrest_get(ref, credential, [
    ('select', 'event_id,event_name,client_platform,received_at,properties'),
    ('event_name', 'in.(read_end,explain_end)'),
    ('received_at', 'gte.' + start), ('received_at', 'lt.' + end),
    ('order', 'received_at.asc'), ('limit', '1000'),
], 25)
expected = headers.get('content-range', '').rsplit('/', 1)[-1]
complete = expected.isdigit() and int(expected) == len(rows)
assert complete, 'end_event_read_incomplete'
failures, new = [], []
for row in rows:
    p = row.get('properties') or {}
    canonical = canonical_mobile_row({**row, **p})
    if not canonical or canonical['environment'] != 'production' or not is_technical_failure(canonical):
        continue
    summary = safe(row)
    failures.append(summary)
    if summary['eventKey'] in known['alertEventKeys']:
        continue
    entry = {'failure': summary, 'relatedSessionEvents': []}
    field = 'read_session_id' if row['event_name'] == 'read_end' else 'explain_session_id'
    session = p.get(field)
    if session:
        related, related_headers = postgrest_get(ref, credential, [
            ('select', 'event_id,event_name,client_platform,received_at,properties'),
            ('properties->>' + field, 'eq.' + session),
            ('received_at', 'gte.2026-09-05T00:00:00Z'), ('received_at', 'lt.' + end),
            ('order', 'received_at.asc'), ('limit', '1000'),
        ], 25)
        total = related_headers.get('content-range', '').rsplit('/', 1)[-1]
        entry['relatedReadComplete'] = total.isdigit() and int(total) == len(related)
        entry['relatedSessionEvents'] = [safe(r) for r in related]
    new.append(entry)
output = {
    'readOnly': True, 'rawContentExported': False, 'completeRead': complete,
    'selectedEndRows': len(rows), 'technicalFailures': failures,
    'newEventKeys': [v['failure']['eventKey'] for v in new], 'newIncidents': new,
    'counterMatchesSnapshot': len(failures) == report['sources']['mobile']['aggregate']['technicalFailureEvents'],
}
(HERE / 'client-failure-dedup.json').write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'failureCount': len(failures), 'newIncidents': new, 'completeRead': complete, 'counterMatchesSnapshot': output['counterMatchesSnapshot']}, ensure_ascii=False))
