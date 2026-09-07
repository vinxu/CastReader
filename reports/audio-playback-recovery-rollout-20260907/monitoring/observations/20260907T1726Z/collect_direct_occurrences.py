from pathlib import Path
import hashlib,json,subprocess
h=Path('reports/backend-audio-iteration-20260906/monitoring/remote_tts_gateway_snapshot.py').resolve()
remote=r"""
import types,json
m=types.ModuleType('reviewed_gateway_parser');exec(compile(HELPER,'remote_tts_gateway_snapshot.py','exec'),m.__dict__)
start=m.parse_timestamp('2026-09-07T16:25:51.808Z');end=m.parse_timestamp('2026-09-07T17:26:52.003Z')
entries,bad,truncated=m.read_journal(start,end);out=[];terminal_counts={};rows=0
for kind,t,block,closed in m.console_blocks(entries):
 if kind!='request':continue
 r=m.request_from_block(block,t)
 if r is None:continue
 rows+=1;k=str(r['status']);terminal_counts[k]=terminal_counts.get(k,0)+1
 if r['key'] in ['06ecf2d95fb6427f2ee3', '22d0da5eebf207417b0c', '22d212bd566b7c364fad', '47bd97dd11785d92e854', '51c699fe532648454018', '5227410452a5955e31d8', '5f88839fe5b9ce639d51', '6e0b443624e754ecb9a8', '730b2ad5f0edc0962b57', '9615da553704366cd337', 'a30d400a395aaee4f773', 'a59bc7dffb96c336f927', 'b16b2d650083193440e7', 'c1ce9be8825c161813df', 'c27280f2eaf70aff833e', 'c9d0ea13f277512e0f8f', 'cbd0595e06c5dd6b58ff', 'db79972ced29b039aca0', 'eb31503a54ee4305167c', 'ec70706a6a4aae1611d1']:out.append(r)
print(json.dumps({'readOnly':True,'productionModified':False,'rawContentExported':False,'synthesisStarted':False,'window':{'startUTC':m.iso(start),'endUTCExclusive':m.iso(end)},'journalParseErrors':bad,'journalRowLimitReached':truncated,'terminalOccurrences':rows,'statusCountsByOccurrence':terminal_counts,'selectedOccurrences':out,'limitations':['Selected keys are exact-window no-response or no-proxy-match records. Count terminal occurrences independently from keys.','The legacy cumulative parser deduplicates by key; its original counts are preserved alongside this occurrence supplement.']}))
"""
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3 -B -'],input='HELPER='+repr(h.read_text())+'\n'+remote,text=True,capture_output=True,timeout=60)
if r.returncode:raise RuntimeError('duplicate_terminal_read_failed')
v=json.loads(r.stdout);v['parserSha256']=hashlib.sha256(h.read_bytes()).hexdigest()
with Path(__file__).with_name('direct-terminal-occurrences.json').open('x') as f:json.dump(v,f,indent=2)
print(json.dumps(v))
