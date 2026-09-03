#!/bin/bash
set -euo pipefail

export NARI_VOICE_PROMPT_ROOT=/workspace/castreader-clone/voices
export CLONE_WARMUP="${CLONE_WARMUP:-1}"
export CLONE_VOICE_BUILD_TIMEOUT_SECONDS="${CLONE_VOICE_BUILD_TIMEOUT_SECONDS:-75}"
export CLONE_ASR_MODEL_DIR="${CLONE_ASR_MODEL_DIR:-/workspace/.hf_home/hub/models--openai--whisper-base/snapshots/e37978b90ca9030d5170a5c07aadb050351a65bb}"
export CLONE_ASR_WARMUP="${CLONE_ASR_WARMUP:-0}"
quality_root="${CLONE_QUALITY_ROOT:-/workspace/castreader-clone/quality}"
export CLONE_SPEAKER_MODEL="${CLONE_SPEAKER_MODEL:-${quality_root}/models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx}"
export CLONE_DENOISE_MODE="${CLONE_DENOISE_MODE:-on}"
export CLONE_DENOISE_MODE_FILE="${CLONE_DENOISE_MODE_FILE:-/workspace/castreader-clone/.adaptive-denoise-mode}"
export CLONE_DEEPFILTER_BIN="${CLONE_DEEPFILTER_BIN:-/workspace/castreader-clone/denoise/bin/deep-filter}"
export CLONE_DEEPFILTER_SHA256="${CLONE_DEEPFILTER_SHA256:-70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da}"
export CLONE_DIARIZATION_MODEL="${CLONE_DIARIZATION_MODEL:-${quality_root}/models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx}"
export CLONE_DIARIZATION_SHA256="${CLONE_DIARIZATION_SHA256:-220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079}"
export CLONE_SPEAKER_MODEL_SHA256="${CLONE_SPEAKER_MODEL_SHA256:-f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11}"
export CLONE_DIARIZATION_CLUSTER_THRESHOLD="${CLONE_DIARIZATION_CLUSTER_THRESHOLD:-0.30}"
export CLONE_DENOISE_WARMUP="${CLONE_DENOISE_WARMUP:-1}"
export PYTHONPATH="${quality_root}/deps${PYTHONPATH:+:${PYTHONPATH}}"
export LD_LIBRARY_PATH="${quality_root}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

exec /workspace/nari-qwen3-tts-clean/venv/bin/python -m uvicorn \
  clone_worker:app \
  --app-dir /workspace/castreader-clone/app \
  --host 127.0.0.1 \
  --port 8890 \
  --workers 1 \
  --log-level info
