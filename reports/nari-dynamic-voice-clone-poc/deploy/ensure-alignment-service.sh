#!/usr/bin/env bash
set -euo pipefail
set +x

root=/root/autodl-tmp/castreader-alignment
install -d -m 0700 "$root/run"
exec 9>"$root/run/ensure.lock"
flock -w 90 9
config="$root/current/alignment-supervisor.conf"
control=/root/miniconda3/bin/supervisorctl
if ! "$control" -c "$config" pid >/dev/null 2>&1; then
  /root/miniconda3/bin/supervisord -c "$config" 9>&-
fi
if "$control" -c "$config" status castreader-clone-alignment 2>/dev/null | grep -Eq ' (STOPPED|FATAL|EXITED) '; then
  "$control" -c "$config" start castreader-clone-alignment >/dev/null
fi
flock -u 9
exec 9>&-
for attempt in $(seq 1 60); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:18891/health \
      | grep -q '"pipeline_revision":"qwen-pcm-measured-groups-v3"'; then
    exit 0
  fi
  sleep 2
done
exit 1
