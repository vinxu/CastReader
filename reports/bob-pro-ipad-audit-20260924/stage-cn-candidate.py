import subprocess,pathlib,json,base64,secrets,hashlib,os
p=pathlib.Path(__file__).parent;os.umask(0o077)
w=pathlib.Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-pro-cn-account-realm-20260924/scripts/video-pipeline')
files=['server/server.mjs','tools/entitlement-realm.mjs']
payload={'files':{f:base64.b64encode((w/f).read_bytes()).decode() for f in files},'secret':pathlib.Path.home().joinpath('.config/castreader/pro-internal-secret.txt').read_text().strip(),'ingress':secrets.token_hex(32)}
(p/'cn-candidate-private.json').write_text(json.dumps(payload));(p/'cn-candidate-private.json').chmod(0o600)
code=r'''
import sys,json,base64,pathlib,shutil,hashlib,subprocess,os
x=json.load(sys.stdin);root=pathlib.Path('/opt/castreader-quickread-cn');old=root/'releases/20260908-cn-response-recovery-1660a11';new=root/'releases/20260924-pro-account-realm'
assert (root/'current').resolve()==old
assert hashlib.sha256((old/'server/server.mjs').read_bytes()).hexdigest()=='b155806c93c4b098bdc3f6a44ddd2d596d6a7bed5be776af171b4426197ce0b0'
assert not new.exists();shutil.copytree(old,new,symlinks=True)
for name,data in x['files'].items():(new/name).write_bytes(base64.b64decode(data))
def write(name,s):
 p=pathlib.Path(name);p.write_text(s);p.chmod(0o600)
write('/etc/castreader/quickread-pro-realm.env','PRO_GLOBAL_INTERNAL_SECRET='+x['secret']+'\nPRO_GLOBAL_INGRESS_SECRET='+x['ingress']+'\n')
write('/etc/castreader/quickread-pro-candidate.env','PORT=17777\n')
# The candidate has separate mutable state; no real job can be read or overwritten.
subprocess.run(['install','-d','-o','castreader-quickread','-g','castreader-quickread','-m','700','/var/lib/castreader-quickread-pro-candidate'],check=True)
s=pathlib.Path('/etc/systemd/system/castreader-quickread-cn.service').read_text()
s=s.replace('WorkingDirectory=/opt/castreader-quickread-cn/current','WorkingDirectory='+str(new))
s=s.replace('EnvironmentFile=/etc/castreader/quickread-cn.env','EnvironmentFile=/etc/castreader/quickread-cn.env\nEnvironmentFile=/etc/castreader/quickread-pro-realm.env\nEnvironment=PORT=17777')
s=s.replace('/var/lib/castreader-quickread-cn','/var/lib/castreader-quickread-pro-candidate')
write('/etc/systemd/system/castreader-quickread-pro-candidate.service',s)
subprocess.run(['systemctl','daemon-reload'],check=True);subprocess.run(['systemctl','start','castreader-quickread-pro-candidate'],check=True)
print(json.dumps({'candidate':str(new),'server_sha':hashlib.sha256((new/'server/server.mjs').read_bytes()).hexdigest()}))
'''
# Code and payload use a single private stdin envelope, never shell interpolation of secrets.
wrapped='import io,sys,base64; sys.stdin=io.StringIO(base64.b64decode('+repr(base64.b64encode(json.dumps(payload).encode()).decode())+').decode()); exec('+repr(code)+')'
r=subprocess.run(['ssh','-i','/Users/xuxuheng/.ssh/castreader_cn_deploy','-o','BatchMode=yes','ubuntu@106.54.47.163','sudo python3 -'],input=wrapped,text=True,capture_output=True)
if r.returncode:print(r.stderr);raise SystemExit(r.returncode)
print(r.stdout);(p/'cn-candidate-stage.json').write_text(r.stdout)
