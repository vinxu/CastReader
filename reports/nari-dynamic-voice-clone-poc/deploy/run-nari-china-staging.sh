#!/bin/bash
set -euo pipefail

staging_root="${NARI_STAGING_ROOT:-/root/autodl-tmp/nari-staging}"
source_root="${NARI_SOURCE_ROOT:-${staging_root}/nari-qwen3-tts}"
model_root="${NARI_MODEL_DIR:-${staging_root}/model-0.6b-base}"
voice_root="${NARI_VOICE_PROMPT_ROOT:-${staging_root}/clone/voices}"
python_bin="${NARI_PYTHON:-${staging_root}/venv/bin/python}"
port="${NARI_PORT:-18094}"
engine_config="${NARI_ENGINE_CONFIG:-${staging_root}/deploy/rtx4090-single.yaml}"

export PYTHONPATH="${source_root}/src"
export NARI_VOICE_PROMPT_ROOT="${voice_root}"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export PATH="${staging_root}/venv/bin:${PATH}"

exec "${python_bin}" -m nari_qwen3_tts.serve \
  --model "${model_root}" \
  --local-files-only \
  --allow-non-h100 \
  --engine-config "${engine_config}" \
  --max-active-requests 1 \
  --host 127.0.0.1 \
  --port "${port}" \
  --readiness-text "Base dynamic voice clone staging ready."
