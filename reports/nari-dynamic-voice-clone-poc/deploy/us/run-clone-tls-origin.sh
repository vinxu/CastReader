#!/bin/bash
set -euo pipefail

exec /opt/instance-tools/bin/caddy run \
  --config /workspace/castreader-clone/deploy/Caddyfile.clone-tls \
  --adapter caddyfile
