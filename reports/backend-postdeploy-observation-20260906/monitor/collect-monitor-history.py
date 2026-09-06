#!/usr/bin/env python3
"""Read and sanitize persisted core-audio monitor history without probing."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys


region = sys.argv[1]
if region not in {"us", "cn"}:
    raise SystemExit("region must be us or cn")
root = Path("/var/lib/castreader-core-audio-monitor") / region
cutoff = "2026-09-06T00:24:11Z"


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def safe_result(value, path):
    segments = []
    for row in value.get("segments", []):
        segments.append({name: row.get(name) for name in (
            "index", "attempts", "requestContract", "processedCharacters",
            "remainingCharacters", "audioBytes", "durationSeconds", "timestampsOk",
            "timestampCount", "gateway", "upstreamNode", "upstreamSource", "upstreamRevision",
        )})
    raw = path.read_bytes()
    return {
        "sourceFile": path.name,
        "sourceBytes": len(raw),
        "sourceSha256": digest_bytes(raw),
        "sourceMtimeUtc": datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat(),
        **{name: value.get(name) for name in (
            "schemaVersion", "probe", "observedAt", "region", "endpoint", "inputSha256",
            "inputCharacters", "language", "locale", "voice", "supplyOk", "alignmentOk",
            "status", "failureCode", "failedRequestContract", "elapsedMs", "segmentCount",
            "totalAudioBytes", "totalDurationSeconds",
        )},
        "segments": segments,
    }


def safe_alert(value, path):
    raw = path.read_bytes()
    return {
        "sourceFile": path.name,
        "sourceBytes": len(raw),
        "sourceSha256": digest_bytes(raw),
        "sourceMtimeUtc": datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat(),
        **{name: value.get(name) for name in (
            "schemaVersion", "type", "severity", "notificationPolicy", "observedAt",
            "region", "failureCode", "consecutiveSupplyFailures",
            "consecutiveAlignmentDegradations", "resultFile",
        )},
    }


def collect(directory, sanitizer):
    rows = []
    invalid = []
    for path in sorted(directory.glob("*.json")):
        try:
            rows.append(sanitizer(read_json(path), path))
        except Exception as error:
            invalid.append({"sourceFile": path.name, "errorType": type(error).__name__})
    return rows, invalid


def show(unit, fields):
    raw = subprocess.check_output(
        ["systemctl", "show", unit, *sum((["-p", field] for field in fields), []), "--no-pager"], text=True,
    )
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


results, invalid_results = collect(root / "results", safe_result)
alerts, invalid_alerts = collect(root / "alerts", safe_alert)
try:
    latest = safe_result(read_json(root / "latest.json"), root / "latest.json")
except Exception:
    latest = None
try:
    state_value = read_json(root / "state.json")
    state = {name: state_value.get(name) for name in (
        "schemaVersion", "updatedAt", "lastStatus", "consecutiveSupplyFailures",
        "consecutiveAlignmentDegradations", "lastHealthyAt", "lastAlertAt",
    )}
except Exception:
    state = None

current = Path("/opt/castreader-core-audio-monitor/current").resolve(strict=True)
release_files = []
for path in sorted(current.rglob("*")):
    if path.is_file() and not path.is_symlink():
        raw = path.read_bytes()
        release_files.append({
            "path": path.relative_to(current).as_posix(), "bytes": len(raw), "sha256": digest_bytes(raw),
        })
release_encoding = b"".join(
    row["path"].encode() + b"\0" + str(row["bytes"]).encode()
    + b"\0" + row["sha256"].encode() + b"\n" for row in release_files
)

print(json.dumps({
    "schema": "castreader.monitor-persisted-history-readback.v1",
    "readAtUtc": datetime.now(timezone.utc).isoformat(),
    "hostClockUtc": subprocess.check_output(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], text=True).strip(),
    "cutoffUtc": cutoff,
    "region": region,
    "readOnly": True,
    "probeStarted": False,
    "productionModified": False,
    "source": {
        "resultsDirectory": str(root / "results"),
        "alertsDirectory": str(root / "alerts"),
        "resultFilesRead": len(results),
        "alertFilesRead": len(alerts),
        "invalidResults": invalid_results,
        "invalidAlerts": invalid_alerts,
    },
    "monitorRelease": {
        "currentTarget": str(current),
        "files": len(release_files),
        "treeSha256": hashlib.sha256(release_encoding).hexdigest(),
    },
    "systemd": {
        "service": show(f"castreader-core-audio-monitor@{region}.service", [
            "ActiveState", "SubState", "MainPID", "Result", "ExecMainStatus",
            "ExecMainStartTimestamp", "ExecMainExitTimestamp",
        ]),
        "timer": show(f"castreader-core-audio-monitor@{region}.timer", [
            "ActiveState", "SubState", "UnitFileState", "LastTriggerUSec", "NextElapseUSecRealtime",
        ]),
    },
    "latest": latest,
    "state": state,
    "results": results,
    "alerts": alerts,
}, sort_keys=True))
