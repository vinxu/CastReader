#!/usr/bin/env python3
"""Rebuild a read-only incident summary from fixed-window evidence."""
from pathlib import Path
import collections
from datetime import datetime
import hashlib
import json
import statistics

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FINAL = ROOT / "reports/audio-playback-recovery-rollout-20260907/monitoring/observations/window-complete-20260907T183752Z"
DIRECT = Path("/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-direct-tts-text-parity-20260907")
ANDROID = Path("/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905")
PROXY = Path("/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-inflight-diagnostics-20260907")

def read(path):
    return json.loads(path.read_text())

def digest(path):
    raw = path.read_bytes()
    return {"path": str(path), "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}

def summary(values):
    return {"count": len(values), "min": min(values), "median": statistics.median(values), "max": max(values)}

joined = read(HERE / "archived-proxy-joins.json")
targeted = read(HERE / "proxy-targeted-readback.json")
direct = read(FINAL / "direct-complete-cumulative-final.json")
followup = read(FINAL / "disconnect-followup.json")
records = joined["targetRecords"]
events = targeted["events"]
assert len(records) == len({r["key"] for r in records}) == 74
assert not joined["missingKeys"]
assert targeted["coverage"]["spansWindow"] and targeted["coverage"]["sameInodeAfter"]
assert targeted["coverage"]["notTruncatedDuringRead"] and targeted["source"]["matchesPinned"]
assert targeted["coverage"]["malformedProxyEvents"] == 0
assert {r["abortSource"] for r in records} == {"downstream_closed"}
assert {r["abortStage"] for r in records} == {"upstream_headers"}
assert {r["status"] for r in records} == {None}
by_key = collections.defaultdict(list)
for e in events:
    by_key[e["requestKey"]].append(e)
assert set(by_key) == {r["key"] for r in records}
per_request = []
delta = []
for r in records:
    es = by_key[r["key"]]
    terminal = [e for e in es if e["stage"] == "request_finished"]
    cancels = [e for e in terminal if e.get("outcome") == "cancelled"]
    for c in cancels:
        observed = datetime.fromisoformat(r["observedAt"].replace("Z", "+00:00")).timestamp()
        delta.append((c["timeUnix"] - observed) * 1000)
    per_request.append({
        "direct": r, "proxyReceived": sum(e["stage"] == "request_received" for e in es),
        "proxyStages": dict(collections.Counter(e["stage"] for e in es)),
        "proxyOutcomes": dict(collections.Counter(e.get("outcome") for e in terminal)),
        "proxyTerminalEvents": terminal,
        "upstreamCancelResponseBytes": [e.get("responseBytes") for e in es if e["stage"] == "upstream_cancelled"],
        "initialCallerCause": "unproven", "userPlaybackOutcome": "unproven",
    })

cohorts = collections.defaultdict(collections.Counter)
for row in direct["aggregate"]["clientStatusCounts"]:
    cohorts[row["clientPlatform"], row["clientVersion"]][row["status"]] += row["count"]
cohort_summary = [
    {"platform": p, "version": v, "recordedStatusCounts": dict(counts), "recordedTotal": sum(counts.values()),
     "noResponsePercent": counts["no_response"] / sum(counts.values()) * 100}
    for (p, v), counts in cohorts.items()
]
cancel_events = [e for e in events if e["stage"] == "upstream_cancelled"]
assert len(cancel_events) == 73 and all(e["responseBytes"] == 0 for e in cancel_events)
assert not [e for e in events if e["stage"] in {"request_failed", "upstream_failed"}]

sources = [
    DIRECT / "ops/tts-direct-gateway/gateway.mjs",
    DIRECT / "ops/tts-direct-gateway/gateway.test.mjs",
    DIRECT / "ops/tts-direct-gateway/Caddyfile.production",
    PROXY / "deployment/r133_stable_proxy.py",
    ANDROID / "app/src/main/java/com/same/castreader/player/manager/PlaybackController.kt",
    ANDROID / "app/src/main/java/com/same/castreader/player/manager/ParagraphPrefetchHorizon.kt",
    ANDROID / "app/src/main/java/com/same/castreader/data/remote/TtsEndpointInterceptor.kt",
    ANDROID / "app/src/main/java/com/same/castreader/data/remote/CastReaderApi.kt",
    ANDROID / "app/src/main/java/com/same/castreader/di/NetworkModule.kt",
    ANDROID / "gradle/libs.versions.toml",
    ANDROID / "app/build.gradle.kts",
]
report = {
    "schema": "castreader.global-tts-disconnect-causal-review.v1",
    "readOnly": True, "productionModified": False, "synthesisStarted": False,
    "rawContentExported": False, "incidentClosed": False,
    "fixedWindow": direct["query"],
    "lastIncrement": {"window": followup["window"], "count": followup["newNoResponse"]},
    "recordedStatusCounts": direct["aggregate"]["statusCounts"],
    "noResponseCount": len(records), "elapsedMs": summary([r["elapsedMs"] for r in records]),
    "cohorts": cohort_summary,
    "proxy": {
        "matchingEventCount": len(events), "uniqueRequestKeys": len(by_key),
        "receivedRequests": sum(e["stage"] == "request_received" for e in events),
        "stages": dict(collections.Counter(e["stage"] for e in events)),
        "outcomes": dict(collections.Counter(e.get("outcome") for e in events if e["stage"] == "request_finished")),
        "newConnectionMs": summary([e["connectMs"] for e in events if "connectMs" in e]),
        "proxyTerminalMinusDirectJournalMs": summary(delta),
        "crossHostClockPrecisionVerified": False,
        "repeatedKey": "77601dd021ec365fe333",
        "completeBeforeDirectClosedKey": "5227410452a5955e31d8",
    },
    "findings": {
        "observedTrigger": "Direct response close/request aborted before response headers; gateway then aborts upstream transport.",
        "upstreamFailuresBeforeCancellation": 0,
        "timeoutBeforeCancellation": False,
        "caddyHistoricalTargetAccessRecords": 0,
        "knownSourceCancellationPath": "Ordinary natural paragraph advance invokes loadParagraph -> cancelPrefetchJobs -> Job.cancel -> Retrofit Call.cancel.",
        "sourcePathExceptions": ["Kindle in-flight successor handoff", "YouTube in-flight successor handoff"],
        "cancellationPathAlsoPresentIn145": True,
        "introducedIn146Proven": False,
        "historical74AttributedToThisSourcePath": False,
        "clientSourcePin": "3fe41d62b9f0c1d699ba20e84aecb63fd970b33b (1.0.46 / 53)",
        "clientBinaryProvenanceFromHeadersAlone": False,
        "directSourcePin": "7d0a22ce8169fb6b6fe8aa3e80a08ae3804ee161",
        "denominatorLimitation": "Recorded Direct request summaries only; max-in-flight 503 branch returns before request logging.",
    },
    "tests": {
        "command": "node --test --test-name-pattern='abort source and downstream connection evidence' ops/tts-direct-gateway/gateway.test.mjs",
        "cwd": str(DIRECT), "nodeVersion": "v24.11.1", "productionNodeVersion": "v22.23.2",
        "passed": 6, "failed": 0,
        "cases": ["headers deadline -> real 504/upstream_timeout", "real downstream HTTP close waiting headers -> null/downstream_closed and upstream transport closes",
                  "body deadline -> real 504/upstream_timeout", "real downstream HTTP close reading body -> null/downstream_closed and upstream transport closes",
                  "upstream AbortError without local deadline -> 502/upstream abort", "incomplete upload -> downstream close, no synthesis dispatch"],
        "runtimeParityLimitation": "Tests used exact production source locally on Node 24; not a production Node 22 runtime replay.",
        "androidRuntimeReproductionPerformed": False,
    },
    "sourceEvidence": [digest(p) for p in sources],
    "archivedEvidence": [digest(FINAL / name) for name in ["direct-complete-cumulative-final.json", "disconnect-followup.json"]]
        + [digest(Path(p)) for p in sorted({row["path"] for rows in joined["matches"].values() for row in rows})],
    "requestEvidence": per_request,
}
(HERE / "root-cause-review.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"noResponse": len(records), "proxyEvents": len(events), "proxyOutcomes": report["proxy"]["outcomes"], "incidentClosed": False}))
