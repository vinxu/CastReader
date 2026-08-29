#!/usr/bin/env python3
"""Build reusable Nari/Qwen3-TTS Base ICL prompts.

The CLI remains useful for provisioning and recovery. Production workers reuse
``VoicePromptBuilder`` in-process so every voice creation does not reload the
same 0.6B model and spend tens of seconds in cold-start work.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
from qwen_tts import Qwen3TTSModel

class VoicePromptBuilder:
    """One warm prompt encoder shared by the worker's single GPU scheduler."""

    def __init__(self, model_path: str) -> None:
        self.model = Qwen3TTSModel.from_pretrained(
            model_path,
            device_map="cuda:0",
            dtype=torch.bfloat16,
            attn_implementation="sdpa",
            local_files_only=True,
        )
        silence = np.zeros(round(0.25 * 24_000), dtype=np.float32)
        encoded_silence = self.model.model.speech_tokenizer.encode(
            silence,
            sr=24_000,
        )
        bootstrap = encoded_silence.audio_codes[0].detach().cpu().to(torch.long)
        if bootstrap.ndim != 2 or not 2 <= bootstrap.shape[0] <= 8:
            raise RuntimeError("Qwen3-TTS silence bootstrap has an unexpected shape")
        self.decoder_bootstrap_code = bootstrap.contiguous()

    @torch.inference_mode()
    def build(
        self,
        reference_audio: str,
        reference_text: str,
        *,
        reference_speech_duration_s: float | None = None,
    ) -> dict[str, object]:
        prompts = self.model.create_voice_clone_prompt(
            ref_audio=reference_audio,
            ref_text=reference_text,
            x_vector_only_mode=False,
        )
        if len(prompts) != 1 or prompts[0].ref_code is None:
            raise RuntimeError("Qwen3-TTS did not create one full ICL prompt")
        prompt = prompts[0]
        ref_code = prompt.ref_code.to(
            self.model.model.talker.device,
            dtype=torch.long,
        )
        talker = self.model.model.talker
        codec_parts = [talker.get_input_embeddings()(ref_code[:, :1])]
        codec_parts.extend(
            embedding(ref_code[:, index : index + 1])
            for index, embedding in enumerate(
                talker.code_predictor.get_input_embeddings(), start=1
            )
        )
        reference_codec_embeddings = torch.cat(codec_parts, dim=1).sum(1)
        compiled: dict[str, object] = {
            "schema": "qwen3_tts_base_voice_clone_prompt_v4",
            "ref_spk_embedding": prompt.ref_spk_embedding.detach()
            .cpu()
            .to(torch.float32),
            # Preserve the small discrete reference (normally 40-375 frames,
            # 16 codebooks) so Nari can cache the decoder's exact causal state
            # at the reference/generated boundary. This matches the official
            # ref_code + generated_code decode without retaining reference PCM
            # or decoding the full reference for every paragraph.
            "decoder_reference_code": ref_code.detach()
            .cpu()
            .contiguous(),
            "reference_codec_embeddings": reference_codec_embeddings.detach()
            .cpu()
            .to(torch.bfloat16),
            "ref_text": prompt.ref_text,
            "x_vector_only_mode": False,
            "icl_mode": True,
        }
        if reference_speech_duration_s is not None:
            compiled["reference_contract_version"] = 1
            compiled["reference_speech_duration_s"] = float(
                reference_speech_duration_s
            )
        return compiled

    def save(
        self,
        reference_audio: str,
        reference_text: str,
        output: Path,
        *,
        reference_speech_duration_s: float | None = None,
    ) -> None:
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(f"{output.name}.tmp")
        torch.save(
            self.build(
                reference_audio,
                reference_text,
                reference_speech_duration_s=reference_speech_duration_s,
            ),
            temporary,
        )
        temporary.replace(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--reference-audio", required=True)
    parser.add_argument("--reference-text", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    VoicePromptBuilder(args.model).save(
        args.reference_audio,
        args.reference_text,
        Path(args.output),
    )


if __name__ == "__main__":
    main()
