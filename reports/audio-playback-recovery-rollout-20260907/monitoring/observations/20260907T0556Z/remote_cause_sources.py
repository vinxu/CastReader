"""Read fixed production source spans for the observed exception; no imports."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json

base = Path('/workspace/castreader-runtime/releases/20260907-kokoro-silent-separators-us-r134')
site = Path('/venv/main/lib/python3.12/site-packages')
specs = [
    (base / 'api/src/inference/kokoro_v1.py', [(970, 986), (1058, 1072)]),
    (base / 'api/src/services/tts_service.py', [(178, 220)]),
    (site / 'misaki/ja.py', [(254, 277)]),
    (site / 'cutlet/cutlet.py', [(267, 284), (310, 375)]),
]
rows = []
for path, spans in specs:
    if not path.is_file():
        rows.append({'path': str(path), 'found': False})
        continue
    raw = path.read_bytes()
    assert len(raw) < 1000000
    lines = raw.decode().splitlines()
    rows.append({'path': str(path), 'found': True, 'sha256': hashlib.sha256(raw).hexdigest(),
                 'bytes': len(raw), 'lines': [{'line': n, 'code': lines[n - 1]}
                                            for low, high in spans for n in range(low, min(high, len(lines)) + 1)]})
print('SAFE_SOURCE=' + json.dumps({'schema': 'castreader.backend-exception-source-evidence.v1',
      'readOnly': True, 'productionModified': False, 'synthesisStarted': False,
      'collectedAtUTC': datetime.now(timezone.utc).isoformat(), 'sources': rows,
      'limitations': ['Installed dependency files are read without importing or executing model code.',
                      'Source SHA binds file content, while traceback file basenames alone do not identify every installed import path.']}))
