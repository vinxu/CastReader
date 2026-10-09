#!/usr/bin/python3
"""Resume real 180-second sessions on the already-authorized acceptance simulator."""
import datetime
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPORTS = ROOT / 'reports/ios-28-languages-20261008'
STATE = REPORTS / 'acceptance-current.json'
SIMULATOR = 'EC127445-7281-4C64-9417-8642E44F4039'


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(state):
    state['updatedAt'] = now()
    state['verifiedLongSessionsInCurrentMatrix'] = sum(
        row['status'] == 'passed' for row in state['longSessions'])
    state['deliveryReady'] = False
    temporary = STATE.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(STATE)


def collect(folder):
    result_file = folder / 'results.json'
    if not result_file.exists():
        return []
    rows = json.loads(result_file.read_text())
    state = json.loads(STATE.read_text())
    for result in rows:
        for mode in ('read', 'explain'):
            match = next(row for row in state['longSessions'] if
                         (row['language'], row['format'], row['mode']) ==
                         (result['language'], result['format'], mode))
            metrics = result.get(mode, {})
            if metrics.get('effectivePlayingSeconds', 0) >= 180:
                match.pop('error', None)
                match.update(status='passed', actualPlayingSeconds=metrics['effectivePlayingSeconds'],
                             evidence=str(result_file.relative_to(REPORTS)),
                             pauseResume=metrics['pauseResume'], segmentsVisited=metrics['segmentsVisited'])
            elif match['status'] != 'passed':
                match.update(status='failed_needs_review',
                             evidence=str(result_file.relative_to(REPORTS)),
                             error=result.get('error', 'Required mode has no passing result'))
    save(state)
    return rows


if len(sys.argv) > 1 and sys.argv[1] in ('--help', '-h'):
    print('Usage: run-ios-language-long-matrix.py [collect RESULT_DIRECTORY]')
    print('Set CASTREADER_MATRIX_STOP_FILE to a path; create it to stop after the active case.')
    raise SystemExit(0)

if len(sys.argv) > 1 and sys.argv[1] == 'collect':
    collect(pathlib.Path(sys.argv[2]).resolve())
    raise SystemExit(0)

batch = REPORTS / ('long-matrix-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
batch.mkdir()
manifest = json.loads((REPORTS / 'long-fixtures/manifest.json').read_text())
for fixture in manifest:
    stop_file = os.environ.get('CASTREADER_MATRIX_STOP_FILE')
    if stop_file and pathlib.Path(stop_file).exists():
        print('STOP: requested after completed case; no active child remains.', flush=True)
        break
    state = json.loads(STATE.read_text())
    language, format_ = fixture['language'], fixture['format']
    allowed = os.environ.get('CASTREADER_MATRIX_LANGUAGES', '').split(',')
    if allowed != [''] and language not in allowed:
        continue
    modes = [row['mode'] for row in state['longSessions'] if
             row['language'] == language and row['format'] == format_ and row['status'] != 'passed']
    if not modes:
        continue
    folder = batch / (language + '-' + format_)
    env = dict(os.environ, CASTREADER_ACCEPTANCE_SIMULATOR=SIMULATOR,
               CASTREADER_ACCEPTANCE_REPORT=str(folder), CASTREADER_ACCEPTANCE_LANGUAGES=language,
               CASTREADER_ACCEPTANCE_FORMATS=format_, CASTREADER_ACCEPTANCE_MODES=','.join(modes))
    state['overallStatus'] = 'running_long_live_acceptance'
    state['activeLongAcceptance'] = dict(language=language, format=format_, modes=modes,
                                       report=str(folder.relative_to(REPORTS)), startedAt=now())
    save(state)
    print(now(), 'START', language, format_, ','.join(modes), flush=True)
    completed = subprocess.run(['bash', str(ROOT / 'scripts/verify-ios-language-reading.sh')],
                               cwd=ROOT, env=env)
    rows = collect(folder)
    print(now(), 'FINISH', language, format_, 'exit', completed.returncode,
          [(row.get('status'), row.get('error', '')) for row in rows], flush=True)
    if not rows:
        print('STOP: test infrastructure produced no result; inspect before spending more quota.', flush=True)
        break
    errors = ' '.join(row.get('error', '') for row in rows)
    if any(code in errors for code in ('API_TTS_DAILY_LIMIT', 'daily limit', 'daily character', '每日额度')):
        print('STOP: shared service budget unavailable; no automatic retries.', flush=True)
        break
state = json.loads(STATE.read_text())
state['overallStatus'] = 'long_live_acceptance_needs_review'
state['activeLongAcceptance'] = None
save(state)
print(now(), 'BATCH COMPLETE', state['verifiedLongSessionsInCurrentMatrix'], '/114 passed', flush=True)
