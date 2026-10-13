"""Opt-in hidden-state capture for an isolated Nari timestamp experiment.

Loaded automatically by Python when this directory is on PYTHONPATH.  The
production Nari source tree is not modified.  Nothing happens unless
NARI_TIMESTAMP_CAPTURE_DIR is set.
"""

from __future__ import annotations

import os
from pathlib import Path
import threading


_capture_root = os.environ.get("NARI_TIMESTAMP_CAPTURE_DIR", "").strip()

if _capture_root:
    import torch

    from nari_qwen3_tts.engine.pipeline import SynthesisPipeline

    _root = Path(_capture_root)
    _root.mkdir(parents=True, exist_ok=True)
    _lock = threading.Lock()
    _frames: dict[str, list[torch.Tensor]] = {}
    _tokens: dict[str, list[int]] = {}
    _original = SynthesisPipeline._talker_completion

    def _capturing_talker_completion(self, batch, output, states, *, decode):
        envelope = _original(self, batch, output, states, decode=decode)
        with _lock:
            for row, state in enumerate(states):
                request_id = state.request_id
                terminal = bool(envelope.talker_terminal[row])
                # The terminal Talker state predicts EOS and never enters the
                # Code Predictor, so it has no corresponding audible codec frame.
                if not terminal:
                    _frames.setdefault(request_id, []).append(
                        output.result.last_hidden[row].detach().to(
                            device="cpu", dtype=torch.float16
                        ).clone()
                    )
                    _tokens.setdefault(request_id, []).append(
                        int(output.result.tokens[row].detach().cpu().item())
                    )
                    continue

                admitted = state.input
                captured = _frames.pop(request_id, [])
                sampled = _tokens.pop(request_id, [])
                if admitted is None or not captured:
                    continue

                prompt_ids = admitted.talker_input.text_token_ids.detach().reshape(-1)
                unique_ids = torch.unique(prompt_ids).to(dtype=torch.long)
                embedding_cache = (
                    self.executor.talker.model.get_projected_text_embedding_cache()
                )
                embedding_values = embedding_cache.index_select(
                    0, unique_ids.to(device=embedding_cache.device)
                ).detach().to(device="cpu", dtype=torch.float16)
                payload = {
                    "request_id": request_id,
                    "text": admitted.request.text,
                    "hidden": torch.stack(captured),
                    "sampled_codec0": torch.tensor(sampled, dtype=torch.long),
                    "prompt_text_ids": prompt_ids.to(device="cpu", dtype=torch.long),
                    "embedding_token_ids": unique_ids.to(device="cpu"),
                    "embedding_values": embedding_values,
                    "samples_per_frame": int(self.model_config.samples_per_frame),
                    "sample_rate": 24_000,
                }
                final_path = _root / f"{request_id}.pt"
                temporary_path = final_path.with_suffix(".tmp")
                torch.save(payload, temporary_path)
                os.replace(temporary_path, final_path)
        return envelope

    SynthesisPipeline._talker_completion = _capturing_talker_completion

