import hashlib,json,subprocess
from pathlib import Path
code=r'''
import collections,hashlib,json,re
from pathlib import Path
from datetime import datetime,timezone
start=datetime.fromisoformat('2026-09-07T13:40:22.326+00:00');end=datetime.fromisoformat('2026-09-07T14:24:51.334+00:00')
allowed={'/api/captioned_speech_partly'}
p=Path('/var/log/nginx/access.log');assert p.stat().st_size<64000000
pattern=re.compile(r'^\S+ \S+ \S+ \[([^]]+)\] "([A-Z]+) ([^ ]+) HTTP/[^\"]+" (\d{3}) ')
counts=collections.Counter();rows=[];unparsed=0
for line in p.read_text(errors='replace').splitlines():
 m=pattern.match(line)
 if not m:unparsed+=1;continue
 t=datetime.strptime(m.group(1),'%d/%b/%Y:%H:%M:%S %z');route=m.group(3).split('?',1)[0]
 if not start<=t<end or route not in allowed:continue
 counts[(route,m.group(2),m.group(4))]+=1
 if m.group(4)!='499':continue
 rows.append({'atUTC':t.astimezone(timezone.utc).isoformat(),'path':route,'method':m.group(2),'loggedStatus':int(m.group(4)),'lineFingerprint':hashlib.sha256(line.encode()).hexdigest()[:20]})
print('SAFE='+json.dumps({'readOnly':True,'productionModified':False,'rawContentExported':False,'synthesisStarted':False,'window':{'startUTC':start.isoformat(),'endUTCExclusive':end.isoformat()},'counts':[{'path':k[0],'method':k[1],'status':k[2],'count':v} for k,v in sorted(counts.items())],'rows':rows,'unparsedFileLines':unparsed,'limitations':['This is the existing default ingress log for the TTS route only; 499 is an ingress log status, not proof it was delivered to the caller.','No request-id join available; matching timestamps alone are not exact attribution.','Recorded HTTP200 cannot prove streaming delivery completed.']}))
'''
r=subprocess.run(['ssh','-T','-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'-o','BatchMode=yes','-o','ConnectTimeout=10','ubuntu@106.54.47.163','sudo -n python3 -B -'],input=code,text=True,capture_output=True,timeout=60)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('no_sanitized_result')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with Path(__file__).with_name('cn-tts-499-ingress.json').open('x') as f:json.dump(v,f,indent=2);f.write('\n')
print(json.dumps(v))
