#!/bin/bash
set -euo pipefail

staging_root="${NARI_STAGING_ROOT:-/root/autodl-tmp/nari-staging}"
python_bin="${NARI_PYTHON:-${staging_root}/venv/bin/python}"
worker_root="${CLONE_WORKER_ROOT:-${staging_root}/worker}"
quality_root="${CLONE_QUALITY_ROOT:-${staging_root}/quality}"
port="${CLONE_PORT:-18890}"

export CLONE_DATA_ROOT="${CLONE_DATA_ROOT:-${staging_root}/clone}"
export CLONE_TOKEN_FILE="${CLONE_TOKEN_FILE:-${staging_root}/clone/.api-token}"
export NARI_MODEL_DIR="${NARI_MODEL_DIR:-${staging_root}/model-0.6b-base}"
export NARI_URL="${NARI_URL:-http://127.0.0.1:18094}"
export NARI_PYTHON="${python_bin}"
export NARI_VOICE_PROMPT_ROOT="${NARI_VOICE_PROMPT_ROOT:-${staging_root}/clone/voices}"
export CLONE_MAX_QUEUE_SIZE="${CLONE_MAX_QUEUE_SIZE:-32}"
export CLONE_SYNTHESIS_TIMEOUT_SECONDS="${CLONE_SYNTHESIS_TIMEOUT_SECONDS:-60}"
export CLONE_VOICE_BUILD_TIMEOUT_SECONDS="${CLONE_VOICE_BUILD_TIMEOUT_SECONDS:-75}"
export NARI_REQUEST_TIMEOUT_SECONDS="${NARI_REQUEST_TIMEOUT_SECONDS:-45}"
export CLONE_WARMUP="${CLONE_WARMUP:-1}"
export CLONE_ASR_MODEL_DIR="${CLONE_ASR_MODEL_DIR:-/root/.cache/huggingface/hub/models--openai--whisper-base/snapshots/e37978b90ca9030d5170a5c07aadb050351a65bb}"
export CLONE_ASR_WARMUP="${CLONE_ASR_WARMUP:-0}"
export CLONE_SPEAKER_MODEL="${CLONE_SPEAKER_MODEL:-${quality_root}/models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx}"
export CLONE_DENOISE_MODE="${CLONE_DENOISE_MODE:-on}"
export CLONE_DENOISE_MODE_FILE="${CLONE_DENOISE_MODE_FILE:-${staging_root}/clone/.adaptive-denoise-mode}"
export CLONE_DEEPFILTER_BIN="${CLONE_DEEPFILTER_BIN:-${staging_root}/denoise/bin/deep-filter}"
export CLONE_DEEPFILTER_SHA256="${CLONE_DEEPFILTER_SHA256:-70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da}"
export CLONE_DIARIZATION_MODEL="${CLONE_DIARIZATION_MODEL:-${quality_root}/models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx}"
export CLONE_DIARIZATION_SHA256="${CLONE_DIARIZATION_SHA256:-220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079}"
export CLONE_SPEAKER_MODEL_SHA256="${CLONE_SPEAKER_MODEL_SHA256:-f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11}"
export CLONE_DIARIZATION_CLUSTER_THRESHOLD="${CLONE_DIARIZATION_CLUSTER_THRESHOLD:-0.30}"
export CLONE_DENOISE_WARMUP="${CLONE_DENOISE_WARMUP:-1}"
export PYTHONPATH="${quality_root}/deps${PYTHONPATH:+:${PYTHONPATH}}"
export LD_LIBRARY_PATH="${quality_root}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

exec "${python_bin}" -m uvicorn \
  clone_worker:app \
  --app-dir "${worker_root}" \
  --host 127.0.0.1 \
  --port "${port}" \
  --workers 1 \
  --log-level info
