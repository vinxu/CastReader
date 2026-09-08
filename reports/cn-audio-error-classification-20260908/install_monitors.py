from pathlib import Path
import hashlib,json,base64,subprocess,concurrent.futures
HERE=Path(__file__).resolve().parent;source=Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-audio-error-classification-20260908/scripts/core-audio-monitor');before=json.loads((HERE/'cn-before.json').read_text());files={str(f.relative_to(source)):{'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'data':base64.b64encode(f.read_bytes()).decode()}for f in source.rglob('*')if f.is_file()};tree=hashlib.sha256(json.dumps({k:v['sha256']for k,v in files.items()},sort_keys=True).encode()).hexdigest();release='eee0a902-'+tree[:8];code=(HERE/'remote_monitor_release.py').read_text()
def install(region):
 config={'region':region,'expectedTarget':before['monitorTarget'],'expectedFiles':before['monitorFiles'],'releaseName':release,'files':files,'protectedUnits':['castreader.service','castreader-quickread-cn.service','castreader-cn-kokoro-tunnel.service','castreader-cn-clone-tunnel.service','nginx.service']if region=='cn'else['castreader-tts-gateway.service','caddy']}
 import shlex
 command=['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10']
 command+=['-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'ubuntu@106.54.47.163','sudo -n python3 -B -c '+shlex.quote(code)]if region=='cn'else['root@140.82.14.49','python3 -B -c '+shlex.quote(code)]
 r=subprocess.run(command,input=json.dumps(config),capture_output=True,text=True,timeout=330)
 rows=[l[5:]for l in r.stdout.splitlines()if l.startswith('SAFE=')]
 if len(rows)!=1:return {'region':region,'failed':True,'exit':r.returncode,'errorType':'remote_execution_failed','stderrSha256':hashlib.sha256(r.stderr.encode()).hexdigest()}
 value=json.loads(rows[0]);(HERE/f'{region}-monitor-release.json').write_text(json.dumps(value,indent=2));return {'region':region,'exit':r.returncode,'status':value['status'],'probe':value.get('probe'),'currentAfter':value['currentAfter']}
with concurrent.futures.ThreadPoolExecutor(max_workers=2)as ex:
 for result in ex.map(install,['cn','us']):print(json.dumps(result),flush=True)
