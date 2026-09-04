"""Replay a local metadata-only injection; makes no network or model calls.

Run with the bundled Python interpreter, which provides real NumPy:
/Users/xuxuheng/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 /tmp/castreader-core-hard-evidence-20260904/replay-local-timing-gate.py
"""
import __future__
import ast
import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace
import wave

import numpy as np

root = Path(__file__).resolve().parent
source = Path('/Users/xuxuheng/Documents/MyProject/castreader-tts-compatible-fix/api/src/services/tts_service.py')
source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
assert source_sha == '7e42a26e742f17c0cf63a4ad546cb58d631fe3b89f4a23ee94a575dac1aee680'
function = next(n for n in ast.parse(source.read_text()).body
                if isinstance(n, ast.FunctionDef) and n.name == '_validate_source_word_timestamps')
scope = {'np': np}
# Preserve the exact function body; postponed annotations avoid loading the
# full GPU service. NumPy is real, not a replacement implementation.
exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), 'exec',
             flags=__future__.annotations.compiler_flag), scope)
validate = scope['_validate_source_word_timestamps']
normal = json.loads((root / 'production-normal-response.json').read_text())
wav_bytes = base64.b64decode(normal['response']['audio'])
with wave.open(io.BytesIO(wav_bytes)) as wav:
    audio_spec = {
        'channels': wav.getnchannels(),
        'rate': wav.getframerate(),
        'sample_width': wav.getsampwidth(),
        # ffmpeg emitted a streaming WAV placeholder rather than a real count.
        'declared_header_frames': wav.getnframes(),
    }
    pcm = np.frombuffer(wav.readframes(wav.getnframes()), dtype='<i2')
assert audio_spec['channels'] == 1 and audio_spec['rate'] == 24000 and audio_spec['sample_width'] == 2
audio_spec['actual_decoded_frames'] = len(pcm) // audio_spec['channels']
audio_spec['actual_duration_seconds'] = audio_spec['actual_decoded_frames'] / audio_spec['rate']
# These containers expose only the fields read by the original function.
# The audio and metadata come from the single successful production request.
chunk = SimpleNamespace(audio=pcm.copy(),
                        word_timestamps=[SimpleNamespace(**t) for t in normal['response']['timestamps']],
                        _source_word_timestamps=True)
words = validate(chunk)
pcm_sha = hashlib.sha256(chunk.audio.tobytes()).hexdigest()
injections = []
for name in ['first_interval_zero_length', 'last_interval_past_audio']:
    candidate = copy.deepcopy(chunk)
    if name == 'first_interval_zero_length':
        candidate.word_timestamps[0].end_time = candidate.word_timestamps[0].start_time
    else:
        candidate.word_timestamps[-1].end_time = len(candidate.audio) / 24000 + 0.01
    try:
        validate(candidate)
        result = {'rejected': False}
    except Exception as error:
        result = {'rejected': True, 'type': type(error).__name__, 'error': str(error)}
    candidate_sha = hashlib.sha256(candidate.audio.tobytes()).hexdigest()
    injections.append({'case': name, 'audio_pcm_sha256': candidate_sha,
                       'audio_unchanged': candidate_sha == pcm_sha, **result})
probe = subprocess.run(['/opt/homebrew/bin/ffprobe', '-v', 'error', '-show_entries',
                        'format=duration:stream=codec_name,sample_rate,channels', '-of', 'json',
                        str(root / 'production-normal.wav')], capture_output=True, text=True, check=True)
report = {
    'kind': 'explicit_local_timestamp_fault_injection_not_natural_production_failure',
    'production_normal_request_utc': normal['utc'], 'production_http_status': normal['status'],
    'production_elapsed_seconds': normal['elapsed_seconds'],
    'wav_sha256': hashlib.sha256(wav_bytes).hexdigest(), 'pcm_sha256': pcm_sha,
    'wav_spec': audio_spec,
    'pcm_rms_normalized': float(np.sqrt(np.mean((pcm.astype(np.float64) / 32768) ** 2))),
    'ffprobe': json.loads(probe.stdout), 'source_file': str(source),
    'source_sha256_verified_equal_to_both_production_regions': source_sha,
    'function_line': function.lineno, 'baseline_passed': True, 'baseline_word_count': len(words),
    'injections': injections,
    'method': 'Unmodified original function AST with real NumPy; actual production WAV PCM and response timestamps; SimpleNamespace field containers; only copied end_time values changed. No production process mutation.',
}
(root / 'local-timing-gate-proof.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
print(json.dumps(report, indent=2, ensure_ascii=False))
