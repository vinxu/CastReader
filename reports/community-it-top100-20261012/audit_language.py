import json
from pathlib import Path
import time
import mlx.core as mx
from mlx_whisper.audio import load_audio, log_mel_spectrogram, pad_or_trim, N_SAMPLES, N_FRAMES
from mlx_whisper.load_models import load_model
from mlx_whisper.decoding import DecodingOptions

root = Path(__file__).resolve().parent
model_path = '/Users/xuxuheng/Documents/MyProject/readout-web/voice-library-clean/audit/model-small'
model = load_model(model_path, dtype=mx.float16)
report = root / 'language-audit.json'
results = json.loads(report.read_text()) if report.exists() else {}
rows = json.loads((root / 'discovery-top100.json').read_text())['voices']
for row in rows:
    sid = row['sourceId']
    if sid in results:
        continue
    checkpoint = root / 'raw' / (sid + '.json')
    for attempt in range(1800):
        raw = json.loads(checkpoint.read_text()) if checkpoint.exists() else {}
        if raw and not raw.get('error'):
            break
        if (root / 'download-audit.json').exists():
            break
        time.sleep(1)
    if not raw or raw.get('error'):
        results[sid] = {'error': raw.get('error', 'download_missing')}
        continue
    audio = load_audio(raw['audioPath'])
    mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
    first = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
    _, probabilities = model.detect_language(first)
    top = sorted(probabilities.items(), key=lambda item: -item[1])
    decoded = model.decode(first, DecodingOptions(language=top[0][0], without_timestamps=True, sample_len=160, fp16=True))
    result = {'index': row['index'], 'name': row['name'], 'language': top[0][0], 'probability': top[0][1], 'top5': dict(top[:5]), 'transcript': decoded.text, 'noSpeechProbability': decoded.no_speech_prob, 'avgLogProbability': decoded.avg_logprob, 'seconds': len(audio)/16000, 'model': 'whisper-small-mlx'}
    if len(audio) > N_SAMPLES + 16000*5:
        start = (len(audio)-N_SAMPLES)//160
        last = pad_or_trim(mel[start:], N_FRAMES, axis=-2).astype(mx.float16)
        _, p = model.detect_language(last)
        last_top = sorted(p.items(), key=lambda item: -item[1])
        result['lastWindow'] = {'language': last_top[0][0], 'probability': last_top[0][1]}
        result['mixedWindows'] = last_top[0][0] != top[0][0] and last_top[0][1] > .7 and top[0][1] > .7
    results[sid] = result
    report.write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(result, ensure_ascii=False), flush=True)
print('COMPLETE', len(results), flush=True)
