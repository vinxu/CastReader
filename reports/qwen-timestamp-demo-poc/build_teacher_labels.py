#!/usr/bin/env python3
"""Create offline-only word-boundary supervision for head distillation."""

from __future__ import annotations

import argparse
from difflib import SequenceMatcher
import json
from pathlib import Path
import re

import whisper


WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)?")


def normalize(word: str) -> str:
    return re.sub(r"[^a-z0-9']", "", word.lower().replace("’", "'"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--whisper-model", default="small.en")
    args = parser.parse_args()
    manifest = json.loads((args.data / "manifest.json").read_text())
    model = whisper.load_model(args.whisper_model)
    labels: dict[str, object] = {}
    for row in manifest:
        if row["split"] != "train":
            continue
        transcript_words = [match.group(0) for match in WORD_RE.finditer(row["text"])]
        decoded = model.transcribe(
            str(args.data / row["audio"]), language="en", word_timestamps=True
        )
        recognized = [
            {
                "word": word["word"].strip(),
                "start": float(word["start"]),
                "end": float(word["end"]),
            }
            for segment in decoded["segments"]
            for word in segment.get("words", [])
        ]
        matcher = SequenceMatcher(
            a=[normalize(word) for word in transcript_words],
            b=[normalize(item["word"]) for item in recognized],
            autojunk=False,
        )
        aligned: dict[str, object] = {}
        for block in matcher.get_matching_blocks():
            for offset in range(block.size):
                transcript_index = block.a + offset
                reference = recognized[block.b + offset]
                aligned[str(transcript_index)] = {
                    "start": reference["start"], "end": reference["end"]
                }
        coverage = len(aligned) / len(transcript_words)
        labels[row["id"]] = {
            "words": transcript_words,
            "aligned": aligned,
            "coverage": coverage,
            "whisper_text": decoded["text"].strip(),
        }
        print(json.dumps({"id": row["id"], "coverage": coverage}), flush=True)
    args.output.write_text(json.dumps(labels, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()

