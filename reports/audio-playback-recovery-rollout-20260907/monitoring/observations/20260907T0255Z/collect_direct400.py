#!/usr/bin/env python3
"""One fixed read-only incident window; all raw journal parsing stays remote."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPORTS = Path('/Users/xuxuheng/Documents/CastReader/reports')
helper_path = REPORTS / "backend-audio-iteration-20260906/monitoring/remote_tts_gateway_snapshot.py"
receipt_path = REPORTS / "audio-errors-root-cause-20260906/direct-gateway-release-20260907/status-receipt.json"
receipt_raw = receipt_path.read_bytes()
release = json.loads(receipt_raw)["production.json"]
helper_raw = helper_path.read_bytes()
prefix = "SANITIZED_DIRECT400="
remote = """
import types, json, hashlib
from datetime import datetime, timezone
from pathlib import Path
module = types.ModuleType('audited_gateway_parser')
exec(compile(HELPER_SOURCE, 'remote_tts_gateway_snapshot.py', 'exec'), module.__dict__)
start = module.parse_timestamp('2026-09-07T01:55:18.503Z')
end = module.parse_timestamp('2026-09-07T02:56:05.405297Z')
active_from = module.parse_timestamp(RELEASE['firstNewTrafficAt'])
entries, parse_errors, truncated = module.read_journal(start, end)
requests = {}
incomplete = malformed = blocks = duplicate = 0
safe_stages = {'request_body', 'request_validation', 'upstream_headers', 'upstream_body', 'response_validation', 'response'}
for kind, observed_at, block, closed in module.console_blocks(entries):
    blocks += 1
    incomplete += not closed
    if kind != 'request' or not start <= observed_at < end:
        continue
    value = module.request_from_block(block, observed_at)
    if value is None:
        malformed += 1
        continue
    if value['status'] != 400:
        continue
    value['downstreamDisconnectedFieldObserved'] = module.field(block, 'downstreamDisconnected') is not None
    if not value['downstreamDisconnectedFieldObserved']:
        value['downstreamDisconnected'] = None
    stage = module.field(block, 'stage')
    value['stage'] = stage if stage in safe_stages else value.get('abortStage')
    value['relativeToDirectRelease'] = 'after' if observed_at >= active_from else 'before'
    if value['key'] in requests:
        duplicate += 1
    else:
        requests[value['key']] = value
raw = module.SOURCE.read_bytes()
service = module.systemd_show(module.UNIT)
rows = sorted(requests.values(), key=lambda v: v['observedAt'])
result = {
 'schema': 'castreader.direct-gateway-400-incident.v1', 'readOnly': True,
 'productionModified': False, 'synthesisStarted': False, 'rawUserDataExported': False,
 'window': {'startUTC': module.iso(start), 'endUTCExclusive': module.iso(end)},
 'collectedAtUTC': module.iso(datetime.now(timezone.utc)),
 'coverage': {'complete': not (parse_errors or truncated or incomplete or malformed),
              'journalRows': len(entries), 'logicalBlocks': blocks, 'journalParseErrors': parse_errors,
              'journalRowLimitReached': truncated, 'incompleteConsoleBlocks': incomplete,
              'malformedRequestBlocks': malformed, 'duplicate400Blocks': duplicate,
              'firstJournalAtUTC': module.iso(entries[0][0]) if entries else None,
              'lastJournalAtUTC': module.iso(entries[-1][0]) if entries else None},
 'release': {'sourceCommit': RELEASE['sourceCommit'], 'sourceSha256': RELEASE['sourceSha256'],
             'firstNewTrafficAtUTC': RELEASE['firstNewTrafficAt']},
 'currentIdentity': {'sourceSha256': hashlib.sha256(raw).hexdigest(), 'sourceBytes': len(raw),
                     'sourceMatchesRelease': hashlib.sha256(raw).hexdigest() == RELEASE['sourceSha256'],
                     'systemd': service},
 'status400Count': len(rows), 'beforeReleaseCount': sum(v['relativeToDirectRelease'] == 'before' for v in rows),
 'afterReleaseCount': sum(v['relativeToDirectRelease'] == 'after' for v in rows), 'requests': rows[:200],
 'requestsTruncated': len(rows) > 200,
 'limitations': ['Missing stage/abortSource means not logged, not absence of that stage.',
                 'Old logs omit downstreamDisconnected; the parser default false is replaced with null when the field was not observed.',
                 'Platform/version come from caller-supplied headers.',
                 'No client request/trace key is retained for the three client failures; time proximity cannot establish an exact join.',
                 'Journal timestamp is the request completion/log observation time.',
                 'Current source identity does not assign that version to earlier records.']
}
print(PREFIX + json.dumps(result, sort_keys=True))
"""
payload = "HELPER_SOURCE=" + repr(helper_raw.decode()) + "\nRELEASE=" + repr(release) + "\nPREFIX=" + repr(prefix) + "\n" + remote
try:
    completed = subprocess.run(["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                "root@140.82.14.49", "python3 -B -"],
                               input=payload, capture_output=True, text=True, timeout=60)
    values = [line[len(prefix):] for line in completed.stdout.splitlines() if line.startswith(prefix)]
    if completed.returncode != 0 or len(values) != 1:
        raise RuntimeError('no_sanitized_remote_result')
    result = json.loads(values[0])
    result['provenance'] = {'helperPath': str(helper_path), 'helperSha256': hashlib.sha256(helper_raw).hexdigest(),
                            'directStatusReceiptPath': str(receipt_path), 'directStatusReceiptSha256': hashlib.sha256(receipt_raw).hexdigest()}
    output = HERE / 'direct400.json'
    output.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    print(json.dumps(result, sort_keys=True, indent=2))
except Exception as error:
    print(json.dumps({'collectionFailed': True, 'errorClass': type(error).__name__}))
    raise SystemExit(1)
