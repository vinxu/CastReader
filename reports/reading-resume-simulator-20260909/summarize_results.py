"""Keep each run's result and the latest verification of every test case."""
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent
runs, latest, samples, previously_failed = [], {}, {}, set()
for filename in [
    "final-regression.log", "web-layout-regression.log",
    "network-and-visual-regression.log", "google-network-diagnosis.log",
    "google-network-final.log",
]:
    path = root / filename
    log = path.read_text(errors="replace") if path.exists() else ""
    run_cases = []
    active_test = None
    for line in log.splitlines():
        started = re.search(r"Test Case '-\[(\S+) (\S+)\]' started\.", line)
        if started:
            active_test = "/".join(started.groups())
        finished = re.search(r"Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)\.", line)
        if finished:
            suite, test, result, seconds = finished.groups()
            key = suite + "/" + test
            case = {"suite": suite, "test": test, "result": result,
                    "seconds": float(seconds), "verifiedIn": filename}
            if result == "failed":
                previously_failed.add(key)
            case["failedInAnEarlierRun"] = key in previously_failed and result != "failed"
            latest[key] = case
            run_cases.append(case)
        if line.startswith("RESUME_ACCEPTANCE "):
            values = dict(field.split("=", 1) for field in line.split()[1:])
            for key in ["stopped", "first", "tolerance"]:
                values[key] = float(values[key])
            values["test"] = active_test
            values["verifiedIn"] = filename
            values["absoluteSampleDifferenceSeconds"] = abs(values["first"] - values["stopped"])
            samples[active_test] = values
    runs.append({"log": filename,
                 "completed": "** TEST SUCCEEDED **" in log or "** TEST FAILED **" in log,
                 "succeeded": "** TEST SUCCEEDED **" in log,
                 "totals": {r: sum(c["result"] == r for c in run_cases) for r in ["passed", "failed", "skipped"]}})

cases = list(latest.values())
completed = all(r["completed"] for r in runs)

report = {
    "aggregation": "Latest result per test after a full run and the affected-scope corrective regression; original run outcomes are retained.",
    "runs": runs,
    "completed": completed,
    "succeeded": completed and bool(cases) and all(c["result"] == "passed" for c in cases),
    "simulator": "982F22E5-53B0-46F8-8CC8-55D055F22D49",
    "runtime": "iOS 26.5",
    "totals": {result: sum(c["result"] == result for c in cases) for result in ["passed", "failed", "skipped"]},
    "cases": cases,
    "resumeSamples": list(samples.values()),
    "limitations": [
        "Deterministic UI tests use real parsers, renderers, persistence and AVPlayer, with generated silent WAV segments.",
        "The explicit live EPUB test uses TTSService and the cloud speech endpoint.",
        "Authenticated third-party library page/chapter navigation is not certified by these fixtures.",
        "Cross-device synchronization, reinstallation recovery and reminders are not implemented by this MVP.",
    ],
}
(root / "final-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({key: report[key] for key in ["completed", "succeeded", "totals"]}))
