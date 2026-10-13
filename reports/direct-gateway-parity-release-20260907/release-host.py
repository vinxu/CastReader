"""Fixed US direct-gateway release; PAYLOAD is supplied by the reviewed operator.

Stage validates a private backup and a loopback-only candidate. Apply temporarily
routes new connections to that candidate, drains the existing process, replaces
its source, then restores the original Caddy route and retires the candidate.
"""
import base64
import fcntl
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tarfile
import time
import urllib.request


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True, timeout=30)


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def atomic(path, raw, mode=0o644):
    temporary = path.with_name(path.name + '.release-tmp')
    with temporary.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.chmod(mode)
    os.replace(temporary, path)


root = Path('/opt/castreader-tts-gateway')
live = root / 'gateway.mjs'
unit = Path('/etc/systemd/system/castreader-tts-gateway.service')
caddy = Path('/etc/caddy/Caddyfile')
release = root / 'releases' / '20260907-preset-parity'
backup = Path('/var/lib/castreader-tts-release/20260907-preset-parity')
shadow_name = 'castreader-tts-gateway-shadow-preset-parity.service'
shadow_unit = unit.with_name(shadow_name)
expected = PAYLOAD['baseline']
new_source = base64.b64decode(PAYLOAD['sourceBase64'])
require(digest(new_source) == PAYLOAD['sourceSha256'], 'candidate source digest mismatch')


def health(port):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(f'http://127.0.0.1:{port}/health', headers={'Connection':'close'})
    with opener.open(request, timeout=3) as response:
        body = json.load(response)
    require(body.get('ok') is True, 'unhealthy gateway')
    return body


def wait_health(port):
    for _ in range(30):
        try:
            return health(port)
        except Exception:
            time.sleep(.25)
    raise RuntimeError('gateway did not become healthy')


def pending_tcp_sockets(output):
    """Ignore listener backlog and fully settled TIME-WAIT, never live senders."""
    pending = []
    for line in output.splitlines():
        fields = line.split()
        require(len(fields) >= 5, 'unexpected TCP socket inventory')
        state = fields[0]
        require(fields[1].isdigit() and fields[2].isdigit(), 'unexpected TCP queue inventory')
        recvq, sendq = int(fields[1]), int(fields[2])
        if state == 'LISTEN':
            continue
        if state == 'TIME-WAIT' and recvq == sendq == 0:
            continue
        pending.append({'state':state,'recvQueueBytes':recvq,'sendQueueBytes':sendq})
    return pending


def drain(port, timeout_seconds=140, stable_seconds=6):
    # response.end() may precede finish by many seconds. in_flight alone cannot
    # prove that audio has left user-space/kernel queues. Keep every established
    # or closing socket alive until it disappears (or settles in TIME-WAIT).
    deadline = time.monotonic() + timeout_seconds
    quiet_since = None
    stable_observations = 0
    while time.monotonic() < deadline:
        status = health(port)  # Explicit short connection, body fully consumed.
        time.sleep(.1)        # Let that probe's close complete before inspection.
        pending = pending_tcp_sockets(run('ss','-H','-tan',f'sport = :{port}'))
        observed = time.monotonic()
        if status.get('in_flight') == 0 and not pending:
            quiet_since = observed if quiet_since is None else quiet_since
            stable_observations += 1
            # Longer than the gateway's configured 5-second keepalive, plus at
            # least two independent health and socket observations.
            if stable_observations >= 2 and observed - quiet_since >= stable_seconds:
                return
        else:
            quiet_since = None
            stable_observations = 0
        time.sleep(.5)
    raise RuntimeError('gateway response sockets have not drained; leave both services available')


def pid(name):
    value = run('systemctl', 'show', name, '-p', 'MainPID', '--value').strip()
    require(value.isdecimal() and int(value) > 1, f'{name} has no live MainPID')
    return value


def listener_pids(port):
    output = run('ss', '-H', '-lntp', f'sport = :{port}')
    values = sorted(set(re.findall(r'pid=(\d+)', output)))
    require(len(values) == 1, f'expected one listener on {port}')
    return values


def gateway_identity(name, port, source_path, source_sha256):
    require(run('systemctl', 'is-active', name).strip() == 'active', f'{name} is not active')
    main_pid = pid(name)
    require(listener_pids(port) == [main_pid], f'{name} does not own port {port}')
    process = Path('/proc') / main_pid
    require(process.exists(), f'{name} process disappeared')
    argv = (process / 'cmdline').read_bytes().split(b'\0')
    require(argv and Path(argv[0].decode()).resolve() == Path('/usr/bin/node').resolve(), 'gateway executable changed')
    require(len(argv) >= 2 and argv[1].decode() == str(source_path), 'gateway source argv changed')
    require(os.readlink(process / 'cwd') == str(root), 'gateway working directory changed')
    require(digest(source_path.read_bytes()) == source_sha256, 'gateway source bytes changed')
    status = health(port)
    return {'MainPID':main_pid, 'argvSha256':digest((process/'cmdline').read_bytes()),
            'cwd':os.readlink(process/'cwd'), 'inFlight':status.get('in_flight')}


def caddy_dials(config, hostname):
    dials = []

    def visit(value, matched=False):
        if isinstance(value, dict):
            local_match = matched
            matches = value.get('match')
            if isinstance(matches, list):
                local_match = local_match or any(
                    isinstance(item, dict) and hostname in item.get('host', [])
                    for item in matches
                )
            if local_match and isinstance(value.get('dial'), str):
                dials.append(value['dial'])
            for child in value.values():
                visit(child, local_match)
        elif isinstance(value, list):
            for child in value:
                visit(child, matched)

    visit(config)
    return sorted(set(dials))


def caddy_runtime_config():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open('http://127.0.0.1:2019/config/', timeout=3) as response:
        return json.load(response)


def adapted_caddy(raw):
    require(caddy.read_bytes() == raw, 'Caddy bytes changed before adaptation')
    # Preserve the real config filename: file_server automatically hides it and
    # adapting stdin would create a misleading hide-path-only difference.
    adapted = subprocess.run(['caddy','adapt','--config',str(caddy),'--adapter','caddyfile'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    require(adapted.returncode == 0, 'Caddy configuration could not be adapted')
    require(caddy.read_bytes() == raw, 'Caddy bytes changed during adaptation')
    return json.loads(adapted.stdout)


def caddy_runtime_matches(raw):
    # Includes QuickRead and every non-TTS setting: a runtime-only admin API edit
    # must never be silently replaced by a file-based reload.
    expected_config = adapted_caddy(raw)
    require(caddy_runtime_config() == expected_config, 'active Caddy configuration changed independently')


def caddy_runtime_dials(hostname):
    return caddy_dials(caddy_runtime_config(), hostname)


def public_health():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    last_error = None
    for _ in range(10):
        try:
            with opener.open('https://tts.castreader.ai/health', timeout=5) as response:
                body = json.load(response)
            require(body.get('ok') is True, 'public gateway is unhealthy')
            return body
        except Exception as error:
            last_error = error
            time.sleep(.5)
    raise RuntimeError('public gateway did not become healthy') from last_error


def caddy_ready(expected_raw, expected_port=7778):
    require(caddy.read_bytes() == expected_raw, 'Caddy bytes differ')
    require(run('systemctl', 'is-active', 'caddy').strip() == 'active', 'Caddy is not active')
    run('caddy', 'validate', '--config', str(caddy), '--adapter', 'caddyfile')
    require(caddy_runtime_dials('tts.castreader.ai') == [f'127.0.0.1:{expected_port}'],
            'live Caddy TTS route differs from the reviewed target')
    public_health()


def check_baseline():
    for row in expected['files']:
        require(digest(Path(row['path']).read_bytes()) == row['sha256'], 'baseline file moved: ' + row['path'])
    caddy_runtime_matches(caddy.read_bytes())
    require(pid('castreader-tts-gateway.service') == expected['service']['MainPID'], 'baseline PID moved')
    require(protected_pids()=={'caddy':expected['protectedCaddyPid'],'quickreadListeners':expected['protectedQuickreadPids']},'protected VPS service identity moved')


def check_offhost_backup(staged, phase='baseline'):
    require(phase in ('baseline','production'),'unknown backup phase')
    receipt_name = 'offhost-readback.json' if phase == 'baseline' else 'offhost-production-readback.json'
    self_name = 'offhost-receipt-readback.json' if phase == 'baseline' else 'offhost-production-receipt-readback.json'
    receipt_path = backup / receipt_name
    require(receipt_path.is_file() and not receipt_path.is_symlink(), 'off-host readback receipt is missing')
    receipt = json.loads(receipt_path.read_text())
    require(receipt.get('schema') == 'castreader.backup-readback.v1', 'unexpected backup receipt schema')
    require(receipt.get('verified') is True and receipt.get('public') is False, 'backup is not verified private storage')
    require(receipt.get('project_ref') == 'zqxgmqygirtpttnrvjpf', 'backup project differs')
    require(receipt.get('bucket') == 'castreader-tts-backups', 'backup bucket differs')
    require(receipt.get('expected_files') == receipt.get('verified_files') == 1, 'backup file count differs')
    require(receipt.get('expected_bytes') == receipt.get('downloaded_bytes') == staged['privateBackupBytes'],
            'backup total bytes differ')
    rows = receipt.get('files')
    require(isinstance(rows, list) and len(rows) == 1, 'backup receipt has unexpected objects')
    row = rows[0]
    require(row.get('object_base') == f'runtime-releases/us/20260907-direct-gateway-preset-parity/complete-{phase}.tar.gz',
            'backup object differs')
    require(row.get('verified') is True, 'backup object was not verified')
    require(row.get('bytes') == row.get('downloaded_bytes') == staged['privateBackupBytes'],
            'backup object bytes differ')
    require(row.get('sha256') == row.get('readback_sha256') == staged['privateBackupSha256'],
            'backup object digest differs')
    parts = row.get('parts')
    require(isinstance(parts, list) and parts, 'backup object has no verified parts')
    require(sum(part.get('bytes', -1) for part in parts) == staged['privateBackupBytes'],
            'backup parts do not cover the archive')
    require(all(part.get('verified') is True and part.get('sha256') == part.get('readback_sha256')
                for part in parts), 'backup part readback differs')
    self_path=backup/self_name
    require(self_path.is_file() and not self_path.is_symlink(),'receipt self-readback is missing')
    own=json.loads(self_path.read_text())
    require(own.get('verified') is True and own.get('public') is False,'receipt self-readback not verified private')
    require(own.get('project_ref')=='zqxgmqygirtpttnrvjpf' and own.get('bucket')=='castreader-tts-backups','receipt storage scope differs')
    own_rows=own.get('files',[])
    require(len(own_rows)==1 and own.get('expected_files')==own.get('verified_files')==1,'unexpected self-readback files')
    own_row=own_rows[0]
    require(own_row.get('object_base')=='runtime-releases/us/20260907-direct-gateway-preset-parity/metadata/'+receipt_name,'receipt object differs')
    require(own_row.get('verified') is True and own_row.get('sha256')==own_row.get('readback_sha256')==digest(receipt_path.read_bytes()),'receipt self digest differs')
    require(own_row.get('bytes')==own_row.get('downloaded_bytes')==receipt_path.stat().st_size,'receipt self bytes differ')
    return {'receiptSha256':digest(receipt_path.read_bytes()),'receiptSelfReadbackSha256':digest(self_path.read_bytes()),'createdAt':receipt.get('created_at')}


def probe(port, label):
    results = []
    text = 'This is a continuity check. Every sentence needs its complete audio. Reading should continue until this final word is spoken.'
    for contract in ['omitted', True, False]:
        body = dict(model='kokoro', input=text, voice='af_heart', voice_code='af_heart', language='en',
                    response_format='mp3', return_timestamps=True, speed=1)
        if contract != 'omitted':
            body['stream'] = contract
        request = urllib.request.Request(f'http://127.0.0.1:{port}/api/captioned_speech_partly',
            data=json.dumps(body).encode(), headers={'Content-Type':'application/json',
                'X-CastReader-Platform':'ops', 'X-CastReader-Version':'release-preset-parity'}, method='POST')
        started = time.monotonic()
        with urllib.request.urlopen(request, timeout=125) as response:
            result = json.load(response)
        audio = base64.b64decode(result.get('audio', ''), validate=True)
        require(bool(audio), 'empty audio')
        require(not result.get('unprocessed_text'), 'unexpected remainder in short fixed probe')
        decoded = subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-f','s16le','-ac','1','-ar','24000','pipe:1'],
                                 input=audio, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        require(decoded.returncode == 0 and len(decoded.stdout) > 0, 'audio did not completely decode')
        results.append({'contract':contract, 'audioBytes':len(audio), 'pcmSamples':len(decoded.stdout)//2,
                        'audioSha256':digest(audio), 'elapsedSeconds':round(time.monotonic()-started,3)})
    require(len({x['pcmSamples'] for x in results}) == 1, 'legacy contracts changed audio length')
    return {'label':label, 'observedAt':now(), 'fixedNonUserText':True, 'results':results}


def persist(name, data):
    atomic(backup / name, (json.dumps(data, indent=2)+'\n').encode(), 0o600)


def reload_caddy(expected_raw, target_raw):
    require(caddy.read_bytes() == expected_raw, 'Caddy changed independently; refusing overwrite')
    caddy_runtime_matches(expected_raw)
    candidate = backup / 'Caddyfile.candidate'
    atomic(candidate, target_raw, 0o600)
    run('caddy', 'validate', '--config', str(candidate), '--adapter', 'caddyfile')
    caddy_runtime_matches(expected_raw)
    # Recheck after external validation, immediately before replacing live bytes.
    require(caddy.read_bytes() == expected_raw, 'Caddy changed during validation; refusing overwrite')
    atomic(caddy, target_raw)
    run('systemctl', 'reload', 'caddy')
    require(caddy.read_bytes() == target_raw, 'Caddy file changed during reload')
    caddy_runtime_matches(target_raw)


def healthy(port):
    try:
        health(port)
        return True
    except Exception:
        return False


def verify_production(source_sha256, caddy_raw):
    identity = gateway_identity('castreader-tts-gateway.service', 7778, live, source_sha256)
    caddy_ready(caddy_raw)
    return identity


def restore_original(old_caddy, shadow_caddy, staged, source_replaced):
    """Restore the complete baseline while the verified shadow remains available."""
    require(caddy.read_bytes() in (old_caddy, shadow_caddy),
            'Caddy changed independently; shadow remains available')
    gateway_identity(shadow_name, 17778, release/'gateway.mjs', staged['sourceSha256'])
    baseline_source = (backup/'gateway.mjs').read_bytes()
    require(digest(baseline_source) == expected['files'][0]['sha256'], 'baseline backup source differs')

    baseline_healthy = False
    if not source_replaced and digest(live.read_bytes()) == expected['files'][0]['sha256']:
        try:
            gateway_identity('castreader-tts-gateway.service', 7778, live,
                             expected['files'][0]['sha256'])
            baseline_healthy = True
        except Exception:
            baseline_healthy = False

    # Route new connections to the already-verified shadow before replacing or
    # restarting an unhealthy 7778 owner. Never overwrite an independent Caddy edit.
    if not baseline_healthy and caddy.read_bytes() == old_caddy:
        reload_caddy(old_caddy, shadow_caddy)
    if not baseline_healthy:
        if healthy(7778):
            drain(7778)
        require(digest(live.read_bytes()) in (expected['files'][0]['sha256'], digest(new_source)),
                'live source changed independently')
        atomic(live, baseline_source)
        run('systemctl', 'restart', 'castreader-tts-gateway.service')
        wait_health(7778)
        gateway_identity('castreader-tts-gateway.service', 7778, live, expected['files'][0]['sha256'])

    require(protected_pids() == staged['protectedPids'], 'unrelated service identity changed during rollback')
    if caddy.read_bytes() == shadow_caddy:
        reload_caddy(shadow_caddy, old_caddy)
    restored = verify_production(expected['files'][0]['sha256'], old_caddy)
    drain(17778)
    run('systemctl', 'disable', '--now', shadow_name)
    restored = verify_production(expected['files'][0]['sha256'], old_caddy)
    require(protected_pids() == staged['protectedPids'], 'unrelated service identity changed after rollback')
    return restored


action = PAYLOAD['action']
lock = open('/var/lock/castreader-direct-tts-release.lock', 'a')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


def interrupted(signum, frame):
    raise InterruptedError('release interrupted')


signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGHUP, interrupted)
signal.signal(signal.SIGINT, interrupted)


def protected_pids():
    listeners = run('ss','-H','-lntp','sport = :7777')
    return {'caddy':pid('caddy'), 'quickreadListeners':sorted(re.findall(r'pid=(\d+)',listeners))}


if action == 'stage':
    check_baseline()
    require(not shadow_unit.exists() and not release.exists(), 'candidate already staged; inspect existing state')
    require(backup.is_dir(), 'verified baseline snapshot is required before staging')
    captured=json.loads((backup/'snapshot-baseline.json').read_text())
    require(captured['sourceSha256']==expected['files'][0]['sha256'],'snapshot source differs')
    check_offhost_backup({'privateBackupSha256':captured['archiveSha256'],'privateBackupBytes':captured['archiveBytes']})
    run('which','ffmpeg')
    original={name:(backup/name).read_bytes() for name in ['gateway.mjs','service.unit','Caddyfile']}
    for name,path in [('gateway.mjs',live),('service.unit',unit),('Caddyfile',caddy)]:
        require(path.read_bytes()==original[name],'baseline changed before staging')
    archive=backup/'complete-baseline.tar.gz'
    release.mkdir(parents=True, mode=0o755)
    atomic(release/'gateway.mjs', new_source)
    run('node','--check',str(release/'gateway.mjs'))
    service = original['service.unit'].decode()
    require(service.count('TTS_GATEWAY_PORT=7778') == 1, 'unexpected service port shape')
    require(service.count('ExecStart=/usr/bin/node /opt/castreader-tts-gateway/gateway.mjs') == 1, 'unexpected exec shape')
    service = service.replace('TTS_GATEWAY_PORT=7778','TTS_GATEWAY_PORT=17778').replace(
        'ExecStart=/usr/bin/node /opt/castreader-tts-gateway/gateway.mjs',f'ExecStart=/usr/bin/node {release}/gateway.mjs')
    atomic(shadow_unit,service.encode())
    run('systemctl','daemon-reload')
    run('systemctl','start',shadow_name)
    wait_health(17778)
    gateway_identity(shadow_name,17778,release/'gateway.mjs',digest(new_source))
    validation = probe(17778,'loopback candidate')
    gateway_identity(shadow_name,17778,release/'gateway.mjs',digest(new_source))
    check_baseline()
    receipt = {'status':'staged_and_verified','observedAt':now(),'sourceCommit':PAYLOAD['sourceCommit'],
               'sourceSha256':digest(new_source),'baseline':expected,'shadowPid':pid(shadow_name),
               'shadowUnitSha256':digest(shadow_unit.read_bytes()),'protectedPids':protected_pids(),
               'privateBackupSha256':digest(archive.read_bytes()),'privateBackupBytes':archive.stat().st_size,
               'privateBackupReadback':True,'validation':validation}
    persist('stage.json',receipt)
    print(json.dumps(receipt),flush=True)
elif action == 'apply':
    staged = json.loads((backup/'stage.json').read_text())
    require(staged['sourceSha256'] == digest(new_source), 'staged source mismatch')
    require(digest((release/'gateway.mjs').read_bytes()) == digest(new_source), 'candidate bytes changed')
    require(pid(shadow_name) == staged['shadowPid'], 'candidate process changed after validation')
    require(digest(shadow_unit.read_bytes()) == staged['shadowUnitSha256'], 'candidate unit changed')
    require(protected_pids() == staged['protectedPids'], 'unrelated service moved before apply')
    check_baseline()
    offhost = check_offhost_backup(staged)
    gateway_identity(shadow_name,17778,release/'gateway.mjs',digest(new_source))
    old_caddy = (backup/'Caddyfile').read_bytes()
    require(old_caddy.count(b'reverse_proxy 127.0.0.1:7778') == 2, 'unexpected Caddy gateway routes')
    shadow_caddy = old_caddy.replace(b'reverse_proxy 127.0.0.1:7778',b'reverse_proxy 127.0.0.1:17778')
    switched_at = None
    source_replaced = False
    committed = False
    try:
        # If the host reboots mid-transaction the temporary live target must boot.
        run('systemctl','enable',shadow_name)
        reload_caddy(old_caddy,shadow_caddy)
        caddy_ready(shadow_caddy,17778)
        gateway_identity(shadow_name,17778,release/'gateway.mjs',digest(new_source))
        switched_at = now()
        persist('transaction.json',{'phase':'shadow_serving','switchedAt':switched_at})
        drain(7778)
        require(digest(live.read_bytes()) == expected['files'][0]['sha256'], 'live source changed before replacement')
        atomic(live,new_source)
        source_replaced = True
        run('systemctl','restart','castreader-tts-gateway.service')
        wait_health(7778)
        validation = probe(7778,'permanent gateway before route restore')
        reload_caddy(shadow_caddy,old_caddy)
        require(protected_pids() == staged['protectedPids'], 'unrelated service identity changed')
        identity = verify_production(digest(new_source), old_caddy)
        receipt = {'status':'production_verified','firstNewTrafficAt':switched_at,'verifiedAt':now(),
                   'sourceCommit':PAYLOAD['sourceCommit'],'sourceSha256':digest(live.read_bytes()),
                   'mainPid':identity['MainPID'],'runtimeIdentity':identity,
                   'caddyRestoredExactly':caddy.read_bytes()==old_caddy,
                   'oldRequestsDrainedBeforeRestart':True,'shadowCleanupPending':True,
                   'offhostBackup':offhost,'validation':validation}
        receipt['protectedPids'] = protected_pids()
        persist('production.json',receipt)
        committed = True
        drain(17778)
        run('systemctl','disable','--now',shadow_name)
        identity = verify_production(digest(new_source), old_caddy)
        require(protected_pids() == staged['protectedPids'], 'unrelated service identity changed after cleanup')
        cleanup = {'status':'production_cleanup_complete','completedAt':now(),
                   'mainPid':identity['MainPID'],'shadowStopped':True,'shadowDrainedBeforeStop':True}
        persist('cleanup.json', cleanup)
        print(json.dumps({**receipt,'status':'production','completedAt':cleanup['completedAt'],
                          'shadowCleanupPending':False,'shadowDrainedBeforeStop':True}),flush=True)
    except BaseException as error:
        durable_commit = backup/'production.json'
        if committed or durable_commit.is_file():
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(sig, signal.SIG_IGN)
            cleanup_failure = {'status':'production_committed_cleanup_failed',
                               'errorType':type(error).__name__,'observedAt':now(),
                               'rollbackAttempted':False,
                               'reason':'verified production route and runtime were durably committed before shadow cleanup'}
            persist('cleanup-failure.json', cleanup_failure)
            print(json.dumps(cleanup_failure),flush=True)
            raise
        # Keep the shadow running until the original complete service is restored.
        # Never overwrite a different operator's Caddy configuration.
        recovery = {'status':'failed','errorType':type(error).__name__,'observedAt':now(), 'rollback':'not_verified'}
        try:
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(sig, signal.SIG_IGN)
            restored = restore_original(old_caddy, shadow_caddy, staged, source_replaced)
            recovery['rollback']='original_source_and_routes_verified'
            recovery['restoredMainPid'] = restored['MainPID']
        except BaseException as rollback_error:
            recovery['rollbackErrorType']=type(rollback_error).__name__
            try:
                recovery['shadowPreserved']=run('systemctl','is-active',shadow_name).strip() == 'active'
            except BaseException:
                recovery['shadowPreserved']='unknown'
        persist('failure.json',recovery)
        print(json.dumps(recovery),flush=True)
        raise
else:
    raise RuntimeError('unknown release action')
