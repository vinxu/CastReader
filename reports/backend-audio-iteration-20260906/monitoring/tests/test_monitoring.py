#!/usr/bin/env python3

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
MONITORING = HERE.parent
sys.path.insert(0, str(MONITORING))

from acceptance_core import aggregate_mobile, evaluate, parse_utc  # noqa: E402
from collect_acceptance import collect_global_capabilities, main as collect_main  # noqa: E402
from remote_monitor_snapshot import consecutive_summary  # noqa: E402
from remote_tts_gateway_snapshot import aggregate_entries  # noqa: E402


FIXTURE = HERE / "fixtures" / "healthy"
GLOBAL_COMMIT = "a" * 40
DIRECT_COMMIT = "b" * 40
DIRECT_SOURCE = "c" * 64
KOKORO_COMMIT = "d" * 40
KOKORO_SOURCE = "e" * 64


def healthy_sources():
    return {
        name: json.loads((FIXTURE / f"{name}.json").read_text())
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


def config(state="window_complete", hours=24):
    start = datetime(2026, 9, 7, tzinfo=timezone.utc)
    end = start + timedelta(hours=hours)
    return {
        "cutoverState": state,
        "window": {
            "startUtc": start.isoformat().replace("+00:00", "Z"),
            "endUtc": end.isoformat().replace("+00:00", "Z"),
            "requiredSeconds": 86_400,
        },
        "requiredComponents": {
            "globalGateway": {
                "verified": True,
                "version": "dpl_expected",
                "sourceCommit": GLOBAL_COMMIT,
                "activeFromUtc": "2026-09-06T23:58:00Z",
                "verifiedAtUtc": "2026-09-06T23:59:00Z",
            },
            "directGateway": {
                "verified": True,
                "version": DIRECT_COMMIT,
                "runtimeSourceSha256": DIRECT_SOURCE,
                "activeFromUtc": "2026-09-06T23:58:30Z",
                "verifiedAtUtc": "2026-09-06T23:59:30Z",
            },
            "usKokoro": {
                "verified": True,
                "version": KOKORO_COMMIT,
                "runtimeReleasePath": "/workspace/castreader-runtime/releases/r133",
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


class AcceptanceEvaluationTests(unittest.TestCase):
    def test_waiting_release_never_starts_window(self):
        value = config("waiting_release")
        value["requiredComponents"]["globalGateway"]["verified"] = False
        result = evaluate(value, {}, now=datetime(2026, 9, 8, tzinfo=timezone.utc))
        self.assertEqual(result["automaticVerdict"], "waiting_release")
        self.assertEqual(result["coverageVerdict"], "waiting_release")
        self.assertFalse(result["windowStarted"])
        self.assertEqual(result["observationSeconds"], 0)

    def test_waiting_release_main_performs_zero_source_queries(self):
        value = config("waiting_release")
        value["requiredComponents"]["globalGateway"]["verified"] = False
        with tempfile.TemporaryDirectory() as directory:
            state_path = Path(directory) / "state.json"
            output_path = Path(directory) / "result.json"
            state_path.write_text(json.dumps(value))
            with patch(
                "collect_acceptance.source_with_error",
                side_effect=AssertionError("waiting state must not collect sources"),
            ):
                self.assertEqual(
                    collect_main(
                        [
                            "--state-file",
                            str(state_path),
                            "--output",
                            str(output_path),
                        ]
                    ),
                    0,
                )
            result = json.loads(output_path.read_text())
        self.assertEqual(result["sourcesQueried"], [])
        self.assertEqual(result["evaluation"]["observationSeconds"], 0)

    def test_any_unverified_required_component_blocks_observation(self):
        value = config("observing")
        value["requiredComponents"]["usKokoro"]["verified"] = False
        with self.assertRaisesRegex(
            ValueError, "observation_cannot_start_with_unverified_components"
        ):
            evaluate(value, healthy_sources(), now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc))

    def test_complete_healthy_fixture_passes(self):
        result = evaluate(
            config(), healthy_sources(), now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["automaticVerdict"], "pass")
        self.assertEqual(result["supplyVerdict"], "pass")
        self.assertEqual(result["clientEvidenceVerdict"], "pass")
        self.assertEqual(result["coverageVerdict"], "pass")
        self.assertEqual(result["verdictScope"], "configured_existing_sources_only")
        limitation_codes = {item["code"] for item in result["evidenceLimitations"]}
        self.assertIn("automatic_verdict_scoped_to_configured_sources", limitation_codes)
        self.assertIn("web_client_events_not_collected", limitation_codes)
        self.assertIn("extension_client_events_not_collected", limitation_codes)
        self.assertIn("clone_first_output_evidence_absent_or_unattributed", limitation_codes)
        self.assertIn("explain_first_output_evidence_absent", limitation_codes)

    def test_read_starts_without_first_audio_are_evidence_gap_not_supply_failure(self):
        sources = healthy_sources()
        ios = sources["mobile"]["aggregate"]["sessionCohorts"]["read"]["byPlatform"]["ios"]
        ios.update(
            {
                "withFirstOutput": 0,
                "withoutFirstOutputInsideWindow": 2,
                "pairedFirstOutputByVoiceFamily": {},
            }
        )
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["supplyVerdict"], "pass")
        self.assertEqual(result["clientEvidenceVerdict"], "insufficient_sample")
        self.assertEqual(result["coverageVerdict"], "pass")
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertEqual(result["technicalFailures"], [])
        gap_codes = {item["code"] for item in result["sampleGaps"]}
        self.assertIn("mobile_read_first_output_sample_missing", gap_codes)
        self.assertIn("mobile_read_start_without_first_output", gap_codes)

    def test_one_paired_and_one_unpaired_read_session_remains_insufficient(self):
        sources = healthy_sources()
        android = sources["mobile"]["aggregate"]["sessionCohorts"]["read"]["byPlatform"]["android"]
        android.update(
            {
                "withFirstOutput": 1,
                "withoutFirstOutputInsideWindow": 1,
                "pairedFirstOutputByVoiceFamily": {"preset": 1},
            }
        )
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["supplyVerdict"], "pass")
        self.assertEqual(result["clientEvidenceVerdict"], "insufficient_sample")
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertNotIn(
            "mobile_read_start_without_first_output",
            {item["code"] for item in result["technicalFailures"]},
        )

    def test_read_start_without_session_id_cannot_be_counted_as_paired(self):
        sources = healthy_sources()
        sources["mobile"]["aggregate"]["sessionCohorts"]["read"]["byPlatform"][
            "android"
        ]["startEventsMissingSessionId"] = 1
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["supplyVerdict"], "pass")
        self.assertEqual(result["clientEvidenceVerdict"], "insufficient_sample")
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertIn(
            "mobile_read_start_missing_session_id",
            {item["code"] for item in result["sampleGaps"]},
        )

    def test_explain_starts_cannot_substitute_for_read_first_audio(self):
        sources = healthy_sources()
        sources["mobile"]["aggregate"]["readStartsByPlatform"]["ios"] = 0
        sources["mobile"]["aggregate"]["sessionCohorts"]["read"]["byPlatform"]["ios"] = {
            "startedSessions": 0,
            "withFirstOutput": 0,
            "withoutFirstOutputInsideWindow": 0,
            "startEventsMissingSessionId": 0,
            "pairedFirstOutputByVoiceFamily": {},
        }
        sources["mobile"]["aggregate"]["startEventsByPlatform"]["ios"] = 3
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["clientEvidenceVerdict"], "insufficient_sample")
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertIn(
            "mobile_read_start_sample_insufficient",
            {item["code"] for item in result["sampleGaps"]},
        )

    def test_23_hours_cannot_pass(self):
        result = evaluate(
            config("observing", 23),
            healthy_sources(),
            now=datetime(2026, 9, 8, tzinfo=timezone.utc),
        )
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertFalse(result["observationRequirementMet"])

    def test_observing_reports_elapsed_watermark_not_configured_duration(self):
        result = evaluate(
            config("observing"),
            healthy_sources(),
            now=datetime(2026, 9, 7, 1, tzinfo=timezone.utc),
        )
        self.assertEqual(result["automaticVerdict"], "observing")
        self.assertEqual(result["observationSeconds"], 3_600)
        self.assertEqual(result["configuredWindowSeconds"], 86_400)
        self.assertFalse(result["observationRequirementMet"])
        self.assertEqual(result["finalVersionObservationSeconds"], 3_600)
        self.assertEqual(result["coverageVerdict"], "observing")

    def test_observing_with_missing_source_reports_coverage_gap(self):
        sources = healthy_sources()
        del sources["monitor_cn"]
        result = evaluate(
            config("observing"),
            sources,
            now=datetime(2026, 9, 7, 1, tzinfo=timezone.utc),
        )
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertEqual(result["supplyVerdict"], "inconclusive")
        self.assertEqual(result["coverageVerdict"], "inconclusive")

    def test_missing_android_145_sample_keeps_supply_pass_but_overall_inconclusive(self):
        sources = healthy_sources()
        sources["direct_gateway"]["aggregate"]["android145Preset"] = {
            "requests": 0,
            "statusCounts": {},
        }
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["supplyVerdict"], "pass")
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertIn(
            "android_145_gateway_sample_missing",
            {item["code"] for item in result["sampleGaps"]},
        )

    def test_healthy_probes_do_not_override_client_failure(self):
        sources = healthy_sources()
        sources["mobile"]["aggregate"]["technicalFailureEvents"] = 2
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["automaticVerdict"], "fail")
        self.assertEqual(result["supplyVerdict"], "pass")
        self.assertEqual(result["clientEvidenceVerdict"], "fail")
        self.assertEqual(result["coverageVerdict"], "pass")
        self.assertIn(
            "healthy_probe_client_failure_contradiction",
            {item["code"] for item in result["technicalFailures"]},
        )

    def test_supply_failure_does_not_erase_clean_client_evidence_or_coverage(self):
        sources = healthy_sources()
        sources["direct_gateway"]["aggregate"]["statusCounts"] = {"502": 1}
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["automaticVerdict"], "fail")
        self.assertEqual(result["supplyVerdict"], "fail")
        self.assertEqual(result["clientEvidenceVerdict"], "pass")
        self.assertEqual(result["coverageVerdict"], "pass")

    def test_verified_direct_gateway_requires_runtime_file_fingerprint(self):
        value = config()
        del value["requiredComponents"]["directGateway"]["runtimeSourceSha256"]
        with self.assertRaisesRegex(
            ValueError, "direct_gateway_runtime_source_invalid"
        ):
            evaluate(
                value,
                healthy_sources(),
                now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc),
            )

    def test_global_capabilities_drift_cannot_pass_silently(self):
        sources = healthy_sources()
        sources["global_capabilities"]["identity"]["deploymentId"] = "dpl_other"
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertEqual(result["supplyVerdict"], "inconclusive")
        self.assertEqual(result["coverageVerdict"], "inconclusive")
        self.assertIn(
            "global_gateway_deployment_mismatch",
            {item["code"] for item in result["dataOrCoverageGaps"]},
        )

    def test_kokoro_runtime_drift_cannot_pass_silently(self):
        sources = healthy_sources()
        sources["kokoro_us"]["identity"]["runtimeSourceSha256"] = "changed"
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertEqual(result["supplyVerdict"], "inconclusive")
        self.assertIn(
            "kokoro_runtime_source_mismatch",
            {item["code"] for item in result["dataOrCoverageGaps"]},
        )

    def test_capabilities_region_mismatch_is_supply_failure(self):
        sources = healthy_sources()
        sources["global_capabilities"]["identity"]["region"] = "cn"
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["automaticVerdict"], "fail")
        self.assertEqual(result["supplyVerdict"], "fail")
        self.assertIn(
            "global_capabilities_region_mismatch",
            {item["code"] for item in result["technicalFailures"]},
        )

    def test_quota_block_is_separate_and_does_not_fail(self):
        sources = healthy_sources()
        sources["mobile"]["aggregate"]["quotaBlockedEvents"] = 3
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["automaticVerdict"], "pass")
        self.assertIn(
            "business_quota_blocked_separate",
            {item["code"] for item in result["advisories"]},
        )

    def test_mid_window_release_does_not_extend_end_and_is_inconclusive(self):
        value = config()
        value["requiredComponents"]["directGateway"].update(
            {
                "activeFromUtc": "2026-09-07T12:00:00Z",
                "verifiedAtUtc": "2026-09-07T12:01:00Z",
            }
        )
        result = evaluate(
            value, healthy_sources(), now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertTrue(result["mixedVersionWindow"])
        self.assertEqual(result["finalVersionObservationSeconds"], 43_140)
        self.assertEqual(result["supplyVerdict"], "inconclusive")
        self.assertEqual(result["clientEvidenceVerdict"], "inconclusive")
        self.assertEqual(result["coverageVerdict"], "pass")
        self.assertEqual(
            result["versionSegments"]["directGateway"],
            [
                {
                    "startUtc": "2026-09-07T00:00:00Z",
                    "endUtc": "2026-09-07T12:00:00Z",
                    "seconds": 43_200,
                    "version": "unknown_before_first_recorded_release",
                },
                {
                    "startUtc": "2026-09-07T12:00:00Z",
                    "endUtc": "2026-09-08T00:00:00Z",
                    "seconds": 43_200,
                    "version": DIRECT_COMMIT,
                },
            ],
        )
        self.assertTrue(result["stopAtConfiguredEnd"])
        self.assertFalse(result["automaticExtensionAllowed"])

    def test_missing_mobile_source_cannot_overall_pass(self):
        sources = healthy_sources()
        del sources["mobile"]
        result = evaluate(
            config(), sources, now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc)
        )
        self.assertEqual(result["supplyVerdict"], "pass")
        self.assertEqual(result["automaticVerdict"], "inconclusive")
        self.assertEqual(result["coverageVerdict"], "inconclusive")

    def test_legacy_two_component_state_cannot_start_observation(self):
        value = config("observing")
        del value["requiredComponents"]["usKokoro"]
        with self.assertRaisesRegex(ValueError, "required_components_missing:usKokoro"):
            evaluate(value, healthy_sources(), now=datetime(2026, 9, 8, 1, tzinfo=timezone.utc))


class GatewayJournalParserTests(unittest.TestCase):
    def test_multiline_whole_and_split_console_records(self):
        start = parse_utc("2026-09-07T00:00:00Z")
        entries = [
            (
                start + timedelta(seconds=1),
                """tts_gateway_request {
  requestId: 'private-one',
  method: 'POST',
  path: '/api/captioned_speech_partly',
  status: 200,
  requestBytes: 120,
  elapsedMs: 900,
  clientPlatform: 'android',
  clientVersion: '1.0.45'
}""",
            ),
            (start + timedelta(seconds=2), "tts_gateway_request {"),
            (start + timedelta(seconds=2), "  requestId: 'private-two',"),
            (start + timedelta(seconds=2), "  method: 'POST',"),
            (start + timedelta(seconds=2), "  path: '/api/captioned_speech_partly',"),
            (start + timedelta(seconds=2), "  status: 502,"),
            (start + timedelta(seconds=2), "  requestBytes: 140,"),
            (start + timedelta(seconds=2), "  elapsedMs: 1200,"),
            (start + timedelta(seconds=2), "  clientPlatform: 'android',"),
            (start + timedelta(seconds=2), "  clientVersion: '1.0.45'"),
            (start + timedelta(seconds=2), "}"),
            (
                start + timedelta(seconds=3),
                """tts_gateway_error {
  requestId: 'private-two',
  name: 'TypeError',
  message: 'fetch failed'
}""",
            ),
        ]
        result = aggregate_entries(entries, start, start + timedelta(minutes=1))
        self.assertEqual(result["statusCounts"], {"200": 1, "502": 1})
        self.assertEqual(result["android145Preset"]["requests"], 2)
        self.assertEqual(result["consoleErrorClassCounts"], {"upstream_network": 1})
        self.assertNotIn("private-one", json.dumps(result))
        self.assertNotIn("private-two", json.dumps(result))


class MonitorAggregationTests(unittest.TestCase):
    def test_consecutive_failure_and_recovery_are_preserved(self):
        rows = [
            {"observedAt": "2026-09-07T00:00:00Z", "status": "supply_failed"},
            {"observedAt": "2026-09-07T00:05:00Z", "status": "supply_failed"},
            {"observedAt": "2026-09-07T00:10:00Z", "status": "healthy"},
            {"observedAt": "2026-09-07T00:15:00Z", "status": "supply_failed"},
        ]
        result = consecutive_summary(
            rows, lambda row: row["status"] == "supply_failed"
        )
        self.assertEqual(result["episodes"], 2)
        self.assertEqual(result["maximumConsecutiveCycles"], 2)
        self.assertEqual(result["currentConsecutiveCycles"], 1)
        self.assertEqual(
            result["recoveryEvents"],
            [
                {
                    "observedAtUtc": "2026-09-07T00:10:00Z",
                    "precedingCycles": 2,
                    "recoveredStatus": "healthy",
                }
            ],
        )


class CollectorSanitizationTests(unittest.TestCase):
    def test_capabilities_retains_only_release_commit_and_region(self):
        manifest = {
            "releaseId": "dpl_Example123",
            "commitSha": "a" * 40,
            "voiceClone": {
                "serviceRoute": "global",
                "workerUrl": "https://private.invalid",
                "token": "must-not-survive",
            },
            "unrelated": {"customer": "must-not-survive"},
        }

        class Response:
            status = 200

            def read(self, _limit):
                return json.dumps(manifest).encode()

        class Connection:
            def __init__(self, *_args, **_kwargs):
                pass

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                return Response()

            def close(self):
                pass

        with patch("collect_acceptance.http.client.HTTPSConnection", Connection):
            result = collect_global_capabilities({"sources": {}})
        encoded = json.dumps(result)
        self.assertEqual(
            result["identity"],
            {
                "deploymentId": "dpl_Example123",
                "commitSha": "a" * 40,
                "region": "global",
            },
        )
        self.assertNotIn("must-not-survive", encoded)
        self.assertNotIn("private.invalid", encoded)


class MobileAggregationTests(unittest.TestCase):
    def test_first_output_pairs_by_platform_session_and_time(self):
        start = parse_utc("2026-09-07T00:00:00Z")
        end = parse_utc("2026-09-08T00:00:00Z")
        rows = [
            {
                "event_id": "ios-first-before-start",
                "eventName": "read_first_audio",
                "analytics_anonymous_id": "same-device",
                "client_platform": "ios",
                "received_at": "2026-09-07T00:30:00Z",
                "environment": "production",
                "readSession": "shared-session-value",
            },
            {
                "event_id": "ios-start",
                "eventName": "read_start",
                "analytics_anonymous_id": "same-device",
                "client_platform": "ios",
                "received_at": "2026-09-07T01:00:00Z",
                "environment": "production",
                "readSession": "shared-session-value",
                "voiceId": "af_heart",
            },
            {
                "event_id": "android-start",
                "eventName": "read_start",
                "analytics_anonymous_id": "same-device",
                "client_platform": "android",
                "received_at": "2026-09-07T01:00:00Z",
                "environment": "production",
                "readSession": "shared-session-value",
                "voiceId": "ef_dora",
            },
            {
                "event_id": "android-first-after-start",
                "eventName": "read_first_audio",
                "analytics_anonymous_id": "same-device",
                "client_platform": "android",
                "received_at": "2026-09-07T01:00:01Z",
                "environment": "production",
                "readSession": "shared-session-value",
            },
            {
                "event_id": "ios-start-without-session",
                "eventName": "read_start",
                "analytics_anonymous_id": "same-device",
                "client_platform": "ios",
                "received_at": "2026-09-07T02:00:00Z",
                "environment": "production",
                "voiceId": "af_heart",
            },
        ]
        result = aggregate_mobile(rows, {"complete": True}, start, end)
        by_platform = result["aggregate"]["sessionCohorts"]["read"]["byPlatform"]
        self.assertEqual(by_platform["android"]["withFirstOutput"], 1)
        self.assertEqual(by_platform["android"]["withoutFirstOutputInsideWindow"], 0)
        self.assertEqual(by_platform["ios"]["withFirstOutput"], 0)
        self.assertEqual(by_platform["ios"]["withoutFirstOutputInsideWindow"], 1)
        self.assertEqual(by_platform["ios"]["startEventsMissingSessionId"], 1)
        self.assertEqual(result["aggregate"]["technicalFailureEvents"], 0)
        encoded = json.dumps(result)
        self.assertNotIn("same-device", encoded)
        self.assertNotIn("shared-session-value", encoded)

    def test_server_clock_production_filter_and_quota_separation(self):
        start = parse_utc("2026-09-07T00:00:00Z")
        end = parse_utc("2026-09-08T00:00:00Z")
        rows = [
            {
                "event_id": "a",
                "eventName": "read_start",
                "analytics_anonymous_id": "device-a",
                "client_platform": "android",
                "received_at": "2026-09-07T01:00:00Z",
                "environment": "production",
                "result": None,
                "readSession": "session-a",
                "voiceId": "ef_dora",
                "clientVersion": "1.0.45",
            },
            {
                "event_id": "b",
                "eventName": "read_end",
                "analytics_anonymous_id": "device-a",
                "client_platform": "android",
                "received_at": "2026-09-07T01:05:00Z",
                "environment": "production",
                "result": "blocked",
                "endReason": "listen_quota",
                "readSession": "session-a",
            },
            {
                "event_id": "c",
                "eventName": "read_end",
                "analytics_anonymous_id": "device-b",
                "client_platform": "ios",
                "received_at": "2026-09-07T02:00:00Z",
                "environment": "development",
                "result": "failed",
            },
        ]
        result = aggregate_mobile(rows, {"complete": True}, start, end)
        self.assertEqual(result["coverage"]["productionTaggedRows"], 2)
        self.assertEqual(result["coverage"]["nonProductionRowsExcluded"], 1)
        self.assertEqual(result["aggregate"]["quotaBlockedEvents"], 1)
        self.assertEqual(result["aggregate"]["technicalFailureEvents"], 0)

    def test_transport_closed_failure_is_not_reclassified_as_user_cancel(self):
        start = parse_utc("2026-09-07T00:00:00Z")
        rows = [
            {
                "event_id": "failure-a",
                "event_name": "read_end",
                "analytics_anonymous_id": "device-a",
                "client_platform": "android",
                "received_at": "2026-09-07T01:00:00Z",
                "environment": "production",
                "result": "failed",
                "endReason": "transport_closed",
            }
        ]
        result = aggregate_mobile(
            rows, {"complete": True}, start, parse_utc("2026-09-08T00:00:00Z")
        )
        self.assertEqual(result["aggregate"]["technicalFailureEvents"], 1)
        self.assertEqual(result["aggregate"]["cancelledEvents"], 0)


if __name__ == "__main__":
    unittest.main()
