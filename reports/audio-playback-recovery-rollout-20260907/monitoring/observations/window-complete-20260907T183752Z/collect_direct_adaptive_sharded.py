"""Read the fixed Direct journal in adjacent bounded shards; parse once to retain split console blocks."""
from pathlib import Path
import hashlib,json,subprocess
h=Path('reports/backend-audio-iteration-20260906/monitoring/remote_tts_gateway_snapshot.py').resolve()
remote=r'''
import types,json,hashlib
from datetime import datetime,timezone,timedelta
m=types.ModuleType('reviewed_gateway_snapshot')
exec(compile(HELPER,'remote_tts_gateway_snapshot.py','exec'),m.__dict__)
start=m.parse_timestamp('2026-09-06T18:37:52.522573Z');end=m.parse_timestamp('2026-09-07T18:37:52.522573Z')
entries=[];shards=[];left=start;errors=0;truncated=False
while left<end:
 hours=3 if left<start+timedelta(hours=21) else 1
 right=min(left+timedelta(hours=hours),end)
 rows,bad,cut=m.read_journal(left,right)
 selected=[r for r in rows if left<=r[0]<right]
 shards.append({'startInclusive':m.iso(left),'endExclusive':m.iso(right),'journalRowsRead':len(rows),'selectedHalfOpenRows':len(selected),'journalParseErrors':bad,'journalRowLimitReached':cut})
 entries.extend(selected);errors+=bad;truncated=truncated or cut
 if len(entries)>1000000:raise RuntimeError('bounded_total_row_limit')
 if cut:break
 left=right
agg=m.aggregate_entries(entries,start,end);raw=m.SOURCE.read_bytes()
complete=not truncated and left==end and errors==0 and agg['incompleteConsoleBlocks']==0 and agg['malformedRequestBlocks']==0
print(json.dumps({'schema':'castreader.direct-tts-gateway-journal.v1','readOnly':True,'productionModified':False,'probeStarted':False,'query':{'startInclusive':m.iso(start),'endExclusive':m.iso(end),'unit':m.UNIT,'maxRowsPerShard':m.MAX_JOURNAL_ROWS,'maxTotalRows':1000000,'shardHoursPolicy':'3h before final3h, then1h'},'readAtUtc':m.iso(datetime.now(timezone.utc)),'source':{'path':str(m.SOURCE),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()},'systemd':m.systemd_show(m.UNIT),'coverage':{'complete':complete,'journalParseErrors':errors,'journalRowLimitReached':truncated,'shards':shards,'reassembledBeforeConsoleParsing':True,'boundaryPolicy':'Exactly adjacent half-open timestamp shards are concatenated in journal order; console blocks are parsed only after reassembly.'},'aggregate':agg,'limitations':['The original250000-row snapshot is preserved separately, with its actual truncation.','No raw messages, body, credentials or original identifiers exported.','Journal retention and unique parsed request counts do not establish full user playback or end-to-end identity.']}))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3 -B -'],input='HELPER='+repr(h.read_text())+'\n'+remote,text=True,capture_output=True,timeout=150)
if r.returncode:raise RuntimeError('sharded_journal_read_failed')
v=json.loads(r.stdout);v['parserSourceSha256']=hashlib.sha256(h.read_bytes()).hexdigest();v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
p=Path(__file__).with_name('direct-complete-cumulative-final.json')
with p.open('x') as f:json.dump(v,f,indent=2);f.write('\n')
print(json.dumps({'saved':str(p),'complete':v['coverage']['complete'],'shards':len(v['coverage']['shards']),'rows':v['aggregate']['journalRowsRead'],'statusCounts':v['aggregate']['statusCounts'],'shardRows':[s['selectedHalfOpenRows'] for s in v['coverage']['shards']]}))
