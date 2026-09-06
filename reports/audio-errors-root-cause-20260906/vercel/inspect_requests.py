"""Read known Vercel log windows; persist only explicitly sanitized metadata.

Uses the existing Vercel CLI credential in memory for the same HTTPS endpoint
called by installed Vercel CLI 59.10.0. Never prints raw IDs or log content.
"""
import datetime
import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path('/Users/xuxuheng/Documents/MyProject/readout-web')
TARGET_KEYS = {
    'e061a66c335ef6dece59', '0865d60458fd5519c2d1',
    '498d54bede61726ce98c', '5e7c7c1c359ddd58195d',
}
TAGS = [
    'FUNCTION_INVOCATION_TIMEOUT', 'EDGE_FUNCTION_INVOCATION_TIMEOUT',
    'MIDDLEWARE_INVOCATION_TIMEOUT', 'ROUTER_EXTERNAL_TARGET_CONNECTION_ERROR',
    'ROUTER_EXTERNAL_TARGET_ERROR', 'Task timed out', 'TimeoutError',
    'AbortError', 'UND_ERR_CONNECT_TIMEOUT', 'UND_ERR_HEADERS_TIMEOUT',
    'UND_ERR_BODY_TIMEOUT', 'ETIMEDOUT', 'ECONNRESET', 'fetch failed',
    '[tts-gateway] preset upstream rejected request', 'TTS upstream timeout',
]
NUMBER_KEYS = {
    'duration', 'durationMs', 'executionDuration', 'executionDurationMs',
    'invocationDuration', 'invocationDurationMs', 'statusCode', 'responseStatusCode',
    'memoryUsed', 'memorySize', 'maxMemoryUsed', 'billedDuration', 'timestamp',
    'startTime', 'endTime', 'executionStart', 'executionEnd', 'runtimeDuration',
    'requestDurationMs', 'httpStatus', 'functionMaxMemoryUsed', 'functionMemorySize',
    'functionMaxDuration', 'concurrency', 'functionColdStartDurationMs',
}
STRING_ENUMS = {'source', 'region', 'functionRegion', 'type', 'status', 'errorCode',
                'runtime', 'cache', 'cacheReason', 'level', 'requestMethod',
                'functionRuntime', 'functionStartType', 'pathType', 'clientRegion'}


def key(value):
    return hashlib.sha256(str(value).encode()).hexdigest()[:20] if value else None


def safe_metadata(value):
    if not isinstance(value, dict):
        return {}
    result = {'providerFieldNames': list(value)}
    for name, item in value.items():
        if name in NUMBER_KEYS | STRING_ENUMS | {'hasFunctionCrashed'} and item is None:
            result[name] = None
        elif name in NUMBER_KEYS and isinstance(item, (int, float)):
            result[name] = item
        elif name in STRING_ENUMS and isinstance(item, str):
            # Only short provider metadata tokens, never message/header/body text.
            if re.fullmatch(r'[A-Za-z0-9_.:-]{1,80}', item):
                result[name] = item
            elif item == '':
                result[name] = ''
        elif name in {'requestId', 'traceId', 'spanId', 'invocationId', 'instanceId'}:
            result[name + 'Key'] = key(item)
        elif name in {'timestamp', 'startTime', 'endTime'} and isinstance(item, str):
            try:
                parsed = datetime.datetime.fromisoformat(item.replace('Z', '+00:00').replace(' UTC', '+00:00'))
                result[name] = parsed.isoformat()
            except ValueError:
                result[name + 'FormatUnrecognized'] = True
        elif name == 'timestamp' and isinstance(item, dict):
            result['timestampComponents'] = {
                k: v for k, v in item.items()
                if k in {'seconds', 'nanos', 'milliseconds'} and isinstance(v, (int, float, str))
                and (not isinstance(v, str) or re.fullmatch(r'\d+', v))
            }
        elif name in {'coldStart', 'isColdStart', 'messageTruncated', 'hasFunctionCrashed'} and isinstance(item, bool):
            result[name] = item
    result['matchedSafeTags'] = [tag for tag in TAGS if tag in json.dumps(value)]
    return result


def fetch_log_window(start, end, status='504'):
    project = json.loads((REPO / '.vercel/project.json').read_text())
    auth_file = Path.home() / 'Library/Application Support/com.vercel.cli/auth.json'
    credential = json.loads(auth_file.read_text())['token']
    def millis(s):
        return int(datetime.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp() * 1000)
    query = urllib.parse.urlencode({
        'projectId': project['projectId'], 'ownerId': project['orgId'], 'page': 0,
        'startDate': millis(start), 'endDate': millis(end),
        'environment': 'production', 'statusCode': status,
    })
    req = urllib.request.Request(
        'https://vercel.com/api/logs/request-logs?' + query,
        headers={'Authorization': 'Bearer ' + credential, 'Accept': 'application/json'},
    )
    with urllib.request.urlopen(req, timeout=40) as response:
        return json.load(response)


def main():
    start, end = '2026-09-06T13:29:30Z', '2026-09-06T13:30:00Z'
    try:
        data = fetch_log_window(start, end)
    except urllib.error.HTTPError as exc:
        print(json.dumps({'readOnly': True, 'errorClass': 'http_error', 'status': exc.code}))
        return
    except Exception as exc:
        print(json.dumps({'readOnly': True, 'errorClass': type(exc).__name__}))
        return
    rows = []
    for row in data.get('rows', []):
        request_key = key(row.get('requestId'))
        if request_key not in TARGET_KEYS:
            continue
        safe = safe_metadata(row)
        safe['requestKey'] = request_key
        safe['staticPath'] = '/api/captioned_speech_partly'
        safe['events'] = [safe_metadata(event) for event in row.get('events', [])]
        safe['proxyEvents'] = [safe_metadata(event) for event in row.get('proxyEvents', [])]
        safe['functionEvents'] = [safe_metadata(event) for event in row.get('functionEvents', [])]
        safe['nestedLogCount'] = len(row.get('logs', []))
        safe['requestHeadersPresent'] = any(k.lower() in {'headers', 'requestheaders'} for k in row)
        tags = row.get('requestTags')
        safe['requestTagsType'] = type(tags).__name__
        safe['requestTagsCount'] = len(tags) if isinstance(tags, (list, dict)) else None
        safe['requestTagCorrelationKeys'] = {}
        if isinstance(tags, dict):
            for name, value in tags.items():
                if name.lower() in {'x-request-id', 'x-correlation-id', 'requestid', 'traceid'}:
                    safe['requestTagCorrelationKeys'][name.lower()] = key(value)
        if isinstance(tags, list):
            safe['requestTagEntryTypes'] = [type(t).__name__ for t in tags]
            for tag in tags:
                if isinstance(tag, dict):
                    name = str(tag.get('name') or tag.get('key') or '').lower()
                    if name in {'x-request-id', 'x-correlation-id', 'requestid', 'traceid'}:
                        safe['requestTagCorrelationKeys'][name] = key(tag.get('value'))
                elif isinstance(tag, str):
                    match = re.match(r'^(x-request-id|x-correlation-id|requestid|traceid)[:=](.+)$', tag, re.I)
                    if match:
                        safe['requestTagCorrelationKeys'][match[1].lower()] = key(match[2])
        agent = str(row.get('clientUserAgent') or '').lower()
        family = 'unclassified'
        for token, name in [('castreader', 'castreader'), ('okhttp', 'okhttp'), ('python', 'python'), ('undici', 'undici'), ('node', 'node'), ('curl/', 'curl'), ('postman', 'postman'), ('chrome/', 'chromium'), ('safari/', 'safari')]:
            if token in agent:
                family = name
                break
        safe['clientFamilyFromUserAgent'] = family if agent else 'absent'
        safe['deploymentMatchesBaseline'] = row.get('deploymentId') == 'dpl_9fnjABFoGBgj2ni2KAgf59Pa2jRc'
        rows.append(safe)
    result = {
        'schema': 'castreader.vercel-request-details.v1', 'readOnly': True,
        'query': {'startInclusive': start, 'endExclusive': end, 'statusCode': '504'},
        'readAtUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'hasMoreRows': data.get('hasMoreRows'), 'targetCount': len(TARGET_KEYS),
        'matchedCount': len(rows), 'rows': rows, 'rawContentExported': False,
        'productionModified': False,
    }
    (HERE / 'request-details.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
