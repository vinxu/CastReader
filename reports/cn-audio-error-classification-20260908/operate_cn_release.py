from pathlib import Path
import json,subprocess,hashlib,base64,sys,shlex
HERE=Path(__file__).resolve().parent
mode=sys.argv[1];assert mode in {'stage','activate'}
source=Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-cn-llm-recovery-20260908/scripts/video-pipeline');manifest=json.loads((source/'deployments/20260906-playback-continuity/release-manifest.json').read_text())
patches={name:{'sha256':hashlib.sha256((source/name).read_bytes()).hexdigest(),'data':base64.b64encode((source/name).read_bytes()).decode()}for name in ['tools/llm-provider.mjs','tools/llm-provider.test.mjs','tools/llm-deadline.test.mjs']}
payload={'mode':mode,'expectedTarget':'/opt/castreader-quickread-cn/releases/20260906-quickread-playback-continuity-3d68d82-cn','expectedFiles':manifest['regions']['cn']['after']['files'],'releaseName':'20260908-cn-response-recovery-1660a11','patches':patches}
code=(HERE/'remote_cn_release.py').read_text()
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'ubuntu@106.54.47.163','sudo -n python3 -B -c '+shlex.quote(code)],input=json.dumps(payload),capture_output=True,text=True,timeout=280)
rows=[s[5:]for s in r.stdout.splitlines()if s.startswith('SAFE=')]
if len(rows)!=1:
 print(json.dumps({'mode':mode,'exit':r.returncode,'stderrSha256':hashlib.sha256(r.stderr.encode()).hexdigest(),'diagnostic':r.stderr[-800:] if 'AssertionError:' in r.stderr else 'remote failure; raw stderr retained locally'}));(HERE/f'cn-{mode}-failure.txt').write_text(r.stderr);raise SystemExit(1)
v=json.loads(rows[0]);(HERE/f'cn-{mode}-receipt.json').write_text(json.dumps(v,indent=2));print(json.dumps({k:v[k] for k in ['mode','from','to','backupVerified','candidateTestsPassed','candidateProviderProbe','productionProviderProbe','healthAfter','oldPID','newPID','finishedUTC']if k in v}));raise SystemExit(r.returncode)
