import os,json,subprocess
from pathlib import Path
p=Path(__file__).parent;env=os.environ.copy();env.update(HTTPS_PROXY='http://127.0.0.1:17890',HTTP_PROXY='http://127.0.0.1:17890',VERCEL_TOKEN=(Path.home()/'.config/castreader/vercel-token').read_text().strip())
aliases=['castreader.com','www.castreader.com'];old='dpl_CqQDaTh4NU3KCLx6ZEK9Uqpg2G7D';new='dpl_4AqP1KPV4mrvhkDmH6KhRGRmsD8T';url='castreader-content-m78nk1ckv-castreader.vercel.app'
def run(args):
 r=subprocess.run(['vercel']+args,env=env,capture_output=True,text=True,timeout=90)
 if r.returncode:raise RuntimeError('Vercel command failed: '+args[0])
 return r.stdout
def inspect(x):return json.loads(run(['inspect',x,'--json']))['id']
assert all(inspect(a)==old for a in aliases),'Production baseline changed; do not promote'
assert inspect(url)==new
try:
 for a in aliases:run(['alias','set',url,a,'--scope','castreader'])
 actual={a:inspect(a) for a in aliases};assert set(actual.values())=={new}
except Exception:
 for a in aliases:run(['alias','set','castreader-content-m7sorm3jt-castreader.vercel.app',a,'--scope','castreader'])
 raise
(p/'website-promotion.json').write_text(json.dumps({'deployment':new,'source':'3b054ed2c195246880e61ac4744098cfc7af8d78','aliases':actual,'previous':old},indent=2));print('Both website aliases verified on '+new)
