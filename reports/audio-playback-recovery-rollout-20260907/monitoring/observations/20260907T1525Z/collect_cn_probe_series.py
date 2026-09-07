"""Read existing CN preset monitor timing/counters; do not run probes."""
from pathlib import Path
import subprocess,json,hashlib
helper=Path('reports/backend-audio-iteration-20260906/monitoring/remote_monitor_snapshot.py').resolve()
source=helper.read_text()
remote="""
from pathlib import Path
from datetime import datetime,timezone
import json,types
module=types.ModuleType('reviewed_monitor_parser')
exec(compile(HELPER,'remote_monitor_snapshot.py','exec'),module.__dict__)
start=module.parse_timestamp('2026-09-07T14:24:51.334Z');end=module.parse_timestamp('2026-09-07T15:25:51.573Z')
rows=[]
for path in Path('/var/lib/castreader-core-audio-monitor/cn/results').glob('*.json'):
 value=json.loads(path.read_bytes());time=module.parse_timestamp(value['observedAt'])
 if not start<=time<end: continue
 row={'observedAtUTC':module.iso(time),'elapsedMs':value.get('elapsedMs'),'supplyOk':value.get('supplyOk') is True,'completeAudio':module.complete_audio(value),'segmentCount':value.get('segmentCount'),'sourceSha256':module.digest(path.read_bytes())}
 row['segmentAttempts']=[s.get('attempts') for s in value.get('segments',[])]
 row['regionMismatch']=any(s.get('upstreamNode')!='castreader-cn4090' for s in value.get('segments',[]))
 rows.append(row)
print('SAFE_PROBE='+json.dumps({'schema':'castreader.cn-existing-probe-timing-series.v1','readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'startUTC':module.iso(start),'endUTCExclusive':module.iso(end),'capturedAtUTC':module.iso(datetime.now(timezone.utc)),'rows':sorted(rows,key=lambda r:r['observedAtUTC']),'limitations':['Each duration is a whole synthetic continuity probe, including multiple requests/contracts and local checks; it is not real-user TTFB or one model request.','Uses already persisted results only; no probes were started.']}))
"""
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'ubuntu@106.54.47.163','sudo -n python3 -B -'],input='HELPER='+repr(source)+'\n'+remote,text=True,capture_output=True,timeout=60)
values=[line[11:] for line in r.stdout.splitlines() if line.startswith('SAFE_PROBE=')]
if r.returncode or len(values)!=1: raise RuntimeError('no_sanitized_result')
v=json.loads(values[0]);v['collectorHelperSha256']=hashlib.sha256(helper.read_bytes()).hexdigest()
output=Path(__file__).with_name('cn-probe-timing-series.json')
with output.open('x')as f:json.dump(v,f,indent=2)
print(json.dumps({'saved':str(output),'rows':len(v['rows'])}))
