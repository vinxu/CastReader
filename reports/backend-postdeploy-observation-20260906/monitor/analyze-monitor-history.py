#!/usr/bin/env python3
"""Aggregate sanitized, persisted monitor history through one fixed cutoff."""

from collections import Counter
from datetime import datetime, timezone
import csv
import hashlib
import json
import math
from pathlib import Path


HERE = Path(__file__).resolve().parent
CUTOFF_TEXT = "2026-09-06T00:24:11Z"
MAIN_START_TEXT = "2026-09-05T18:50:21Z"
CUTOFF = datetime.fromisoformat(CUTOFF_TEXT.replace("Z", "+00:00"))
MAIN_START = datetime.fromisoformat(MAIN_START_TEXT.replace("Z", "+00:00"))
F6 = {
    "us": {
        "transactionStart": "2026-09-05T18:08:19.304908Z",
        "firstConfirmedCurrent": "2026-09-05T18:08:19.708702Z",
        "firstResult": "2026-09-05T18:08:34.685Z",
        "receipt": "reports/backend-core-fixes-20260905/release/monitor-legacy-contracts-20260906/transaction-receipt.json",
    },
    "cn": {
        "transactionStart": "2026-09-05T18:31:42.170655Z",
        "firstConfirmedCurrent": "2026-09-05T18:31:43.116174Z",
        "firstResult": "2026-09-05T18:31:49.911Z",
        "receipt": "reports/backend-core-fixes-20260905/release/monitor-legacy-contracts-20260906/cn-transaction-receipt.json",
    },
}
KNOWN_MANUAL = {
    "us": {
        "2026-09-05T16:15:00.370Z": "initial rollout receipt",
        F6["us"]["firstResult"]: "f6 cutover transaction receipt",
    },
    "cn": {
        "2026-09-05T15:58:13.669Z": "initial rollout receipt",
        F6["cn"]["firstResult"]: "f6 cutover transaction receipt",
    },
}


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def nearest_rank(values, quantile):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * quantile) - 1)]


def distribution(values, digits=3):
    values = [float(value) for value in values if value is not None]
    if not values:
        return None
    clean = lambda value: round(value, digits)
    return {
        "samples": len(values),
        "p50": clean(nearest_rank(values, 0.50)),
        "p95": clean(nearest_rank(values, 0.95)),
        "max": clean(max(values)),
    }


def is_complete(row):
    segments = row.get("segments") or []
    return bool(
        row.get("supplyOk") is True
        and row.get("segmentCount") == len(segments)
        and len(segments) >= 2
        and sum(int(segment.get("processedCharacters") or 0) for segment in segments) == row.get("inputCharacters")
        and segments[-1].get("remainingCharacters") == 0
        and all(
            (segment.get("audioBytes") or 0) > 0
            and (segment.get("durationSeconds") or 0) > 0
            for segment in segments
        )
    )


def deduplicate(rows):
    by_sha = {}
    by_time = {}
    duplicates = []
    conflicts = []
    for row in sorted(rows, key=lambda item: (timestamp(item["observedAt"]), item["sourceFile"])):
        if row["sourceSha256"] in by_sha:
            duplicates.append({"kept": by_sha[row["sourceSha256"]]["sourceFile"], "skipped": row["sourceFile"], "reason": "identical_content"})
            continue
        if row["observedAt"] in by_time:
            conflicts.append({"first": by_time[row["observedAt"]]["sourceFile"], "second": row["sourceFile"], "observedAt": row["observedAt"]})
            continue
        by_sha[row["sourceSha256"]] = row
        by_time[row["observedAt"]] = row
    if conflicts:
        raise RuntimeError(f"conflicting results share observedAt: {conflicts}")
    return sorted(by_time.values(), key=lambda item: timestamp(item["observedAt"])), duplicates


def origin(region, observed_at):
    if observed_at in KNOWN_MANUAL[region]:
        return "manual_confirmed_by_transaction_receipt"
    return "not_encoded_in_result"


def release_phase(region, observed_at):
    boundary = timestamp(F6[region]["firstConfirmedCurrent"])
    return "f6eb6691" if timestamp(observed_at) >= boundary else "272d3148"


def simplify_cycle(region, row):
    segments = row.get("segments") or []
    metadata = sorted({
        "|".join(str(segment.get(name) or "") for name in ("gateway", "upstreamNode", "upstreamSource", "upstreamRevision"))
        for segment in segments
    })
    return {
        "region": region,
        "observedAt": row["observedAt"],
        "sourceFile": row["sourceFile"],
        "monitorReleasePhase": release_phase(region, row["observedAt"]),
        "origin": origin(region, row["observedAt"]),
        "inMainWindow": MAIN_START <= timestamp(row["observedAt"]) <= CUTOFF,
        "inF6Window": timestamp(F6[region]["firstConfirmedCurrent"]) <= timestamp(row["observedAt"]) <= CUTOFF,
        "status": row.get("status"),
        "supplyOk": row.get("supplyOk"),
        "alignmentOk": row.get("alignmentOk"),
        "failureCode": row.get("failureCode"),
        "failedRequestContract": row.get("failedRequestContract"),
        "segmentCount": row.get("segmentCount"),
        "requestContracts": [segment.get("requestContract") for segment in segments],
        "completeRemainderDecoded": is_complete(row),
        "inputCharacters": row.get("inputCharacters"),
        "processedCharacters": sum(int(segment.get("processedCharacters") or 0) for segment in segments),
        "finalRemainingCharacters": segments[-1].get("remainingCharacters") if segments else None,
        "totalAudioBytes": row.get("totalAudioBytes"),
        "firstSegmentAudioDurationSeconds": segments[0].get("durationSeconds") if segments else None,
        "totalAudioDurationSeconds": row.get("totalDurationSeconds"),
        "probeElapsedMs": row.get("elapsedMs"),
        "upstreamMetadata": metadata,
    }


def failure_streaks(window_rows, all_rows, start):
    if not window_rows:
        return []
    all_index = {row["observedAt"]: index for index, row in enumerate(all_rows)}
    streaks = []
    index = 0
    while index < len(window_rows):
        if window_rows[index].get("status") != "supply_failed":
            index += 1
            continue
        first = index
        while index + 1 < len(window_rows) and window_rows[index + 1].get("status") == "supply_failed":
            index += 1
        last = index
        global_first = all_index[window_rows[first]["observedAt"]]
        while global_first > 0 and all_rows[global_first - 1].get("status") == "supply_failed":
            global_first -= 1
        global_last = all_index[window_rows[last]["observedAt"]]
        while global_last + 1 < len(all_rows) and all_rows[global_last + 1].get("status") == "supply_failed":
            global_last += 1
        recovery = all_rows[global_last + 1]["observedAt"] if global_last + 1 < len(all_rows) else None
        streaks.append({
            "firstFailureInWindow": window_rows[first]["observedAt"],
            "lastFailureInWindow": window_rows[last]["observedAt"],
            "cyclesInWindow": last - first + 1,
            "actualStreakStartThroughCutoff": all_rows[global_first]["observedAt"],
            "actualStreakCyclesThroughCutoff": global_last - global_first + 1,
            "startedBeforeWindow": timestamp(all_rows[global_first]["observedAt"]) < start,
            "recoveryObservedAt": recovery,
            "openAtCutoff": recovery is None,
        })
        index += 1
    return streaks


def window_metrics(region, rows, all_rows, alerts, start, end):
    selected = [row for row in rows if start <= timestamp(row["observedAt"]) <= end]
    statuses = Counter(str(row.get("status")) for row in selected)
    failure_codes = Counter(str(row.get("failureCode")) for row in selected if row.get("failureCode"))
    failed_contracts = Counter(str(row.get("failedRequestContract")) for row in selected if row.get("failedRequestContract"))
    executed_contracts = Counter(
        str(segment.get("requestContract"))
        for row in selected for segment in row.get("segments", []) if segment.get("requestContract") is not None
    )
    completed = [row for row in selected if is_complete(row)]
    supply_ok = [row for row in selected if row.get("supplyOk") is True]
    observed = [timestamp(row["observedAt"]) for row in selected]
    gaps = [(right - left).total_seconds() for left, right in zip(observed, observed[1:])]
    largest_gap = None
    if gaps:
        gap_index = max(range(len(gaps)), key=lambda index: gaps[index])
        largest_gap = {
            "seconds": round(gaps[gap_index], 3),
            "from": selected[gap_index]["observedAt"],
            "to": selected[gap_index + 1]["observedAt"],
        }
    upstream_variants = Counter()
    for row in selected:
        variants = {
            tuple(segment.get(name) for name in ("gateway", "upstreamNode", "upstreamSource", "upstreamRevision"))
            for segment in row.get("segments", [])
        }
        for variant in variants:
            upstream_variants[variant] += 1
    alert_rows = [alert for alert in alerts if start <= timestamp(alert["observedAt"]) <= end]
    origin_counts = Counter(origin(region, row["observedAt"]) for row in selected)
    first_audio = [row["segments"][0].get("durationSeconds") for row in selected if row.get("segments")]
    return {
        "startInclusive": start.isoformat().replace("+00:00", "Z"),
        "endInclusive": end.isoformat().replace("+00:00", "Z"),
        "firstObservedAt": selected[0]["observedAt"] if selected else None,
        "lastObservedAt": selected[-1]["observedAt"] if selected else None,
        "cycles": len(selected),
        "originCounts": dict(sorted(origin_counts.items())),
        "statusCounts": dict(sorted(statuses.items())),
        "failureCodeCounts": dict(sorted(failure_codes.items())),
        "failedRequestContractCounts": dict(sorted(failed_contracts.items())),
        "executedSegmentContractCounts": dict(sorted(executed_contracts.items())),
        "alignmentDegradationCycles": statuses.get("alignment_degraded", 0),
        "regionMismatchCycles": failure_codes.get("region_contract_mismatch", 0),
        "regionValidatedSuccessfulCycles": len(supply_ok),
        "regionValidationUnavailableBeforeSuccess": len(selected) - len(supply_ok) - failure_codes.get("region_contract_mismatch", 0),
        "completeRemainderDecoded": {
            "cycles": len(completed),
            "denominatorAllCycles": len(selected),
            "ratioAllCycles": round(len(completed) / len(selected), 6) if selected else None,
            "denominatorSupplyOkCycles": len(supply_ok),
            "ratioSupplyOkCycles": round(len(completed) / len(supply_ok), 6) if supply_ok else None,
        },
        "timing": {
            "probeTotalElapsedMs": distribution([row.get("elapsedMs") for row in selected], digits=3),
            "firstSegmentGenerationLatency": {"available": False, "reason": "persisted schema has no per-segment request elapsed or time-to-first-audio field"},
            "firstSegmentAudioDurationSeconds": distribution(first_audio, digits=3),
            "totalDecodedAudioDurationSeconds": distribution([row.get("totalDurationSeconds") for row in supply_ok], digits=3),
            "percentileMethod": "nearest-rank",
        },
        "cadence": {
            "observedGapSeconds": distribution(gaps, digits=3),
            "largestObservedGap": largest_gap,
            "windowStartToFirstObservedSeconds": round((observed[0] - start).total_seconds(), 3) if observed else None,
            "lastObservedToCutoffSeconds": round((end - observed[-1]).total_seconds(), 3) if observed else None,
            "note": "observedAt is completion time; gaps include probe duration, timer randomization and any manual invocation",
        },
        "failureStreaks": failure_streaks(selected, all_rows, start),
        "localAlertEvents": [
            {name: alert.get(name) for name in (
                "observedAt", "type", "severity", "notificationPolicy", "failureCode",
                "consecutiveSupplyFailures", "consecutiveAlignmentDegradations",
            )} for alert in alert_rows
        ],
        "upstreamMetadata": [
            {
                "gateway": key[0], "upstreamNode": key[1], "upstreamSource": key[2],
                "upstreamRevision": key[3], "cyclesContainingVariant": count,
            } for key, count in sorted(upstream_variants.items(), key=lambda item: tuple(str(part) for part in item[0]))
        ],
    }


aggregate = {
    "schema": "castreader.monitor-postdeploy-observation.v1",
    "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
    "cutoffUtcInclusive": CUTOFF_TEXT,
    "mainComparisonWindow": {"startInclusive": MAIN_START_TEXT, "endInclusive": CUTOFF_TEXT},
    "deduplication": "results/*.json only; exclude latest.json copy; then exact content SHA and observedAt",
    "monitorContractEvolution": {
        "272d3148": {
            "sourceCommit": "272d3148d6a93cec079d7dc649a78d406e5fe36f",
            "requestShape": "every segment sent stream:false",
            "persistedRequestContractField": False,
        },
        "f6eb6691": {
            "sourceCommit": "f6eb669178c665defff239fd8a60210b54894aeb",
            "requestShape": "remainder segments rotate stream omitted, true, false; retries preserve the segment contract",
            "persistedRequestContractField": True,
        },
        "boundary": "source commits and exact cutover transaction receipts, not inferred from result filenames",
        "gatewayDeploymentIdAvailableInPersistedResults": False,
    },
    "regions": {},
}
coverage = {
    "schema": "castreader.monitor-source-coverage.v1",
    "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
    "cutoffUtcInclusive": CUTOFF_TEXT,
    "latestJsonCountedAsCycle": False,
    "regions": {},
}

for region in ("us", "cn"):
    source_path = HERE / f"collected-{region}.json"
    source = json.loads(source_path.read_text())
    unique, duplicates = deduplicate(source["results"])
    included = [row for row in unique if timestamp(row["observedAt"]) <= CUTOFF]
    excluded = [row for row in unique if timestamp(row["observedAt"]) > CUTOFF]
    alerts = [alert for alert in source["alerts"] if timestamp(alert["observedAt"]) <= CUTOFF]
    history_start = timestamp(included[0]["observedAt"])
    f6_start = timestamp(F6[region]["firstConfirmedCurrent"])
    aggregate["regions"][region] = {
        "f6Upgrade": F6[region],
        "monitorSourceTransitions": [
            {"release": "272d3148", "throughBefore": F6[region]["transactionStart"]},
            {"release": "f6eb6691", "confirmedCurrentBy": F6[region]["firstConfirmedCurrent"], "firstPersistedResult": F6[region]["firstResult"]},
        ],
        "windows": {
            "observedHistory": window_metrics(region, included, included, alerts, history_start, CUTOFF),
            "mainComparison": window_metrics(region, included, included, alerts, MAIN_START, CUTOFF),
            "f6PostUpgrade": window_metrics(region, included, included, alerts, f6_start, CUTOFF),
        },
        "currentReadbackAfterCutoff": {
            "readAtUtc": source["readAtUtc"],
            "latestObservedAt": source["latest"]["observedAt"],
            "latestStatus": source["latest"].get("status"),
            "latestFailureCode": source["latest"].get("failureCode"),
            "state": source.get("state"),
            "timer": source["systemd"]["timer"],
        },
    }
    source_bytes = source_path.read_bytes()
    coverage["regions"][region] = {
        "readAtUtc": source["readAtUtc"],
        "hostClockUtc": source["hostClockUtc"],
        "resultsDirectory": source["source"]["resultsDirectory"],
        "alertsDirectory": source["source"]["alertsDirectory"],
        "resultFilesRead": source["source"]["resultFilesRead"],
        "uniqueResultCycles": len(unique),
        "includedThroughCutoff": len(included),
        "excludedAfterCutoff": [
            {"sourceFile": row["sourceFile"], "observedAt": row["observedAt"], "status": row.get("status"), "failureCode": row.get("failureCode")}
            for row in excluded
        ],
        "exactDuplicatesSkipped": duplicates,
        "invalidResults": source["source"]["invalidResults"],
        "alertFilesRead": source["source"]["alertFilesRead"],
        "invalidAlerts": source["source"]["invalidAlerts"],
        "includedObservedRange": {"first": included[0]["observedAt"], "last": included[-1]["observedAt"]},
        "latestJsonMatchesOneResultFile": sum(row["sourceSha256"] == source["latest"]["sourceSha256"] for row in unique) == 1,
        "monitorReleaseAtRead": source["monitorRelease"],
        "collectorOutput": {"path": source_path.name, "bytes": len(source_bytes), "sha256": hashlib.sha256(source_bytes).hexdigest()},
    }
    cycles = [simplify_cycle(region, row) for row in included]
    (HERE / f"cycles-{region}.json").write_text(json.dumps({
        "schema": "castreader.monitor-cycle-summary.v1", "cutoffUtcInclusive": CUTOFF_TEXT,
        "region": region, "cycles": cycles,
    }, indent=2, sort_keys=True) + "\n")
    with (HERE / f"cycles-{region}.csv").open("w", newline="") as output:
        names = [
            "region", "observedAt", "sourceFile", "monitorReleasePhase", "origin",
            "inMainWindow", "inF6Window", "status", "supplyOk", "alignmentOk",
            "failureCode", "failedRequestContract", "segmentCount", "requestContracts",
            "completeRemainderDecoded", "inputCharacters", "processedCharacters",
            "finalRemainingCharacters", "totalAudioBytes", "firstSegmentAudioDurationSeconds",
            "totalAudioDurationSeconds", "probeElapsedMs", "upstreamMetadata",
        ]
        writer = csv.DictWriter(output, fieldnames=names)
        writer.writeheader()
        for cycle in cycles:
            writer.writerow({
                **cycle,
                "requestContracts": ">".join(str(value) for value in cycle["requestContracts"]),
                "upstreamMetadata": ";".join(cycle["upstreamMetadata"]),
            })

(HERE / "aggregate.json").write_text(json.dumps(aggregate, indent=2, sort_keys=True) + "\n")
(HERE / "source-coverage.json").write_text(json.dumps(coverage, indent=2, sort_keys=True) + "\n")
print(json.dumps({
    "ok": True,
    "usMain": aggregate["regions"]["us"]["windows"]["mainComparison"]["statusCounts"],
    "cnMain": aggregate["regions"]["cn"]["windows"]["mainComparison"]["statusCounts"],
}, sort_keys=True))
