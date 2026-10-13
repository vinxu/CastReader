from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import numpy as np
import soundfile as sf
import torch

from caption_pipeline import PCM, QwenPCMAligner, project_words
from alignment_contract import AlignmentRejected


def shifted_alignment(aligner, pcm, text, language, shift):
    padding = round(shift * pcm.sample_rate)
    padded = PCM(np.pad(pcm.samples, (padding, 0)), pcm.sample_rate)
    words = aligner(padded, text, language)
    return [dict(word, start_time=max(0.0, round(word["start_time"] - shift, 6)),
                 end_time=min(pcm.duration, round(word["end_time"] - shift, 6)))
            for word in words]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--slow", action="store_true")
    args = parser.parse_args()
    torch.set_num_threads(4)
    if torch.cuda.mem_get_info()[0] < 6 * 1024**3:
        raise RuntimeError("insufficient-gpu-headroom")
    torch.cuda.set_per_process_memory_fraction(.20)
    aligner = QwenPCMAligner("cuda:0", str(args.root / "model"))
    manifest = json.loads((args.root / "evidence/manifest.json").read_text())
    fixtures = json.loads((args.root / "live-tts/client-fixtures.json").read_text())
    cases = [(row["id"], args.root / "evidence" / row["audio"], row["text"], "en")
             for row in manifest]
    cases.extend((row["id"], args.root / "live-tts" / f'{row["id"]}.wav',
                  row["text"], row["language"]) for row in fixtures
                 if row["language"] not in {"zh", "ja", "ko"})
    result = []
    for identity, path, text, language in cases:
        samples, rate = sf.read(path, dtype="float32")
        pcm = PCM(samples, rate)
        record = {"id": identity, "text": text, "language": language, "attempts": []}
        for shift in ([1, 1.5, 2, 3] if args.slow else [0, .02, .04, .06, .10, .14, .18]):
            started = time.perf_counter()
            if args.slow:
                if pcm.duration * shift > 120:
                    continue
                slower = PCM(pcm.samples, round(pcm.sample_rate / shift))
                words = [dict(word, start_time=word["start_time"] / shift,
                              end_time=word["end_time"] / shift)
                         for word in aligner(slower, text, language)]
            else:
                words = shifted_alignment(aligner, pcm, text, language, shift)
            try:
                project_words(text, words, pcm.duration)
                reason = "accepted"
            except AlignmentRejected as error:
                reason = str(error)
            record["attempts"].append({"shift": shift, "reason": reason, "words": words,
                                       "elapsed_ms": (time.perf_counter() - started) * 1000})
            if reason == "accepted":
                break
        result.append(record)
        filename = "refinement-slow.json" if args.slow else "refinement.json"
        (args.root / filename).write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps({"id": identity, "attempts": len(record["attempts"]),
                          "reason": reason}), flush=True)


if __name__ == "__main__":
    main()
