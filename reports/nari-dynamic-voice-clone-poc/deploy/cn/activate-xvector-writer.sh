#!/bin/bash
set -euo pipefail

base=/root/autodl-tmp/nari-staging
incoming="${base}/release-incoming-fast-hotpath"
worker="${base}/worker/clone_worker.py"
builder="${base}/worker/build_prompt.py"
activation_validator="${base}/worker/xvector_activation.py"
reader="${base}/nari-qwen3-tts/src/nari_qwen3_tts/model/text.py"
marker="${base}/clone/.xvector-writer-v1-enabled"
source_commit="${1:?pass the 40-character source commit SHA}"
release_record="${2:?pass the fast-hotpath release record path}"

if [[ ! "${source_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid source commit SHA" >&2
  exit 64
fi

test -s "${incoming}/worker/clone_worker.py"
test -s "${incoming}/worker/build_prompt.py"
test -s "${incoming}/worker/xvector_activation.py"
test -s "${incoming}/nari_qwen3_tts/model/text.py"
test -s "${release_record}"
test "$(sha256sum "${worker}" | cut -d' ' -f1)" = \
  "$(sha256sum "${incoming}/worker/clone_worker.py" | cut -d' ' -f1)"
test "$(sha256sum "${builder}" | cut -d' ' -f1)" = \
  "$(sha256sum "${incoming}/worker/build_prompt.py" | cut -d' ' -f1)"
test "$(sha256sum "${activation_validator}" | cut -d' ' -f1)" = \
  "$(sha256sum "${incoming}/worker/xvector_activation.py" | cut -d' ' -f1)"
test "$(sha256sum "${reader}" | cut -d' ' -f1)" = \
  "$(sha256sum "${incoming}/nari_qwen3_tts/model/text.py" | cut -d' ' -f1)"
test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:18094/ready >/dev/null
curl -fsS --max-time 3 http://127.0.0.1:18890/health | grep -q '"status":"healthy"'

rollback() {
  echo "x-vector writer activation failed; disabling new voice creation" >&2
  rm -f "${marker}" "${marker}.next"
}
trap rollback ERR

"${base}/venv/bin/python" "${activation_validator}" \
  --marker "${marker}" \
  --source-commit "${source_commit}" \
  --release-record "${release_record}" \
  --releases-dir "${base}/releases" \
  --worker "${worker}" \
  --builder "${builder}" \
  --activation-validator "${activation_validator}" \
  --reader "${reader}"

curl -fsS --max-time 3 http://127.0.0.1:18890/health \
  | grep -q '"voice_creation_enabled":true'

trap - ERR
echo "writer_marker=${marker}"
echo "release_record=${release_record}"
curl -fsS http://127.0.0.1:18890/health
