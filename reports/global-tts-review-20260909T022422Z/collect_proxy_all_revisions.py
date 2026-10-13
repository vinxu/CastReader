from pathlib import Path
import json,hashlib,subprocess,shlex
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
MON=ROOT/'reports/audio-playback-recovery-rollout-20260907/monitoring'
identity=json.loads((MON.parent/'model-r135/proxy-monitor-identity.json').read_text())
direct=json.loads((HERE/'direct-streaming.json').read_text())
payload={'startUTC':'2026-09-08T02:24:22Z','endUTC':'2026-09-09T02:24:22Z','productionActiveFromUTC':identity['verifiedAtUTC'],
'expected':identity['expected'],'modelExpectation':identity['modelExpectation'],
'identityHelperSource':(ROOT/'reports/backend-audio-rollout-20260906/monitoring/remote_proxy_identity.py').read_text(),
'maxScanMiB':1024,'maxEvents':2000,'maxRequests':100000,'includeEvents':False,
'helper':(MON/'remote_proxy_events.py').read_text(),'targets':[r['key'] for r in direct['non200Records']], 'vercelDetails':(HERE/'vercel-error-platform-details-complete.json').read_text()}
remote=r'''
import json,sys,types,hashlib
P=json.load(sys.stdin);m=types.ModuleType('reviewed_proxy');source=P['helper'].replace('unexpected_routing += 1\n                continue','unexpected_routing += 1');exec(compile(source,'proxy.py','exec'),m.__dict__)
import collections
versionGroups={};minuteCounts=collections.Counter();incidentEvents=[]
vercel=json.loads(P['vercelDetails']);vercelKeys={e['requestKey'] for q in vercel['queries'] for r in q['rows'] for l in r['logs'] for e in l['events']} 
events=[];original=m.safe_event;targets=set(P['targets']);start=m.parse_utc(P['startUTC']);end=m.parse_utc(P['endUTC'])
def safe(v):
 e=original(v)
 if e and start<=e['timeUnix']<end:
  key=(e.get('revision'),e.get('slot'),e.get('releaseId'));g=versionGroups.setdefault(key,{'firstUTC':e['atUTC'],'lastUTC':e['atUTC'],'stages':collections.Counter(),'outcomes':collections.Counter()});g['firstUTC']=min(g['firstUTC'],e['atUTC']);g['lastUTC']=max(g['lastUTC'],e['atUTC']);g['stages'][e['stage']]+=1
  if e.get('outcome'):g['outcomes'][e['outcome']]+=1
  minuteCounts[(e['atUTC'][:16],e['stage'])]+=1
  if e.get('requestKey') in targets or e.get('requestKey') in vercelKeys:events.append(e)
  if '2026-09-08T17:55'<=e['atUTC']<'2026-09-08T18:20':incidentEvents.append(e)
 return e
m.safe_event=safe
out=m.collect(P);allrows=out.pop('anonymousRequests');out['anonymousRequestsTotal']=len(allrows)
out['targetRequests']=[r for r in allrows if r['requestKey'] in targets];out['allAnonymousRequests']=allrows;out['targetEvents']=events
out['missingTargetKeys']=sorted(targets-{r['requestKey'] for r in out['targetRequests']})
out['anonymousRequestExportScope']='All sanitized request summaries across observed revisions, plus targeted lifecycle events.'
out['expectedIdentity']=P['expected'];out['modelExpectation']=P['modelExpectation'];out['versionGroups']=[{'revision':k[0],'slot':k[1],'releaseId':k[2],**v} for k,v in versionGroups.items()];out['minuteStages']=[{'minuteUTC':k[0],'stage':k[1],'count':v} for k,v in sorted(minuteCounts.items())];out['incidentEvents']=incidentEvents;out['vercelMatches']=[r for r in allrows if r['requestKey'] in vercelKeys];out['collectorPolicy']='Include all observed routing revisions, preserve baseline mismatch and report revision groups separately; do not reinterpret drift as a parse failure.'
print('SAFE='+json.dumps(out))
'''
r=subprocess.run(['ssh','-C','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -c '+shlex.quote(remote)],input=json.dumps(payload),text=True,capture_output=True,timeout=100)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('proxy_read_failed')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with (HERE/'proxy-all-revisions.json').open('x')as f:json.dump(v,f,indent=2)
print(json.dumps({'verified':v['identityAndCoverageVerified'],'coverage':v['coverage'],'counts':v['counts'],'targetKeys':len(v['targetRequests']),'missingTargets':len(v['missingTargetKeys'])}))
