#!/usr/bin/env python3
"""Collect one bounded, read-only US proxy log window with pinned identity."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from remote_proxy_events import parse_utc, validate_expected, EXPECTED_RELEASE, EXPECTED_PROXY_SHA

HERE = Path(__file__).resolve().parent
PREFIX = "CASTREADER_SANITIZED_PROXY_WINDOW="
MODEL_SOURCE_SHA = "06953419d01f961c70b22b12b4d59ecdfaa187e699cc555b3be4109522368e4e"
IDENTITY_RECEIPT_SCHEMA = "castreader.us-proxy-monitor-identity-receipt.v1"


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def load_expected(apply_path, status_path):
    apply_raw = apply_path.read_bytes()
    status_raw = status_path.read_bytes()
    receipt = json.loads(apply_raw)
    status = json.loads(status_raw)
    if (receipt.get("schema") != "castreader.us-origin-proxy-apply.v2"
            or receipt.get("verified") is not True or receipt.get("modelsRestarted") is not False
            or receipt.get("sourceSha256") != EXPECTED_PROXY_SHA
            or status.get("schema") != "castreader.us-origin-proxy-status.v2"
            or status.get("readOnly") is not True):
        raise ValueError("verified_v2_apply_and_status_receipts_required")
    health = receipt["after"]["health"]
    process = receipt["after"]["process"]
    slot = health["currentSlot"]
    baseline = status["baseline"]
    if (health["proxyReleaseId"] != EXPECTED_RELEASE or slot != "green"
            or health["revision"] != 2 or status.get("candidateProcess") is not None
            or baseline["proxySourceSha256"] != receipt["sourceSha256"]
            or baseline["proxyProcess"] != process
            or baseline["routing"] != receipt["before"]["routing"]
            or baseline["modelProcesses"] != receipt["before"]["modelProcesses"]):
        raise ValueError("apply_status_identity_mismatch")
    for key in ("proxyReleaseId", "revision", "currentSlot", "currentReleaseId"):
        if status["health"].get(key) != health.get(key):
            raise ValueError("apply_status_health_mismatch")
    if status["health"].get("ok") is not True or status["health"].get("drainTrusted") is not True:
        raise ValueError("status_health_unverified")
    confirmed = status["verifiedAtUTC"]
    parse_utc(confirmed)
    expected = {
        "sourcePath": process["cwd"] + "/r133_stable_proxy.py",
        "sourceSha256": receipt["sourceSha256"], "sourceCommit": receipt["sourceCommit"],
        "proxyReleaseId": health["proxyReleaseId"], "revision": health["revision"],
        "currentSlot": slot, "currentReleaseId": health["currentReleaseId"],
        "currentReceiptSha256": receipt["before"]["routing"]["slots"][slot]["receiptSha256"],
        "process": process, "modelProcess": receipt["before"]["modelProcesses"][slot],
        "modelSourceSha256": MODEL_SOURCE_SHA,
    }
    provenance = {"productionApplyReceiptPath": str(apply_path),
                  "productionApplyReceiptSha256": sha(apply_raw),
                  "productionStatusReceiptPath": str(status_path),
                  "productionStatusReceiptSha256": sha(status_raw)}
    return expected, confirmed, provenance


def read_bound_json(path, root):
    """Only canonical regular JSON evidence inside this rollout; no secret paths."""
    if (not isinstance(path, str) or not Path(path).is_absolute()
            or Path(path).suffix != ".json"):
        raise ValueError("evidence_path_invalid")
    candidate = Path(path)
    resolved = candidate.resolve(strict=True)
    resolved.relative_to(root.resolve(strict=True))
    if (str(candidate) != path or resolved != candidate or not candidate.is_file()
            or not 0 < candidate.stat().st_size <= 8 * 1024 * 1024):
        raise ValueError("evidence_path_not_canonical_regular_json")
    raw = candidate.read_bytes()
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("evidence_object_required")
    return raw, value


def load_identity_receipt(path, evidence_root=None):
    root = evidence_root if evidence_root is not None else HERE.parent
    raw, receipt = read_bound_json(str(path), root)
    if (set(receipt) != {"schema", "verified", "verifiedAtUTC", "expected",
                         "modelExpectation", "deploymentEvidence"}
            or receipt["schema"] != IDENTITY_RECEIPT_SCHEMA or receipt["verified"] is not True):
        raise ValueError("verified_identity_receipt_required")
    confirmed = receipt["verifiedAtUTC"]
    parse_utc(confirmed)
    expected, model = receipt["expected"], receipt["modelExpectation"]
    validate_expected(expected, model)
    evidence = receipt["deploymentEvidence"]
    if not isinstance(evidence, list) or not 1 <= len(evidence) <= 16:
        raise ValueError("deployment_evidence_required")
    seen = set()
    for row in evidence:
        if (not isinstance(row, dict) or set(row) != {"path", "sha256"}
                or not isinstance(row["sha256"], str)
                or re.fullmatch(r"[a-f0-9]{64}", row["sha256"]) is None):
            raise ValueError("deployment_evidence_shape_invalid")
        evidence_raw, _ = read_bound_json(row["path"], root)
        if row["path"] in seen or row["path"] == str(path) or sha(evidence_raw) != row["sha256"]:
            raise ValueError("deployment_evidence_binding_invalid")
        seen.add(row["path"])
    return expected, confirmed, {
        "identityReceiptPath": str(path), "identityReceiptSha256": sha(raw),
        "deploymentEvidence": evidence,
    }, model


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start-utc", required=True)
    parser.add_argument("--end-utc", required=True, help="Explicit UTC timestamp, or now")
    parser.add_argument("--production-active-from-utc", help="Must be at/after the status receipt confirmation")
    parser.add_argument("--identity-receipt", type=Path, help="Explicit frozen identity after a verified model/proxy transition")
    parser.add_argument("--production-receipt", type=Path)
    parser.add_argument("--status-receipt", type=Path)
    parser.add_argument("--max-scan-mib", type=int, default=64, help="1–128 MiB tail of the combined log")
    parser.add_argument("--max-events", type=int, default=2000, help="1–10000 exported event rows")
    parser.add_argument("--max-requests", type=int, default=2000, help="1–10000 exported anonymous request groups")
    parser.add_argument("--include-events", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not (1 <= args.max_scan_mib <= 128 and 1 <= args.max_events <= 10000
            and 1 <= args.max_requests <= 10000):
        parser.error("scan/export limits are outside the bounded range")
    if args.identity_receipt is not None:
        if args.production_receipt is not None or args.status_receipt is not None:
            parser.error("identity receipt and legacy receipt arguments cannot be combined")
        # Do not resolve here: the loader must reject a symlink alias rather than
        # silently turning it into an approved-looking evidence path.
        expected, confirmed, provenance, model = load_identity_receipt(args.identity_receipt.absolute())
    else:
        expected, confirmed, provenance = load_expected(
            (args.production_receipt or HERE.parent / "us-proxy-apply.json").resolve(),
            (args.status_receipt or HERE.parent / "us-proxy-status.json").resolve())
        model = None
    active_from = args.production_active_from_utc or confirmed
    end = datetime.now(timezone.utc).isoformat() if args.end_utc == "now" else args.end_utc
    if not (parse_utc(confirmed) <= parse_utc(active_from) <= parse_utc(args.start_utc) < parse_utc(end)):
        parser.error("window must start at/after confirmed production and end after its start")
    helper_path = HERE.parents[1] / "backend-audio-rollout-20260906/monitoring/remote_proxy_identity.py"
    helper = helper_path.read_bytes()
    remote = (HERE / "remote_proxy_events.py").read_bytes()
    payload = {"startUTC": args.start_utc, "endUTC": end, "productionActiveFromUTC": active_from,
               "expected": expected, "identityHelperSource": helper.decode(),
               "maxScanMiB": args.max_scan_mib, "maxEvents": args.max_events,
               "maxRequests": args.max_requests, "includeEvents": args.include_events}
    if model is not None:
        payload["modelExpectation"] = model
    # stdin contains code and reviewed scalar configuration, never user content.
    source = remote.decode() + "\nprint(" + repr(PREFIX) + " + json.dumps(collect(json.loads(" + repr(
        json.dumps(payload)) + ")), sort_keys=True))\n"
    completed = subprocess.run(
        ["ssh", "-C", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "castreader-us4090",
         "/venv/main/bin/python -B -"], input=source, text=True, capture_output=True, timeout=60, check=False)
    # SSH banners and exception values are never reflected into the evidence.
    lines = [line[len(PREFIX):] for line in completed.stdout.splitlines() if line.startswith(PREFIX)]
    if completed.returncode != 0 or len(lines) != 1:
        raise RuntimeError("remote_collection_failed_no_sanitized_result")
    result = json.loads(lines[0])
    if result.get("schema") != "castreader.us-proxy-event-window.v1":
        raise RuntimeError("remote_collection_schema_invalid")
    result["expectedProductionIdentity"] = expected
    if model is not None:
        result["expectedModelIdentity"] = model
    result["collector"] = {**provenance, "sshAlias": "castreader-us4090",
                           "identityHelperSourceSha256": sha(helper), "remoteCollectorSourceSha256": sha(remote),
                           "localCollectorSourceSha256": sha(Path(__file__).read_bytes())}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"output": str(args.output.resolve()), "window": result["window"],
                      "identityVerified": result["runtime"]["verified"], "coverage": result["coverage"],
                      "counts": result["counts"], "coalescing": result["coalescing"]}, indent=2, sort_keys=True))
    return 0 if result["identityAndCoverageVerified"] else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        # Class names only: remote stderr/exception values can contain addresses.
        print(json.dumps({"collectionFailed": True, "errorClass": type(error).__name__,
                          "rawUserDataExported": False}), file=sys.stderr)
        sys.exit(1)
