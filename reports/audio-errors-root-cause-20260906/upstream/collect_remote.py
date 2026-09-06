#!/usr/bin/env python3
"""Read-only US collector; all filtering happens remotely before export."""
import collections
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

START = '2026-09-06T13:23:00+00:00'
END = '2026-09-06T13:32:59+00:00'
START_TS = datetime.fromisoformat(START).timestamp()
END_TS = datetime.fromisoformat(END).timestamp()
ANSI = re.compile(r'\x1b\[[0-9;]*m')
ROOT = Path('/workspace/castreader-runtime')
MODEL = ROOT / 'releases/20260906-kokoro-repeated-digits-us-r133'
PROXY = ROOT / 'proxy-releases/us-tts-origin-proxy-20260906-v1/r133_stable_proxy.py'

def key(value):
    return hashlib.sha256(str(value).encode()).hexdigest()

def safe_diagnostic(o):
    out = {k:v for k,v in o.items() if isinstance(v,(int,float,bool))}
    out['requestKeySha256'] = key(o.get('request_id'))
    for k in ('stage','release','fingerprint'):
        v=o.get(k)
        if isinstance(v,str) and re.fullmatch(r'[A-Za-z0-9_.:-]{1,120}',v):out[k]=v
    out['atUTC'] = datetime.fromtimestamp(o['time_unix'],timezone.utc).isoformat()
    if isinstance(o.get('causes'),list):
        out['causes']=[{'type':c.get('type'), 'frames':[{'file':f.get('file'), 'line':f.get('line'), 'function':f.get('function')} for f in c.get('frames',[])]} for c in o['causes']]
    return out

out={'schema':'castreader.upstream-incident-evidence.v1', 'readOnly':True,
     'synthesisStarted':False, 'userContentExported':False,
     'requestIDHash':'sha256 UTF-8 raw x-request-id', 'window':{'startUTC':START,'endUTC':END},
     'collectedAtUTC':datetime.now(timezone.utc).isoformat()}
diags=[]; inventory=[]
for p in sorted((ROOT/'logs').glob('playback.jsonl*')):
    first=None;last=None;n=0;size=p.stat().st_size
    for s in p.open(errors='replace'):
        try:o=json.loads(s)
        except ValueError:continue
        ts=o.get('time_unix')
        if not isinstance(ts,(int,float)):continue
        first=ts if first is None else min(first,ts);last=ts if last is None else max(last,ts)
        if START_TS<=ts<=END_TS:diags.append(safe_diagnostic(o));n+=1
    inventory.append({'path':str(p),'bytes':size,'firstUTC':datetime.fromtimestamp(first,timezone.utc).isoformat() if first else None,'lastUTC':datetime.fromtimestamp(last,timezone.utc).isoformat() if last else None,'windowRecords':n})
out['diagnosticInventory']=inventory;out['diagnostics']=sorted(diags,key=lambda v:v['time_unix'])

p=Path('/var/log/onstart.log');size=p.stat().st_size;offset=max(0,size-16*1024*1024)
events=[];counts=collections.Counter();minute=collections.defaultdict(collections.Counter)
first_struct=None;last_struct=None;last_time=None;unparsed=0;access=[]
with p.open('rb') as f:
    f.seek(offset);f.readline()
    while f.tell()<size:
        pos=f.tell();s=ANSI.sub('',f.readline().decode(errors='replace').strip())
        try:o=json.loads(s[s.index('{'):])
        except (ValueError,KeyError):o=None
        if isinstance(o,dict) and isinstance(o.get('time_unix'),(float,int)):
            ts=o['time_unix'];first_struct=ts if first_struct is None else min(first_struct,ts);last_struct=ts if last_struct is None else max(last_struct,ts)
        m=re.match(r'^(\d\d:\d\d:\d\d [AP]M)\s*\|\s*(INFO|DEBUG|WARNING|ERROR|CRITICAL)\s*\|\s*([A-Za-z0-9_]+):(\d+)\s*\|\s*(.*)$',s)
        if m:
            dt=datetime.strptime('2026-09-06 '+m.group(1),'%Y-%m-%d %I:%M:%S %p').replace(tzinfo=timezone.utc)
            last_time=dt.isoformat()
            if not START_TS<=dt.timestamp()<=END_TS:continue
            source=m.group(3)+':'+m.group(4);level=m.group(2);message=m.group(5)
            counts[(level,source)]+=1;minute[last_time[:16]][source]+=1
            e={'atUTC':last_time,'offset':pos,'level':level,'source':source}
            # Only known static forms can export their numeric parameters.
            match=re.fullmatch(r'Split completed in ([0-9.]+)ms, produced (\d+) chunks \(including pauses\)',message)
            if match:e.update(stage='split_iteration_completed',elapsedMs=float(match.group(1)),chunks=int(match.group(2)))
            elif re.fullmatch(r'Starting smart split for \d+ chars',message):e.update(stage='split_started',textChars=int(re.search(r'\d+',message).group()))
            elif message.startswith('Yielding '):
                e['stage']='chunk_yielded'
                match=re.search(r'\((\d+) tokens\)$',message)
                if match:e['tokens']=int(match.group(1))
            elif message.startswith('Using lang_code '):e['stage']='audio_stream_started'
            elif message.startswith('Applied deterministic PCM safety gain '):e['stage']='pcm_safety_gain'
            elif message=='Skipping text normalization as it is only supported for english':e['stage']='normalization_skipped'
            elif message=='Client disconnected, stopping audio generation':e['stage']='client_disconnected'
            else:e['stage']='message_omitted'
            # Fixed error-class matches only; never export message text.
            for token in ('OutOfMemoryError','TimeoutError','CancelledError','ClientConnectionResetError','ConnectionResetError','BrokenPipeError','CUDA out of memory'):
                if token in message:e.setdefault('errorClasses',[]).append(token)
            events.append(e)
        elif last_time and START<=last_time<=END:
            m=re.search(r'"(GET|POST) (/dev/captioned_speech|/health|/v1/audio/speech) HTTP/[^\"]+" (\d{3})',s)
            if m:access.append({'nearestPrecedingLogUTC':last_time,'timeExact':False,'method':m.group(1),'path':m.group(2),'status':int(m.group(3)),'offset':pos})
            if any(token in s for token in ('OutOfMemoryError','TimeoutError','CancelledError','ClientConnectionResetError','ConnectionResetError','BrokenPipeError','CUDA out of memory')):
                events.append({'atUTC':last_time,'timeExact':False,'offset':pos,'stage':'unstructured_error_class','errorClasses':[token for token in ('OutOfMemoryError','TimeoutError','CancelledError','ClientConnectionResetError','ConnectionResetError','BrokenPipeError','CUDA out of memory')if token in s]})

out['combinedLogCoverage']={'path':str(p),'fileBytesAtRead':size,'startOffset':offset,'bytesScanned':size-offset,'structuredFirstUTC':datetime.fromtimestamp(first_struct,timezone.utc).isoformat() if first_struct else None,'structuredLastUTC':datetime.fromtimestamp(last_struct,timezone.utc).isoformat() if last_struct else None,'timeSemantics':'Loguru local UTC hh:mm:ss A, date bounded by nearby structured Unix timestamps. Uvicorn access lines lack timestamps; their preceding Loguru timestamp is an approximate lower bound.'}
out['sourceCounts']=[{'level':k[0],'source':k[1],'count':v}for k,v in counts.most_common()]
out['minuteSourceCounts']=dict(minute);out['modelEvents']=events;out['accessRecords']=access

supervisor=Path('/var/log/supervisor/supervisord.log');sev=[]
for line in supervisor.read_text(errors='replace').splitlines():
    if not line.startswith('2026-09-06'):continue
    if any(name in line for name in ('castreader-tts','castreader-clone','castreader-nari')):
        t=re.match(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d[,.]\d+)',line)
        prog=re.search(r"(?:spawned: |success: |stopped: |exited: |waiting for )'?([a-zA-Z0-9_-]+)",line)
        kind=next((k for k in ('spawned','success','stopped','exited','waiting') if k in line),None)
        sev.append({'atUTC':t.group(1)if t else None,'program':prog.group(1)if prog else None,'kind':kind})
out['supervisorEventsToday']=sev
state=json.loads(Path('/var/lib/castreader-tts-origin-proxy/state.json').read_text())
out['runtime']={'proxyRevision':state.get('revision'),'proxySlot':state.get('currentSlot'),'proxyRelease':state.get('proxyReleaseId'),'proxySourceSHA256':hashlib.sha256(PROXY.read_bytes()).hexdigest(),'modelG2PSourceSHA256':hashlib.sha256((MODEL/'api/src/inference/english_g2p_recovery.py').read_bytes()).hexdigest(),'processes':[]}
for program in ('castreader-tts-origin-proxy','castreader-tts-r133-green','castreader-tts','castreader-clone'):
    r=subprocess.run(['supervisorctl','status',program],capture_output=True,text=True,timeout=5)
    m=re.match(r'\S+\s+([A-Z]+)\s+pid (\d+), uptime (.*)',r.stdout.strip())
    if m:
        pid=int(m.group(2));out['runtime']['processes'].append({'program':program,'state':m.group(1),'pid':pid,'uptime':m.group(3),'cwd':os.readlink('/proc/'+str(pid)+'/cwd')})
out['limitations']=['Stable proxy disables access logging, so its individual connection/timeout/cancel outcomes are not persisted.','Model middleware records failures and selected recovery stages; it does not record successful request arrival/completion or queue wait times.','Loguru model activity lacks per-request ID and release/PID, so concurrent blue/green attribution is not exact.','Current process state and source identity corroborate continuity but are not historical GPU utilization measurements.']
print(json.dumps(out,sort_keys=True))
