#!/bin/bash
set -euo pipefail

staging_root="${NARI_STAGING_ROOT:-/root/autodl-tmp/nari-staging}"
python_bin="${NARI_PYTHON:-${staging_root}/venv/bin/python}"
requests="${SOAK_REQUESTS:-2500}"
concurrency="${SOAK_CONCURRENCY:-4}"
voice_id="${SOAK_VOICE_ID:-vc_e2e_generated_test}"
result_path="${SOAK_RESULT_PATH:-${staging_root}/run/soak-result.json}"
monitor_path="${SOAK_MONITOR_PATH:-${staging_root}/run/soak-monitor.log}"

: > "${monitor_path}"
(
  while true; do
    timestamp=$(date +%s.%3N)
    old_health=$(curl -sS --max-time 2 -o /dev/null -w "%{http_code} %{time_total}" \
      http://127.0.0.1:8880/health || echo "000 2")
    gpu=$(nvidia-smi \
      --query-gpu=memory.free,utilization.gpu,temperature.gpu \
      --format=csv,noheader,nounits)
    echo "${timestamp} old=${old_health} gpu=${gpu}" >> "${monitor_path}"
    sleep 2
  done
) &
monitor_pid=$!
stop_monitor() {
  kill "${monitor_pid}" 2>/dev/null || true
  wait "${monitor_pid}" 2>/dev/null || true
}
trap stop_monitor EXIT TERM INT

"${python_bin}" "${staging_root}/loadtest/run_captioned_load.py" \
  --base-url http://127.0.0.1:18890 \
  --voice-id "${voice_id}" \
  --token-file "${staging_root}/clone/.api-token" \
  --requests "${requests}" \
  --concurrency "${concurrency}" \
  --timeout 100 > "${result_path}"

stop_monitor
trap - EXIT TERM INT
echo "soak_complete result=${result_path} monitor=${monitor_path}"
