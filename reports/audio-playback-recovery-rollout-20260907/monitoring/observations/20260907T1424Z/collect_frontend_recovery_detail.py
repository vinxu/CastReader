import hashlib,json,subprocess
from pathlib import Path
code=r'''
import hashlib,json,re
from pathlib import Path
from datetime import datetime,timezone
start=datetime.fromisoformat('2026-09-07T13:40:22.326+00:00').timestamp();end=datetime.fromisoformat('2026-09-07T14:24:51.334+00:00').timestamp()
rows=[]
for p in sorted(Path('/workspace/castreader-runtime/logs').glob('playback.jsonl*')):
 assert p.stat().st_size<12000000
 for line in p.read_bytes().splitlines():
  try:v=json.loads(line)
  except (ValueError,UnicodeError):continue
  if not isinstance(v,dict) or v.get('release')!='20260907-kokoro-japanese-numbers-us-r135' or v.get('stage') not in {'source_frontend_unavailable','english_g2p_recovered'}:continue
  t=v.get('time_unix')
  if not isinstance(t,(int,float)) or not start<=t<end:continue
  row={'atUTC':datetime.fromtimestamp(t,timezone.utc).isoformat(),'stage':v['stage'],'requestKey':hashlib.sha256(str(v.get('request_id','')).encode()).hexdigest()[:20],'causes':[]}
  for cause in v.get('causes',[]):
   kind=cause.get('type','');item={'type':kind if re.fullmatch('[A-Za-z_][A-Za-z_0-9]{0,90}',kind) else 'unclassified','frames':[]}
   for frame in cause.get('frames',[]):
    file=frame.get('file','');fn=frame.get('function','');line=frame.get('line')
    if re.fullmatch('[A-Za-z_0-9.\\-]{1,90}',file) and re.fullmatch('[A-Za-z_<>][A-Za-z_0-9<>]{0,100}',fn) and isinstance(line,int):item['frames'].append({'file':file,'line':line,'function':fn})
   row['causes'].append(item)
  rows.append(row)
print('SAFE='+json.dumps({'readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'rows':rows,'scope':'Fixed optional source-bookkeeping recovery diagnostics only; no text or exception messages.'}))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python','-B','-'],input=code,text=True,capture_output=True,timeout=60)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('no_sanitized_result')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with Path(__file__).with_name('frontend-recovery-detail.json').open('x') as f:json.dump(v,f,indent=2);f.write('\n')
print(json.dumps(v))
