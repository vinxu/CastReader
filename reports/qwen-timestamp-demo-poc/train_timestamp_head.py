#!/usr/bin/env python3
"""Train a tiny text-conditioned CTC timestamp head from transcript only."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
from pathlib import Path
import re

import torch
from torch import nn
from torch.nn import functional as F
from transformers import Qwen2TokenizerFast


WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)?")


@dataclass
class Sample:
    sample_id: str
    split: str
    text: str
    words: list[str]
    hidden: torch.Tensor
    word_embeddings: torch.Tensor
    frame_seconds: float
    audio_seconds: float


class TimestampHead(nn.Module):
    def __init__(self, hidden_size: int, width: int = 96) -> None:
        super().__init__()
        self.audio = nn.Sequential(
            nn.LayerNorm(hidden_size), nn.Linear(hidden_size, width), nn.GELU(), nn.Linear(width, width)
        )
        self.text = nn.Sequential(
            nn.LayerNorm(hidden_size), nn.Linear(hidden_size, width), nn.GELU(), nn.Linear(width, width)
        )
        self.blank = nn.Linear(width, 1)
        self.scale = nn.Parameter(torch.tensor(math.log(10.0)))

    def forward(self, hidden: torch.Tensor, words: torch.Tensor) -> torch.Tensor:
        audio = F.normalize(self.audio(hidden), dim=-1)
        text = F.normalize(self.text(words), dim=-1)
        word_scores = audio @ text.transpose(0, 1) * self.scale.exp().clamp(max=40)
        return torch.cat((self.blank(audio), word_scores), dim=-1)


def word_features(
    tokenizer: Qwen2TokenizerFast, text: str, capture: dict[str, object]
) -> tuple[list[str], torch.Tensor]:
    spans = [(match.group(0), match.start(), match.end()) for match in WORD_RE.finditer(text)]
    encoded = tokenizer(text, add_special_tokens=False, return_offsets_mapping=True)
    token_ids = encoded["input_ids"]
    offsets = encoded["offset_mapping"]
    saved_ids = capture["embedding_token_ids"].tolist()
    saved_values = capture["embedding_values"].float()
    embedding_by_id = {int(token_id): saved_values[index] for index, token_id in enumerate(saved_ids)}
    word_vectors: list[torch.Tensor] = []
    for word, start, end in spans:
        ids = [
            int(token_id)
            for token_id, (token_start, token_end) in zip(token_ids, offsets, strict=True)
            if token_end > start and token_start < end
        ]
        values = [embedding_by_id[token_id] for token_id in ids if token_id in embedding_by_id]
        if not values:
            raise RuntimeError(f"no projected text embedding captured for {word!r}")
        word_vectors.append(torch.stack(values).mean(0))
    return [word for word, _, _ in spans], torch.stack(word_vectors)


def load_samples(root: Path, model_dir: Path) -> list[Sample]:
    tokenizer = Qwen2TokenizerFast.from_pretrained(model_dir, fix_mistral_regex=True)
    manifest = json.loads((root / "manifest.json").read_text())
    result: list[Sample] = []
    for row in manifest:
        capture = torch.load(root / row["capture"], map_location="cpu", weights_only=True)
        hidden = capture["hidden"].float()
        frame_seconds = capture["samples_per_frame"] / capture["sample_rate"]
        expected_frames = int(round(float(row["audio_seconds"]) / frame_seconds))
        # Base voice cloning normally suppresses one fixed bootstrap frame.
        # Retain the audible suffix when the codec reports fewer frames.
        if hidden.shape[0] > expected_frames:
            hidden = hidden[-expected_frames:]
        elif hidden.shape[0] < expected_frames:
            raise RuntimeError(
                f"{row['id']} has {hidden.shape[0]} hidden frames for {expected_frames} audio frames"
            )
        words, embeddings = word_features(tokenizer, row["text"], capture)
        result.append(
            Sample(
                sample_id=row["id"], split=row["split"], text=row["text"], words=words,
                hidden=hidden, word_embeddings=embeddings, frame_seconds=frame_seconds,
                audio_seconds=float(row["audio_seconds"]),
            )
        )
    return result


def forced_ctc_path(logits: torch.Tensor, word_count: int) -> torch.Tensor:
    """Viterbi-align the known ordered word sequence to frame emissions."""
    logp = logits.log_softmax(-1)
    target = torch.arange(1, word_count + 1, device=logits.device)
    expanded = torch.zeros(word_count * 2 + 1, dtype=torch.long, device=logits.device)
    expanded[1::2] = target
    time_count, state_count = logp.shape[0], expanded.numel()
    neg = torch.finfo(logp.dtype).min
    score = torch.full((time_count, state_count), neg, device=logits.device)
    back = torch.zeros((time_count, state_count), dtype=torch.int8, device=logits.device)
    score[0, 0] = logp[0, 0]
    if state_count > 1:
        score[0, 1] = logp[0, expanded[1]]
    for time_index in range(1, time_count):
        previous = score[time_index - 1]
        stay = previous
        advance = torch.cat((previous.new_full((1,), neg), previous[:-1]))
        skip = torch.cat((previous.new_full((2,), neg), previous[:-2]))
        skip = torch.where(expanded == 0, skip.new_full(skip.shape, neg), skip)
        options = torch.stack((stay, advance, skip))
        best, choice = options.max(dim=0)
        score[time_index] = best + logp[time_index, expanded]
        back[time_index] = choice.to(torch.int8)
    state_index = state_count - 1
    if score[-1, -2] > score[-1, -1]:
        state_index -= 1
    states = torch.empty(time_count, dtype=torch.long, device=logits.device)
    for time_index in range(time_count - 1, -1, -1):
        states[time_index] = state_index
        if time_index:
            state_index -= int(back[time_index, state_index])
    return expanded.index_select(0, states)


def timestamps_from_path(sample: Sample, path: torch.Tensor) -> list[dict[str, object]]:
    timestamps: list[dict[str, object]] = []
    for word_index, word in enumerate(sample.words, start=1):
        frames = torch.nonzero(path == word_index, as_tuple=False).reshape(-1)
        if frames.numel() == 0:
            raise RuntimeError(f"alignment skipped {word!r}")
        start = int(frames[0]) * sample.frame_seconds
        end = min(sample.audio_seconds, (int(frames[-1]) + 1) * sample.frame_seconds)
        timestamps.append({"word": word, "start": round(start, 3), "end": round(end, 3)})
    return timestamps


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=120)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    torch.manual_seed(20260825)
    samples = load_samples(args.data, args.model_dir)
    train = [sample for sample in samples if sample.split == "train"]
    demos = [sample for sample in samples if sample.split == "demo"]
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    head = TimestampHead(train[0].hidden.shape[1]).to(device)
    optimizer = torch.optim.AdamW(head.parameters(), lr=2e-3, weight_decay=1e-4)
    ctc = nn.CTCLoss(blank=0, zero_infinity=True)
    history: list[float] = []
    head.train()
    for epoch in range(args.epochs):
        order = torch.randperm(len(train)).tolist()
        epoch_loss = 0.0
        for sample_index in order:
            sample = train[sample_index]
            logits = head(sample.hidden.to(device), sample.word_embeddings.to(device))
            logp = logits.log_softmax(-1).unsqueeze(1)
            targets = torch.arange(1, len(sample.words) + 1, device=device)
            loss = ctc(
                logp, targets,
                torch.tensor([logits.shape[0]], device=device),
                torch.tensor([len(sample.words)], device=device),
            )
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(head.parameters(), 5)
            optimizer.step()
            epoch_loss += float(loss.detach())
        epoch_loss /= len(train)
        history.append(epoch_loss)
        if epoch == 0 or (epoch + 1) % 10 == 0:
            print(json.dumps({"epoch": epoch + 1, "loss": epoch_loss}), flush=True)

    args.output.mkdir(parents=True, exist_ok=True)
    torch.save(
        {"state_dict": head.state_dict(), "hidden_size": train[0].hidden.shape[1], "width": 96},
        args.output / "timestamp_head.pt",
    )
    head.eval()
    summary: dict[str, object] = {
        "training_samples": len(train), "epochs": args.epochs,
        "initial_loss": history[0], "final_loss": history[-1], "demos": [],
    }
    with torch.inference_mode():
        for sample in demos:
            logits = head(sample.hidden.to(device), sample.word_embeddings.to(device))
            path = forced_ctc_path(logits, len(sample.words)).cpu()
            timestamps = timestamps_from_path(sample, path)
            payload = {
                "id": sample.sample_id,
                "text": sample.text,
                "audio_seconds": sample.audio_seconds,
                "frame_seconds": sample.frame_seconds,
                "words": timestamps,
            }
            (args.output / f"{sample.sample_id}.timestamps.json").write_text(
                json.dumps(payload, indent=2), encoding="utf-8"
            )
            summary["demos"].append(
                {"id": sample.sample_id, "words": len(sample.words), "frames": sample.hidden.shape[0]}
            )
    (args.output / "training_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
