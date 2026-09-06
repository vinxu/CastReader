"""Read-only baseline capture; refuses a changed source/configuration/runtime."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE, text=True, timeout=10)


expected = [
    ('/opt/castreader-tts-gateway/gateway.mjs', 'EXPECTED_SOURCE_SHA256'),
    ('/etc/systemd/system/castreader-tts-gateway.service', '71b0ca830d4554851c11feab0bf48a271ded803558942d685a194ca68b17fca9'),
    ('/etc/caddy/Caddyfile', '243706a702274b86cea400b4ff0c627ddead335e2dfb457fe62303952b30bdd1'),
]
files = []
for name, digest in expected:
    raw = Path(name).read_bytes()
    require(hashlib.sha256(raw).hexdigest() == digest, 'reviewed production file changed')
    files.append({'path': name, 'sha256': digest, 'bytes': len(raw)})
fields = ['MainPID', 'NRestarts', 'ActiveState', 'SubState', 'DropInPaths', 'FragmentPath', 'ActiveEnterTimestamp']
raw = run('systemctl', 'show', 'castreader-tts-gateway.service', '--no-pager', *[argument for field in fields for argument in ('-p', field)])
service = dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)
require(service.get('ActiveState') == 'active' and service.get('SubState') == 'running', 'gateway not active')
require(service.get('DropInPaths') == '' and service.get('FragmentPath') == expected[1][0], 'service configuration identity differs')
pid = service['MainPID']
require(pid.isdecimal() and int(pid) > 1, 'invalid gateway PID')
process = Path('/proc')/pid
argv = (process/'cmdline').read_bytes().split(b'\0')
require(Path(argv[0].decode()).resolve() == Path('/usr/bin/node').resolve(), 'runtime executable differs')
require(len(argv) >= 2 and argv[1].decode() == expected[0][0], 'runtime source path differs')
require(os.readlink(process/'cwd') == '/opt/castreader-tts-gateway', 'runtime cwd differs')
listeners = re.findall(r'pid=(\d+)', run('ss', '-H', '-lntp', 'sport = :7778'))
require(sorted(set(listeners)) == [pid], 'service does not exclusively own gateway port')
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open('http://127.0.0.1:7778/health', timeout=3) as response:
    health = json.load(response)
require(health.get('ok') is True, 'gateway health differs')
require(run('systemctl', 'show', 'castreader-tts-gateway.service', '-p', 'MainPID', '--value').strip() == pid, 'process moved during capture')
for name, digest in expected:
    require(hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest, 'file moved during capture')
print(json.dumps({'capturedAtUtc': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
    'readOnly': True, 'productionModified': False, 'synthesisStarted': False,
    'files': files, 'service': service, 'inFlight': health.get('in_flight'),
    'protectedCaddyPid': run('systemctl', 'show', 'caddy', '-p', 'MainPID', '--value').strip(),
    'protectedQuickreadPids': sorted(set(re.findall(r'pid=(\d+)', run('ss', '-H', '-lntp', 'sport = :7777'))))}))
