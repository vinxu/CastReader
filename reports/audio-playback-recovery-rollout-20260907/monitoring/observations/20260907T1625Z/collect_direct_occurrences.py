from pathlib import Path
import hashlib,json,subprocess
h=Path('reports/backend-audio-iteration-20260906/monitoring/remote_tts_gateway_snapshot.py').resolve()
remote=r"""
import types,json
m=types.ModuleType('reviewed_gateway_parser');exec(compile(HELPER,'remote_tts_gateway_snapshot.py','exec'),m.__dict__)
start=m.parse_timestamp('2026-09-07T15:25:51.573Z');end=m.parse_timestamp('2026-09-07T16:25:51.808Z')
entries,bad,truncated=m.read_journal(start,end);out=[];terminal_counts={};rows=0
for kind,t,block,closed in m.console_blocks(entries):
 if kind!='request':continue
 r=m.request_from_block(block,t)
 if r is None:continue
 rows+=1;k=str(r['status']);terminal_counts[k]=terminal_counts.get(k,0)+1
 if r['key']=='77601dd021ec365fe333':out.append(r)
print(json.dumps({'readOnly':True,'productionModified':False,'rawContentExported':False,'synthesisStarted':False,'window':{'startUTC':m.iso(start),'endUTCExclusive':m.iso(end)},'journalParseErrors':bad,'journalRowLimitReached':truncated,'terminalOccurrences':rows,'statusCountsByOccurrence':terminal_counts,'repeatedKeyOccurrences':out,'limitations':['Repeated caller request keys are separate terminal occurrences; cannot prove they represent one user intention or a successful user retry.','The legacy cumulative parser deduplicates by key; its original counts are preserved alongside this occurrence supplement.']}))
"""
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3 -B -'],input='HELPER='+repr(h.read_text())+'\n'+remote,text=True,capture_output=True,timeout=60)
if r.returncode:raise RuntimeError('duplicate_terminal_read_failed')
v=json.loads(r.stdout);v['parserSha256']=hashlib.sha256(h.read_bytes()).hexdigest()
with Path(__file__).with_name('direct-terminal-occurrences.json').open('x') as f:json.dump(v,f,indent=2)
print(json.dumps(v))
