"""Stream retained journal; retain sanitized request occurrences, not raw lines."""
from pathlib import Path
import json, subprocess, hashlib, shlex
HERE=Path(__file__).resolve().parent
LIB=HERE.parents[1]/'reports/backend-audio-iteration-20260906/monitoring/remote_tts_gateway_snapshot.py'
REMOTE=r'''
import json,sys,types,subprocess,hashlib,collections
from datetime import timedelta,datetime,timezone
P=json.load(sys.stdin);m=types.ModuleType('reviewed_parser');exec(compile(P['source'],'parser.py','exec'),m.__dict__)
start=m.parse_timestamp(P['start']);end=m.parse_timestamp(P['end'])
stats={'journalRowsRead':0,'journalParseErrors':0,'incompleteBlocks':0,'malformedRequests':0};first=last=None
source_before=hashlib.sha256(m.SOURCE.read_bytes()).hexdigest()
p=subprocess.Popen(['journalctl','-u',m.UNIT,'--since',m.iso(start-timedelta(seconds=2)),'--until',m.iso(end+timedelta(seconds=2)),'-o','json','--no-pager','--quiet'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
def entries():
 global first,last
 for line in p.stdout:
  stats['journalRowsRead']+=1
  if stats['journalRowsRead']>3000000: p.terminate();raise RuntimeError('bounded_rows_exceeded')
  try:
   x=json.loads(line);t=datetime.fromtimestamp(int(x['__REALTIME_TIMESTAMP'])/1000000,timezone.utc);message=x.get('MESSAGE','')
   if isinstance(message,list):message=bytes(message).decode('utf8','replace')
  except (ValueError,KeyError,TypeError):stats['journalParseErrors']+=1;continue
  first=t if first is None else min(first,t);last=t if last is None else max(last,t)
  yield t,str(message)
rows=[];error_details=[];errors=collections.Counter();seen=set();duplicates=0
for kind,t,block,closed in m.console_blocks(entries()):
 if not start<=t<end:continue
 if not closed:stats['incompleteBlocks']+=1
 if kind=='error':
  errors[m.error_from_block(block)]+=1
  error_details.append({'atUTC':m.iso(t),'requestKey':m.field(block,'requestKey') if m.field(block,'requestKey') and len(m.field(block,'requestKey'))==20 else None,'messageSha256':hashlib.sha256(block.encode()).hexdigest(),'fixedFragments':[x for x in ['UND_ERR_CONNECT_TIMEOUT','ETIMEDOUT','ECONNRESET','ECONNREFUSED','TTS_UPSTREAM_TIMEOUT','TTS_UPSTREAM_UNAVAILABLE','TTS_UPSTREAM_TRANSPORT','TTS_TOTAL_BUDGET_EXCEEDED','TTS_DOWNSTREAM_CLOSED','fetch failed','ConnectTimeoutError'] if x in block]})
  continue
 r=m.request_from_block(block,t)
 if r is None:stats['malformedRequests']+=1;continue
 k=(r['key'],r['observedAt'],r['status'])
 if k in seen:duplicates+=1;continue
 seen.add(k);rows.append(r)
rc=p.wait();source_after=hashlib.sha256(m.SOURCE.read_bytes()).hexdigest()
if rc:raise RuntimeError('journal_command_failed')
statuses=collections.Counter(str(r['status']) if r['status'] is not None else 'no_response' for r in rows)
clients=collections.Counter((r['clientPlatform'],r['clientVersion'],str(r['status']) if r['status'] is not None else 'no_response') for r in rows)
hourly=collections.Counter((r['observedAt'][:13],str(r['status']) if r['status'] is not None else 'no_response') for r in rows)
non200=[r for r in rows if r['status']!=200];keys=collections.Counter(r['key'] for r in rows)
out={'readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'window':{'startUTC':P['start'],'endUTCExclusive':P['end']},'observedAtUTC':m.iso(datetime.now(timezone.utc)),
'source':{'path':str(m.SOURCE),'sha256':source_after,'unchangedDuringRead':source_before==source_after},'systemd':m.systemd_show(m.UNIT),
'coverage':{**stats,'complete':all(stats[k]==0 for k in ['journalParseErrors','incompleteBlocks','malformedRequests']),'firstJournalUTC':m.iso(first),'lastJournalUTC':m.iso(last),'endBoundaryPaddingSeconds':2},
'allIncidentRequests':rows,'errorDetails':error_details,'requests':len(rows),'uniqueRequestKeys':len(keys),'exactDuplicateOccurrences':duplicates,'statusCounts':dict(statuses),'errorClassCounts':dict(errors),
'clientStatuses':[{'platform':k[0],'version':k[1],'status':k[2],'count':v} for k,v in sorted(clients.items())],
'hourlyStatuses':[{'hourUTC':k[0],'status':k[1],'count':v} for k,v in sorted(hourly.items())],
'elapsedMs':m.distribution([r['elapsedMs'] for r in rows]),'non200Records':non200,
'repeatedKeyOccurrences':[r for r in rows if keys[r['key']]>1],
'limitations':['Counts retain separate request occurrences even if a caller repeats its request key.','Gateway early-return admission paths are not covered by its request summary logger.','Recorded HTTP200 is not proof of audio playback; no_response is not a delivered HTTP error.']}
print(json.dumps(out))
'''
payload={'source':LIB.read_text(),'start':'2026-09-08T17:55:00Z','end':'2026-09-08T18:20:00Z'}
r=subprocess.run(['ssh','-C','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3 -B -c '+shlex.quote(REMOTE)],input=json.dumps(payload),text=True,capture_output=True,timeout=150)
if r.returncode:
 value={'collectionFailed':True,'returnCode':r.returncode,'rawOutputWithheld':True}
else:value=json.loads(r.stdout)
value['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest();value['parserSha256']=hashlib.sha256(LIB.read_bytes()).hexdigest()
with (HERE/'direct-incident-keyed.json').open('x')as f:json.dump(value,f,indent=2)
print(json.dumps({k:v for k,v in value.items() if k in ['collectionFailed','returnCode','coverage','statusCounts','requests','errorClassCounts']}))
