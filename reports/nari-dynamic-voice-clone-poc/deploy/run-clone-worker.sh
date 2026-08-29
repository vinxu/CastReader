#!/bin/bash
set -euo pipefail

export NARI_VOICE_PROMPT_ROOT=/workspace/castreader-clone/voices
export CLONE_ASR_MODEL_DIR="${CLONE_ASR_MODEL_DIR:-/workspace/.hf_home/hub/models--openai--whisper-base/snapshots/e37978b90ca9030d5170a5c07aadb050351a65bb}"
export CLONE_ASR_WARMUP="${CLONE_ASR_WARMUP:-0}"
quality_root="${CLONE_QUALITY_ROOT:-/workspace/castreader-clone/quality}"
export CLONE_SPEAKER_MODEL="${CLONE_SPEAKER_MODEL:-${quality_root}/models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx}"
export PYTHONPATH="${quality_root}/deps${PYTHONPATH:+:${PYTHONPATH}}"
export LD_LIBRARY_PATH="${quality_root}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

exec /workspace/nari-qwen3-tts-clean/venv/bin/python -m uvicorn \
  clone_worker:app \
  --app-dir /workspace/castreader-clone/app \
  --host 127.0.0.1 \
  --port 8890 \
  --workers 1 \
  --log-level info
