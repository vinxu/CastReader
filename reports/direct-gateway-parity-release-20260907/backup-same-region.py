"""Upload/read back the immutable snapshot and then its receipt, privately.

Credentials enter through SUPABASE_SERVICE_ROLE_KEY or a caller-selected 0600
key-only local secret file. No credential is written to artifacts or argv.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess

ROOT = Path(__file__).resolve().parent
PLAN = json.loads((ROOT / 'release-plan.json').read_text())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('phase', choices=['baseline', 'production'])
args = parser.parse_args()
key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY')
if not key and os.environ.get('CASTREADER_BACKUP_KEY_FILE'):
    path = Path(os.environ['CASTREADER_BACKUP_KEY_FILE'])
    info = path.stat()
    if path.is_symlink() or not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
        raise SystemExit('backup key file must be a private regular file')
    if info.st_uid != os.getuid():
        raise SystemExit('backup key file owner differs')
    key = path.read_text().strip()
if not key:
    raise SystemExit('pending approved Global backup credential in environment or local secret store')
try:
    part = key.split('.')[1]
    claims = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
    if claims.get('role') != 'service_role' or claims.get('ref') not in (None, 'zqxgmqygirtpttnrvjpf'):
        raise ValueError()
except Exception:
    raise SystemExit('Global backup credential scope validation failed') from None
tool = (ROOT / 'supabase_tus_backup.py').read_text()
if hashlib.sha256(tool.encode()).hexdigest() != PLAN['backupToolSha256']:
    raise SystemExit('reviewed immutable backup tool changed')

program = 'KEY=' + repr(key) + '\nTOOL=' + repr(tool) + '\nPHASE=' + repr(args.phase) + '\n' + '''
import hashlib,json
from pathlib import Path
try:
    module={'__name__':'castreader_backup_tool'}
    exec(TOOL,module)
    root=Path('/var/lib/castreader-tts-release/20260907-preset-parity')
    snapshot=json.loads((root/('snapshot-'+PHASE+'.json')).read_text())
    archive=root/('complete-'+PHASE+'.tar.gz')
    hasher=hashlib.sha256()
    with archive.open('rb') as stream:
        for data in iter(lambda:stream.read(1024*1024),b''): hasher.update(data)
    if hasher.hexdigest()!=snapshot['archiveSha256'] or archive.stat().st_size!=snapshot['archiveBytes']:
        raise RuntimeError('immutable snapshot changed')
    prefix='runtime-releases/us/20260907-direct-gateway-preset-parity/'
    name='offhost-readback.json' if PHASE=='baseline' else 'offhost-production-readback.json'
    receipt_path=root/name
    http=module['StorageHTTP'](KEY)
    if receipt_path.exists():
        receipt=json.loads(receipt_path.read_text())
        files=receipt.get('files',[])
        if receipt.get('verified') is not True or len(files)!=1 or files[0].get('sha256')!=snapshot['archiveSha256']:
            raise RuntimeError('existing immutable readback receipt differs')
    else:
        receipt=module['run_backup']({'files':[{'path':str(archive),'object':prefix+archive.name,
            'part_bytes':32*1024*1024}]},root/('offhost-transfer-'+PHASE),receipt_path,http)
    own_name='offhost-receipt-readback.json' if PHASE=='baseline' else 'offhost-production-receipt-readback.json'
    own_path=root/own_name
    if own_path.exists():
        own=json.loads(own_path.read_text())
        rows=own.get('files',[])
        if own.get('verified') is not True or len(rows)!=1 or rows[0].get('sha256')!=hashlib.sha256(receipt_path.read_bytes()).hexdigest():
            raise RuntimeError('existing receipt self-readback differs')
    else:
        own=module['run_backup']({'files':[{'path':str(receipt_path),'object':prefix+'metadata/'+name}]},
            root/('offhost-receipt-transfer-'+PHASE),own_path,http)
    print(json.dumps({'phase':PHASE,'archiveReadback':receipt,'receiptSelfReadback':own,
        'verified':receipt.get('verified') is True and own.get('verified') is True}))
except Exception as error:
    print(json.dumps({'status':'failed','phase':PHASE,'errorType':type(error).__name__}))
    raise SystemExit(1)
'''
result = subprocess.run(['ssh', '-F', str(ROOT / 'ssh-config'), PLAN['hostAlias'], 'python3', '-B', '-'],
                        input=program, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=900)
if result.stdout:
    try:
        receipt = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise SystemExit('backup did not return a sanitized receipt; raw output withheld')
    if result.returncode or receipt.get('verified') is not True:
        print(json.dumps(receipt))
        raise SystemExit(result.returncode or 1)
    name = 'offhost-' + args.phase + '-combined-receipt.json'
    target = ROOT / name
    if target.exists():
        if json.loads(target.read_text()) != receipt:
            raise SystemExit('local immutable combined receipt already differs')
    else:
        with target.open('x') as stream:
            stream.write(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))
if result.returncode:
    print('Private backup/readback incomplete; no credential or raw server error exported.')
raise SystemExit(result.returncode)
