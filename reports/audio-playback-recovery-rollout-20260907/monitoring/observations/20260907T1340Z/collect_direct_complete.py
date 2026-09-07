"""Backfill the same bounded production journal with an explicit larger local row cap."""
from pathlib import Path
import hashlib,json,subprocess
h=Path('reports/backend-audio-iteration-20260906/monitoring/remote_tts_gateway_snapshot.py').resolve()
remote="""
import sys,types
m=types.ModuleType('reviewed_gateway_snapshot')
exec(compile(HELPER,'remote_tts_gateway_snapshot.py','exec'),m.__dict__)
m.MAX_JOURNAL_ROWS=500000
sys.argv=['remote_tts_gateway_snapshot.py','2026-09-06T18:37:52.522573Z','2026-09-07T13:40:22.326Z']
m.main()
"""
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3 -B -'],input='HELPER='+repr(h.read_text())+'\n'+remote,text=True,capture_output=True,timeout=60)
if r.returncode:raise RuntimeError('journal_snapshot_failed')
v=json.loads(r.stdout);v['parserSourceSha256']=hashlib.sha256(h.read_bytes()).hexdigest();v['localCollectorRowCapOverride']={'original':250000,'boundedBackfill':500000,'productionModified':False}
p=Path(__file__).with_name('direct-complete-cumulative.json')
with p.open('x') as f:json.dump(v,f,indent=2)
print(json.dumps({'coverage':v['coverage'],'counts':v['aggregate']['statusCounts'],'journalRows':v['aggregate']['journalRowsRead'],'noResponse':v['aggregate']['nonHttpRequests'][-2:]}))
