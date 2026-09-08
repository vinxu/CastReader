"""Read existing CN application logs around fixed probe delays; do not send traffic."""
from pathlib import Path
import json,subprocess,shlex
HERE=Path(__file__).resolve().parent;folder=HERE/'observations/20260908T144032Z';ROOT=HERE.parents[1]
REMOTE=r'''
import json,sys,types,subprocess,collections,hashlib,re
from datetime import datetime,timezone
P=json.load(sys.stdin);m=types.ModuleType('safe_preset_events');exec(compile(P['helper'],'helper.py','exec'),m.__dict__)
start=datetime.fromisoformat(P['start'].replace('Z','+00:00'));end=datetime.fromisoformat(P['end'].replace('Z','+00:00'))
proc=subprocess.Popen(['journalctl','-u','castreader.service','--since',start.strftime('%Y-%m-%d %H:%M:%S UTC'),'--until',end.strftime('%Y-%m-%d %H:%M:%S UTC'),'-o','json','--no-pager','--quiet'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
rows=0;bad=0;events=[];fixed=collections.Counter();routes=[];first=last=None
for line in proc.stdout:
 rows+=1
 if rows>100000:proc.terminate();raise RuntimeError('row_bound')
 try:v=json.loads(line);t=datetime.fromtimestamp(int(v['__REALTIME_TIMESTAMP'])/1e6,timezone.utc);msg=v.get('MESSAGE','')
 except (ValueError,KeyError,TypeError):bad+=1;continue
 if not isinstance(msg,str)or not start<=t<end:continue
 first=t.isoformat()if first is None else first;last=t.isoformat()
 for token in ['[tts-gateway] preset upstream rejected request','[tts-gateway] word timing unavailable; continuing audio','[tts-gateway] regional routing rejected','tts-preset','fetch failed','ECONNRESET','UND_ERR_SOCKET','TimeoutError','502','503','504']:
  if token in msg:fixed[token]+=1
 if 'tts-preset'in msg:
  try:e=m.safe_event(json.loads(msg[msg.index('{'):]))
  except (ValueError,TypeError):continue
  if e:events.append({'atUTC':t.isoformat(),**e})
 mm=re.search(r'\b(POST|GET) (/api/(?:captioned_speech_partly|captioned_speech|tts/generate|voice-clone/captioned-speech)) (\d{3}) in (\d+)\s?ms',msg)
 if mm:routes.append({'atUTC':t.isoformat(),'method':mm[1],'path':mm[2],'status':int(mm[3]),'elapsedMs':int(mm[4]),'lineKey':hashlib.sha256(msg.encode()).hexdigest()[:20]})
if proc.wait()!=0:raise RuntimeError('journal_read_failed')
print(json.dumps({'readOnly':True,'synthesisStarted':False,'rawContentExported':False,'window':{'startUTC':P['start'],'endUTCExclusive':P['end']},'coverage':{'journalRows':rows,'parseErrors':bad,'firstUTC':first,'lastUTC':last},'fixedTokenCounts':dict(fixed),'presetEvents':events,'fixedRouteTimings':routes,'limitations':['Fixed-token matches do not independently prove a production error.','Absence of reviewed structured events prevents precise phase attribution.']}))
'''
payload={'start':'2026-09-08T13:53:50Z','end':'2026-09-08T14:13:15Z','helper':(ROOT/'reports/audio-playback-recovery-rollout-20260907/monitoring/collect_vercel_preset_events.py').read_text()}
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'ubuntu@106.54.47.163','sudo -n python3 -B -c '+shlex.quote(REMOTE)],input=json.dumps(payload),text=True,capture_output=True,timeout=60)
if r.returncode:raise SystemExit('CN log read failed; raw output withheld')
v=json.loads(r.stdout);(folder/'cn-slow-delivery-logs.json').write_text(json.dumps(v,indent=2));print(json.dumps(v))
