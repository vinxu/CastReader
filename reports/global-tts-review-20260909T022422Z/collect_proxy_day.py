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
'helper':(MON/'remote_proxy_events.py').read_text(),'targets':[r['key'] for r in direct['non200Records']]}
remote=r'''
import json,sys,types,hashlib
P=json.load(sys.stdin);m=types.ModuleType('reviewed_proxy');exec(compile(P['helper'],'proxy.py','exec'),m.__dict__)
events=[];original=m.safe_event;targets=set(P['targets']);start=m.parse_utc(P['startUTC']);end=m.parse_utc(P['endUTC'])
def safe(v):
 e=original(v)
 if e and start<=e['timeUnix']<end and e.get('requestKey') in targets:events.append(e)
 return e
m.safe_event=safe
out=m.collect(P);allrows=out.pop('anonymousRequests');out['anonymousRequestsTotal']=len(allrows)
out['targetRequests']=[r for r in allrows if r['requestKey'] in targets];out['allAnonymousRequests']=allrows;out['targetEvents']=events
out['missingTargetKeys']=sorted(targets-{r['requestKey'] for r in out['targetRequests']})
out['anonymousRequestExportScope']='Direct non-200/closed requests only; aggregate counts cover the complete selected proxy window.'
out['expectedIdentity']=P['expected'];out['modelExpectation']=P['modelExpectation']
print('SAFE='+json.dumps(out))
'''
r=subprocess.run(['ssh','-C','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -c '+shlex.quote(remote)],input=json.dumps(payload),text=True,capture_output=True,timeout=100)
rows=[s[5:] for s in r.stdout.splitlines() if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('proxy_read_failed')
v=json.loads(rows[0]);v['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
with (HERE/'proxy-day.json').open('x')as f:json.dump(v,f,indent=2)
print(json.dumps({'verified':v['identityAndCoverageVerified'],'coverage':v['coverage'],'counts':v['counts'],'targetKeys':len(v['targetRequests']),'missingTargets':len(v['missingTargetKeys'])}))
