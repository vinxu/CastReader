"""Count fixed clone events in retained combined logs after per-service rotation."""
from pathlib import Path
import subprocess,json,hashlib
HERE=Path(__file__).resolve().parent
CODE=r'''
from pathlib import Path
from datetime import datetime,timezone
import json,collections,hashlib,math
start=datetime.fromisoformat('2026-09-07T12:18:27+00:00');end=datetime.fromisoformat('2026-09-08T12:18:27+00:00')
allowed={'gpu_job_completed','generated_audio_semantic_accepted','generated_audio_semantic_validation_unavailable','generated_audio_accepted','xvector_fallback_accepted','generated_audio_fast_path_accepted','generated_audio_semantic_rejected','generated_audio_quality_warning','captioned_timestamps_built','generated_audio_rejected','generated_audio_duration_warning','xvector_fallback_rejected','xvector_fallback_failed','captioned_word_timing_unavailable','generated_audio_semantic_fallback','voice_reference_quality_rejected','voice_denoise_warmup_unavailable','voice_reference_diarization_unavailable','voice_reference_competing_speech_observed','voice_reference_quality_passed','voice_reference_semantic_deferred','voice_denoise_reference_warning','voice_denoise_reference_rejected','voice_denoise_failed','voice_denoise_selected'}
kinds={'captioned-speech','speech','voice-denoise-prompt-build','captioned-speech-semantic-fallback','speech-semantic-fallback'}
counts=collections.Counter();first=last=None;rows=[];seen=set();duplicates=0;timing=collections.defaultdict(list)
p=Path('/var/log/onstart.log');stat=p.stat();offset=max(0,stat.st_size-1024*1024*1024)
with p.open('rb')as f:
 f.seek(offset)
 if offset:f.readline()
 while f.tell()<stat.st_size:
  raw=f.readline();pos=raw.find(b'{')
  if pos<0:continue
  try:v,_=json.JSONDecoder().raw_decode(raw[pos:].decode(errors='replace'))
  except ValueError:continue
  if not isinstance(v,dict) or v.get('event') not in allowed:continue
  try:t=datetime.fromisoformat(v['timestamp'].replace('Z','+00:00'))
  except (KeyError,ValueError,AttributeError):continue
  first=t if first is None else min(first,t);last=t if last is None else max(last,t)
  if not start<=t<end:continue
  key=hashlib.sha256(json.dumps(v,sort_keys=True,separators=(',',':')).encode()).hexdigest()
  if key in seen:duplicates+=1;continue
  seen.add(key);event=v['event'];kind=v.get('kind') if v.get('kind') in kinds else 'other_or_missing';counts[event,kind]+=1
  if event=='gpu_job_completed':
   for name in ['queue_wait_ms','run_ms']:
    if type(v.get(name)) in {int,float} and math.isfinite(v[name]):timing[kind,name].append(v[name])
  if event in {'generated_audio_quality_warning','generated_audio_duration_warning','generated_audio_rejected','xvector_fallback_rejected','xvector_fallback_failed','voice_denoise_failed','voice_reference_quality_rejected','voice_denoise_reference_rejected'}:
   rows.append({'atUTC':t.isoformat(),'event':event,'blocking':v.get('blocking') if type(v.get('blocking')) is bool else None,'policy':v.get('policy') if v.get('policy')=='playback-first-v1' else 'other_or_missing'})
after=p.stat()
out={'readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'window':{'startUTC':start.isoformat(),'endUTCExclusive':end.isoformat()},'coverage':{'path':str(p),'fileBytes':stat.st_size,'scanOffset':offset,'firstCloneEventUTC':first.isoformat() if first else None,'lastCloneEventUTC':last.isoformat() if last else None,'coversWindowStart':first is not None and first<=start,'sameInode':after.st_ino==stat.st_ino,'notTruncated':after.st_size>=stat.st_size},'exactDuplicateEventsSkipped':duplicates,'events':[{'event':k[0],'kind':k[1],'count':v} for k,v in sorted(counts.items())],'warningAndRejectionEvents':rows,'timings':[{'kind':k[0],'metric':k[1],'samples':len(v),'p50':sorted(v)[math.ceil(len(v)*.5)-1],'p95':sorted(v)[math.ceil(len(v)*.95)-1],'max':max(v)} for k,v in sorted(timing.items())],'limitations':['Fixed structured event names only; unknown unstructured failures and HTTP delivery are not a complete ledger.','Combined log restores coverage absent from the rotated per-service log; rows are deduplicated by complete event serialization without exporting content fingerprints.']}
print('SAFE='+json.dumps(out))
'''
r=subprocess.run(['ssh','-C','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -'],input=CODE,capture_output=True,text=True,timeout=65)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('clone_combined_read_failed')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with (HERE/'clone-combined.json').open('x')as f:json.dump(v,f,indent=2)
print(json.dumps({'coverage':v['coverage'],'events':v['events'],'warnings':len(v['warningAndRejectionEvents'])}))
