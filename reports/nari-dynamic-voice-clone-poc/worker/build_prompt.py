#!/usr/bin/env python3
"""Build reusable speaker-only Nari/Qwen3-TTS Base prompts.

The CLI remains useful for provisioning and recovery. Production workers reuse
``VoicePromptBuilder`` in-process so every voice creation does not reload the
same 0.6B model and spend tens of seconds in cold-start work.
"""

from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path

import torch
from qwen_tts import Qwen3TTSModel

XVECTOR_PROMPT_SCHEMA = "qwen3_tts_base_voice_clone_prompt_xvector_v1"
XVECTOR_CONDITIONING_CONTRACT_VERSION = 1
XVECTOR_SPEAKER_EMBEDDING_SIZE = 1024


def compile_xvector_prompt(
    speaker_embedding: torch.Tensor,
    *,
    reference_speech_duration_s: float | None = None,
) -> dict[str, object]:
    """Build and validate the only prompt shape production may publish."""

    speaker = speaker_embedding.detach().cpu().to(torch.float32)
    if (
        speaker.ndim != 1
        or speaker.numel() != XVECTOR_SPEAKER_EMBEDDING_SIZE
        or not bool(torch.isfinite(speaker).all().item())
    ):
        raise RuntimeError("Qwen3-TTS returned an invalid speaker embedding")
    compiled: dict[str, object] = {
        "schema": XVECTOR_PROMPT_SCHEMA,
        "ref_spk_embedding": speaker.contiguous(),
        "x_vector_only_mode": True,
        "icl_mode": False,
        "conditioning_contract_version": XVECTOR_CONDITIONING_CONTRACT_VERSION,
    }
    if reference_speech_duration_s is not None:
        compiled["reference_speech_duration_s"] = float(
            reference_speech_duration_s
        )
    validate_xvector_prompt_schema(compiled)
    return compiled


def validate_xvector_prompt_schema(prompt: object) -> str:
    """Reject any prompt that could reintroduce reference audio or text."""

    if not isinstance(prompt, dict):
        raise RuntimeError("x-vector prompt must be a dictionary")
    if prompt.get("schema") != XVECTOR_PROMPT_SCHEMA:
        raise RuntimeError("unexpected x-vector prompt schema")
    if prompt.get("x_vector_only_mode") is not True:
        raise RuntimeError("x-vector-only mode is required")
    if prompt.get("icl_mode") is not False:
        raise RuntimeError("ICL mode must be disabled")
    if (
        prompt.get("conditioning_contract_version")
        != XVECTOR_CONDITIONING_CONTRACT_VERSION
    ):
        raise RuntimeError("unexpected conditioning contract version")
    forbidden = {"ref_code", "ref_text", "reference_audio", "reference_text"}
    if forbidden.intersection(prompt):
        raise RuntimeError("speaker-only prompt contains reference content")
    speaker = prompt.get("ref_spk_embedding")
    if (
        not isinstance(speaker, torch.Tensor)
        or speaker.dtype != torch.float32
        or speaker.ndim != 1
        or speaker.numel() != XVECTOR_SPEAKER_EMBEDDING_SIZE
        or not bool(torch.isfinite(speaker).all().item())
    ):
        raise RuntimeError("x-vector prompt contains an invalid speaker embedding")
    return XVECTOR_PROMPT_SCHEMA


def dry_run_xvector_prompt_schema() -> dict[str, object]:
    """Round-trip a schema probe in an isolated temporary directory.

    The activation gate calls this before enabling writes. It deliberately does
    not accept a voice root or output path, so it cannot create or replace a
    production voice.
    """

    probe = compile_xvector_prompt(
        torch.zeros(XVECTOR_SPEAKER_EMBEDDING_SIZE, dtype=torch.float32)
    )
    with tempfile.TemporaryDirectory(prefix="castreader-xvector-schema-") as directory:
        artifact = Path(directory) / "prompt.pt"
        torch.save(probe, artifact)
        loaded = torch.load(artifact, map_location="cpu", weights_only=True)
        schema = validate_xvector_prompt_schema(loaded)
    return {
        "schema": schema,
        "embedding_size": XVECTOR_SPEAKER_EMBEDDING_SIZE,
        "storage": "temporary-only",
    }


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
        return compile_xvector_prompt(
            prompt.ref_spk_embedding,
            reference_speech_duration_s=reference_speech_duration_s,
        )

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
    parser.add_argument("--dry-run-xvector-schema", action="store_true")
    parser.add_argument("--model")
    parser.add_argument("--reference-audio")
    parser.add_argument(
        "--reference-text",
        default="",
        help="Optional recording note; speaker-only prompts do not condition on it",
    )
    parser.add_argument("--output")
    args = parser.parse_args()

    if args.dry_run_xvector_schema:
        print(json.dumps(dry_run_xvector_prompt_schema(), sort_keys=True))
        return
    if not args.model or not args.reference_audio or not args.output:
        parser.error("--model, --reference-audio and --output are required")

    VoicePromptBuilder(args.model).save(
        args.reference_audio,
        args.reference_text,
        Path(args.output),
    )


if __name__ == "__main__":
    main()
