#!/usr/bin/env python3
"""Bounded, read-only three-window model check; no raw messages leave host."""
from pathlib import Path
from datetime import datetime, timezone
import collections
import hashlib
import json
import os
import re

ROOT = Path('/workspace/castreader-runtime')
MODEL = ROOT / 'releases/20260906-kokoro-repeated-digits-us-r133'
WINDOWS = [
    ('7fe6315b3454e3737bc7', '2026-09-06T16:04:04.896206Z'),
    ('e4331852bd595754975e', '2026-09-06T16:04:17.957222Z'),
    ('8a0585d2909dc89be5b7', '2026-09-06T16:13:12.950192Z'),
]
LANGS = {'a', 'b', 'e', 'f', 'h', 'i', 'j', 'p', 'z', 'de', 'en', 'en-us', 'en-gb', 'zh', 'fr', 'ja', 'pt', 'es', 'it', 'hi'}
VOICES = {'af_heart', 'af_alloy', 'af_aoede', 'af_bella', 'af_jessica', 'af_kore', 'af_nicole', 'af_nova', 'af_river', 'af_sarah', 'af_sky',
          'am_adam', 'am_echo', 'am_eric', 'am_fenrir', 'am_liam', 'am_michael', 'am_onyx', 'am_puck', 'am_santa',
          'bf_alice', 'bf_emma', 'bf_isabella', 'bf_lily', 'bm_daniel', 'bm_fable', 'bm_george', 'bm_lewis'}
VOICES.update(f'{prefix}_{number:03}' for prefix in ('zf', 'zm') for number in range(1000))
ANSI = re.compile(r'\x1b\[[0-9;]*m')
TIMED = re.compile(r'^(\d\d:\d\d:\d\d [AP]M)\s*\|\s*(INFO|DEBUG|WARNING|ERROR|CRITICAL)\s*\|\s*([A-Za-z0-9_]+):(\d+)\s*\|\s*(.*)$')


def ts(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def iso(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat()


def classification(message):
    if 'Text contains no speakable content' in message:
        return 'no_speakable_content'
    if 'Unsupported language code:' in message:
        return 'unsupported_language_code'
    if 'has no enabled model package' in message:
        return 'no_enabled_model_language'
    if 'is not compatible with language' in message:
        return 'voice_language_incompatible'
    if 'voice has no adapter in shared package:' in message:
        return 'voice_adapter_missing'
    if 'not found. Available voices:' in message or 'Voice not found at path:' in message:
        return 'voice_not_found'
    if 'Voice combination contains empty combine items' in message:
        return 'invalid_voice_combination'
    if 'contains too many weight items' in message:
        return 'invalid_voice_weight'
    if 'Unsupported format:' in message or re.search(r'Format \S+ not supported', message):
        return 'unsupported_audio_format'
    if 'Failed to convert audio stream to' in message:
        return 'audio_conversion_failed'
    if message.startswith('Invalid request:'):
        return 'other_model_validation_error'
    if message.startswith('ValueError:'):
        return 'other_value_error'
    return None


out = {'schema': 'castreader.model-400-three-window.v1', 'readOnly': True,
       'productionModified': False, 'synthesisStarted': False, 'rawUserDataExported': False,
       'collectedAtUTC': datetime.now(timezone.utc).isoformat(), 'windows': []}
for request_key, center in WINDOWS:
    out['windows'].append({'directRequestKey': request_key, 'directCompletionUTC': center,
        'startUTC': iso(ts(center) - 2), 'endUTCInclusive': iso(ts(center) + 2),
        'diagnostics': [], 'modelLogEvents': [], 'modelAccessRecords': []})


def matching(timestamp):
    return [v for v in out['windows'] if ts(v['startUTC']) <= timestamp <= ts(v['endUTCInclusive'])]


p = ROOT / 'logs/playback.jsonl'
size = p.stat().st_size
offset = max(0, size - 10 * 1024 * 1024)
first_diag = last_diag = None
with p.open('rb') as stream:
    stream.seek(offset)
    if offset:
        stream.readline()
    while stream.tell() < size:
        try:
            value = json.loads(stream.readline())
        except (ValueError, UnicodeError):
            continue
        stamp = value.get('time_unix')
        if type(stamp) not in (int, float):
            continue
        first_diag = stamp if first_diag is None else min(first_diag, stamp)
        last_diag = stamp if last_diag is None else max(last_diag, stamp)
        selected = matching(stamp)
        if not selected or value.get('release') != MODEL.name:
            continue
        stage = value.get('stage')
        if stage not in {'request_failed', 'request_exception', 'captioned_speech_failed', 'complete_audio_failed', 'source_frontend_unavailable', 'generated_audio_source_bookkeeping_failed'}:
            continue
        key = hashlib.sha256(str(value.get('request_id', '')).encode()).hexdigest()[:20]
        row = {'atUTC': iso(stamp), 'stage': stage, 'requestKey': key, 'releaseId': MODEL.name}
        for name in ('status', 'elapsed_ms', 'text_chars'):
            if type(value.get(name)) in (int, float) and value[name] >= 0:
                row[name] = value[name]
        row['causes'] = []
        for cause in value.get('causes', []):
            if cause.get('type') not in {'ValueError', 'RuntimeError', 'HTTPException', 'TimeoutError'}:
                continue
            frames = [{'file': frame['file'], 'line': frame['line'], 'function': frame['function']}
                      for frame in cause.get('frames', [])
                      if frame.get('file') in {'tts_service.py', 'development.py', 'playback_diagnostics.py'}
                      and frame.get('function') in {'generate_audio', 'generate_audio_stream', 'create_captioned_speech', '_process_chunk', '__call__', '_split_for_generation'}
                      and type(frame.get('line')) is int]
            row['causes'].append({'type': cause['type'], 'frames': frames})
        for window in selected:
            window['diagnostics'].append({**row, 'matchesDirectRequestKey': key == window['directRequestKey']})
out['diagnosticCoverage'] = {'path': str(p), 'bytesAtRead': size, 'scanStartOffset': offset,
    'bytesScanned': size - offset, 'firstStructuredUTC': iso(first_diag) if first_diag else None,
    'lastStructuredUTC': iso(last_diag) if last_diag else None, 'rotatedFilesRead': False}

p = Path('/var/log/onstart.log')
size = p.stat().st_size
offset = max(0, size - 16 * 1024 * 1024)
last_log_time = None
first_struct = last_struct = None
source_counts = collections.Counter()
with p.open('rb') as stream:
    stream.seek(offset)
    if offset:
        stream.readline()
    while stream.tell() < size:
        position = stream.tell()
        line = ANSI.sub('', stream.readline().decode(errors='replace').strip())
        try:
            value = json.loads(line[line.index('{'):])
        except (ValueError, KeyError):
            value = None
        if isinstance(value, dict) and type(value.get('time_unix')) in (int, float):
            stamp = value['time_unix']
            first_struct = stamp if first_struct is None else min(first_struct, stamp)
            last_struct = stamp if last_struct is None else max(last_struct, stamp)
        timed = TIMED.match(line)
        if timed:
            last_log_time = datetime.strptime('2026-09-06 ' + timed.group(1), '%Y-%m-%d %I:%M:%S %p').replace(tzinfo=timezone.utc).timestamp()
            selected = matching(last_log_time)
            if not selected:
                continue
            message = timed.group(5)
            source = timed.group(3) + ':' + timed.group(4)
            source_counts[source] += 1
            row = {'atUTC': iso(last_log_time), 'timestampPrecisionSeconds': 1,
                   'source': source, 'level': timed.group(2), 'fileOffset': position}
            category = classification(message)
            if category:
                row['fixedClassification'] = category
            elif message.startswith('Using lang_code '):
                row['stage'] = 'audio_stream_started'
            elif message.startswith('TTS route voice='):
                row['stage'] = 'model_route_selected'
            elif re.fullmatch(r'Starting smart split for \d+ chars', message):
                row['stage'] = 'split_started'
                row['textChars'] = int(re.search(r'\d+', message).group())
            else:
                row['stage'] = 'message_omitted'
            for pattern, name, allowed in ((r"(?:lang_code |language=)'([^']+)'", 'language', LANGS),
                                           (r"voice='([^']+)'", 'voice', VOICES)):
                match = re.search(pattern, message)
                if match and match.group(1) in allowed:
                    row[name] = match.group(1)
            for window in selected:
                window['modelLogEvents'].append(row)
        elif last_log_time is not None and matching(last_log_time):
            access = re.search(r'"POST /dev/captioned_speech HTTP/[^\"]+" (\d{3})', line)
            if access:
                row = {'nearestPrecedingLogUTC': iso(last_log_time), 'timestampExact': False,
                       'status': int(access.group(1)), 'path': '/dev/captioned_speech', 'fileOffset': position}
                for window in matching(last_log_time):
                    window['modelAccessRecords'].append(row)
            category = classification(line)
            if category:
                for window in matching(last_log_time):
                    window['modelLogEvents'].append({'nearestPrecedingLogUTC': iso(last_log_time),
                        'timestampExact': False, 'fileOffset': position, 'fixedClassification': category})
out['combinedLogCoverage'] = {'path': str(p), 'bytesAtRead': size, 'scanStartOffset': offset,
    'bytesScanned': size - offset, 'structuredFirstUTC': iso(first_struct) if first_struct else None,
    'structuredLastUTC': iso(last_struct) if last_struct else None, 'sourceCountsInsideWindows': source_counts}
out['sourceEvidence'] = []
spans = {'routers/development.py': [(163,181),(388,406)], 'core/playback_diagnostics.py': [(45,54),(78,103)],
         'services/tts_service.py': [(580,598)], 'inference/model_packages.py': [(116,144)],
         'routers/openai_compatible.py': [(120,129)]}
for relative, ranges in spans.items():
    source = MODEL / 'api/src' / relative
    raw = source.read_bytes()
    lines = raw.decode().splitlines()
    out['sourceEvidence'].append({'path': str(source), 'sha256': hashlib.sha256(raw).hexdigest(),
        'lines': [{'line': n + 1, 'code': lines[n]} for low, high in ranges for n in range(low - 1, min(high, len(lines)))]})
out['currentModelIdentity'] = {'pid': 3459850, 'cwd': os.readlink('/proc/3459850/cwd'),
    'startTicks': Path('/proc/3459850/stat').read_text().split()[21],
    'g2pSourceSha256': hashlib.sha256((MODEL / 'api/src/inference/english_g2p_recovery.py').read_bytes()).hexdigest()}
out['limitations'] = [
    'Only the three requested +/-2-second windows are selected; no synthesis or model changes occurred.',
    'Loguru timestamps have one-second precision and no date/PID/request ID. Nearby structured Unix times provide date context; concurrent model-slot attribution is not exact for these text log rows.',
    'Uvicorn access records have no timestamp; only the nearest preceding timed log is exported.',
    'R133 structured diagnostics do carry release and request ID, hashed remotely to the same 20-character key as Direct.',
    'Missing voice/language/textChars means no allowed field was observed, not an empty request.',
    'The bounded active diagnostic file and log tail are not automatically expanded if they do not cover the requested windows.',
]
print('SANITIZED_MODEL400=' + json.dumps(out, sort_keys=True))
