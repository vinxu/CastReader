"""Read existing gateway journal grouped by recorded process PID; never request audio."""
from pathlib import Path
import json,subprocess,hashlib
helper=Path('reports/backend-audio-iteration-20260906/monitoring/remote_tts_gateway_snapshot.py').resolve()
remote=r"""
import json,types,subprocess,collections
from datetime import datetime,timezone
module=types.ModuleType('reviewed_gateway_parser')
exec(compile(HELPER,'remote_tts_gateway_snapshot.py','exec'),module.__dict__)
start=module.parse_timestamp('2026-09-07T16:25:51.808Z');end=module.parse_timestamp('2026-09-07T17:26:52.003Z')
p=subprocess.run(['journalctl','-u','castreader-tts-gateway.service','--since',module.iso(start),'--until',module.iso(end),'-o','json','--no-pager'],capture_output=True,text=True,timeout=40)
if p.returncode:raise RuntimeError('journal_read_failed')
groups=collections.defaultdict(list);bad=0;lines=p.stdout.splitlines()
if len(lines)>250000:raise RuntimeError('row_limit_exceeded')
for line in lines:
 try:
  v=json.loads(line);t=datetime.fromtimestamp(int(v['__REALTIME_TIMESTAMP'])/1000000,timezone.utc)
  if not start<=t<end:continue
  pid=v.get('_PID');pid=pid if pid in {'576327','596392','594453'}else 'other'
  groups[pid].append((t,v.get('MESSAGE','')))
 except (ValueError,KeyError,TypeError):bad+=1
out=[];safe_requests=[]
for pid,entries in groups.items():
 counts=collections.Counter();policies=collections.Counter();first=last=None;incomplete=malformed=0;keys=set();duplicates=0
 for kind,t,block,closed in module.console_blocks(entries):
  incomplete+=not closed
  if kind!='request':continue
  v=module.request_from_block(block,t)
  if v is None:malformed+=1;continue
  if v['key'] in keys:duplicates+=1;continue
  keys.add(v['key']);counts[str(v['status'])]+=1
  policy=module.field(block,'policy');policy=policy if policy in {'legacy','extension-v1'}else 'unavailable'
  policies[policy]+=1
  safe_requests.append({'requestKey':v['key'],'pid':pid,'observedAtUTC':module.iso(t),'status':v['status'],'policy':policy,'elapsedMs':v['elapsedMs'],'attempts':int(module.field(block,'attempts')) if module.field(block,'attempts') in {'0','1','2','3'} else None})
  first=t if first is None else min(first,t);last=t if last is None else max(last,t)
 out.append({'pid':pid,'statusCounts':dict(counts),'policyCounts':dict(policies),'requests':len(keys),'firstCompletionUTC':module.iso(first)if first else None,'lastCompletionUTC':module.iso(last)if last else None,'incompleteBlocks':incomplete,'malformedRequests':malformed,'duplicateRequestKeys':duplicates})
print('SAFE_VERSION='+json.dumps({'schema':'castreader.direct-pid-window.v1','readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'capturedAtUTC':datetime.now(timezone.utc).isoformat(),'window':{'startUTC':module.iso(start),'endUTCExclusive':module.iso(end)},'journalRows':len(lines),'parseErrors':bad,'groups':out,'requests':safe_requests,'limitations':['Process identity is bound to separately verified release receipts.','This unit excludes the private candidate unit and its brief public handoff interval.','Journal timestamps are completion/log times; they are not request-start times.']}))
"""
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3 -B -'],input='HELPER='+repr(helper.read_text())+'\n'+remote,text=True,capture_output=True,timeout=60)
values=[line[13:]for line in r.stdout.splitlines()if line.startswith('SAFE_VERSION=')]
if r.returncode or len(values)!=1:raise RuntimeError('no_sanitized_result')
v=json.loads(values[0]);v['parserSourceSha256']=hashlib.sha256(helper.read_bytes()).hexdigest()
p=Path(__file__).with_name('direct-version-requests.json')
with p.open('x')as f:json.dump(v,f,indent=2)
print(json.dumps({'saved':str(p),'groups':v['groups'],'requests':len(v['requests'])}))
