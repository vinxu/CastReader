from __future__ import annotations

import unittest
from collections import OrderedDict
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

import torch

from nari_qwen3_tts.contract.request import SynthesisRequest
from nari_qwen3_tts.model.input_layout import (
    BaseVoiceCloneConditioning,
    build_batched_base_talker_token_layout,
)
from nari_qwen3_tts.model.text import Qwen3TTSTextDomain


class NariXVectorLayoutTests(unittest.TestCase):
    @staticmethod
    def _config():
        talker = SimpleNamespace(
            codec_think_id=10,
            codec_think_bos_id=11,
            codec_language_id={"english": 12},
            codec_think_eos_id=13,
            codec_nothink_id=14,
            codec_pad_id=15,
            codec_bos_id=16,
        )
        return SimpleNamespace(
            talker_config=talker,
            tts_bos_token_id=20,
            tts_eos_token_id=21,
            tts_pad_token_id=22,
        )

    def test_xvector_request_requires_one_dynamic_clone_prompt(self) -> None:
        request = SynthesisRequest(
            text="Fast speech.",
            voice="clone",
            voice_prompt="vc_fast",
            voice_clone_mode="x-vector",
            language="english",
        )

        self.assertEqual(request.voice_clone_mode, "x_vector")
        with self.assertRaises(ValueError):
            SynthesisRequest(
                text="Fast speech.",
                voice="clone",
                voice_clone_mode="x_vector",
                language="english",
            )

    def test_non_streaming_xvector_layout_omits_reference_audio_and_text(self) -> None:
        text = torch.arange(100, 112, dtype=torch.long)
        reference_text = torch.arange(200, 210, dtype=torch.long)
        reference_embeddings = torch.full((7, 4), 9.0)
        conditioning = BaseVoiceCloneConditioning(
            speaker_embedding=torch.tensor([1.0, 2.0, 3.0, 4.0]),
            reference_codec_embeddings=reference_embeddings,
            x_vector_only=True,
        )

        layout = build_batched_base_talker_token_layout(
            self._config(),
            [text],
            [reference_text],
            languages=["english"],
            speakers=["clone"],
            non_streaming_modes=[True],
            conditionings=[conditioning],
        )

        # role(3) + codec/speaker prefix(6) + target/eos(5) + codec bos(1)
        self.assertEqual(layout.seq_lens, [15])
        self.assertEqual(layout.trailing_text_ids[0].tolist(), [22])
        self.assertFalse(
            torch.any(torch.all(layout.extra_embeddings == 9.0, dim=1)).item()
        )
        self.assertEqual(
            layout.extra_embeddings[7].tolist(),
            conditioning.speaker_embedding.tolist(),
        )

    def test_xvector_asset_loader_requires_only_speaker_embedding(self) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            voice = root / "vc_fast"
            voice.mkdir()
            torch.save(
                {
                    "schema": "qwen3_tts_base_voice_clone_prompt_xvector_v1",
                    "ref_spk_embedding": torch.arange(4, dtype=torch.float32),
                    "x_vector_only_mode": True,
                    "icl_mode": False,
                    "conditioning_contract_version": 1,
                },
                voice / "prompt.pt",
            )
            domain = object.__new__(Qwen3TTSTextDomain)
            domain._base_prompt_root = root
            domain._base_prompt_cache = OrderedDict()
            domain._base_ref_token_ids = torch.tensor([1, 2, 3])
            domain._speaker_embedding_size = 4

            ref_ids, speaker, reference, prefix, context = domain._load_base_prompt(
                "vc_fast"
            )

        self.assertEqual(ref_ids.tolist(), [1, 2, 3])
        self.assertEqual(speaker.tolist(), [0.0, 1.0, 2.0, 3.0])
        self.assertEqual(tuple(reference.shape), (1, 4))
        self.assertFalse(torch.any(reference).item())
        self.assertIsNone(prefix)
        self.assertIsNone(context)

    def test_xvector_asset_loader_rejects_corrupt_contracts(self) -> None:
        base = {
            "schema": "qwen3_tts_base_voice_clone_prompt_xvector_v1",
            "ref_spk_embedding": torch.arange(4, dtype=torch.float32),
            "x_vector_only_mode": True,
            "icl_mode": False,
            "conditioning_contract_version": 1,
        }
        invalid_variants = {
            "wrong contract version": {"conditioning_contract_version": 2},
            "wrong embedding size": {
                "ref_spk_embedding": torch.arange(3, dtype=torch.float32)
            },
            "integer embedding": {
                "ref_spk_embedding": torch.arange(4, dtype=torch.int64)
            },
            "non-finite embedding": {
                "ref_spk_embedding": torch.tensor(
                    [0.0, 1.0, float("nan"), float("inf")]
                )
            },
        }

        for label, changes in invalid_variants.items():
            with self.subTest(label=label), TemporaryDirectory() as directory:
                root = Path(directory)
                voice = root / "vc_invalid"
                voice.mkdir()
                prompt = dict(base)
                prompt.update(changes)
                torch.save(prompt, voice / "prompt.pt")
                domain = object.__new__(Qwen3TTSTextDomain)
                domain._base_prompt_root = root
                domain._base_prompt_cache = OrderedDict()
                domain._base_ref_token_ids = torch.tensor([1, 2, 3])
                domain._speaker_embedding_size = 4

                with self.assertRaises(ValueError):
                    domain._load_base_prompt("vc_invalid")


if __name__ == "__main__":
    unittest.main()
