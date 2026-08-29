#!/bin/bash
set -euo pipefail

base=/workspace/castreader-clone
incoming="${base}/release-incoming-semantic-contract"
app="${base}/app"
source_commit="${1:?pass the 40-character source commit SHA}"

if [[ ! "${source_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid source commit SHA" >&2
  exit 64
fi

for name in clone_worker.py build_prompt.py; do
  test -s "${incoming}/${name}"
  /workspace/nari-qwen3-tts-clean/venv/bin/python -m py_compile \
    "${incoming}/${name}"
done

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
for name in clone_worker.py build_prompt.py; do
  cp -a "${app}/${name}" "${backup}/${name}"
done

rollback() {
  echo "semantic contract deployment failed; restoring ${backup}" >&2
  for name in clone_worker.py build_prompt.py; do
    cp -a "${backup}/${name}" "${app}/${name}"
  done
  supervisorctl restart castreader-clone >/dev/null || true
}
trap rollback ERR

for name in clone_worker.py build_prompt.py; do
  cp "${incoming}/${name}" "${app}/${name}.next"
  chown --reference="${app}/${name}" "${app}/${name}.next"
  chmod --reference="${app}/${name}" "${app}/${name}.next"
  mv "${app}/${name}.next" "${app}/${name}"
done

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
  "${release_record}" <<'PY'
import json
import pathlib
import sys

commit, worker_hash, builder_hash, destination = sys.argv[1:]
pathlib.Path(destination).write_text(
    json.dumps(
        {
            "source_commit": commit,
            "clone_worker_sha256": worker_hash,
            "build_prompt_sha256": builder_hash,
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
