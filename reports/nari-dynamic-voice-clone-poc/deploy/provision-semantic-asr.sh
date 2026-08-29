#!/bin/bash
set -euo pipefail

python_bin="${1:?pass the production worker Python binary}"
hf_home="${2:?pass the persistent Hugging Face cache root}"
requirements="${3:?pass requirements-semantic-asr.txt}"
revision=e37978b90ca9030d5170a5c07aadb050351a65bb

test -x "${python_bin}"
test -s "${requirements}"
mkdir -p "${hf_home}"

if command -v uv >/dev/null 2>&1; then
  uv pip install --python "${python_bin}" -r "${requirements}"
else
  "$(dirname "${python_bin}")/pip" install -r "${requirements}"
fi
HF_HOME="${hf_home}" "${python_bin}" - "${revision}" <<'PY'
from __future__ import annotations

import hashlib
import pathlib
import sys

from huggingface_hub import snapshot_download

revision = sys.argv[1]
path = pathlib.Path(
    snapshot_download("openai/whisper-base", revision=revision)
).resolve()
expected = {
    "model.safetensors": "07cadb9f25677c8d50df603e66a98fbd842cce45047139baeb16e6219a1e807b",
    "config.json": "a153c53883a6799b6f056b4a8d1a515c9926d03994682ba88a7616618d7da0c1",
    "generation_config.json": "444b3f636d2fff89dd9ecf549e2a085b61f7ff0fa0246d4628bac6a3b8cc9ba4",
    "preprocessor_config.json": "9b5cd03a36fbb8a627c64d98a5b5b126ead95a77720723944487311f0110b666",
    "tokenizer.json": "27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566",
}
for name, digest in expected.items():
    actual = hashlib.sha256((path / name).read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f"ASR checkpoint hash mismatch: {name}")
if path.name != revision:
    raise SystemExit("ASR checkpoint did not resolve to the pinned revision")
print(path)
PY
