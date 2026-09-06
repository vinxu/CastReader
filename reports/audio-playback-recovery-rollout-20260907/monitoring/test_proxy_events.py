"""Synthetic fixtures: privacy boundary, lifecycle counting, bounded evidence."""
from datetime import datetime, timezone
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

import collect_proxy_events as local
import remote_proxy_events as remote


def frozen_identity():
    model = {"slot": "blue", "releaseId": "20260907-kokoro-silent-separators-us-r134",
             "version": "c" * 40,
             "releasePath": remote.MODEL_DIRECTORY + "20260907-kokoro-silent-separators-us-r134",
             "sourceRelativePath": "api/src/services/tts_service.py", "sourceSha256": "d" * 64}
    expected = {"sourcePath": remote.PROXY_DIRECTORY + "/r133_stable_proxy.py",
                "sourceSha256": local.EXPECTED_PROXY_SHA, "sourceCommit": "e" * 40,
                "proxyReleaseId": local.EXPECTED_RELEASE, "revision": 6, "currentSlot": model["slot"],
                "currentReleaseId": model["releaseId"], "currentReceiptSha256": "a" * 64,
                "process": {"pid": 10001, "startTicks": "600000001", "cwd": remote.PROXY_DIRECTORY},
                "modelProcess": {"pid": 10002, "startTicks": "600000000", "cwd": model["releasePath"]},
                "modelSourceSha256": model["sourceSha256"]}
    return expected, model


def observed_identity(expected, model):
    process = deepcopy(expected["process"])
    model_process = deepcopy(expected["modelProcess"])
    measured = {key: expected[key] for key in ("sourcePath", "sourceSha256", "proxyReleaseId",
                    "revision", "currentSlot", "currentReleaseId", "currentReceiptSha256")}
    measured.update(processIds=[process["pid"]], listenerProcessIds=[process["pid"]], currentEnabled=True)
    measured["currentModel"] = {"slot": model["slot"], "fixedReleaseId": model["releaseId"],
        "stateReleaseId": model["releaseId"], "stateReceiptSha256": expected["currentReceiptSha256"],
        "runtimeReleasePath": model["releasePath"], "runtimeSourceSha256": model["sourceSha256"],
        "runtimeSourceRelativePath": model["sourceRelativePath"], "stateEnabled": True,
        "internalPort": remote.MODEL_PORTS[model["slot"]],
        "supervisorProgram": remote.MODEL_PROGRAMS[model["slot"]], "supervisorState": "RUNNING",
        "supervisorPid": model_process["pid"], "supervisorCwd": model_process["cwd"],
        "supervisorProcess": deepcopy(model_process), "listenerProcessIds": [model_process["pid"]],
        "listenerProcesses": [deepcopy(model_process)]}
    health = {key: expected[key] for key in ("proxyReleaseId", "revision", "currentSlot", "currentReleaseId")}
    health.update(ok=True, drainTrusted=True)
    return {"identity": measured, "health": health}, process, model_process


class MonitoringTests(unittest.TestCase):
    def test_user_data_and_non_hash_identifiers_never_exported(self):
        event = remote.safe_event({"schema": remote.EVENT_SCHEMA, "stage": "request_failed",
            "time_unix": 1788712640, "requestKey": "raw-request-secret", "flightKey": "b" * 20,
            "attempt": 2, "body": "PRIVATE_BODY_SENTINEL", "userId": "PRIVATE_ACCOUNT_SENTINEL",
            "authorization": "PRIVATE_TOKEN_SENTINEL", "errorClass": "PRIVATE_EXCEPTION_SENTINEL",
            "headers": {"x-request-id": "PRIVATE_REQUEST_SENTINEL"}})
        self.assertEqual(event["errorClass"], "OtherException")
        self.assertNotIn("requestKey", event)
        self.assertEqual(event["flightKey"], "b" * 20)
        self.assertNotIn("PRIVATE", json.dumps(event))

    def test_malformed_fields_cannot_break_collector_or_escape_whitelist(self):
        base = {"schema": remote.EVENT_SCHEMA, "stage": "request_finished", "time_unix": 1788712640}
        self.assertIsNone(remote.safe_event({**base, "stage": {"input": "private"}}))
        self.assertIsNone(remote.safe_event({**base, "time_unix": float("inf")}))
        self.assertIsNone(remote.safe_event({**base, "time_unix": 1e200}))
        event = remote.safe_event({**base, "errorClass": {"input": "private"}, "outcome": [],
                                   "status": True, "elapsedMs": float("nan")})
        self.assertEqual(event["errorClass"], "OtherException")
        self.assertNotIn("outcome", event)
        self.assertNotIn("status", event)
        self.assertNotIn("elapsedMs", event)

    def test_utc_is_explicit_and_pre_confirmation_window_is_rejected(self):
        for value in ("2026-09-06T16:37:00", "2026-09-07T00:37:00+08:00"):
            with self.assertRaises(ValueError):
                remote.parse_utc(value)
        with self.assertRaises(ValueError):
            remote.collect({"startUTC": "2026-09-06T16:30:00Z", "endUTC": "2026-09-06T16:38:00Z",
                            "productionActiveFromUTC": "2026-09-06T16:36:52.292087Z"})

    def test_shared_failure_is_one_producer_and_two_callers_even_when_rows_truncated(self):
        start = remote.parse_utc("2026-09-06T16:37:00Z")
        release = local.EXPECTED_RELEASE
        rows = []
        def event(stage, request="a" * 20, shared=True, **extra):
            row = {"schema": remote.EVENT_SCHEMA, "stage": stage, "time_unix": start + len(rows),
                   "requestKey": request, "attempt": 1, "proxyReleaseId": release,
                   "body": "PRIVATE_BODY_SENTINEL", **extra}
            if shared:
                row["flightKey"] = "f" * 20
            rows.append(row)
        event("request_received", shared=False)
        event("flight_created")
        event("upstream_connect_started")
        event("upstream_connected", connectMs=0.8)
        event("request_received", request="b" * 20, shared=False)
        event("flight_joined", request="b" * 20)
        event("upstream_failed", errorClass="TimeoutError")
        event("request_failed", errorClass="TimeoutError")
        event("request_failed", request="b" * 20, errorClass="TimeoutError")
        event("request_finished", outcome="timeout")
        event("request_finished", request="b" * 20, outcome="timeout")
        event("request_received", request="c" * 20, shared=False)
        event("request_independent", request="c" * 20, shared=False)
        event("request_finished", request="c" * 20, shared=False, outcome="cancelled")
        payload = {"startUTC": remote.utc(start), "endUTC": remote.utc(start + 60),
                   "productionActiveFromUTC": remote.utc(start - 10), "expected": {"proxyReleaseId": release},
                   "maxScanMiB": 1, "includeEvents": True, "maxEvents": 2, "maxRequests": 1}
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "synthetic.log"
            log.write_text("User log PRIVATE_MODEL_TEXT_SENTINEL\n" + "\n".join(json.dumps(v) for v in rows) + "\n")
            with patch.object(remote, "runtime_identity", return_value={"verified": True, "issues": []}), \
                    patch.object(remote, "Path", return_value=log):
                result = remote.collect(payload)
        scopes = result["counts"]["failureScopesAndLastObservedPhases"]
        self.assertEqual(scopes, {"shared_producer:waiting_response_headers": 1,
                                  "shared_caller:waiting_response_headers": 2})
        self.assertEqual(result["counts"]["finishedOutcomes"], {"timeout": 2, "cancelled": 1})
        self.assertEqual(result["coalescing"]["joinFractionOfSharedAdmissions"], 0.5)
        self.assertAlmostEqual(result["coalescing"]["joinFractionOfAllAdmissions"], 1 / 3)
        self.assertTrue(result["identityAndCoverageVerified"])
        self.assertTrue(result["eventsTruncated"])
        self.assertTrue(result["failureEventsTruncated"])
        self.assertTrue(result["anonymousRequestsTruncated"])
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_real_sanitized_receipts_pin_deployed_process_and_source(self):
        expected, confirmed, _ = local.load_expected(local.HERE.parent / "us-proxy-apply.json",
                                                     local.HERE.parent / "us-proxy-status.json")
        self.assertEqual(expected["process"]["pid"], 4031530)
        self.assertEqual(expected["sourceSha256"], local.EXPECTED_PROXY_SHA)
        self.assertEqual(remote.parse_utc(confirmed), remote.parse_utc("2026-09-06T16:36:52.292087Z"))

    def test_frozen_new_identity_and_bound_local_evidence(self):
        expected, model = frozen_identity()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            evidence = root / "independent-identity.json"
            evidence.write_text(json.dumps({"verified": True, "identity": expected}))
            receipt = {"schema": local.IDENTITY_RECEIPT_SCHEMA, "verified": True,
                       "verifiedAtUTC": "2026-09-06T18:00:00Z", "expected": expected,
                       "modelExpectation": model,
                       "deploymentEvidence": [{"path": str(evidence), "sha256": local.sha(evidence.read_bytes())}]}
            path = root / "frozen.json"
            path.write_text(json.dumps(receipt))
            actual, confirmed, provenance, actual_model = local.load_identity_receipt(path, root)
            self.assertEqual(actual, expected)
            self.assertEqual(actual_model, model)
            self.assertEqual(confirmed, receipt["verifiedAtUTC"])
            self.assertEqual(provenance["identityReceiptSha256"], local.sha(path.read_bytes()))
            evidence.write_text('{"verified":false}')
            with self.assertRaisesRegex(ValueError, "binding"):
                local.load_identity_receipt(path, root)

    def test_forged_paths_and_inconsistent_receipt_fields_fail_closed(self):
        expected, model = frozen_identity()
        mutations = [
            ("expected", "sourcePath", remote.PROXY_DIRECTORY + "/../other/r133_stable_proxy.py"),
            ("expected", "sourceSha256", "f" * 64), ("expected", "sourceCommit", "short"),
            ("expected", "currentSlot", "green"), ("expected", "modelSourceSha256", "b" * 64),
            ("expected", "revision", True), ("model", "version", "bad"),
            ("model", "releasePath", remote.MODEL_DIRECTORY + "../elsewhere"),
            ("model", "sourceRelativePath", "api/src/../private.py"),
            ("model", "sourceRelativePath", "/tmp/private.py"),
            ("model", "sourceRelativePath", "api//src/source.py"),
        ]
        for target, key, value in mutations:
            with self.subTest(target=target, key=key, value=value):
                values = {"expected": deepcopy(expected), "model": deepcopy(model)}
                values[target][key] = value
                with self.assertRaises(ValueError):
                    remote.validate_expected(values["expected"], values["model"])
        for field in ("process", "modelProcess"):
            for key, value in (("pid", True), ("startTicks", ""), ("cwd", "/tmp/alias")):
                other = deepcopy(expected)
                other[field][key] = value
                with self.assertRaises(ValueError):
                    remote.validate_expected(other, model)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "allowed"
            root.mkdir()
            outside = Path(directory) / "outside.json"
            outside.write_text('{}')
            alias = root / "alias.json"
            alias.symlink_to(outside)
            for path in (str(outside), str(alias), str(root / ".." / "outside.json")):
                with self.assertRaises(ValueError):
                    local.read_bound_json(path, root)

    def test_runtime_drift_same_v2_release_does_not_pass(self):
        expected, model = frozen_identity()
        remote.validate_expected(expected, model)
        value, process, model_process = observed_identity(expected, model)
        self.assertEqual(remote.identity_issues(value, expected, process, model_process, model), [])
        for field, replacement in (("revision", 2), ("currentSlot", "green"),
                                   ("currentReleaseId", "old-r133"), ("currentReceiptSha256", "b" * 64)):
            other = deepcopy(value)
            other["identity"][field] = replacement
            self.assertTrue(remote.identity_issues(other, expected, process, model_process, model))

    def test_explicit_model_expectation_reaches_helper_and_argv_is_restored(self):
        expected, model = frozen_identity()
        value, process, model_process = observed_identity(expected, model)
        helper = '''import json,sys
def main():
    assert sys.argv[2] == "--model-expectation-json"
    assert json.loads(sys.argv[3]) == MODEL
    print(json.dumps(VALUE))
def process_metadata(pid):
    return PROCESSES[str(pid)]
'''.replace("MODEL", repr(model)).replace("VALUE", repr(value)).replace(
            "PROCESSES", repr({str(process["pid"]): process, str(model_process["pid"]): model_process}))
        payload = {"expected": expected, "modelExpectation": model,
                   "identityHelperSource": helper, "productionActiveFromUTC": "2026-09-06T18:00:00Z"}
        original_argv = remote.sys.argv
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "supervisor.log"
            log.write_text("")
            source_path = Mock()
            source_path.resolve.return_value = source_path
            def local_path(path):
                if path == expected["sourcePath"]:
                    return source_path
                if path == "/var/log/supervisor/supervisord.log":
                    return log
                return Path(directory) / "unavailable-proc-stat"
            with patch.object(remote, "Path", side_effect=local_path):
                result = remote.runtime_identity(payload)
        self.assertTrue(result["verified"])
        self.assertIs(remote.sys.argv, original_argv)
        for which in ("proxy", "model"):
            p, mp = deepcopy(process), deepcopy(model_process)
            (p if which == "proxy" else mp)["startTicks"] = "600000999"
            self.assertTrue(remote.identity_issues(value, expected, p, mp, model))
        for field, replacement in (("runtimeSourceSha256", "b" * 64),
                ("runtimeSourceRelativePath", "api/src/private.py"),
                ("runtimeReleasePath", remote.MODEL_DIRECTORY + "old-r133"),
                ("supervisorState", "STOPPED"), ("stateEnabled", False), ("internalPort", 18880)):
            other = deepcopy(value)
            other["identity"]["currentModel"][field] = replacement
            self.assertTrue(remote.identity_issues(other, expected, process, model_process, model))

    def test_old_slot_events_in_new_window_make_coverage_incomplete(self):
        expected, model = frozen_identity()
        start = remote.parse_utc("2026-09-06T18:01:00Z")
        rows = [{"schema": remote.EVENT_SCHEMA, "stage": "request_finished", "time_unix": start + n,
                 "proxyReleaseId": expected["proxyReleaseId"], "slot": slot, "revision": revision,
                 "releaseId": release, "status": 200, "outcome": "complete"}
                for n, (slot, revision, release) in enumerate([
                    ("green", 2, "old-r133"), ("blue", 6, model["releaseId"])])]
        payload = {"startUTC": remote.utc(start), "endUTC": remote.utc(start + 5),
                   "productionActiveFromUTC": remote.utc(start - 1), "expected": expected,
                   "maxScanMiB": 1, "includeEvents": True, "maxEvents": 20, "maxRequests": 20}
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "synthetic.log"
            log.write_text('\n'.join(json.dumps(v) for v in rows) + '\n')
            with patch.object(remote, "runtime_identity", return_value={"verified": True}), \
                    patch.object(remote, "Path", return_value=log):
                result = remote.collect(payload)
        self.assertFalse(result["identityAndCoverageVerified"])
        self.assertEqual(result["coverage"]["unexpectedRoutingIdentityEvents"], 1)
        self.assertEqual(result["counts"]["finishedReportedStatuses"], {"200": 1})


if __name__ == "__main__":
    unittest.main()
