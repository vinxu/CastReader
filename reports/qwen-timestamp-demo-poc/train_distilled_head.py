#!/usr/bin/env python3
"""Distill offline word boundaries into the runtime-native timestamp head."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch import nn

from train_timestamp_head import (
    TimestampHead,
    forced_ctc_path,
    load_samples,
    timestamps_from_path,
)


def smoothed_word_embeddings(values: torch.Tensor) -> torch.Tensor:
    result = values.clone()
    if values.shape[0] > 1:
        result[1:] += values[:-1] * 0.35
        result[:-1] += values[1:] * 0.35
    return result


def frame_targets(sample, teacher: dict[str, object]) -> tuple[torch.Tensor, torch.Tensor]:
    targets = torch.zeros(sample.hidden.shape[0], dtype=torch.long)
    weights = torch.full((sample.hidden.shape[0],), 0.15)
    for raw_index, boundary in teacher["aligned"].items():
        word_index = int(raw_index)
        start = max(0, int(float(boundary["start"]) / sample.frame_seconds))
        end = min(
            sample.hidden.shape[0],
            max(start + 1, int(round(float(boundary["end"]) / sample.frame_seconds))),
        )
        targets[start:end] = word_index + 1
        weights[start:end] = 1.0
    return targets, weights


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--teacher-labels", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    torch.manual_seed(20260825)
    samples = load_samples(args.data, args.model_dir)
    train = [sample for sample in samples if sample.split == "train"]
    demos = [sample for sample in samples if sample.split == "demo"]
    teacher = json.loads(args.teacher_labels.read_text())
    minimum_coverage = min(float(teacher[sample.sample_id]["coverage"]) for sample in train)
    if minimum_coverage < 0.9:
        raise RuntimeError(f"teacher coverage too low: {minimum_coverage:.3f}")
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    head = TimestampHead(train[0].hidden.shape[1]).to(device)
    optimizer = torch.optim.AdamW(head.parameters(), lr=1.5e-3, weight_decay=1e-4)
    history: list[float] = []
    for epoch in range(args.epochs):
        epoch_loss = 0.0
        for sample_index in torch.randperm(len(train)).tolist():
            sample = train[sample_index]
            targets, weights = frame_targets(sample, teacher[sample.sample_id])
            logits = head(
                sample.hidden.to(device),
                smoothed_word_embeddings(sample.word_embeddings).to(device),
            )
            losses = nn.functional.cross_entropy(
                logits, targets.to(device), reduction="none"
            )
            loss = (losses * weights.to(device)).sum() / weights.sum().to(device)
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
        {
            "state_dict": head.state_dict(), "hidden_size": train[0].hidden.shape[1],
            "width": 96, "smoothed_word_context": 0.35,
        },
        args.output / "timestamp_head_distilled.pt",
    )
    summary: dict[str, object] = {
        "training_samples": len(train), "epochs": args.epochs,
        "minimum_teacher_coverage": minimum_coverage,
        "initial_loss": history[0], "final_loss": history[-1], "demos": [],
    }
    head.eval()
    with torch.inference_mode():
        for sample in demos:
            logits = head(
                sample.hidden.to(device),
                smoothed_word_embeddings(sample.word_embeddings).to(device),
            )
            path = forced_ctc_path(logits, len(sample.words)).cpu()
            payload = {
                "id": sample.sample_id, "text": sample.text,
                "audio_seconds": sample.audio_seconds, "frame_seconds": sample.frame_seconds,
                "words": timestamps_from_path(sample, path),
            }
            (args.output / f"{sample.sample_id}.timestamps.distilled.json").write_text(
                json.dumps(payload, indent=2), encoding="utf-8"
            )
            summary["demos"].append(
                {"id": sample.sample_id, "words": len(sample.words), "frames": sample.hidden.shape[0]}
            )
    (args.output / "distilled_training_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
