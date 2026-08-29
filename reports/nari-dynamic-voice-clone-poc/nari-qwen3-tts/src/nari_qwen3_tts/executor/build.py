"""Concrete construction of the fixed Qwen3-TTS CUDA executors."""

from __future__ import annotations

import math

import torch

from nari_qwen3_tts.contract.stage import CudaGraphKey
from nari_qwen3_tts.executor.code_predictor import CodePredictorExecutor
from nari_qwen3_tts.executor.codec import CodecExecutor
from nari_qwen3_tts.executor.cuda_graph import CudaGraphPoolFence, TorchCaptureDriver
from nari_qwen3_tts.executor.executor import Executor
from nari_qwen3_tts.executor.optimizations import install_capture_optimizations
from nari_qwen3_tts.executor.talker import TalkerExecutor
from nari_qwen3_tts.executor.talker_kv import PagedTalkerKV
from nari_qwen3_tts.model.checkpoint import LoadedModelAssets
from nari_qwen3_tts.model.input_layout import BaseVoiceCloneConditioning
from nari_qwen3_tts.profile import ResolvedProfile


def build_cuda_execution(
    assets: LoadedModelAssets,
    *,
    config: ResolvedProfile,
    required_keys: frozenset[CudaGraphKey],
) -> Executor:
    """Build the complete typed CUDA execution surface without capturing it yet."""
    stages = config.stages
    resources = config.resources
    device = assets.device
    if device.type != "cuda" or not torch.cuda.is_available():
        raise RuntimeError("production execution requires CUDA")
    model_config = assets.model_config
    talker_config = model_config.talker
    prefill = stages.talker_prefill
    largest_prefill_tokens = max(
        prefill.token_buckets[-1],
        prefill.exact_batch_sizes[-1] * prefill.exact_sequence_lengths[-1],
    )
    cache = PagedTalkerKV(
        num_layers=talker_config.num_hidden_layers,
        num_kv_heads=talker_config.num_key_value_heads,
        num_qo_heads=talker_config.num_attention_heads,
        head_dim=talker_config.head_dim,
        total_pages=resources.kv_pages,
        page_size=resources.kv_page_size,
        scratch_page_count=max(
            math.ceil(largest_prefill_tokens / resources.kv_page_size),
            stages.talker_decode.batch_sizes[-1],
        ),
        workspace_bytes=resources.workspace_bytes,
        device=device,
        dtype=assets.talker.get_input_embeddings().weight.dtype,
    )
    talker_pool = torch.cuda.graphs.graph_pool_handle()
    code_predictor_pool = torch.cuda.graphs.graph_pool_handle()
    codec_pool = torch.cuda.graphs.graph_pool_handle()
    generation_fence = CudaGraphPoolFence(device=device)
    codec_fence = CudaGraphPoolFence(device=device)
    model_dtype = assets.talker.get_input_embeddings().weight.dtype
    base_conditioning = None
    if model_config.tts_model_type == "base":
        prompt = assets.voice_clone_prompt
        if prompt is None:
            raise RuntimeError("Qwen3-TTS Base assets require a cached voice-clone prompt")
        ref_code = prompt.ref_code.to(device=device, dtype=torch.long)
        reference_codec_embeddings = assets.talker.get_input_embeddings()(ref_code[:, 0])
        for group_index in range(1, model_config.num_code_groups):
            reference_codec_embeddings = reference_codec_embeddings + assets.code_predictor.get_embedding(
                group_index
            )(ref_code[:, group_index])
        base_conditioning = BaseVoiceCloneConditioning(
            speaker_embedding=prompt.ref_spk_embedding.to(dtype=model_dtype).contiguous(),
            reference_codec_embeddings=reference_codec_embeddings.to(device="cpu").contiguous(),
            # The bundled prompt is used by startup warmup and has no explicit
            # decoder bootstrap contract. Dynamic prompt v3 supplies the small
            # silence prefix through EncodedText instead.
            reference_codec_tokens=None,
            reference_codec_context=None,
        )
    talker = TalkerExecutor(
        model=assets.talker,
        config=model_config,
        cache=cache,
        capture_slots=resources.talker_capture_slots,
        driver=TorchCaptureDriver(
            device=device,
            autocast_dtype=model_dtype,
            memory_pool=talker_pool,
        ),
        submission_fence=generation_fence,
        base_conditioning=base_conditioning,
    )
    # The published engine targets H100 and its FP8 gate/up kernel is SM90-only.
    # In experimental non-H100 mode, retain the rest of the captured execution
    # path and fall back to the checkpoint's BF16 gate/up projection.
    require_talker_fp8 = torch.cuda.get_device_capability(device)[0] == 9
    optimizations = install_capture_optimizations(
        assets,
        require_talker_fp8=require_talker_fp8,
    )
    code_predictor = CodePredictorExecutor(
        model=assets.code_predictor,
        layer0_embedding=assets.code_predictor_layer0_embedding,
        config=model_config,
        max_batch_size=stages.code_predictor.max_batch_size,
        driver=TorchCaptureDriver(
            device=device,
            autocast_dtype=model_dtype,
            memory_pool=code_predictor_pool,
        ),
        submission_fence=generation_fence,
    )
    codec = CodecExecutor(
        model=assets.codec,
        num_code_groups=model_config.num_code_groups,
        cold_frame_sizes=stages.codec.frames.cold,
        device=device,
        driver=TorchCaptureDriver(
            device=device,
            autocast_dtype=None,
            memory_pool=codec_pool,
        ),
        submission_fence=codec_fence,
    )
    return Executor(
        config=config,
        required_keys=required_keys,
        talker=talker,
        code_predictor=code_predictor,
        codec=codec,
        optimizations=optimizations,
    )


__all__ = ["build_cuda_execution"]
