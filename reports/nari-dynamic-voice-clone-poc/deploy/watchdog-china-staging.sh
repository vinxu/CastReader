#!/bin/bash
set -uo pipefail

staging_root="${NARI_STAGING_ROOT:-/root/autodl-tmp/nari-staging}"
log_root="${NARI_LOG_ROOT:-${staging_root}/logs}"
nari_runner="${staging_root}/deploy/run-nari-china-staging.sh"
worker_runner="${staging_root}/deploy/run-clone-china-staging.sh"
nari_port="${NARI_PORT:-18094}"
worker_port="${CLONE_PORT:-18890}"
restart_delay="${NARI_RESTART_DELAY:-2}"
runtime_check_interval="${NARI_RUNTIME_CHECK_INTERVAL:-2}"
worker_startup_grace_seconds="${CLONE_WORKER_STARTUP_GRACE_SECONDS:-20}"
minimum_free_before_mib="${NARI_MIN_FREE_BEFORE_MIB:-14000}"
minimum_free_after_mib="${NARI_MIN_FREE_AFTER_MIB:-2500}"

mkdir -p "${log_root}" "${staging_root}/run"
nari_pid=""
worker_pid=""
worker_started_epoch=0

stop_children() {
  for child in "${worker_pid}" "${nari_pid}"; do
    if [[ -n "${child}" ]] && kill -0 "${child}" 2>/dev/null; then
      kill -TERM "${child}" 2>/dev/null || true
    fi
  done
  for child in "${worker_pid}" "${nari_pid}"; do
    if [[ -n "${child}" ]]; then
      wait "${child}" 2>/dev/null || true
    fi
  done
}
trap 'stop_children; exit 0' TERM INT

start_worker() {
  echo "$(date -u +%FT%TZ) starting clone adapter"
  /bin/bash "${worker_runner}" >> "${log_root}/worker.log" 2>&1 &
  worker_pid=$!
  worker_started_epoch=$(date +%s)
  echo "${worker_pid}" > "${staging_root}/run/worker.pid"
}

while true; do
  gpu_free_before=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')
  if ! curl -fsS --max-time 2 http://127.0.0.1:8880/health >/dev/null \
    || [[ ! "${gpu_free_before}" =~ ^[0-9]+$ ]] \
    || (( gpu_free_before < minimum_free_before_mib )); then
    echo "$(date -u +%FT%TZ) staging preflight blocked old_tts_or_gpu_free=${gpu_free_before:-unknown}MiB"
    sleep 30
    continue
  fi
  echo "$(date -u +%FT%TZ) starting isolated Nari staging"
  /bin/bash "${nari_runner}" >> "${log_root}/nari.log" 2>&1 &
  nari_pid=$!
  echo "${nari_pid}" > "${staging_root}/run/nari.pid"

  ready=""
  for _ in $(seq 1 360); do
    if ! kill -0 "${nari_pid}" 2>/dev/null; then
      break
    fi
    if curl -fsS --max-time 2 "http://127.0.0.1:${nari_port}/ready" >/dev/null; then
      ready="yes"
      break
    fi
    sleep 5
  done

  if [[ "${ready}" == "yes" ]]; then
    gpu_free_after=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')
    if [[ "${gpu_free_after}" =~ ^[0-9]+$ ]] \
      && (( gpu_free_after >= minimum_free_after_mib )) \
      && curl -fsS --max-time 2 http://127.0.0.1:8880/health >/dev/null; then
      echo "$(date -u +%FT%TZ) Nari ready gpu_free=${gpu_free_after}MiB"
      start_worker
      nari_health_failures=0
      worker_health_failures=0
      while kill -0 "${nari_pid}" 2>/dev/null; do
        sleep "${runtime_check_interval}"
        gpu_free_runtime=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')
        if ! curl -fsS --max-time 2 http://127.0.0.1:8880/health >/dev/null \
          || [[ ! "${gpu_free_runtime}" =~ ^[0-9]+$ ]] \
          || (( gpu_free_runtime < minimum_free_after_mib )); then
          echo "$(date -u +%FT%TZ) runtime safety gate failed gpu_free=${gpu_free_runtime:-unknown}MiB"
          break
        fi
        if curl -fsS --max-time 2 "http://127.0.0.1:${nari_port}/ready" >/dev/null; then
          nari_health_failures=0
        else
          ((nari_health_failures += 1))
          if (( nari_health_failures >= 2 )); then
            echo "$(date -u +%FT%TZ) Nari readiness failed two consecutive checks"
            break
          fi
        fi

        if [[ -n "${worker_pid}" ]] && kill -0 "${worker_pid}" 2>/dev/null; then
          if curl -fsS --max-time 2 "http://127.0.0.1:${worker_port}/health" \
            | grep -q '"status":"healthy"'; then
            worker_health_failures=0
          elif (( $(date +%s) - worker_started_epoch < worker_startup_grace_seconds )); then
            # Importing and warming the reusable prompt encoder makes the
            # adapter's first start slower than a plain Uvicorn restart. Do not
            # turn a healthy bounded warmup into a restart loop.
            worker_health_failures=0
          else
            ((worker_health_failures += 1))
            if (( worker_health_failures >= 3 )); then
              echo "$(date -u +%FT%TZ) clone adapter health failed three consecutive checks"
              kill -TERM "${worker_pid}" 2>/dev/null || true
              wait "${worker_pid}" 2>/dev/null || true
              worker_pid=""
            fi
          fi
        else
          if [[ -n "${worker_pid}" ]]; then
            wait "${worker_pid}" 2>/dev/null || true
            echo "$(date -u +%FT%TZ) clone adapter exited"
          fi
          worker_pid=""
        fi

        if [[ -z "${worker_pid}" ]] && (( nari_health_failures == 0 )); then
          sleep 1
          worker_health_failures=0
          start_worker
        fi
      done
    else
      echo "$(date -u +%FT%TZ) post-start safety gate failed gpu_free=${gpu_free_after:-unknown}MiB"
    fi
  else
    echo "$(date -u +%FT%TZ) Nari failed readiness"
  fi

  stop_children
  nari_pid=""
  worker_pid=""
  echo "$(date -u +%FT%TZ) isolated staging stopped; restarting in ${restart_delay}s"
  sleep "${restart_delay}"
done
