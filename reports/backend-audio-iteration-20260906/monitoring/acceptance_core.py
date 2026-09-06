#!/usr/bin/env python3
"""Pure aggregation and conservative acceptance evaluation helpers."""

from __future__ import annotations

from collections import Counter
from datetime import datetime, timezone
import math
import re


VALID_CUTOVER_STATES = {"waiting_release", "observing", "window_complete"}
REQUIRED_COMPONENT_NAMES = {"globalGateway", "directGateway", "usKokoro"}
SAFE_CODE = re.compile(r"^[a-z][a-z0-9_]{0,69}$")
SAFE_VERSION = re.compile(r"^[0-9A-Za-z._+-]{1,32}$")
SAFE_LANGUAGE = re.compile(r"^[a-z]{2,3}(?:-[a-z]{2,4})?$")
DEPLOYMENT_ID = re.compile(r"^dpl_[A-Za-z0-9]+$")
COMMIT_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
KOKORO_RELEASE = re.compile(
    r"^/workspace/castreader-runtime/releases/[0-9A-Za-z._-]+$"
)
MOBILE_EVENTS = {
    "read_start",
    "read_first_audio",
    "read_milestone",
    "read_end",
    "explain_start",
    "explain_first_block",
    "explain_milestone",
    "explain_end",
}


def parse_utc(value):
    if not isinstance(value, str):
        raise ValueError("timestamp_must_be_string")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp_requires_timezone")
    return parsed.astimezone(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def nearest_rank(values, quantile):
    ordered = sorted(float(value) for value in values if value is not None)
    if not ordered:
        return None
    return round(ordered[max(0, math.ceil(len(ordered) * quantile) - 1)], 3)


def distribution(values):
    values = [float(value) for value in values if value is not None]
    return {
        "samples": len(values),
        "p50": nearest_rank(values, 0.50),
        "p95": nearest_rank(values, 0.95),
        "max": round(max(values), 3) if values else None,
    }


def safe_code(value):
    if value is None or value == "":
        return "unspecified"
    value = str(value).lower()
    return value if SAFE_CODE.fullmatch(value) else "unclassified_format"


def safe_version(value):
    if value is None or value == "":
        return "unknown"
    value = str(value)
    return value if SAFE_VERSION.fullmatch(value) else "other"


def safe_language(value):
    if value is None or value == "":
        return "unknown"
    value = str(value).lower().replace("_", "-")
    return value if SAFE_LANGUAGE.fullmatch(value) else "other"


def safe_platform(value):
    value = str(value or "unknown").lower()
    return value if value in {"ios", "android"} else "other"


def safe_route(value):
    value = str(value or "unknown").lower()
    return value if value in {"global", "cn", "unknown"} else "other"


def safe_source(value):
    value = str(value or "unknown").lower()
    allowed = {
        "camera",
        "photo_library",
        "file",
        "url",
        "text",
        "clipboard",
        "share_sheet",
        "history",
        "kindle",
        "weread",
        "google_books",
        "kobo",
        "oreilly",
        "youtube_android",
        "unknown",
    }
    return value if value in allowed else "other"


def voice_family(value):
    value = str(value or "")
    if value.startswith("vc_"):
        return "clone"
    if re.fullmatch(r"[a-z]{2}_[a-z0-9_]{1,30}", value):
        return "preset"
    return "unknown"


def number(value):
    try:
        parsed = float(value)
        return parsed if math.isfinite(parsed) else None
    except (TypeError, ValueError):
        return None


def canonical_mobile_row(row):
    event = str(row.get("eventName") or row.get("event_name") or "")
    if event not in MOBILE_EVENTS:
        return None
    received_at = parse_utc(row.get("received_at"))
    environment = str(row.get("environment") or "unknown").lower()
    result = safe_code(row.get("result"))
    end_reason = safe_code(row.get("endReason") or row.get("stopReason"))
    error_code = safe_code(row.get("errorCode"))
    error_stage = safe_code(row.get("errorStage"))
    return {
        "eventId": row.get("event_id"),
        "deviceId": row.get("analytics_anonymous_id"),
        "event": event,
        "receivedAt": received_at,
        "environment": environment,
        "platform": safe_platform(row.get("client_platform") or row.get("platform")),
        "clientRoute": safe_route(row.get("serviceRoute")),
        "ingressRoute": safe_route(row.get("ingressRoute")),
        "routeMismatch": str(row.get("routeMismatch")).lower() == "true",
        "readSession": row.get("readSession"),
        "explainSession": row.get("explainSession"),
        "result": result,
        "endReason": end_reason,
        "errorCode": error_code,
        "errorStage": error_stage,
        "voiceFamily": voice_family(row.get("voiceId")),
        "contentSource": safe_source(row.get("contentSource")),
        "clientVersion": safe_version(row.get("clientVersion")),
        "language": safe_language(row.get("language")),
        "latencyMs": number(row.get("latencyMs")),
        "playbackSeconds": number(row.get("playbackSeconds") or row.get("durationSec")),
    }


def is_quota_block(row):
    joined = f"{row['result']} {row['endReason']} {row['errorCode']}"
    return row["result"] == "blocked" and ("quota" in joined or "limit" in joined)


def is_cancelled(row):
    return row["result"] in {"cancelled", "canceled"} or row["endReason"] in {
        "user_stop",
        "user_stopped",
        "user_cancel",
        "user_cancelled",
        "view_closed",
        "reader_closed",
        "mode_switch",
        "navigation",
        "navigated_away",
    }


def is_technical_failure(row):
    if row["event"] not in {"read_end", "explain_end"}:
        return False
    if is_quota_block(row) or is_cancelled(row):
        return False
    return row["result"] in {"failed", "error"}


def aggregate_mobile(rows, query_coverage, start, end):
    deduped = {}
    invalid = 0
    for raw in rows:
        try:
            row = canonical_mobile_row(raw)
        except (ValueError, TypeError):
            invalid += 1
            continue
        if row is None or not (start <= row["receivedAt"] < end):
            continue
        key = row["eventId"]
        if not isinstance(key, str) or not key:
            invalid += 1
            continue
        deduped[key] = row

    all_rows = sorted(deduped.values(), key=lambda row: row["receivedAt"])
    production = [row for row in all_rows if row["environment"] == "production"]
    excluded = len(all_rows) - len(production)
    groups = Counter(
        (
            row["event"],
            row["platform"],
            row["clientRoute"],
            row["ingressRoute"],
            row["result"],
            row["endReason"],
            row["errorCode"],
            row["errorStage"],
            row["voiceFamily"],
            row["contentSource"],
            row["clientVersion"],
            row["language"],
        )
        for row in production
    )
    devices = {row["deviceId"] for row in production if row["deviceId"]}
    starts = Counter(
        row["platform"]
        for row in production
        if row["event"] in {"read_start", "explain_start"}
    )
    read_starts = Counter(
        row["platform"] for row in production if row["event"] == "read_start"
    )
    explain_starts = Counter(
        row["platform"] for row in production if row["event"] == "explain_start"
    )
    technical = [row for row in production if is_technical_failure(row)]
    quota = [row for row in production if is_quota_block(row)]
    cancelled = [row for row in production if is_cancelled(row)]
    blocked_other = [
        row
        for row in production
        if row["result"] == "blocked" and not is_quota_block(row)
    ]

    session_maps = {"read": {}, "explain": {}}
    missing_session_starts = {"read": Counter(), "explain": Counter()}
    for row in production:
        if row["event"].startswith("read_"):
            kind, field_name = "read", "readSession"
        elif row["event"].startswith("explain_"):
            kind, field_name = "explain", "explainSession"
        else:
            continue
        session_id = row[field_name]
        if not session_id:
            if row["event"] == f"{kind}_start":
                missing_session_starts[kind][row["platform"]] += 1
            continue
        key = (row["platform"], row["deviceId"] or "missing_device", session_id)
        session_maps[kind].setdefault(key, []).append(row)

    def cohort_summary(started, start_event, first_event, end_event):
        evidence = []
        for values in started:
            first_start_at = min(
                row["receivedAt"] for row in values if row["event"] == start_event
            )
            has_first_output = any(
                row["event"] == first_event and row["receivedAt"] >= first_start_at
                for row in values
            )
            family = next(
                (
                    row["voiceFamily"]
                    for row in values
                    if row["event"] == start_event and row["voiceFamily"] != "unknown"
                ),
                "unknown",
            )
            evidence.append((values, has_first_output, family))
        paired_families = Counter(
            family for _values, has_first_output, family in evidence if has_first_output
        )
        return {
            "startedSessions": len(evidence),
            "withFirstOutput": sum(has_first for _values, has_first, _family in evidence),
            "withoutFirstOutputInsideWindow": sum(
                not has_first for _values, has_first, _family in evidence
            ),
            "withEnd": sum(
                any(row["event"] == end_event for row in values)
                for values, _has_first, _family in evidence
            ),
            "withTechnicalFailure": sum(
                any(is_technical_failure(row) for row in values)
                for values, _has_first, _family in evidence
            ),
            "withQuotaBlock": sum(
                any(is_quota_block(row) for row in values)
                for values, _has_first, _family in evidence
            ),
            "withoutEndInsideWindow": sum(
                not any(row["event"] == end_event for row in values)
                for values, _has_first, _family in evidence
            ),
            "pairedFirstOutputByVoiceFamily": dict(sorted(paired_families.items())),
        }

    cohorts = {}
    for kind, sessions in session_maps.items():
        start_event = f"{kind}_start"
        first_event = "read_first_audio" if kind == "read" else "explain_first_block"
        end_event = f"{kind}_end"
        started = [
            values
            for values in sessions.values()
            if any(row["event"] == start_event for row in values)
        ]
        summary = cohort_summary(started, start_event, first_event, end_event)
        platforms = sorted(
            {row["platform"] for values in started for row in values}
            | set(missing_session_starts[kind])
        )
        summary["byPlatform"] = {
            platform: {
                **cohort_summary(
                    [
                        values
                        for values in started
                        if any(row["platform"] == platform for row in values)
                    ],
                    start_event,
                    first_event,
                    end_event,
                ),
                "startEventsMissingSessionId": int(
                    missing_session_starts[kind].get(platform, 0)
                ),
            }
            for platform in platforms
        }
        summary["startEventsMissingSessionId"] = sum(
            missing_session_starts[kind].values()
        )
        cohorts[kind] = summary

    session_evidence_by_platform = {}
    all_platforms = set(starts)
    all_platforms.update(
        platform
        for cohort in cohorts.values()
        for platform in cohort.get("byPlatform", {})
    )
    for platform in sorted(all_platforms):
        per_kind = [
            cohort.get("byPlatform", {}).get(platform, {})
            for cohort in cohorts.values()
        ]
        paired_families = Counter()
        for item in per_kind:
            paired_families.update(item.get("pairedFirstOutputByVoiceFamily", {}))
        session_evidence_by_platform[platform] = {
            "startedSessions": sum(int(item.get("startedSessions") or 0) for item in per_kind),
            "withFirstOutput": sum(int(item.get("withFirstOutput") or 0) for item in per_kind),
            "withoutFirstOutputInsideWindow": sum(
                int(item.get("withoutFirstOutputInsideWindow") or 0) for item in per_kind
            ),
            "startEventsMissingSessionId": sum(
                int(item.get("startEventsMissingSessionId") or 0) for item in per_kind
            ),
            "pairedFirstOutputByVoiceFamily": dict(sorted(paired_families.items())),
        }

    return {
        "schema": "castreader.mobile-funnel-acceptance.v1",
        "readOnly": True,
        "query": {"startInclusive": iso(start), "endExclusive": iso(end)},
        "coverage": {
            **query_coverage,
            "invalidSelectedRows": invalid,
            "uniqueSelectedRowsAllEnvironments": len(all_rows),
            "productionTaggedRows": len(production),
            "nonProductionRowsExcluded": excluded,
            "firstProductionReceivedAt": iso(production[0]["receivedAt"]) if production else None,
            "lastProductionReceivedAt": iso(production[-1]["receivedAt"]) if production else None,
            "serverClockColumn": "received_at",
            "productionTagCannotExcludeManualTests": True,
        },
        "aggregate": {
            "events": len(production),
            "devices": len(devices),
            "startEventsByPlatform": dict(sorted(starts.items())),
            "readStartsByPlatform": dict(sorted(read_starts.items())),
            "explainStartsByPlatform": dict(sorted(explain_starts.items())),
            "technicalFailureEvents": len(technical),
            "technicalFailuresByPlatform": dict(
                sorted(Counter(row["platform"] for row in technical).items())
            ),
            "quotaBlockedEvents": len(quota),
            "quotaBlockedByPlatform": dict(
                sorted(Counter(row["platform"] for row in quota).items())
            ),
            "cancelledEvents": len(cancelled),
            "otherBlockedEvents": len(blocked_other),
            "routeMismatchEvents": sum(row["routeMismatch"] for row in production),
            "firstOutputLatencyMs": {
                platform: distribution(
                    [
                        row["latencyMs"]
                        for row in production
                        if row["platform"] == platform
                        and row["event"] in {"read_first_audio", "explain_first_block"}
                    ]
                )
                for platform in ("ios", "android")
            },
            "sessionCohorts": cohorts,
            "sessionEvidenceByPlatform": session_evidence_by_platform,
            "groups": [
                {
                    "event": key[0],
                    "platform": key[1],
                    "clientRoute": key[2],
                    "ingressRoute": key[3],
                    "result": key[4],
                    "endReason": key[5],
                    "errorCode": key[6],
                    "errorStage": key[7],
                    "voiceFamily": key[8],
                    "contentSource": key[9],
                    "clientVersion": key[10],
                    "language": key[11],
                    "count": count,
                }
                for key, count in sorted(groups.items())
            ],
        },
        "limitations": [
            "Only server-clocked mobile_funnel_events.received_at is used.",
            "production is a validated client event label, but production traffic can still include operator or manual tests.",
            "Starts and ends inside the bounded window are not a cohort completion rate for sessions crossing a boundary.",
            "A start without a later first-output event inside the same window is an evidence gap, not by itself a technical failure; the session may cross the window boundary.",
            "Device counts are installations, not verified people.",
        ],
    }


def validate_state(config):
    state = config.get("cutoverState")
    if state not in VALID_CUTOVER_STATES:
        raise ValueError("invalid_cutover_state")
    required_seconds = int(config.get("window", {}).get("requiredSeconds", 86_400))
    if required_seconds <= 0:
        raise ValueError("invalid_required_seconds")
    components = config.get("requiredComponents", {})
    if not isinstance(components, dict) or not components:
        raise ValueError("required_components_missing")
    missing_components = sorted(REQUIRED_COMPONENT_NAMES - set(components))
    if missing_components:
        raise ValueError(f"required_components_missing:{','.join(missing_components)}")
    if any(not isinstance(value, dict) for value in components.values()):
        raise ValueError("required_component_must_be_object")
    unverified = [name for name, value in components.items() if not value.get("verified")]
    component_times = {}
    for name, value in components.items():
        if not value.get("verified"):
            continue
        version = value.get("version")
        if not isinstance(version, str) or not version:
            raise ValueError(f"verified_component_version_missing:{name}")
        active_from = parse_utc(value.get("activeFromUtc"))
        verified_at = parse_utc(value.get("verifiedAtUtc"))
        if verified_at < active_from:
            raise ValueError(f"component_verified_before_active:{name}")
        if name == "globalGateway":
            if not DEPLOYMENT_ID.fullmatch(version):
                raise ValueError("global_gateway_deployment_id_invalid")
            if not COMMIT_SHA.fullmatch(str(value.get("sourceCommit") or "")):
                raise ValueError("global_gateway_source_commit_invalid")
        elif name == "directGateway":
            if not COMMIT_SHA.fullmatch(version):
                raise ValueError("direct_gateway_source_commit_invalid")
            if not SHA256.fullmatch(str(value.get("runtimeSourceSha256") or "")):
                raise ValueError("direct_gateway_runtime_source_invalid")
        elif name == "usKokoro":
            if not COMMIT_SHA.fullmatch(version):
                raise ValueError("kokoro_source_commit_invalid")
            if not KOKORO_RELEASE.fullmatch(str(value.get("runtimeReleasePath") or "")):
                raise ValueError("kokoro_runtime_release_path_invalid")
            if not SHA256.fullmatch(str(value.get("runtimeSourceSha256") or "")):
                raise ValueError("kokoro_runtime_source_invalid")
        component_times[name] = (active_from, verified_at)
    if state == "waiting_release":
        return {
            "state": state,
            "requiredSeconds": required_seconds,
            "unverifiedComponents": unverified,
            "window": None,
            "components": components,
        }
    if unverified:
        raise ValueError("observation_cannot_start_with_unverified_components")
    start = parse_utc(config.get("window", {}).get("startUtc"))
    end = parse_utc(config.get("window", {}).get("endUtc"))
    if end <= start:
        raise ValueError("end_must_follow_start")
    active_times = [
        (name, times[0]) for name, times in component_times.items()
    ]
    ready_times = [
        (name, times[1]) for name, times in component_times.items()
    ]
    latest_component, latest_active = max(active_times, key=lambda item: item[1])
    latest_ready_component, latest_ready = max(ready_times, key=lambda item: item[1])
    history = []
    raw_history = config.get("releaseHistory", [])
    if not isinstance(raw_history, list):
        raise ValueError("release_history_must_be_array")
    for entry in raw_history:
        component = entry.get("component")
        version = entry.get("version")
        if component not in components or not isinstance(version, str) or not version:
            raise ValueError("invalid_release_history_entry")
        active_from = parse_utc(entry.get("activeFromUtc"))
        verified_at = parse_utc(entry.get("verifiedAtUtc"))
        if verified_at < active_from:
            raise ValueError("release_history_verified_before_active")
        history.append(
            {
                "component": component,
                "version": version,
                "activeFrom": active_from,
                "verifiedAt": verified_at,
            }
        )
    for component, value in components.items():
        current_active = parse_utc(value["activeFromUtc"])
        current_version = value["version"]
        if not any(
            entry["component"] == component
            and entry["version"] == current_version
            and entry["activeFrom"] == current_active
            for entry in history
        ):
            history.append(
                {
                    "component": component,
                    "version": current_version,
                    "activeFrom": current_active,
                    "verifiedAt": parse_utc(value["verifiedAtUtc"]),
                }
            )

    version_segments = {}
    transitions_in_window = []
    for component in sorted(components):
        entries = sorted(
            (entry for entry in history if entry["component"] == component),
            key=lambda entry: entry["activeFrom"],
        )
        boundaries = [start]
        boundaries.extend(
            entry["activeFrom"] for entry in entries if start < entry["activeFrom"] < end
        )
        boundaries.append(end)
        boundaries = sorted(set(boundaries))
        component_segments = []
        for segment_start, segment_end in zip(boundaries, boundaries[1:]):
            active = [entry for entry in entries if entry["activeFrom"] <= segment_start]
            chosen = active[-1] if active else None
            component_segments.append(
                {
                    "startUtc": iso(segment_start),
                    "endUtc": iso(segment_end),
                    "seconds": int((segment_end - segment_start).total_seconds()),
                    "version": chosen["version"] if chosen else "unknown_before_first_recorded_release",
                }
            )
        version_segments[component] = component_segments
        transitions_in_window.extend(
            {
                "component": component,
                "version": entry["version"],
                "activeFromUtc": iso(entry["activeFrom"]),
                "verifiedAtUtc": iso(entry["verifiedAt"]),
            }
            for entry in entries
            if start < entry["activeFrom"] < end
        )
    return {
        "state": state,
        "requiredSeconds": required_seconds,
        "unverifiedComponents": [],
        "window": {"start": start, "end": end},
        "components": components,
        "latestComponent": latest_component,
        "latestComponentActiveFrom": latest_active,
        "latestReadyComponent": latest_ready_component,
        "latestReadyAt": latest_ready,
        "versionSegments": version_segments,
        "transitionsInWindow": sorted(
            transitions_in_window, key=lambda item: (item["activeFromUtc"], item["component"])
        ),
    }


def issue(code, source, detail):
    return {"code": code, "source": source, "detail": detail}


def evidence_limitations(mobile=None):
    limitations = [
        issue(
            "automatic_verdict_scoped_to_configured_sources",
            "evaluation",
            "automaticVerdict assesses only the configured, successfully collected sources; it does not certify the complete iOS, Android, Web and extension chain or prove every request stayed in-region.",
        ),
        issue(
            "web_client_events_not_collected",
            "mobile",
            "No Web client start-to-first-output session telemetry is collected by this tool.",
        ),
        issue(
            "extension_client_events_not_collected",
            "mobile",
            "No extension client start-to-first-output session telemetry is collected by this tool.",
        ),
        issue(
            "first_output_is_not_playback_completion",
            "mobile",
            "A paired first-output event proves initial output only; it does not prove that the whole document played to completion.",
        ),
    ]
    aggregate = mobile.get("aggregate", {}) if isinstance(mobile, dict) else {}
    cohorts = aggregate.get("sessionCohorts", {})
    read = cohorts.get("read", {})
    explain = cohorts.get("explain", {})
    clone_pairs = sum(
        int(cohort.get("pairedFirstOutputByVoiceFamily", {}).get("clone", 0) or 0)
        for cohort in (read, explain)
    )
    if clone_pairs == 0:
        limitations.append(
            issue(
                "clone_first_output_evidence_absent_or_unattributed",
                "mobile",
                "No same-window mobile start-to-first-output session was attributed to a clone voice; this is an evidence limitation, not a clone failure.",
            )
        )
    else:
        limitations.append(
            issue(
                "clone_evidence_limited_to_mobile_funnel",
                "mobile",
                f"{clone_pairs} same-window clone start-to-first-output session(s) were observed, without Web/extension or full-playback certification.",
            )
        )
    explain_pairs = int(explain.get("withFirstOutput") or 0)
    if explain_pairs == 0:
        limitations.append(
            issue(
                "explain_first_output_evidence_absent",
                "mobile",
                "No same-window mobile explain start-to-first-block session was observed; this is an evidence limitation, not an Explain failure.",
            )
        )
    else:
        limitations.append(
            issue(
                "explain_evidence_limited_to_mobile_funnel",
                "mobile",
                f"{explain_pairs} same-window Explain start-to-first-block session(s) were observed, without Web/extension or full-playback certification.",
            )
        )
    return limitations


def evaluate(config, sources, now=None):
    now = now or datetime.now(timezone.utc)
    state = validate_state(config)
    if state["state"] == "waiting_release":
        return {
            "verdictScope": "configured_existing_sources_only",
            "automaticVerdict": "waiting_release",
            "supplyVerdict": "waiting_release",
            "clientEvidenceVerdict": "waiting_release",
            "coverageVerdict": "waiting_release",
            "windowStarted": False,
            "observationSeconds": 0,
            "requiredObservationSeconds": state["requiredSeconds"],
            "unverifiedComponents": state["unverifiedComponents"],
            "technicalFailures": [],
            "dataOrCoverageGaps": [],
            "sampleGaps": [],
            "advisories": [],
            "evidenceLimitations": evidence_limitations(),
            "note": "No 24-hour observation time accrues before every required release is verified.",
        }

    start = state["window"]["start"]
    end = state["window"]["end"]
    duration = (end - start).total_seconds()
    observed_end = min(now, end)
    elapsed = max(0, (observed_end - start).total_seconds())
    required = state["requiredSeconds"]
    policy = config.get("policy", {})
    boundary_limit = float(policy.get("monitorMaxBoundaryLagSeconds", 900))
    gap_limit = float(policy.get("monitorMaxObservedGapSeconds", 900))
    technical = []
    data_gaps = []
    sample_gaps = []
    advisories = []

    if start > now:
        data_gaps.append(issue("window_start_in_future", "state", iso(start)))
    if state["state"] == "window_complete" and end > now:
        data_gaps.append(issue("window_closed_before_end", "state", iso(end)))
    if duration < required:
        data_gaps.append(
            issue("observation_window_incomplete", "state", f"{int(duration)}/{required} seconds")
        )
    if state["state"] != "window_complete" and end <= now:
        data_gaps.append(issue("cutover_state_not_closed", "state", state["state"]))

    latest_active = state["latestComponentActiveFrom"]
    latest_ready = state["latestReadyAt"]
    final_version_seconds = max(
        0, (observed_end - max(start, latest_ready)).total_seconds()
    )
    mixed_version = latest_active > start
    if final_version_seconds < required:
        sample_gaps.append(
            issue(
                "final_version_observation_incomplete",
                "state",
                f"latest={state['latestReadyComponent']}; observed={int(final_version_seconds)}s; required={required}s",
            )
        )

    monitors_healthy = True
    for region in ("us", "cn"):
        source_name = f"monitor_{region}"
        monitor = sources.get(source_name)
        if not monitor:
            monitors_healthy = False
            data_gaps.append(issue("source_missing", source_name, "collector returned no document"))
            continue
        coverage = monitor.get("coverage", {})
        aggregate = monitor.get("aggregate", {})
        source = monitor.get("source", {})
        if not coverage.get("completeRead"):
            monitors_healthy = False
            data_gaps.append(issue("monitor_read_incomplete", source_name, "invalid/conflicting result files"))
        cycles = int(aggregate.get("cycles") or 0)
        if cycles == 0:
            monitors_healthy = False
            data_gaps.append(issue("monitor_no_cycles", source_name, "zero persisted cycles"))
            continue
        first_lag = source.get("windowStartToFirstSelectedSeconds")
        last_lag = source.get("lastSelectedToWindowEndSeconds")
        largest_gap = aggregate.get("largestObservedGapSeconds")
        if first_lag is None or first_lag > boundary_limit:
            monitors_healthy = False
            data_gaps.append(issue("monitor_start_watermark_gap", source_name, str(first_lag)))
        if last_lag is None or last_lag > boundary_limit:
            monitors_healthy = False
            data_gaps.append(issue("monitor_end_watermark_gap", source_name, str(last_lag)))
        if largest_gap is not None and largest_gap > gap_limit:
            monitors_healthy = False
            data_gaps.append(issue("monitor_cadence_gap", source_name, str(largest_gap)))
        status_counts = aggregate.get("statusCounts", {})
        supply_failures = int(status_counts.get("supply_failed", 0))
        region_mismatches = int(aggregate.get("regionMismatchCycles") or 0)
        incomplete_audio = cycles - int(aggregate.get("completeRemainderDecodedCycles") or 0)
        if supply_failures:
            monitors_healthy = False
            technical.append(issue("monitor_supply_failure", source_name, str(supply_failures)))
        if region_mismatches:
            monitors_healthy = False
            technical.append(issue("monitor_region_mismatch", source_name, str(region_mismatches)))
        if incomplete_audio:
            monitors_healthy = False
            technical.append(issue("monitor_incomplete_audio", source_name, str(incomplete_audio)))
        alignment = int(aggregate.get("alignmentDegradationCycles") or 0)
        if alignment:
            advisories.append(issue("alignment_degraded_audio_preserved", source_name, str(alignment)))
        timer = monitor.get("systemd", {}).get("timer", {})
        if timer.get("ActiveState") != "active" or timer.get("UnitFileState") != "enabled":
            monitors_healthy = False
            data_gaps.append(issue("monitor_timer_not_active", source_name, str(timer)))

    mobile = sources.get("mobile")
    mobile_technical_failures = 0
    mobile_sample_adequate = True
    if not mobile:
        data_gaps.append(issue("source_missing", "mobile", "collector returned no document"))
        mobile_sample_adequate = False
    else:
        coverage = mobile.get("coverage", {})
        aggregate = mobile.get("aggregate", {})
        if not coverage.get("complete"):
            data_gaps.append(issue("mobile_query_incomplete", "mobile", str(coverage.get("errorCode"))))
        if int(coverage.get("invalidSelectedRows") or 0):
            data_gaps.append(issue("mobile_invalid_rows", "mobile", str(coverage["invalidSelectedRows"])))
        mobile_technical_failures = int(aggregate.get("technicalFailureEvents") or 0)
        if mobile_technical_failures:
            technical.append(issue("client_technical_failure", "mobile", str(mobile_technical_failures)))
        route_mismatches = int(aggregate.get("routeMismatchEvents") or 0)
        if route_mismatches:
            technical.append(issue("client_region_mismatch", "mobile", str(route_mismatches)))
        quota = int(aggregate.get("quotaBlockedEvents") or 0)
        if quota:
            advisories.append(issue("business_quota_blocked_separate", "mobile", str(quota)))
        cancelled = int(aggregate.get("cancelledEvents") or 0)
        if cancelled:
            advisories.append(issue("client_cancelled_separate", "mobile", str(cancelled)))
        blocked_other = int(aggregate.get("otherBlockedEvents") or 0)
        if blocked_other:
            advisories.append(
                issue(
                    "other_blocked_events_separate_review",
                    "mobile",
                    str(blocked_other),
                )
            )
        minimum = policy.get("minimumProductionStartsByPlatform", {"ios": 1, "android": 1})
        starts = aggregate.get("readStartsByPlatform", {})
        read_cohorts = aggregate.get("sessionCohorts", {}).get("read", {})
        read_by_platform = read_cohorts.get("byPlatform", {})
        for platform, expected in minimum.items():
            observed = int(starts.get(platform, 0))
            if observed < int(expected):
                mobile_sample_adequate = False
                sample_gaps.append(
                    issue(
                        "mobile_read_start_sample_insufficient",
                        "mobile",
                        f"{platform}:{observed}/{int(expected)}",
                    )
                )
            platform_cohort = read_by_platform.get(platform, {})
            paired = int(platform_cohort.get("withFirstOutput") or 0)
            if paired == 0:
                mobile_sample_adequate = False
                sample_gaps.append(
                    issue(
                        "mobile_read_first_output_sample_missing",
                        "mobile",
                        f"{platform}:0 same-window read start-to-first-audio sessions",
                    )
                )
            without_first = int(
                platform_cohort.get("withoutFirstOutputInsideWindow") or 0
            )
            if without_first:
                mobile_sample_adequate = False
                sample_gaps.append(
                    issue(
                        "mobile_read_start_without_first_output",
                        "mobile",
                        f"{platform}:{without_first}; boundary sessions are not classified as technical failures",
                    )
                )
            missing_session_id = int(
                platform_cohort.get("startEventsMissingSessionId") or 0
            )
            if missing_session_id:
                mobile_sample_adequate = False
                sample_gaps.append(
                    issue(
                        "mobile_read_start_missing_session_id",
                        "mobile",
                        f"{platform}:{missing_session_id}; cannot pair start with first audio",
                    )
                )

    vercel = sources.get("vercel")
    if not vercel:
        data_gaps.append(issue("source_missing", "vercel", "collector returned no document"))
    else:
        if not vercel.get("coverage", {}).get("complete"):
            data_gaps.append(issue("vercel_query_incomplete", "vercel", "one or more shards failed or truncated"))
        core_failures = int(vercel.get("aggregate", {}).get("core5xxRecords") or 0)
        if core_failures:
            technical.append(issue("vercel_core_5xx", "vercel", str(core_failures)))
        expected_deployment = state["components"].get("globalGateway", {}).get("version")
        unexpected = [
            row
            for row in vercel.get("aggregate", {}).get("deploymentCounts", [])
            if row.get("deploymentId") not in {None, expected_deployment}
        ]
        if unexpected:
            advisories.append(issue("vercel_failure_from_other_deployment", "vercel", str(unexpected)))

    capabilities = sources.get("global_capabilities")
    if not capabilities:
        data_gaps.append(
            issue(
                "source_missing",
                "global_capabilities",
                "collector returned no document",
            )
        )
    else:
        if not capabilities.get("coverage", {}).get("complete"):
            data_gaps.append(
                issue(
                    "global_capabilities_read_incomplete",
                    "global_capabilities",
                    str(capabilities.get("coverage", {}).get("fieldErrors")),
                )
            )
        identity = capabilities.get("identity", {})
        global_component = state["components"].get("globalGateway", {})
        if identity.get("region") is not None and identity.get("region") != "global":
            technical.append(
                issue(
                    "global_capabilities_region_mismatch",
                    "global_capabilities",
                    str(identity.get("region")),
                )
            )
        if (
            identity.get("deploymentId") is not None
            and identity.get("deploymentId") != global_component.get("version")
        ):
            data_gaps.append(
                issue(
                    "global_gateway_deployment_mismatch",
                    "global_capabilities",
                    str(identity.get("deploymentId")),
                )
            )
        expected_commit = global_component.get("sourceCommit")
        if not expected_commit:
            data_gaps.append(
                issue(
                    "global_gateway_expected_commit_missing",
                    "global_capabilities",
                    "verified release has no sourceCommit",
                )
            )
        elif identity.get("commitSha") != expected_commit:
            data_gaps.append(
                issue(
                    "global_gateway_commit_mismatch",
                    "global_capabilities",
                    str(identity.get("commitSha")),
                )
            )

    kokoro = sources.get("kokoro_us")
    if not kokoro:
        data_gaps.append(
            issue("source_missing", "kokoro_us", "collector returned no document")
        )
    else:
        if not kokoro.get("coverage", {}).get("complete"):
            data_gaps.append(
                issue(
                    "kokoro_identity_read_incomplete",
                    "kokoro_us",
                    "runtime identity document is incomplete",
                )
            )
        kokoro_identity = kokoro.get("identity", {})
        kokoro_component = state["components"].get("usKokoro", {})
        expected_path = kokoro_component.get("runtimeReleasePath")
        expected_source = kokoro_component.get("runtimeSourceSha256")
        if not expected_path:
            data_gaps.append(
                issue(
                    "kokoro_expected_release_path_missing",
                    "kokoro_us",
                    "verified release has no runtimeReleasePath",
                )
            )
        elif kokoro_identity.get("runtimeReleasePath") != expected_path:
            data_gaps.append(
                issue(
                    "kokoro_runtime_release_mismatch",
                    "kokoro_us",
                    str(kokoro_identity.get("runtimeReleasePath")),
                )
            )
        if not expected_source:
            data_gaps.append(
                issue(
                    "kokoro_expected_source_missing",
                    "kokoro_us",
                    "verified release has no runtimeSourceSha256",
                )
            )
        elif kokoro_identity.get("runtimeSourceSha256") != expected_source:
            data_gaps.append(
                issue(
                    "kokoro_runtime_source_mismatch",
                    "kokoro_us",
                    str(kokoro_identity.get("runtimeSourceSha256")),
                )
            )

    gateway = sources.get("direct_gateway")
    legacy_sample_adequate = True
    if not gateway:
        data_gaps.append(issue("source_missing", "direct_gateway", "collector returned no document"))
        legacy_sample_adequate = False
    else:
        if not gateway.get("coverage", {}).get("complete"):
            data_gaps.append(issue("direct_gateway_journal_incomplete", "direct_gateway", "parse/truncation"))
        systemd = gateway.get("systemd", {})
        if systemd.get("ActiveState") != "active" or systemd.get("SubState") != "running":
            data_gaps.append(issue("direct_gateway_not_running", "direct_gateway", str(systemd)))
        expected_sha = state["components"].get("directGateway", {}).get(
            "runtimeSourceSha256"
        )
        actual_sha = gateway.get("source", {}).get("sha256")
        if not expected_sha:
            data_gaps.append(
                issue(
                    "direct_gateway_expected_source_missing",
                    "direct_gateway",
                    "verified release has no runtimeSourceSha256",
                )
            )
        elif actual_sha != expected_sha:
            data_gaps.append(issue("direct_gateway_source_mismatch", "direct_gateway", str(actual_sha)))
        aggregate = gateway.get("aggregate", {})
        all_5xx = sum(
            int(count)
            for status, count in aggregate.get("statusCounts", {}).items()
            if status.isdigit() and int(status) >= 500
        )
        if all_5xx:
            technical.append(issue("direct_gateway_5xx", "direct_gateway", str(all_5xx)))
        legacy = aggregate.get("android145Preset", {})
        legacy_requests = int(legacy.get("requests") or 0)
        if policy.get("requireAndroid145GatewaySample", True) and legacy_requests == 0:
            legacy_sample_adequate = False
            sample_gaps.append(
                issue("android_145_gateway_sample_missing", "direct_gateway", "zero matching requests")
            )
        legacy_errors = sum(
            int(count)
            for status, count in legacy.get("statusCounts", {}).items()
            if not status.isdigit() or int(status) < 200 or int(status) >= 300
        )
        if legacy_errors:
            technical.append(issue("android_145_gateway_non_2xx", "direct_gateway", str(legacy_errors)))

    if monitors_healthy and mobile_technical_failures:
        technical.append(
            issue(
                "healthy_probe_client_failure_contradiction",
                "cross_source",
                "probe supply success cannot override client technical failures",
            )
        )

    observation_complete = (
        duration >= required and state["state"] == "window_complete" and end <= now
    )
    observation_in_progress = (
        state["state"] == "observing"
        and start <= now < end
        and duration >= required
    )
    supply_sources = {
        "monitor_us",
        "monitor_cn",
        "vercel",
        "direct_gateway",
        "global_capabilities",
        "kokoro_us",
    }
    supply_technical = [item for item in technical if item["source"] in supply_sources]
    client_technical = [item for item in technical if item["source"] == "mobile"]
    supply_data_gaps = [
        item for item in data_gaps if item["source"] in supply_sources | {"state"}
    ]
    mobile_data_gaps = [item for item in data_gaps if item["source"] == "mobile"]
    final_version_incomplete = final_version_seconds < required

    if supply_technical:
        supply = "fail"
    elif supply_data_gaps:
        supply = "inconclusive"
    elif observation_in_progress:
        supply = "observing"
    elif not observation_complete or final_version_incomplete:
        supply = "inconclusive"
    else:
        supply = "pass"

    if client_technical:
        client_verdict = "fail"
    elif mobile_data_gaps:
        client_verdict = "inconclusive"
    elif observation_in_progress:
        client_verdict = "observing"
    elif not observation_complete or final_version_incomplete:
        client_verdict = "inconclusive"
    elif not mobile_sample_adequate:
        client_verdict = "insufficient_sample"
    else:
        client_verdict = "pass"

    if data_gaps:
        coverage = "inconclusive"
    elif observation_in_progress:
        coverage = "observing"
    elif not observation_complete:
        coverage = "inconclusive"
    else:
        coverage = "pass"

    if technical:
        automatic = "fail"
    elif data_gaps:
        automatic = "inconclusive"
    elif observation_in_progress:
        automatic = "observing"
    elif not observation_complete:
        automatic = "inconclusive"
    elif sample_gaps or not legacy_sample_adequate or not mobile_sample_adequate:
        automatic = "inconclusive"
    else:
        automatic = "pass"

    return {
        "verdictScope": "configured_existing_sources_only",
        "automaticVerdict": automatic,
        "supplyVerdict": supply,
        "clientEvidenceVerdict": client_verdict,
        "coverageVerdict": coverage,
        "windowStarted": True,
        "cutoverState": state["state"],
        "startUtc": iso(start),
        "endUtc": iso(end),
        "observationSeconds": int(elapsed),
        "configuredWindowSeconds": int(duration),
        "requiredObservationSeconds": required,
        "observationRequirementMet": elapsed >= required and duration >= required,
        "mixedVersionWindow": mixed_version,
        "latestActiveComponent": state["latestComponent"],
        "latestActiveComponentAtUtc": iso(latest_active),
        "latestRequiredComponent": state["latestReadyComponent"],
        "latestRequiredComponentVerifiedAtUtc": iso(latest_ready),
        "releaseTransitionsInsideWindow": state["transitionsInWindow"],
        "versionSegments": state["versionSegments"],
        "finalVersionObservationSeconds": int(final_version_seconds),
        "finalVersionObservationRequirementMet": final_version_seconds >= required,
        "technicalFailures": technical,
        "dataOrCoverageGaps": data_gaps,
        "sampleGaps": sample_gaps,
        "advisories": advisories,
        "evidenceLimitations": evidence_limitations(mobile),
        "stopAtConfiguredEnd": True,
        "automaticExtensionAllowed": False,
    }
