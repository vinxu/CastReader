"""Classify fixed voice-creation log names; never export references or payloads."""
import hashlib,json,subprocess
from pathlib import Path
code=r'''
import json,collections
from datetime import datetime,timezone
from pathlib import Path
start=datetime.fromisoformat('2026-09-06T18:37:52.522573+00:00');recent=datetime.fromisoformat('2026-09-07T17:26:52.003+00:00');end=datetime.fromisoformat('2026-09-07T18:37:52.522573+00:00')
allowed={'voice_reference_quality_rejected','voice_denoise_warmup_unavailable','voice_reference_diarization_unavailable','voice_reference_competing_speech_observed','voice_reference_quality_passed','voice_reference_semantic_deferred','voice_denoise_reference_warning','voice_denoise_reference_rejected','voice_denoise_failed','voice_denoise_selected'}
p=Path('/var/log/portal/castreader-clone.log');assert p.stat().st_size<32000000
counts=collections.Counter();delta=collections.Counter();rows=[]
for line in p.read_text(errors='replace').splitlines():
 brace=line.find('{')
 if brace<0:continue
 try:v,_=json.JSONDecoder().raw_decode(line[brace:])
 except ValueError:continue
 if not isinstance(v,dict) or v.get('event') not in allowed:continue
 try:t=datetime.fromisoformat(v['timestamp'].replace('Z','+00:00'))
 except (KeyError,ValueError,TypeError,AttributeError):continue
 if not start<=t<end:continue
 counts[v['event']]+=1
 if t>=recent:delta[v['event']]+=1;rows.append({'timestampUTC':t.isoformat(),'event':v['event']})
print('SAFE='+json.dumps({'readOnly':True,'productionModified':False,'rawContentExported':False,'synthesisStarted':False,'window':{'startUTC':start.isoformat(),'incrementalStartUTC':recent.isoformat(),'endUTCExclusive':end.isoformat()},'fixedCreationEventCounts':dict(counts),'incrementalCounts':dict(delta),'incrementalRows':rows,'limitations':['Only fixed names from reviewed local worker source; no reference recordings, voice identities, quality metrics or exception messages.','Voice creation is distinct from existing-voice TTS and HTTP audio delivery.']}))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python','-B','-'],input=code,text=True,capture_output=True,timeout=60)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('sanitized_creation_read_failed')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with Path(__file__).with_name('clone-fixed-creation-events.json').open('x') as f:json.dump(v,f,indent=2);f.write('\n')
print(json.dumps(v))
