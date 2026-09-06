from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import unittest

from collect_rollout_acceptance import evaluate, merge_proxy_evidence


HERE = Path(__file__).resolve().parent
LEGACY_FIXTURES = (
    HERE.parent.parent / "backend-audio-iteration-20260906" /
    "monitoring" / "tests" / "fixtures" / "healthy"
)
KOKORO_PATH = "/workspace/castreader-runtime/releases/20260906-kokoro-repeated-digits-us-r133"
KOKORO_SOURCE = "e" * 64


def fixtures():
    report = {"evaluation": {
        "windowStarted": True, "automaticVerdict": "pass", "supplyVerdict": "pass",
        "coverageVerdict": "pass", "clientEvidenceVerdict": "insufficient_sample",
        "dataOrCoverageGaps": [], "evidenceLimitations": [],
    }}
    expected = {
        "verified": True, "runtimeSourcePath": "/workspace/proxy/r133_stable_proxy.py",
        "runtimeSourceSha256": "a" * 64, "version": "proxy-v1", "routeRevision": 1,
        "currentSlot": "green", "currentReleaseId": "r133", "currentReceiptSha256": "b" * 64,
    }
    identity = {
        "sourcePath": expected["runtimeSourcePath"], "sourceSha256": "a" * 64,
        "proxyReleaseId": "proxy-v1", "revision": 1, "currentSlot": "green",
        "currentReleaseId": "r133", "currentReceiptSha256": "b" * 64,
        "processIds": [123], "listenerProcessIds": [123], "currentEnabled": True,
    }
    identity["currentModel"] = {
        "slot": "green", "internalPort": 18880,
        "fixedReleaseId": "r133", "stateReleaseId": "r133",
        "stateReceiptSha256": "b" * 64, "stateEnabled": True,
        "runtimeReleasePath": KOKORO_PATH,
        "runtimeSourceRelativePath": "api/src/inference/english_g2p_recovery.py",
        "runtimeSourceBytes": 1234, "runtimeSourceSha256": KOKORO_SOURCE,
        "listenerProcessIds": [456],
        "listenerProcesses": [{"pid": 456, "cwd": KOKORO_PATH}],
        "supervisorProgram": "castreader-tts-r133-green",
        "supervisorState": "RUNNING", "supervisorPid": 456,
        "supervisorCwd": KOKORO_PATH,
        "supervisorProcess": {"pid": 456, "cwd": KOKORO_PATH},
    }
    document = {
        "schema": "castreader.us-origin-proxy-identity.v1",
        "readOnly": True,
        "productionModified": False,
        "synthesisStarted": False,
        "coverage": {"complete": True},
        "identity": identity,
        "health": {
            "ok": True, "drainTrusted": True, "active": {"blue": 0, "green": 0},
            "proxyReleaseId": "proxy-v1", "revision": 1,
            "currentSlot": "green", "currentReleaseId": "r133",
        },
    }
    return report, expected, document


def acceptance_config():
    start = datetime(2026, 9, 7, tzinfo=timezone.utc)
    end = start + timedelta(hours=24)
    return {
        "cutoverState": "window_complete",
        "window": {
            "startUtc": start.isoformat().replace("+00:00", "Z"),
            "endUtc": end.isoformat().replace("+00:00", "Z"),
            "requiredSeconds": 86_400,
        },
        "requiredComponents": {
            "globalGateway": {
                "verified": True, "version": "dpl_expected", "sourceCommit": "a" * 40,
                "activeFromUtc": "2026-09-06T23:58:00Z",
                "verifiedAtUtc": "2026-09-06T23:59:00Z",
            },
            "directGateway": {
                "verified": True, "version": "b" * 40, "runtimeSourceSha256": "c" * 64,
                "activeFromUtc": "2026-09-06T23:58:30Z",
                "verifiedAtUtc": "2026-09-06T23:59:30Z",
            },
            "usKokoro": {
                "verified": True, "version": "d" * 40,
                "runtimeReleasePath": KOKORO_PATH,
                "runtimeSourceSha256": KOKORO_SOURCE,
                "activeFromUtc": "2026-09-06T23:59:00Z",
                "verifiedAtUtc": "2026-09-06T23:59:45Z",
            },
        },
        "policy": {
            "monitorMaxBoundaryLagSeconds": 900,
            "monitorMaxObservedGapSeconds": 900,
            "minimumProductionStartsByPlatform": {"ios": 1, "android": 1},
            "requireAndroid145GatewaySample": True,
        },
    }


def healthy_sources():
    return {
        name: json.loads((LEGACY_FIXTURES / f"{name}.json").read_text())
        for name in (
            "monitor_us", "monitor_cn", "mobile", "vercel", "direct_gateway",
            "global_capabilities", "kokoro_us",
        )
    }


def evaluated_report(technical_failure=False):
    config = acceptance_config()
    sources = healthy_sources()
    sources["kokoro_us"] = {
        "coverage": {"complete": True},
        "identity": {
            "runtimeReleasePath": "/workspace/castreader-runtime/releases/20260905-kokoro-english-g2p-us-r132",
            "runtimeSourceSha256": "f" * 64,
        },
    }
    if technical_failure:
        sources["direct_gateway"]["aggregate"]["statusCounts"] = {"502": 1}
    now = datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
    return {
        "generatedAtUtc": now.isoformat().replace("+00:00", "Z"),
        "sourcesAttempted": sorted(sources),
        "sourcesReturned": sorted(sources),
        "sources": sources,
        "evaluation": evaluate(config, sources, now=now),
        "limitations": [],
    }, config


class ProxyAcceptanceTests(unittest.TestCase):
    def test_healthy_proxy_never_upgrades_insufficient_client_evidence(self):
        report, expected, document = fixtures()
        result = merge_proxy_evidence(report, expected, document)
        self.assertEqual(result["evaluation"]["clientEvidenceVerdict"], "insufficient_sample")
        self.assertEqual(result["evaluation"]["automaticVerdict"], "pass")
        self.assertNotIn("sources", report)

    def test_source_or_route_or_process_drift_prevents_pass(self):
        for key, value in (("sourceSha256", "c" * 64), ("currentSlot", "blue"),
                           ("processIds", []), ("processIds", [123, 456]),
                           ("listenerProcessIds", []), ("revision", 2)):
            with self.subTest(key=key, value=value):
                report, expected, document = fixtures()
                document["identity"][key] = value
                result = merge_proxy_evidence(report, expected, document)
                self.assertEqual(result["evaluation"]["automaticVerdict"], "inconclusive")
                self.assertEqual(result["evaluation"]["supplyVerdict"], "inconclusive")

    def test_health_cannot_claim_a_different_model_than_disk_state(self):
        report, expected, document = fixtures()
        document["health"]["currentReleaseId"] = "r132"
        result = merge_proxy_evidence(report, expected, document)
        self.assertEqual(result["evaluation"]["coverageVerdict"], "inconclusive")

    def test_untrusted_or_missing_drain_state_cannot_pass(self):
        for value in (False, None):
            with self.subTest(value=value):
                report, expected, document = fixtures()
                if value is None:
                    del document["health"]["drainTrusted"]
                else:
                    document["health"]["drainTrusted"] = value
                result = merge_proxy_evidence(report, expected, document)
                self.assertEqual(result["evaluation"]["automaticVerdict"], "inconclusive")
                self.assertIn(
                    "proxy_drain_state_untrusted",
                    {item["code"] for item in result["evaluation"]["dataOrCoverageGaps"]},
                )

    def test_document_schema_and_read_only_boundary_are_required(self):
        mutations = (
            ("schema", "unexpected"),
            ("readOnly", False),
            ("productionModified", True),
            ("synthesisStarted", True),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                report, expected, document = fixtures()
                document[key] = value
                result = merge_proxy_evidence(report, expected, document)
                self.assertEqual(result["evaluation"]["automaticVerdict"], "inconclusive")

    def test_actual_green_model_replaces_legacy_blue_before_evaluation(self):
        report, config = evaluated_report()
        self.assertEqual(report["evaluation"]["automaticVerdict"], "inconclusive")
        _, expected, document = fixtures()
        result = merge_proxy_evidence(report, expected, document, config)
        self.assertEqual(result["evaluation"]["automaticVerdict"], "pass")
        self.assertEqual(
            result["sources"]["legacy_blue"]["identity"]["runtimeReleasePath"],
            "/workspace/castreader-runtime/releases/20260905-kokoro-english-g2p-us-r132",
        )
        self.assertEqual(
            result["sources"]["kokoro_us"]["identity"]["runtimeReleasePath"],
            KOKORO_PATH,
        )

    def test_green_source_or_runtime_process_drift_cannot_pass(self):
        mutations = (
            ("runtimeSourceSha256", "0" * 64),
            ("listenerProcessIds", []),
            ("supervisorPid", 999),
            ("supervisorCwd", "/workspace/castreader-runtime/releases/wrong"),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                report, config = evaluated_report()
                _, expected, document = fixtures()
                document["identity"]["currentModel"][key] = value
                result = merge_proxy_evidence(report, expected, document, config)
                self.assertNotEqual(result["evaluation"]["automaticVerdict"], "pass")

    def test_re_evaluation_does_not_hide_an_existing_supply_failure(self):
        report, config = evaluated_report(technical_failure=True)
        self.assertEqual(report["evaluation"]["automaticVerdict"], "fail")
        _, expected, document = fixtures()
        result = merge_proxy_evidence(report, expected, document, config)
        self.assertEqual(result["evaluation"]["automaticVerdict"], "fail")
        self.assertEqual(result["evaluation"]["supplyVerdict"], "fail")

    def test_collector_failure_cannot_hide_existing_technical_failure(self):
        report, expected, _ = fixtures()
        report["evaluation"]["automaticVerdict"] = "fail"
        report["evaluation"]["supplyVerdict"] = "fail"
        result = merge_proxy_evidence(report, expected, {"coverage": {"complete": False}})
        self.assertEqual(result["evaluation"]["automaticVerdict"], "fail")
        self.assertEqual(result["evaluation"]["supplyVerdict"], "fail")
        self.assertEqual(result["sourcesAttempted"], ["origin_proxy_us"])

    def test_waiting_release_does_not_count_proxy_evidence_as_observation(self):
        report, expected, document = fixtures()
        report["evaluation"].update(windowStarted=False, automaticVerdict="waiting_release")
        self.assertEqual(merge_proxy_evidence(report, expected, document), report)


if __name__ == "__main__":
    unittest.main()
