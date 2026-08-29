#!/bin/bash
set -euo pipefail

base=/root/autodl-tmp/nari-staging
incoming="${base}/release-incoming-semantic-contract"
worker="${base}/worker"
source_commit="${1:?pass the 40-character source commit SHA}"

if [[ ! "${source_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid source commit SHA" >&2
  exit 64
fi

for name in clone_worker.py build_prompt.py; do
  test -s "${incoming}/${name}"
  "${base}/venv/bin/python" -m py_compile "${incoming}/${name}"
done

test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:18094/ready >/dev/null
health_before=$(curl -fsS --max-time 3 http://127.0.0.1:18890/health)
"${base}/venv/bin/python" - "${health_before}" <<'PY'
import json
import sys

health = json.loads(sys.argv[1])
if health.get("status") != "healthy":
    raise SystemExit("clone worker is not healthy")
PY

nari_pid=$(cat "${base}/run/nari.pid")
worker_pid=$(cat "${base}/run/worker.pid")
old_tts_pid=$(pgrep -f "uvicorn api.src.main:app.*--port 8880" | head -1)
for pid in "${nari_pid}" "${worker_pid}" "${old_tts_pid}"; do
  test -n "${pid}"
  kill -0 "${pid}"
done

idle_streak=0
for attempt in $(seq 1 60); do
  health=$(curl -fsS --max-time 3 http://127.0.0.1:18890/health)
  read -r queue busy < <("${base}/venv/bin/python" - "${health}" <<'PY'
import json
import sys

health = json.loads(sys.argv[1])
print(int(health.get("queue_depth", -1)), "yes" if health.get("busy") else "no")
PY
)
  utilization=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | tr -d ' ')
  if [[ "${queue}" == "0" && "${busy}" == "no" ]] \
    && [[ "${utilization}" =~ ^[0-9]+$ ]] && (( utilization <= 2 )); then
    idle_streak=$((idle_streak + 1))
  else
    idle_streak=0
  fi
  if (( idle_streak >= 3 )); then
    echo "idle_window_ready attempt=${attempt} utilization=${utilization}%"
    break
  fi
  sleep 2
done
if (( idle_streak < 3 )); then
  echo "No safe idle window; deployment not started." >&2
  exit 75
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="${base}/backups/semantic-contract-${stamp}"
release_record="${base}/releases/semantic-contract-${stamp}.json"
mkdir -p "${backup}" "${base}/releases"
for name in clone_worker.py build_prompt.py; do
  cp -a "${worker}/${name}" "${backup}/${name}"
done

restart_worker() {
  local active_pid
  active_pid=$(cat "${base}/run/worker.pid" 2>/dev/null || true)
  if [[ -n "${active_pid}" ]] && kill -0 "${active_pid}" 2>/dev/null; then
    kill -TERM "${active_pid}"
  fi
}

wait_for_new_worker() {
  local previous_pid="$1"
  local active_pid=""
  for _ in $(seq 1 90); do
    active_pid=$(cat "${base}/run/worker.pid" 2>/dev/null || true)
    if [[ -n "${active_pid}" && "${active_pid}" != "${previous_pid}" ]] \
      && kill -0 "${active_pid}" 2>/dev/null \
      && curl -fsS --max-time 2 http://127.0.0.1:18890/health \
        | grep -q '"status":"healthy"'; then
      echo "${active_pid}"
      return 0
    fi
    sleep 2
  done
  return 1
}

rollback() {
  echo "semantic contract deployment failed; restoring ${backup}" >&2
  for name in clone_worker.py build_prompt.py; do
    cp -a "${backup}/${name}" "${worker}/${name}"
  done
  local failed_pid
  failed_pid=$(cat "${base}/run/worker.pid" 2>/dev/null || true)
  restart_worker || true
  wait_for_new_worker "${failed_pid}" >/dev/null || true
}
trap rollback ERR

for name in clone_worker.py build_prompt.py; do
  cp "${incoming}/${name}" "${worker}/${name}.next"
  chown --reference="${worker}/${name}" "${worker}/${name}.next"
  chmod --reference="${worker}/${name}" "${worker}/${name}.next"
  mv "${worker}/${name}.next" "${worker}/${name}"
done

restart_worker
new_worker_pid=$(wait_for_new_worker "${worker_pid}")

test "$(cat "${base}/run/nari.pid")" = "${nari_pid}"
kill -0 "${nari_pid}"
test "$(pgrep -f "uvicorn api.src.main:app.*--port 8880" | head -1)" = "${old_tts_pid}"
kill -0 "${old_tts_pid}"

"${base}/venv/bin/python" - \
  "${source_commit}" \
  "$(sha256sum "${worker}/clone_worker.py" | cut -d' ' -f1)" \
  "$(sha256sum "${worker}/build_prompt.py" | cut -d' ' -f1)" \
  "${release_record}" <<'PY'
import json
import pathlib
import sys

commit, worker_hash, builder_hash, destination = sys.argv[1:]
pathlib.Path(destination).write_text(
    json.dumps(
        {
            "source_commit": commit,
            "clone_worker_sha256": worker_hash,
            "build_prompt_sha256": builder_hash,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

trap - ERR
echo "backup=${backup}"
echo "release_record=${release_record}"
echo "worker_pid=${new_worker_pid} nari_pid=${nari_pid} old_tts_pid=${old_tts_pid}"
curl -fsS http://127.0.0.1:18890/health
nvidia-smi --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
