#!/usr/bin/env python3
"""Resolve experiment voice IDs to worker acceptance/retry log records."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


EVENTS = {
    "xvector_fallback_accepted",
    "xvector_fallback_rejected",
    "xvector_fallback_failed",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("clone_result", type=Path)
    parser.add_argument("worker_log", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    result = json.loads(args.clone_result.read_text(encoding="utf-8"))
    run_id = str(result["run_id"])
    by_hash: dict[str, list[dict[str, object]]] = {}
    with args.worker_log.open("r", encoding="utf-8", errors="replace") as source:
        for line in source:
            if "xvector_fallback_" not in line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("event") not in EVENTS:
                continue
            voice_hash = record.get("voice_hash")
            if isinstance(voice_hash, str):
                by_hash.setdefault(voice_hash, []).append(record)

    records = []
    missing = []
    for index, sample in enumerate(result["records"], start=1):
        branches = {}
        for branch in ("online", "deepfilter"):
            voice_id = f"vc_dab_{run_id}_{index:02d}_{branch[:2]}"
            voice_hash = hashlib.sha256(voice_id.encode()).hexdigest()[:12]
            events = by_hash.get(voice_hash, [])
            accepted = [item for item in events if item.get("event") == "xvector_fallback_accepted"]
            if len(accepted) != 1:
                missing.append(
                    {
                        "sample_id": sample["sample_id"],
                        "branch": branch,
                        "voice_hash": voice_hash,
                        "accepted_count": len(accepted),
                    }
                )
            branches[branch] = {
                "voice_hash": voice_hash,
                "events": events,
                "accepted": accepted[-1] if accepted else None,
            }
        records.append({"sample_id": sample["sample_id"], "branches": branches})

    output = {
        "run_id": run_id,
        "fixed_seed": result["fixed_seed"],
        "records": records,
        "missing_or_ambiguous": missing,
    }
    args.output.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    for record in records:
        values = []
        for branch, branch_result in record["branches"].items():
            accepted = branch_result["accepted"]
            values.append(
                f"{branch}=attempt{accepted.get('attempt') if accepted else 'missing'}"
            )
        print(f"{record['sample_id']} {' '.join(values)}")
    return 0 if not missing else 1


if __name__ == "__main__":
    raise SystemExit(main())
