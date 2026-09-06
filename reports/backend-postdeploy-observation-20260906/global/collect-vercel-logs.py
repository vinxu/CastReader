#!/usr/bin/env python3
"""Collect bounded 5xx Vercel records and persist only anonymized metadata.

Raw CLI JSON and nested runtime messages are held in memory only. Unknown paths,
request ids, trace ids, headers, bodies, and log text are never written.
"""

from __future__ import annotations

import collections
import datetime as dt
import hashlib
import json
import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).parent
LINKED_REPO = pathlib.Path("/Users/xuxuheng/Documents/MyProject/readout-web")
START = dt.datetime.fromisoformat("2026-09-05T18:50:21+00:00")
END = dt.datetime.fromisoformat("2026-09-06T00:24:11+00:00")
PROJECT_ID = "prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK"
PAGE_LIMIT = 1000
INITIAL_SHARD = dt.timedelta(minutes=30)
MINIMUM_SHARD = dt.timedelta(seconds=2)
QUERY_TIMEOUT_SECONDS = 45

EXACT_PATHS = {
    "/api/captioned_speech_partly": "tts",
    "/api/captioned_speech": "tts",
    "/api/quickread/extract-plan": "quickread",
    "/api/quickread/extract-block": "quickread",
    "/api/quickread/compose-block": "quickread",
    "/api/quickread/fast": "quickread",
    "/api/voice-clone/stream": "clone",
    "/api/voice-clone/library/stream": "clone",
}

KNOWN_FAILURE_PHRASES = {
    "preset_upstream_rejected": "preset upstream rejected request",
    "regional_routing_rejected": "regional routing rejected",
    "json_extra_data": "Extra data",
    "timeout_mentioned": "timeout",
}

ADVISORY_PHRASES = {
    "word_timing_unavailable_audio_continued": (
        "word timing unavailable; continuing audio"
    ),
}


def iso(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def hash_key(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    return hashlib.sha256(value.encode()).hexdigest()[:16]


def normalize_path(raw: object) -> tuple[str, str]:
    path = raw.split("?", 1)[0] if isinstance(raw, str) else ""
    if path in EXACT_PATHS:
        return path, EXACT_PATHS[path]
    if path.startswith("/api/quickread/"):
        return "/api/quickread/[other]", "quickread"
    if path.startswith("/api/voice-clone/"):
        return "/api/voice-clone/[other]", "clone"
    return "[other_project_path]", "other"


def normalize_domain(raw: object) -> str:
    domain = raw.lower() if isinstance(raw, str) else ""
    if domain == "api.castreader.ai":
        return domain
    if domain.endswith(".vercel.app"):
        return "[vercel_deployment_domain]"
    return "[other_or_missing_domain]"


def classify_message(record: dict) -> tuple[list[str], list[str]]:
    # This string is never printed or persisted; only fixed phrase booleans survive.
    volatile = json.dumps(
        {"message": record.get("message"), "logs": record.get("logs")},
        ensure_ascii=False,
    )
    failure_codes = [
        code for code, phrase in KNOWN_FAILURE_PHRASES.items() if phrase in volatile
    ]
    advisories = [
        code for code, phrase in ADVISORY_PHRASES.items() if phrase in volatile
    ]
    if not failure_codes:
        status = record.get("responseStatusCode")
        failure_codes.append(f"http_{status}_unclassified")
    return failure_codes, advisories


def sanitize(record: dict) -> dict | None:
    timestamp = record.get("timestamp")
    if not isinstance(timestamp, (int, float)):
        return None
    instant = dt.datetime.fromtimestamp(timestamp / 1000, dt.timezone.utc)
    if not (START <= instant < END):
        return None

    path, group = normalize_path(record.get("requestPath"))
    failure_codes, advisories = classify_message(record)
    return {
        "requestKey": hash_key(record.get("id")),
        "traceKey": hash_key(record.get("traceId")),
        "atUtc": iso(instant),
        "routeGroup": group,
        "path": path,
        "method": record.get("requestMethod"),
        "status": record.get("responseStatusCode"),
        "deploymentId": record.get("deploymentId"),
        "domainClass": normalize_domain(record.get("domain")),
        "source": record.get("source"),
        "level": record.get("level"),
        "failureCodes": failure_codes,
        "advisories": advisories,
        "originClassification": "unclassified_no_request_identity",
    }


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
        "--status-code",
        "5xx",
        "--json",
    ]
    completed = subprocess.run(
        command,
        cwd=LINKED_REPO,
        capture_output=True,
        text=True,
        timeout=QUERY_TIMEOUT_SECONDS,
    )
    if completed.returncode:
        # Never expose stderr: it is not part of the anonymized evidence contract.
        raise RuntimeError(f"vercel_logs_query_failed:{completed.returncode}")
    records = []
    for line in completed.stdout.splitlines():
        if not line.startswith("{"):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


safe_by_key: dict[str, dict] = {}
pages: list[dict] = []
query_failures: list[dict] = []


def collect(start: dt.datetime, end: dt.datetime, *, depth: int = 0) -> None:
    try:
        raw_records = run_query(start, end)
    except (subprocess.TimeoutExpired, RuntimeError) as error:
        if end - start <= MINIMUM_SHARD:
            query_failures.append(
                {
                    "since": iso(start),
                    "untilExclusive": iso(end),
                    "errorClass": type(error).__name__,
                }
            )
            return
        middle = start + (end - start) / 2
        collect(start, middle, depth=depth + 1)
        collect(middle, end, depth=depth + 1)
        return

    if len(raw_records) >= PAGE_LIMIT:
        if end - start <= MINIMUM_SHARD:
            query_failures.append(
                {
                    "since": iso(start),
                    "untilExclusive": iso(end),
                    "errorClass": "page_limit_reached_at_minimum_shard",
                }
            )
            return
        middle = start + (end - start) / 2
        collect(start, middle, depth=depth + 1)
        collect(middle, end, depth=depth + 1)
        return

    pages.append(
        {
            "since": iso(start),
            "untilExclusive": iso(end),
            "returnedRows": len(raw_records),
            "depth": depth,
        }
    )
    for record in raw_records:
        safe = sanitize(record)
        if safe is None:
            continue
        key = safe["requestKey"]
        if key:
            safe_by_key[key] = safe
    print(
        json.dumps(
            {
                "since": iso(start),
                "untilExclusive": iso(end),
                "returned5xx": len(raw_records),
                "unique5xxSoFar": len(safe_by_key),
            }
        ),
        flush=True,
    )


cursor = START
while cursor < END:
    shard_end = min(cursor + INITIAL_SHARD, END)
    collect(cursor, shard_end)
    cursor = shard_end

requests = sorted(safe_by_key.values(), key=lambda row: (row["atUtc"], row["requestKey"]))


def counter_rows(counter: collections.Counter, names: tuple[str, ...]) -> list[dict]:
    return [
        {**dict(zip(names, key if isinstance(key, tuple) else (key,))), "count": count}
        for key, count in sorted(counter.items(), key=lambda item: repr(item[0]))
    ]


status_by_route = collections.Counter(
    (row["routeGroup"], str(row["status"])) for row in requests
)
path_status = collections.Counter((row["path"], str(row["status"])) for row in requests)
failure_by_route = collections.Counter(
    (row["routeGroup"], failure)
    for row in requests
    for failure in row["failureCodes"]
)
deployment_status = collections.Counter(
    (str(row["deploymentId"]), str(row["status"])) for row in requests
)
domain_status = collections.Counter(
    (row["domainClass"], str(row["status"])) for row in requests
)

core_requests = [row for row in requests if row["routeGroup"] != "other"]
output = {
    "schema": "castreader.vercel-5xx-observation.v2",
    "sinceInclusive": iso(START),
    "untilExclusive": iso(END),
    "queriedAtUtc": iso(dt.datetime.now(dt.timezone.utc)),
    "readOnly": True,
    "projectId": PROJECT_ID,
    "query": {
        "environment": "production",
        "statusCode": "5xx",
        "pageLimit": PAGE_LIMIT,
        "initialShardSeconds": int(INITIAL_SHARD.total_seconds()),
        "timeoutSecondsPerQuery": QUERY_TIMEOUT_SECONDS,
    },
    "coverage": {
        "successfulShards": len(pages),
        "failedShards": len(query_failures),
        "pages": pages,
        "queryFailures": query_failures,
        "uniqueReturned5xxRecords": len(requests),
        "core5xxRecords": len(core_requests),
        "otherProject5xxRecords": len(requests) - len(core_requests),
        "hitPageLimit": any(page["returnedRows"] >= PAGE_LIMIT for page in pages),
    },
    "aggregates": {
        "statusByRouteGroup": counter_rows(status_by_route, ("routeGroup", "status")),
        "pathStatus": counter_rows(path_status, ("path", "status")),
        "failureCodeByRouteGroup": counter_rows(
            failure_by_route, ("routeGroup", "failureCode")
        ),
        "deploymentStatus": counter_rows(
            deployment_status, ("deploymentId", "status")
        ),
        "domainStatus": counter_rows(domain_status, ("domainClass", "status")),
    },
    "limitations": [
        "Counts are unique Vercel runtime log records returned by the CLI, not unique users.",
        "Vercel retention, ingestion, or sampling can make historical logs incomplete; no request denominator was available from metrics because the account returned payment_required.",
        "No monitor-versus-client attribution is asserted because these records expose no trustworthy client identity or user-agent field.",
        "Unknown request paths are collapsed; request/trace ids are one-way hashed; raw messages, nested logs, text, headers, IPs, and bodies are not persisted.",
    ],
    "requests": requests,
}

destination = ROOT / "vercel-5xx-observation.json"
destination.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n")
print(
    json.dumps(
        {
            "output": str(destination),
            "unique5xx": len(requests),
            "core5xx": len(core_requests),
            "failedShards": len(query_failures),
        }
    ),
    flush=True,
)
if query_failures:
    sys.exit(2)
