import os,sys,subprocess
from pathlib import Path
p=Path(__file__).resolve().parent
context=p/'press-site'
env=os.environ.copy();env['VERCEL_TOKEN']=(Path.home()/'.config/castreader/vercel-token').read_text().strip()
r=subprocess.run(['vercel']+sys.argv[1:],cwd=context,env=env,capture_output=True,text=True)
print(r.stdout);print(r.stderr)
(p/'vercel-last-stdout.txt').write_text(r.stdout)
(p/'vercel-last-stderr.txt').write_text(r.stderr)
raise SystemExit(r.returncode)
