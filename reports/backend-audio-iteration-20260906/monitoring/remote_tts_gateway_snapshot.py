#!/usr/bin/env python3
"""Aggregate the US direct TTS gateway journal without exporting raw messages."""

from __future__ import annotations

from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys


UNIT = "castreader-tts-gateway.service"
SOURCE = Path("/opt/castreader-tts-gateway/gateway.mjs")
EXPECTED_PATH = "/api/captioned_speech_partly"
MAX_JOURNAL_ROWS = 250_000
SAFE_VERSION = re.compile(r"^[0-9A-Za-z._+-]{1,32}$")


def parse_timestamp(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp_requires_timezone")
    return parsed.astimezone(timezone.utc)


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def percentile(values, quantile):
    values = sorted(float(value) for value in values if value is not None)
    if not values:
        return None
    return round(values[max(0, math.ceil(len(values) * quantile) - 1)], 3)


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


def field(block: str, name: str):
    match = re.search(
        rf"(?:^|\n)\s*{re.escape(name)}:\s*(?:'([^']*)'|\"([^\"]*)\"|([^,\n}}]+))",
        block,
    )
    if not match:
        return None
    return next((value for value in match.groups() if value is not None), None)


def safe_platform(value):
    value = str(value or "unknown").lower()
    return value if value in {"android", "ios", "web", "extension", "unknown"} else "other"


def safe_version(value):
    value = str(value or "unknown")
    return value if SAFE_VERSION.fullmatch(value) else "other"


def safe_path(value):
    return EXPECTED_PATH if value == EXPECTED_PATH else "[other_path]"


def request_from_block(block: str, observed_at: datetime):
    request_id = field(block, "requestId")
    method = field(block, "method")
    path = field(block, "path")
    status = field(block, "status")
    elapsed = field(block, "elapsedMs")
    request_bytes = field(block, "requestBytes")
    if not request_id or not status:
        return None
    try:
        status_number = int(status)
        elapsed_number = int(elapsed) if elapsed is not None else None
        bytes_number = int(request_bytes) if request_bytes is not None else None
    except ValueError:
        return None
    if not 100 <= status_number <= 599:
        return None
    return {
        "key": hashlib.sha256(request_id.encode()).hexdigest()[:20],
        "observedAt": iso(observed_at),
        "method": method if method in {"GET", "POST"} else "other",
        "path": safe_path(path),
        "status": status_number,
        "elapsedMs": elapsed_number if elapsed_number is not None and elapsed_number >= 0 else None,
        "requestBytes": bytes_number if bytes_number is not None and bytes_number >= 0 else None,
        "clientPlatform": safe_platform(field(block, "clientPlatform")),
        "clientVersion": safe_version(field(block, "clientVersion")),
    }


def error_from_block(block: str):
    name = str(field(block, "name") or "").lower()
    message = str(field(block, "message") or "").lower()
    combined = f"{name} {message}"
    if "abort" in combined or "timeout" in combined:
        return "timeout_or_abort"
    if "fetch" in combined or "connect" in combined or "network" in combined:
        return "upstream_network"
    if "json" in combined:
        return "upstream_invalid_json"
    return "unclassified"


def console_blocks(entries):
    """Yield logical console calls whether journald preserved or split newlines."""
    current = None
    for observed_at, message in entries:
        stripped = message.strip()
        kind = None
        if stripped.startswith("tts_gateway_request"):
            kind = "request"
        elif stripped.startswith("tts_gateway_error"):
            kind = "error"
        if kind:
            if current is not None:
                yield current[0], current[1], "\n".join(current[2]), False
            current = [kind, observed_at, [message]]
            if "}" in stripped:
                yield kind, observed_at, message, True
                current = None
            continue
        if current is not None:
            current[2].append(message)
            if stripped == "}" or stripped.endswith("}"):
                yield current[0], current[1], "\n".join(current[2]), True
                current = None
    if current is not None:
        yield current[0], current[1], "\n".join(current[2]), False


def aggregate_entries(entries, start: datetime, end: datetime):
    selected_entries = []
    for observed_at, message in entries:
        if start <= observed_at < end:
            selected_entries.append((observed_at, message))

    requests = {}
    error_counts = Counter()
    incomplete_blocks = 0
    malformed_request_blocks = 0
    logical_blocks = 0
    for kind, observed_at, block, closed in console_blocks(selected_entries):
        logical_blocks += 1
        if not closed:
            incomplete_blocks += 1
        if kind == "request":
            record = request_from_block(block, observed_at)
            if record is None:
                malformed_request_blocks += 1
                continue
            existing = requests.get(record["key"])
            if existing is None or record["observedAt"] < existing["observedAt"]:
                requests[record["key"]] = record
        else:
            error_counts[error_from_block(block)] += 1

    rows = sorted(requests.values(), key=lambda row: row["observedAt"])
    status_counts = Counter(str(row["status"]) for row in rows)
    path_status = Counter((row["path"], str(row["status"])) for row in rows)
    client_status = Counter(
        (row["clientPlatform"], row["clientVersion"], str(row["status"]))
        for row in rows
    )
    hourly_status = Counter(
        (row["observedAt"][:13] + ":00:00Z", str(row["status"])) for row in rows
    )
    legacy = [
        row
        for row in rows
        if row["clientPlatform"] == "android" and row["clientVersion"] == "1.0.45"
    ]
    request_times = [parse_timestamp(row["observedAt"]) for row in rows]
    return {
        "journalRowsRead": len(selected_entries),
        "logicalGatewayBlocks": logical_blocks,
        "incompleteConsoleBlocks": incomplete_blocks,
        "malformedRequestBlocks": malformed_request_blocks,
        "uniqueRequestIds": len(rows),
        "duplicateRequestLogBlocks": max(
            0,
            logical_blocks - sum(error_counts.values()) - malformed_request_blocks - len(rows),
        ),
        "firstJournalAtUtc": iso(selected_entries[0][0]) if selected_entries else None,
        "lastJournalAtUtc": iso(selected_entries[-1][0]) if selected_entries else None,
        "firstRequestAtUtc": iso(request_times[0]) if request_times else None,
        "lastRequestAtUtc": iso(request_times[-1]) if request_times else None,
        "statusCounts": dict(sorted(status_counts.items())),
        "pathStatusCounts": [
            {"path": path, "status": status, "count": count}
            for (path, status), count in sorted(path_status.items())
        ],
        "clientStatusCounts": [
            {
                "clientPlatform": platform,
                "clientVersion": version,
                "status": status,
                "count": count,
            }
            for (platform, version, status), count in sorted(client_status.items())
        ],
        "hourlyStatusCounts": [
            {"hourUtc": hour, "status": status, "count": count}
            for (hour, status), count in sorted(hourly_status.items())
        ],
        "elapsedMs": distribution([row["elapsedMs"] for row in rows]),
        "requestBytes": distribution([row["requestBytes"] for row in rows]),
        "consoleErrorClassCounts": dict(sorted(error_counts.items())),
        "android145Preset": {
            "requests": len(legacy),
            "statusCounts": dict(
                sorted(Counter(str(row["status"]) for row in legacy).items())
            ),
            "elapsedMs": distribution([row["elapsedMs"] for row in legacy]),
            "firstRequestAtUtc": legacy[0]["observedAt"] if legacy else None,
            "lastRequestAtUtc": legacy[-1]["observedAt"] if legacy else None,
            "attribution": "client_supplied_platform_and_version_headers",
        },
    }


def systemd_show(unit):
    fields = [
        "ActiveState",
        "SubState",
        "MainPID",
        "NRestarts",
        "ExecMainStartTimestamp",
        "FragmentPath",
    ]
    raw = subprocess.check_output(
        ["systemctl", "show", unit, "--no-pager"]
        + [item for name in fields for item in ("-p", name)],
        text=True,
    )
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


def read_journal(start: datetime, end: datetime):
    command = [
        "journalctl",
        "-u",
        UNIT,
        "--since",
        iso(start),
        "--until",
        iso(end),
        "--output=json",
        "--no-pager",
        "--quiet",
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
    entries = []
    parse_errors = 0
    truncated = False
    assert process.stdout is not None
    for line in process.stdout:
        if len(entries) >= MAX_JOURNAL_ROWS:
            truncated = True
            process.terminate()
            break
        try:
            value = json.loads(line)
            micros = int(value["__REALTIME_TIMESTAMP"])
            message = value.get("MESSAGE", "")
            if isinstance(message, list):
                message = bytes(message).decode("utf-8", "replace")
            entries.append(
                (datetime.fromtimestamp(micros / 1_000_000, timezone.utc), str(message))
            )
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            parse_errors += 1
    return_code = process.wait()
    if return_code not in {0, -15}:
        raise RuntimeError(f"journalctl_failed:{return_code}")
    return entries, parse_errors, truncated


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: remote_tts_gateway_snapshot.py START_UTC END_UTC")
    start, end = map(parse_timestamp, sys.argv[1:])
    if end <= start:
        raise SystemExit("end_must_follow_start")
    entries, parse_errors, truncated = read_journal(start, end)
    aggregate = aggregate_entries(entries, start, end)
    source_bytes = SOURCE.read_bytes()
    host_clock = datetime.now(timezone.utc)
    complete = (
        not truncated
        and parse_errors == 0
        and aggregate["incompleteConsoleBlocks"] == 0
        and aggregate["malformedRequestBlocks"] == 0
    )
    print(
        json.dumps(
            {
                "schema": "castreader.direct-tts-gateway-journal.v1",
                "readOnly": True,
                "productionModified": False,
                "probeStarted": False,
                "query": {
                    "startInclusive": iso(start),
                    "endExclusive": iso(end),
                    "unit": UNIT,
                    "maxJournalRows": MAX_JOURNAL_ROWS,
                },
                "readAtUtc": iso(host_clock),
                "hostClockUtc": iso(host_clock),
                "source": {
                    "path": str(SOURCE),
                    "bytes": len(source_bytes),
                    "sha256": hashlib.sha256(source_bytes).hexdigest(),
                },
                "systemd": systemd_show(UNIT),
                "coverage": {
                    "complete": complete,
                    "journalParseErrors": parse_errors,
                    "journalRowLimitReached": truncated,
                    "note": "No request body, text, raw message, request id, header, IP, or credential is exported.",
                },
                "aggregate": aggregate,
                "limitations": [
                    "clientPlatform and clientVersion are caller-supplied headers and cannot exclude spoofing or manual tests.",
                    "Absence of request records can mean no traffic; it is not by itself proof of journal retention coverage.",
                    "HTTP aggregation covers only the direct US compatibility gateway used by applicable legacy clients, not Vercel ingress.",
                ],
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
