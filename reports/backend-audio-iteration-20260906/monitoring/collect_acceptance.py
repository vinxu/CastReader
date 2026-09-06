#!/usr/bin/env python3
"""Collect a bounded, read-only 24-hour CastReader audio acceptance snapshot."""

from __future__ import annotations

import argparse
import base64
from collections import Counter
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import time
from urllib.parse import urlencode, unquote, urlparse

from acceptance_core import aggregate_mobile, evaluate, iso, parse_utc, validate_state


HERE = Path(__file__).resolve().parent
DEFAULT_STATE = HERE / "acceptance-state.json"
DEFAULT_OUTPUT = HERE / "latest-acceptance.json"
DEFAULT_CACHE = HERE / "cache"
CORE_PATHS = {
    "/api/captioned_speech_partly": "tts",
    "/api/captioned_speech": "tts",
    "/api/quickread/extract-plan": "quickread",
    "/api/quickread/extract-block": "quickread",
    "/api/quickread/compose-block": "quickread",
    "/api/quickread/fast": "quickread",
    "/api/voice-clone/stream": "clone",
    "/api/voice-clone/library/stream": "clone",
    "/api/voice-clone/captioned-speech": "clone",
}
FAILURE_PHRASES = {
    "preset_upstream_rejected": "preset upstream rejected request",
    "regional_routing_rejected": "regional routing rejected",
    "json_extra_data": "Extra data",
    "timeout_mentioned": "timeout",
}
MOBILE_EVENT_NAMES = (
    "read_start",
    "read_first_audio",
    "read_milestone",
    "read_end",
    "explain_start",
    "explain_first_block",
    "explain_milestone",
    "explain_end",
)


def load_json(path):
    return json.loads(Path(path).read_text())


def atomic_write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def safe_error(source, error):
    return {
        "schema": "castreader.acceptance-source-error.v1",
        "source": source,
        "complete": False,
        "errorType": type(error).__name__,
        "detail": "collector_failed_without_exporting_raw_stderr_or_response_body",
    }


def deep_override(config, arguments):
    value = copy.deepcopy(config)
    if arguments.cutover_state:
        value["cutoverState"] = arguments.cutover_state
    if arguments.start:
        value.setdefault("window", {})["startUtc"] = arguments.start
    if arguments.end:
        value.setdefault("window", {})["endUtc"] = arguments.end
    return value


def run_remote_script(host_arguments, script, script_arguments, timeout):
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    command.extend(host_arguments)
    command.extend(["python3", "-", *script_arguments])
    completed = subprocess.run(
        command,
        input=script.read_text(),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if completed.returncode:
        raise RuntimeError(f"remote_collector_failed:{completed.returncode}")
    lines = [line for line in completed.stdout.splitlines() if line.startswith("{")]
    if len(lines) != 1:
        raise RuntimeError("remote_collector_invalid_output")
    value = json.loads(lines[0])
    if not isinstance(value, dict):
        raise RuntimeError("remote_collector_non_object")
    return value


def parse_dotenv(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        name, raw = stripped.split("=", 1)
        raw = raw.strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {'"', "'"}:
            raw = raw[1:-1]
        values[name.strip()] = raw
    return values


def extract_assignment(path, name):
    source = Path(path).read_text()
    match = re.search(rf"^\s*{re.escape(name)}\s*=\s*['\"]([^'\"]+)['\"]", source, re.M)
    if not match:
        raise RuntimeError(f"credential_assignment_missing:{name}")
    return match.group(1)


def decode_jwt_claim(token):
    parts = token.split(".")
    if len(parts) < 2:
        raise RuntimeError("credential_not_jwt")
    padded = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(padded))


def mobile_credentials(config):
    sources = config.get("sources", {})
    env_path = sources.get("globalEnvFile")
    credential_path = sources.get("supabaseCredentialSource")
    if not env_path or not credential_path:
        raise RuntimeError("mobile_credential_source_path_missing")
    database_url = parse_dotenv(env_path).get("DATABASE_URL")
    if not database_url:
        raise RuntimeError("database_url_missing")
    parsed = urlparse(database_url)
    username = unquote(parsed.username or "")
    project_ref = username.rsplit(".", 1)[-1]
    if not re.fullmatch(r"[a-z]{20}", project_ref):
        raise RuntimeError("database_project_ref_invalid")
    expected_origin = f"https://{project_ref}.supabase.co"
    configured_origin = extract_assignment(credential_path, "SUPABASE_URL")
    if urlparse(configured_origin).scheme != "https" or configured_origin.rstrip("/") != expected_origin:
        raise RuntimeError("supabase_origin_mismatch")
    key = extract_assignment(credential_path, "SUPABASE_KEY")
    claim = decode_jwt_claim(key)
    if claim.get("role") != "service_role" or claim.get("ref", project_ref) != project_ref:
        raise RuntimeError("supabase_credential_scope_mismatch")
    return project_ref, key


def postgrest_get(project_ref, key, parameters, timeout):
    connection = http.client.HTTPSConnection(
        f"{project_ref}.supabase.co",
        timeout=timeout,
        context=ssl.create_default_context(),
    )
    path = "/rest/v1/mobile_funnel_events?" + urlencode(parameters, safe="(),.*->>")
    connection.request(
        "GET",
        path,
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Prefer": "count=exact",
            "Accept": "application/json",
        },
    )
    response = connection.getresponse()
    body = response.read()
    headers = {name.lower(): value for name, value in response.getheaders()}
    connection.close()
    if response.status != 200:
        raise RuntimeError(f"postgrest_http_{response.status}")
    value = json.loads(body)
    if not isinstance(value, list):
        raise RuntimeError("postgrest_non_array")
    return value, headers


def collect_global_capabilities(config):
    sources = config.get("sources", {})
    endpoint = sources.get(
        "globalCapabilitiesURL", "https://api.castreader.ai/api/capabilities"
    )
    timeout = int(sources.get("globalCapabilitiesTimeoutSeconds", 15))
    parsed = urlparse(endpoint)
    if (
        parsed.scheme != "https"
        or parsed.hostname != "api.castreader.ai"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port not in {None, 443}
        or parsed.path != "/api/capabilities"
        or parsed.params
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError("global_capabilities_endpoint_not_allowlisted")
    connection = http.client.HTTPSConnection(
        parsed.hostname,
        port=parsed.port,
        timeout=timeout,
        context=ssl.create_default_context(),
    )
    try:
        connection.request(
            "GET",
            parsed.path,
            headers={"Accept": "application/json", "Cache-Control": "no-cache"},
        )
        response = connection.getresponse()
        body = response.read(1_048_577)
    finally:
        connection.close()
    if response.status != 200:
        raise RuntimeError(f"global_capabilities_http_{response.status}")
    if len(body) > 1_048_576:
        raise RuntimeError("global_capabilities_response_too_large")
    manifest = json.loads(body)
    if not isinstance(manifest, dict):
        raise RuntimeError("global_capabilities_non_object")
    release_id = manifest.get("releaseId")
    commit_sha = manifest.get("commitSha")
    voice_clone = manifest.get("voiceClone")
    region = voice_clone.get("serviceRoute") if isinstance(voice_clone, dict) else None
    field_errors = []
    if not isinstance(release_id, str) or not re.fullmatch(r"dpl_[A-Za-z0-9]+", release_id):
        field_errors.append("release_id_invalid")
        release_id = None
    if not isinstance(commit_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", commit_sha):
        field_errors.append("commit_sha_invalid")
        commit_sha = None
    if region not in {"global", "cn"}:
        field_errors.append("region_invalid")
        region = None
    return {
        "schema": "castreader.global-capabilities-identity.v1",
        "readOnly": True,
        "productionModified": False,
        "probeStarted": False,
        "readAtUtc": iso(datetime.now(timezone.utc)),
        "query": {"endpoint": endpoint, "method": "GET"},
        "coverage": {
            "complete": not field_errors,
            "tlsCertificateVerification": True,
            "fieldErrors": field_errors,
        },
        "identity": {
            "deploymentId": release_id,
            "commitSha": commit_sha,
            "region": region,
        },
        "limitations": [
            "Only deploymentId, commitSha and the published service region are retained from the response.",
            "This identity GET performs no synthesis and does not provide a traffic denominator.",
        ],
    }


def collect_mobile(config, start, end):
    project_ref, key = mobile_credentials(config)
    sources = config.get("sources", {})
    page_size = int(sources.get("mobilePageSize", 1000))
    max_pages = int(sources.get("mobileMaxPages", 100))
    timeout = int(sources.get("mobileTimeoutSeconds", 25))
    wall_clock_budget = float(sources.get("mobileWallClockBudgetSeconds", 180))
    deadline = time.monotonic() + wall_clock_budget
    fields = [
        "event_id",
        "event_name",
        "analytics_anonymous_id",
        "client_platform",
        "received_at",
        "environment:properties->>environment",
        "serviceRoute:properties->>client_service_route",
        "ingressRoute:properties->>ingress_service_route",
        "routeMismatch:properties->>service_route_mismatch",
        "readSession:properties->>read_session_id",
        "explainSession:properties->>explain_session_id",
        "result:properties->>result",
        "endReason:properties->>endReason",
        "stopReason:properties->>stop_reason",
        "errorCode:properties->>errorCode",
        "errorStage:properties->>errorStage",
        "latencyMs:properties->>latencyMs",
        "playbackSeconds:properties->>playbackSeconds",
        "durationSec:properties->>duration_sec",
        "voiceId:properties->>voiceId",
        "contentSource:properties->>contentSource",
        "language:properties->>language",
        "clientVersion:properties->>client_version",
    ]
    rows = []
    expected = None
    pages = 0
    exhausted = False
    wall_clock_exhausted = False
    for page in range(max_pages):
        if time.monotonic() >= deadline:
            wall_clock_exhausted = True
            break
        data, headers = postgrest_get(
            project_ref,
            key,
            [
                ("select", ",".join(fields)),
                ("received_at", f"gte.{iso(start)}"),
                ("received_at", f"lt.{iso(end)}"),
                ("event_name", f"in.({','.join(MOBILE_EVENT_NAMES)})"),
                ("order", "received_at.asc,event_id.asc"),
                ("limit", str(page_size)),
                ("offset", str(page * page_size)),
            ],
            timeout,
        )
        pages += 1
        content_range = headers.get("content-range", "")
        total = content_range.rsplit("/", 1)[-1]
        if total.isdigit():
            expected = int(total)
        rows.extend(data)
        if len(data) < page_size or (expected is not None and len(rows) >= expected):
            break
    else:
        exhausted = True
    unique = len({row.get("event_id") for row in rows if row.get("event_id")})
    complete = (
        not exhausted
        and not wall_clock_exhausted
        and (expected is None or unique == expected)
    )
    return aggregate_mobile(
        rows,
        {
            "complete": complete,
            "pages": pages,
            "expectedRowsAllEnvironments": expected,
            "returnedRowsAllEnvironments": len(rows),
            "duplicateRows": len(rows) - unique,
            "pageBudgetExhausted": exhausted,
            "wallClockBudgetSeconds": wall_clock_budget,
            "wallClockBudgetExhausted": wall_clock_exhausted,
            "tlsCertificateVerification": True,
            "source": "authenticated HTTPS PostgREST; credential values not exported",
        },
        start,
        end,
    )


def normalize_vercel_path(raw):
    path = raw.split("?", 1)[0] if isinstance(raw, str) else ""
    if path in CORE_PATHS:
        return path, CORE_PATHS[path]
    if path.startswith("/api/quickread/"):
        return "/api/quickread/[other]", "quickread"
    if path.startswith("/api/voice-clone/"):
        return "/api/voice-clone/[other]", "clone"
    return "[other_project_path]", "other"


def sanitize_vercel(record, start, end):
    timestamp = record.get("timestamp")
    if not isinstance(timestamp, (int, float)):
        return None
    observed = datetime.fromtimestamp(timestamp / 1000, timezone.utc)
    if not (start <= observed < end):
        return None
    request_id = record.get("id")
    if not isinstance(request_id, str) or not request_id:
        return None
    path, group = normalize_vercel_path(record.get("requestPath"))
    volatile = json.dumps(
        {"message": record.get("message"), "logs": record.get("logs")},
        ensure_ascii=False,
    )
    codes = [code for code, phrase in FAILURE_PHRASES.items() if phrase in volatile]
    status = record.get("responseStatusCode")
    if not codes:
        codes = [f"http_{status}_unclassified"]
    domain = str(record.get("domain") or "").lower()
    domain_class = (
        "api.castreader.ai"
        if domain == "api.castreader.ai"
        else "[vercel_deployment_domain]"
        if domain.endswith(".vercel.app")
        else "[other_or_missing_domain]"
    )
    return {
        "requestKey": hashlib.sha256(request_id.encode()).hexdigest()[:20],
        "observedAtUtc": iso(observed),
        "path": path,
        "routeGroup": group,
        "status": status,
        "deploymentId": record.get("deploymentId"),
        "domainClass": domain_class,
        "failureCodes": codes,
    }


def vercel_cache_path(cache_root, project_id, start, end):
    key = hashlib.sha256(f"{project_id}|{iso(start)}|{iso(end)}|5xx".encode()).hexdigest()
    return cache_root / "vercel-5xx" / f"{key}.json"


def collect_vercel(config, start, end, cache_root, max_queries_override=None):
    sources = config.get("sources", {})
    repo = Path(sources.get("vercelRepo", "/Users/xuxuheng/Documents/MyProject/readout-web"))
    project_file = load_json(repo / ".vercel" / "project.json")
    project_id = sources.get("vercelProjectId", "prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK")
    if project_file.get("projectId") != project_id:
        raise RuntimeError("vercel_project_mismatch")
    page_limit = int(sources.get("vercelPageLimit", 1000))
    timeout = int(sources.get("vercelTimeoutSeconds", 45))
    max_queries = int(
        max_queries_override
        if max_queries_override is not None
        else sources.get("vercelMaxQueries", 80)
    )
    wall_clock_budget = float(sources.get("vercelWallClockBudgetSeconds", 300))
    cache_safety_lag = float(sources.get("vercelCacheSafetyLagSeconds", 900))
    deadline = time.monotonic() + wall_clock_budget
    cache_root = Path(cache_root)
    query_count = 0
    pages = []
    failures = []
    rows = {}

    def query(shard_start, shard_end):
        nonlocal query_count
        cache_path = vercel_cache_path(cache_root, project_id, shard_start, shard_end)
        cacheable = shard_end <= datetime.now(timezone.utc) - timedelta(
            seconds=cache_safety_lag
        )
        if cacheable and cache_path.exists():
            cached = load_json(cache_path)
            if (
                cached.get("schema") == "castreader.vercel-5xx-shard.v1"
                and cached.get("startInclusive") == iso(shard_start)
                and cached.get("endExclusive") == iso(shard_end)
                and cached.get("complete") is True
            ):
                pages.append(
                    {
                        "startInclusive": iso(shard_start),
                        "endExclusive": iso(shard_end),
                        "returnedRows": cached.get("returnedRows"),
                        "uniqueRows": len(cached.get("records", [])),
                        "cache": "hit",
                    }
                )
                for row in cached.get("records", []):
                    rows[row["requestKey"]] = row
                return
        if time.monotonic() >= deadline:
            failures.append(
                {
                    "startInclusive": iso(shard_start),
                    "endExclusive": iso(shard_end),
                    "errorClass": "wall_clock_budget_exhausted",
                }
            )
            return
        if query_count >= max_queries:
            failures.append(
                {
                    "startInclusive": iso(shard_start),
                    "endExclusive": iso(shard_end),
                    "errorClass": "query_budget_exhausted",
                }
            )
            return
        query_count += 1
        command = [
            "vercel",
            "logs",
            "--environment",
            "production",
            "--since",
            iso(shard_start),
            "--until",
            iso(shard_end),
            "--limit",
            str(page_limit),
            "--status-code",
            "5xx",
            "--json",
        ]
        try:
            remaining = max(1, deadline - time.monotonic())
            completed = subprocess.run(
                command,
                cwd=repo,
                capture_output=True,
                text=True,
                timeout=min(timeout, remaining),
            )
        except subprocess.TimeoutExpired:
            completed = None
        if completed is None or completed.returncode:
            if (shard_end - shard_start).total_seconds() <= 2:
                failures.append(
                    {
                        "startInclusive": iso(shard_start),
                        "endExclusive": iso(shard_end),
                        "errorClass": "timeout" if completed is None else "query_failed",
                    }
                )
                return
            middle = shard_start + (shard_end - shard_start) / 2
            query(shard_start, middle)
            query(middle, shard_end)
            return
        raw = []
        for line in completed.stdout.splitlines():
            if not line.startswith("{"):
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                raw.append(value)
        if len(raw) >= page_limit:
            if (shard_end - shard_start).total_seconds() <= 2:
                failures.append(
                    {
                        "startInclusive": iso(shard_start),
                        "endExclusive": iso(shard_end),
                        "errorClass": "page_limit_reached",
                    }
                )
                return
            middle = shard_start + (shard_end - shard_start) / 2
            query(shard_start, middle)
            query(middle, shard_end)
            return
        safe = {}
        for record in raw:
            row = sanitize_vercel(record, shard_start, shard_end)
            if row is not None:
                safe[row["requestKey"]] = row
                rows[row["requestKey"]] = row
        pages.append(
            {
                "startInclusive": iso(shard_start),
                "endExclusive": iso(shard_end),
                "returnedRows": len(raw),
                "uniqueRows": len(safe),
                "cache": "miss",
            }
        )
        if cacheable:
            atomic_write_json(
                cache_path,
                {
                    "schema": "castreader.vercel-5xx-shard.v1",
                    "startInclusive": iso(shard_start),
                    "endExclusive": iso(shard_end),
                    "complete": True,
                    "returnedRows": len(raw),
                    "records": sorted(safe.values(), key=lambda row: row["observedAtUtc"]),
                },
            )

    cursor = start
    while cursor < end:
        shard_end = min(cursor + timedelta(hours=1), end)
        query(cursor, shard_end)
        cursor = shard_end
    selected = sorted(rows.values(), key=lambda row: row["observedAtUtc"])
    core = [row for row in selected if row["routeGroup"] != "other"]
    route_status = Counter((row["routeGroup"], str(row["status"])) for row in selected)
    failure_codes = Counter(
        (row["routeGroup"], code) for row in selected for code in row["failureCodes"]
    )
    deployments = Counter(str(row.get("deploymentId")) for row in core)
    return {
        "schema": "castreader.vercel-core-5xx-window.v1",
        "readOnly": True,
        "query": {
            "startInclusive": iso(start),
            "endExclusive": iso(end),
            "environment": "production",
            "statusCode": "5xx",
            "projectId": project_id,
            "queryBudget": max_queries,
            "queriesUsed": query_count,
            "wallClockBudgetSeconds": wall_clock_budget,
            "cacheSafetyLagSeconds": cache_safety_lag,
        },
        "coverage": {
            "complete": not failures,
            "successfulShards": len(pages),
            "failedShards": len(failures),
            "queryFailures": failures,
            "queryBudgetExhausted": any(
                row["errorClass"] == "query_budget_exhausted" for row in failures
            ),
            "wallClockBudgetExhausted": any(
                row["errorClass"] == "wall_clock_budget_exhausted" for row in failures
            ),
            "cacheHits": sum(page["cache"] == "hit" for page in pages),
            "cacheMisses": sum(page["cache"] == "miss" for page in pages),
            "pages": pages,
            "firstReturnedAtUtc": selected[0]["observedAtUtc"] if selected else None,
            "lastReturnedAtUtc": selected[-1]["observedAtUtc"] if selected else None,
        },
        "aggregate": {
            "unique5xxRecords": len(selected),
            "core5xxRecords": len(core),
            "otherProject5xxRecords": len(selected) - len(core),
            "routeStatusCounts": [
                {"routeGroup": group, "status": status, "count": count}
                for (group, status), count in sorted(route_status.items())
            ],
            "failureCodeCounts": [
                {"routeGroup": group, "failureCode": code, "count": count}
                for (group, code), count in sorted(failure_codes.items())
            ],
            "deploymentCounts": [
                {"deploymentId": deployment, "count": count}
                for deployment, count in sorted(deployments.items())
            ],
        },
        "limitations": [
            "Counts are unique retained Vercel request-log ids, not users or a request denominator.",
            "Vercel retention or ingestion can be incomplete even when every query shard succeeds.",
            "No raw message, nested log, request body, header, text, IP, or request id is persisted.",
        ],
    }


def source_with_error(name, function):
    try:
        return function()
    except Exception as error:
        return safe_error(name, error)


def source_available(value):
    return not (
        isinstance(value, dict)
        and value.get("schema") == "castreader.acceptance-source-error.v1"
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-file", default=str(DEFAULT_STATE))
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--cache-dir", default=str(DEFAULT_CACHE))
    parser.add_argument("--fixture-dir")
    parser.add_argument("--cutover-state", choices=["waiting_release", "observing", "window_complete"])
    parser.add_argument("--start", help="UTC ISO-8601 inclusive override")
    parser.add_argument("--end", help="UTC ISO-8601 exclusive override")
    parser.add_argument("--max-vercel-queries", type=int)
    arguments = parser.parse_args(argv)

    config = deep_override(load_json(arguments.state_file), arguments)
    validated = validate_state(config)
    generated_at = datetime.now(timezone.utc)
    if validated["state"] == "waiting_release":
        result = {
            "schema": "castreader.audio-acceptance-run.v1",
            "generatedAtUtc": iso(generated_at),
            "readOnly": True,
            "productionModified": False,
            "probeStarted": False,
            "cutoverState": "waiting_release",
            "requiredComponents": config.get("requiredComponents"),
            "sourcesQueried": [],
            "evaluation": evaluate(config, {}, now=generated_at),
            "limitations": [
                "The 24-hour clock has not started because required production releases are not all verified.",
                "automaticVerdict is scoped to configured existing sources and cannot certify the complete iOS, Android, Web and extension chain or prove every request stayed in-region.",
            ],
        }
        atomic_write_json(arguments.output, result)
        print(json.dumps({"ok": True, "verdict": "waiting_release", "sourcesQueried": 0}))
        return 0

    start = validated["window"]["start"]
    end = validated["window"]["end"]
    collection_end = min(end, generated_at)
    if collection_end <= start:
        sources = {}
        mode = "window_not_started"
    elif arguments.fixture_dir:
        fixture = Path(arguments.fixture_dir)
        sources = {
            name: load_json(fixture / f"{name}.json")
            for name in (
                "monitor_us",
                "monitor_cn",
                "mobile",
                "vercel",
                "direct_gateway",
                "global_capabilities",
                "kokoro_us",
            )
        }
        mode = "fixture"
    else:
        source_config = config.get("sources", {})
        timeout = int(source_config.get("sshTimeoutSeconds", 90))
        kokoro_timeout = int(source_config.get("kokoroSshTimeoutSeconds", 30))
        bounds = [iso(start), iso(collection_end)]
        us_host = source_config.get("usSshHost", "root@140.82.14.49")
        cn_host = source_config.get("cnSshHost", "ubuntu@106.54.47.163")
        cn_identity = os.path.expanduser(
            source_config.get("cnSshIdentity", "~/.ssh/castreader_cn_deploy")
        )
        kokoro_host = source_config.get("usKokoroSshHost", "castreader-us4090")
        remote = {
            "monitor_us": source_with_error(
                "monitor_us",
                lambda: run_remote_script(
                    [us_host], HERE / "remote_monitor_snapshot.py", ["us", *bounds], timeout
                ),
            ),
            "monitor_cn": source_with_error(
                "monitor_cn",
                lambda: run_remote_script(
                    ["-i", cn_identity, cn_host, "sudo"],
                    HERE / "remote_monitor_snapshot.py",
                    ["cn", *bounds],
                    timeout,
                ),
            ),
            "direct_gateway": source_with_error(
                "direct_gateway",
                lambda: run_remote_script(
                    [us_host], HERE / "remote_tts_gateway_snapshot.py", bounds, timeout
                ),
            ),
            "kokoro_us": source_with_error(
                "kokoro_us",
                lambda: run_remote_script(
                    [kokoro_host],
                    HERE / "remote_kokoro_identity.py",
                    [],
                    kokoro_timeout,
                ),
            ),
        }
        sources = {
            **remote,
            "mobile": source_with_error(
                "mobile", lambda: collect_mobile(config, start, collection_end)
            ),
            "global_capabilities": source_with_error(
                "global_capabilities", lambda: collect_global_capabilities(config)
            ),
            "vercel": source_with_error(
                "vercel",
                lambda: collect_vercel(
                    config,
                    start,
                    collection_end,
                    arguments.cache_dir,
                    arguments.max_vercel_queries,
                ),
            ),
        }
        mode = "live_read_only"

    evaluable_sources = {
        name: value for name, value in sources.items() if source_available(value)
    }
    evaluation = evaluate(config, evaluable_sources, now=generated_at)
    result = {
        "schema": "castreader.audio-acceptance-run.v1",
        "generatedAtUtc": iso(generated_at),
        "readOnly": True,
        "productionModified": False,
        "probeStarted": False,
        "mode": mode,
        "cutoverState": validated["state"],
        "window": {
            "startInclusive": iso(start),
            "endExclusive": iso(end),
            "configuredSeconds": int((end - start).total_seconds()),
            "collectedThroughExclusive": iso(collection_end)
            if collection_end > start
            else None,
        },
        "requiredComponents": config.get("requiredComponents"),
        "sourcesAttempted": sorted(sources),
        "sourcesReturned": sorted(evaluable_sources),
        "sources": sources,
        "evaluation": evaluation,
        "limitations": [
            "This run reads existing monitors, journals and telemetry; it starts no synthetic audio request.",
            "A production-tagged mobile event can still come from an operator or manual test.",
            "A configured 24-hour end is final for this run; the collector never extends the window automatically.",
            "automaticVerdict is scoped to configured existing sources and cannot certify the complete iOS, Android, Web and extension chain or prove every request stayed in-region.",
        ],
    }
    atomic_write_json(arguments.output, result)
    print(
        json.dumps(
            {
                "ok": True,
                "mode": mode,
                "verdict": evaluation["automaticVerdict"],
                "supplyVerdict": evaluation["supplyVerdict"],
                "clientEvidenceVerdict": evaluation["clientEvidenceVerdict"],
                "coverageVerdict": evaluation["coverageVerdict"],
                "sourcesReturned": sorted(evaluable_sources),
                "output": str(Path(arguments.output).resolve()),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
