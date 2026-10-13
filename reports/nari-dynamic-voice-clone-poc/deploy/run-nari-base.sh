#!/bin/bash
set -euo pipefail

export PYTHONPATH=/workspace/nari-qwen3-tts-clean/src
export NARI_VOICE_PROMPT_ROOT=/workspace/castreader-clone/voices

exec /workspace/nari-qwen3-tts-clean/venv/bin/python -m nari_qwen3_tts.serve \
  --model /workspace/qwen3-tts-base/model-0.6b-base \
  --local-files-only \
  --allow-non-h100 \
  --engine-config /workspace/nari-qwen3-tts-clean/rtx4090-single.yaml \
  --host 127.0.0.1 \
  --port 8094 \
  --readiness-text "Base dynamic voice clone ready."
