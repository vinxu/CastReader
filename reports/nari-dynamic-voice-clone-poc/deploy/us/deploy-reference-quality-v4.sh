#!/bin/bash
set -euo pipefail

base=/workspace/castreader-clone
incoming="${base}/release-incoming-reference-v4"
app="${base}/app"
backup="${base}/backups/reference-v4-$(date -u +%Y%m%dT%H%M%SZ)"

test -f "${incoming}/audio_quality.py"
"/workspace/nari-qwen3-tts-clean/venv/bin/python" -m py_compile \
  "${incoming}/audio_quality.py"

test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:8094/ready >/dev/null
worker_health=$(curl -fsS --max-time 3 http://127.0.0.1:8890/health)
grep -q '"status":"healthy"' <<<"${worker_health}"
grep -q '"busy":false' <<<"${worker_health}"
grep -q '"queue_depth":0' <<<"${worker_health}"
test "$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1:8888/health)" = 200

old_tts_pid=$(supervisorctl pid castreader-tts)
nari_pid=$(supervisorctl pid castreader-nari-base)
tls_pid=$(supervisorctl pid castreader-clone-tls)

# Observe a natural six-second idle window. This deploy never synthesizes a
# canary on the US production GPU and never signals the legacy TTS or Nari.
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
cp "${app}/audio_quality.py" "${backup}/audio_quality.py"
cp "${incoming}/audio_quality.py" "${app}/audio_quality.py.next"
mv "${app}/audio_quality.py.next" "${app}/audio_quality.py"

supervisorctl restart castreader-clone

ready=no
for attempt in $(seq 1 60); do
  old_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8880/health || true)
  nari_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8094/ready || true)
  tls_code=$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 2 https://127.0.0.1:8888/health || true)
  worker_body=$(curl -sS --max-time 2 http://127.0.0.1:8890/health || true)
  if [[ "${old_code}" == 200 && "${nari_code}" == 200 && "${tls_code}" == 200 ]] \
    && grep -q '"status":"healthy"' <<<"${worker_body}"; then
    ready=yes
    echo "reference_v4_worker_ready attempt=${attempt} old_8880=${old_code} nari=${nari_code} tls=${tls_code}"
    break
  fi
  sleep 2
done

if [[ "${ready}" != yes ]]; then
  echo "Reference v4 failed readiness; restoring the previous quality gate."
  cp "${backup}/audio_quality.py" "${app}/audio_quality.py"
  supervisorctl restart castreader-clone
  exit 1
fi

test "$(supervisorctl pid castreader-tts)" = "${old_tts_pid}"
test "$(supervisorctl pid castreader-nari-base)" = "${nari_pid}"
test "$(supervisorctl pid castreader-clone-tls)" = "${tls_pid}"

echo "backup=${backup}"
supervisorctl status castreader-clone castreader-tts castreader-nari-base castreader-clone-tls
curl -fsS http://127.0.0.1:8890/health
nvidia-smi --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
