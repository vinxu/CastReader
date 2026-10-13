#!/bin/bash
set -euo pipefail

base=/workspace/castreader-clone
incoming="${base}/release-incoming-20260826"
quality_incoming="${base}/quality-incoming-20260826"
quality_live="${base}/quality"
app="${base}/app"
runner="${base}/run-clone-worker.sh"
backup_suffix=.pre-reference-quality-20260826

for path in \
  "${incoming}/clone_worker.py" \
  "${incoming}/audio_quality.py" \
  "${incoming}/run-clone-worker.sh" \
  "${quality_incoming}/models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx" \
  "${quality_incoming}/lib/libonnxruntime.so.1.27.1"; do
  test -e "${path}"
done

test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:8094/ready >/dev/null
curl -fsS --max-time 3 http://127.0.0.1:8890/health >/dev/null

# Wait for a natural idle gap so reloading the clone prompt encoder does not
# contend with active legacy TTS work. This never stops or signals port 8880.
idle_streak=0
for attempt in $(seq 1 60); do
  utilization=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | tr -d ' ')
  if [[ "${utilization}" =~ ^[0-9]+$ ]] && (( utilization <= 2 )); then
    ((idle_streak += 1))
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
  echo "No safe idle window; deployment not started."
  exit 75
fi

cp -n "${app}/clone_worker.py" "${app}/clone_worker.py${backup_suffix}"
cp -n "${runner}" "${runner}${backup_suffix}"

if [[ ! -e "${quality_live}" ]]; then
  mv "${quality_incoming}" "${quality_live}"
fi
ln -sfn libonnxruntime.so.1.27.1 "${quality_live}/lib/libonnxruntime.so"

cp "${incoming}/clone_worker.py" "${app}/clone_worker.py.next"
cp "${incoming}/audio_quality.py" "${app}/audio_quality.py.next"
cp "${incoming}/run-clone-worker.sh" "${runner}.next"
chmod 755 "${runner}.next"
mv "${app}/clone_worker.py.next" "${app}/clone_worker.py"
mv "${app}/audio_quality.py.next" "${app}/audio_quality.py"
mv "${runner}.next" "${runner}"

supervisorctl restart castreader-clone

ready=no
for attempt in $(seq 1 60); do
  old_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8880/health || true)
  nari_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8094/ready || true)
  worker_body=$(curl -sS --max-time 2 http://127.0.0.1:8890/health || true)
  if [[ "${old_code}" == 200 && "${nari_code}" == 200 ]] \
    && grep -q '"status":"healthy"' <<<"${worker_body}"; then
    ready=yes
    echo "quality_worker_ready attempt=${attempt} old_8880=${old_code} nari=${nari_code}"
    break
  fi
  sleep 2
done

if [[ "${ready}" != yes ]]; then
  echo "Quality worker failed readiness; restoring the previous adapter."
  cp "${app}/clone_worker.py${backup_suffix}" "${app}/clone_worker.py"
  cp "${runner}${backup_suffix}" "${runner}"
  chmod 755 "${runner}"
  supervisorctl restart castreader-clone
  exit 1
fi

supervisorctl status castreader-clone castreader-nari-base castreader-tts
nvidia-smi --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
