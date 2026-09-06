#!/usr/bin/env python3
"""Read-only remote collector. Export only reviewed proxy stages/scalars/hashes."""
import collections
from contextlib import redirect_stdout
from datetime import datetime, timezone
import io
import json
import math
from pathlib import Path
import re
import sys
import types

EVENT_SCHEMA = "castreader.us-tts-origin-event.v1"
STAGES = {
    "request_received": "admission", "request_body_read": "inbound_body",
    "request_independent": "admission", "flight_created": "admission",
    "flight_joined": "coalescing", "upstream_connect_started": "connect",
    "upstream_connected": "connect", "upstream_headers": "response_headers",
    "upstream_first_body": "response_body", "upstream_complete": "response_complete",
    "upstream_cancelled": "cancellation", "upstream_failed": "upstream_failure",
    "request_failed": "request_failure", "request_finished": "completion",
}
OUTCOMES = {"incomplete", "complete", "redirect_rejected", "timeout",
            "downstream_disconnected", "cancelled", "transport_failed"}
ERROR_CLASSES = {
    "TimeoutError", "ConnectionTimeoutError", "SocketTimeoutError", "ClientConnectorError",
    "ClientConnectorDNSError", "ClientConnectorCertificateError", "ClientConnectorSSLError",
    "ServerDisconnectedError", "ClientPayloadError", "ClientConnectionResetError",
    "ConnectionResetError", "BrokenPipeError", "ConnectionError", "ClientOSError",
    "ClientResponseError", "ClientError", "OSError",
}
NUMBERS = {"elapsedMs", "connectMs", "bodyBytes", "responseBytes", "peakReplayBytes", "subscribers"}
ANONYMOUS_KEYS = ("requestKey", "flightKey", "upstreamRequestKey")


def utc(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def parse_utc(value):
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None or dt.utcoffset().total_seconds() != 0:
        raise ValueError("UTC_timestamp_required")
    return dt.timestamp()


def safe_event(value):
    if not isinstance(value, dict) or value.get("schema") != EVENT_SCHEMA:
        return None
    stage = value.get("stage")
    ts = value.get("time_unix")
    if (not isinstance(stage, str) or stage not in STAGES
            or type(ts) not in (float, int) or not math.isfinite(ts)
            or not 0 <= ts <= 253402300799):
        return None
    out = {"stage": stage, "phase": STAGES[stage], "timeUnix": ts, "atUTC": utc(ts)}
    for key in ANONYMOUS_KEYS:
        v = value.get(key)
        if isinstance(v, str) and re.fullmatch(r"[a-f0-9]{20}", v):
            out[key] = v
    for key in ("proxyReleaseId", "releaseId"):
        v = value.get(key)
        if isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", v):
            out[key] = v
    if value.get("slot") in ("blue", "green"):
        out["slot"] = value["slot"]
    for key in ("revision", "status", "attempt"):
        v = value.get(key)
        if type(v) is int and ((key == "status" and 100 <= v <= 599)
                or (key == "attempt" and 1 <= v <= 3) or (key == "revision" and v >= 0)):
            out[key] = v
    for key in NUMBERS:
        v = value.get(key)
        if type(v) in (int, float) and math.isfinite(v) and v >= 0:
            out[key] = v
    if isinstance(value.get("outcome"), str) and value["outcome"] in OUTCOMES:
        out["outcome"] = value["outcome"]
    if "errorClass" in value:
        error = value["errorClass"]
        out["errorClass"] = error if isinstance(error, str) and error in ERROR_CLASSES else "OtherException"
    return out


def percentiles(values):
    if not values:
        return {"n": 0, "median": None, "p95": None, "max": None}
    values = sorted(values)
    middle = len(values) // 2
    median = values[middle] if len(values) % 2 else (values[middle - 1] + values[middle]) / 2
    return {"n": len(values), "median": round(median, 3),
            "p95": round(values[max(0, math.ceil(len(values) * .95) - 1)], 3), "max": max(values)}


def runtime_identity(payload):
    module = types.ModuleType("audited_proxy_identity")
    exec(compile(payload["identityHelperSource"], "remote_proxy_identity.py", "exec"), module.__dict__)
    original_argv = sys.argv
    captured = io.StringIO()
    try:
        sys.argv = ["remote_proxy_identity.py", payload["expected"]["sourcePath"]]
        with redirect_stdout(captured):
            module.main()
        value = json.loads(captured.getvalue())
    finally:
        sys.argv = original_argv
    actual = value["identity"]
    expected = payload["expected"]
    issues = []
    for key in ("sourcePath", "sourceSha256", "proxyReleaseId", "revision", "currentSlot",
                "currentReleaseId", "currentReceiptSha256"):
        if actual.get(key) != expected.get(key):
            issues.append(key + "_mismatch")
    pids = actual.get("processIds")
    if pids != [expected["process"]["pid"]] or actual.get("listenerProcessIds") != pids:
        issues.append("proxy_process_listener_mismatch")
    process = module.process_metadata(expected["process"]["pid"])
    for key in ("pid", "startTicks", "cwd"):
        if process.get(key) != expected["process"].get(key):
            issues.append("proxy_process_" + key + "_mismatch")
    model = actual.get("currentModel", {})
    if model.get("runtimeSourceSha256") != expected["modelSourceSha256"]:
        issues.append("model_source_sha_mismatch")
    if model.get("listenerProcessIds") != [expected["modelProcess"]["pid"]]:
        issues.append("model_process_mismatch")
    model_process = module.process_metadata(expected["modelProcess"]["pid"])
    for key in ("pid", "startTicks", "cwd"):
        if model_process.get(key) != expected["modelProcess"].get(key):
            issues.append("model_process_" + key + "_mismatch")
    health = value.get("health", {})
    if health.get("ok") is not True or health.get("drainTrusted") is not True:
        issues.append("health_or_drain_untrusted")
    for key in ("proxyReleaseId", "revision", "currentSlot", "currentReleaseId"):
        if health.get(key) != expected.get(key):
            issues.append("health_" + key + "_mismatch")
    # Linux process creation time is separate from readiness; keep it as an
    # estimate, never replace the operator's later production confirmation.
    startup = None
    try:
        import os
        boot = int(next(line.split()[1] for line in Path("/proc/stat").read_text().splitlines()
                        if line.startswith("btime ")))
        startup = utc(boot + int(process["startTicks"]) / os.sysconf("SC_CLK_TCK"))
    except (OSError, ValueError, KeyError, StopIteration):
        pass
    supervisor_events = []
    supervisor_log = Path("/var/log/supervisor/supervisord.log")
    supervisor_size = supervisor_log.stat().st_size
    with supervisor_log.open("rb") as stream:
        stream.seek(max(0, supervisor_size - 2 * 1024 * 1024))
        if stream.tell():
            stream.readline()
        supervisor_lines = stream.read().decode(errors="replace").splitlines()
    for line in supervisor_lines:
        if not line.startswith(payload["productionActiveFromUTC"][:10]):
            continue
        if "castreader-tts-origin-proxy" not in line or "candidate" in line:
            continue
        kind = next((v for v in ("spawned", "success", "stopped", "exited") if v + ":" in line), None)
        timestamp = re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d,\d+)", line)
        pid = re.search(r"\bpid (\d+)\b", line)
        if timestamp and kind and (pid is None or int(pid.group(1)) == expected["process"]["pid"]):
            at = timestamp.group(1).replace(" ", "T").replace(",", ".") + "Z"
            if startup and parse_utc(at) < parse_utc(startup) - 2:
                continue
            supervisor_events.append({"atUTC": at, "stage": kind})
    return {"verified": not issues, "issues": issues, "identity": actual, "health": health,
            "proxyProcess": process, "estimatedProcessStartUTC": startup,
            "supervisorEvents": supervisor_events,
            "productionCoverageStartsAtUTC": payload["productionActiveFromUTC"]}


def collect(payload):
    started = datetime.now(timezone.utc)
    start = parse_utc(payload["startUTC"])
    end = parse_utc(payload["endUTC"])
    production_start = parse_utc(payload["productionActiveFromUTC"])
    if not start < end or start < production_start:
        raise ValueError("window_must_start_at_or_after_confirmed_production")
    try:
        identity = runtime_identity(payload)
    except Exception:
        # Preserve sanitized event evidence if a live identity probe is down;
        # do not print an exception value that can contain a URL/header.
        identity = {"verified": False, "issues": ["runtime_identity_read_failed"]}
    p = Path("/var/log/onstart.log")
    stat = p.stat()
    limit = payload["maxScanMiB"] * 1024 * 1024
    offset = max(0, stat.st_size - limit)
    first_any = last_any = None
    first_proxy = last_proxy = None
    stages = collections.Counter()
    phases = collections.Counter()
    outcomes = collections.Counter()
    statuses = collections.Counter()
    attempts = collections.Counter()
    failures = collections.Counter()
    error_classes = collections.Counter()
    duration = collections.defaultdict(list)
    flow_phase = {}
    requests = {}
    events = []
    failure_events = []
    unexpected_release = 0
    malformed = 0
    scanned_proxy_records = 0
    with p.open("rb") as stream:
        stream.seek(offset)
        if offset:
            stream.readline()
        while stream.tell() < stat.st_size:
            raw = stream.readline()
            # All v2 diagnostics are compact JSON; other model/user log text
            # is discarded remotely without export or content fingerprints.
            begin = raw.find(b"{")
            if begin < 0:
                continue
            try:
                value = json.loads(raw[begin:])
            except (ValueError, UnicodeError):
                continue
            ts = value.get("time_unix") if isinstance(value, dict) else None
            if type(ts) in (int, float) and math.isfinite(ts) and 0 <= ts <= 253402300799:
                first_any = ts if first_any is None else min(first_any, ts)
                last_any = ts if last_any is None else max(last_any, ts)
            if not isinstance(value, dict) or value.get("schema") != EVENT_SCHEMA:
                continue
            event = safe_event(value)
            if event is None:
                malformed += 1
                continue
            scanned_proxy_records += 1
            first_proxy = ts if first_proxy is None else min(first_proxy, ts)
            last_proxy = ts if last_proxy is None else max(last_proxy, ts)
            if not start <= ts < end:
                continue
            if event.get("proxyReleaseId") != payload["expected"]["proxyReleaseId"]:
                unexpected_release += 1
                continue
            stage = event["stage"]
            stages[stage] += 1
            phases[event["phase"]] += 1
            if "outcome" in event:
                outcomes[event["outcome"]] += 1
            if stage == "request_finished" and "status" in event:
                statuses[str(event["status"])] += 1
            if stage == "request_received":
                attempts[str(event.get("attempt", "unavailable"))] += 1
            for metric in ("connectMs", "elapsedMs"):
                if metric in event:
                    duration[stage + "." + metric].append(event[metric])
            request = (event.get("requestKey"), event.get("attempt"))
            if request[0]:
                row = requests.setdefault(request, {"requestKey": request[0], "attempt": request[1],
                    "firstUTC": event["atUTC"], "lastUTC": event["atUTC"], "receivedEvents": 0,
                    "phases": set(), "flightKeys": set(), "outcomes": collections.Counter()})
                row["lastUTC"] = event["atUTC"]
                row["receivedEvents"] += stage == "request_received"
                row["phases"].add(event["phase"])
                if "flightKey" in event:
                    row["flightKeys"].add(event["flightKey"])
                if "outcome" in event:
                    row["outcomes"][event["outcome"]] += 1
            flow = ("flight", event["flightKey"]) if event.get("flightKey") else ("request", *request)
            previous = flow_phase.get(flow, "unknown_before_window")
            if stage in ("upstream_failed", "request_failed"):
                # A shared producer failure also triggers each caller failure;
                # distinguish producers from caller observations in counts.
                scope = "shared_producer" if stage == "upstream_failed" else (
                    "shared_caller" if "flightKey" in event else "independent_caller")
                event["failureScope"] = scope
                event["lastObservedUpstreamPhase"] = previous
                failures[scope + ":" + previous] += 1
                error_classes[event.get("errorClass", "unavailable")] += 1
                if len(failure_events) < payload["maxEvents"]:
                    failure_events.append(event)
            if stage in ("flight_created", "request_independent"):
                flow_phase[flow] = "upstream_request_created"
            elif stage == "upstream_connect_started":
                flow_phase[flow] = "connecting"
            elif stage == "upstream_connected":
                flow_phase[flow] = "waiting_response_headers"
            elif stage in ("upstream_headers", "upstream_first_body"):
                flow_phase[flow] = "receiving_response_body"
            elif stage == "upstream_complete":
                flow_phase[flow] = "upstream_body_complete"
            if payload["includeEvents"] and len(events) < payload["maxEvents"]:
                events.append(event)
    read_at = datetime.now(timezone.utc)
    issues = []
    if offset and (first_any is None or first_any > start):
        issues.append("scan_budget_does_not_cover_window_start")
    if read_at.timestamp() < end:
        issues.append("window_end_is_in_future")
    if unexpected_release:
        issues.append("unexpected_proxy_release_events_in_window")
    if malformed:
        issues.append("malformed_proxy_events_seen_in_scanned_log")
    joined = stages["flight_joined"]
    shared = stages["flight_created"] + joined
    admitted = shared + stages["request_independent"]
    anonymous = []
    for row in requests.values():
        row["phases"] = sorted(row["phases"])
        row["flightKeys"] = sorted(row["flightKeys"])
        row["ambiguousRepeatedRequestKey"] = row["receivedEvents"] > 1
        if len(anonymous) < payload["maxRequests"]:
            anonymous.append(row)
    return {"schema": "castreader.us-proxy-event-window.v1", "readOnly": True,
            "productionModified": False, "synthesisStarted": False, "rawUserDataExported": False,
            "window": {"startUTC": utc(start), "endUTCExclusive": utc(end),
                       "productionActiveFromUTC": utc(production_start)},
            "collectedAtUTC": read_at.isoformat(), "collectionStartedAtUTC": started.isoformat(),
            "identityAndCoverageVerified": identity["verified"] and not issues,
            "runtime": identity,
            "coverage": {"complete": not issues, "issues": issues, "filePath": str(p),
                         "fileBytesAtRead": stat.st_size, "fileInode": stat.st_ino,
                         "scanStartOffset": offset, "bytesScanned": stat.st_size - offset,
                         "firstAnyStructuredUTC": utc(first_any) if first_any else None,
                         "lastAnyStructuredUTC": utc(last_any) if last_any else None,
                         "firstProxyEventUTC": utc(first_proxy) if first_proxy else None,
                         "lastProxyEventUTC": utc(last_proxy) if last_proxy else None,
                         "scannedProxyEventCount": scanned_proxy_records,
                         "unexpectedReleaseEvents": unexpected_release},
            "counts": {"stages": stages, "phases": phases, "finishedOutcomes": outcomes,
                       "finishedReportedStatuses": statuses, "receivedAttempts": attempts,
                       "failureScopesAndLastObservedPhases": failures, "errorClasses": error_classes},
            "coalescing": {"sharedProducersCreated": stages["flight_created"], "callersJoined": joined,
                           "independentCallers": stages["request_independent"],
                           "joinFractionOfSharedAdmissions": joined / shared if shared else None,
                           "joinFractionOfAllAdmissions": joined / admitted if admitted else None,
                           "denominatorNote": "Admission events in this window, not a completed-request cohort."},
            "stageTimingMilliseconds": {k: percentiles(v) for k, v in duration.items()},
            "failureEvents": failure_events, "failureEventsTruncated": sum(failures.values()) > len(failure_events),
            "anonymousRequests": anonymous, "anonymousRequestsTruncated": len(requests) > len(anonymous),
            "events": events, "eventsIncluded": payload["includeEvents"],
            "eventsTruncated": payload["includeEvents"] and sum(stages.values()) > len(events),
            "limitations": [
                "Runtime identity is checked at collection time; event rows contain release/slot/revision but no PID or source SHA.",
                "Candidate and production used the same release ID; collection rejects windows before the confirmed production time.",
                "Process-start/Supervisor timestamps are retained as earlier startup evidence, never as the production-coverage start.",
                "An upstream body completion proves HTTP bytes completed, not decoded audio quality or client playback completion.",
                "connect/header/body phases cannot separate ASGI queue, language lock, G2P and model inference time.",
                "Reused connections emit no connect-start/connect-end events; upstream_request_created alone does not locate a transport stall.",
                "Shared producer failures and shared caller failures are distinct observations of the same underlying failure.",
                "Client cancellation and upstream cancellation after final subscriber departure are reported separately from failures.",
                "Requests crossing the window boundary or reusing the same anonymous key may lack a unique full lifecycle.",
                "No-event windows or a zero merge rate are not proof of user playback reliability; logs may be delayed before persistence.",
            ]}
