from datetime import datetime, timedelta, timezone
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from collect_rollout_acceptance import evaluate, merge_proxy_evidence, proxy_identity_args
import remote_proxy_identity as remote_identity


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


def new_release_fixtures():
    report, config = evaluated_report()
    _, expected, document = fixtures()
    release_id = "20260907-fixture-silent-unit-v2"
    release_path = str(remote_identity.RELEASES / release_id)
    expected.update(
        currentSlot="blue", currentReleaseId=release_id,
        activeFromUtc="2026-09-06T23:59:00Z", verifiedAtUtc="2026-09-06T23:59:45Z",
    )
    config["requiredComponents"]["usOriginProxy"] = expected
    config["requiredComponents"]["usKokoro"].update(
        runtimeReleasePath=release_path,
        runtimeSourceRelativePath="api/src/services/tts_service.py",
    )
    document["identity"].update(currentSlot="blue", currentReleaseId=release_id)
    document["health"].update(currentSlot="blue", currentReleaseId=release_id)
    model = document["identity"]["currentModel"]
    model.update(
        slot="blue", internalPort=8880,
        fixedReleaseId=release_id, stateReleaseId=release_id,
        runtimeReleasePath=release_path,
        runtimeSourceRelativePath="api/src/services/tts_service.py",
        expectedVersion=config["requiredComponents"]["usKokoro"]["version"],
        supervisorProgram="castreader-tts", supervisorCwd=release_path,
        supervisorProcess={"pid": 456, "cwd": release_path},
        listenerProcesses=[{"pid": 456, "cwd": release_path}],
    )
    return report, config, expected, document


class ConfiguredModelAcceptanceTests(unittest.TestCase):
    def test_reviewed_new_blue_release_passes_and_is_explicitly_forwarded(self):
        report, config, expected, document = new_release_fixtures()
        original = copy.deepcopy(config)
        arguments = proxy_identity_args(config)
        self.assertEqual(arguments[:2], [expected["runtimeSourcePath"], "--model-expectation-json"])
        transmitted = json.loads(arguments[2])
        self.assertEqual(transmitted["slot"], "blue")
        self.assertEqual(transmitted["releaseId"], expected["currentReleaseId"])
        self.assertEqual(transmitted["sourceRelativePath"], "api/src/services/tts_service.py")
        self.assertEqual(transmitted["sourceSha256"], KOKORO_SOURCE)
        self.assertEqual(config, original)
        result = merge_proxy_evidence(report, expected, document, config)
        self.assertEqual(result["evaluation"]["automaticVerdict"], "pass")

    def test_new_model_path_slot_source_hash_version_and_process_drift_cannot_pass(self):
        mutations = (
            ("runtimeReleasePath", str(remote_identity.RELEASES / "wrong")),
            ("slot", "green"), ("internalPort", 18880),
            ("runtimeSourceRelativePath", "api/src/inference/english_g2p_recovery.py"),
            ("runtimeSourceSha256", "0" * 64), ("expectedVersion", "0" * 40),
            ("supervisorProgram", "other-program"),
            ("supervisorPid", 999), ("listenerProcessIds", [999]),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                report, config, expected, document = new_release_fixtures()
                document["identity"]["currentModel"][key] = value
                result = merge_proxy_evidence(report, expected, document, config)
                self.assertNotEqual(result["evaluation"]["automaticVerdict"], "pass")

    def test_unreviewed_or_malformed_local_model_expectation_is_not_forwarded(self):
        for component in ("usKokoro", "usOriginProxy"):
            _, config, _, _ = new_release_fixtures()
            config["requiredComponents"][component]["verified"] = False
            with self.assertRaisesRegex(ValueError, "not_verified"):
                proxy_identity_args(config)
        _, config, _, _ = new_release_fixtures()
        config["requiredComponents"]["usKokoro"]["runtimeSourceRelativePath"] = "../tts_service.py"
        with self.assertRaisesRegex(ValueError, "source_path_invalid"):
            proxy_identity_args(config)

    def test_legacy_acceptance_state_still_uses_source_only_invocation(self):
        _, expected, _ = fixtures()
        config = acceptance_config()
        config["requiredComponents"]["usOriginProxy"] = expected
        self.assertEqual(proxy_identity_args(config), [expected["runtimeSourcePath"]])


class RemoteModelIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.temporary = Path(temporary.name).resolve()
        self.releases = self.temporary / "releases"
        self.releases.mkdir()
        self.release_id = "20260907-fixture-silent-unit-v2"
        self.release = self.releases / self.release_id
        self.relative = "api/src/services/tts_service.py"
        self.source = self.release / self.relative
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b"# deterministic model source fixture\n")
        self.expected = {
            "slot": "blue", "releaseId": self.release_id, "version": "a" * 40,
            "releasePath": str(self.release), "sourceRelativePath": self.relative,
            "sourceSha256": hashlib.sha256(self.source.read_bytes()).hexdigest(),
        }
        self.state = {"currentSlot": "blue", "slots": {"blue": {
            "releaseId": self.release_id, "receiptSha256": "b" * 64, "enabled": True,
        }}}
        slots = copy.deepcopy(remote_identity.SLOTS)
        for slot in slots.values():
            slot["releasePath"] = self.releases / slot["releaseId"]
        for name, replacement in (("RELEASES", self.releases), ("SLOTS", slots)):
            patcher = patch.object(remote_identity, name, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        process = {"pid": 456, "cwd": str(self.release)}
        self.listeners = patch.object(remote_identity, "listener_processes", return_value=[process])
        self.supervisor = patch.object(remote_identity, "supervisor_identity", return_value={
            "program": "castreader-tts", "state": "RUNNING", "pid": 456, "process": process,
        })
        self.listener_mock = self.listeners.start()
        self.supervisor_mock = self.supervisor.start()
        self.addCleanup(self.listeners.stop)
        self.addCleanup(self.supervisor.stop)

    def test_new_source_is_hashed_with_fixed_blue_process_and_port(self):
        result = remote_identity.current_model_identity(self.state, self.expected)
        self.assertEqual(result["runtimeSourceSha256"], self.expected["sourceSha256"])
        self.assertEqual(result["runtimeSourceRelativePath"], self.relative)
        self.assertEqual(result["runtimeReleasePath"], str(self.release))
        self.assertEqual(result["expectedVersion"], "a" * 40)
        self.assertEqual(result["internalPort"], 8880)
        self.listener_mock.assert_called_once_with(8880)
        self.supervisor_mock.assert_called_once_with("castreader-tts")

    def test_explicit_expectation_never_learns_release_or_slot_from_online_state(self):
        for key, value in (("releaseId", "unreviewed-online-release"), ("currentSlot", "green")):
            state = copy.deepcopy(self.state)
            if key == "currentSlot":
                state[key] = value
                state["slots"]["green"] = state["slots"]["blue"]
            else:
                state["slots"]["blue"][key] = value
            with self.assertRaisesRegex(ValueError, "route_mismatch"):
                remote_identity.current_model_identity(state, self.expected)
        self.listener_mock.assert_not_called()

    def test_invalid_configuration_paths_hashes_and_port_override_are_rejected(self):
        mutations = (
            ("releasePath", str(self.temporary / "outside")),
            ("releaseId", "../escape"), ("slot", "other"),
            ("sourceRelativePath", "../tts_service.py"),
            ("sourceRelativePath", "/api/src/services/tts_service.py"),
            ("sourceRelativePath", "api/src/../services/tts_service.py"),
            ("sourceRelativePath", "api//src/services/tts_service.py"),
            ("sourceRelativePath", "api/src/services/missing.py"),
            ("sourceSha256", "0" * 64), ("version", "unreviewed"),
            ("port", 18880),
        )
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                expected = dict(self.expected, **{key: value})
                with self.assertRaises((ValueError, OSError)):
                    remote_identity.current_model_identity(self.state, expected)
        self.listener_mock.assert_not_called()

    def test_source_and_release_symlink_escape_or_alias_are_rejected(self):
        outside = self.temporary / "outside.py"
        outside.write_bytes(self.source.read_bytes())
        self.source.unlink()
        self.source.symlink_to(outside)
        with self.assertRaises(ValueError):
            remote_identity.current_model_identity(self.state, self.expected)
        self.source.unlink()
        alias = self.release / "other.py"
        alias.write_bytes(outside.read_bytes())
        self.source.symlink_to(alias)
        with self.assertRaisesRegex(ValueError, "source_path_not_canonical"):
            remote_identity.current_model_identity(self.state, self.expected)
        self.source.unlink()
        self.source.write_bytes(outside.read_bytes())
        moved = self.releases / "other-release"
        self.release.rename(moved)
        self.release.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "release_path_not_canonical"):
            remote_identity.current_model_identity(self.state, self.expected)
        self.listener_mock.assert_not_called()

    def test_no_optional_argument_preserves_frozen_legacy_release_and_source(self):
        for slot_name, settings in remote_identity.SLOTS.items():
            legacy_source = settings["releasePath"] / remote_identity.SOURCE_RELATIVE
            legacy_source.parent.mkdir(parents=True)
            legacy_source.write_bytes(b"# legacy fixture\n")
            state = {"currentSlot": slot_name, "slots": {slot_name: {
                "releaseId": settings["releaseId"], "receiptSha256": "c" * 64, "enabled": True,
            }}}
            result = remote_identity.current_model_identity(state)
            self.assertEqual(result["fixedReleaseId"], settings["releaseId"])
            self.assertEqual(result["runtimeSourceRelativePath"], remote_identity.SOURCE_RELATIVE.as_posix())
            self.assertEqual(result["runtimeSourceSha256"], hashlib.sha256(b"# legacy fixture\n").hexdigest())
            self.assertNotIn("expectedVersion", result)
            self.listener_mock.assert_called_with(settings["port"])
            self.supervisor_mock.assert_called_with(settings["supervisorProgram"])


if __name__ == "__main__":
    unittest.main()
