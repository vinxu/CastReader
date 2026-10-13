from __future__ import annotations

import unittest
from collections import OrderedDict
from types import SimpleNamespace

import torch

from nari_qwen3_tts.engine.codec_readiness import next_codec_readiness
from nari_qwen3_tts.engine.admission import (
    _codec_decoder_context,
    _codec_decoder_prefix,
)
from nari_qwen3_tts.engine.state import CodecLane, CodecPhase
from nari_qwen3_tts.contract.stage import CodecExecutionMode
from nari_qwen3_tts.executor.codec import CodecExecutor


class _FakeIncrementalDecoder:
    samples_per_frame = 1
    retained_context = 71

    def __init__(self) -> None:
        self.calls = 0

    def __call__(
        self,
        codes: torch.Tensor,
        states: list,
        **_kwargs,
    ) -> torch.Tensor:
        self.calls += 1
        fresh_frames = int(codes.shape[2])
        for state in states:
            state.frame_position += fresh_frames
            state.transformer_context_length = min(
                self.retained_context,
                state.transformer_context_length + fresh_frames,
            )
            retained = self.retained_context
            state.transformer_keys[0] = torch.zeros((1, retained, 1))
            state.transformer_values[0] = torch.zeros((1, retained, 1))
            state.conv_histories["conv"] = torch.zeros((1, 1))
            state.transconv_overlaps["transconv"] = torch.zeros((1, 1))
        return torch.zeros((codes.shape[0], 1, fresh_frames))


class ReferenceCodecContextTests(unittest.TestCase):
    def test_decoder_prefix_is_available_to_incremental_decode(self) -> None:
        prefix = torch.zeros((4, 16), dtype=torch.long)
        plan = SimpleNamespace(codec_decoder_prefixes=(prefix,))

        warmup = SimpleNamespace(defer_codec_until_terminal=False)
        clone = SimpleNamespace(defer_codec_until_terminal=True)

        self.assertIs(_codec_decoder_prefix(warmup, plan), prefix)
        self.assertIs(_codec_decoder_prefix(clone, plan), prefix)

    def test_full_decoder_context_is_available_to_incremental_decode(self) -> None:
        context = torch.zeros((71, 16), dtype=torch.long)
        plan = SimpleNamespace(codec_decoder_contexts=(context,))
        request = SimpleNamespace(defer_codec_until_terminal=False)

        self.assertIs(_codec_decoder_context(request, plan), context)

    def test_full_reference_state_is_built_once_and_cached(self) -> None:
        decoder = _FakeIncrementalDecoder()
        executor = object.__new__(CodecExecutor)
        executor.num_code_groups = 16
        executor.device = torch.device("cpu")
        executor.incremental_decoder = decoder
        executor.retained_context = decoder.retained_context
        executor._reference_state_cache = OrderedDict()
        executor._reference_state_cache_size = 2
        reference = torch.arange(80 * 16, dtype=torch.long).reshape(80, 16)

        first = executor.reference_state(reference)
        calls_after_first = decoder.calls
        second = executor.reference_state(reference.clone())

        self.assertIs(first, second)
        self.assertEqual(calls_after_first, 7)
        self.assertEqual(decoder.calls, calls_after_first)
        self.assertEqual(first.frame_position, 80)
        self.assertEqual(first.transformer_context_length, 71)

    def test_incremental_first_chunk_prepends_and_hides_silence_bootstrap(self) -> None:
        bootstrap = tuple(torch.zeros(16, dtype=torch.long) for _ in range(4))
        generated = tuple(torch.ones(16, dtype=torch.long) for _ in range(4))
        lane = CodecLane(
            history_frames=bootstrap + generated,
            buffered_frames=generated,
            decoder_prefix_frames=len(bootstrap),
            context_frames_consumed=len(bootstrap),
        )

        readiness = next_codec_readiness(lane)

        assert readiness is not None and readiness.compatibility is not None
        self.assertEqual(readiness.compatibility.mode, CodecExecutionMode.COLD)
        self.assertEqual(readiness.compatibility.input_frames, 6)
        self.assertEqual(readiness.compatibility.pcm_start_frame, 4)
        self.assertEqual(readiness.compatibility.visible_frames, 2)
        self.assertEqual(readiness.compatibility.producer_frames, 2)

    def test_terminal_decode_prepends_reference_and_hides_it_from_pcm(self) -> None:
        reference = tuple(torch.full((16,), index, dtype=torch.long) for index in range(3))
        generated = tuple(torch.full((16,), index + 10, dtype=torch.long) for index in range(4))
        lane = CodecLane(
            defer_until_terminal=True,
            producer_done=True,
            history_frames=reference + generated,
            buffered_frames=generated,
            decoder_prefix_frames=len(reference),
        )

        readiness = next_codec_readiness(lane)

        self.assertIsNotNone(readiness)
        assert readiness is not None
        self.assertEqual(readiness.phase, CodecPhase.READY)
        compatibility = readiness.compatibility
        self.assertIsNotNone(compatibility)
        assert compatibility is not None
        self.assertEqual(compatibility.mode, CodecExecutionMode.TERMINAL_WHOLE_SEQUENCE)
        self.assertEqual(compatibility.model_frames, 7)
        self.assertEqual(compatibility.input_frames, 7)
        self.assertEqual(compatibility.pcm_start_frame, 3)
        self.assertEqual(compatibility.visible_frames, 4)
        self.assertEqual(compatibility.producer_frames, 4)

    def test_generated_bootstrap_suppression_is_applied_after_reference(self) -> None:
        reference = tuple(torch.zeros(16, dtype=torch.long) for _ in range(5))
        generated = tuple(torch.ones(16, dtype=torch.long) for _ in range(6))
        lane = CodecLane(
            defer_until_terminal=True,
            producer_done=True,
            suppress_first_silent_frame=True,
            history_frames=reference + generated,
            buffered_frames=generated,
            decoder_prefix_frames=len(reference),
        )

        readiness = next_codec_readiness(lane)

        assert readiness is not None and readiness.compatibility is not None
        self.assertEqual(readiness.compatibility.pcm_start_frame, 6)
        self.assertEqual(readiness.compatibility.visible_frames, 5)
        self.assertEqual(readiness.compatibility.producer_frames, 6)

    def test_legacy_prompt_without_reference_tokens_keeps_old_contract(self) -> None:
        generated = tuple(torch.ones(16, dtype=torch.long) for _ in range(4))
        lane = CodecLane(
            defer_until_terminal=True,
            producer_done=True,
            history_frames=generated,
            buffered_frames=generated,
        )

        readiness = next_codec_readiness(lane)

        assert readiness is not None and readiness.compatibility is not None
        self.assertEqual(readiness.compatibility.model_frames, 4)
        self.assertEqual(readiness.compatibility.pcm_start_frame, 0)
        self.assertEqual(readiness.compatibility.visible_frames, 4)


if __name__ == "__main__":
    unittest.main()
