#!/bin/bash
set -euo pipefail

base=/root/autodl-tmp/nari-staging
incoming="${base}/release-incoming-fast-hotpath"
worker_root="${base}/worker"
nari_root="${base}/nari-qwen3-tts/src/nari_qwen3_tts"
runner="${base}/deploy/run-clone-china-staging.sh"
source_commit="${1:?pass the 40-character source commit SHA}"
worker_files=(
  clone_worker.py
  audio_quality.py
  adaptive_denoise.py
  build_prompt.py
  semantic_asr.py
  xvector_activation.py
)
nari_files=(
  contract/request.py
  api/app.py
  api/schemas.py
  model/text.py
  model/input_layout.py
  executor/input_layout.py
  executor/talker.py
)
deepfilter_source="${incoming}/assets/denoise/bin/deep-filter"
deepfilter_destination="${base}/denoise/bin/deep-filter"
diarization_source="${incoming}/assets/quality/models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
diarization_destination="${base}/quality/models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
diarization_license_source="${incoming}/assets/quality/models/sherpa-onnx-pyannote-segmentation-3-0/LICENSE"
diarization_license_destination="${base}/quality/models/sherpa-onnx-pyannote-segmentation-3-0/LICENSE"
mode_file="${base}/clone/.adaptive-denoise-mode"

if [[ ! "${source_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid source commit SHA" >&2
  exit 64
fi
for name in "${worker_files[@]}"; do
  test -s "${incoming}/worker/${name}"
  "${base}/venv/bin/python" -m py_compile "${incoming}/worker/${name}"
done
test -s "${incoming}/run-clone-china-staging.sh"
bash -n "${incoming}/run-clone-china-staging.sh"
for name in "${nari_files[@]}"; do
  test -s "${incoming}/nari_qwen3_tts/${name}"
  "${base}/venv/bin/python" -m py_compile \
    "${incoming}/nari_qwen3_tts/${name}"
done
test "$(sha256sum "${deepfilter_source}" | cut -d' ' -f1)" = \
  70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da
test "$(sha256sum "${diarization_source}" | cut -d' ' -f1)" = \
  220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079
test -s "${diarization_license_source}"
PYTHONPATH="${base}/quality/deps" \
LD_LIBRARY_PATH="${base}/quality/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
  "${base}/venv/bin/python" -c 'import sherpa_onnx'

test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:18094/ready >/dev/null
curl -fsS --max-time 3 http://127.0.0.1:18890/health | grep -q '"status":"healthy"'
old_tts_pid=$(pgrep -f "uvicorn api.src.main:app.*--port 8880" | head -1)
old_nari_pid=$(cat "${base}/run/nari.pid")
old_worker_pid=$(cat "${base}/run/worker.pid")
for process_id in "${old_tts_pid}" "${old_nari_pid}" "${old_worker_pid}"; do
  test -n "${process_id}"
  kill -0 "${process_id}"
done

idle_streak=0
for attempt in $(seq 1 60); do
  health=$(curl -fsS --max-time 3 http://127.0.0.1:18890/health)
  read -r queue busy < <("${base}/venv/bin/python" - "${health}" <<'PY'
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
cp -a "${runner}" "${backup}/run-clone-china-staging.sh"
if [[ -e "${mode_file}" ]]; then
  cp -a "${mode_file}" "${backup}/adaptive-denoise-mode"
else
  : > "${backup}/adaptive-denoise-mode.absent"
fi
for name in "${worker_files[@]}"; do
  mkdir -p "${backup}/worker/$(dirname "${name}")"
  if [[ -e "${worker_root}/${name}" ]]; then
    cp -a "${worker_root}/${name}" "${backup}/worker/${name}"
  else
    : > "${backup}/worker/${name}.absent"
  fi
done
for name in "${nari_files[@]}"; do
  mkdir -p "${backup}/nari_qwen3_tts/$(dirname "${name}")"
  cp -a "${nari_root}/${name}" "${backup}/nari_qwen3_tts/${name}"
done

install_one() {
  local source_file="$1"
  local destination_file="$2"
  cp "${source_file}" "${destination_file}.next"
  if [[ -e "${destination_file}" ]]; then
    chown --reference="${destination_file}" "${destination_file}.next"
    chmod --reference="${destination_file}" "${destination_file}.next"
  else
    chown --reference="$(dirname "${destination_file}")" "${destination_file}.next"
    chmod 0644 "${destination_file}.next"
  fi
  mv "${destination_file}.next" "${destination_file}"
}

restore_files() {
  for name in "${worker_files[@]}"; do
    if [[ -e "${backup}/worker/${name}.absent" ]]; then
      rm -f "${worker_root}/${name}"
    else
      cp -a "${backup}/worker/${name}" "${worker_root}/${name}"
    fi
  done
  for name in "${nari_files[@]}"; do
    cp -a "${backup}/nari_qwen3_tts/${name}" "${nari_root}/${name}"
  done
  cp -a "${backup}/run-clone-china-staging.sh" "${runner}"
  if [[ -e "${backup}/adaptive-denoise-mode.absent" ]]; then
    rm -f "${mode_file}"
  else
    cp -a "${backup}/adaptive-denoise-mode" "${mode_file}"
  fi
}

wait_for_restarted_stack() {
  local previous_nari="$1"
  local previous_worker="$2"
  for _ in $(seq 1 120); do
    current_nari=$(cat "${base}/run/nari.pid" 2>/dev/null || true)
    current_worker=$(cat "${base}/run/worker.pid" 2>/dev/null || true)
    if [[ -n "${current_nari}" && -n "${current_worker}" \
      && "${current_nari}" != "${previous_nari}" \
      && "${current_worker}" != "${previous_worker}" ]] \
      && kill -0 "${current_nari}" 2>/dev/null \
      && kill -0 "${current_worker}" 2>/dev/null \
      && curl -fsS --max-time 2 http://127.0.0.1:18094/ready >/dev/null \
      && curl -fsS --max-time 2 http://127.0.0.1:18890/health | grep -q '"status":"healthy"'; then
      echo "${current_nari} ${current_worker}"
      return 0
    fi
    sleep 2
  done
  return 1
}

rollback() {
  echo "fast hotpath deployment failed; restoring ${backup}" >&2
  restore_files
  failed_nari=$(cat "${base}/run/nari.pid" 2>/dev/null || true)
  failed_worker=$(cat "${base}/run/worker.pid" 2>/dev/null || true)
  if [[ -n "${failed_nari}" ]]; then
    kill -TERM "${failed_nari}" 2>/dev/null || true
  fi
  wait_for_restarted_stack "${failed_nari}" "${failed_worker}" >/dev/null || true
}
trap rollback ERR

for name in "${worker_files[@]}"; do
  install_one "${incoming}/worker/${name}" "${worker_root}/${name}"
done
for name in "${nari_files[@]}"; do
  install_one "${incoming}/nari_qwen3_tts/${name}" "${nari_root}/${name}"
done
mkdir -p "$(dirname "${deepfilter_destination}")" \
  "$(dirname "${diarization_destination}")"
install -m 0755 "${deepfilter_source}" "${deepfilter_destination}.next"
mv "${deepfilter_destination}.next" "${deepfilter_destination}"
install -m 0644 "${diarization_source}" "${diarization_destination}.next"
mv "${diarization_destination}.next" "${diarization_destination}"
install -m 0644 "${diarization_license_source}" "${diarization_license_destination}.next"
mv "${diarization_license_destination}.next" "${diarization_license_destination}"
install_one "${incoming}/run-clone-china-staging.sh" "${runner}"
install -m 0600 /dev/null "${mode_file}.next"
printf 'shadow\n' > "${mode_file}.next"
mv "${mode_file}.next" "${mode_file}"

kill -TERM "${old_nari_pid}"
read -r new_nari_pid new_worker_pid < <(
  wait_for_restarted_stack "${old_nari_pid}" "${old_worker_pid}"
)
test "$(pgrep -f "uvicorn api.src.main:app.*--port 8880" | head -1)" = "${old_tts_pid}"
kill -0 "${old_tts_pid}"

"${base}/venv/bin/python" - \
  "${source_commit}" "${stamp}" "${release_record}" \
  "${worker_root}" "${nari_root}" "${runner}" <<'PY'
import hashlib
import json
import pathlib
import sys

commit, stamp, destination, worker_root, nari_root, runner = sys.argv[1:]
worker_files = (
    "clone_worker.py",
    "audio_quality.py",
    "adaptive_denoise.py",
    "build_prompt.py",
    "semantic_asr.py",
    "xvector_activation.py",
)
nari_files = (
    "contract/request.py",
    "api/app.py",
    "api/schemas.py",
    "model/text.py",
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
    "runner_sha256": digest(pathlib.Path(runner)),
    "hotpath": "nari-x-vector-only",
    "runtime_asr": "offline-audit-only",
    "writer_activation": "requires-bound-release-marker-v1",
    "adaptive_denoise": {
        "selector": "adaptive-deepfilter-24-100-v1",
        "deployment_mode": "shadow",
        "deepfilter_sha256": "70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da",
        "diarization_sha256": "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
        "speaker_sha256": "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11",
    },
}
pathlib.Path(destination).write_text(json.dumps(record, indent=2) + "\n")
PY

trap - ERR
echo "backup=${backup}"
echo "release_record=${release_record}"
echo "nari_pid=${new_nari_pid} worker_pid=${new_worker_pid} old_tts_pid=${old_tts_pid}"
curl -fsS http://127.0.0.1:18890/health
nvidia-smi --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
