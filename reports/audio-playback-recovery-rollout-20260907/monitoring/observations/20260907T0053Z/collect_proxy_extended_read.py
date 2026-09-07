"""One bounded read retry; only SSH duration differs from the existing collector."""
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
MONITORING = HERE.parent.parent
sys.path.insert(0, str(MONITORING))
spec = importlib.util.spec_from_file_location('proxy_read_retry', MONITORING / 'collect_proxy_events.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_run = subprocess.run

def bounded_run(command, **kwargs):
    if command != ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                   'castreader-us4090', '/venv/main/bin/python -B -']:
        raise ValueError('unexpected_subprocess_for_read_retry')
    if kwargs.get('timeout') != 60:
        raise ValueError('unexpected_original_read_deadline')
    kwargs['timeout'] = 180
    return original_run(command, **kwargs)

subprocess.run = bounded_run
started = time.monotonic()
receipt = {'schema': 'castreader.proxy-extended-read-receipt.v1',
    'startedAtUTC': datetime.now(timezone.utc).isoformat(), 'readOnly': True,
    'productionModified': False, 'synthesisStarted': False,
    'originalRemoteDeadlineSeconds': 60, 'retryRemoteDeadlineSeconds': 180,
    'sourceSha256': hashlib.sha256((MONITORING / 'collect_proxy_events.py').read_bytes()).hexdigest(),
    'wrapperSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'semanticsUnchanged': ['frozen identity', 'fixed window', '64 MiB scan limit',
        'sanitization', 'coverage checks', 'request grouping']}
try:
    code = module.main()
    receipt['exitCode'] = code
except Exception as error:
    code = 1
    receipt['collectionFailed'] = True
    receipt['errorClass'] = type(error).__name__
finally:
    subprocess.run = original_run
    receipt['elapsedSeconds'] = round(time.monotonic() - started, 3)
    receipt['finishedAtUTC'] = datetime.now(timezone.utc).isoformat()
    (HERE / 'proxy-extended-read-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'extendedReadReceipt': receipt}))
raise SystemExit(code)
