"""Input construction helpers for the two Qwen3-TTS Talker modes."""

from __future__ import annotations

from dataclasses import dataclass

import torch


@dataclass(frozen=True)
class PackedTalkerTokenLayout:
    """Integer Talker prefill layout plus request-local continuation data."""

    text_token_ids: torch.Tensor
    codec_token_ids: torch.Tensor
    codec_token_mask: torch.Tensor
    seq_lens: list[int]
    trailing_text_ids: list[torch.Tensor]
    tts_pad_id: torch.Tensor
    extra_embeddings: torch.Tensor | None = None


@dataclass(frozen=True)
class BaseVoiceCloneConditioning:
    """Cached Base conditioning after the one-time reference encoders run."""

    speaker_embedding: torch.Tensor
    reference_codec_embeddings: torch.Tensor
    reference_codec_tokens: torch.Tensor | None = None
    reference_codec_context: torch.Tensor | None = None
    x_vector_only: bool = False

    def __post_init__(self) -> None:
        if type(self.x_vector_only) is not bool:
            raise TypeError("Base x-vector mode must be a boolean")
        if self.speaker_embedding.ndim != 1 or not self.speaker_embedding.is_floating_point():
            raise ValueError("Base speaker embedding must be a floating-point vector")
        if (
            self.reference_codec_embeddings.ndim != 2
            or self.reference_codec_embeddings.shape[0] < 1
            or not self.reference_codec_embeddings.is_floating_point()
        ):
            raise ValueError("Base reference codec embeddings must be a non-empty matrix")
        if self.reference_codec_embeddings.shape[1] != self.speaker_embedding.numel():
            raise ValueError("Base conditioning hidden sizes must match")
        if self.reference_codec_embeddings.device != self.speaker_embedding.device:
            raise ValueError("Base conditioning tensors must share one device")
        if self.reference_codec_tokens is not None:
            tokens = self.reference_codec_tokens
            if tokens.ndim != 2 or tokens.shape[0] < 1:
                raise ValueError("Base reference codec tokens must be a non-empty matrix")
            if tokens.dtype != torch.long:
                raise TypeError("Base reference codec tokens must use torch.long")
        if self.reference_codec_context is not None:
            context = self.reference_codec_context
            if context.ndim != 2 or context.shape[0] < 1:
                raise ValueError("Base reference codec context must be a non-empty matrix")
            if context.dtype != torch.long:
                raise TypeError("Base reference codec context must use torch.long")
        if self.reference_codec_tokens is not None and self.reference_codec_context is not None:
            raise ValueError("Base decoder prefix and full context are mutually exclusive")


def _custom_voice_codec_prefix(
    config,
    *,
    language: str,
    speaker: str,
) -> tuple[int, list[int]]:
    """Resolve request metadata to the official CustomVoice codec prefix."""
    talker_config = config.talker_config
    speaker_key = speaker.lower()
    if speaker_key not in talker_config.spk_id:
        raise ValueError(f"Unsupported Qwen3-TTS speaker: {speaker!r}")
    speaker_id = talker_config.spk_id[speaker_key]

    language_key = language.lower()
    if language_key == "auto":
        language_id = None
    elif language_key in talker_config.codec_language_id:
        language_id = talker_config.codec_language_id[language_key]
    else:
        raise ValueError(f"Unsupported Qwen3-TTS language: {language!r}")

    if language_key in {"chinese", "auto"} and talker_config.spk_is_dialect[speaker_key]:
        dialect = talker_config.spk_is_dialect[speaker_key]
        language_id = talker_config.codec_language_id[dialect]

    if language_id is None:
        codec_prefix = [
            talker_config.codec_nothink_id,
            talker_config.codec_think_bos_id,
            talker_config.codec_think_eos_id,
        ]
    else:
        codec_prefix = [
            talker_config.codec_think_id,
            talker_config.codec_think_bos_id,
            language_id,
            talker_config.codec_think_eos_id,
        ]
    return speaker_id, codec_prefix


def custom_voice_talker_input_seq_len(
    config,
    *,
    text_token_count: int,
    instruct_token_count: int,
    language: str,
    speaker: str,
    non_streaming_mode: bool,
) -> int:
    """Return the prefill length without launching tensor operations."""
    _, codec_prefix = _custom_voice_codec_prefix(
        config,
        language=language,
        speaker=speaker,
    )
    role_token_count = min(text_token_count, 3)
    prefix_token_count = len(codec_prefix) + 2
    if non_streaming_mode:
        target_token_count = max(0, text_token_count - 8) + 1
        continuation_token_count = target_token_count + 1
    else:
        continuation_token_count = int(text_token_count > 3)
    return instruct_token_count + role_token_count + prefix_token_count + continuation_token_count


def build_batched_custom_voice_talker_token_layout(  # noqa: PLR0915 - one explicit fixed layout
    config,
    text_inputs: list[torch.Tensor],
    instruct_inputs: list[torch.Tensor],
    *,
    languages: list[str],
    speakers: list[str],
    non_streaming_modes: list[bool],
) -> PackedTalkerTokenLayout:
    """Build the integer CustomVoice layout consumed by captured prefill.

    Keeping embedding lookup out of this function lets the Talker CUDA Graph
    capture text/codec lookup and addition together with transformer prefill.
    Trailing text is returned separately so callers can materialize it in one
    batched lookup without copying the full prefill embedding tensor.
    """
    batch_size = len(text_inputs)
    if batch_size == 0:
        raise ValueError("Qwen3-TTS Talker prefill batch cannot be empty")
    if not (len(instruct_inputs) == len(languages) == len(speakers) == len(non_streaming_modes) == batch_size):
        raise ValueError("Qwen3-TTS Talker prefill batch fields must have equal lengths")
    talker_config = config.talker_config
    text_dtype = text_inputs[0].dtype
    device = text_inputs[0].device
    special_text_ids = torch.tensor(
        [
            config.tts_bos_token_id,
            config.tts_eos_token_id,
            config.tts_pad_token_id,
        ],
        dtype=text_dtype,
        device=device,
    )
    tts_bos_id = special_text_ids[0:1]
    tts_eos_id = special_text_ids[1:2]
    tts_pad_id = special_text_ids[2:3]

    prefill_text_pieces: list[torch.Tensor] = []
    prefill_codec_ids: list[int] = []
    prefill_codec_mask: list[bool] = []
    trailing_text_ids: list[torch.Tensor] = []
    seq_lens: list[int] = []
    packed_length = 0

    for raw_text, raw_instruct, language, speaker, non_streaming_mode in zip(
        text_inputs,
        instruct_inputs,
        languages,
        speakers,
        non_streaming_modes,
        strict=True,
    ):
        text = raw_text.reshape(-1)
        instruct = raw_instruct.reshape(-1)
        speaker_id, codec_prefix = _custom_voice_codec_prefix(
            config,
            language=language,
            speaker=speaker,
        )

        if instruct.numel():
            prefill_text_pieces.append(instruct)
            prefill_codec_ids.extend([talker_config.codec_pad_id] * instruct.numel())
            prefill_codec_mask.extend([False] * instruct.numel())
        role_text = text[:3]
        if role_text.numel():
            prefill_text_pieces.append(role_text)
            prefill_codec_ids.extend([talker_config.codec_pad_id] * role_text.numel())
            prefill_codec_mask.extend([False] * role_text.numel())

        # Prefix text is PAD for every codec conditioning token except the
        # final slot, where the official layout uses text BOS.
        prefill_text_pieces.append(tts_pad_id.expand(len(codec_prefix) + 1))
        prefill_text_pieces.append(tts_bos_id)
        request_codec_ids = [
            *codec_prefix,
            speaker_id,
            talker_config.codec_pad_id,
        ]
        prefill_codec_ids.extend(request_codec_ids)
        prefill_codec_mask.extend([True] * len(request_codec_ids))

        if non_streaming_mode:
            target_text = text[3:-5]
            if target_text.numel():
                prefill_text_pieces.append(target_text)
            prefill_text_pieces.extend([tts_eos_id, tts_pad_id])
            continuation_codec_ids = [talker_config.codec_pad_id] * (target_text.numel() + 1)
            continuation_codec_ids.append(talker_config.codec_bos_id)
            prefill_codec_ids.extend(continuation_codec_ids)
            prefill_codec_mask.extend([True] * len(continuation_codec_ids))
            trailing_text_ids.append(tts_pad_id)
        else:
            first_text = text[3:4]
            if first_text.numel():
                prefill_text_pieces.append(first_text)
                prefill_codec_ids.append(talker_config.codec_bos_id)
                prefill_codec_mask.append(True)

            trailing_text = text[4:-5]
            trailing_text_ids.append(torch.cat([trailing_text, tts_eos_id], dim=0))

        seq_len = custom_voice_talker_input_seq_len(
            config,
            text_token_count=text.numel(),
            instruct_token_count=instruct.numel(),
            language=language,
            speaker=speaker,
            non_streaming_mode=non_streaming_mode,
        )
        if len(prefill_codec_ids) != packed_length + seq_len or len(prefill_codec_mask) != packed_length + seq_len:
            raise RuntimeError("Qwen3-TTS Talker prefill layout length mismatch")
        seq_lens.append(seq_len)
        packed_length += seq_len

    packed_text_ids = torch.cat(prefill_text_pieces, dim=0)
    packed_codec_ids = torch.tensor(
        prefill_codec_ids,
        dtype=text_dtype,
        device=device,
    )
    packed_codec_mask = torch.tensor(
        prefill_codec_mask,
        dtype=torch.bool,
        device=device,
    )
    if not (packed_text_ids.shape == packed_codec_ids.shape == packed_codec_mask.shape):
        raise RuntimeError("Qwen3-TTS packed prefill fields have mismatched lengths")
    return PackedTalkerTokenLayout(
        text_token_ids=packed_text_ids,
        codec_token_ids=packed_codec_ids,
        codec_token_mask=packed_codec_mask,
        seq_lens=seq_lens,
        trailing_text_ids=trailing_text_ids,
        tts_pad_id=tts_pad_id,
    )


def _base_codec_prefix(config, *, language: str) -> list[int]:
    talker = config.talker_config
    key = language.lower()
    if key == "auto":
        return [
            talker.codec_nothink_id,
            talker.codec_think_bos_id,
            talker.codec_think_eos_id,
        ]
    if key not in talker.codec_language_id:
        raise ValueError(f"Unsupported Qwen3-TTS language: {language!r}")
    return [
        talker.codec_think_id,
        talker.codec_think_bos_id,
        talker.codec_language_id[key],
        talker.codec_think_eos_id,
    ]


def build_batched_base_talker_token_layout(  # noqa: PLR0915 - mirrors the official Base layout
    config,
    text_inputs: list[torch.Tensor],
    ref_inputs: list[torch.Tensor],
    *,
    languages: list[str],
    speakers: list[str],
    non_streaming_modes: list[bool],
    conditionings: list[BaseVoiceCloneConditioning],
) -> PackedTalkerTokenLayout:
    """Build the official Base ICL prefix using one cached clone prompt."""

    batch_size = len(text_inputs)
    if batch_size == 0:
        raise ValueError("Qwen3-TTS Base prefill batch cannot be empty")
    if not (len(ref_inputs) == len(languages) == len(speakers) == len(non_streaming_modes) == batch_size):
        raise ValueError("Qwen3-TTS Base prefill batch fields must have equal lengths")
    if len(conditionings) != batch_size:
        raise ValueError("Qwen3-TTS Base conditioning rows must match the batch")
    if any(speaker != "clone" for speaker in speakers):
        raise ValueError("Qwen3-TTS Base requires voice='clone'")

    talker = config.talker_config
    device = text_inputs[0].device
    dtype = text_inputs[0].dtype
    if any(conditioning.speaker_embedding.device != device for conditioning in conditionings):
        raise ValueError("Base conditioning and token inputs must share one device")
    hidden_size = conditionings[0].speaker_embedding.numel()
    if any(conditioning.speaker_embedding.numel() != hidden_size for conditioning in conditionings):
        raise ValueError("Base conditioning hidden sizes must match")
    special = torch.tensor(
        [config.tts_bos_token_id, config.tts_eos_token_id, config.tts_pad_token_id],
        dtype=dtype,
        device=device,
    )
    tts_bos_id, tts_eos_id, tts_pad_id = special[0:1], special[1:2], special[2:3]

    packed_text: list[torch.Tensor] = []
    packed_codec: list[torch.Tensor] = []
    packed_mask: list[torch.Tensor] = []
    packed_extra: list[torch.Tensor] = []
    trailing_text_ids: list[torch.Tensor] = []
    seq_lens: list[int] = []

    def append_piece(
        text_ids: torch.Tensor,
        codec_ids: list[int] | torch.Tensor,
        mask: list[bool] | torch.Tensor,
        extra: torch.Tensor | None = None,
    ) -> None:
        text_ids = text_ids.reshape(-1)
        codec_tensor = torch.as_tensor(codec_ids, dtype=dtype, device=device).reshape(-1)
        mask_tensor = torch.as_tensor(mask, dtype=torch.bool, device=device).reshape(-1)
        if not (text_ids.numel() == codec_tensor.numel() == mask_tensor.numel()):
            raise RuntimeError("Base Talker piece fields have mismatched lengths")
        packed_text.append(text_ids)
        packed_codec.append(codec_tensor)
        packed_mask.append(mask_tensor)
        if extra is None:
            extra = torch.zeros(
                (text_ids.numel(), hidden_size),
                dtype=conditioning.speaker_embedding.dtype,
                device=device,
            )
        if tuple(extra.shape) != (text_ids.numel(), hidden_size):
            raise RuntimeError("Base Talker extra embedding shape mismatch")
        packed_extra.append(extra)

    for raw_text, raw_ref, language, non_streaming_mode, conditioning in zip(
        text_inputs,
        ref_inputs,
        languages,
        non_streaming_modes,
        conditionings,
        strict=True,
    ):
        start = sum(piece.numel() for piece in packed_text)
        text = raw_text.reshape(-1)
        ref = raw_ref.reshape(-1)
        role = text[:3]
        append_piece(role, [talker.codec_pad_id] * role.numel(), [False] * role.numel())

        codec_prefix = _base_codec_prefix(config, language=language)
        prefix_text = torch.cat(
            [tts_pad_id.expand(len(codec_prefix) + 1), tts_bos_id],
            dim=0,
        )
        prefix_extra = torch.zeros(
            (len(codec_prefix) + 2, hidden_size),
            dtype=conditioning.speaker_embedding.dtype,
            device=device,
        )
        prefix_extra[len(codec_prefix)].copy_(conditioning.speaker_embedding)
        append_piece(
            prefix_text,
            [*codec_prefix, talker.codec_pad_id, talker.codec_pad_id],
            [True] * len(codec_prefix) + [False, True],
            prefix_extra,
        )

        reference = conditioning.reference_codec_embeddings
        if conditioning.x_vector_only and non_streaming_mode:
            target_text = torch.cat([text[3:-5], tts_eos_id], dim=0)
            append_piece(
                target_text,
                [talker.codec_pad_id] * target_text.numel(),
                [True] * target_text.numel(),
            )
            append_piece(tts_pad_id, [talker.codec_bos_id], [True])
            trailing_text_ids.append(tts_pad_id)
        elif conditioning.x_vector_only:
            first_target = text[3:4]
            append_piece(first_target, [talker.codec_bos_id], [True])
            trailing = torch.cat([text[4:-5], tts_eos_id], dim=0)
            trailing_text_ids.append(trailing if trailing.numel() else tts_pad_id)
        else:
            icl_text = torch.cat([ref[3:-2], text[3:-5], tts_eos_id], dim=0)
            if non_streaming_mode:
                append_piece(
                    icl_text,
                    [talker.codec_pad_id] * icl_text.numel(),
                    [True] * icl_text.numel(),
                )
                append_piece(tts_pad_id, [talker.codec_bos_id], [True])
                append_piece(
                    tts_pad_id.expand(reference.shape[0]),
                    [talker.codec_pad_id] * reference.shape[0],
                    [False] * reference.shape[0],
                    reference,
                )
                trailing_text_ids.append(tts_pad_id)
            else:
                codec_length = reference.shape[0] + 1
                paired_text = torch.cat(
                    [icl_text[:codec_length], tts_pad_id.expand(max(0, codec_length - icl_text.numel()))],
                    dim=0,
                )
                append_piece(paired_text[:1], [talker.codec_bos_id], [True])
                append_piece(
                    paired_text[1:],
                    [talker.codec_pad_id] * reference.shape[0],
                    [False] * reference.shape[0],
                    reference,
                )
                trailing = icl_text[codec_length:]
                trailing_text_ids.append(trailing if trailing.numel() else tts_pad_id)

        seq_len = sum(piece.numel() for piece in packed_text) - start
        if seq_len < 1:
            raise RuntimeError("Base Talker prefill cannot be empty")
        seq_lens.append(seq_len)

    text_ids = torch.cat(packed_text, dim=0)
    codec_ids = torch.cat(packed_codec, dim=0)
    codec_mask = torch.cat(packed_mask, dim=0)
    extra_embeddings = torch.cat(packed_extra, dim=0)
    if not (text_ids.shape == codec_ids.shape == codec_mask.shape):
        raise RuntimeError("Base packed prefill fields have mismatched lengths")
    return PackedTalkerTokenLayout(
        text_token_ids=text_ids,
        codec_token_ids=codec_ids,
        codec_token_mask=codec_mask,
        seq_lens=seq_lens,
        trailing_text_ids=trailing_text_ids,
        tts_pad_id=tts_pad_id,
        extra_embeddings=extra_embeddings,
    )
