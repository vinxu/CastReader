"""Archive the verified R134 delta and v2 routing on the existing private US store.

This adds to the verified full R133 recovery set; it never rewrites a serving
release. The approved credential is sent in SSH stdin, never printed or saved.
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
MODEL_REPO = Path('/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-silent-separators-20260907')
PLAN = HERE / 'model-plan.json'
EXPECTED_COMMIT = '5dddb1b9f96e431e76e4c3a8305e1a3fe3963c52'
EXPECTED_TREE = 'e1e37519b0f53dd9e16dbc2c9b366e1e2fd343df4e40de56036e45ab898c47c6'
EXPECTED_MARKER = '46194b37bfd80a48b4d674e5156b83e5015c82f69471d9adcd4c4fdf5fe28589'


def main():
    target = HERE / 'production-private-backup-readback.json'
    if target.exists():
        raise RuntimeError('local_immutable_receipt_already_exists')
    plan = json.loads(PLAN.read_text())
    if (plan['sourceCommit'] != EXPECTED_COMMIT or plan['candidateTreeSha256'] != EXPECTED_TREE
            or plan['installReceiptSha256'] != EXPECTED_MARKER):
        raise RuntimeError('reviewed_model_plan_changed')
    report_root = HERE.parent
    base = report_root.parent / 'backend-audio-rollout-20260906/us-kokoro/r133-production-recovery-index.json'
    base_raw = base.read_bytes()
    if hashlib.sha256(base_raw).hexdigest() != plan['recoveryIndexSha256']:
        raise RuntimeError('verified_recovery_parent_changed')
    secret_source = Path('/Users/xuxuheng/Documents/MyProject/cast-reader-api/reader-service/supabase_storage.py').read_text()
    def assignment(name):
        return re.search(r'^\s*' + name + r'''\s*=\s*["']([^"']+)["']''', secret_source, re.M).group(1)
    if assignment('SUPABASE_URL').rstrip('/') != 'https://zqxgmqygirtpttnrvjpf.supabase.co':
        raise RuntimeError('approved_global_storage_authority_changed')
    key = assignment('SUPABASE_KEY')
    part = key.split('.')[1]
    claims = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
    if claims.get('role') != 'service_role' or claims.get('ref') not in (None, 'zqxgmqygirtpttnrvjpf'):
        raise RuntimeError('approved_global_storage_scope_changed')
    utility = Path('/Users/xuxuheng/Documents/MyProject/castreader-tts-compatible-fix/verification/supabase_tus_backup.py').read_text()
    host = (MODEL_REPO / 'deployment/r133_proxy_switch_host.py').read_text()
    context = {'plan': plan, 'parentRecoveryIndex': json.loads(base_raw)}
    code = 'KEY=' + repr(key) + '\nTOOL=' + repr(utility) + '\nHELPER=' + repr(host) + '\nCONTEXT=' + repr(context) + '\n' + REMOTE
    result = subprocess.run(['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                             'castreader-us4090', '/venv/main/bin/python -B -'],
                            input=code, text=True, capture_output=True, timeout=240)
    rows = [line.removeprefix('R134_BACKUP=') for line in result.stdout.splitlines() if line.startswith('R134_BACKUP=')]
    if result.returncode or len(rows) != 1:
        raise RuntimeError('private_backup_failed_no_raw_response_exported')
    receipt = json.loads(rows[0])
    if receipt.get('verified') is not True or receipt.get('public') is not False:
        raise RuntimeError('private_backup_receipt_not_verified')
    target.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'verified': receipt.get('verified'), 'public': receipt.get('public'), 'receipt': str(target)}))


REMOTE = r'''
from pathlib import Path
import base64, hashlib, io, json, os, tarfile, types
try:
    legacy = types.ModuleType('reviewed_r133_utility')
    exec(HELPER, legacy.__dict__)
    module = {'__name__':'private_us_backup_tool'}
    exec(TOOL, module)
    root = Path('/workspace/castreader-runtime')
    release = root/'releases/20260907-kokoro-silent-separators-us-r134'
    proxy = root/'proxy-releases/us-tts-origin-proxy-20260907-v2'
    plan = CONTEXT['plan']
    state_before = legacy.current_state()['state']
    if (state_before['proxyReleaseId'] != proxy.name
            or state_before['currentSlot'] != 'blue' or not state_before['slots']['blue']['enabled']
            or state_before['slots']['blue']['receiptSha256'] != plan['installReceiptSha256']
            or state_before['slots']['blue']['releaseId'] != release.name):
        raise RuntimeError('r134_not_the_verified_active_model')
    identity = legacy.listener(8880)
    if identity['cwd'] != str(release) or identity['pid'] != legacy.supervisor_pid('castreader-tts'):
        raise RuntimeError('r134_process_directory_differs')
    proxy_identity = legacy.listener(8889)
    argv = (Path('/proc')/str(proxy_identity['pid'])/'cmdline').read_bytes().decode().split('\0')
    if (proxy_identity['pid'] != legacy.supervisor_pid('castreader-tts-origin-proxy')
            or proxy_identity['cwd'] != str(proxy)
            or argv[1:3] != ['-B',str(proxy/'r133_stable_proxy.py')]):
        raise RuntimeError('live_proxy_process_identity_differs')
    inventory = legacy.runtime_tree(release)
    inventory.pop('R134_INSTALL.json', None)
    if legacy.tree_digest(inventory) != plan['candidateTreeSha256']:
        raise RuntimeError('complete_runtime_inventory_changed')
    marker = (release/'R134_INSTALL.json').read_bytes()
    if hashlib.sha256(marker).hexdigest() != plan['installReceiptSha256']:
        raise RuntimeError('install_marker_changed')
    paths = {('runtime/'+name):release/name for name in plan['overlay']}
    paths['runtime/R134_INSTALL.json'] = release/'R134_INSTALL.json'
    paths.update({
        'proxy/r133_stable_proxy.py':proxy/'r133_stable_proxy.py',
        'proxy/RELEASE.json':proxy/'RELEASE.json',
        'config/blue.conf':Path('/etc/supervisor/conf.d/castreader-tts.conf'),
        'config/green.conf':Path('/etc/supervisor/conf.d/castreader-tts-r133-green.conf'),
        'config/proxy.conf':Path('/etc/supervisor/conf.d/castreader-tts-origin-proxy.conf'),
        'config/model-wrapper.sh':Path('/opt/supervisor-scripts/castreader-tts.sh'),
    })
    files = {name:path.read_bytes() for name,path in paths.items()}
    for name,row in plan['overlay'].items():
        if hashlib.sha256(files['runtime/'+name]).hexdigest() != row['sha256']:
            raise RuntimeError('model_overlay_changed')
    if hashlib.sha256(files['proxy/r133_stable_proxy.py']).hexdigest() != '0502fc2d9b3793be6309ae6f13ea544380404721857e55162b3eae060daa7eba':
        raise RuntimeError('proxy_binary_changed')
    if str((root/'current').resolve()) != str(release):
        raise RuntimeError('blue_startup_target_changed')
    metadata = {'schema':'castreader.us-r134-recovery-delta.v1', 'region':'us',
                'sourceCommit':plan['sourceCommit'], 'modelTreeSha256':plan['candidateTreeSha256'],
                'installReceiptSha256':plan['installReceiptSha256'], 'currentTarget':str(release),
                'modelProcess':identity,'proxyProcess':proxy_identity,
                'stateSnapshotForReviewNotBlindRestore':state_before,
                'restoreOrder':['restore verified complete R133 parent into a new release',
                                'overlay exact R134 files and verify full inventory',
                                'restore unchanged v2 proxy binary and reviewed configs',
                                'start and verify both local model slots',
                                'review saved route and perform operator CAS only after genuine clean state'],
                'parentRecoveryIndex':CONTEXT['parentRecoveryIndex'], 'runtimeInventory':inventory}
    files['metadata/recovery.json'] = json.dumps(metadata,sort_keys=True,indent=2).encode()
    archive_dir = root/'model-upgrades/20260907-silent-separators-r134'
    archive = archive_dir/'complete-production-delta.tar.gz'
    if not archive.exists():
        with tarfile.open(archive,'x:gz') as output:
            for name,raw in sorted(files.items()):
                member=tarfile.TarInfo(name);member.size=len(raw);member.mode=0o600
                output.addfile(member,io.BytesIO(raw))
        archive.chmod(0o600)
    with tarfile.open(archive) as saved:
        if {member.name:saved.extractfile(member).read() for member in saved} != files:
            raise RuntimeError('local_backup_readback_failed')
    if (not legacy.same_process(identity) or not legacy.same_process(proxy_identity)
            or legacy.current_state()['state'] != state_before
            or any(path.read_bytes()!=files[name] for name,path in paths.items())):
        raise RuntimeError('runtime_changed_during_archive')
    receipt = module['run_backup'](
        {'files':[{'path':str(archive),'object':'runtime-releases/us/20260907-kokoro-silent-separators-r134/complete-production-delta.tar.gz'}]},
        archive_dir/'private-transfer', archive_dir/'production-private-backup-readback.json', module['StorageHTTP'](KEY))
    print('R134_BACKUP='+json.dumps(receipt))
except Exception as error:
    print('R134_BACKUP_FAILURE='+type(error).__name__)
    raise SystemExit(1)
'''


if __name__ == '__main__':
    main()
