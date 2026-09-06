#!/usr/bin/env python3
"""Aggregate one region's already-persisted continuity monitor results."""

from __future__ import annotations

from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys


def parse_timestamp(value):
    parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp_requires_timezone")
    return parsed.astimezone(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def digest(value):
    return hashlib.sha256(value).hexdigest()


def percentile(values, quantile):
    ordered = sorted(float(value) for value in values if value is not None)
    if not ordered:
        return None
    return round(ordered[max(0, math.ceil(len(ordered) * quantile) - 1)], 3)


def distribution(values):
    values = [float(value) for value in values if value is not None]
    if not values:
        return {"samples": 0, "p50": None, "p95": None, "max": None}
    return {
        "samples": len(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": round(max(values), 3),
    }


def complete_audio(value):
    segments = value.get("segments") or []
    return bool(
        value.get("supplyOk") is True
        and value.get("segmentCount") == len(segments)
        and len(segments) >= 1
        and sum(int(segment.get("processedCharacters") or 0) for segment in segments)
        == value.get("inputCharacters")
        and segments[-1].get("remainingCharacters") == 0
        and all(
            (segment.get("audioBytes") or 0) > 0
            and (segment.get("durationSeconds") or 0) > 0
            for segment in segments
        )
    )


def consecutive_summary(rows, predicate, recovery_predicate=None):
    current = 0
    maximum = 0
    episodes = 0
    recoveries = []
    for row in rows:
        if predicate(row):
            if current == 0:
                episodes += 1
            current += 1
            maximum = max(maximum, current)
        elif current:
            if recovery_predicate is None or recovery_predicate(row):
                recoveries.append(
                    {
                        "observedAtUtc": row.get("observedAt"),
                        "precedingCycles": current,
                        "recoveredStatus": row.get("status"),
                    }
                )
            current = 0
    return {
        "episodes": episodes,
        "maximumConsecutiveCycles": maximum,
        "currentConsecutiveCycles": current,
        "recoveryEvents": recoveries,
    }


def systemd_show(unit, fields):
    raw = subprocess.check_output(
        ["systemctl", "show", unit, "--no-pager"]
        + [item for name in fields for item in ("-p", name)],
        text=True,
    )
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


def safe_result(value, path):
    raw = path.read_bytes()
    segments = [
        {
            name: segment.get(name)
            for name in (
                "index",
                "attempts",
                "requestContract",
                "processedCharacters",
                "remainingCharacters",
                "audioBytes",
                "durationSeconds",
                "timestampsOk",
                "timestampCount",
                "gateway",
                "upstreamNode",
                "upstreamSource",
                "upstreamRevision",
            )
        }
        for segment in value.get("segments", [])
    ]
    return {
        "sourceFile": path.name,
        "sourceSha256": digest(raw),
        "sourceMtimeUtc": iso(datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)),
        **{
            name: value.get(name)
            for name in (
                "schemaVersion",
                "probe",
                "observedAt",
                "region",
                "inputCharacters",
                "language",
                "locale",
                "voice",
                "supplyOk",
                "alignmentOk",
                "status",
                "failureCode",
                "failedRequestContract",
                "elapsedMs",
                "segmentCount",
                "totalAudioBytes",
                "totalDurationSeconds",
            )
        },
        "segments": segments,
    }


def monitor_release():
    current = Path("/opt/castreader-core-audio-monitor/current").resolve(strict=True)
    files = []
    for path in sorted(current.rglob("*")):
        if path.is_file() and not path.is_symlink():
            raw = path.read_bytes()
            files.append(
                {
                    "path": path.relative_to(current).as_posix(),
                    "bytes": len(raw),
                    "sha256": digest(raw),
                }
            )
    encoding = b"".join(
        row["path"].encode()
        + b"\0"
        + str(row["bytes"]).encode()
        + b"\0"
        + row["sha256"].encode()
        + b"\n"
        for row in files
    )
    return {
        "currentTarget": str(current),
        "files": len(files),
        "treeSha256": digest(encoding),
    }


def aggregate(region, start, end):
    root = Path("/var/lib/castreader-core-audio-monitor") / region
    parsed = []
    invalid = []
    for path in sorted((root / "results").glob("*.json")):
        try:
            value = safe_result(json.loads(path.read_text()), path)
            parse_timestamp(value["observedAt"])
            parsed.append(value)
        except Exception as error:
            mtime = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
            invalid.append(
                {
                    "sourceFile": path.name,
                    "sourceMtimeUtc": iso(mtime),
                    "errorType": type(error).__name__,
                    "mtimeOverlapsWindow": start <= mtime < end,
                }
            )

    by_sha = {}
    by_time = {}
    duplicates = 0
    conflicts = []
    for row in sorted(parsed, key=lambda item: (parse_timestamp(item["observedAt"]), item["sourceFile"])):
        if row["sourceSha256"] in by_sha:
            duplicates += 1
            continue
        if row["observedAt"] in by_time:
            conflicts.append(row["observedAt"])
            continue
        by_sha[row["sourceSha256"]] = row
        by_time[row["observedAt"]] = row
    unique = sorted(by_time.values(), key=lambda item: parse_timestamp(item["observedAt"]))
    selected = [row for row in unique if start <= parse_timestamp(row["observedAt"]) < end]

    status_counts = Counter(str(row.get("status")) for row in selected)
    failure_counts = Counter(
        str(row.get("failureCode")) for row in selected if row.get("failureCode")
    )
    failed_contracts = Counter(
        str(row.get("failedRequestContract"))
        for row in selected
        if row.get("failedRequestContract")
    )
    executed_contracts = Counter(
        str(segment.get("requestContract"))
        for row in selected
        for segment in row.get("segments", [])
        if segment.get("requestContract") is not None
    )
    complete_rows = [row for row in selected if complete_audio(row)]
    supply_sequence = consecutive_summary(
        selected,
        lambda row: row.get("status") == "supply_failed"
        or row.get("supplyOk") is False,
        lambda row: row.get("supplyOk") is True,
    )
    alignment_sequence = consecutive_summary(
        selected,
        lambda row: row.get("status") == "alignment_degraded",
        lambda row: row.get("status") == "healthy" and row.get("supplyOk") is True,
    )
    observed = [parse_timestamp(row["observedAt"]) for row in selected]
    gaps = [(right - left).total_seconds() for left, right in zip(observed, observed[1:])]
    metadata = Counter()
    for row in selected:
        variants = {
            tuple(
                segment.get(name)
                for name in (
                    "gateway",
                    "upstreamNode",
                    "upstreamSource",
                    "upstreamRevision",
                )
            )
            for segment in row.get("segments", [])
        }
        for variant in variants:
            metadata[variant] += 1

    source_range = {
        "firstAvailableObservedAt": unique[0]["observedAt"] if unique else None,
        "lastAvailableObservedAt": unique[-1]["observedAt"] if unique else None,
        "firstSelectedObservedAt": selected[0]["observedAt"] if selected else None,
        "lastSelectedObservedAt": selected[-1]["observedAt"] if selected else None,
        "windowStartToFirstSelectedSeconds": round((observed[0] - start).total_seconds(), 3)
        if observed
        else None,
        "lastSelectedToWindowEndSeconds": round((end - observed[-1]).total_seconds(), 3)
        if observed
        else None,
    }

    return {
        "schema": "castreader.monitor-window-readback.v2",
        "region": region,
        "readOnly": True,
        "probeStarted": False,
        "productionModified": False,
        "readAtUtc": iso(datetime.now(timezone.utc)),
        "query": {"startInclusive": iso(start), "endExclusive": iso(end)},
        "source": {
            "resultsDirectory": str(root / "results"),
            "resultFilesScanned": len(parsed) + len(invalid),
            "validResultFiles": len(parsed),
            "uniqueResultCycles": len(unique),
            "exactDuplicatesSkipped": duplicates,
            "invalidResults": invalid,
            "conflictingObservedAt": sorted(set(conflicts)),
            **source_range,
        },
        "coverage": {
            "completeRead": not conflicts
            and not any(row["mtimeOverlapsWindow"] for row in invalid),
            "selectedCycles": len(selected),
            "originAttributionAvailable": False,
            "note": "Persisted result schema does not distinguish timer from manual invocation.",
        },
        "monitorRelease": monitor_release(),
        "systemd": {
            "service": systemd_show(
                f"castreader-core-audio-monitor@{region}.service",
                ["ActiveState", "SubState", "MainPID", "Result", "ExecMainStatus"],
            ),
            "timer": systemd_show(
                f"castreader-core-audio-monitor@{region}.timer",
                [
                    "ActiveState",
                    "SubState",
                    "UnitFileState",
                    "LastTriggerUSec",
                    "NextElapseUSecRealtime",
                ],
            ),
        },
        "aggregate": {
            "cycles": len(selected),
            "statusCounts": dict(sorted(status_counts.items())),
            "failureCodeCounts": dict(sorted(failure_counts.items())),
            "failedRequestContractCounts": dict(sorted(failed_contracts.items())),
            "executedRequestContractCounts": dict(sorted(executed_contracts.items())),
            "supplyOkCycles": sum(row.get("supplyOk") is True for row in selected),
            "supplyFailureSequence": supply_sequence,
            "alignmentDegradationCycles": sum(
                row.get("status") == "alignment_degraded" for row in selected
            ),
            "alignmentDegradationSequence": alignment_sequence,
            "regionMismatchCycles": failure_counts.get("region_contract_mismatch", 0),
            "completeRemainderDecodedCycles": len(complete_rows),
            "completeRemainderDecodedRatio": round(len(complete_rows) / len(selected), 6)
            if selected
            else None,
            "probeElapsedMs": distribution([row.get("elapsedMs") for row in selected]),
            "firstSegmentAudioDurationSeconds": distribution(
                [
                    row["segments"][0].get("durationSeconds")
                    for row in selected
                    if row.get("segments")
                ]
            ),
            "totalAudioDurationSeconds": distribution(
                [row.get("totalDurationSeconds") for row in selected if row.get("supplyOk")]
            ),
            "observedGapSeconds": distribution(gaps),
            "largestObservedGapSeconds": round(max(gaps), 3) if gaps else None,
            "upstreamMetadata": [
                {
                    "gateway": key[0],
                    "upstreamNode": key[1],
                    "upstreamSource": key[2],
                    "upstreamRevision": key[3],
                    "cyclesContainingVariant": count,
                }
                for key, count in sorted(
                    metadata.items(), key=lambda item: tuple(str(part) for part in item[0])
                )
            ],
        },
        "limitations": [
            "observedAt is probe completion time, not request start time.",
            "First-segment audio duration is not time-to-first-audio latency.",
            "No persisted client traffic or user identity is read by this collector.",
        ],
    }


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in {"us", "cn"}:
        raise SystemExit("usage: remote_monitor_snapshot.py us|cn START_UTC END_UTC")
    region = sys.argv[1]
    start, end = map(parse_timestamp, sys.argv[2:])
    if end <= start:
        raise SystemExit("end_must_follow_start")
    print(json.dumps(aggregate(region, start, end), sort_keys=True))


if __name__ == "__main__":
    main()
