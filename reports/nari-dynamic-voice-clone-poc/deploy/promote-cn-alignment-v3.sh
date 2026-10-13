#!/usr/bin/env bash
set -Eeuo pipefail
set +x

root=/root/autodl-tmp/castreader-alignment
previous="$root/releases/20260908-qwen-pcm-v2-r1"
candidate="$root/releases/20260908-qwen-pcm-v3-r1"
control=/root/miniconda3/bin/supervisorctl
config="$root/current/alignment-supervisor.conf"
exec 8>"$root/run/promotion.lock"
flock -w 30 8
test "$(readlink -f "$root/current")" = "$previous"
(cd "$previous"; sha256sum --check --quiet SHA256SUMS)
(cd "$candidate"; sha256sum --check --quiet SHA256SUMS)
/root/autodl-tmp/alignment-pipeline-20260908/venv/bin/python - "$root/run/v3-backup-gates" <<'PY'
import json, sys, time, urllib.request
from pathlib import Path
receipts = list(Path(sys.argv[1]).glob('*.receipt.json'))
assert len(receipts) == 2
for path in receipts:
    receipt = json.loads(path.read_text())
    assert receipt['verified'] and not receipt['public']
    assert receipt['sha256'] == receipt['readback_sha256']
for attempt in range(5):
    with urllib.request.urlopen('http://127.0.0.1:18890/health', timeout=3) as response:
        health = json.load(response)
    assert health['status'] == 'healthy' and health['accepting']
    assert not health['busy'] and not health['queue_depth'] and not health['active_voice_tasks']
    time.sleep(.5)
PY
rollback() {
  trap - ERR
  "$control" -c "$config" stop castreader-clone-alignment || true
  ln -s "$previous" "$root/current.rollback"
  mv -Tf "$root/current.rollback" "$root/current"
  "$control" -c "$config" start castreader-clone-alignment
  "$previous/ensure-alignment-service.sh"
  printf 'Rolled back to %s\n' "$previous" >&2
  exit 1
}
trap rollback ERR
printf 'Cutover started %s\n' "$(date --iso-8601=seconds)"
"$control" -c "$config" stop castreader-clone-alignment
ln -s "$candidate" "$root/current.next"
mv -Tf "$root/current.next" "$root/current"
"$control" -c "$config" start castreader-clone-alignment
"$candidate/ensure-alignment-service.sh"
curl --fail --silent --max-time 3 http://127.0.0.1:18891/health
curl --fail --silent --max-time 3 http://127.0.0.1:18890/health > "$root/run/v3-original-health.json"
trap - ERR
printf '\nCutover completed %s\n' "$(date --iso-8601=seconds)"
ps -p 639323,639681,338758 -o pid,lstart,comm
