"""Read bounded existing structured model diagnostics; do not import model code."""
from pathlib import Path
from datetime import datetime, timezone
from collections import Counter
import hashlib,json
root=Path('/workspace/castreader-runtime')
release='20260907-kokoro-silent-separators-us-r134'
start=datetime.fromisoformat('2026-09-06T18:37:52.522573+00:00').timestamp()
incremental=datetime.fromisoformat('2026-09-07T01:55:18.503+00:00').timestamp()
end=datetime.fromisoformat('2026-09-07T02:55:18.766+00:00').timestamp()
allowed={'request_failed','request_exception','captioned_speech_failed','complete_audio_failed','audio_unit_failed','audio_generation_failed','model_generation_failed','model_unit_retry','model_unit_failed','source_frontend_unavailable','generated_audio_source_bookkeeping_failed','trim_preserved_complete_pcm','trim_unavailable','source_durations_unavailable','splitter_unavailable','silent_request_audio_ready','silent_separator_skipped','timestamps_unavailable','timestamps_degraded','audio_writer_cleanup_failed','word_alignment_unavailable','word_cues_unavailable','english_g2p_recovered','english_g2p_recovery_failed'}
files=[];counts=Counter();delta=Counter();failures=[];unknown=0;total=0;timings=Counter()
for suffix in ['', '.1','.2','.3','.4','.5']:
 p=root/('logs/playback.jsonl'+suffix)
 if not p.exists(): continue
 size=p.stat().st_size
 if size>11000000 or total+size>66000000: raise RuntimeError('bounded_scan_limit')
 total+=size;first=last=None;parsed=invalid=0
 with p.open('rb') as f:
  remaining=size
  while remaining>0:
   line=f.readline(min(remaining,1000000));remaining-=len(line)
   if not line: break
   try: v=json.loads(line)
   except (ValueError,UnicodeError): invalid+=1;continue
   t=v.get('time_unix')
   if type(t) not in (int,float): continue
   parsed+=1;first=t if first is None else min(first,t);last=t if last is None else max(last,t)
   if not start<=t<end or v.get('release')!=release: continue
   stage=v.get('stage')
   if stage not in allowed: unknown+=1;continue
   counts[stage]+=1
   if t>=incremental: delta[stage]+=1
   for field in ('queue_wait_ms','inference_ms','encoding_ms','run_ms','elapsed_ms'):
    if type(v.get(field)) in (int,float): timings[field]+=1
   if stage in {'request_failed','request_exception','captioned_speech_failed','complete_audio_failed','audio_unit_failed','audio_generation_failed','model_generation_failed','model_unit_failed','english_g2p_recovery_failed'}:
    row={'atUTC':datetime.fromtimestamp(t,timezone.utc).isoformat(),'stage':stage,'requestKey':hashlib.sha256(str(v.get('request_id','')).encode()).hexdigest()[:20]}
    for k in ('status','elapsed_ms'):
     if type(v.get(k)) in (int,float): row[k]=v[k]
    failures.append(row)
 files.append({'path':str(p),'bytesAtRead':size,'bytesScanned':size-remaining,'parsedTimestampedRows':parsed,'invalidJsonRows':invalid,'firstTimestampUTC':datetime.fromtimestamp(first,timezone.utc).isoformat() if first is not None else None,'lastTimestampUTC':datetime.fromtimestamp(last,timezone.utc).isoformat() if last is not None else None})
sources=[]
for rel in ('api/src/core/playback_diagnostics.py','api/src/services/tts_service.py'):
 p=root/'releases'/release/rel;raw=p.read_bytes();sources.append({'path':str(p),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
result={'schema':'castreader.model-existing-diagnostics-window.v1','readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'window':{'startUTC':'2026-09-06T18:37:52.522573Z','incrementalStartUTC':'2026-09-07T01:55:18.503Z','endUTCExclusive':'2026-09-07T02:55:18.766Z'},'capturedAtUTC':datetime.now(timezone.utc).isoformat(),'releaseId':release,'files':files,'sourceDigests':sources,'fixedStageCounts':dict(counts),'incrementalFixedStageCounts':dict(delta),'unrecognizedStageRows':unknown,'fixedTimingFieldSampleCounts':dict(timings),'failureEvents':failures[:200],'failureEventsTruncated':len(failures)>200,'limitations':['Diagnostics record failures/degradation/recovery, not a complete successful request ledger.','Zero stage-specific timing fields cannot isolate queue, inference or encoding.','Retained files are bounded snapshots; lack of model diagnostics does not establish all-event ingestion completeness.']}
print('SAFE_MODEL='+json.dumps(result))
