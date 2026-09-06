"""Synthetic fixtures: privacy boundary, lifecycle counting, bounded evidence."""
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import collect_proxy_events as local
import remote_proxy_events as remote


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


if __name__ == "__main__":
    unittest.main()
