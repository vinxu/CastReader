#!/bin/bash
set -euo pipefail

staging_root="${NARI_STAGING_ROOT:-/root/autodl-tmp/nari-staging}"
incoming="${1:?pass the staged audio_quality.py path}"
worker_file="${staging_root}/worker/audio_quality.py"

health=$(curl -fsS http://127.0.0.1:18890/health)
"${staging_root}/venv/bin/python3" - "${health}" <<'PY'
import json
import sys

health = json.loads(sys.argv[1])
if health.get("busy") or int(health.get("queue_depth", 0)) != 0:
    raise SystemExit("clone worker is not idle")
PY

stamp=$(date -u +%Y%m%d%H%M%S)
backup="${staging_root}/backups/audio-quality-${stamp}"
mkdir -p "${backup}"
cp "${worker_file}" "${backup}/audio_quality.py"
cp "${incoming}" "${worker_file}.next"
"${staging_root}/venv/bin/python3" -m py_compile "${worker_file}.next"
mv "${worker_file}.next" "${worker_file}"

old_pid=$(pgrep -f "python -m uvicorn clone_worker:app.*--port 18890" | head -1)
test -n "${old_pid}"
kill -TERM "${old_pid}"

for _ in $(seq 1 60); do
    new_pid=$(pgrep -f "python -m uvicorn clone_worker:app.*--port 18890" | head -1 || true)
    if [[ -n "${new_pid}" && "${new_pid}" != "${old_pid}" ]] \
        && curl -fsS --max-time 2 http://127.0.0.1:18890/health \
            | grep -q '"status":"healthy"'; then
        echo "clone_worker_restarted old=${old_pid} new=${new_pid} backup=$(basename "${backup}")"
        curl -fsS http://127.0.0.1:18890/health
        exit 0
    fi
    sleep 1
done

echo "clone worker failed to return; watchdog remains responsible for recovery" >&2
exit 1
