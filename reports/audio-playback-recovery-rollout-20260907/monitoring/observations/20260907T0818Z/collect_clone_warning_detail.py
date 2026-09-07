import json,subprocess,hashlib
from pathlib import Path
code=r'''
import json,math
from pathlib import Path
from datetime import datetime,timezone
start=datetime.fromisoformat('2026-09-07T07:18:20.570+00:00');end=datetime.fromisoformat('2026-09-07T08:18:21.015+00:00')
p=Path('/var/log/portal/castreader-clone.log');assert p.stat().st_size<32000000
warnings={'excessive-clipping','dc-offset','noise-or-electronic-spectrum','electronic-prefix-spectrum','unstable-prefix-pitch'}
fields={'duration_s','expected_duration_limit_s','rms','peak','clipping_ratio','silent_ratio','high_frequency_ratio','spectral_flatness','prefix_high_frequency_p75','prefix_spectral_flatness_p75','prefix_body_pitch_ratio','prefix_body_pitch_p90_ratio','prefix_pitch_frame_count','body_pitch_frame_count'}
rows=[]
for line in p.read_text(errors='replace').splitlines():
 brace=line.find('{')
 if brace<0:continue
 try:v,_=json.JSONDecoder().raw_decode(line[brace:]);t=datetime.fromisoformat(v.get('timestamp','').replace('Z','+00:00'))
 except (ValueError,TypeError,AttributeError):continue
 if not start<=t<end or v.get('event') not in {'generated_audio_quality_warning','generated_audio_duration_warning'}:continue
 row={'atUTC':t.isoformat(),'event':v['event'],'blocking':v.get('blocking') if isinstance(v.get('blocking'),bool) else None,'policy':v.get('policy') if v.get('policy')=='playback-first-v1' else 'unknown'}
 if 'warnings' in v:row['warnings']=[x if x in warnings else 'unclassified' for x in v['warnings']]
 row['metrics']={k:v[k] for k in fields if isinstance(v.get(k),(int,float)) and math.isfinite(v[k])}
 rows.append(row)
print('SAFE='+json.dumps({'readOnly':True,'productionModified':False,'rawContentExported':False,'synthesisStarted':False,'window':{'startUTC':start.isoformat(),'endUTCExclusive':end.isoformat()},'warnings':rows,'limitations':['Acoustic warning scores do not establish that playback failed or audio is defective.','No recording/audio/text read; no exact HTTP request join is available in these warning records.']}))
'''
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python','-B','-'],input=code,text=True,capture_output=True,timeout=60)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('no_sanitized_result')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with Path(__file__).with_name('clone-warning-detail.json').open('x') as f:json.dump(v,f,indent=2);f.write('\n')
print(json.dumps(v))
