#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

root=/workspace/castreader-alignment
release="$root/releases/20260909-qwen-pcm-v3-r2"
before="$root/backups/us-v3-pre-20260909"
config=/workspace/castreader-clone/deploy/Caddyfile.clone-tls
revision=qwen-pcm-measured-groups-v3

exec 9>"$root/run/deploy.lock"
flock -w 30 9
test ! -e "$root/current"
test ! -e /etc/supervisor/conf.d/castreader-clone-alignment.conf
cd "$release"
sha256sum --check --quiet SHA256SUMS
sha256sum --check --quiet "$before/worker-source.sha256"
cmp "$config" "$before/Caddyfile.clone-tls"
/workspace/castreader-alignment/venv/bin/python - "$root" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
for name in ("pre", "candidate"):
    receipt = json.loads((root / f"us-v3-{name}.receipt.json").read_text())
    if not (receipt["verified"] is True and receipt["public"] is False
            and receipt["sha256"] == receipt["readback_sha256"]):
        raise SystemExit("Unverified private deployment backup")
PY
/opt/instance-tools/bin/caddy validate --config "$release/Caddyfile.clone-tls-v3" --adapter caddyfile

cutover_started=false
rollback() {
  status=$?
  if test "$status" -ne 0; then
    if test "$cutover_started" = true; then
      cp "$before/Caddyfile.clone-tls" "$config.rollback"
      mv "$config.rollback" "$config"
      supervisorctl restart castreader-clone-tls || true
    fi
    supervisorctl stop castreader-clone-alignment || true
    printf '%s\n' "Deployment failed; original clone routing retained/restored" >&2
  fi
  exit "$status"
}
trap rollback EXIT

ln -s "$release" "$root/current.pending"
mv -T "$root/current.pending" "$root/current"
install -m 0600 "$release/alignment-supervisor.conf" /etc/supervisor/conf.d/castreader-clone-alignment.conf
supervisorctl reread
supervisorctl update castreader-clone-alignment
for attempt in $(seq 1 90); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:18891/health \
      | grep -q "\"pipeline_revision\":\"$revision\""; then
    break
  fi
  if test "$attempt" -eq 90; then exit 1; fi
  sleep 2
done
/workspace/castreader-alignment/venv/bin/python - <<'PY'
import subprocess

free_mib = int(subprocess.check_output([
    "nvidia-smi", "--query-gpu=memory.free", "--format=csv,noheader,nounits"
], text=True).strip())
if free_mib < 4096:
    raise SystemExit("Insufficient operational GPU headroom")
PY
for attempt in $(seq 1 60); do
  if curl --fail --silent --max-time 2 http://127.0.0.1:8890/health \
      | /workspace/castreader-alignment/venv/bin/python -c 'import json,sys; state=json.load(sys.stdin); sys.exit(0 if not state.get("busy", True) and state.get("queue_depth", 1) == 0 and state.get("active_voice_tasks", 1) == 0 else 1)'; then
    break
  fi
  if test "$attempt" -eq 60; then exit 1; fi
  sleep 1
done
sha256sum --check --quiet "$before/worker-source.sha256"
cutover_started=true
install -m 0644 "$release/Caddyfile.clone-tls-v3" "$config.pending"
mv "$config.pending" "$config"
supervisorctl restart castreader-clone-tls
curl --fail --silent --show-error --max-time 5 \
  --cacert /workspace/castreader-clone/tls/origin-cert.pem \
  --resolve 71.175.237.103:8888:127.0.0.1 \
  https://71.175.237.103:8888/health > "$root/run/clone-health-after.json"
curl --silent --show-error --head --max-time 5 \
  --cacert /workspace/castreader-clone/tls/origin-cert.pem \
  --resolve 71.175.237.103:8888:127.0.0.1 \
  https://71.175.237.103:8888/v1/captioned-speech > "$root/run/caption-route-after.headers"
grep -iq "x-voice-alignment-revision: $revision" "$root/run/caption-route-after.headers"
curl --fail --silent --max-time 2 http://127.0.0.1:18891/health > "$root/run/alignment-health-after.json"
date -u '+%Y-%m-%dT%H:%M:%SZ' | tee "$root/run/cutover-at.txt"
supervisorctl status castreader-clone-alignment castreader-clone castreader-nari-base castreader-tts-r133-green castreader-clone-tls
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
trap - EXIT
