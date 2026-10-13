#!/usr/bin/env bash
set -euo pipefail
socket=/run/castreader-clone-tunnel/control.sock
for attempt in $(seq 1 30); do
  if [[ -S "$socket" ]]; then
    exec /usr/bin/ssh -S "$socket" -i /etc/castreader/cn-clone-tunnel \
      -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile=/etc/castreader/cn4090-known-hosts \
      -p 12085 root@connect.bjb1.seetacloud.com \
      /bin/bash /root/autodl-tmp/castreader-alignment/current/ensure-alignment-service.sh
  fi
  sleep 1
done
exit 1
