import json
from pathlib import Path
import mlx.core as mx
from mlx_whisper.audio import load_audio,log_mel_spectrogram,pad_or_trim,N_SAMPLES,N_FRAMES
from mlx_whisper.load_models import load_model
from mlx_whisper.decoding import DecodingOptions
p=Path(__file__).resolve().parent
model=load_model('/Users/xuxuheng/Documents/MyProject/readout-web/voice-library-clean/audit/model-small',dtype=mx.float16)
rows=json.loads((p/'download-audit.json').read_text());original=json.loads((p/'language-audit.json').read_text());results={}
review={3,4,7,32,35,36,38,44,52,58,68,72,77,81,85,89,91,93,95,97,100}
for row in rows:
 if row['index'] not in review:continue
 a=load_audio(row['audioPath']);mel=pad_or_trim(log_mel_spectrogram(a,n_mels=model.dims.n_mels,padding=N_SAMPLES),N_FRAMES,axis=-2).astype(mx.float16)
 r=model.decode(mel,DecodingOptions(language='it',without_timestamps=True,sample_len=220,fp16=True))
 results[row['sourceId']]={'index':row['index'],'name':row['name'],'transcript':r.text,'avgLogProbability':r.avg_logprob,'noSpeechProbability':r.no_speech_prob,'method':'secondary_italian_transcription'}
 (p/'italian-review.json').write_text(json.dumps(results,ensure_ascii=False,indent=2));print(json.dumps(results[row['sourceId']],ensure_ascii=False),flush=True)
