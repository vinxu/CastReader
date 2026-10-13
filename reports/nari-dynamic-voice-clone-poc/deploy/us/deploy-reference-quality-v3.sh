#!/bin/bash
set -euo pipefail

base=/workspace/castreader-clone
incoming="${base}/release-incoming-reference-v3"
app="${base}/app"
backup="${base}/backups/reference-v3-$(date -u +%Y%m%dT%H%M%SZ)"

for path in "${incoming}/clone_worker.py" "${incoming}/audio_quality.py"; do
  test -f "${path}"
done

test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:8094/ready >/dev/null
curl -fsS --max-time 3 http://127.0.0.1:8890/health >/dev/null

# Only reload the clone adapter in a natural idle window. Never stop or signal
# the legacy TTS service or Nari.
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

mkdir -p "${backup}"
cp "${app}/clone_worker.py" "${backup}/clone_worker.py"
cp "${app}/audio_quality.py" "${backup}/audio_quality.py"

cp "${incoming}/clone_worker.py" "${app}/clone_worker.py.next"
cp "${incoming}/audio_quality.py" "${app}/audio_quality.py.next"
mv "${app}/clone_worker.py.next" "${app}/clone_worker.py"
mv "${app}/audio_quality.py.next" "${app}/audio_quality.py"

supervisorctl restart castreader-clone

ready=no
for attempt in $(seq 1 60); do
  old_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8880/health || true)
  nari_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8094/ready || true)
  worker_body=$(curl -sS --max-time 2 http://127.0.0.1:8890/health || true)
  if [[ "${old_code}" == 200 && "${nari_code}" == 200 ]] \
    && grep -q '"status":"healthy"' <<<"${worker_body}"; then
    ready=yes
    echo "quality_v3_worker_ready attempt=${attempt} old_8880=${old_code} nari=${nari_code}"
    break
  fi
  sleep 2
done

if [[ "${ready}" != yes ]]; then
  echo "Quality v3 failed readiness; restoring the immediately previous adapter."
  cp "${backup}/clone_worker.py" "${app}/clone_worker.py"
  cp "${backup}/audio_quality.py" "${app}/audio_quality.py"
  supervisorctl restart castreader-clone
  exit 1
fi

supervisorctl status castreader-clone castreader-tts
ps -p 937403 -o pid=,etimes=,cmd=
curl -fsS http://127.0.0.1:8890/health
nvidia-smi --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
