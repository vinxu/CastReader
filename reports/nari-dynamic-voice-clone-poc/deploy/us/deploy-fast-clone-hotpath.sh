#!/bin/bash
set -euo pipefail

base=/workspace/castreader-clone
nari_base=/workspace/nari-qwen3-tts-clean
incoming="${base}/release-incoming-fast-hotpath"
worker_root="${base}/app"
nari_root="${nari_base}/src/nari_qwen3_tts"
source_commit="${1:?pass the 40-character source commit SHA}"
worker_files=(clone_worker.py build_prompt.py semantic_asr.py)
nari_files=(
  contract/request.py
  api/schemas.py
  model/input_layout.py
  executor/input_layout.py
  executor/talker.py
)

if [[ ! "${source_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid source commit SHA" >&2
  exit 64
fi

for name in "${worker_files[@]}"; do
  test -s "${incoming}/worker/${name}"
  "${nari_base}/venv/bin/python" -m py_compile "${incoming}/worker/${name}"
done
for name in "${nari_files[@]}"; do
  test -s "${incoming}/nari_qwen3_tts/${name}"
  "${nari_base}/venv/bin/python" -m py_compile \
    "${incoming}/nari_qwen3_tts/${name}"
done

test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:8094/ready >/dev/null
curl -fsS --max-time 3 http://127.0.0.1:8890/health | grep -q '"status":"healthy"'
old_tts_pid=$(supervisorctl pid castreader-tts)
test -n "${old_tts_pid}"

idle_streak=0
for attempt in $(seq 1 60); do
  health=$(curl -fsS --max-time 3 http://127.0.0.1:8890/health)
  read -r queue busy < <("${nari_base}/venv/bin/python" - "${health}" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
print(int(value.get("queue_depth", -1)), "yes" if value.get("busy") else "no")
PY
)
  utilization=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | tr -d ' ')
  if [[ "${queue}" == 0 && "${busy}" == no && "${utilization}" =~ ^[0-9]+$ ]] \
    && (( utilization <= 2 )); then
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
backup="${base}/backups/fast-hotpath-${stamp}"
release_record="${base}/releases/fast-hotpath-${stamp}.json"
mkdir -p "${backup}/worker" "${backup}/nari_qwen3_tts" "${base}/releases"
for name in "${worker_files[@]}"; do
  mkdir -p "${backup}/worker/$(dirname "${name}")"
  cp -a "${worker_root}/${name}" "${backup}/worker/${name}"
done
for name in "${nari_files[@]}"; do
  mkdir -p "${backup}/nari_qwen3_tts/$(dirname "${name}")"
  cp -a "${nari_root}/${name}" "${backup}/nari_qwen3_tts/${name}"
done

install_one() {
  local source_file="$1"
  local destination_file="$2"
  cp "${source_file}" "${destination_file}.next"
  chown --reference="${destination_file}" "${destination_file}.next"
  chmod --reference="${destination_file}" "${destination_file}.next"
  mv "${destination_file}.next" "${destination_file}"
}

restore_files() {
  for name in "${worker_files[@]}"; do
    cp -a "${backup}/worker/${name}" "${worker_root}/${name}"
  done
  for name in "${nari_files[@]}"; do
    cp -a "${backup}/nari_qwen3_tts/${name}" "${nari_root}/${name}"
  done
}

rollback() {
  echo "fast hotpath deployment failed; restoring ${backup}" >&2
  restore_files
  supervisorctl restart castreader-nari-base >/dev/null || true
  supervisorctl restart castreader-clone >/dev/null || true
}
trap rollback ERR

for name in "${worker_files[@]}"; do
  install_one "${incoming}/worker/${name}" "${worker_root}/${name}"
done
for name in "${nari_files[@]}"; do
  install_one "${incoming}/nari_qwen3_tts/${name}" "${nari_root}/${name}"
done

supervisorctl stop castreader-clone >/dev/null
supervisorctl restart castreader-nari-base >/dev/null
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 http://127.0.0.1:8094/ready >/dev/null; then
    break
  fi
  sleep 2
done
curl -fsS --max-time 3 http://127.0.0.1:8094/ready >/dev/null
supervisorctl start castreader-clone >/dev/null
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 http://127.0.0.1:8890/health | grep -q '"status":"healthy"'; then
    break
  fi
  sleep 2
done
curl -fsS --max-time 3 http://127.0.0.1:8890/health | grep -q '"status":"healthy"'
test "$(supervisorctl pid castreader-tts)" = "${old_tts_pid}"
test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200

"${nari_base}/venv/bin/python" - \
  "${source_commit}" "${stamp}" "${release_record}" \
  "${worker_root}" "${nari_root}" <<'PY'
import hashlib
import json
import pathlib
import sys

commit, stamp, destination, worker_root, nari_root = sys.argv[1:]
worker_files = ("clone_worker.py", "build_prompt.py", "semantic_asr.py")
nari_files = (
    "contract/request.py",
    "api/schemas.py",
    "model/input_layout.py",
    "executor/input_layout.py",
    "executor/talker.py",
)

def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

record = {
    "source_commit": commit,
    "deployed_at": stamp,
    "worker_sha256": {
        name: digest(pathlib.Path(worker_root) / name) for name in worker_files
    },
    "nari_sha256": {
        name: digest(pathlib.Path(nari_root) / name) for name in nari_files
    },
    "hotpath": "nari-x-vector-or-attested-icl",
    "runtime_asr": "creation-only",
}
pathlib.Path(destination).write_text(json.dumps(record, indent=2) + "\n")
PY

trap - ERR
echo "backup=${backup}"
echo "release_record=${release_record}"
supervisorctl status castreader-clone castreader-nari-base castreader-tts
curl -fsS http://127.0.0.1:8890/health
nvidia-smi --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
