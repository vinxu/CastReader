"""Read-only, CPU-only forced-alignment qualification using an existing test WAV.

Runs trusted candidate source in memory over SSH; does not change the deployed
service, model files, dependencies, GPU process, gateway, or account allowance.
CPU latency is diagnostic only and cannot qualify the production GPU budget.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--wav', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
source = Path(__file__).with_name('caption_pipeline.py').read_text()
audio = args.wav.read_bytes()
payload = dict(source=source, audio=base64.b64encode(audio).decode(),
    text='早上，小林打开窗户。花园里的小鸟正在唱歌，阳光慢慢照进安静的房间。',
    source_sha256=hashlib.sha256(source.encode()).hexdigest(),
    audio_sha256=hashlib.sha256(audio).hexdigest())
script = '''
import base64, io, json, sys, time, types
sys.path.insert(0, '/workspace/castreader-alignment/current/src')
import torch
import soundfile as sf
torch.set_num_threads(4)
torch.set_num_interop_threads(1)
payload = json.loads(PAYLOAD)
module = types.ModuleType('cjk_candidate')
sys.modules[module.__name__] = module
exec(compile(payload['source'], '<candidate-in-memory>', 'exec'), module.__dict__)
samples, rate = sf.read(io.BytesIO(base64.b64decode(payload['audio'])), dtype='float32')
pcm = module.PCM(samples, rate)
aligner = module.QwenPCMAligner('cpu', '/workspace/castreader-alignment/model')
started = time.perf_counter()
words = aligner(pcm, payload['text'], 'zh')
report = {'candidate_sha256': payload['source_sha256'], 'audio_sha256': payload['audio_sha256'],
          'duration': pcm.duration, 'device': 'cpu', 'model_revision': module.MODEL_REVISION,
          'alignment_ms': (time.perf_counter()-started)*1000, 'raw_words': words}
try:
    grouped = module.measured_word_groups(words, pcm.duration)
    report['timestamps'] = module.project_words(payload['text'], grouped, pcm.duration)
    module.reject_uncovered_zero_word_gaps(pcm, words)
    report['coverage_qualified'] = True
except Exception as error:
    report['coverage_qualified'] = False
    report['rejection'] = str(error)
report['production_latency_qualified'] = False
report['acoustic_review_complete'] = False
print('QUALIFICATION_RESULT=' + json.dumps(report, ensure_ascii=False))
'''.replace('PAYLOAD', repr(json.dumps(payload, ensure_ascii=False)))
remote = ('env PYTHONDONTWRITEBYTECODE=1 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 '
          'CUDA_VISIBLE_DEVICES=-1 OMP_NUM_THREADS=4 MKL_NUM_THREADS=4 '
          '/workspace/castreader-alignment/venv/bin/python -B -')
result = subprocess.run(['ssh', 'castreader-us4090', remote], input=script,
                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=240)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.with_suffix('.stderr.log').write_text(result.stderr)
rows = [line.split('=', 1)[1] for line in result.stdout.splitlines() if line.startswith('QUALIFICATION_RESULT=')]
if result.returncode or not rows:
    args.output.with_suffix('.stdout.log').write_text(result.stdout)
    raise SystemExit('Qualification failed; inspect local diagnostic logs')
report = json.loads(rows[-1])
args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({k: v for k,v in report.items() if k not in {'raw_words','timestamps'}}, ensure_ascii=False))
