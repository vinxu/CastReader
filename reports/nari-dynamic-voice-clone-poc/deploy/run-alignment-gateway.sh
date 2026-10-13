#!/usr/bin/env bash
set -euo pipefail
set +x

root=/root/autodl-tmp/castreader-alignment
release=$(readlink -f "$root/current")
test -d "$release/src"
cd "$release"
sha256sum --check --quiet SHA256SUMS
curl --fail --silent --max-time 3 http://127.0.0.1:18890/health >/dev/null
export CLONE_TOKEN_FILE=/root/autodl-tmp/nari-staging/clone/.api-token
export CLONE_VOICE_ROOT=/root/autodl-tmp/nari-staging/clone/voices
export CLONE_ORIGINAL_WORKER=http://127.0.0.1:18890
export CLONE_ALIGNER_MODEL=/root/autodl-tmp/alignment-pipeline-20260908/model
export PYTHONPATH="$release/src"
export PYTHONDONTWRITEBYTECODE=1
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
exec /root/autodl-tmp/alignment-pipeline-20260908/venv/bin/python -m uvicorn \
  alignment_gateway:create_app --factory --host 127.0.0.1 --port 18891 \
  --workers 1 --limit-concurrency 8 --no-access-log
