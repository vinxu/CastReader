import subprocess,json,hashlib
from pathlib import Path
REMOTE=r"""
import json,hashlib
from pathlib import Path
from datetime import datetime,timezone
p=Path('/var/lib/castreader-tts-origin-proxy/state.json');v=json.loads(p.read_bytes())
print('SAFE='+json.dumps({'readOnly':True,'capturedAtUTC':datetime.now(timezone.utc).isoformat(),'stateSha256':hashlib.sha256(p.read_bytes()).hexdigest(),'stateMtimeUTC':datetime.fromtimestamp(p.stat().st_mtime,timezone.utc).isoformat(),'selected':{k:v[k] for k in ['schema','revision','currentSlot','updatedAt','proxyReleaseId','slots'] if k in v},'operationKey':hashlib.sha256(str(v.get('lastOperationId','')).encode()).hexdigest()[:20]}))
"""
r=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10','castreader-us4090','/venv/main/bin/python -B -'],input=REMOTE,text=True,capture_output=True,timeout=30)
rows=[x[5:] for x in r.stdout.splitlines() if x.startswith('SAFE=')]
if r.returncode or len(rows)!=1:raise RuntimeError('state_read_failed')
v=json.loads(rows[0]);Path(__file__).with_name('proxy-state-readback.json').write_text(json.dumps(v,indent=2));print(json.dumps(v))
