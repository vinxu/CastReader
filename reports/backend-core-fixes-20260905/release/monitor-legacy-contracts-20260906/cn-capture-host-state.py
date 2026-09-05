#!/usr/bin/env python3
"""Secret-free CN control-host state for the monitor-only cutover."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import urllib.request


MONITOR = Path("/opt/castreader-core-audio-monitor")
NEXT_LINK = Path("/opt/castreader/current")


def digest(path):
    value = hashlib.sha256()
    size = 0
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
            size += len(block)
    return {"bytes": size, "sha256": value.hexdigest()}


def monitor_tree(root):
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


def release_material(root):
    records = []
    files = links = 0
    root = str(root)
    for base, directories, names in os.walk(root, followlinks=False):
        directories.sort()
        names.sort()
        for name in directories:
            path = os.path.join(base, name)
            if os.path.islink(path):
                records.append("L\0" + os.path.relpath(path, root) + "\0" + os.readlink(path))
                links += 1
        for name in names:
            path = os.path.join(base, name)
            relative = os.path.relpath(path, root)
            mode = os.lstat(path).st_mode
            if stat.S_ISREG(mode):
                records.append("F\0" + relative + "\0" + digest(path)["sha256"])
                files += 1
            elif stat.S_ISLNK(mode):
                records.append("L\0" + relative + "\0" + os.readlink(path))
                links += 1
    return {
        "regular_files": files,
        "symlinks": links,
        "tree_sha256": hashlib.sha256("\n".join(sorted(records)).encode()).hexdigest(),
    }


def show(unit):
    fields = ["LoadState", "ActiveState", "SubState", "UnitFileState", "MainPID", "NRestarts", "ExecMainStartTimestampMonotonic"]
    raw = subprocess.check_output(
        ["systemctl", "show", unit, *sum((["-p", field] for field in fields), []), "--no-pager"], text=True,
    )
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


def process(pid):
    root = Path("/proc") / str(pid)
    fields = (root / "stat").read_text().rsplit(")", 1)[1].split()
    return {
        "pid": pid,
        "start_ticks": fields[19],
        "cwd": os.readlink(root / "cwd"),
        "exe": os.readlink(root / "exe"),
        "argv_sha256": hashlib.sha256((root / "cmdline").read_bytes()).hexdigest(),
    }


def http_fingerprint(url):
    try:
        with urllib.request.urlopen(url, timeout=4) as response:
            body = response.read(262145)
            return {
                "status": response.status,
                "bytes": len(body),
                "body_sha256": hashlib.sha256(body).hexdigest(),
            }
    except Exception as error:
        return {"error_type": type(error).__name__}


def latest():
    path = Path("/var/lib/castreader-core-audio-monitor/cn/latest.json")
    try:
        value = json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    return {
        "observedAt": value.get("observedAt"), "status": value.get("status"),
        "supplyOk": value.get("supplyOk"), "failureCode": value.get("failureCode"),
        "failedRequestContract": value.get("failedRequestContract"),
        "segmentCount": value.get("segmentCount"),
        "requestContracts": [row.get("requestContract") for row in value.get("segments", [])],
    }


units = [
    "castreader.service", "castreader-quickread-cn.service",
    "castreader-cn-kokoro-tunnel.service", "castreader-cn-clone-tunnel.service",
    "nginx.service", "castreader-core-audio-monitor@cn.service",
    "castreader-core-audio-monitor@cn.timer",
]
states = {unit: show(unit) for unit in units}
next_pid = int(states["castreader.service"]["MainPID"])
quickread_pid = int(states["castreader-quickread-cn.service"]["MainPID"])
next_target = NEXT_LINK.resolve(strict=True)
descriptor = json.loads((next_target / ".castreader-release.json").read_text())
config_paths = [
    "/etc/nginx/sites-available/castreader",
    "/etc/systemd/system/castreader.service.d/20-service-route.conf",
    "/etc/systemd/system/castreader.service.d/27-cn-tts.conf",
    "/etc/systemd/system/castreader.service.d/30-release-id.conf",
    "/etc/systemd/system/castreader-core-audio-monitor@.service",
    "/etc/systemd/system/castreader-core-audio-monitor@.timer",
]
current_monitor = (MONITOR / "current").resolve(strict=True)
print(json.dumps({
    "schema": "castreader.cn-monitor-host-state.v1",
    "captured_at_utc": datetime.now(timezone.utc).isoformat(),
    "scope": "read-only; no environment values, user text, audio, or secrets",
    "monitor": {
        "current_target": str(current_monitor),
        "current_tree": monitor_tree(current_monitor),
        "new_tree": monitor_tree(MONITOR / "releases/f6eb6691-7a2c0b1f"),
        "latest": latest(),
    },
    "services": states,
    "next": {
        "target": str(next_target),
        "link_inode": NEXT_LINK.lstat().st_ino,
        "link_mtime_ns": NEXT_LINK.lstat().st_mtime_ns,
        "descriptor": {name: descriptor.get(name) for name in ("releaseId", "sourceCommit")},
        "process": process(next_pid),
        "material": release_material(next_target),
        "health": http_fingerprint("http://127.0.0.1:3000/api/capabilities"),
    },
    "quickread": {
        "process": process(quickread_pid),
        "health": http_fingerprint("http://127.0.0.1:7777/health"),
    },
    "tunnels": {
        "kokoro_health": http_fingerprint("http://127.0.0.1:18880/health"),
        "clone_health": http_fingerprint("http://127.0.0.1:18890/health"),
    },
    "config": {path: digest(path) for path in config_paths},
}, sort_keys=True))
