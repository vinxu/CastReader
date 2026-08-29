"""Qwen3-TTS Talker input-mode planning without Engine request state."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

import torch

from nari_qwen3_tts.contract.request import TextContinuation
from nari_qwen3_tts.model.input_layout import (
    BaseVoiceCloneConditioning,
    build_batched_base_talker_token_layout,
    build_batched_custom_voice_talker_token_layout,
)


class TalkerInputMode(str, Enum):
    """The two model-defined ways target text enters the Talker."""

    FULL_TEXT_PREFILL = "full_text_prefill"
    STREAMING_DECODE = "streaming_decode"

    @classmethod
    def from_non_streaming_mode(cls, value: bool) -> TalkerInputMode:
        if not isinstance(value, bool):
            raise TypeError("non_streaming_mode must be a boolean")
        return cls.FULL_TEXT_PREFILL if value else cls.STREAMING_DECODE

    @property
    def non_streaming_mode(self) -> bool:
        return self is TalkerInputMode.FULL_TEXT_PREFILL


@dataclass(frozen=True, slots=True)
class TalkerInputPlan:
    """Packed prefill tensors and per-request decode text semantics."""

    text_token_ids: torch.Tensor
    codec_token_ids: torch.Tensor
    codec_token_mask: torch.Tensor
    sequence_lengths: tuple[int, ...]
    continuations: tuple[TextContinuation, ...]
    extra_embeddings: torch.Tensor | None = None
    codec_decoder_prefixes: tuple[torch.Tensor | None, ...] = ()
    codec_decoder_contexts: tuple[torch.Tensor | None, ...] = ()

    def __post_init__(self) -> None:
        if not self.sequence_lengths:
            raise ValueError("Talker input plan cannot be empty")
        if len(self.sequence_lengths) != len(self.continuations):
            raise ValueError("Talker input plan request rows do not match")
        if self.codec_decoder_prefixes and len(self.codec_decoder_prefixes) != len(self.continuations):
            raise ValueError("Codec decoder prefixes must match Talker request rows")
        if self.codec_decoder_contexts and len(self.codec_decoder_contexts) != len(self.continuations):
            raise ValueError("Codec decoder contexts must match Talker request rows")
        if any(isinstance(length, bool) or not isinstance(length, int) for length in self.sequence_lengths):
            raise TypeError("Talker prefill sequence lengths must be integers")
        if any(length < 1 for length in self.sequence_lengths):
            raise ValueError("Talker prefill sequence lengths must be positive")
        expected_tokens = sum(self.sequence_lengths)
        for name in ("text_token_ids", "codec_token_ids", "codec_token_mask"):
            value = getattr(self, name)
            if value.ndim != 1 or value.numel() != expected_tokens:
                raise ValueError(f"{name} must match the packed prefill length")
        if self.text_token_ids.dtype != torch.long or self.codec_token_ids.dtype != torch.long:
            raise TypeError("Talker input plan token IDs must use torch.long")
        if self.codec_token_mask.dtype != torch.bool:
            raise TypeError("Talker input plan codec_token_mask must use torch.bool")
        device = self.text_token_ids.device
        if self.codec_token_ids.device != device or self.codec_token_mask.device != device:
            raise ValueError("Talker input plan tensors must share one device")
        if self.extra_embeddings is not None:
            if self.extra_embeddings.ndim != 2 or self.extra_embeddings.shape[0] != expected_tokens:
                raise ValueError("Talker extra embeddings must match the packed prefill length")
            if not self.extra_embeddings.is_floating_point():
                raise TypeError("Talker extra embeddings must be floating point")
            if self.extra_embeddings.device != device:
                raise ValueError("Talker extra embeddings must share the packed tensor device")
        if any(
            continuation.token_ids.device != device or continuation.pad_token_id.device != device
            for continuation in self.continuations
        ):
            raise ValueError("Talker input plan continuations must share the packed tensor device")
        for prefix in self.codec_decoder_prefixes:
            if prefix is None:
                continue
            if prefix.ndim != 2 or prefix.shape[0] < 1:
                raise ValueError("Codec decoder prefix must be a non-empty frame matrix")
            if prefix.dtype != torch.long:
                raise TypeError("Codec decoder prefix must use torch.long")
        for context in self.codec_decoder_contexts:
            if context is None:
                continue
            if context.ndim != 2 or context.shape[0] < 1:
                raise ValueError("Codec decoder context must be a non-empty frame matrix")
            if context.dtype != torch.long:
                raise TypeError("Codec decoder context must use torch.long")
        if self.codec_decoder_prefixes and self.codec_decoder_contexts:
            for prefix, context in zip(
                self.codec_decoder_prefixes,
                self.codec_decoder_contexts,
                strict=True,
            ):
                if prefix is not None and context is not None:
                    raise ValueError("Codec decoder prefix and full context are mutually exclusive")

    @property
    def modes(self) -> tuple[TalkerInputMode, ...]:
        return tuple(
            TalkerInputMode.from_non_streaming_mode(continuation.non_streaming_mode)
            for continuation in self.continuations
        )

    def decode_text_tokens(self, generation_steps: tuple[int, ...]) -> torch.Tensor:
        if len(generation_steps) != len(self.continuations):
            raise ValueError("Talker generation-step rows do not match the input plan")
        return torch.cat(
            [
                continuation.token_at(step)
                for continuation, step in zip(
                    self.continuations,
                    generation_steps,
                    strict=True,
                )
            ]
        )


def prepare_talker_input_plan(
    config: object,
    *,
    text_inputs: list[torch.Tensor],
    instruct_inputs: list[torch.Tensor],
    languages: list[str],
    speakers: list[str],
    non_streaming_modes: list[bool],
    ref_inputs: list[torch.Tensor] | None = None,
    base_conditionings: list[BaseVoiceCloneConditioning] | None = None,
) -> TalkerInputPlan:
    """Prepare both official input modes through one explicit typed surface."""

    tensors = [*text_inputs, *instruct_inputs, *(ref_inputs or [])]
    if any(not isinstance(value, torch.Tensor) for value in tensors):
        raise TypeError("Talker text and instruction inputs must be tensors")
    if any(value.dtype != torch.long for value in tensors):
        raise TypeError("Talker text and instruction inputs must use torch.long")
    if tensors:
        device = tensors[0].device
        if any(value.device != device for value in tensors):
            raise ValueError("Talker text and instruction inputs must share one device")
    modes = tuple(TalkerInputMode.from_non_streaming_mode(value) for value in non_streaming_modes)
    if getattr(config, "tts_model_type", "custom_voice") == "base":
        if base_conditionings is None or ref_inputs is None:
            raise ValueError("Qwen3-TTS Base requires cached clone conditioning and reference text")
        if any(value.numel() for value in instruct_inputs):
            raise ValueError("Qwen3-TTS Base voice cloning does not accept instructions")
        layout = build_batched_base_talker_token_layout(
            config,
            text_inputs,
            ref_inputs,
            languages=languages,
            speakers=speakers,
            non_streaming_modes=non_streaming_modes,
            conditionings=base_conditionings,
        )
    else:
        layout = build_batched_custom_voice_talker_token_layout(
            config,
            text_inputs,
            instruct_inputs,
            languages=languages,
            speakers=speakers,
            non_streaming_modes=non_streaming_modes,
        )
    return TalkerInputPlan(
        text_token_ids=layout.text_token_ids,
        codec_token_ids=layout.codec_token_ids,
        codec_token_mask=layout.codec_token_mask,
        sequence_lengths=tuple(layout.seq_lens),
        continuations=tuple(
            TextContinuation(
                non_streaming_mode=mode.non_streaming_mode,
                token_ids=token_ids,
                pad_token_id=layout.tts_pad_id,
            )
            for mode, token_ids in zip(modes, layout.trailing_text_ids, strict=True)
        ),
        extra_embeddings=layout.extra_embeddings,
        codec_decoder_prefixes=(
            tuple(
                None if conditioning.x_vector_only else conditioning.reference_codec_tokens
                for conditioning in base_conditionings
            )
            if base_conditionings is not None
            else tuple(None for _ in modes)
        ),
        codec_decoder_contexts=(
            tuple(
                None if conditioning.x_vector_only else conditioning.reference_codec_context
                for conditioning in base_conditionings
            )
            if base_conditionings is not None
            else tuple(None for _ in modes)
        ),
    )


__all__ = [
    "TalkerInputMode",
    "TalkerInputPlan",
    "prepare_talker_input_plan",
]
