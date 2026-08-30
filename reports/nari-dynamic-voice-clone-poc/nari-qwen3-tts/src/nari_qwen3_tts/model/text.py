"""Qwen3-TTS tokenizer wrapping and append-safe text ingress."""

from __future__ import annotations

import copy
import json
import os
import queue
import threading
from collections import OrderedDict
from contextlib import contextmanager
from pathlib import Path
from typing import TYPE_CHECKING, Iterator

import torch

from nari_qwen3_tts.contract.request import (
    EncodedText,
    FragmentTokenization,
    SynthesisRequest,
)
from nari_qwen3_tts.model.streaming_text import (
    StreamingTextControlTokenError,
    StreamingTextTokenization,
)

if TYPE_CHECKING:
    from transformers import Qwen2TokenizerFast


DEFAULT_STREAMING_TOKENIZER_POOL_SIZE = min(4, max(1, os.cpu_count() or 1))


def _strict_bool(name: str, value: object) -> None:
    if type(value) is not bool:
        raise TypeError(f"{name} must be a boolean")

class Qwen3TTSTextDomain:
    """Own exact CustomVoice tokenizer wrapping and append-safe text tokenization."""

    _ASSISTANT_PREFIX = "<|im_start|>assistant\n"
    _ASSISTANT_SUFFIX = "<|im_end|>\n<|im_start|>assistant\n"

    def __init__(
        self,
        model_directory: str | Path,
        *,
        tokenizer_pool_size: int = DEFAULT_STREAMING_TOKENIZER_POOL_SIZE,
    ) -> None:
        if type(tokenizer_pool_size) is not int or tokenizer_pool_size < 1:
            raise ValueError("tokenizer_pool_size must be a positive integer")
        from transformers import Qwen2TokenizerFast

        self.model_directory = Path(model_directory).resolve()
        self.tokenizer = Qwen2TokenizerFast.from_pretrained(
            self.model_directory,
            fix_mistral_regex=True,
        )
        self._tokenizer_pool_size = tokenizer_pool_size
        self._tokenizer_lock = threading.RLock()
        self._pool_init_lock = threading.Lock()
        self._pool: queue.LifoQueue[Qwen2TokenizerFast] | None = None
        self._forbidden_control_tokens = tuple(
            sorted(
                {
                    *(token for token in self.tokenizer.all_special_tokens if token),
                    *(str(token) for token in self.tokenizer.added_tokens_decoder.values() if str(token)),
                },
                key=len,
                reverse=True,
            )
        )
        self._assistant_prefix_ids = self.tokenizer(
            self._ASSISTANT_PREFIX,
            add_special_tokens=False,
        )["input_ids"]
        self._assistant_suffix_ids = self.tokenizer(
            self._ASSISTANT_SUFFIX,
            add_special_tokens=False,
        )["input_ids"]
        raw_config = json.loads((self.model_directory / "config.json").read_text())
        self.tts_model_type = str(raw_config.get("tts_model_type", ""))
        talker_config = raw_config.get("talker_config")
        speaker_embedding_size = (
            talker_config.get("hidden_size")
            if isinstance(talker_config, dict)
            else None
        )
        if type(speaker_embedding_size) is not int or speaker_embedding_size < 1:
            raise ValueError("Talker hidden_size must be a positive integer")
        self._speaker_embedding_size = speaker_embedding_size
        self._base_ref_token_ids: torch.Tensor | None = None
        self._base_prompt_root = Path(
            os.environ.get(
                "NARI_VOICE_PROMPT_ROOT",
                str(self.model_directory / "voice_prompts"),
            )
        ).resolve()
        self._base_prompt_cache: OrderedDict[
            str,
            tuple[
                int,
                torch.Tensor,
                torch.Tensor,
                torch.Tensor,
                torch.Tensor | None,
                torch.Tensor | None,
            ],
        ] = OrderedDict()
        if self.tts_model_type == "base":
            prompt_path = self.model_directory / "voice_clone_prompt.pt"
            if not prompt_path.is_file():
                raise FileNotFoundError(
                    f"Qwen3-TTS Base requires a cached voice-clone prompt: {prompt_path}"
                )
            prompt = torch.load(prompt_path, map_location="cpu", weights_only=True)
            ref_text = prompt.get("ref_text") if isinstance(prompt, dict) else None
            if not isinstance(ref_text, str) or not ref_text.strip():
                raise ValueError("Qwen3-TTS Base voice-clone prompt requires ref_text")
            wrapped_ref = f"{self._ASSISTANT_PREFIX}{ref_text}<|im_end|>\n"
            self._base_ref_token_ids = self.tokenizer(
                wrapped_ref,
                return_tensors="pt",
            )["input_ids"][0].to(torch.long)

    def _load_base_prompt(
        self,
        voice_prompt: str,
    ) -> tuple[
        torch.Tensor,
        torch.Tensor,
        torch.Tensor,
        torch.Tensor | None,
        torch.Tensor | None,
    ]:
        prompt_path = (self._base_prompt_root / voice_prompt / "prompt.pt").resolve()
        if not prompt_path.is_relative_to(self._base_prompt_root):
            raise ValueError("voice prompt path escapes the configured prompt root")
        try:
            modified_ns = prompt_path.stat().st_mtime_ns
        except FileNotFoundError as error:
            raise ValueError("cloned voice prompt was not found") from error
        cached = self._base_prompt_cache.get(voice_prompt)
        if cached is not None and cached[0] == modified_ns:
            self._base_prompt_cache.move_to_end(voice_prompt)
            return cached[1], cached[2], cached[3], cached[4], cached[5]
        raw = torch.load(prompt_path, map_location="cpu", weights_only=True)
        if not isinstance(raw, dict) or raw.get("schema") not in {
            "qwen3_tts_base_voice_clone_prompt_xvector_v1",
            "qwen3_tts_base_voice_clone_prompt_v2",
            "qwen3_tts_base_voice_clone_prompt_v3",
            "qwen3_tts_base_voice_clone_prompt_v4",
        }:
            raise ValueError("unsupported cloned voice prompt schema")
        schema = raw.get("schema")
        ref_text = raw.get("ref_text")
        speaker = raw.get("ref_spk_embedding")
        if not isinstance(speaker, torch.Tensor) or speaker.ndim != 1:
            raise ValueError("cloned voice prompt speaker embedding is invalid")
        if schema == "qwen3_tts_base_voice_clone_prompt_xvector_v1":
            if (
                raw.get("conditioning_contract_version") != 1
                or raw.get("x_vector_only_mode") is not True
                or raw.get("icl_mode") is not False
                or not speaker.is_floating_point()
                or speaker.numel() != self._speaker_embedding_size
                or not bool(torch.isfinite(speaker).all().item())
                or any(
                    raw.get(key) is not None
                    for key in (
                        "ref_text",
                        "reference_codec_embeddings",
                        "decoder_bootstrap_code",
                        "decoder_reference_code",
                    )
                )
            ):
                raise ValueError("x-vector voice prompt contains ICL fields")
            if self._base_ref_token_ids is None:
                raise ValueError("Qwen3-TTS Base lacks placeholder reference tokens")
            value = (
                modified_ns,
                self._base_ref_token_ids.contiguous(),
                speaker.to(torch.float32).contiguous(),
                torch.zeros((1, speaker.numel()), dtype=torch.bfloat16),
                None,
                None,
            )
            self._base_prompt_cache[voice_prompt] = value
            self._base_prompt_cache.move_to_end(voice_prompt)
            while len(self._base_prompt_cache) > 128:
                self._base_prompt_cache.popitem(last=False)
            return value[1], value[2], value[3], value[4], value[5]
        reference = raw.get("reference_codec_embeddings")
        reference_tokens = raw.get("decoder_bootstrap_code")
        reference_context = raw.get("decoder_reference_code")
        if not isinstance(ref_text, str) or not ref_text.strip():
            raise ValueError("cloned voice prompt requires reference text")
        if not isinstance(reference, torch.Tensor) or reference.ndim != 2 or reference.shape[0] < 1:
            raise ValueError("cloned voice prompt codec embeddings are invalid")
        if reference.shape[1] != speaker.numel():
            raise ValueError("cloned voice prompt hidden sizes do not match")
        if reference_tokens is not None and (
            not isinstance(reference_tokens, torch.Tensor)
            or reference_tokens.ndim != 2
            or reference_tokens.shape[0] < 1
            or reference_tokens.shape[0] > 8
            or reference_tokens.dtype != torch.long
        ):
            raise ValueError("cloned voice prompt decoder bootstrap is invalid")
        if reference_context is not None and (
            not isinstance(reference_context, torch.Tensor)
            or reference_context.ndim != 2
            or reference_context.shape[0] < 1
            or reference_context.shape[0] > 512
            or reference_context.shape[1] != 16
            or reference_context.dtype != torch.long
        ):
            raise ValueError("cloned voice prompt decoder reference context is invalid")
        if reference_tokens is not None and reference_context is not None:
            raise ValueError("cloned voice prompt has conflicting decoder contexts")
        if raw.get("schema") == "qwen3_tts_base_voice_clone_prompt_v4" and reference_context is None:
            raise ValueError("v4 cloned voice prompt requires decoder reference context")
        wrapped_ref = f"{self._ASSISTANT_PREFIX}{ref_text}<|im_end|>\n"
        with self._tokenizer_lock:
            ref_ids = self.tokenizer(wrapped_ref, return_tensors="pt")["input_ids"][0].to(torch.long)
        value = (
            modified_ns,
            ref_ids.contiguous(),
            speaker.to(torch.float32).contiguous(),
            reference.to(torch.bfloat16).contiguous(),
            reference_tokens.contiguous() if reference_tokens is not None else None,
            reference_context.contiguous() if reference_context is not None else None,
        )
        self._base_prompt_cache[voice_prompt] = value
        self._base_prompt_cache.move_to_end(voice_prompt)
        while len(self._base_prompt_cache) > 128:
            self._base_prompt_cache.popitem(last=False)
        return value[1], value[2], value[3], value[4], value[5]

    def __getstate__(self) -> dict[str, object]:
        state = dict(self.__dict__)
        for name in ("_tokenizer_lock", "_pool_init_lock", "_pool"):
            state.pop(name, None)
        return state

    def __setstate__(self, state: dict[str, object]) -> None:
        self.__dict__.update(state)
        self._tokenizer_lock = threading.RLock()
        self._pool_init_lock = threading.Lock()
        self._pool = None

    def prepare_streaming_tokenizer_pool(self) -> None:
        if self._pool is not None:
            return
        with self._pool_init_lock:
            if self._pool is not None:
                return
            pool: queue.LifoQueue[Qwen2TokenizerFast] = queue.LifoQueue(maxsize=self._tokenizer_pool_size)
            with self._tokenizer_lock:
                for _ in range(self._tokenizer_pool_size):
                    pool.put(copy.deepcopy(self.tokenizer))
            self._pool = pool

    @contextmanager
    def _tokenizer_lease(self) -> Iterator[Qwen2TokenizerFast]:
        self.prepare_streaming_tokenizer_pool()
        assert self._pool is not None
        tokenizer = self._pool.get()
        try:
            yield tokenizer
        finally:
            self._pool.put(tokenizer)

    @property
    def streaming_tokenizer_concurrency(self) -> int:
        return self._tokenizer_pool_size

    def prepare(self, request: SynthesisRequest) -> EncodedText:
        ref_token_ids = self._base_ref_token_ids
        ref_speaker_embedding = None
        ref_codec_embeddings = None
        ref_codec_tokens = None
        ref_codec_context = None
        if self.tts_model_type == "base":
            if request.voice != "clone":
                raise ValueError("Qwen3-TTS Base requires voice='clone'")
            if request.instruct:
                raise ValueError("Qwen3-TTS Base voice cloning does not accept instructions")
            if request.voice_prompt:
                (
                    ref_token_ids,
                    ref_speaker_embedding,
                    ref_codec_embeddings,
                    ref_codec_tokens,
                    ref_codec_context,
                ) = self._load_base_prompt(request.voice_prompt)
        assistant_text = f"{self._ASSISTANT_PREFIX}{request.text}{self._ASSISTANT_SUFFIX}"
        with self._tokenizer_lock:
            text_ids = self.tokenizer(assistant_text, return_tensors="pt")["input_ids"][0].to(torch.long)
            if request.instruct:
                instruct_text = f"<|im_start|>user\n{request.instruct}<|im_end|>\n"
                instruct_ids = self.tokenizer(instruct_text, return_tensors="pt")["input_ids"][0].to(torch.long)
            else:
                instruct_ids = torch.empty(0, dtype=torch.long)
        return EncodedText(
            request=request,
            text_token_ids=text_ids,
            instruct_token_ids=instruct_ids,
            ref_token_ids=ref_token_ids,
            ref_speaker_embedding=ref_speaker_embedding,
            ref_codec_embeddings=ref_codec_embeddings,
            ref_codec_tokens=ref_codec_tokens,
            ref_codec_context=ref_codec_context,
        )

    def prepare_live(
        self,
        request: SynthesisRequest,
        *,
        token_ids: tuple[int, ...],
        wrapped_ids: tuple[int, ...],
    ) -> EncodedText:
        if self.tts_model_type == "base":
            raise ValueError("Qwen3-TTS Base POC does not support live text append")
        if not isinstance(request, SynthesisRequest):
            raise TypeError("live text preparation requires a SynthesisRequest")
        for name, values in (("target", token_ids), ("wrapped", wrapped_ids)):
            if not isinstance(values, tuple) or any(
                type(token_id) is not int or token_id < 0 for token_id in values
            ):
                raise ValueError(f"live {name} token IDs must be non-negative integers")
        prefix, suffix = self._wrapper_ids()
        if (
            len(wrapped_ids) < 3 + len(suffix)
            or tuple(wrapped_ids[:3]) != tuple(prefix[:3])
            or tuple(wrapped_ids[-len(suffix) :]) != tuple(suffix)
        ):
            raise ValueError("live wrapped token IDs do not preserve the assistant wrapper")
        if tuple(wrapped_ids[3 : -len(suffix)]) != token_ids:
            raise ValueError("live target token IDs do not match the wrapped prompt")
        if request.instruct:
            instruct_text = f"<|im_start|>user\n{request.instruct}<|im_end|>\n"
            with self._tokenizer_lock:
                instruct_ids = self.tokenizer(instruct_text, return_tensors="pt")["input_ids"][0].to(torch.long)
        else:
            instruct_ids = torch.empty(0, dtype=torch.long)
        return EncodedText(
            request=request,
            text_token_ids=torch.tensor(wrapped_ids, dtype=torch.long),
            instruct_token_ids=instruct_ids,
        )

    def _wrapper_ids(self) -> tuple[list[int], list[int]]:
        return list(self._assistant_prefix_ids), list(self._assistant_suffix_ids)

    def _tokenize_wrapped_with(self, tokenizer: Qwen2TokenizerFast, text: str) -> list[int]:
        prefix, suffix = self._wrapper_ids()
        wrapped = list(
            tokenizer(
                f"{self._ASSISTANT_PREFIX}{text}{self._ASSISTANT_SUFFIX}",
                add_special_tokens=False,
            )["input_ids"]
        )
        if len(wrapped) < 2 + len(suffix) or wrapped[:2] != prefix[:2] or wrapped[-len(suffix) :] != suffix:
            raise RuntimeError("Qwen3-TTS prompt wrapper tokenization changed")
        return wrapped

    def _validate_target_control_tokens(self, text: str) -> int:
        unstable_suffix_start = len(text)
        for token in self._forbidden_control_tokens:
            if token in text:
                raise StreamingTextControlTokenError(
                    f"Target text must not contain reserved tokenizer control token {token!r}"
                )
            for prefix_length in range(min(len(text), len(token) - 1), 0, -1):
                if text.endswith(token[:prefix_length]):
                    unstable_suffix_start = min(unstable_suffix_start, len(text) - prefix_length)
                    break
        return unstable_suffix_start

    def tokenize_streaming_fragment(
        self,
        text: str,
        *,
        is_initial: bool,
        is_final: bool,
    ) -> FragmentTokenization:
        if not isinstance(text, str):
            raise TypeError("streaming text must be a string")
        _strict_bool("is_initial", is_initial)
        _strict_bool("is_final", is_final)
        if not text:
            return FragmentTokenization((), (), 0)
        suffix_length = len(self._assistant_suffix_ids)
        with self._tokenizer_lease() as tokenizer:
            stable_special_end = self._validate_target_control_tokens(text)
            if is_initial:
                wrapped = self._tokenize_wrapped_with(tokenizer, text)
                token_ids = wrapped[3:-suffix_length]
            else:
                wrapped = []
                token_ids = list(tokenizer(text, add_special_tokens=False)["input_ids"])
            if is_final:
                return FragmentTokenization(tuple(token_ids), tuple(wrapped), len(text))
            pieces = tokenizer.backend_tokenizer.pre_tokenizer.pre_tokenize_str(text)
            boundaries = [int(piece[1][1]) for piece in pieces[:-1] if 0 < int(piece[1][1]) <= stable_special_end]
            for boundary in reversed(boundaries):
                candidate = text[:boundary]
                if is_initial:
                    candidate_wrapped = self._tokenize_wrapped_with(tokenizer, candidate)
                    candidate_ids = candidate_wrapped[3:-suffix_length]
                    prefix_stable = candidate_wrapped[:3] == wrapped[:3]
                else:
                    candidate_wrapped = []
                    candidate_ids = list(tokenizer(candidate, add_special_tokens=False)["input_ids"])
                    prefix_stable = True
                if candidate_ids and prefix_stable and token_ids[: len(candidate_ids)] == candidate_ids:
                    return FragmentTokenization(
                        tuple(candidate_ids),
                        tuple(candidate_wrapped),
                        boundary,
                    )
        return FragmentTokenization((), (), 0)

    def tokenize_streaming(self, text: str) -> list[int]:
        if not isinstance(text, str):
            raise TypeError("streaming text must be a string")
        with self._tokenizer_lock:
            wrapped = self._tokenize_wrapped_with(self.tokenizer, text)
        return wrapped[3 : -len(self._assistant_suffix_ids)]

    def tokenize_streaming_state(self, text: str) -> StreamingTextTokenization:
        if not isinstance(text, str):
            raise TypeError("streaming text must be a string")
        with self._tokenizer_lock:
            wrapped = self._tokenize_wrapped_with(self.tokenizer, text)
            suffix_length = len(self._assistant_suffix_ids)
            token_ids = wrapped[3:-suffix_length]
            pieces = self.tokenizer.backend_tokenizer.pre_tokenizer.pre_tokenize_str(text)
            boundaries = [int(piece[1][1]) for piece in pieces[:-1]]
            stable_character_count = 0
            stable_wrapped = self._tokenize_wrapped_with(self.tokenizer, "")
            stable_token_ids: list[int] = []
            for boundary in reversed(boundaries):
                candidate_wrapped = self._tokenize_wrapped_with(self.tokenizer, text[:boundary])
                candidate_ids = candidate_wrapped[3:-suffix_length]
                if token_ids[: len(candidate_ids)] == candidate_ids:
                    stable_character_count = boundary
                    stable_wrapped = candidate_wrapped
                    stable_token_ids = candidate_ids
                    break
        return StreamingTextTokenization(
            token_ids=tuple(token_ids),
            stable_token_ids=tuple(stable_token_ids),
            wrapped_ids=tuple(wrapped),
            stable_wrapped_ids=tuple(stable_wrapped),
            stable_character_count=stable_character_count,
        )


__all__ = [
    "DEFAULT_STREAMING_TOKENIZER_POOL_SIZE",
    "EncodedText",
    "Qwen3TTSTextDomain",
]
