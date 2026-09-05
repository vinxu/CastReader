#!/usr/bin/env python3
"""CAS-guarded US monitor-only switch. Never restarts a business service."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request


ROOT = Path("/opt/castreader-core-audio-monitor")
CURRENT = ROOT / "current"
OLD = ROOT / "releases/272d3148-5c085a61"
NEW = ROOT / "releases/f6eb6691-7a2c0b1f"
EXPECTED_OLD_TREE = "07a96474a70a9814e9b7882b3e26ac9b16a8681bcfdc305b19ce033987841833"
EXPECTED_NEW_TREE = "7a2c0b1f0715d4db766a26fe84a5899a1c77b3107f2119d0907d766cef12236a"
QUICKREAD_LINK = Path("/root/castreader/video-pipeline")
EXPECTED_QUICKREAD = Path("/root/castreader/routing-releases/20260906-quickread-playback-continuity-3d68d82-us")
EXPECTED_QUICKREAD_TREE = "386c0297e96e18473152432a9efd5ac374d30ec8bc37de886fc62d6e6c557edd"
EXPECTED_PID = 543663
EXPECTED_START_TICKS = "182086288"
EXPECTED_ARGV_SHA = "9a0e7b4118a1ab1c870da34c37ea82fe5f4ec2a18d78baf3eda54d3732be35ec"
EXPECTED_UNIT_HASHES = {
    "/etc/systemd/system/castreader-core-audio-monitor@.service": "65fe20188f2b15af652e614d81e3fdf6b3e90de71670c1e352f5827a9e6f6916",
    "/etc/systemd/system/castreader-core-audio-monitor@.timer": "d7cf2893eb75f9c9397958ce8fe0c3833228c9c6decedae2bee36b6bc076be92",
}
EXPECTED_INFRA_HASHES = {
    "/etc/caddy/Caddyfile": "243706a702274b86cea400b4ff0c627ddead335e2dfb457fe62303952b30bdd1",
    "/usr/bin/node": "3517c2df0b2f8cd7f422b4b8450ef81c6889f08eb03e281d6de9079b15e6a327",
    "/usr/bin/ffmpeg": "ed16af623947494a72e284b6eb8ff225f2da22b38b5d5069c2fd4b4ba3384e41",
}
SOURCE_SUFFIXES = {".mjs", ".cjs", ".js", ".json", ".sh"}
SERVICE = "castreader-core-audio-monitor@us.service"
TIMER = "castreader-core-audio-monitor@us.timer"
STATE = Path("/var/lib/castreader-core-audio-monitor/us/latest.json")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def tree_digest(root, source_only=False):
    root = Path(root)
    rows = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(root).as_posix()
        if source_only and (
            relative.split("/", 1)[0] not in {"server", "tools", "deploy"}
            or path.suffix not in SOURCE_SUFFIXES
        ):
            continue
        size = path.stat().st_size
        rows.append((relative, size, digest(path)))
    encoded = b"".join(
        name.encode() + b"\0" + str(size).encode() + b"\0" + sha.encode() + b"\n"
        for name, size, sha in rows
    )
    return len(rows), hashlib.sha256(encoded).hexdigest()


def show(unit, properties):
    raw = subprocess.check_output(
        ["systemctl", "show", unit, *sum((["-p", item] for item in properties), []), "--no-pager"],
        text=True,
    )
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


def pm2_quickread():
    raw = subprocess.check_output(["pm2", "jlist"], text=True, stderr=subprocess.DEVNULL)
    rows = []
    for item in json.loads(raw):
        if item.get("name") == "quickread":
            env = item.get("pm2_env") or {}
            rows.append({
                "pid": item.get("pid"), "status": env.get("status"),
                "cwd": env.get("pm_cwd"), "pm_uptime": env.get("pm_uptime"),
                "restart_time": env.get("restart_time"),
            })
    require(len(rows) == 1, "quickread process count differs")
    return rows[0]


def process_identity(pid):
    root = Path("/proc") / str(pid)
    fields = (root / "stat").read_text().rsplit(")", 1)[1].split()
    return {
        "pid": pid,
        "start_ticks": fields[19],
        "cwd": os.readlink(root / "cwd"),
        "argv_sha256": hashlib.sha256((root / "cmdline").read_bytes()).hexdigest(),
        "exe": os.readlink(root / "exe"),
    }


def health():
    with urllib.request.urlopen("http://127.0.0.1:7777/health", timeout=4) as response:
        body = json.load(response)
        return {
            "http_status": response.status, "ok": body.get("ok"),
            "active": body.get("active"), "queue": body.get("queue"),
        }


def latest():
    try:
        return json.loads(STATE.read_text())
    except FileNotFoundError:
        return None


def safe_outcome(value):
    if value is None:
        return None
    segments = []
    for row in value.get("segments", []):
        segments.append({name: row.get(name) for name in (
            "index", "attempts", "requestContract", "processedCharacters",
            "remainingCharacters", "audioBytes", "durationSeconds", "timestampsOk",
            "timestampCount", "gateway", "upstreamNode", "upstreamSource", "upstreamRevision",
        )})
    return {
        name: value.get(name) for name in (
            "schemaVersion", "probe", "observedAt", "region", "endpoint", "inputSha256",
            "inputCharacters", "language", "locale", "voice", "supplyOk", "alignmentOk",
            "status", "failureCode", "failedRequestContract", "elapsedMs", "segmentCount",
            "totalAudioBytes", "totalDurationSeconds",
        )
    } | {"segments": segments}


def protected_snapshot():
    pm2 = pm2_quickread()
    pid = pm2.get("pid")
    return {
        "quickread_target": str(QUICKREAD_LINK.resolve(strict=True)),
        "quickread_link_inode": QUICKREAD_LINK.lstat().st_ino,
        "quickread_link_mtime_ns": QUICKREAD_LINK.lstat().st_mtime_ns,
        "quickread_pm2": pm2,
        "quickread_process": process_identity(pid),
        "quickread_tree": tree_digest(QUICKREAD_LINK.resolve(strict=True), source_only=True),
        "quickread_health": health(),
        "unit_hashes": {path: digest(path) for path in EXPECTED_UNIT_HASHES},
        "infra_hashes": {path: digest(path) for path in EXPECTED_INFRA_HASHES},
    }


def validate_protected(value, require_idle=False):
    require(value["quickread_target"] == str(EXPECTED_QUICKREAD), "quickread target drifted")
    require(value["quickread_pm2"]["pid"] == EXPECTED_PID, "quickread pid drifted")
    require(value["quickread_pm2"]["status"] == "online", "quickread is not online")
    require(value["quickread_process"]["start_ticks"] == EXPECTED_START_TICKS, "quickread start time drifted")
    require(value["quickread_process"]["argv_sha256"] == EXPECTED_ARGV_SHA, "quickread argv drifted")
    require(value["quickread_process"]["cwd"] == str(EXPECTED_QUICKREAD), "quickread cwd drifted")
    require(tuple(value["quickread_tree"]) == (65, EXPECTED_QUICKREAD_TREE), "quickread source tree drifted")
    require(value["quickread_health"]["http_status"] == 200 and value["quickread_health"]["ok"] is True, "quickread health failed")
    if require_idle:
        require(value["quickread_health"]["active"] is False and value["quickread_health"]["queue"] == 0, "quickread is busy")
    require(value["unit_hashes"] == EXPECTED_UNIT_HASHES, "installed monitor unit changed")
    require(value["infra_hashes"] == EXPECTED_INFRA_HASHES, "proxy or runtime changed")


def atomic_current(target):
    temporary = ROOT / f".current-{target.name}-{os.getpid()}"
    require(not temporary.exists() and not temporary.is_symlink(), "temporary symlink already exists")
    os.symlink(str(target), temporary)
    os.replace(temporary, CURRENT)
    descriptor = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


started = datetime.now(timezone.utc)
transaction = {
    "schema": "castreader.us-monitor-switch.v1",
    "started_at_utc": started.isoformat(),
    "old_release": str(OLD),
    "new_release": str(NEW),
    "business_services_restarted": [],
    "units_modified": False,
    "timer_temporarily_stopped": False,
    "switched": False,
    "rolled_back": False,
}
timer_initial = show(TIMER, ["ActiveState", "SubState", "UnitFileState"])
transaction["timer_before"] = timer_initial
require(timer_initial.get("ActiveState") == "active" and timer_initial.get("UnitFileState") == "enabled", "timer baseline differs")

try:
    subprocess.run(["systemctl", "stop", TIMER], check=True, timeout=15)
    transaction["timer_temporarily_stopped"] = True
    deadline = time.monotonic() + 160
    while show(SERVICE, ["ActiveState"])["ActiveState"] not in {"inactive", "failed"}:
        require(time.monotonic() < deadline, "monitor oneshot did not become inactive")
        time.sleep(0.5)
    subprocess.run(["systemctl", "reset-failed", SERVICE], check=False, timeout=10)
    require(show(SERVICE, ["ActiveState", "SubState"])["ActiveState"] == "inactive", "monitor oneshot not inactive")

    require(CURRENT.resolve(strict=True) == OLD, "current monitor release drifted")
    require(tree_digest(OLD) == (9, EXPECTED_OLD_TREE), "old monitor release tree drifted")
    require(tree_digest(NEW) == (9, EXPECTED_NEW_TREE), "new monitor release tree drifted")
    before = protected_snapshot()
    validate_protected(before, require_idle=True)
    transaction["protected_before"] = before
    prior_latest = latest()
    transaction["prior_observed_at"] = prior_latest.get("observedAt") if prior_latest else None

    atomic_current(NEW)
    transaction["switched"] = True
    require(CURRENT.resolve(strict=True) == NEW, "atomic current switch failed")
    require(tree_digest(CURRENT.resolve(strict=True)) == (9, EXPECTED_NEW_TREE), "current tree differs after switch")

    manual_started = datetime.now(timezone.utc)
    run = subprocess.run(["systemctl", "start", SERVICE], capture_output=True, text=True, timeout=160)
    transaction["manual_service"] = {
        "started_at_utc": manual_started.isoformat(),
        "finished_at_utc": datetime.now(timezone.utc).isoformat(),
        "systemctl_exit": run.returncode,
        "service": show(SERVICE, ["ActiveState", "SubState", "Result", "ExecMainStatus"]),
    }
    outcome = latest()
    require(outcome is not None and outcome.get("observedAt") != transaction["prior_observed_at"], "manual run did not persist a new result")
    require(outcome.get("region") == "us", "manual result region differs")
    require(outcome.get("endpoint") == "https://api.castreader.ai/api/captioned_speech_partly", "manual endpoint differs")
    require(outcome.get("language") == "en" and outcome.get("voice") == "af_heart", "manual fixed contract differs")
    require(outcome.get("status") in {"healthy", "alignment_degraded", "supply_failed"}, "monitor program result invalid")
    require(outcome.get("status") != "monitor_error", "monitor program fault")
    if outcome.get("supplyOk"):
        require(outcome.get("segmentCount", 0) >= 2, "successful result did not validate continuity")
    else:
        require(isinstance(outcome.get("failureCode"), str) and outcome.get("failureCode"), "supply failure has no code")
    transaction["manual_result"] = safe_outcome(outcome)

    try:
        after = protected_snapshot()
        validate_protected(after)
        protected_drift = [
            field for field in (
                "quickread_target", "quickread_link_inode", "quickread_link_mtime_ns",
                "quickread_pm2", "quickread_process", "quickread_tree", "unit_hashes", "infra_hashes",
            ) if after[field] != before[field]
        ]
        transaction["protected_after"] = after
        transaction["protected_drift_after"] = protected_drift
    except Exception as after_error:
        # A concurrent business-state change is evidence to investigate, not a
        # reason to alter or restart that service or roll back a valid monitor.
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
    if (
        transaction.get("status") == "committed"
        and (transaction.get("timer_restart_exit") != 0 or transaction["timer_after"].get("ActiveState") != "active")
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
