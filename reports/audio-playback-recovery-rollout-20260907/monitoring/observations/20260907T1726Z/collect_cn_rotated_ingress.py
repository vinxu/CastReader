"""Read both retained sides of the CN midnight log rotation, exporting fixed TTS fields only."""
import json,hashlib,subprocess
from pathlib import Path
code=r'''
import json,re,hashlib,collections
from pathlib import Path
from datetime import datetime,timezone
start=datetime.fromisoformat('2026-09-06T18:37:52.522573+00:00');increment=datetime.fromisoformat('2026-09-07T16:25:51.808+00:00');end=datetime.fromisoformat('2026-09-07T17:26:52.003+00:00')
pattern=re.compile(r'^\S+ \S+ \S+ \[([^]]+)\] "([A-Z]+) ([^ ]+) HTTP/[^\"]+" (\d{3}) ')
counts=collections.Counter();delta=collections.Counter();sources=[];errors=[]
for name in ['access.log.1','access.log']:
 p=Path('/var/log/nginx')/name;assert p.stat().st_size<64000000
 raw=p.read_bytes();source={'path':str(p),'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest(),'unparsedLines':0,'firstParsedUTC':None,'lastParsedUTC':None};last=None
 for line in raw.decode(errors='replace').splitlines():
  m=pattern.match(line)
  if not m:source['unparsedLines']+=1;continue
  t=datetime.strptime(m.group(1),'%d/%b/%Y:%H:%M:%S %z').astimezone(timezone.utc)
  if source['firstParsedUTC'] is None:source['firstParsedUTC']=t.isoformat()
  source['lastParsedUTC']=t.isoformat();route=m.group(3).split('?',1)[0]
  if not start<=t<end or route!='/api/captioned_speech_partly' or m.group(2)!='POST':continue
  status=m.group(4);counts[status]+=1
  if t>=increment:delta[status]+=1
  if status!='200':errors.append({'atUTC':t.isoformat(),'path':route,'method':'POST','loggedStatus':int(status),'lineFingerprint':hashlib.sha256(line.encode()).hexdigest()[:20],'incremental':t>=increment})
 sources.append(source)
assert sources[0]['lastParsedUTC']<=sources[1]['firstParsedUTC']
print('SAFE='+json.dumps({'schema':'castreader.cn-rotated-tts-ingress.v1','readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'window':{'startUTC':start.isoformat(),'incrementalStartUTC':increment.isoformat(),'endUTCExclusive':end.isoformat()},'sources':sources,'orderedFilesHaveNonoverlappingTimestamps':True,'cumulativeStatuses':dict(counts),'incrementalStatuses':dict(delta),'non200Rows':errors,'limitations':['Both retained files are read; original current-file-only snapshot is preserved and not used as a cumulative total.','Unparsed lines remain a coverage limitation. HTTP200 is not proof of complete playback.','Ingress log has no request-id join or voice attribution; 499 does not prove the status was delivered to a caller.']}))
'''
r=subprocess.run(['ssh','-T','-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'-o','BatchMode=yes','-o','ConnectTimeout=10','ubuntu@106.54.47.163','sudo -n python3 -B -'],input=code,text=True,capture_output=True,timeout=60)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('no_sanitized_result')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with Path(__file__).with_name('cn-rotated-ingress.json').open('x') as f:json.dump(v,f,indent=2);f.write('\n')
print(json.dumps(v))
