#!/usr/bin/env python3
"""Read-only, deployment-pinned extraction of fixed tts-preset event fields.

No raw logs, request IDs, input, audio, URLs, headers or exception text are saved.
Run using a Python environment with certifi; no certificate verification bypass.
"""
from collections import Counter
from datetime import datetime, timedelta, timezone
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = Path('/Users/xuxuheng/Documents/MyProject/readout-web')
EVENTS = {'request_start', 'attempt_start', 'upstream_headers', 'upstream_body',
          'attempt_failed', 'retry_scheduled', 'request_finished'}
STAGES = {'request', 'headers', 'body', 'validation', 'backoff'}
CODES = {'TTS_REQUEST_CANCELLED', 'TTS_TOTAL_BUDGET_EXCEEDED', 'TTS_ATTEMPT_TIMEOUT',
         'TTS_UPSTREAM_HTTP', 'TTS_UPSTREAM_TRANSPORT', 'TTS_UPSTREAM_INVALID_JSON',
         'TTS_UPSTREAM_INVALID_PAYLOAD', 'TTS_UPSTREAM_EMPTY_AUDIO', 'TTS_UPSTREAM_INCOMPLETE_AUDIO'}
TRANSPORT_CODES = {'ECONNRESET', 'ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN', 'ETIMEDOUT',
                   'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_HEADERS_TIMEOUT', 'UND_ERR_BODY_TIMEOUT', 'UND_ERR_SOCKET'}
NUMBERS = {'elapsedMs', 'attemptElapsedMs', 'bodyBytes', 'retryDelayMs', 'budgetMs', 'attemptTimeoutMs'}
PATHS = {'/api/captioned_speech_partly', '/api/captioned_speech', '/api/tts/generate',
         '/api/tts/tts_and_transcribe', '/api/markdown-tts/generate'}
MAX_HTTP_BYTES = 16 * 1024 * 1024
MAX_LOG_LINE_BYTES = 16 * 1024
KEY = re.compile(r'^[a-f0-9]{20}$')


def utc(value):
    if not isinstance(value, str):
        raise ValueError('utc_string_required')
    dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if dt.tzinfo is None or dt.utcoffset().total_seconds() != 0:
        raise ValueError('explicit_utc_required')
    return dt


def stamp(value):
    return value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def anonymous(value):
    return hashlib.sha256(value.encode()).hexdigest()[:20] if isinstance(value, str) and value else None


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def member(value, allowed):
    return isinstance(value, str) and value in allowed


def safe_event(value):
    if not isinstance(value, dict) or value.get('source') != 'tts-preset':
        return None
    if not member(value.get('event'), EVENTS) or not member(value.get('stage'), STAGES):
        return None
    if not isinstance(value.get('requestKey'), str) or not KEY.fullmatch(value['requestKey']):
        return None
    if type(value.get('attempt')) is not int or not 0 <= value['attempt'] <= 3 or not number(value.get('elapsedMs')):
        return None
    result = {name: value[name] for name in ('event', 'stage', 'requestKey', 'attempt', 'elapsedMs')}
    for name in NUMBERS:
        if number(value.get(name)):
            result[name] = value[name]
    if member(value.get('region'), ('global', 'cn')):
        result['region'] = value['region']
    if member(value.get('code'), CODES):
        result['code'] = value['code']
    if member(value.get('transportCode'), TRANSPORT_CODES):
        result['transportCode'] = value['transportCode']
    if type(value.get('status')) is int and 100 <= value['status'] <= 599:
        result['status'] = value['status']
    return result


def sanitize_rows(rows, start, end, expected_deployment):
    requests = {}
    counts = Counter()
    for row in rows:
        if not isinstance(row, dict):
            counts['invalidProviderRows'] += 1
            continue
        if row.get('deploymentId') != expected_deployment:
            counts['deploymentMismatchRows'] += 1
            continue
        try:
            request_start = utc(row.get('timestamp'))
        except (ValueError, TypeError):
            counts['missingOrInvalidRequestTimestamps'] += 1
            continue
        if not start <= request_start < end:
            counts['outOfWindowRows'] += 1
            continue
        if not member(row.get('requestPath'), PATHS):
            counts['unreviewedPathRows'] += 1
            continue
        provider_key = anonymous(row.get('requestId'))
        if provider_key is None:
            counts['missingProviderRequestId'] += 1
            continue
        if provider_key in requests:
            counts['duplicateProviderRows'] += 1
        request = requests.setdefault(provider_key, {
            'vercelRequestKey': provider_key, 'requestStartUTC': stamp(request_start),
            'path': row['requestPath'], 'events': [], '_eventKeys': set(),
        })
        if type(row.get('statusCode')) is int and 100 <= row['statusCode'] <= 599:
            request['status'] = row['statusCode']
        if number(row.get('requestDurationMs')):
            request['requestDurationMs'] = row['requestDurationMs']
        logs = row.get('logs')
        if not isinstance(logs, list):
            counts['missingNestedLogsRows'] += 1
            continue
        for log in logs:
            if not isinstance(log, dict) or not isinstance(log.get('message'), str):
                counts['invalidLogEnvelopes'] += 1
                continue
            if log.get('messageTruncated') is True:
                counts['truncatedProviderLogs'] += 1
            for line in log['message'].splitlines():
                if len(line.encode()) > MAX_LOG_LINE_BYTES:
                    counts['oversizedLogLines'] += 1
                    continue
                try:
                    value = json.loads(line)
                except (ValueError, TypeError):
                    if re.search(r'"source"\s*:\s*"tts-preset"', line):
                        counts['malformedPresetJsonLines'] += 1
                    continue
                event = safe_event(value)
                if event is None:
                    if isinstance(value, dict) and value.get('source') == 'tts-preset':
                        counts['rejectedPresetEvents'] += 1
                    continue
                identity = json.dumps(event, sort_keys=True, separators=(',', ':'))
                if identity in request['_eventKeys']:
                    counts['duplicateSafeEvents'] += 1
                    continue
                request['_eventKeys'].add(identity)
                request['events'].append(event)
    result = []
    for request in requests.values():
        del request['_eventKeys']
        request['events'].sort(key=lambda event: (event['elapsedMs'], event['attempt']))
        request['applicationRequestKeys'] = sorted({event['requestKey'] for event in request['events']})
        request['hasRequestStart'] = any(event['event'] == 'request_start' for event in request['events'])
        request['hasRequestFinished'] = any(event['event'] == 'request_finished' for event in request['events'])
        if not request['events']:
            counts['requestsWithoutAcceptedEvents'] += 1
        result.append(request)
    return sorted(result, key=lambda row: (row['requestStartUTC'], row['vercelRequestKey'])), dict(counts)


def tls_context():
    import certifi
    context = ssl.create_default_context()
    context.load_verify_locations(cafile=certifi.where())
    if not context.check_hostname or context.verify_mode != ssl.CERT_REQUIRED:
        raise RuntimeError('tls_verification_required')
    return context


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, 'redirect_rejected', headers, fp)


def query_parameters(project, start, end, deployment, page):
    # Same documented-in-installed-CLI request-logs query used by inspect_requests.py.
    return {'projectId': project['projectId'], 'ownerId': project['orgId'], 'page': page,
            'startDate': int(start.timestamp() * 1000), 'endDate': int(end.timestamp() * 1000),
            'environment': 'production', 'deploymentId': deployment, 'search': 'tts-preset'}


def collect_pages(start, end, deployment, max_pages, max_rows):
    context = tls_context()
    project = json.loads((REPO/'.vercel/project.json').read_text())
    # Let the official CLI refresh its existing login before reading the token.
    # A raw request with a stale token can return 403 despite valid project access.
    # Never initiate interactive login, print credentials, or change team scope.
    login = subprocess.run(['vercel', 'whoami'], cwd=REPO,
        stdin=subprocess.DEVNULL, capture_output=True, timeout=45)
    if login.returncode:
        raise RuntimeError('existing_vercel_login_unavailable')
    auth = Path.home()/'Library/Application Support/com.vercel.cli/auth.json'
    credential = json.loads(auth.read_text())['token']
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=context), NoRedirect())
    rows = []
    page = 0
    has_more = True
    issues = []
    cursor_end = end
    previous_oldest = None
    while page < max_pages and has_more:
        # Current provider search pagination can repeat page 0 even when page
        # increments. Walk the explicit time range backwards, with 1ms overlap
        # for boundary rows; retain deduplication and stop if time cannot advance.
        query = urllib.parse.urlencode(query_parameters(project, start, cursor_end, deployment, 0))
        request = urllib.request.Request('https://vercel.com/api/logs/request-logs?' + query,
            headers={'Authorization': 'Bearer ' + credential, 'Accept': 'application/json'})
        with opener.open(request, timeout=40) as response:
            raw = response.read(MAX_HTTP_BYTES + 1)
        if len(raw) > MAX_HTTP_BYTES:
            raise RuntimeError('response_size_limit')
        data = json.loads(raw)
        if not isinstance(data, dict) or not isinstance(data.get('rows'), list):
            raise RuntimeError('invalid_provider_response')
        batch = data['rows']
        page += 1
        if type(data.get('hasMoreRows')) is not bool:
            issues.append('provider_pagination_flag_unavailable')
        has_more = data.get('hasMoreRows') is True
        remaining = max_rows - len(rows)
        rows.extend(batch[:remaining])
        if len(batch) > remaining or (has_more and len(rows) >= max_rows):
            issues.append('row_limit_reached')
            break
        if not batch and has_more:
            issues.append('empty_page_with_more_rows')
            break
        if has_more:
            timestamps = []
            for row in batch:
                try:
                    timestamp = utc(row.get('timestamp'))
                    if start <= timestamp < cursor_end:
                        timestamps.append(timestamp)
                except (ValueError, TypeError, AttributeError):
                    pass
            oldest = min(timestamps) if timestamps else None
            if oldest is None or (previous_oldest is not None and oldest >= previous_oldest):
                issues.append('timestamp_boundary_did_not_advance')
                break
            previous_oldest = oldest
            cursor_end = min(cursor_end, oldest + timedelta(milliseconds=1))
    if has_more:
        issues.append('pagination_incomplete')
    return rows, {'pagesRead': page, 'providerHasMoreRows': has_more, 'issues': issues,
                  'paginationMode': 'backward_timestamp_windows_with_1ms_overlap',
                  'tlsCertificateAndHostnameVerified': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--start-utc', required=True)
    parser.add_argument('--end-utc', required=True)
    parser.add_argument('--expected-deployment', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--max-pages', type=int, default=20)
    parser.add_argument('--max-rows', type=int, default=5000)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('output_exists_choose_a_new_snapshot')
    try:
        start, end = utc(args.start_utc), utc(args.end_utc)
        if not 0 < (end - start).total_seconds() <= 86400 or end > datetime.now(timezone.utc):
            raise ValueError('window_must_be_past_and_at_most_24h')
        if not re.fullmatch(r'dpl_[A-Za-z0-9]{10,100}', args.expected_deployment):
            raise ValueError('invalid_expected_deployment')
        if not 1 <= args.max_pages <= 100 or not 1 <= args.max_rows <= 10000:
            raise ValueError('collection_limit_out_of_bounds')
    except (ValueError, TypeError):
        parser.error('invalid_UTC_window_deployment_or_limits')
    report = {'schema': 'castreader.vercel-preset-event-window.v1', 'readOnly': True,
        'productionModified': False, 'synthesisStarted': False, 'rawContentExported': False,
        'expectedDeployment': args.expected_deployment,
        'window': {'requestStartInclusiveUTC': stamp(start), 'requestStartExclusiveUTC': stamp(end)},
        'query': {'production': True, 'deploymentPinned': True, 'search': 'tts-preset'},
        'collectionStartedUTC': stamp(datetime.now(timezone.utc))}
    try:
        rows, coverage = collect_pages(start, end, args.expected_deployment, args.max_pages, args.max_rows)
        requests, parser_counts = sanitize_rows(rows, start, end, args.expected_deployment)
        issues = coverage['issues']
        for name in ('deploymentMismatchRows', 'missingOrInvalidRequestTimestamps', 'missingProviderRequestId',
                     'missingNestedLogsRows', 'invalidLogEnvelopes', 'truncatedProviderLogs', 'oversizedLogLines',
                     'malformedPresetJsonLines', 'rejectedPresetEvents', 'requestsWithoutAcceptedEvents'):
            if parser_counts.get(name):
                issues.append(name)
        events = [event for row in requests for event in row['events']]
        missing_lifecycle = sum(not row['hasRequestStart'] or not row['hasRequestFinished'] for row in requests)
        if missing_lifecycle:
            issues.append('requests_missing_start_or_finish')
        coverage.update({'completeForReturnedRequestCohort': not issues, 'providerRowsRead': len(rows),
            'uniqueProviderRequests': len(requests), 'parserCounts': parser_counts,
            'requestsMissingStartOrFinish': missing_lifecycle,
            'structuredEventsObserved': bool(events), 'ingestionCompletenessVerified': False})
        report.update({'coverage': coverage, 'requests': requests,
            'counts': {'events': dict(Counter(event['event'] for event in events)),
                'failureCodes': dict(Counter(event['code'] for event in events if 'code' in event)),
                'terminalCodes': dict(Counter(event['code'] for event in events if event['event'] == 'request_finished' and 'code' in event)),
                'attemptStarts': dict(Counter(str(event['attempt']) for event in events if event['event'] == 'attempt_start'))}})
    except Exception as error:
        kind = 'http_error' if isinstance(error, urllib.error.HTTPError) else 'collection_unavailable'
        if isinstance(error, ModuleNotFoundError):
            kind = 'certifi_unavailable'
        report['coverage'] = {'completeForReturnedRequestCohort': False, 'issues': [kind], 'ingestionCompletenessVerified': False}
        if isinstance(error, urllib.error.HTTPError):
            report['coverage']['httpStatus'] = error.code
    report['collectedAtUTC'] = stamp(datetime.now(timezone.utc))
    report['limitations'] = [
        'Window selects provider request-start timestamps; nested event elapsedMs is relative to the application executor start, not the provider request start.',
        'Application events have no absolute timestamp. Requests may finish after the window end; never infer exact event wall time by adding elapsedMs to the provider timestamp.',
        'Vercel search and ingestion can omit or delay logs. Zero accepted events and even complete pagination do not prove zero requests or healthy playback.',
        'requestKey plus attempt joins proxy caller diagnostics; vercelRequestKey is a separate provider identifier hash and must not be joined as an application key.',
        'Repeated application request keys across provider requests remain separate. An attempt failure, scheduled retry and final error may describe the same failure.',
        'Header/body timings locate the observed waiting stage; they do not distinguish network, queue, language lock or inference time inside the upstream.',
        'Complete HTTP audio bytes do not prove decoding quality, delivery to the device or playback completion.',
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write('\n')
    print(json.dumps({'saved': str(args.output), 'coverage': report['coverage'], 'counts': report.get('counts', {})}))
    return 0 if report['coverage']['completeForReturnedRequestCohort'] else 2


if __name__ == '__main__':
    sys.exit(main())
