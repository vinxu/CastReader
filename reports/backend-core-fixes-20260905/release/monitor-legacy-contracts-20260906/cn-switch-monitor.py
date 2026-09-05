#!/usr/bin/env python3
"""CAS-guarded CN monitor-only switch; business services are read-only."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


ROOT = Path("/opt/castreader-core-audio-monitor")
CURRENT = ROOT / "current"
OLD = ROOT / "releases/272d3148-5c085a61"
NEW = ROOT / "releases/f6eb6691-7a2c0b1f"
OLD_TREE = "07a96474a70a9814e9b7882b3e26ac9b16a8681bcfdc305b19ce033987841833"
NEW_TREE = "7a2c0b1f0715d4db766a26fe84a5899a1c77b3107f2119d0907d766cef12236a"
BASELINE = Path("/tmp/castreader-cn-monitor-before-f6eb6691.json")
CAPTURE = Path("/tmp/castreader-cn-monitor-capture-f6eb6691.py")
STATE = Path("/var/lib/castreader-core-audio-monitor/cn/latest.json")
SERVICE = "castreader-core-audio-monitor@cn.service"
TIMER = "castreader-core-audio-monitor@cn.timer"
BUSINESS_UNITS = [
    "castreader.service", "castreader-quickread-cn.service",
    "castreader-cn-kokoro-tunnel.service", "castreader-cn-clone-tunnel.service",
    "nginx.service",
]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    value = hashlib.sha256()
    size = 0
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
            size += len(block)
    return {"bytes": size, "sha256": value.hexdigest()}


def tree(root):
    root = Path(root)
    rows = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            rows.append({"path": path.relative_to(root).as_posix(), **digest(path)})
    encoded = b"".join(
        row["path"].encode() + b"\0" + str(row["bytes"]).encode()
        + b"\0" + row["sha256"].encode() + b"\n" for row in rows
    )
    return {"files": len(rows), "tree_sha256": hashlib.sha256(encoded).hexdigest()}


def show(unit, fields):
    raw = subprocess.check_output(
        ["systemctl", "show", unit, *sum((["-p", field] for field in fields), []), "--no-pager"], text=True,
    )
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


def capture():
    return json.loads(subprocess.check_output(["/usr/bin/python3", "-B", str(CAPTURE)], text=True, timeout=30))


def latest():
    try:
        return json.loads(STATE.read_text())
    except FileNotFoundError:
        return None


def safe_outcome(value):
    if value is None:
        return None
    segments = [
        {name: row.get(name) for name in (
            "index", "attempts", "requestContract", "processedCharacters",
            "remainingCharacters", "audioBytes", "durationSeconds", "timestampsOk",
            "timestampCount", "gateway", "upstreamNode", "upstreamSource", "upstreamRevision",
        )} for row in value.get("segments", [])
    ]
    return {
        name: value.get(name) for name in (
            "schemaVersion", "probe", "observedAt", "region", "endpoint", "inputSha256",
            "inputCharacters", "language", "locale", "voice", "supplyOk", "alignmentOk",
            "status", "failureCode", "failedRequestContract", "elapsedMs", "segmentCount",
            "totalAudioBytes", "totalDurationSeconds",
        )
    } | {"segments": segments}


def protected_differences(before, after):
    differences = []
    for name in BUSINESS_UNITS:
        if before["services"][name] != after["services"][name]:
            differences.append(f"service:{name}")
    for name in ("target", "link_inode", "link_mtime_ns", "descriptor", "process", "material"):
        if before["next"][name] != after["next"][name]:
            differences.append(f"next:{name}")
    if before["quickread"]["process"] != after["quickread"]["process"]:
        differences.append("quickread:process")
    if before["config"] != after["config"]:
        differences.append("config")
    return differences


def validate_protected(value):
    for name in BUSINESS_UNITS:
        state = value["services"][name]
        require(state["ActiveState"] == "active", f"business service inactive: {name}")
        require(state["NRestarts"] == "0", f"business service restart count differs: {name}")
    require(value["next"]["target"] == "/opt/castreader/release-20260904120513", "Next target differs")
    require(value["next"]["descriptor"] == {
        "releaseId": "release-20260904120513",
        "sourceCommit": "62386e902cb7201919e9680e56c82c8627b47110",
    }, "Next descriptor differs")
    require(value["next"]["health"].get("status") == 200, "Next health failed")
    require(value["quickread"]["process"]["cwd"] == "/opt/castreader-quickread-cn/releases/20260906-quickread-playback-continuity-3d68d82-cn", "QuickRead target differs")
    require(value["quickread"]["health"].get("status") == 200, "QuickRead health failed")
    require(value["tunnels"]["kokoro_health"].get("status") == 200, "Kokoro tunnel health failed")
    require(value["tunnels"]["clone_health"].get("status") == 200, "clone tunnel health failed")


def atomic_current(target):
    temporary = ROOT / f".current-{target.name}-{os.getpid()}"
    require(not temporary.exists() and not temporary.is_symlink(), "temporary symlink exists")
    os.symlink(str(target), temporary)
    os.replace(temporary, CURRENT)
    descriptor = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


baseline = json.loads(BASELINE.read_text())
transaction = {
    "schema": "castreader.cn-monitor-switch.v1",
    "started_at_utc": datetime.now(timezone.utc).isoformat(),
    "old_release": str(OLD), "new_release": str(NEW),
    "business_services_restarted": [], "units_modified": False,
    "timer_temporarily_stopped": False, "switched": False, "rolled_back": False,
}
timer_initial = show(TIMER, ["ActiveState", "SubState", "UnitFileState"])
transaction["timer_before"] = timer_initial
require(timer_initial["ActiveState"] == "active" and timer_initial["UnitFileState"] == "enabled", "timer baseline differs")

try:
    subprocess.run(["systemctl", "stop", TIMER], check=True, timeout=15)
    transaction["timer_temporarily_stopped"] = True
    deadline = time.monotonic() + 160
    while show(SERVICE, ["ActiveState"])["ActiveState"] not in {"inactive", "failed"}:
        require(time.monotonic() < deadline, "monitor oneshot did not finish")
        time.sleep(0.5)
    subprocess.run(["systemctl", "reset-failed", SERVICE], check=False, timeout=10)
    require(show(SERVICE, ["ActiveState"])["ActiveState"] == "inactive", "monitor oneshot not inactive")

    require(CURRENT.resolve(strict=True) == OLD, "monitor current drifted")
    require(tree(OLD) == {"files": 9, "tree_sha256": OLD_TREE}, "old monitor tree drifted")
    require(tree(NEW) == {"files": 9, "tree_sha256": NEW_TREE}, "new monitor tree drifted")
    fresh = capture()
    validate_protected(fresh)
    require(protected_differences(baseline, fresh) == [], "fresh business CAS differs from approved baseline")
    transaction["protected_before"] = fresh
    prior = latest()
    transaction["prior_observed_at"] = prior.get("observedAt") if prior else None

    atomic_current(NEW)
    transaction["switched"] = True
    require(CURRENT.resolve(strict=True) == NEW and tree(NEW)["tree_sha256"] == NEW_TREE, "current switch verification failed")
    manual_started = datetime.now(timezone.utc)
    run = subprocess.run(["systemctl", "start", SERVICE], capture_output=True, text=True, timeout=160)
    transaction["manual_service"] = {
        "started_at_utc": manual_started.isoformat(),
        "finished_at_utc": datetime.now(timezone.utc).isoformat(),
        "systemctl_exit": run.returncode,
        "service": show(SERVICE, ["ActiveState", "SubState", "Result", "ExecMainStatus"]),
    }
    outcome = latest()
    require(outcome is not None and outcome.get("observedAt") != transaction["prior_observed_at"], "manual result missing")
    require(outcome.get("region") == "cn", "manual region differs")
    require(outcome.get("endpoint") == "https://api.castreader.cn/api/captioned_speech_partly", "manual endpoint differs")
    require(outcome.get("language") == "zh" and outcome.get("voice") == "zf_001", "manual fixed contract differs")
    require(outcome.get("status") in {"healthy", "alignment_degraded", "supply_failed"}, "monitor program fault")
    require(outcome.get("status") != "monitor_error", "monitor program fault")
    if outcome.get("supplyOk"):
        segments = outcome.get("segments", [])
        require(outcome.get("segmentCount") == len(segments) and len(segments) >= 2, "continuity segment count differs")
        require(sum(row.get("processedCharacters", 0) for row in segments) == outcome.get("inputCharacters"), "full text was not consumed")
        require(segments[-1].get("remainingCharacters") == 0, "final remainder is not empty")
        require(outcome.get("totalAudioBytes", 0) > 0 and outcome.get("totalDurationSeconds", 0) > 0, "playable audio missing")
        expected = ["stream_omitted", "stream_true", "stream_false"]
        require([row.get("requestContract") for row in segments] == [expected[index % 3] for index in range(len(segments))], "request contracts differ")
    else:
        require(isinstance(outcome.get("failureCode"), str) and outcome.get("failureCode"), "supply failure missing code")
    transaction["manual_result"] = safe_outcome(outcome)

    try:
        after = capture()
        validate_protected(after)
        transaction["protected_after"] = after
        transaction["protected_drift_after"] = protected_differences(fresh, after)
    except Exception as after_error:
        transaction["protected_after_capture_error"] = str(after_error)
    transaction["status"] = "committed"
except Exception as error:
    transaction["error"] = str(error)
    if transaction["switched"]:
        try:
            atomic_current(OLD)
            transaction["rolled_back"] = True
        except Exception as rollback_error:
            transaction["rollback_error"] = str(rollback_error)
    transaction["status"] = "rolled_back" if transaction["rolled_back"] else "aborted"
finally:
    if transaction["timer_temporarily_stopped"]:
        subprocess.run(["systemctl", "reset-failed", SERVICE], check=False, timeout=10)
        timer_start = subprocess.run(["systemctl", "start", TIMER], capture_output=True, text=True, timeout=15)
        transaction["timer_restart_exit"] = timer_start.returncode
    transaction["timer_after"] = show(TIMER, ["ActiveState", "SubState", "UnitFileState"])
    if transaction.get("status") == "committed" and (
        transaction.get("timer_restart_exit") != 0 or transaction["timer_after"].get("ActiveState") != "active"
    ):
        atomic_current(OLD)
        transaction["rolled_back"] = True
        transaction["status"] = "rolled_back"
        transaction["error"] = "monitor timer did not resume"
        subprocess.run(["systemctl", "start", TIMER], check=False, timeout=15)
        transaction["timer_after_rollback"] = show(TIMER, ["ActiveState", "SubState", "UnitFileState"])
    transaction["current_after"] = str(CURRENT.resolve(strict=True))
    transaction["finished_at_utc"] = datetime.now(timezone.utc).isoformat()

print(json.dumps(transaction, sort_keys=True))
if transaction["status"] != "committed":
    raise SystemExit(1)
