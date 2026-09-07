"""Read fixed clone event identifiers and numeric fields, discarding all content."""
from pathlib import Path
from datetime import datetime, timezone
from collections import Counter
import hashlib
import json
import math

start = datetime.fromisoformat('2026-09-07T04:55:49.447+00:00')
end = datetime.fromisoformat('2026-09-07T05:56:19.987+00:00')
allowed = {'captioned_timestamps_built', 'captioned_word_timing_unavailable', 'generated_audio_accepted',
           'generated_audio_duration_warning', 'generated_audio_fast_path_accepted', 'generated_audio_quality_warning',
           'generated_audio_rejected', 'generated_audio_semantic_accepted', 'generated_audio_semantic_fallback',
           'generated_audio_semantic_rejected', 'generated_audio_semantic_validation_unavailable', 'gpu_job_completed',
           'semantic_asr_validator_ready', 'voice_denoise_failed', 'voice_denoise_reference_rejected',
           'voice_denoise_reference_warning', 'voice_denoise_selected', 'voice_denoise_warmup_unavailable',
           'voice_prompt_builder_ready', 'voice_reference_competing_speech_observed',
           'voice_reference_diarization_unavailable', 'voice_reference_quality_passed', 'voice_reference_quality_rejected',
           'voice_reference_semantic_deferred', 'xvector_fallback_accepted', 'xvector_fallback_failed', 'xvector_fallback_rejected'}
p = Path('/var/log/portal/castreader-clone.log')
size = p.stat().st_size
assert size < 16 * 1024 * 1024
counts, unknown = Counter(), 0
warnings = []
with p.open('rb') as stream:
    raw = stream.read(size)
for line in raw.decode('utf-8', 'replace').splitlines():
    brace = line.find('{')
    if brace < 0:
        continue
    try:
        v, _ = json.JSONDecoder().raw_decode(line[brace:])
        t = datetime.fromisoformat(v['timestamp'].replace('Z', '+00:00'))
    except (ValueError, KeyError, TypeError):
        continue
    if not start <= t < end:
        continue
    event = v.get('event')
    if event not in allowed:
        unknown += 1
        continue
    counts[event] += 1
    if event == 'generated_audio_duration_warning':
        row = {'atUTC': t.isoformat(), 'event': event}
        if type(v.get('blocking')) is bool:
            row['blocking'] = v['blocking']
        if v.get('policy') == 'playback-first-v1':
            row['policy'] = v['policy']
        for k in ('duration_s', 'expected_duration_limit_s'):
            if type(v.get(k)) in (int, float) and math.isfinite(v[k]):
                row[k] = v[k]
        warnings.append(row)
source = Path('/workspace/castreader-clone/app/clone_worker.py')
data = source.read_bytes()
print('SAFE_CLONE=' + json.dumps({'schema': 'castreader.clone-fixed-event-detail.v1', 'readOnly': True,
      'productionModified': False, 'synthesisStarted': False, 'rawContentExported': False,
      'window': {'startUTC': start.isoformat(), 'endUTCExclusive': end.isoformat()},
      'capturedAtUTC': datetime.now(timezone.utc).isoformat(),
      'source': {'path': str(source), 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)},
      'log': {'path': str(p), 'bytesAtRead': size, 'bytesRead': len(raw)},
      'fixedEventCounts': dict(counts), 'unknownEventCount': unknown, 'durationWarnings': warnings,
      'limitations': ['Known event names were taken from static clone source. No voice, job, account, text, audio or arbitrary error values are exported.',
                      'Job completion and nonblocking warning fields do not prove full HTTP delivery.']}))
