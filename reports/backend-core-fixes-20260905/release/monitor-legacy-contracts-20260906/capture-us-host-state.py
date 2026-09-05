#!/usr/bin/env python3
"""Read-only, secret-free US monitor and protected-service snapshot."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import urllib.request


MONITOR_ROOT = Path("/opt/castreader-core-audio-monitor")
QUICKREAD_LINK = Path("/root/castreader/video-pipeline")
SOURCE_SUFFIXES = {".mjs", ".cjs", ".js", ".json", ".sh"}


def digest(path):
    path = Path(path)
    value = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
            size += len(block)
    return {"bytes": size, "sha256": value.hexdigest()}


def manifest(root, *, source_only=False):
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
        rows.append({"path": relative, **digest(path)})
    encoded = b"".join(
        row["path"].encode()
        + b"\0"
        + str(row["bytes"]).encode()
        + b"\0"
        + row["sha256"].encode()
        + b"\n"
        for row in rows
    )
    return {"files": len(rows), "tree_sha256": hashlib.sha256(encoded).hexdigest(), "manifest": rows}


def show(unit, properties):
    raw = subprocess.check_output(
        ["systemctl", "show", unit, *sum((["-p", name] for name in properties), []), "--no-pager"],
        text=True,
    )
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


def safe_health():
    with urllib.request.urlopen("http://127.0.0.1:7777/health", timeout=4) as response:
        value = json.load(response)
        return {
            "http_status": response.status,
            **{name: value.get(name) for name in ("ok", "active", "queue", "jobs_cached")},
        }


def quickread_pm2():
    raw = subprocess.check_output(["pm2", "jlist"], text=True, stderr=subprocess.DEVNULL)
    rows = []
    for process in json.loads(raw):
        if process.get("name") != "quickread":
            continue
        env = process.get("pm2_env") or {}
        rows.append(
            {
                "name": process.get("name"),
                "pid": process.get("pid"),
                "status": env.get("status"),
                "cwd": env.get("pm_cwd"),
                "pm_uptime": env.get("pm_uptime"),
                "restart_time": env.get("restart_time"),
            }
        )
    return rows


def process_identity(pid):
    path = Path("/proc") / str(pid)
    raw = (path / "cmdline").read_bytes()
    fields = (path / "stat").read_text().rsplit(")", 1)[1].split()
    return {
        "pid": pid,
        "ppid": int(fields[1]),
        "start_ticks": fields[19],
        "cwd": os.readlink(path / "cwd"),
        "argv_sha256": hashlib.sha256(raw).hexdigest(),
        "exe": os.readlink(path / "exe"),
    }


def safe_latest():
    for path in (
        Path("/var/lib/castreader-core-audio-monitor/us/latest.json"),
        Path("/var/lib/private/castreader-core-audio-monitor/us/latest.json"),
    ):
        try:
            value = json.loads(path.read_text())
            return {
                "path": str(path),
                "observedAt": value.get("observedAt"),
                "status": value.get("status"),
                "supplyOk": value.get("supplyOk"),
                "failureCode": value.get("failureCode"),
                "failedRequestContract": value.get("failedRequestContract"),
                "segmentCount": value.get("segmentCount"),
                "requestContracts": [row.get("requestContract") for row in value.get("segments", [])],
            }
        except (FileNotFoundError, PermissionError, json.JSONDecodeError):
            continue
    return None


current = (MONITOR_ROOT / "current").resolve(strict=True)
quickread = QUICKREAD_LINK.resolve(strict=True)
pm2 = quickread_pm2()
if len(pm2) != 1 or not isinstance(pm2[0].get("pid"), int):
    raise RuntimeError("Expected exactly one QuickRead PM2 process")

installed_units = {}
for path in (
    Path("/etc/systemd/system/castreader-core-audio-monitor@.service"),
    Path("/etc/systemd/system/castreader-core-audio-monitor@.timer"),
):
    installed_units[str(path)] = digest(path)

caddy = Path("/etc/caddy/Caddyfile")
node = Path("/usr/bin/node")
ffmpeg = Path("/usr/bin/ffmpeg")
print(
    json.dumps(
        {
            "schema": "castreader.us-monitor-upgrade-host-state.v1",
            "captured_at_utc": datetime.now(timezone.utc).isoformat(),
            "scope": "read-only; no environment values, job payloads, user text, audio, or secrets",
            "host": {"hostname": platform.node(), "arch": platform.machine()},
            "monitor": {
                "current_target": str(current),
                "release": manifest(current),
                "installed_units": installed_units,
                "service": show(
                    "castreader-core-audio-monitor@us.service",
                    ["ActiveState", "SubState", "MainPID", "Result", "ExecMainStatus"],
                ),
                "timer": show(
                    "castreader-core-audio-monitor@us.timer",
                    ["ActiveState", "SubState", "UnitFileState", "LastTriggerUSec", "NextElapseUSecRealtime"],
                ),
                "latest": safe_latest(),
            },
            "quickread": {
                "current_target": str(quickread),
                "link": {
                    "inode": QUICKREAD_LINK.lstat().st_ino,
                    "mtime_ns": QUICKREAD_LINK.lstat().st_mtime_ns,
                },
                "health": safe_health(),
                "pm2": pm2,
                "process": process_identity(pm2[0]["pid"]),
                "source": manifest(quickread, source_only=True),
            },
            "reverse_proxy": {"path": str(caddy), **digest(caddy)},
            "runtime": {
                "node": {"path": str(node), **digest(node)},
                "ffmpeg": {"path": str(ffmpeg), **digest(ffmpeg)},
            },
        },
        sort_keys=True,
    )
)
