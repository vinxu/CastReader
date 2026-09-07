"""Read frozen R135 identity and fixed, sanitized model diagnostic fields only."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import sys
ROOT=Path('/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907')
OUT=Path(__file__).resolve().parent
sys.path.insert(0,'/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-japanese-g2p-20260907/deployment')
from r131_backup import REGIONS
cn=json.loads((ROOT/'model-r135/cn-final-identity.json').read_text())
us=json.loads((ROOT/'model-r135/proxy-monitor-identity.json').read_text())
REMOTE=r'''
import collections,hashlib,json,os,re
from datetime import datetime,timezone
from pathlib import Path
root=Path(P['runtime']);release=root/'releases'/P['release']
def proc(expected):
 p=Path('/proc')/str(expected['pid'])
 actual={'pid':expected['pid'],'cwd':os.readlink(p/'cwd'),'startTicks':(p/'stat').read_text().rsplit(')',1)[1].split()[19],'exe':os.readlink(p/'exe'),'argvSha256':hashlib.sha256((p/'cmdline').read_bytes()).hexdigest()}
 return {'actual':actual,'matchesFrozen':all(actual.get(k)==v for k,v in expected.items())}
identity={'primary':proc(P['process']),'sourceDigests':{}}
for name,expected in P['sourceDigests'].items():
 raw=(release/name).read_bytes();actual={'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)}
 identity['sourceDigests'][name]={'actual':actual,'matchesFrozen':all(actual.get(k)==v for k,v in expected.items())}
if P['region']=='cn':
 identity['currentMatchesFrozen']=(root/'current').resolve()==release
 identity['protectedProcesses']={k:proc(v) for k,v in P['protected'].items()}
identity['verified']=identity['primary']['matchesFrozen'] and all(v['matchesFrozen'] for v in identity['sourceDigests'].values()) and identity.get('currentMatchesFrozen',True) and all(v['matchesFrozen'] for v in identity.get('protectedProcesses',{}).values())
start=datetime.fromisoformat(P['startUTC'].replace('Z','+00:00')).timestamp();end=datetime.fromisoformat(P['endUTC'].replace('Z','+00:00')).timestamp()
allowed={'model_unit_retry','model_unit_failed','audio_unit_failed','splitter_unavailable','silent_request_audio_ready','silent_separator_skipped','audio_generation_failed','complete_audio_failed','audio_writer_cleanup_failed','captioned_speech_failed','source_frontend_unavailable','word_alignment_unavailable','word_cues_unavailable','model_generation_failed','request_exception','request_failed','japanese_numeric_text_recovered','english_g2p_recovered'}
fail={'model_unit_failed','audio_unit_failed','audio_generation_failed','complete_audio_failed','captioned_speech_failed','model_generation_failed','request_exception','request_failed'}
counts=collections.Counter();failures=[];coverage=[];unclassified=0;invalid=0
for p in sorted((root/'logs').glob('playback.jsonl*')):
 size=p.stat().st_size
 if size>12000000:raise RuntimeError('diagnostic_file_limit')
 raw=p.read_bytes();coverage.append({'name':p.name,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
 for line in raw.splitlines():
  try:v=json.loads(line)
  except (ValueError,UnicodeError):invalid+=1;continue
  if not isinstance(v,dict) or v.get('release')!=P['release']:continue
  stamp=v.get('time_unix')
  if not isinstance(stamp,(int,float)) or not start<=stamp<end:continue
  stage=v.get('stage')
  if stage not in allowed:unclassified+=1;continue
  counts[stage]+=1
  if stage in fail:
   f={'atUTC':datetime.fromtimestamp(stamp,timezone.utc).isoformat(),'stage':stage,'requestKey':hashlib.sha256(str(v.get('request_id','')).encode()).hexdigest()[:20]}
   if isinstance(v.get('status'),int):f['status']=v['status']
   if re.fullmatch('[0-9a-f]{16}',str(v.get('fingerprint',''))):f['fingerprint']=v['fingerprint']
   failures.append(f)
print('SAFE='+json.dumps({'schema':'castreader.r135-model-readonly-observation.v1','region':P['region'],'release':P['release'],'readOnly':True,'productionModified':False,'synthesisStarted':False,'rawContentExported':False,'capturedAtUTC':datetime.now(timezone.utc).isoformat(),'window':{'startUTC':P['startUTC'],'endUTCExclusive':P['endUTC']},'identity':identity,'fixedStageCounts':dict(counts),'failureEvents':failures,'unclassifiedEvents':unclassified,'invalidLines':invalid,'coverage':coverage,'successLedgerComplete':False}))
'''
def run(region):
 p={'region':region,'runtime':REGIONS[region]['runtime'],'release':'20260907-kokoro-japanese-numbers-'+region+'-r135','startUTC':'2026-09-07T14:24:51.334Z','endUTC':'2026-09-07T15:25:51.573Z'}
 if region=='cn':p.update(process=cn['primaryProcess'],sourceDigests=cn['sourceDigests'],protected=cn['cloneProcesses'])
 else:p.update(process=us['expected']['modelProcess'],sourceDigests={us['modelExpectation']['sourceRelativePath']:{'sha256':us['modelExpectation']['sourceSha256']}})
 code='P='+repr(p)+'\n'+REMOTE
 try:
  r=subprocess.run(REGIONS[region]['ssh']+[REGIONS[region]['python'],'-B','-'],input=code,text=True,capture_output=True,timeout=60)
  rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
  if r.returncode or len(rows)!=1:raise RuntimeError('no_sanitized_result')
  value=json.loads(rows[0])
 except Exception as e:value={'collectionFailed':True,'errorClass':type(e).__name__}
 value['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
 with (OUT/(region+'-r135-model.json')).open('x') as f:json.dump(value,f,indent=2);f.write('\n')
 return {'region':region,'collectionFailed':value.get('collectionFailed',False),'identityVerified':value.get('identity',{}).get('verified'),'fixedStageCounts':value.get('fixedStageCounts'),'failureEvents':value.get('failureEvents')}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:print(json.dumps(list(pool.map(run,['us','cn']))))
