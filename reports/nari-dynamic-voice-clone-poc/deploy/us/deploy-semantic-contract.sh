#!/bin/bash
set -euo pipefail

base=/workspace/castreader-clone
incoming="${base}/release-incoming-semantic-contract"
app="${base}/app"
source_commit="${1:?pass the 40-character source commit SHA}"
asr_revision=e37978b90ca9030d5170a5c07aadb050351a65bb
asr_model="/workspace/.hf_home/hub/models--openai--whisper-base/snapshots/${asr_revision}"
files=(clone_worker.py build_prompt.py semantic_asr.py)

if [[ ! "${source_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid source commit SHA" >&2
  exit 64
fi

for name in "${files[@]}"; do
  test -s "${incoming}/${name}"
  /workspace/nari-qwen3-tts-clean/venv/bin/python -m py_compile \
    "${incoming}/${name}"
done
test -s "${incoming}/run-clone-worker.sh"
bash -n "${incoming}/run-clone-worker.sh"
asr_model_files_sha256=$(/workspace/nari-qwen3-tts-clean/venv/bin/python - "${asr_model}" <<'PY'
import hashlib
import json
import pathlib
import sys

model = pathlib.Path(sys.argv[1])
expected = {
    "config.json": "a153c53883a6799b6f056b4a8d1a515c9926d03994682ba88a7616618d7da0c1",
    "generation_config.json": "444b3f636d2fff89dd9ecf549e2a085b61f7ff0fa0246d4628bac6a3b8cc9ba4",
    "model.safetensors": "07cadb9f25677c8d50df603e66a98fbd842cce45047139baeb16e6219a1e807b",
    "preprocessor_config.json": "9b5cd03a36fbb8a627c64d98a5b5b126ead95a77720723944487311f0110b666",
    "tokenizer.json": "27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566",
}
actual = {
    name: hashlib.sha256((model / name).read_bytes()).hexdigest()
    for name in expected
}
if actual != expected:
    raise SystemExit("pinned ASR checkpoint file hash mismatch")
print(json.dumps(actual, sort_keys=True, separators=(",", ":")))
PY
)

test "$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8880/health)" = 200
curl -fsS --max-time 3 http://127.0.0.1:8094/ready >/dev/null
health_before=$(curl -fsS --max-time 3 http://127.0.0.1:8890/health)
/workspace/nari-qwen3-tts-clean/venv/bin/python - "${health_before}" <<'PY'
import json
import sys

health = json.loads(sys.argv[1])
if health.get("status") != "healthy":
    raise SystemExit("clone worker is not healthy")
PY

idle_streak=0
for attempt in $(seq 1 60); do
  health=$(curl -fsS --max-time 3 http://127.0.0.1:8890/health)
  queue=$(/workspace/nari-qwen3-tts-clean/venv/bin/python - "${health}" <<'PY'
import json
import sys
print(int(json.loads(sys.argv[1]).get("queue_depth", -1)))
PY
)
  busy=$(/workspace/nari-qwen3-tts-clean/venv/bin/python - "${health}" <<'PY'
import json
import sys
print("yes" if json.loads(sys.argv[1]).get("busy") else "no")
PY
)
  utilization=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | tr -d ' ')
  if [[ "${queue}" == "0" && "${busy}" == "no" ]] \
    && [[ "${utilization}" =~ ^[0-9]+$ ]] && (( utilization <= 2 )); then
    idle_streak=$((idle_streak + 1))
  else
    idle_streak=0
  fi
  if (( idle_streak >= 3 )); then
    echo "idle_window_ready attempt=${attempt} utilization=${utilization}%"
    break
  fi
  sleep 2
done
if (( idle_streak < 3 )); then
  echo "No safe idle window; deployment not started." >&2
  exit 75
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="${base}/backups/semantic-contract-${stamp}"
release_record="${base}/releases/semantic-contract-${stamp}.json"
mkdir -p "${backup}" "${base}/releases"
for name in "${files[@]}"; do
  if [[ -e "${app}/${name}" ]]; then
    cp -a "${app}/${name}" "${backup}/${name}"
  fi
done
cp -a "${base}/run-clone-worker.sh" "${backup}/run-clone-worker.sh"

rollback() {
  echo "semantic contract deployment failed; restoring ${backup}" >&2
  for name in "${files[@]}"; do
    if [[ -e "${backup}/${name}" ]]; then
      cp -a "${backup}/${name}" "${app}/${name}"
    else
      rm -f "${app}/${name}"
    fi
  done
  cp -a "${backup}/run-clone-worker.sh" "${base}/run-clone-worker.sh"
  supervisorctl restart castreader-clone >/dev/null || true
}
trap rollback ERR

for name in "${files[@]}"; do
  cp "${incoming}/${name}" "${app}/${name}.next"
  chown --reference="${app}/clone_worker.py" "${app}/${name}.next"
  chmod --reference="${app}/clone_worker.py" "${app}/${name}.next"
  mv "${app}/${name}.next" "${app}/${name}"
done
cp "${incoming}/run-clone-worker.sh" "${base}/run-clone-worker.sh.next"
chown --reference="${base}/run-clone-worker.sh" "${base}/run-clone-worker.sh.next"
chmod --reference="${base}/run-clone-worker.sh" "${base}/run-clone-worker.sh.next"
mv "${base}/run-clone-worker.sh.next" "${base}/run-clone-worker.sh"

supervisorctl restart castreader-clone >/dev/null

ready=no
for attempt in $(seq 1 60); do
  old_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8880/health || true)
  nari_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8094/ready || true)
  worker_body=$(curl -sS --max-time 2 http://127.0.0.1:8890/health || true)
  if [[ "${old_code}" == 200 && "${nari_code}" == 200 ]] \
    && grep -q '"status":"healthy"' <<<"${worker_body}"; then
    ready=yes
    echo "semantic_contract_worker_ready attempt=${attempt}"
    break
  fi
  sleep 2
done
test "${ready}" = yes

/workspace/nari-qwen3-tts-clean/venv/bin/python - \
  "${source_commit}" \
  "$(sha256sum "${app}/clone_worker.py" | cut -d' ' -f1)" \
  "$(sha256sum "${app}/build_prompt.py" | cut -d' ' -f1)" \
  "$(sha256sum "${app}/semantic_asr.py" | cut -d' ' -f1)" \
  "$(sha256sum "${base}/run-clone-worker.sh" | cut -d' ' -f1)" \
  "${asr_revision}" \
  "${asr_model_files_sha256}" \
  "${release_record}" <<'PY'
import json
import pathlib
import sys

(
    commit,
    worker_hash,
    builder_hash,
    asr_worker_hash,
    runner_hash,
    asr_revision,
    asr_model_files_json,
    destination,
) = sys.argv[1:]
pathlib.Path(destination).write_text(
    json.dumps(
        {
            "source_commit": commit,
            "clone_worker_sha256": worker_hash,
            "build_prompt_sha256": builder_hash,
            "semantic_asr_sha256": asr_worker_hash,
            "runner_sha256": runner_hash,
            "asr_revision": asr_revision,
            "asr_model_files_sha256": json.loads(asr_model_files_json),
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

trap - ERR
echo "backup=${backup}"
echo "release_record=${release_record}"
supervisorctl status castreader-clone castreader-nari-base castreader-tts
curl -fsS http://127.0.0.1:8890/health
nvidia-smi --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
