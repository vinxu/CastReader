"""Fixed-window, read-only mobile incident join; no raw identity or content export."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
REPORTS = Path('/Users/xuxuheng/Documents/CastReader/reports')
MONITOR = REPORTS / 'backend-audio-iteration-20260906/monitoring'
sys.path.insert(0, str(MONITOR))
os.environ['SSL_CERT_FILE'] = '/etc/ssl/cert.pem'
from collect_acceptance import mobile_credentials, postgrest_get
from acceptance_core import safe_code, safe_version, safe_platform, safe_route, safe_source, safe_language, number, parse_utc, voice_family

EVENTS = ('read_start', 'read_first_audio', 'read_milestone', 'read_end',
          'explain_start', 'explain_first_block', 'explain_milestone', 'explain_end')
ALIASES = {
    'environment': 'environment', 'occurredAt': 'occurred_at',
    'clientVersion': 'client_version', 'clientBuild': 'client_build',
    'result': 'result', 'endReason': 'endReason', 'errorCode': 'errorCode',
    'errorStage': 'errorStage', 'contentSource': 'contentSource',
    'contentFormat': 'contentFormat', 'language': 'language', 'voiceId': 'voiceId',
    'latencyMs': 'latencyMs', 'playbackSeconds': 'playbackSeconds',
    'durationSec': 'duration_sec', 'completionBucket': 'completionBucket',
    'clientRoute': 'client_service_route', 'ingressRoute': 'ingress_service_route',
    'readSession': 'read_session_id', 'explainSession': 'explain_session_id',
    'contentSession': 'content_session_id', 'requestId': 'request_id',
    'camelRequestId': 'requestId', 'traceId': 'trace_id', 'httpStatus': 'httpStatus',
    'resume': 'resume',
}
SELECT = ','.join(['event_id', 'event_name', 'analytics_anonymous_id',
                   'client_platform', 'received_at'] +
                  [alias + ':properties->>' + prop for alias, prop in ALIASES.items()])


def key(value):
    return hashlib.sha256(value.encode()).hexdigest()[:20] if isinstance(value, str) and value else None


def timestamp(value):
    try:
        return parse_utc(value).isoformat().replace('+00:00', 'Z')
    except (TypeError, ValueError, AttributeError):
        return None


def safe(row):
    result = {
        'eventKey': key(row.get('event_id')), 'deviceKey': key(row.get('analytics_anonymous_id')),
        'event': row['event_name'] if row.get('event_name') in EVENTS else 'other',
        'platform': safe_platform(row.get('client_platform')),
        'receivedAtUtc': timestamp(row.get('received_at')),
        'occurredAtUtc': timestamp(row.get('occurredAt')),
        'clientVersion': safe_version(row.get('clientVersion')),
        'clientBuild': number(row.get('clientBuild')),
        'contentSource': safe_source(row.get('contentSource')),
        'language': safe_language(row.get('language')),
        'voiceFamily': voice_family(row.get('voiceId')),
        'clientRoute': safe_route(row.get('clientRoute')),
        'ingressRoute': safe_route(row.get('ingressRoute')),
    }
    for name in ('environment', 'result', 'endReason', 'errorCode', 'errorStage',
                 'contentFormat', 'completionBucket'):
        if row.get(name) is not None:
            result[name] = safe_code(row[name])
    for name in ('latencyMs', 'playbackSeconds', 'durationSec', 'httpStatus'):
        if row.get(name) is not None:
            result[name] = number(row[name])
    for name in ('readSession', 'explainSession', 'contentSession', 'requestId', 'camelRequestId', 'traceId'):
        if row.get(name):
            result[name + 'Key'] = key(row[name])
    if row.get('resume') in ('true', 'false'):
        result['resume'] = row['resume'] == 'true'
    if result['occurredAtUtc'] and result['receivedAtUtc']:
        result['receiptLagSeconds'] = round((parse_utc(result['receivedAtUtc']) - parse_utc(result['occurredAtUtc'])).total_seconds(), 6)
    return result


def main():
    output = HERE / 'mobile-new-failures.json'
    assert not output.exists(), 'preserve_existing_evidence'
    snapshot = json.loads((HERE / 'latest-acceptance.json').read_text())
    assert snapshot['generatedAtUtc'] == '2026-09-06T19:50:40.854045Z'
    start = snapshot['window']['startInclusive']
    end = snapshot['window']['collectedThroughExclusive']
    context_end = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    state = json.loads((MONITOR / 'acceptance-state.json').read_text())
    ref, credential = mobile_credentials(state)
    query_count = 0

    def read(filters):
        nonlocal query_count
        rows, headers = postgrest_get(ref, credential, [('select', SELECT), *filters,
            ('order', 'received_at.asc,event_id.asc'), ('limit', '1000')], 25)
        query_count += 1
        total = headers.get('content-range', '').rsplit('/', 1)[-1]
        assert total.isdigit() and int(total) == len(rows), 'bounded_query_incomplete'
        assert len({row.get('event_id') for row in rows}) == len(rows), 'duplicate_event_rows'
        return rows

    filters = [('event_name', 'eq.read_end'), ('client_platform', 'eq.android'),
        ('properties->>environment', 'eq.production'), ('properties->>client_version', 'eq.1.0.46'),
        ('properties->>result', 'eq.failed'), ('properties->>endReason', 'eq.tts_failed'),
        ('properties->>errorCode', 'eq.generation_failed'), ('properties->>errorStage', 'eq.tts'),
        ('received_at', 'gte.' + start), ('received_at', 'lt.' + end)]
    failures = read(filters)
    assert len(failures) == 2, 'target_failure_count_differs_from_snapshot'
    incidents = []
    for failure in failures:
        entry = {'failure': safe(failure), 'sessionChains': []}
        related_by_id = {}
        for alias, prop in (('readSession', 'read_session_id'), ('contentSession', 'content_session_id')):
            session = failure.get(alias)
            if not session:
                continue
            related = read([('properties->>' + prop, 'eq.' + session),
                ('analytics_anonymous_id', 'eq.' + failure['analytics_anonymous_id']),
                ('event_name', 'in.(' + ','.join(EVENTS) + ')'),
                ('received_at', 'gte.2026-09-05T00:00:00Z'), ('received_at', 'lt.' + context_end)])
            entry['sessionChains'].append({'type': alias, 'sessionKey': key(session),
                'completeInsideBounds': True, 'eventCount': len(related), 'events': [safe(row) for row in related]})
            for row in related:
                related_by_id[row['event_id']] = row
        read_session = failure.get('readSession')
        paired = [safe(row) for row in related_by_id.values()
                  if read_session and row.get('readSession') == read_session]
        paired.sort(key=lambda row: (row['receivedAtUtc'] or '', row['eventKey'] or ''))
        entry['pairedReadStarts'] = [row for row in paired if row['event'] == 'read_start']
        entry['pairedFirstAudio'] = [row for row in paired if row['event'] == 'read_first_audio']
        entry['sameReadSessionEventsBeforeFailure'] = [row['eventKey'] for row in paired
            if row['receivedAtUtc'] < entry['failure']['receivedAtUtc']]
        entry['sameReadSessionEventsAfterFailure'] = [row['eventKey'] for row in paired
            if row['receivedAtUtc'] > entry['failure']['receivedAtUtc']]
        incidents.append(entry)
    result = {
        'schema': 'castreader.mobile-new-failures.v1', 'readOnly': True,
        'productionModified': False, 'rawContentQueried': False, 'rawIdentityExported': False,
        'arbitraryMetadataQueried': False, 'synthesisStarted': False,
        'queriedAtUtc': context_end, 'completedAtUtc': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'snapshotGeneratedAtUtc': snapshot['generatedAtUtc'],
        'failureWindow': {'startInclusive': start, 'endExclusive': end},
        'sessionContextWindow': {'startInclusive': '2026-09-05T00:00:00Z', 'endExclusive': context_end},
        'queryCount': query_count, 'completeInsideBounds': True,
        'failureCount': len(incidents), 'snapshotTechnicalFailureCount': snapshot['sources']['mobile']['aggregate']['technicalFailureEvents'],
        'incidents': incidents,
        'limitations': [
            'Occurred time is client-supplied; received time is server-clocked. Neither supplies a TTS request timestamp.',
            'Near-time gateway events are not a proven request match; only explicit correlation-key equality could establish that.',
            'Hash keys are anonymous correlation handles, not verified people. Only selected session events inside the stated bounds were joined.',
            'Only fixed selected request/trace aliases were queried; missing values do not prove all systems lack correlation data.',
        ],
    }
    output.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    print(json.dumps({'failureCount': len(incidents), 'queryCount': query_count,
        'incidents': [{'failure': entry['failure'], 'readStarts': entry['pairedReadStarts'],
                       'firstAudio': entry['pairedFirstAudio'],
                       'eventsAfterFailure': entry['sameReadSessionEventsAfterFailure']}
                      for entry in incidents]}, sort_keys=True))


if __name__ == '__main__':
    main()
