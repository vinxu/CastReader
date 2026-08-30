#!/usr/bin/env python3
"""Build reusable speaker-only Nari/Qwen3-TTS Base prompts.

The CLI remains useful for provisioning and recovery. Production workers reuse
``VoicePromptBuilder`` in-process so every voice creation does not reload the
same 0.6B model and spend tens of seconds in cold-start work.
"""

from __future__ import annotations

import argparse
from pathlib import Path

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

    @torch.inference_mode()
    def build(
        self,
        reference_audio: str,
        reference_text: str | None,
        *,
        reference_speech_duration_s: float | None = None,
        semantic_attested: bool = False,
    ) -> dict[str, object]:
        prompts = self.model.create_voice_clone_prompt(
            ref_audio=reference_audio,
            # Speaker-only cloning intentionally accepts arbitrary speech.
            # The suggested recording script is UX guidance, not model input.
            ref_text=None,
            x_vector_only_mode=True,
        )
        if (
            len(prompts) != 1
            or prompts[0].ref_code is not None
            or not prompts[0].x_vector_only_mode
            or prompts[0].icl_mode
        ):
            raise RuntimeError("Qwen3-TTS did not create one x-vector prompt")
        prompt = prompts[0]
        speaker = prompt.ref_spk_embedding.detach().cpu().to(torch.float32)
        if (
            speaker.ndim != 1
            or speaker.numel() != 1024
            or not bool(torch.isfinite(speaker).all().item())
        ):
            raise RuntimeError("Qwen3-TTS returned an invalid speaker embedding")
        compiled: dict[str, object] = {
            "schema": "qwen3_tts_base_voice_clone_prompt_xvector_v1",
            "ref_spk_embedding": speaker.contiguous(),
            "x_vector_only_mode": True,
            "icl_mode": False,
            "conditioning_contract_version": 1,
        }
        if reference_speech_duration_s is not None:
            compiled["reference_speech_duration_s"] = float(
                reference_speech_duration_s
            )
        return compiled

    def save(
        self,
        reference_audio: str,
        reference_text: str | None,
        output: Path,
        *,
        reference_speech_duration_s: float | None = None,
        semantic_attested: bool = False,
    ) -> None:
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(f"{output.name}.tmp")
        torch.save(
            self.build(
                reference_audio,
                reference_text,
                reference_speech_duration_s=reference_speech_duration_s,
                semantic_attested=semantic_attested,
            ),
            temporary,
        )
        temporary.replace(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--reference-audio", required=True)
    parser.add_argument(
        "--reference-text",
        default="",
        help="Optional recording note; speaker-only prompts do not condition on it",
    )
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    VoicePromptBuilder(args.model).save(
        args.reference_audio,
        args.reference_text,
        Path(args.output),
    )


if __name__ == "__main__":
    main()
