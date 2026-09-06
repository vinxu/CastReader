#!/usr/bin/env python3
"""Read the US origin proxy state and live source without synthesizing audio."""

import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess


PROXY_STATE = Path("/var/lib/castreader-tts-origin-proxy/state.json")
PROXY_STATE_SCHEMA = "castreader.us-tts-origin-proxy-state.v1"
RELEASES = Path("/workspace/castreader-runtime/releases")
SOURCE_RELATIVE = Path("api/src/inference/english_g2p_recovery.py")
SLOTS = {
    "blue": {
        "port": 8880,
        "releaseId": "20260905-kokoro-english-g2p-us-r132",
        "releasePath": RELEASES / "20260905-kokoro-english-g2p-us-r132",
        "supervisorProgram": "castreader-tts",
    },
    "green": {
        "port": 18880,
        "releaseId": "20260906-kokoro-repeated-digits-us-r133",
        "releasePath": RELEASES / "20260906-kokoro-repeated-digits-us-r133",
        "supervisorProgram": "castreader-tts-r133-green",
    },
}


def validate_model_expectation(expected):
    """Validate an explicit local expectation, never values learned from live state."""
    keys = {"slot", "releaseId", "version", "releasePath", "sourceRelativePath", "sourceSha256"}
    if not isinstance(expected, dict) or set(expected) != keys:
        raise ValueError("model_expected_identity_shape_invalid")
    if not isinstance(expected["slot"], str) or expected["slot"] not in SLOTS:
        raise ValueError("model_expected_slot_invalid")
    release_id = expected["releaseId"]
    if not isinstance(release_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", release_id):
        raise ValueError("model_expected_release_id_invalid")
    if expected["releasePath"] != str(RELEASES / release_id):
        raise ValueError("model_expected_release_path_invalid")
    relative = expected["sourceRelativePath"]
    if (
        not isinstance(relative, str)
        or not re.fullmatch(r"(?:[A-Za-z0-9_-]+/)+[A-Za-z0-9_-]+\.py", relative)
        or Path(relative).is_absolute()
        or any(part in (".", "..") for part in relative.split("/"))
    ):
        raise ValueError("model_expected_source_path_invalid")
    if not isinstance(expected["version"], str) or not re.fullmatch(r"[0-9a-f]{40}", expected["version"]):
        raise ValueError("model_expected_version_invalid")
    if not isinstance(expected["sourceSha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", expected["sourceSha256"]):
        raise ValueError("model_expected_source_hash_invalid")
    return dict(expected)


def current_model_identity(state, expected=None):
    current = state["currentSlot"]
    if current not in SLOTS:
        raise ValueError("proxy_current_slot_invalid")
    slot = state.get("slots", {}).get(current)
    if not isinstance(slot, dict):
        raise ValueError("proxy_current_slot_state_invalid")
    fixed = SLOTS[current]
    if expected is not None:
        expected = validate_model_expectation(expected)
        if current != expected["slot"] or slot.get("releaseId") != expected["releaseId"]:
            raise ValueError("model_expected_route_mismatch")
        release_path = Path(expected["releasePath"])
        release_id = expected["releaseId"]
        source_relative = Path(expected["sourceRelativePath"])
    else:
        # Preserve the original source-only invocation and its frozen R132/R133 map.
        release_path = fixed["releasePath"]
        release_id = fixed["releaseId"]
        source_relative = SOURCE_RELATIVE
    release = release_path.resolve(strict=True)
    releases_root = RELEASES.resolve(strict=True)
    release.relative_to(releases_root)
    if release != releases_root / release_id:
        raise ValueError("model_release_path_not_canonical")
    recovery_source = (release / source_relative).resolve(strict=True)
    recovery_source.relative_to(release)
    if recovery_source != release / source_relative:
        raise ValueError("model_source_path_not_canonical")
    recovery_raw = recovery_source.read_bytes()
    source_hash = hashlib.sha256(recovery_raw).hexdigest()
    if expected is not None and source_hash != expected["sourceSha256"]:
        raise ValueError("model_expected_source_hash_mismatch")
    model_listeners = listener_processes(fixed["port"])
    supervisor = supervisor_identity(fixed["supervisorProgram"])
    result = {
        "slot": current,
        "internalPort": fixed["port"],
        "fixedReleaseId": release_id,
        "stateReleaseId": slot.get("releaseId"),
        "stateReceiptSha256": slot.get("receiptSha256"),
        "stateEnabled": slot.get("enabled"),
        "runtimeReleasePath": str(release),
        "runtimeSourceRelativePath": source_relative.as_posix(),
        "runtimeSourceBytes": len(recovery_raw),
        "runtimeSourceSha256": source_hash,
        "listenerProcessIds": [value["pid"] for value in model_listeners],
        "listenerProcesses": model_listeners,
        "supervisorProgram": supervisor["program"],
        "supervisorState": supervisor["state"],
        "supervisorPid": supervisor["pid"],
        "supervisorProcess": supervisor["process"],
        "supervisorCwd": (
            supervisor["process"].get("cwd")
            if isinstance(supervisor.get("process"), dict)
            else None
        ),
    }
    if expected is not None:
        # This is an expectation label; the measured identity is the source SHA/path above.
        result["expectedVersion"] = expected["version"]
    return result


def process_metadata(pid):
    proc = Path("/proc") / str(pid)
    try:
        stat = (proc / "stat").read_text().split()
        return {
            "pid": pid,
            "parentPid": int(stat[3]),
            "startTicks": stat[21],
            "cwd": os.readlink(proc / "cwd"),
            "exe": os.readlink(proc / "exe"),
        }
    except (FileNotFoundError, ProcessLookupError, PermissionError, ValueError, IndexError):
        return {"pid": pid, "unreadable": True}


def listener_processes(port):
    socket_inodes = set()
    for table in ("tcp", "tcp6"):
        for line in (Path("/proc/net") / table).read_text().splitlines()[1:]:
            fields = line.split()
            if int(fields[1].rsplit(":", 1)[1], 16) == port and fields[3] == "0A":
                socket_inodes.add(fields[9])
    matches = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            targets = {os.readlink(fd) for fd in (proc / "fd").iterdir()}
            if any("socket:[" + inode + "]" in targets for inode in socket_inodes):
                matches.append(process_metadata(int(proc.name)))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    return sorted(matches, key=lambda value: value["pid"])


def supervisor_identity(program):
    completed = subprocess.run(
        ["supervisorctl", "status", program],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    output = completed.stdout.strip()
    match = re.fullmatch(
        rf"{re.escape(program)}\s+([A-Z]+)(?:\s+pid\s+(\d+),.*)?",
        output,
    )
    if completed.returncode != 0 or not match:
        return {
            "program": program,
            "state": "UNREADABLE",
            "pid": None,
            "process": None,
        }
    pid = int(match.group(2)) if match.group(2) else None
    return {
        "program": program,
        "state": match.group(1),
        "pid": pid,
        "process": process_metadata(pid) if pid is not None else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("--model-expectation-json")
    args = parser.parse_args()
    expected = (
        validate_model_expectation(json.loads(args.model_expectation_json))
        if args.model_expectation_json is not None else None
    )
    source = Path(args.source)
    if not source.is_absolute() or source.name != "r133_stable_proxy.py":
        raise ValueError("proxy_source_path_invalid")
    source.resolve(strict=True).relative_to(Path("/workspace"))
    raw = source.read_bytes()
    matches = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            argv = (proc / "cmdline").read_bytes().decode().split("\0")
            # The collector itself receives source as an argument to `python -`.
            # Match the actual supervised Python program position, not any arg.
            if len(argv) > 2 and argv[1:3] == ["-B", str(source)]:
                matches.append(int(proc.name))
        except (FileNotFoundError, ProcessLookupError, PermissionError, UnicodeError):
            continue
    state = json.loads(PROXY_STATE.read_text())
    if not isinstance(state, dict) or state.get("schema") != PROXY_STATE_SCHEMA:
        raise ValueError("proxy_state_schema_invalid")
    socket_inodes = set()
    for table in ("tcp", "tcp6"):
        for line in (Path("/proc/net") / table).read_text().splitlines()[1:]:
            fields = line.split()
            if int(fields[1].rsplit(":", 1)[1], 16) == 8889 and fields[3] == "0A":
                socket_inodes.add(fields[9])
    listener_matches = []
    for pid in matches:
        try:
            targets = {os.readlink(fd) for fd in (Path("/proc") / str(pid) / "fd").iterdir()}
            if any("socket:[" + inode + "]" in targets for inode in socket_inodes):
                listener_matches.append(pid)
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    connection = http.client.HTTPConnection("127.0.0.1", 8889, timeout=5)
    try:
        connection.request("GET", "/health", headers={"Cache-Control": "no-cache"})
        response = connection.getresponse()
        body = response.read(8193)
        if response.status != 200 or len(body) > 8192:
            raise ValueError("proxy_health_failed")
        health = json.loads(body)
    finally:
        connection.close()
    current = state["currentSlot"]
    model = current_model_identity(state, expected)
    print(json.dumps({
        "schema": "castreader.us-origin-proxy-identity.v1",
        "readOnly": True,
        "productionModified": False,
        "synthesisStarted": False,
        "diagnosticFunctionExecuted": False,
        "readAtUtc": datetime.now(timezone.utc).isoformat(),
        "coverage": {"complete": True},
        "identity": {
            "sourcePath": str(source),
            "sourceSha256": hashlib.sha256(raw).hexdigest(),
            "processIds": matches,
            "listenerProcessIds": listener_matches,
            "proxyReleaseId": state["proxyReleaseId"],
            "revision": state["revision"],
            "currentSlot": current,
            "currentReleaseId": state["slots"][current]["releaseId"],
            "currentReceiptSha256": state["slots"][current]["receiptSha256"],
            "currentEnabled": state["slots"][current]["enabled"],
            "currentModel": model,
        },
        "health": {key: health.get(key) for key in (
            "ok", "proxyReleaseId", "revision", "currentSlot", "currentReleaseId",
            "active", "drainTrusted",
        )},
        "limitations": ["Point-in-time source, process and routing identity; existing continuous probes provide the interval evidence."],
    }, sort_keys=True))


if __name__ == "__main__":
    main()
