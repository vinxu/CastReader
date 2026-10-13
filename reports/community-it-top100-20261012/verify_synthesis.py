import json
from pathlib import Path
import mlx.core as mx
from mlx_whisper.audio import load_audio,log_mel_spectrogram,pad_or_trim,N_SAMPLES,N_FRAMES
from mlx_whisper.load_models import load_model
from mlx_whisper.decoding import DecodingOptions
p=Path(__file__).resolve().parent
model=load_model('/Users/xuxuheng/Documents/MyProject/readout-web/voice-library-clean/audit/model-small',dtype=mx.float16)
results={}
for f in sorted((p/'synthesis-samples').glob('*.wav')):
 a=load_audio(str(f));mel=pad_or_trim(log_mel_spectrogram(a,n_mels=model.dims.n_mels,padding=N_SAMPLES),N_FRAMES,axis=-2).astype(mx.float16)
 _,prob=model.detect_language(mel)
 r=model.decode(mel,DecodingOptions(language='it',without_timestamps=True,sample_len=160,fp16=True))
 results[f.stem]={'durationSeconds':len(a)/16000,'transcript':r.text,'italianProbability':prob['it'],'avgLogProbability':r.avg_logprob}
 print(json.dumps(results[f.stem],ensure_ascii=False),flush=True)
(p/'synthesis-verification.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
