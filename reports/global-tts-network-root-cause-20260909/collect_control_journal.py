from pathlib import Path
import subprocess,json
HERE=Path(__file__).resolve().parent
REMOTE=r'''
from pathlib import Path
from datetime import datetime,timezone
import subprocess,json,collections
r=subprocess.run(['journalctl','--since','2026-09-08 17:40:00 UTC','--until','2026-09-08 18:30:00 UTC','-o','json','--no-pager'],capture_output=True,text=True,timeout=30,check=True)
units=collections.Counter();events=[];parsed=0
terms=['out of memory','oom-kill','link is down','link is up','network is unreachable','no route to host','conntrack: table full','NETDEV WATCHDOG','segfault','clock jumped','time has been changed','synchronized to time server','restarting','failed to start','shutting down']
for l in r.stdout.splitlines():
 try:v=json.loads(l)
 except ValueError:continue
 unit=v.get('_SYSTEMD_UNIT','kernel' if v.get('_TRANSPORT')=='kernel' else 'other');msg=str(v.get('MESSAGE',''));parsed+=1;units[unit]+=1
 if unit=='castreader-tts-gateway.service':continue
 found=[x for x in terms if x.lower() in msg.lower()]
 if found:
  event={'atUTC':datetime.fromtimestamp(int(v['__REALTIME_TIMESTAMP'])/1e6,timezone.utc).isoformat(),'unit':unit,'fixedFragments':found}
  if 'castreader-core-audio-monitor@us' in msg:event['target']='castreader-core-audio-monitor@us'
  events.append(event)
print(json.dumps({'readOnly':True,'window':{'startUTC':'2026-09-08T17:40:00Z','endUTCExclusive':'2026-09-08T18:30:00Z'},'rows':parsed,'unitCounts':dict(units),'infrastructureEvents':events}))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','root@140.82.14.49','python3 -B -'],input=REMOTE,text=True,capture_output=True,timeout=40)
if r.returncode:raise RuntimeError('journal_read_failed')
v=json.loads(r.stdout);(HERE/'control-journal.json').write_text(json.dumps(v,indent=2));print(json.dumps(v))
