"""Read-only backend observation, executed over SSH; exports fixed aggregates only."""
import collections
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import urllib.request

def timestamp(value):
    try:
        if isinstance(value, (int, float)):
            return datetime.fromtimestamp(value / 1000, timezone.utc)
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError, AttributeError, OverflowError):
        return None

def health(port):
    # Exact loopback endpoint, no redirects or external requests.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    allowed = {'ok', 'status', 'queue', 'active', 'concurrency', 'jobs_cached',
        'accepting', 'busy', 'queue_depth', 'max_queue_size', 'submitted', 'completed',
        'failed', 'expired', 'queue_wait_p50_ms', 'queue_wait_p95_ms', 'run_p50_ms',
        'run_p95_ms', 'nari_ready'}
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
        with opener.open(f'http://127.0.0.1:{port}/health', timeout=8) as response:
            data = json.loads(response.read(262144))
            safe = {k: v for k, v in data.items() if k in allowed and
                (v is None or type(v) in (bool, int, float) or v in ('healthy', 'ready', 'degraded', 'unhealthy'))}
            return {'httpStatus': response.status, 'fields': safe,
                'observedAtUTC': datetime.now(timezone.utc).isoformat(),
                'counterScope': 'Cumulative since current service startup, not window outcomes.'}
    except Exception as error:
        return {'queryFailed': True, 'errorClass': type(error).__name__}

def process(pid):
    try:
        path = Path(f'/proc/{pid}')
        stat = (path / 'stat').read_text().rsplit(')', 1)[1].split()
        cwd = str((path / 'cwd').resolve())
        result = {'pid': pid, 'startTicks': stat[19], 'cwd': cwd}
        source = Path(cwd) / 'server/server.mjs'
        if source.is_file():
            result['serverSourceSha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
        lifecycle = Path(cwd) / 'server/request-lifecycle.mjs'
        if lifecycle.is_file():
            result['requestLifecycleSourceSha256'] = hashlib.sha256(lifecycle.read_bytes()).hexdigest()
        return result
    except OSError:
        return {'pid': pid, 'notRunningOrUnreadable': True}

TAGS = ('compose-block error:', 'fast-block0 error:', 'extract-block error:',
    'extract-plan error:', 'extract error:', 'compose error:', 'pipeline error:',
    '[pro-gate] allow', '[pro-gate] deny', '[pro-gate] entitlement check failed',
    'block0 checkpoint unavailable:', 'block0 early emit:',
    '[quickread] job persistence unavailable', '[quickread] job snapshot unavailable',
    '[quickread] job snapshot write unavailable', 'buildPreviewSpec failed:')
LEADING = re.compile(r'^(?:\d+\|[^|]{1,40}\|\s*)?\[?(20\d{2}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)')

def log_counts(rows, start, end, incremental):
    all_counts, new_counts, undated = collections.Counter(), collections.Counter(), collections.Counter()
    fixed_errors = []
    inside = recent = 0
    stamps = []
    for stamp, line in rows:
        if stamp:
            stamps.append(stamp)
        if stamp and start <= stamp < end:
            inside += 1
            recent += stamp >= incremental
        for tag in TAGS:
            if tag not in line:
                continue
            if stamp is None:
                undated[tag] += 1
            elif start <= stamp < end:
                all_counts[tag] += 1
                if stamp >= incremental:
                    new_counts[tag] += 1
                if tag.endswith('error:'):
                    message = line.split(tag, 1)[1].strip()
                    digest = hashlib.sha256(message.encode()).hexdigest()
                    code = 'request_disconnected' if digest == '1d6dad470351e74d5d881a9c2193f0b8e1c38bf79fe4a8c1e801415914e23edc' else 'unclassified'
                    fixed_errors.append({'timestampUTC': stamp.isoformat(), 'tag': tag,
                        'messageSha256': digest, 'staticCodeMatch': code})
    return {'windowTimestampedLines': inside, 'incrementalTimestampedLines': recent,
        'fixedTagCounts': dict(all_counts), 'incrementalFixedTagCounts': dict(new_counts),
        'undatedFixedTagCounts': dict(undated),
        'fixedErrorRecords': fixed_errors,
        'firstTrustedTimestampUTC': min(stamps).isoformat() if stamps else None,
        'lastTrustedTimestampUTC': max(stamps).isoformat() if stamps else None}

def jobs(directory, start, end, incremental):
    files = list(Path(directory).glob('qr_*.json'))
    parse_errors = created = updated = postcutoff = new_created = unknown_created = parse_errors_inside = 0
    states, streaming_states, pairs = collections.Counter(), collections.Counter(), collections.Counter()
    block0 = all_blocks = partial_ready = consistent = 0
    for path in files:
        try:
            if path.stat().st_size > 8 * 1024 * 1024:
                parse_errors += 1
                continue
            value = json.loads(path.read_bytes())
            spec = value['spec']
            at = timestamp(spec.get('created_at'))
            mtime = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
            updated += start <= mtime < end
            if at is None:
                unknown_created += 1
            if at and start <= at < end:
                created += 1
                new_created += at >= incremental
            # Outcome cohort is files modified inside the window; no invented creation time.
            if not start <= mtime < end:
                postcutoff += bool(at and start <= at < end and mtime >= end)
                continue
            # Current files may contain continuation after cutoff: do not backdate their outcome.
            if mtime >= end:
                postcutoff += 1
                continue
            state = spec.get('_streamState') or {}
            status = spec.get('status')
            status = status if status in ('discovering', 'planning', 'streaming', 'ready', 'done', 'error', 'failed') else 'other_or_missing'
            stream = state.get('status')
            stream = stream if stream in ('planning', 'ready', 'done', 'error', 'failed') else 'other_or_missing'
            states[status] += 1
            streaming_states[stream] += 1
            sections = len(spec.get('sections') or [])
            total = state.get('total')
            block0 += sections > 0
            if type(total) is int and total > 0:
                pairs[f'{sections}/{total}'] += 1
                all_blocks += sections >= total
                partial_ready += sections < total and stream == 'ready'
            consistent += state.get('nextIdx') == sections
        except (OSError, ValueError, KeyError, TypeError):
            parse_errors += 1
            try:
                parse_errors_inside += start <= datetime.fromtimestamp(path.stat().st_mtime, timezone.utc) < end
            except OSError:
                pass
    return {'directory': directory, 'filesAtRead': len(files), 'parseFailures': parse_errors,
        'parseFailuresModifiedInsideWindow': parse_errors_inside,
        'jobsWithExplicitCreationTimeInWindow': created,
        'jobsWithExplicitCreationTimeInIncrementalWindow': new_created,
        'jobsMissingExplicitCreationTime': unknown_created,
        'outcomeCohort': 'Current state of files modified inside the window, not all HTTP requests or newly created jobs.',
        'filesModifiedInWindow': updated, 'createdJobsUpdatedAfterCutoffExcludedFromOutcome': postcutoff,
        'status': dict(states), 'streamStateStatus': dict(streaming_states),
        'withAtLeastBlock0': block0, 'allServerBlocksGenerated': all_blocks,
        'partialButReady': partial_ready, 'sectionTotalPairs': dict(pairs),
        'nextIndexConsistentWithStoredSections': consistent}

def controller(region, start, end, incremental):
    result = {'quickreadHealthAfterCutoff': health(7777)}
    if region == 'us':
        result['quickreadExpectedProcess'] = process(543663)
        rows = []
        coverage = []
        for path in (Path('/root/.pm2/logs/quickread-out.log'), Path('/root/.pm2/logs/quickread-error.log')):
            size = path.stat().st_size
            if size > 32 * 1024 * 1024:
                raise ValueError('quickread_log_limit_exceeded')
            raw = path.read_bytes()
            coverage.append({'path': str(path), 'bytes': len(raw), 'completeFileRead': len(raw) >= size})
            for line in raw.decode('utf-8', 'replace').splitlines():
                match = LEADING.match(line)
                rows.append((timestamp(match.group(1)) if match else None, line))
        result['quickreadLogCoverage'] = coverage
        directory = '/root/.url-video-agent/jobs/quickread-state'
    else:
        units = ('castreader.service', 'castreader-quickread-cn.service',
            'castreader-cn-kokoro-tunnel.service', 'castreader-cn-clone-tunnel.service', 'nginx.service')
        result['units'] = {}
        for unit in units:
            cmd = ['systemctl', 'show', unit, '--property=MainPID,NRestarts,ActiveState,SubState,ActiveEnterTimestamp']
            p = subprocess.run(cmd, text=True, capture_output=True, timeout=10, check=True)
            result['units'][unit] = dict(line.split('=', 1) for line in p.stdout.splitlines() if '=' in line)
        pid = int(result['units']['castreader-quickread-cn.service']['MainPID'])
        result['quickreadProcess'] = process(pid)
        p = subprocess.run(['journalctl', '-u', 'castreader-quickread-cn.service',
            '--since', '@' + str(start.timestamp()), '--until', '@' + str(end.timestamp()), '-o', 'json', '--no-pager'],
            text=True, capture_output=True, timeout=25, check=True)
        rows = []
        for line in p.stdout.splitlines():
            event = json.loads(line)
            stamp = datetime.fromtimestamp(int(event['__REALTIME_TIMESTAMP']) / 1000000, timezone.utc)
            rows.append((stamp, event.get('MESSAGE', '')))
        result['quickreadLogCoverage'] = {'journalQueryOk': True, 'returnedRecords': len(rows),
            'limitation': 'Journal retention and application success-request coverage are not complete HTTP accounting.'}
        result['cloneHealthAfterCutoff'] = health(18890)
        directory = '/var/lib/castreader-quickread-cn/.url-video-agent/jobs/quickread-state'
        counts = collections.Counter()
        times = []
        invalid = 0
        path = Path('/var/log/nginx/access.log')
        size = path.stat().st_size
        if size > 64 * 1024 * 1024:
            raise ValueError('nginx_log_limit_exceeded')
        pattern = re.compile(r'^\S+ \S+ \S+ \[([^]]+)\] "([A-Z]+) ([^ ]+) HTTP/[^\"]+" (\d{3}) ')
        for line in path.read_text(errors='replace').splitlines():
            m = pattern.match(line)
            if not m:
                invalid += 1
                continue
            stamp = datetime.strptime(m.group(1), '%d/%b/%Y:%H:%M:%S %z')
            times.append(stamp)
            route = m.group(3).split('?', 1)[0]
            allowed = {'/api/captioned_speech_partly', '/api/captioned_speech',
                '/api/tts/generate', '/api/tts/tts_and_transcribe', '/api/markdown-tts/generate'}
            if route in allowed and start <= stamp < end:
                counts[(route, m.group(2), m.group(4))] += 1
        result['ttsIngress'] = {'path': str(path), 'fileBytes': size, 'unparsedLines': invalid,
            'firstParsedUTC': min(times).isoformat() if times else None,
            'lastParsedUTC': max(times).isoformat() if times else None,
            'routeMethodStatuses': [{'path': k[0], 'method': k[1], 'status': k[2], 'count': v} for k, v in sorted(counts.items())],
            'limitation': 'No model/voice attribution or request latency in access format; includes existing monitoring traffic.'}
    result['quickreadLogs'] = log_counts(rows, start, end, incremental)
    result['quickreadJobs'] = jobs(directory, start, end, incremental)
    return result

def gpu(start, end, incremental):
    result = {'cloneHealthAfterCutoff': health(8890),
        'expectedCloneProcess': process(568834), 'expectedNariProcess': process(4136837)}
    path = Path('/var/log/portal/castreader-clone.log')
    size = path.stat().st_size
    limit = 32 * 1024 * 1024
    with path.open('rb') as stream:
        offset = max(0, size - limit)
        stream.seek(offset)
        if offset:
            stream.readline()
        raw = stream.read(limit)
    # Event and kind names are fixed source-derived identifiers; all other fields discarded.
    events = {'gpu_job_completed', 'generated_audio_semantic_accepted',
        'generated_audio_semantic_validation_unavailable', 'generated_audio_accepted',
        'xvector_fallback_accepted', 'generated_audio_fast_path_accepted',
        'generated_audio_semantic_rejected', 'generated_audio_quality_warning',
        'captioned_timestamps_built', 'generated_audio_rejected',
        'generated_audio_duration_warning', 'xvector_fallback_rejected',
        'xvector_fallback_failed', 'captioned_word_timing_unavailable',
        'generated_audio_semantic_fallback'}
    kinds = {'captioned-speech', 'speech', 'voice-denoise-prompt-build',
        'captioned-speech-semantic-fallback', 'speech-semantic-fallback'}
    all_counts, recent_counts = collections.Counter(), collections.Counter()
    timings = collections.defaultdict(list)
    trusted, unknown_events = [], collections.Counter()
    for line in raw.decode('utf-8', 'replace').splitlines():
        brace = line.find('{')
        if brace < 0:
            continue
        try:
            value, _ = json.JSONDecoder().raw_decode(line[brace:])
        except ValueError:
            continue
        if not isinstance(value, dict):
            continue
        stamp = timestamp(value.get('timestamp'))
        if not stamp:
            continue
        trusted.append(stamp)
        if not start <= stamp < end:
            continue
        event = value.get('event')
        if event not in events:
            # Aggregate unknown event count only; never export arbitrary strings.
            unknown_events['otherStructuredEvents'] += 1
            continue
        kind = value.get('kind')
        kind = kind if kind in kinds else 'other_or_missing'
        all_counts[(event, kind)] += 1
        if stamp >= incremental:
            recent_counts[(event, kind)] += 1
        if event == 'gpu_job_completed':
            for key in ('queue_wait_ms', 'run_ms'):
                v = value.get(key)
                if type(v) in (int, float) and math.isfinite(v) and v >= 0:
                    timings[(kind, key)].append(v)
    def count_rows(counts):
        return [{'event': event, 'kind': kind, 'count': count} for (event, kind), count in sorted(counts.items())]
    result['cloneStructuredLog'] = {'path': str(path), 'fileBytes': size, 'scanOffset': offset,
        'bytesRead': len(raw), 'firstTrustedUTC': min(trusted).isoformat() if trusted else None,
        'lastTrustedUTC': max(trusted).isoformat() if trusted else None,
        'wholeFileScanned': offset == 0, 'windowEvents': count_rows(all_counts),
        'incrementalEvents': count_rows(recent_counts), 'unclassifiedEventCounts': dict(unknown_events),
        'timings': [{'kind': kind, 'metric': key, 'samples': len(values),
            'p50': sorted(values)[math.ceil(len(values) * .5) - 1],
            'p95': sorted(values)[math.ceil(len(values) * .95) - 1], 'max': max(values)}
            for (kind, key), values in sorted(timings.items())],
        'limitation': 'Scheduled job completion is not HTTP media completion; unstructured HTTP lines lack trustworthy timestamps.'}
    return result

def collect(config):
    start, end, incremental = (timestamp(config[key]) for key in ('startUTC', 'endUTC', 'incrementalStartUTC'))
    assert start <= incremental < end
    result = gpu(start, end, incremental) if config['role'] == 'us-gpu' else controller(config['role'], start, end, incremental)
    return {'schema': 'castreader.backend-supply-observation.v1', 'regionRole': config['role'],
        'window': config, 'readOnly': True, 'productionModified': False, 'synthesisStarted': False,
        'rawContentExported': False, 'capturedAtUTC': datetime.now(timezone.utc).isoformat(),
        'result': result,
        'limitations': ['QuickRead has no complete HTTP request ledger; persisted blocks do not prove downstream TTS completion.',
            'No log-content/body/audio/identity export; counts include unclassified callers and existing probes.',
            'Current health is outside the fixed cutoff. Readiness and cumulative counters alone cannot prove window success rate.']}
