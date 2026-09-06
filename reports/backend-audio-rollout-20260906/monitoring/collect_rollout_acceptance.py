#!/usr/bin/env python3
"""Extend the frozen acceptance collector with the new stable origin identity."""

import argparse
import copy
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
LEGACY = HERE.parent.parent / "backend-audio-iteration-20260906" / "monitoring"
sys.path.insert(0, str(LEGACY))
from acceptance_core import evaluate, parse_utc
from collect_acceptance import (
    atomic_write_json,
    run_remote_script,
    safe_error,
    source_available,
)


PROXY_DOCUMENT_SCHEMA = "castreader.us-origin-proxy-identity.v1"
KOKORO_DOCUMENT_SCHEMA = "castreader.kokoro-runtime-identity.v1"
MODEL_SLOT_PORTS = {"blue": 8880, "green": 18880}


def current_model_document(document):
    if not isinstance(document, dict):
        return None
    identity = document.get("identity")
    if not isinstance(identity, dict):
        return None
    model = identity.get("currentModel")
    if not isinstance(model, dict):
        return None
    coverage = document.get("coverage")
    complete = (
        document.get("schema") == PROXY_DOCUMENT_SCHEMA
        and document.get("readOnly") is True
        and document.get("productionModified") is False
        and document.get("synthesisStarted") is False
        and isinstance(coverage, dict)
        and coverage.get("complete") is True
    )
    return {
        "schema": KOKORO_DOCUMENT_SCHEMA,
        "readOnly": True,
        "productionModified": False,
        "modelLoadedByCollector": False,
        "diagnosticFunctionExecuted": False,
        "readAtUtc": document.get("readAtUtc"),
        "coverage": {"complete": complete},
        "identity": {
            "runtimeReleasePath": model.get("runtimeReleasePath"),
            "runtimeSourceRelativePath": model.get("runtimeSourceRelativePath"),
            "runtimeSourceBytes": model.get("runtimeSourceBytes"),
            "runtimeSourceSha256": model.get("runtimeSourceSha256"),
            "routeSlot": model.get("slot"),
            "routeReleaseId": model.get("stateReleaseId"),
            "routeReceiptSha256": model.get("stateReceiptSha256"),
            "internalPort": model.get("internalPort"),
            "listenerProcessIds": model.get("listenerProcessIds"),
            "supervisorProgram": model.get("supervisorProgram"),
            "supervisorState": model.get("supervisorState"),
            "supervisorPid": model.get("supervisorPid"),
            "supervisorCwd": model.get("supervisorCwd"),
        },
        "limitations": [
            "Identity follows the stable proxy's actual current slot; the legacy current symlink is retained separately as legacy_blue evidence."
        ],
    }


def replace_kokoro_with_routed_model(report, config, document):
    result = copy.deepcopy(report)
    previous_evaluation = copy.deepcopy(result.get("evaluation", {}))
    sources = result.setdefault("sources", {})
    attempted = set(result.get("sourcesAttempted", []))
    returned = set(result.get("sourcesReturned", []))
    legacy = sources.pop("kokoro_us", None)
    returned.discard("kokoro_us")
    if legacy is not None:
        sources["legacy_blue"] = legacy
        attempted.add("legacy_blue")
        if source_available(legacy):
            returned.add("legacy_blue")
    attempted.add("kokoro_us")
    current = current_model_document(document)
    if current is not None:
        sources["kokoro_us"] = current
        returned.add("kokoro_us")
    result["sourcesAttempted"] = sorted(attempted)
    result["sourcesReturned"] = sorted(returned)
    evaluable = {
        name: value for name, value in sources.items() if source_available(value)
    }
    evaluation = evaluate(
        config,
        evaluable,
        now=parse_utc(result["generatedAtUtc"]),
    )
    for verdict in (
        "automaticVerdict", "supplyVerdict", "clientEvidenceVerdict", "coverageVerdict"
    ):
        if previous_evaluation.get(verdict) == "fail":
            evaluation[verdict] = "fail"
    for field in ("technicalFailures",):
        existing = evaluation.setdefault(field, [])
        for item in previous_evaluation.get(field, []):
            if item not in existing:
                existing.append(item)
    result["evaluation"] = evaluation
    limitation = (
        "The legacy current-symlink Kokoro identity is retained as sources.legacy_blue; "
        "sources.kokoro_us is rebuilt from the stable proxy's actual current slot."
    )
    if limitation not in result.setdefault("limitations", []):
        result["limitations"].append(limitation)
    return result


def merge_proxy_evidence(report, expected, document, config=None):
    result = copy.deepcopy(report)
    if not result.get("evaluation", {}).get("windowStarted"):
        return result
    if config is not None:
        result = replace_kokoro_with_routed_model(result, config, document)
    result.setdefault("sources", {})["origin_proxy_us"] = document
    result["sourcesAttempted"] = sorted(set(result.get("sourcesAttempted", [])) | {"origin_proxy_us"})
    issues = []
    if not isinstance(expected, dict) or expected.get("verified") is not True:
        issues.append("proxy_expected_identity_missing")
    valid_document = isinstance(document, dict)
    if not valid_document or document.get("schema") != PROXY_DOCUMENT_SCHEMA:
        issues.append("proxy_document_schema_invalid")
    if not valid_document or document.get("readOnly") is not True:
        issues.append("proxy_document_not_read_only")
    if not valid_document or document.get("productionModified") is not False:
        issues.append("proxy_document_production_boundary_invalid")
    if not valid_document or document.get("synthesisStarted") is not False:
        issues.append("proxy_document_synthesis_boundary_invalid")
    coverage = document.get("coverage") if valid_document else None
    identity = document.get("identity") if valid_document else None
    health = document.get("health") if valid_document else None
    if not isinstance(coverage, dict) or coverage.get("complete") is not True:
        issues.append("proxy_identity_read_incomplete")
    if not isinstance(identity, dict):
        identity = {}
        issues.append("proxy_identity_shape_invalid")
    if not isinstance(health, dict):
        health = {}
        issues.append("proxy_health_shape_invalid")
    document_contract_complete = (
        valid_document
        and document.get("schema") == PROXY_DOCUMENT_SCHEMA
        and document.get("readOnly") is True
        and document.get("productionModified") is False
        and document.get("synthesisStarted") is False
        and isinstance(coverage, dict)
        and coverage.get("complete") is True
    )
    if document_contract_complete:
        result["sourcesReturned"] = sorted(set(result.get("sourcesReturned", [])) | {"origin_proxy_us"})
    comparisons = {
        "sourcePath": "runtimeSourcePath",
        "sourceSha256": "runtimeSourceSha256",
        "proxyReleaseId": "version",
        "revision": "routeRevision",
        "currentSlot": "currentSlot",
        "currentReleaseId": "currentReleaseId",
        "currentReceiptSha256": "currentReceiptSha256",
    }
    for actual_key, expected_key in comparisons.items():
        if (
            not isinstance(expected, dict)
            or expected.get(expected_key) is None
            or identity.get(actual_key) != expected[expected_key]
        ):
            issues.append(f"proxy_{actual_key}_mismatch")
    if (not isinstance(identity.get("processIds"), list)
            or len(identity.get("processIds")) != 1
            or identity.get("listenerProcessIds") != identity.get("processIds")
            or identity.get("currentEnabled") is not True):
        issues.append("proxy_runtime_not_single_active_process")
    model = identity.get("currentModel")
    if not isinstance(model, dict):
        model = {}
        issues.append("proxy_current_model_shape_invalid")
    current_slot = identity.get("currentSlot")
    expected_port = MODEL_SLOT_PORTS.get(current_slot)
    if (
        model.get("slot") != current_slot
        or model.get("internalPort") != expected_port
        or model.get("fixedReleaseId") != identity.get("currentReleaseId")
        or model.get("stateReleaseId") != identity.get("currentReleaseId")
        or model.get("stateReceiptSha256") != identity.get("currentReceiptSha256")
        or model.get("stateEnabled") is not True
    ):
        issues.append("proxy_current_model_route_mismatch")
    model_listener_pids = model.get("listenerProcessIds")
    supervisor_pid = model.get("supervisorPid")
    supervisor_process = model.get("supervisorProcess")
    listener_processes = model.get("listenerProcesses")
    listener_process = (
        listener_processes[0]
        if isinstance(listener_processes, list)
        and len(listener_processes) == 1
        and isinstance(listener_processes[0], dict)
        else {}
    )
    if (
        not isinstance(model_listener_pids, list)
        or len(model_listener_pids) != 1
        or not isinstance(supervisor_pid, int)
        or model_listener_pids != [supervisor_pid]
        or model.get("supervisorState") != "RUNNING"
        or model.get("supervisorCwd") != model.get("runtimeReleasePath")
        or not isinstance(supervisor_process, dict)
        or supervisor_process.get("pid") != supervisor_pid
        or supervisor_process.get("cwd") != model.get("runtimeReleasePath")
        or not isinstance(listener_processes, list)
        or len(listener_processes) != 1
        or listener_process.get("pid") != supervisor_pid
        or listener_process.get("cwd") != model.get("runtimeReleasePath")
    ):
        issues.append("proxy_current_model_process_mismatch")
    if health.get("ok") is not True:
        issues.append("proxy_health_unhealthy")
    if health.get("drainTrusted") is not True:
        issues.append("proxy_drain_state_untrusted")
    active = health.get("active")
    if (
        not isinstance(active, dict)
        or set(active) != set(MODEL_SLOT_PORTS)
        or any(type(active.get(slot)) is not int or active[slot] < 0 for slot in MODEL_SLOT_PORTS)
    ):
        issues.append("proxy_live_active_shape_invalid")
    for key in ("proxyReleaseId", "revision", "currentSlot", "currentReleaseId"):
        if health.get(key) != identity.get(key):
            issues.append(f"proxy_live_{key}_mismatch")
    evaluation = result["evaluation"]
    evaluation.setdefault("dataOrCoverageGaps", []).extend({
        "code": code, "source": "origin_proxy_us", "detail": "Stable US origin identity differs or could not be verified."
    } for code in issues)
    if issues:
        for key in ("automaticVerdict", "supplyVerdict", "coverageVerdict"):
            if evaluation.get(key) != "fail":
                evaluation[key] = "inconclusive"
    evaluation.setdefault("evidenceLimitations", []).append(
        "The stable US proxy is checked against its expected live source and current model slot; it shares the GPU host failure domain."
    )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-file", default=str(LEGACY / "acceptance-state.json"))
    parser.add_argument("--output", default=str(LEGACY / "latest-acceptance.json"))
    parser.add_argument("--cache-dir", default=str(HERE / "cache"))
    args = parser.parse_args()
    state = json.loads(Path(args.state_file).read_text())
    with tempfile.TemporaryDirectory(prefix="castreader-audio-observation-") as temporary:
        output = Path(temporary) / "base.json"
        completed = subprocess.run([
            sys.executable, str(LEGACY / "collect_acceptance.py"),
            "--state-file", str(Path(args.state_file).resolve()),
            "--output", str(output), "--cache-dir", args.cache_dir,
        ], capture_output=True, text=True, timeout=900)
        if completed.returncode:
            raise RuntimeError("base_acceptance_collector_failed_without_exporting_raw_output")
        report = json.loads(output.read_text())
    expected = state.get("requiredComponents", {}).get("usOriginProxy", {})
    if report.get("evaluation", {}).get("windowStarted"):
        try:
            source = expected.get("runtimeSourcePath", "")
            if not re.fullmatch(r"/workspace/[A-Za-z0-9._/-]+/r133_stable_proxy\.py", source):
                raise ValueError("proxy_expected_path_invalid")
            document = run_remote_script(
                ["castreader-us4090"], HERE / "remote_proxy_identity.py", [source], 30
            )
        except Exception as error:
            document = safe_error("origin_proxy_us", error)
        report = merge_proxy_evidence(report, expected, document, state)
    atomic_write_json(args.output, report)
    print(json.dumps({
        "ok": True,
        "verdict": report["evaluation"]["automaticVerdict"],
        "output": str(Path(args.output).resolve()),
        "proxyReadAttempted": "origin_proxy_us" in report.get("sourcesAttempted", []),
    }))


if __name__ == "__main__":
    main()
