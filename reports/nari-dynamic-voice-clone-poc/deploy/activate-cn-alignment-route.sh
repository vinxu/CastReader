#!/usr/bin/env bash
set -euo pipefail
set +x

test "${CASTREADER_ALIGNMENT_RELEASE_APPROVED:-0}" = 1
test "$(id -u)" = 0
staged=/tmp/castreader-cn-clone-private-route.conf
target=/etc/nginx/conf.d/castreader-cn-clone-private-route.conf
test -f "$staged"
test ! -e "$target"
test "$(readlink -f /opt/castreader/current)" = /opt/castreader/release-20260906014729
systemctl is-active --quiet castreader-cn-clone-raw-tunnel.service
curl --fail --silent --max-time 3 http://127.0.0.1:18892/health | grep -q '"status":"healthy"'
curl --fail --silent --max-time 3 http://127.0.0.1:18891/health | grep -q '"pipeline_revision":"qwen-pcm-measured-groups-v3"'
python3 - /tmp/castreader-cn-alignment-pre-20260908T1201Z.receipt.json /tmp/castreader-cn-clone-alignment-runtime-20260908.receipt.json /tmp/castreader-cn-alignment-r1-delta.receipt.json <<'PY'
import json
import sys
for filename in sys.argv[1:]:
    receipt = json.load(open(filename))
    assert receipt['verified'] is True
    assert receipt['sha256'] == receipt['readback_sha256']
    assert receipt['region'] == 'ap-shanghai'
PY
python3 - <<'PY'
import json
import time
import urllib.request
for attempt in range(30):
    with urllib.request.urlopen('http://127.0.0.1:18892/health', timeout=3) as response:
        health = json.load(response)
    if not health['busy'] and not health['queue_depth']:
        break
    time.sleep(1)
else:
    raise SystemExit('Clone worker did not become idle; no cutover performed')
PY
rollback() {
  rm -f "$target"
  nginx -t && systemctl reload nginx
  systemctl enable --now castreader-cn-clone-tunnel.service
}
trap rollback ERR
rm -f /etc/nginx/conf.d/castreader-cn-clone-private-stage.conf
install -m 0644 "$staged" "$target"
nginx -t
systemctl stop castreader-cn-clone-tunnel.service
systemctl reload nginx
for attempt in $(seq 1 20); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:18890/health | grep -q '"status":"healthy"'; then
    break
  fi
  sleep 1
done
curl --fail --silent --max-time 3 http://127.0.0.1:18890/health | grep -q '"status":"healthy"'
systemctl disable castreader-cn-clone-tunnel.service
trap - ERR
printf 'China private caption route activated at %s\n' "$(date -u +%FT%TZ)"
