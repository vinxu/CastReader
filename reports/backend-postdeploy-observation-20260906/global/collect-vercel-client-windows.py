#!/usr/bin/env python3
"""Collect TTS request statuses around known client events without raw logs."""

from __future__ import annotations

import collections
import datetime as dt
import hashlib
import json
import pathlib
import subprocess


ROOT = pathlib.Path(__file__).parent
LINKED_REPO = pathlib.Path("/Users/xuxuheng/Documents/MyProject/readout-web")
PAGE_LIMIT = 1000
TIMEOUT_SECONDS = 45
INITIAL_SHARD = dt.timedelta(seconds=15)
MINIMUM_SHARD = dt.timedelta(milliseconds=100)
PROJECT_ID = "prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK"
TTS_PATH = "/api/captioned_speech_partly"

WINDOWS = {
    "ios_kindle_page_turn_event_plus_minus_30s": (
        "2026-09-05T20:45:00.711Z",
        "2026-09-05T20:46:00.711Z",
    ),
    "ios_clipboard_tts_failure_plus_minus_30s": (
        "2026-09-05T20:47:47.066Z",
        "2026-09-05T20:48:47.066Z",
    ),
    "android_generation_failure_session": (
        "2026-09-05T23:49:45Z",
        "2026-09-05T23:53:30Z",
    ),
}

KNOWN_FAILURE_PHRASES = {
    "preset_upstream_rejected": "preset upstream rejected request",
    "regional_routing_rejected": "regional routing rejected",
    "json_extra_data": "Extra data",
    "timeout_mentioned": "timeout",
}


def parse(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def iso(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def hash_key(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    return hashlib.sha256(value.encode()).hexdigest()[:16]


def run_query(start: dt.datetime, end: dt.datetime) -> list[dict]:
    command = [
        "vercel",
        "logs",
        "--environment",
        "production",
        "--since",
        iso(start),
        "--until",
        iso(end),
        "--limit",
        str(PAGE_LIMIT),
        "--query",
        f"requestPath:{TTS_PATH}",
        "--json",
    ]
    completed = subprocess.run(
        command,
        cwd=LINKED_REPO,
        capture_output=True,
        text=True,
        timeout=TIMEOUT_SECONDS,
    )
    if completed.returncode:
        raise RuntimeError(f"vercel_logs_query_failed:{completed.returncode}")
    rows = []
    for line in completed.stdout.splitlines():
        if not line.startswith("{"):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            rows.append(value)
    return rows


def sanitize_record(record: dict, start: dt.datetime, end: dt.datetime) -> dict | None:
    timestamp = record.get("timestamp")
    if not isinstance(timestamp, (int, float)):
        return None
    instant = dt.datetime.fromtimestamp(timestamp / 1000, dt.timezone.utc)
    if not (start <= instant < end):
        return None
    path = (record.get("requestPath") or "").split("?", 1)[0]
    if path != TTS_PATH:
        return None
    key = hash_key(record.get("id"))
    if key is None:
        return None
    volatile = json.dumps(
        {"message": record.get("message"), "logs": record.get("logs")},
        ensure_ascii=False,
    )
    codes = [
        code for code, phrase in KNOWN_FAILURE_PHRASES.items() if phrase in volatile
    ]
    status = record.get("responseStatusCode")
    if isinstance(status, int) and status >= 400 and not codes:
        codes = [f"http_{status}_unclassified"]
    return {
        "requestKey": key,
        "atUtc": iso(instant),
        "path": TTS_PATH,
        "method": record.get("requestMethod"),
        "status": status,
        "deploymentId": record.get("deploymentId"),
        "source": record.get("source"),
        "failureCodes": codes,
        "originClassification": "unclassified_no_request_identity",
    }


def merge_request(existing: dict | None, incoming: dict) -> dict:
    if existing is None:
        return incoming
    existing["atUtc"] = min(existing["atUtc"], incoming["atUtc"])
    if existing.get("status") is None and incoming.get("status") is not None:
        existing["status"] = incoming["status"]
    existing["failureCodes"] = sorted(
        set(existing["failureCodes"]) | set(incoming["failureCodes"])
    )
    return existing


def collect_window(name: str, since: str, until: str) -> dict:
    window_start, window_end = parse(since), parse(until)
    safe_by_key: dict[str, dict] = {}
    shards: list[dict] = []
    failures: list[dict] = []

    def collect(start: dt.datetime, end: dt.datetime, depth: int = 0) -> None:
        try:
            raw = run_query(start, end)
        except (subprocess.TimeoutExpired, RuntimeError) as error:
            if end - start <= MINIMUM_SHARD:
                failures.append(
                    {
                        "since": iso(start),
                        "untilExclusive": iso(end),
                        "errorClass": type(error).__name__,
                    }
                )
                return
            middle = start + (end - start) / 2
            collect(start, middle, depth + 1)
            collect(middle, end, depth + 1)
            return
        if len(raw) >= PAGE_LIMIT:
            if end - start <= MINIMUM_SHARD:
                failures.append(
                    {
                        "since": iso(start),
                        "untilExclusive": iso(end),
                        "errorClass": "page_limit_reached_at_minimum_shard",
                    }
                )
                return
            middle = start + (end - start) / 2
            collect(start, middle, depth + 1)
            collect(middle, end, depth + 1)
            return
        shards.append(
            {
                "since": iso(start),
                "untilExclusive": iso(end),
                "returnedLogRows": len(raw),
                "depth": depth,
            }
        )
        for record in raw:
            safe = sanitize_record(record, window_start, window_end)
            if safe is None:
                continue
            key = safe["requestKey"]
            safe_by_key[key] = merge_request(safe_by_key.get(key), safe)

    cursor = window_start
    while cursor < window_end:
        shard_end = min(cursor + INITIAL_SHARD, window_end)
        collect(cursor, shard_end)
        cursor = shard_end

    records = sorted(
        safe_by_key.values(), key=lambda row: (row["atUtc"], row["requestKey"])
    )
    status_counts = collections.Counter(str(row["status"]) for row in records)
    failure_counts = collections.Counter(
        code for row in records for code in row["failureCodes"]
    )
    result = {
        "window": name,
        "sinceInclusive": since,
        "untilExclusive": until,
        "successfulShards": len(shards),
        "failedShards": len(failures),
        "queryFailures": failures,
        "hitPageLimitAfterSplitting": any(
            shard["returnedLogRows"] >= PAGE_LIMIT for shard in shards
        ),
        "returnedLogRows": sum(shard["returnedLogRows"] for shard in shards),
        "uniqueTtsRequestIds": len(records),
        "statusCounts": dict(sorted(status_counts.items())),
        "failureCodeCounts": dict(sorted(failure_counts.items())),
        "shards": shards,
        "records": records,
    }
    print(
        json.dumps(
            {
                "window": name,
                "successfulShards": result["successfulShards"],
                "failedShards": result["failedShards"],
                "returnedLogRows": result["returnedLogRows"],
                "uniqueTtsRequestIds": result["uniqueTtsRequestIds"],
                "statusCounts": result["statusCounts"],
            }
        ),
        flush=True,
    )
    return result


results = [collect_window(name, *bounds) for name, bounds in WINDOWS.items()]
output = {
    "schema": "castreader.vercel-client-window-status.v2",
    "queriedAtUtc": iso(dt.datetime.now(dt.timezone.utc)),
    "readOnly": True,
    "projectId": PROJECT_ID,
    "query": {
        "requestPath": TTS_PATH,
        "initialShardMilliseconds": int(INITIAL_SHARD.total_seconds() * 1000),
        "pageLimit": PAGE_LIMIT,
    },
    "windows": results,
    "limitations": [
        "Counts deduplicate Vercel log rows by request id; one request can produce many returned log rows.",
        "Historical retention or ingestion can still be incomplete even when no shard reaches the CLI page limit.",
        "Time overlap alone does not establish that a Vercel request caused a client event; no shared request or trace identity was available.",
        "These windows cover the normal preset TTS endpoint used by the cited iOS and Android events; they are not denominators for every core API route.",
        "Raw messages, nested logs, text, headers, IPs, and bodies are discarded in memory and are not persisted.",
    ],
}
(ROOT / "vercel-client-window-status.json").write_text(
    json.dumps(output, indent=2, ensure_ascii=False) + "\n"
)
if any(item["failedShards"] for item in results):
    raise SystemExit(2)
