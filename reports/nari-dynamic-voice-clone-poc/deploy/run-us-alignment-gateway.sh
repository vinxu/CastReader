#!/usr/bin/env bash
set -euo pipefail
set +x

root=/workspace/castreader-alignment
release=$(readlink -f "$root/current")
test -d "$release/src"
cd "$release"
sha256sum --check --quiet SHA256SUMS
for attempt in $(seq 1 150); do
  if curl --fail --silent --max-time 3 http://127.0.0.1:8890/health \
      | /usr/bin/python3 -c 'import json,sys; state=json.load(sys.stdin); sys.exit(0 if state.get("status") == "healthy" and state.get("nari_ready") is True else 1)' 2>/dev/null; then
    break
  fi
  if test "$attempt" -eq 150; then exit 1; fi
  sleep 2
done
export CLONE_TOKEN_FILE=/workspace/castreader-clone/.api-token
export CLONE_VOICE_ROOT=/workspace/castreader-clone/voices
export CLONE_ORIGINAL_WORKER=http://127.0.0.1:8890
export CLONE_ALIGNER_MODEL=/workspace/castreader-alignment/model
export PYTHONPATH="$release/src"
export PYTHONDONTWRITEBYTECODE=1
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
exec /workspace/castreader-alignment/venv/bin/python -m uvicorn \
  alignment_gateway:create_app --factory --host 127.0.0.1 --port 18891 \
  --workers 1 --limit-concurrency 8 --no-access-log
