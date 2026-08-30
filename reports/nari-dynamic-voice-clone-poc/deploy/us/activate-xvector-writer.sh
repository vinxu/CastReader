#!/bin/bash
set -euo pipefail

base=/workspace/castreader-clone
nari_base=/workspace/nari-qwen3-tts-clean
incoming="${base}/release-incoming-fast-hotpath"
worker="${base}/app/clone_worker.py"
reader="${nari_base}/src/nari_qwen3_tts/model/text.py"
marker="${base}/.xvector-writer-v1-enabled"
source_commit="${1:?pass the 40-character source commit SHA}"

if [[ ! "${source_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid source commit SHA" >&2
  exit 64
fi

test -s "${incoming}/worker/clone_worker.py"
test -s "${incoming}/nari_qwen3_tts/model/text.py"
test "$(sha256sum "${worker}" | cut -d' ' -f1)" = \
  "$(sha256sum "${incoming}/worker/clone_worker.py" | cut -d' ' -f1)"
test "$(sha256sum "${reader}" | cut -d' ' -f1)" = \
  "$(sha256sum "${incoming}/nari_qwen3_tts/model/text.py" | cut -d' ' -f1)"
test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:8094/ready >/dev/null
curl -fsS --max-time 3 http://127.0.0.1:8890/health | grep -q '"status":"healthy"'

if [[ -e "${marker}" ]]; then
  curl -fsS --max-time 3 http://127.0.0.1:8890/health \
    | grep -q '"voice_creation_enabled":true'
  echo "x-vector writer already enabled"
  exit 0
fi

temporary="${marker}.next"
printf '%s\n' "${source_commit}" > "${temporary}"
chmod 600 "${temporary}"
mv "${temporary}" "${marker}"

rollback() {
  echo "x-vector writer activation failed; disabling new voice creation" >&2
  rm -f "${marker}" "${temporary}"
}
trap rollback ERR

curl -fsS --max-time 3 http://127.0.0.1:8890/health \
  | grep -q '"voice_creation_enabled":true'

trap - ERR
echo "writer_marker=${marker}"
curl -fsS http://127.0.0.1:8890/health
