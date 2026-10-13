from __future__ import annotations

import argparse
from difflib import SequenceMatcher
import json
from pathlib import Path
import statistics

from alignment_contract import lexical_key


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return None
    return {"count": len(ordered), "median_ms": statistics.median(ordered),
            "p95_ms": ordered[min(len(ordered) - 1, int(len(ordered) * .95))],
            "max_ms": ordered[-1], "over_250ms": sum(value > 250 for value in ordered),
            "over_500ms": sum(value > 500 for value in ordered)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    originals = {row["id"]: row for row in json.loads((args.evidence / "manifest.json").read_text())}
    references = {row["id"]: [word for segment in row["reference"]["segments"]
                             for word in segment.get("words", [])]
                  for row in json.loads((args.evidence / "whisper-reference.json").read_text())}
    rows = []
    for fixture in json.loads(args.fixtures.read_text()):
        identity = fixture["id"]
        original = originals[identity]["original_timestamps"]
        reference = references[identity]
        source_keys = [lexical_key(word[0]) for word in original]
        reference_keys = [lexical_key(word["word"]) for word in reference]
        matched = {}
        for block in SequenceMatcher(a=source_keys, b=reference_keys, autojunk=False).get_matching_blocks():
            for offset in range(block.size):
                matched[block.a + offset] = block.b + offset
        starts, ends = {}, {}
        position = 0
        for index, key in enumerate(source_keys):
            starts[position] = index
            position += len(key)
            ends[position] = index
        candidate = fixture["response"]["timestamps"]
        assert "".join(lexical_key(word["word"]) for word in candidate) == "".join(source_keys)
        position = 0
        pairs = []
        groups = []
        for stamp in candidate:
            first = starts.get(position)
            position += len(lexical_key(stamp["word"]))
            last = ends.get(position)
            if first is None or last is None:
                continue
            if last > first:
                groups.append({"word": stamp["word"], "words": last - first + 1})
            if any(index not in matched for index in range(first, last + 1)):
                continue
            if matched[last] - matched[first] != last - first:
                continue
            first_ref, last_ref = reference[matched[first]], reference[matched[last]]
            pairs.append({"word": stamp["word"], "words": last - first + 1,
                          "old_start_ms": abs(original[first][1] - first_ref["start"]) * 1000,
                          "new_start_ms": abs(stamp["start_time"] - first_ref["start"]) * 1000,
                          "old_end_ms": abs(original[last][2] - last_ref["end"]) * 1000,
                          "new_end_ms": abs(stamp["end_time"] - last_ref["end"]) * 1000})
        rows.append({"id": identity, "duration": fixture["duration"],
                     "source_words": len(original), "timestamp_spans": len(candidate),
                     "groups": groups, "pairs": pairs})
    summary = {}
    for cohort, included in {"all": rows, "excluding_94s_tail": [row for row in rows if row["id"] != "phone-14"]}.items():
        pairs = [pair for row in included for pair in row["pairs"]]
        summary[cohort] = {key: distribution([pair[key] for pair in pairs])
                           for key in ["old_start_ms", "new_start_ms", "old_end_ms", "new_end_ms"]}
        summary[cohort]["start_improved"] = sum(pair["new_start_ms"] < pair["old_start_ms"] for pair in pairs)
        summary[cohort]["start_worsened"] = sum(pair["new_start_ms"] > pair["old_start_ms"] for pair in pairs)
    result = {"limitation": "Independent Whisper Base corroboration, not manually annotated ground truth. Paired identical measured word/phrase spans; no invented individual boundaries.",
              "samples": len(rows), "source_words": sum(row["source_words"] for row in rows),
              "timestamp_spans": sum(row["timestamp_spans"] for row in rows),
              "grouped_spans": sum(len(row["groups"]) for row in rows), "summary": summary, "rows": rows}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "rows"}, indent=2))


if __name__ == "__main__":
    main()
