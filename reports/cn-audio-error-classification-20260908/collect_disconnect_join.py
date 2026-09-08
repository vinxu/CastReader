"""Join only observed post-release Direct disconnect keys to regional proxy records."""
from pathlib import Path
import ast,json,subprocess,shlex
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1];MON=ROOT/'reports/audio-playback-recovery-rollout-20260907/monitoring'
state=json.loads((HERE/'observation-state.json').read_text());targets=set()
for path in (HERE/'observations').glob('*/direct.json'):
 v=json.loads(path.read_text())
 for row in v.get('non200Records',[]):targets.add(row['key'])
identity=json.loads((MON.parent/'model-r135/proxy-monitor-identity.json').read_text())
payload={'startUTC':state['fixedObservationStartUTC'],'endUTC':state['lastCompleteEndUTC'],'productionActiveFromUTC':identity['verifiedAtUTC'],'expected':identity['expected'],'modelExpectation':identity['modelExpectation'],'identityHelperSource':(ROOT/'reports/backend-audio-rollout-20260906/monitoring/remote_proxy_identity.py').read_text(),'maxScanMiB':64,'maxEvents':2000,'maxRequests':100000,'includeEvents':False,'helper':(MON/'remote_proxy_events.py').read_text(),'targets':sorted(targets)}
source=ROOT/'reports/backend-service-review-20260908T121827Z/collect_proxy_day.py'
code=next(ast.literal_eval(node.value)for node in ast.parse(source.read_text()).body if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name)and t.id=='remote'for t in node.targets))
r=subprocess.run(['ssh','-C','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -c '+shlex.quote(code)],input=json.dumps(payload),text=True,capture_output=True,timeout=100)
rows=[s[5:]for s in r.stdout.splitlines()if s.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise SystemExit('proxy read failed; raw output withheld')
v=json.loads(rows[0]);(HERE/'initial-disconnect-proxy-join.json').write_text(json.dumps(v,indent=2))
print(json.dumps({k:v.get(k)for k in ['identityAndCoverageVerified','coverage','counts','targetRequests','missingTargetKeys']}))
