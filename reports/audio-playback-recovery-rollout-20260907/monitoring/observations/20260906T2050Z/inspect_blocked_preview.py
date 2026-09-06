"""Read only fixed mobile projections and frozen iOS release code for one gate."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = Path('/Users/xuxuheng/Documents/CastReader')
BASELINE = 'e3bbe903c0bed886a53b3b0ba2c8240c4fe6b9d6'
previous = HERE.parent / '20260906T1949Z/inspect_mobile_new_failures.py'
spec = importlib.util.spec_from_file_location('reviewed_mobile_projection', previous)
mobile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mobile)
KNOWN_FAILURES = {'14826f73872753709911', '75181424100861e4d767'}


def main():
    output = HERE / 'blocked-preview-review.json'
    assert not output.exists(), 'preserve_existing_review'
    snapshot = json.loads((HERE / 'latest-acceptance.json').read_text())
    assert snapshot['generatedAtUtc'] == '2026-09-06T20:51:42.476216Z'
    start = snapshot['window']['startInclusive']
    end = snapshot['window']['collectedThroughExclusive']
    state = json.loads((mobile.MONITOR / 'acceptance-state.json').read_text())
    ref, credential = mobile.mobile_credentials(state)
    query_count = 0

    def read(filters):
        nonlocal query_count
        rows, headers = mobile.postgrest_get(ref, credential, [('select', mobile.SELECT), *filters,
            ('order', 'received_at.asc,event_id.asc'), ('limit', '1000')], 25)
        query_count += 1
        total = headers.get('content-range', '').rsplit('/', 1)[-1]
        assert total.isdigit() and int(total) == len(rows), 'bounded_read_incomplete'
        return rows

    rows = read([('event_name', 'in.(read_end,explain_end)'),
        ('properties->>environment', 'eq.production'), ('properties->>result', 'in.(failed,blocked)'),
        ('received_at', 'gte.' + start), ('received_at', 'lt.' + end)])
    failures = [row for row in rows if row.get('result') == 'failed']
    failure_keys = {mobile.key(row['event_id']) for row in failures}
    blocked = [row for row in rows if row.get('endReason') == 'growth_first_value_preview']
    assert len(blocked) == 1, 'preview_event_count_changed'
    target = blocked[0]
    chains = []
    for alias, property_name in (('readSession', 'read_session_id'), ('contentSession', 'content_session_id')):
        value = target.get(alias)
        if value:
            related = read([('properties->>' + property_name, 'eq.' + value),
                ('analytics_anonymous_id', 'eq.' + target['analytics_anonymous_id']),
                ('event_name', 'in.(' + ','.join(mobile.EVENTS) + ')'),
                ('received_at', 'gte.2026-09-05T00:00:00Z'), ('received_at', 'lt.' + end)])
            chains.append({'type': alias, 'sessionKey': mobile.key(value),
                'completeInsideBounds': True, 'events': [mobile.safe(row) for row in related]})
    evidence = []
    for path, lines, finding in [
        ('CastReader.xcodeproj/project.pbxproj', [1690, 1707], 'Frozen baseline identifies iOS 1.2.33/build53.'),
        ('CastReader/Services/GrowthLoopConversionCoordinator.swift', [61, 62, 77, 135, 147, 312, 317, 327, 335, 478, 505],
         'An eligible, enabled server-assigned US growth policy plus US storefront, non-Pro status and supported source intentionally claims a paywall after cumulative 300-second preview at a paragraph boundary; an already-presented wall is reclaimed on continue. Progress is persisted, not reset for every read session.'),
        ('CastReader/ViewModels/ReadAloudViewModel.swift', [2691, 2702, 3364, 3371, 3444, 3451],
         'The three production emission sites explicitly report result blocked / growth_first_value_preview and stop advancing or pause, without reporting a TTS/player error.'),
        ('CastReader/Views/Paywall/PaywallView.swift', [343], 'The paywall trigger maps to listen_300s.'),
        ('CastReaderTests/GrowthLoopProductTests.swift', [49, 73, 152, 156, 163],
         'Frozen tests specify assignment gating and paragraph-boundary/repeated-continue behavior; tests were read, not executed during this heartbeat.'),
        ('docs/US-GB-增长闭环-下一版本产品与数据迭代计划.md', [155, 168, 181],
         'Existing product plan explicitly defines a five-minute preview and paragraph-boundary paywall; this is product intent, with shipped source providing implementation evidence.'),
    ]:
        raw = subprocess.check_output(['git', 'show', BASELINE + ':' + path], cwd=REPO)
        evidence.append({'commit': BASELINE, 'path': path, 'lines': lines,
                         'sourceSha256': hashlib.sha256(raw).hexdigest(), 'finding': finding})
    result = {
        'schema': 'castreader.blocked-preview-review.v1',
        'reviewedAtUtc': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'readOnly': True, 'productionModified': False, 'codeModified': False,
        'synthesisStarted': False, 'notificationStateModified': False,
        'rawContentQueried': False, 'rawIdentityExported': False, 'arbitraryMetadataQueried': False,
        'frozenIOSBaseline': BASELINE, 'snapshotGeneratedAtUtc': snapshot['generatedAtUtc'],
        'queryCount': query_count, 'completeInsideBounds': True,
        'failureWindow': {'startInclusive': start, 'endExclusive': end},
        'contextWindow': {'startInclusive': '2026-09-05T00:00:00Z', 'endExclusive': end},
        'blockedEvent': mobile.safe(target), 'sessionChains': chains,
        'currentWindowFailures': [mobile.safe(row) for row in failures],
        'failureKeyDedup': {'knownKeys': sorted(KNOWN_FAILURES), 'observedKeys': sorted(failure_keys),
            'newKeys': sorted(failure_keys - KNOWN_FAILURES), 'missingKnownKeys': sorted(KNOWN_FAILURES - failure_keys),
            'exactlySameEvents': failure_keys == KNOWN_FAILURES},
        'classification': 'defined_business_preview_paywall',
        'quotaClassification': 'other_business_block_not_listen_quota',
        'newTechnicalIssueEstablishedByThisEvent': False,
        'technicalFailureNotificationRecommendedForThisEvent': False,
        'sourceEvidence': evidence,
        'limitations': [
            'The telemetry identifies the intentional client policy branch; it does not independently audit the device storefront, server assignment, Pro entitlement or persisted preview counter.',
            'Blocked is not treated as daily quota or generation failure. No general reclassification of other blocked reasons is made.',
            'Client-supplied occurred time and server received time have different clocks; session-local playback seconds need not equal the cumulative persisted preview counter.',
        ],
    }
    output.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    print(json.dumps({'classification': result['classification'], 'blockedEvent': result['blockedEvent'],
        'failureKeyDedup': result['failureKeyDedup'], 'sessionChains': chains}, sort_keys=True))


if __name__ == '__main__':
    main()
