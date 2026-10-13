"""Independent local ASR corroboration of the GPU multilingual smoke samples."""
import argparse
from difflib import SequenceMatcher
import json
from pathlib import Path

import mlx_whisper

from alignment_contract import lexical_key
from analyze_results import errors, distribution


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    source = json.loads((args.results / "results.json").read_text())
    records = []
    for row in source["languages"]:
        reference = mlx_whisper.transcribe(
            str(args.results / ("live-" + row["language"] + ".wav")), path_or_hf_repo=args.model,
            language=row["language"], word_timestamps=True, condition_on_previous_text=False,
        )
        words = [word for segment in reference["segments"] for word in segment.get("words", [])]
        deltas = errors([(word["word"], word["start_time"], word["end_time"])
                         for word in row["timestamps"]], words)
        records.append({"language": row["language"], "reference": reference,
                        "lexical_similarity": SequenceMatcher(a=lexical_key(row["text"]),
                                                              b=lexical_key(reference["text"]), autojunk=False).ratio(),
                        "aligned_words": len(row["timestamps"]), "matched_reference_words": len(deltas),
                        "start_difference_ms": distribution([entry["start_error_ms"] for entry in deltas])})
        (args.results / "independent-reference.json").write_text(json.dumps(records, ensure_ascii=False, indent=2))
        print(json.dumps({key: value for key, value in records[-1].items() if key != "reference"}), flush=True)


if __name__ == "__main__":
    main()
