#!/usr/bin/env python3
"""Freeze a conservative adaptive branch from per-seed measurements.

This aggregation deliberately does not majority-vote the permissive single-seed
selector.  It defaults to 24 dB, promotes to 100 dB only with repeatable
electrical-noise evidence, and falls back to the online/raw branch only with
repeatable evidence that the selected enhanced branch is materially worse.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


MINIMUM_SEEDS = 3
MATERIAL_DELTA = 0.030
MAXIMUM_SINGLE_SEED_REGRESSION = 0.020


def electrical_fraction(record: dict[str, object], branch: str) -> float:
    electrical = record["electrical"]
    assert isinstance(electrical, dict)
    metrics = electrical[branch]
    assert isinstance(metrics, dict)
    return float(metrics["suspicious_fraction_all_frames"])


def eligible(record: dict[str, object], branch: str) -> bool:
    eligibility = record["eligibility"]
    assert isinstance(eligibility, dict)
    candidate = eligibility[branch]
    assert isinstance(candidate, dict)
    return bool(candidate["eligible"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("selections", nargs="+", type=Path)
    parser.add_argument("--final-seed", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    measurements: dict[str, list[dict[str, object]]] = {}
    source_files = []
    for path in args.selections:
        document = json.loads(path.read_text(encoding="utf-8"))
        seed = int(document["fixed_seed"])
        source_files.append({"path": str(path), "seed": seed})
        for record in document["records"]:
            measurements.setdefault(str(record["sample_id"]), []).append(
                {"seed": seed, "record": record}
            )

    records = []
    for sample_id in sorted(measurements):
        sample_measurements = sorted(
            measurements[sample_id], key=lambda item: int(item["seed"])
        )
        per_seed = []
        for item in sample_measurements:
            source = item["record"]
            assert isinstance(source, dict)
            online = electrical_fraction(source, "online")
            atten24 = electrical_fraction(source, "atten24")
            atten100 = electrical_fraction(source, "atten100")
            per_seed.append(
                {
                    "seed": int(item["seed"]),
                    "online_e": online,
                    "atten24_e": atten24,
                    "atten100_e": atten100,
                    "atten100_improvement_vs_atten24": atten24 - atten100,
                    "atten24_regression_vs_online": atten24 - online,
                    "atten100_regression_vs_online": atten100 - online,
                    "atten24_eligible": eligible(source, "atten24"),
                    "atten100_eligible": eligible(source, "atten100"),
                }
            )

        has_three_seeds = len(per_seed) >= MINIMUM_SEEDS
        final_seed_measurement = next(
            (item for item in per_seed if int(item["seed"]) == args.final_seed), None
        )
        if final_seed_measurement is None:
            raise RuntimeError(
                f"{sample_id} has no measurements for final seed {args.final_seed}"
            )
        # Identity guards apply to the exact fresh-seed artifact that will ship.
        # Other seeds are repeatability probes for the electrical-noise metric;
        # their stochastic clone embeddings are not candidate outputs.
        atten24_guards_pass = bool(final_seed_measurement["atten24_eligible"])
        atten100_guards_pass = bool(final_seed_measurement["atten100_eligible"])
        atten100_material_wins = sum(
            float(item["atten100_improvement_vs_atten24"]) >= MATERIAL_DELTA
            for item in per_seed
        )
        atten100_bad_regressions = sum(
            -float(item["atten100_improvement_vs_atten24"])
            > MAXIMUM_SINGLE_SEED_REGRESSION
            for item in per_seed
        )
        promote_100 = (
            has_three_seeds
            and atten100_guards_pass
            and atten100_material_wins >= 2
            and atten100_bad_regressions == 0
        )

        provisional = "atten100" if promote_100 else "atten24"
        selected_guard_pass = (
            atten100_guards_pass if provisional == "atten100" else atten24_guards_pass
        )
        regression_key = f"{provisional}_regression_vs_online"
        raw_material_wins = sum(
            float(item[regression_key]) >= MATERIAL_DELTA for item in per_seed
        )
        fall_back_online = (
            not selected_guard_pass
            or (has_three_seeds and raw_material_wins >= 2)
        )
        selected = "online" if fall_back_online else provisional

        if not selected_guard_pass:
            decision = f"{provisional}-identity-guard-failed; fall back online"
        elif fall_back_online:
            decision = (
                f"{provisional} materially worse than online in "
                f"{raw_material_wins}/{len(per_seed)} seeds; fall back online"
            )
        elif promote_100:
            decision = (
                f"atten100 materially better than atten24 in "
                f"{atten100_material_wins}/{len(per_seed)} seeds with no >0.020 "
                "single-seed regression"
            )
        elif not has_three_seeds:
            decision = "default atten24; fewer than three registered seed measurements"
        else:
            decision = (
                f"default atten24; atten100 material wins "
                f"{atten100_material_wins}/{len(per_seed)}"
            )

        records.append(
            {
                "sample_id": sample_id,
                "selected": selected,
                "decision": decision,
                "seed_count": len(per_seed),
                "per_seed": per_seed,
                "atten100_upgrade": {
                    "final_seed_identity_guard_passed": atten100_guards_pass,
                    "material_wins": atten100_material_wins,
                    "single_seed_regressions_over_0_020": atten100_bad_regressions,
                    "selected": promote_100,
                },
                "raw_fallback": {
                    "evaluated_branch": provisional,
                    "final_seed_identity_guard_passed": selected_guard_pass,
                    "material_regressions": raw_material_wins,
                    "selected": fall_back_online,
                },
                "upstream_competing_speech_reject_recommended": (
                    sample_id == "06-public-cafeteria"
                ),
            }
        )
        print(
            f"aggregate {sample_id} selected={selected} "
            f"100_wins={atten100_material_wins}/{len(per_seed)} "
            f"raw_wins={raw_material_wins}/{len(per_seed)}",
            flush=True,
        )

    args.output.write_text(
        json.dumps(
            {
                "aggregation": "conservative per-seed repeatability rule",
                "rules": {
                    "default": "atten24",
                    "atten100_upgrade": (
                        "at least 2 of 3 seeds have E24-E100 >= 0.030; no observed "
                        "seed has E100-E24 > 0.020; final-seed identity guards pass"
                    ),
                    "online_fallback": (
                        "at least 2 of 3 seeds have Eselected-Eonline >= 0.030, "
                        "or the final-seed selected candidate identity guard fails"
                    ),
                    "insufficient_seed_evidence": "keep default atten24",
                },
                "clean_oracle_used": False,
                "fixed_seed": args.final_seed,
                "sources": source_files,
                "records": records,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
