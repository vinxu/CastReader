#!/usr/bin/env bash
set -euo pipefail

DEVICE_ID="${1:-00008130-001C64800C60001C}"
OUT="${2:-/tmp/kindle-background-probe.log}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier com.same.castreader \
  --source Documents/kindle-background-probe.log \
  --destination "$OUT"

"$ROOT/scripts/analyze_kindle_probe_log.py" "$OUT"
