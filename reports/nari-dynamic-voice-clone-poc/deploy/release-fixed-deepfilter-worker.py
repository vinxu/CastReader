#!/usr/bin/env python3
"""Immutable, worker-only DeepFilter release; never deploys Nari or web artifacts.

Run ``package --help`` locally, then ``apply --help`` on the destination host.
Apply is preflight-only unless --execute is supplied. Keep the returned backup.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from urllib.request import ProxyHandler, build_opener


PREFIX = "reports/nari-dynamic-voice-clone-poc"
TOOL_PATH = f"{PREFIX}/deploy/release-fixed-deepfilter-worker.py"
POLICY = "fixed-deepfilter-atten24-v1"
ALLOWED_FILES = {"clone_worker.py", "adaptive_denoise.py"}
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
SUPERVISOR_PID_NOT_RUNNING_EXIT_CODE = 7


class ReleaseError(RuntimeError):
    pass


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(value: object, message: str) -> None:
    if not value:
        raise ReleaseError(message)


def load_object(path: Path) -> dict:
    value = json.loads(path.read_text())
    require(isinstance(value, dict), f"Expected JSON object: {path.name}")
    return value


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    path.chmod(0o600)


def run(argv: list[str], **kwargs) -> str:
    result = subprocess.run(argv, check=True, capture_output=True, text=True, **kwargs)
    return result.stdout.strip()


def package(repo: Path, commit: str, destination: Path, files: list[str]) -> dict:
    require(SHA40.fullmatch(commit), "Use a full lowercase immutable commit SHA")
    require(set(files) <= ALLOWED_FILES and "clone_worker.py" in files,
            "Only clone_worker.py and optional adaptive_denoise.py may be released")
    require(len(files) == len(set(files)), "Duplicate release file")
    require(not destination.exists(), "Bundle destination must not exist")
    resolved = run(["git", "-C", str(repo), "rev-parse", f"{commit}^{{commit}}"])
    require(resolved == commit, "Source commit is not exact")
    # Read Git blobs, never the current checkout or an old release-incoming tree.
    blobs = {name: subprocess.check_output([
        "git", "-C", str(repo), "show", f"{commit}:{PREFIX}/worker/{name}",
    ]) for name in sorted(files)}
    tool = subprocess.check_output(["git", "-C", str(repo), "show", f"{commit}:{TOOL_PATH}"])
    for name, value in blobs.items():
        compile(value, name, "exec")
    destination.mkdir(parents=True, mode=0o700)
    (destination / "worker").mkdir(mode=0o700)
    for name, value in blobs.items():
        (destination / "worker" / name).write_bytes(value)
    (destination / "release-tool.py").write_bytes(tool)
    manifest = {
        "bundle_version": 1,
        "release_type": "fixed-deepfilter-worker-only",
        "source_commit": commit,
        "policy": POLICY,
        "files": {name: hashlib.sha256(value).hexdigest() for name, value in blobs.items()},
        "tool_sha256": hashlib.sha256(tool).hexdigest(),
    }
    write_json(destination / "manifest.json", manifest)
    return {"bundle": str(destination), "source_commit": commit,
            "manifest_sha256": digest(destination / "manifest.json")}


def validate_bundle(bundle: Path, commit: str, manifest_sha: str) -> dict:
    require(SHA40.fullmatch(commit), "Invalid source commit")
    require(SHA64.fullmatch(manifest_sha), "Invalid manifest SHA256")
    require(not bundle.is_symlink(), "Bundle may not be a symlink")
    require(digest(bundle / "manifest.json") == manifest_sha, "Manifest checksum mismatch")
    manifest = load_object(bundle / "manifest.json")
    require(manifest.get("bundle_version") == 1, "Unknown bundle format")
    require(manifest.get("release_type") == "fixed-deepfilter-worker-only", "Wrong release type")
    require(manifest.get("source_commit") == commit, "Source commit mismatch")
    require(manifest.get("policy") == POLICY, "Wrong release policy")
    files = manifest.get("files")
    require(isinstance(files, dict) and "clone_worker.py" in files,
            "clone_worker.py is required")
    require(set(files) <= ALLOWED_FILES, "Bundle attempts to replace out-of-scope files")
    for name, expected in files.items():
        path = bundle / "worker" / name
        require(path.is_file() and not path.is_symlink(), f"Invalid bundle file: {name}")
        require(isinstance(expected, str) and SHA64.fullmatch(expected), "Invalid file SHA")
        require(digest(path) == expected, f"Bundle checksum mismatch: {name}")
        compile(path.read_bytes(), name, "exec")
    require(digest(Path(__file__)) == manifest.get("tool_sha256"),
            "Run the release tool included in this immutable bundle")
    return manifest


def region_config(region: str) -> dict:
    if region == "cn":
        base = Path("/root/autodl-tmp/nari-staging").resolve()
        return dict(region=region, base=base, worker=base / "worker", data=base / "clone",
                    nari=base / "nari-qwen3-tts/src/nari_qwen3_tts",
                    python=base / "venv/bin/python", port=18890, nari_port=18094,
                    runner=base / "deploy/run-clone-china-staging.sh",
                    extra_protected=[base / "deploy/watchdog-china-staging.sh",
                                     base / "deploy/run-nari-china-staging.sh"])
    base = Path("/workspace/castreader-clone").resolve()
    return dict(region=region, base=base, worker=base / "app", data=base,
                nari=Path("/workspace/nari-qwen3-tts-clean/src/nari_qwen3_tts"),
                python=Path("/workspace/nari-qwen3-tts-clean/venv/bin/python"),
                port=8890, nari_port=8094, runner=base / "run-clone-worker.sh",
                extra_protected=[Path("/etc/supervisor/conf.d/castreader-clone.conf"),
                                 Path("/etc/supervisor/conf.d/castreader-nari-base.conf")])


def http_json(port: int, route: str) -> dict:
    with build_opener(ProxyHandler({})).open(f"http://127.0.0.1:{port}{route}", timeout=3) as response:
        return json.load(response)


def supervisor_pid(name: str) -> int:
    require(name in {"castreader-clone", "castreader-nari-base", "castreader-tts"},
            "Unexpected supervisor service name")
    result = subprocess.run(["supervisorctl", "pid", name], capture_output=True,
                            text=True, timeout=5)
    value = result.stdout.strip()
    require(re.fullmatch(r"\d+", value), "Supervisor PID response is not numeric")
    pid = int(value)
    # Actual Supervisor returns LSBInitExitStatuses.NOT_RUNNING (7) and prints 0
    # for STOPPED (whereas the separate `status` command returns 3).
    # EXITED/FATAL states. This is a valid state snapshot, not a failed command.
    require((pid == 0 and result.returncode == SUPERVISOR_PID_NOT_RUNNING_EXIT_CODE)
            or (pid > 1 and result.returncode == 0),
            f"Supervisor PID response has an unexpected exit status: service={name}, returncode={result.returncode}")
    return pid


def service_pids(config: dict) -> dict[str, int]:
    if config["region"] == "us":
        return {key: supervisor_pid(name) for key, name in (
            ("worker", "castreader-clone"), ("nari", "castreader-nari-base"),
            ("tts", "castreader-tts"))}
    base = config["base"]
    tts = run(["pgrep", "-f", "uvicorn api.src.main:app.*--port 8880"]).splitlines()
    require(len(tts) == 1, "Cannot identify unique existing TTS process")
    return {"worker": int((base / "run/worker.pid").read_text()),
            "nari": int((base / "run/nari.pid").read_text()), "tts": int(tts[0])}


def process_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return Path(f"/proc/{pid}/stat").read_text().split(")", 1)[1].split()[0] != "Z"
    except (ProcessLookupError, FileNotFoundError):
        return False


def process_identity(pid: int) -> tuple[int, str]:
    """Parent PID and start-time token, guarding against PID reuse."""
    fields = Path(f"/proc/{pid}/stat").read_text().split(")", 1)[1].split()
    return int(fields[1]), fields[19]


WATCHDOG_RESUME_GUARD = r'''
import os, pathlib, select, signal, sys
pid, start = int(sys.argv[1]), sys.argv[2]
# Parent holds this pipe. EOF on parent crash/SIGKILL resumes supervision; the
# timeout also bounds a hung deployment. Only the exact validated process is signaled.
select.select([sys.stdin], [], [], 130)
try:
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split(")", 1)[1].split()
    if fields[19] == start:
        os.kill(pid, signal.SIGCONT)
except (FileNotFoundError, ProcessLookupError):
    pass
'''


@contextmanager
def paused_process(pid: int):
    _, start_token = process_identity(pid)
    guard = subprocess.Popen([sys.executable, "-c", WATCHDOG_RESUME_GUARD,
                              str(pid), start_token], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    try:
        os.kill(pid, signal.SIGSTOP)
        wait_process_stopped(pid)
        yield
    finally:
        # The child performs the same check if this process is killed during finally.
        try:
            if process_identity(pid)[1] == start_token:
                os.kill(pid, signal.SIGCONT)
        except (FileNotFoundError, ProcessLookupError):
            pass
        finally:
            assert guard.stdin is not None
            guard.stdin.close()
            guard.wait(timeout=3)


def wait_process_stopped(pid: int) -> None:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        state = Path(f"/proc/{pid}/stat").read_text().split(")", 1)[1].split()[0]
        if state in {"T", "t"}:
            return
        time.sleep(0.01)
    raise ReleaseError("Process did not acknowledge the temporary safety pause")


@contextmanager
def paused_watchdog(config: dict, pids: dict):
    """Pause only CN's exact restart supervisor, never a Nari/TTS process."""
    if config["region"] != "cn":
        yield
        return
    watchdog_pid, _ = process_identity(pids["nari"])
    command = Path(f"/proc/{watchdog_pid}/cmdline").read_bytes().split(b"\0")
    command = [part.decode() for part in command if part]
    expected = str(config["base"] / "deploy/watchdog-china-staging.sh")
    require(command in (["/bin/bash", expected], ["bash", expected]),
            "Nari parent is not the exact expected China watchdog")
    require(watchdog_pid not in (pids["nari"], pids["tts"], pids["worker"]),
            "Watchdog cannot be a serving process")
    if process_alive(pids["worker"]):
        require(process_identity(pids["worker"])[0] == watchdog_pid,
                "Worker and Nari do not share the expected watchdog")
    with paused_process(watchdog_pid):
        yield


def established_connections(port: int) -> int:
    # A conservative migration gate for old Workers without active_voice_tasks.
    # Includes keepalive connections; refusing a busy release is safer than guessing.
    count = 0
    for filename in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in Path(filename).read_text().splitlines()[1:]:
            columns = line.split()
            if int(columns[1].rsplit(":", 1)[1], 16) == port and columns[3] == "01":
                count += 1
    return count


def idle_health(health: dict, connections: int, building: bool,
                *, require_creation_enabled: bool = True) -> bool:
    return bool(health.get("status") == "healthy"
                and (not require_creation_enabled or health.get("voice_creation_enabled") is True)
                and health.get("busy") is False
                and health.get("queue_depth") == 0
                and health.get("active_voice_tasks", 0) == 0
                and connections == 0 and not building)


def wait_idle(config: dict, timeout: float = 120, *, require_creation_enabled: bool = True) -> None:
    deadline = time.monotonic() + timeout
    streak = 0
    while time.monotonic() < deadline:
        health = http_json(config["port"], "/health")
        connections = established_connections(config["port"])
        building = any((config["data"] / "voices").glob(".vc_*.*.building"))
        streak = streak + 1 if idle_health(health, connections, building,
                     require_creation_enabled=require_creation_enabled) else 0
        if streak >= 5:
            return
        time.sleep(2)
    raise ReleaseError("No sustained safe idle window; production files were not changed")


def protected_snapshot(config: dict, changed: set[str]) -> dict[str, str]:
    paths = [path for path in config["worker"].glob("*.py") if path.name not in changed]
    paths += list(config["nari"].rglob("*.py"))
    paths += [config["runner"], *config["extra_protected"]]
    mode_file = config["data"] / ".adaptive-denoise-mode"
    if mode_file.exists():
        paths.append(mode_file)
    return {str(path): digest(path) for path in sorted(paths)}


PREFLIGHT_CODE = r'''
import json, pathlib, sys, tempfile, threading, time
import numpy as np
sys.path[:0] = [sys.argv[1], sys.argv[2]]
import clone_worker as worker
from build_prompt import dry_run_xvector_prompt_schema
from xvector_activation import EXPECTED_DRY_RUN, marker_matches_current_release
root = pathlib.Path(sys.argv[2])
assert marker_matches_current_release(pathlib.Path(sys.argv[3]), worker=root / "clone_worker.py",
    builder=root / "build_prompt.py", activation_validator=root / "xvector_activation.py")
assert dry_run_xvector_prompt_schema() == EXPECTED_DRY_RUN
policy = worker.denoise_health()
assert policy["selector_version"] == "fixed-deepfilter-atten24-v1"
assert policy["mode"] == "on" and policy["all_recordings"] is True
assert policy["raw_fallback"] is False
assert policy["deepfilter"]["ready"] is True
worker.SPEAKER_DIARIZER.warmup()
assert worker.SPEAKER_DIARIZER.model_status()["ready"] is True
with tempfile.TemporaryDirectory(prefix="deepfilter-preflight-") as directory:
    rate = 24000
    synthetic = (0.02 * np.sin(2 * np.pi * 220 * np.arange(rate) / rate)).astype(np.float32)
    enhanced, output_rate, elapsed = worker.DEEPFILTER_RUNNER.enhance(synthetic, rate,
        attenuation_db=24, work_dir=pathlib.Path(directory), deadline_at=time.monotonic() + 20,
        cancelled=threading.Event())
    assert enhanced.size > 0 and np.isfinite(enhanced).all() and output_rate > 0
worker.SCHEDULER.close(wait=True)
worker.NARI_CLIENT.close()
print(json.dumps({"schema": "xvector_v1", "policy": policy["selector_version"],
                  "deepfilter_applied": True, "deepfilter_elapsed_s": round(elapsed, 3),
                  "diarization_ready": True}))
'''


def preflight(config: dict, bundle: Path, pid: int) -> dict:
    # Use the *running service's* environment, not an SSH shell's differing defaults.
    # It can contain credentials. Keep it in memory and never print/log it.
    raw = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    environment = {key.decode(): value.decode() for item in raw if b"=" in item
                   for key, value in [item.split(b"=", 1)]}
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    result = subprocess.run([str(config["python"]), "-c", PREFLIGHT_CODE,
                             str(bundle / "worker"), str(config["worker"]),
                             str(config["data"] / ".xvector-writer-v1-enabled")],
                            env=environment, capture_output=True, text=True, timeout=60)
    require(result.returncode == 0,
            "Candidate import/schema/DeepFilter/diarizer preflight failed (output withheld)")
    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError) as error:
        raise ReleaseError("Candidate preflight did not return valid evidence") from error


def activation_module(worker: Path):
    spec = importlib.util.spec_from_file_location("release_activation", worker / "xvector_activation.py")
    require(spec is not None and spec.loader is not None, "Activation validator missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def atomic_copy(source: Path, destination: Path) -> None:
    require(destination.is_file() and not destination.is_symlink(),
            f"Refusing unexpected replacement target: {destination}")
    metadata = destination.stat()
    temporary = destination.with_name(f".{destination.name}.fixed-release-{os.getpid()}")
    require(not temporary.exists(), "Replacement staging path already exists")
    try:
        shutil.copyfile(source, temporary)
        os.chmod(temporary, metadata.st_mode & 0o777)
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
        with temporary.open("rb") as handle:
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def fixed_health(health: dict) -> bool:
    denoise = health.get("adaptive_denoise", {})
    return bool(health.get("status") == "healthy"
                and health.get("voice_creation_enabled") is True
                and health.get("voice_prompt_writer_schema") == "xvector_v1"
                and denoise.get("selector_version") == POLICY
                and denoise.get("mode") == "on"
                and denoise.get("all_recordings") is True
                and denoise.get("raw_fallback") is False
                and denoise.get("deepfilter", {}).get("ready") is True
                and denoise.get("diarization", {}).get("ready") is True)


def wait_restarted(config: dict, old_pids: dict, *, fixed: bool) -> dict:
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        try:
            pids = service_pids(config)
            require(pids["nari"] == old_pids["nari"] and pids["tts"] == old_pids["tts"],
                    "Protected Nari/TTS process changed; stop and investigate")
            health = http_json(config["port"], "/health")
            valid = fixed_health(health) if fixed else (
                health.get("status") == "healthy" and health.get("voice_creation_enabled") is True)
            if pids["worker"] != old_pids["worker"] and valid:
                return {"pids": pids, "health": health}
        except (OSError, ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(2)
    raise ReleaseError("Worker failed to restart healthy with voice creation enabled")


def graceful_stop(old_pid: int) -> None:
    if process_alive(old_pid):
        os.kill(old_pid, signal.SIGTERM)
    deadline = time.monotonic() + 100
    while process_alive(old_pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    require(not process_alive(old_pid), "Worker did not drain; no forced kill was attempted")


def supervisor_worker_state() -> tuple[str, int]:
    status = subprocess.run(["supervisorctl", "status", "castreader-clone"],
                            capture_output=True, text=True, timeout=5)
    fields = status.stdout.strip().split()
    require(len(fields) >= 2 and fields[0] == "castreader-clone", "Cannot read clone supervisor state")
    pid = supervisor_pid("castreader-clone")
    return fields[1], pid


def worker_port_sockets(pid: int, port: int) -> set[str]:
    """Owned listener/accepted sockets, not unrelated processes' health clients."""
    inodes = set()
    for entry in Path(f"/proc/{pid}/fd").iterdir():
        try:
            target = os.readlink(entry)
        except FileNotFoundError:
            continue
        if target.startswith("socket:["):
            inodes.add(target[8:-1])
    states = set()
    for filename in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in Path(filename).read_text().splitlines()[1:]:
            fields = line.split()
            if fields[9] in inodes and int(fields[1].rsplit(":", 1)[1], 16) == port:
                states.add(fields[3])
    return states


def begin_supervisor_stop():
    return subprocess.Popen(["supervisorctl", "stop", "castreader-clone"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def require_supervisor_stopped(*, recovery: bool = False) -> None:
    state, pid = supervisor_worker_state()
    allowed = {"STOPPED", "FATAL"} if recovery else {"STOPPED"}
    require(state in allowed and pid == 0,
            "Worker must be supervisor STOPPED with PID 0 before replacing source")


def stop_worker_for_swap(config: dict, original_pid: int, *, recovery: bool = False) -> None:
    """Drain live work, then suppress US autorestart without shortening its deadline.

    Uvicorn 0.52 re-raises SIGTERM after draining. Supervisor can therefore spawn
    a replacement. Only a frozen, socket-free STARTING replacement may be stopped
    with Supervisor's short stopwaitsecs; a serving replacement is drained again.
    """
    graceful_stop(original_pid)
    if config["region"] != "us":
        return
    deadline = time.monotonic() + 15
    serving_retries = 0
    while time.monotonic() < deadline:
        state, pid = supervisor_worker_state()
        if state == "STOPPED" and pid == 0:
            return
        stop_command = None
        if pid == 0:
            # stopProcess rejects EXITED/FATAL/STOPPING with NOT_RUNNING;
            # BACKOFF may respawn between a state read and the stop RPC. Wait
            # for a replacement we can actually freeze instead of guessing.
            if state == "FATAL" and recovery:
                # FATAL is stable/non-autorestarting. Recovery must be able to
                # restore a candidate that failed startup; fresh apply may not.
                time.sleep(0.1)
                require(supervisor_worker_state() == ("FATAL", 0),
                        "Fatal worker state changed while preparing recovery")
                return
            require(state != "FATAL", "Clone supervisor is FATAL; source was not replaced")
            require(state in {"EXITED", "BACKOFF", "STOPPING", "STARTING"},
                    "Unexpected process-free clone supervisor state")
            time.sleep(0.1)
            continue
        elif process_alive(pid):
            with paused_process(pid):
                # Freeze before inspecting so the replacement cannot open its
                # listener between the zero-socket check and Supervisor STOPPING.
                state_now, pid_now = supervisor_worker_state()
                safe_start = (pid_now == pid and state_now == "STARTING"
                              and not worker_port_sockets(pid, config["port"])
                              and not any((config["data"] / "voices").glob(".vc_*.*.building")))
                if safe_start:
                    stop_command = begin_supervisor_stop()
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        stopping, stopping_pid = supervisor_worker_state()
                        if stopping == "STOPPING" and stopping_pid == pid:
                            break
                        if stopping == "STOPPED" and stopping_pid == 0:
                            break
                        time.sleep(0.05)
                    else:
                        raise ReleaseError("Supervisor did not acknowledge replacement STOPPING")
            if stop_command is None:
                # The replacement already serves requests. Never apply the
                # shorter Supervisor timeout to it; let Uvicorn drain naturally.
                graceful_stop(pid)
                serving_retries += 1
                require(serving_retries <= 3, "Repeated replacement became active; source was not replaced")
                deadline = time.monotonic() + 15
                continue
        else:
            time.sleep(0.1)
            continue
        if stop_command is not None:
            stop_command.communicate(timeout=25)
            require_supervisor_stopped()
            return
    raise ReleaseError("Could not safely suppress worker autorestart; source was not replaced")


def start_worker(config: dict, *, recovery: bool = False) -> None:
    if config["region"] == "us":
        require_supervisor_stopped(recovery=recovery)
        run(["supervisorctl", "start", "castreader-clone"], timeout=60)
    # China watchdog alone replaces its exited worker; never signal its Nari PID.


def graceful_restart(config: dict, old_pid: int) -> None:
    stop_worker_for_swap(config, old_pid)
    start_worker(config)


def apply_release(config: dict, bundle: Path, manifest: dict, *, execute: bool) -> dict:
    pids = service_pids(config)
    require(all(process_alive(pid) for pid in pids.values()), "Existing stack is not running")
    require(http_json(config["nari_port"], "/ready").get("ready") is True, "Nari not ready")
    require(http_json(8880, "/health"), "Existing TTS not healthy")
    changed = set(manifest["files"])
    marker = config["data"] / ".xvector-writer-v1-enabled"
    require(marker.is_file() and not marker.is_symlink(), "Existing bound writer marker required")
    before = protected_snapshot(config, changed)
    evidence = preflight(config, bundle, pids["worker"])
    if not execute:
        return {"executed": False, "region": config["region"], "preflight": evidence,
                "source_commit": manifest["source_commit"], "changed_files": sorted(changed)}
    wait_idle(config)
    require(service_pids(config) == pids, "Service changed during preflight; retry from fresh state")
    require(protected_snapshot(config, changed) == before, "Protected source changed during preflight")
    # Validate the old binding once more before taking a recoverable backup.
    validator = activation_module(config["worker"])
    require(validator.marker_matches_current_release(marker,
            worker=config["worker"] / "clone_worker.py",
            builder=config["worker"] / "build_prompt.py",
            activation_validator=config["worker"] / "xvector_activation.py"),
            "Existing writer marker no longer matches live source")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}"
    backup = config["base"] / "backups" / f"fixed-deepfilter-worker-{stamp}"
    backup.mkdir(parents=True, mode=0o700)
    for name in sorted(changed):
        target = config["worker"] / name
        require(target.is_file() and not target.is_symlink(), f"Existing target required: {name}")
        shutil.copy2(target, backup / name)
    shutil.copy2(marker, backup / "writer-marker.json")
    shutil.copy2(bundle / "manifest.json", backup / "source-manifest.json")
    old_marker = load_object(marker)
    record = {
        "source_commit": manifest["source_commit"], "deployed_at": stamp,
        "hotpath": "nari-x-vector-only", "writer_activation": "requires-bound-release-marker-v1",
        "release_type": "fixed-deepfilter-worker-only", "changed_files": sorted(changed),
        "source_manifest_sha256": digest(bundle / "manifest.json"),
        "previous_release_record": old_marker["release_record"],
        "previous_source_commit": old_marker["source_commit"],
        "worker_sha256": {path.name: (manifest["files"].get(path.name) or digest(path))
                          for path in config["worker"].glob("*.py")},
        "nari_sha256": {str(path.relative_to(config["nari"])): digest(path)
                        for path in config["nari"].rglob("*.py")},
        "runner_sha256": digest(config["runner"]), "protected_before": before,
        "adaptive_denoise": {"selector": POLICY, "all_recordings": True, "raw_fallback": False},
        "preflight": evidence, "backup": str(backup),
    }
    releases = config["base"] / "releases"
    releases.mkdir(exist_ok=True)
    release_record = releases / f"fast-hotpath-fixed-deepfilter-{stamp}.json"
    require(not release_record.exists(), "Release record already exists")
    backup_info = {
        "region": config["region"], "release_record": str(release_record),
        "source_commit": manifest["source_commit"], "changed_files": sorted(changed),
        "worker_sha256": {name: digest(backup / name) for name in changed},
        "writer_marker_sha256": digest(backup / "writer-marker.json"),
        "protected_before": before,
    }
    write_json(backup / "backup-info.json", backup_info)
    record["backup_info_sha256"] = digest(backup / "backup-info.json")
    write_json(release_record, record)
    # Prepare the attestation before touching production. It binds the candidate
    # Worker hash to the unchanged, currently deployed builder/validator/reader.
    staged_marker = backup / "candidate-marker.json"
    validator.activate_xvector_writer(marker=staged_marker, source_commit=manifest["source_commit"],
        release_record=release_record, releases_dir=releases,
        worker=bundle / "worker/clone_worker.py", builder=config["worker"] / "build_prompt.py",
        activation_validator=config["worker"] / "xvector_activation.py",
        reader=config["nari"] / "model/text.py",
        schema_probe=lambda: validator.EXPECTED_DRY_RUN)  # genuine probe already passed above
    touched = False
    try:
        # Uvicorn drains already accepted requests on SIGTERM. Wait for natural
        # exit before replacing source, so its default supervisor stop timeout
        # cannot truncate an in-flight creation. All bytes/marker are prepared.
        with paused_watchdog(config, pids):
            touched = True
            stop_worker_for_swap(config, pids["worker"])
            current = service_pids(config)
            require(current["nari"] == pids["nari"] and current["tts"] == pids["tts"],
                    "Protected process changed while draining")
            require(current["worker"] in (0, pids["worker"]) or not process_alive(current["worker"]),
                    "Worker restarted before source swap; abort and re-evaluate idle window")
            for name in sorted(changed):
                atomic_copy(bundle / "worker" / name, config["worker"] / name)
            atomic_copy(staged_marker, marker)
        start_worker(config)
        result = wait_restarted(config, pids, fixed=True)
        require(protected_snapshot(config, changed) == before, "Protected files changed during release")
        write_json(backup / "verification.json", result)
        return {"executed": True, "region": config["region"], "release_record": str(release_record),
                "backup": str(backup), "source_commit": manifest["source_commit"],
                "changed_files": sorted(changed), "preflight": evidence,
                "voice_creation_enabled": True, "policy": POLICY,
                "nari_tts_unchanged": True, "worker_pid": result["pids"]["worker"]}
    except BaseException as error:
        if touched:
            # Restore the exact original marker, not an absent/disabled marker.
            # Its release record stays immutable and already describes these bytes.
            files_restored = False
            try:
                current = service_pids(config)
                with paused_watchdog(config, current):
                    stop_worker_for_swap(config, current["worker"], recovery=True)
                    for name in sorted(changed):
                        atomic_copy(backup / name, config["worker"] / name)
                    atomic_copy(backup / "writer-marker.json", marker)
                    files_restored = True
                start_worker(config, recovery=True)
                restored = wait_restarted(config, current, fixed=False)
                require(restored["pids"]["nari"] == pids["nari"]
                        and restored["pids"]["tts"] == pids["tts"],
                        "Original protected Nari/TTS processes did not survive")
                write_json(backup / "rollback-verification.json", restored)
            except BaseException as recovery_error:
                progress = ("original files/marker restored; worker recovery needs attention" if files_restored
                            else "original files/marker were NOT fully restored; recovery needs attention")
                failure = ReleaseError(f"Release failed; {progress}: {backup}")
                failure.recovery_error = recovery_error
                raise failure from error
        raise ReleaseError(f"Release failed and original worker/marker restored: {backup}") from error


def validate_rollback(config: dict, backup: Path) -> tuple[dict, set[str]]:
    """Accept only this tool's bound backup of the currently deployed release."""
    require(not backup.is_symlink(), "Rollback backup may not be a symlink")
    resolved = backup.resolve(strict=True)
    expected_parent = (config["base"] / "backups").resolve(strict=True)
    require(resolved.parent == expected_parent
            and re.fullmatch(r"fixed-deepfilter-worker-\d{8}T\d{6}Z-\d+", resolved.name),
            "Rollback requires a direct, named worker-release backup")
    info = load_object(backup / "backup-info.json")
    require(info.get("region") == config["region"], "Rollback region mismatch")
    changed = set(info.get("changed_files", []))
    require("clone_worker.py" in changed and changed <= ALLOWED_FILES,
            "Rollback contains out-of-scope files")
    record_path = Path(info.get("release_record", ""))
    require(record_path.resolve(strict=True).parent == (config["base"] / "releases").resolve(strict=True),
            "Rollback release record must belong to this region")
    record = load_object(record_path)
    require(record.get("release_type") == "fixed-deepfilter-worker-only"
            and record.get("backup") == str(resolved)
            and record.get("source_commit") == info.get("source_commit")
            and set(record.get("changed_files", [])) == changed,
            "Rollback release/backup association mismatch")
    require(record.get("backup_info_sha256") == digest(backup / "backup-info.json"),
            "Rollback backup metadata changed")
    source = load_object(backup / "source-manifest.json")
    require(record.get("source_manifest_sha256") == digest(backup / "source-manifest.json")
            and source.get("source_commit") == record.get("source_commit"),
            "Rollback immutable source manifest mismatch")
    current_marker = config["data"] / ".xvector-writer-v1-enabled"
    current = load_object(current_marker)
    require(current.get("release_record") == str(record_path.resolve()),
            "This backup is not for the currently active release")
    validator = activation_module(config["worker"])
    common = dict(builder=config["worker"] / "build_prompt.py",
                  activation_validator=config["worker"] / "xvector_activation.py")
    require(validator.marker_matches_current_release(current_marker,
            worker=config["worker"] / "clone_worker.py", **common),
            "Current writer marker is not bound to current source")
    old_marker = backup / "writer-marker.json"
    require(not old_marker.is_symlink()
            and digest(old_marker) == info.get("writer_marker_sha256"),
            "Original writer marker checksum mismatch")
    require(validator.marker_matches_current_release(old_marker,
            worker=backup / "clone_worker.py", **common),
            "Original backup no longer matches its original bound release")
    old_record = load_object(Path(load_object(old_marker)["release_record"]))
    for name in changed:
        saved = backup / name
        require(saved.is_file() and not saved.is_symlink(), "Invalid saved worker file")
        saved_hash = digest(saved)
        require(saved_hash == info.get("worker_sha256", {}).get(name)
                and saved_hash == old_record.get("worker_sha256", {}).get(name),
                f"Original release checksum mismatch: {name}")
        require(digest(config["worker"] / name) == record.get("worker_sha256", {}).get(name),
                f"Current worker source drifted: {name}")
    require(protected_snapshot(config, changed) == info.get("protected_before"),
            "Nari, builder, runner or another protected file changed; rollback refused")
    return info, changed


def rollback_release(config: dict, backup: Path, *, execute: bool) -> dict:
    info, changed = validate_rollback(config, backup)
    if not execute:
        return {"executed": False, "rollback_ready": True, "region": config["region"],
                "backup": str(backup), "changed_files": sorted(changed)}
    if not fatal_recovery_without_http(config):
        wait_idle(config, require_creation_enabled=False)
    pids = service_pids(config)
    # Recheck hashes/binding after waiting: never roll back a newer concurrent release.
    validate_rollback(config, backup)
    with paused_watchdog(config, pids):
        stop_worker_for_swap(config, pids["worker"], recovery=True)
        for name in sorted(changed):
            atomic_copy(backup / name, config["worker"] / name)
        atomic_copy(backup / "writer-marker.json", config["data"] / ".xvector-writer-v1-enabled")
    start_worker(config, recovery=True)
    result = wait_restarted(config, pids, fixed=False)
    require(protected_snapshot(config, changed) == info["protected_before"],
            "Protected source changed during rollback")
    write_json(backup / "manual-rollback-verification.json", result)
    return {"executed": True, "rolled_back": True, "region": config["region"],
            "backup": str(backup), "voice_creation_enabled": True, "nari_tts_unchanged": True}


def fatal_recovery_without_http(config: dict) -> bool:
    """Only a stable, socket-free US FATAL worker may skip its unavailable health."""
    if config["region"] != "us" or supervisor_worker_state() != ("FATAL", 0):
        return False
    time.sleep(0.1)
    require(supervisor_worker_state() == ("FATAL", 0), "Fatal worker changed during recovery gate")
    pids = service_pids(config)
    require(pids["worker"] == 0 and process_alive(pids["nari"]) and process_alive(pids["tts"]),
            "Protected serving processes must be alive during fatal recovery")
    require(http_json(config["nari_port"], "/ready").get("ready") is True,
            "Protected Nari is not ready for fatal recovery")
    require(http_json(8880, "/health"), "Protected TTS is not healthy for fatal recovery")
    for filename in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in Path(filename).read_text().splitlines()[1:]:
            fields = line.split()
            require(not (int(fields[1].rsplit(":", 1)[1], 16) == config["port"]
                         and fields[3] in {"01", "0A"}),
                    "Worker port still has active sockets; fatal recovery refused")
    return True


def diagnostic_exception_chain(error: BaseException) -> list[dict]:
    """No command, stderr, arbitrary exception text, or environment is exposed."""
    items, pending, seen = [], [("failure", error)], set()
    while pending and len(items) < 8:
        relation, current = pending.pop(0)
        if id(current) in seen:
            continue
        seen.add(id(current))
        item = {"relation": relation, "class": type(current).__name__}
        if isinstance(current, ReleaseError):
            item["message"] = str(current)[:600]
        if isinstance(current, subprocess.CalledProcessError):
            item["returncode"] = current.returncode
        items.append(item)
        recovery = getattr(current, "recovery_error", None)
        if isinstance(recovery, BaseException):
            pending.append(("recovery", recovery))
        cause = current.__cause__ or current.__context__
        if cause is not None:
            pending.append(("cause", cause))
    return items


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    packaging = commands.add_parser("package", help="Create bundle from exact committed Git blobs")
    packaging.add_argument("--repo", required=True, type=Path)
    packaging.add_argument("--source-commit", required=True)
    packaging.add_argument("--destination", required=True, type=Path)
    packaging.add_argument("--worker-file", action="append", default=[])
    applying = commands.add_parser("apply", help="Host-side preflight; add --execute to deploy")
    applying.add_argument("--region", choices=("cn", "us"), required=True)
    applying.add_argument("--bundle", required=True, type=Path)
    applying.add_argument("--source-commit", required=True)
    applying.add_argument("--manifest-sha256", required=True)
    applying.add_argument("--execute", action="store_true")
    rollback = commands.add_parser("rollback", help="Validate/recover only the current release's bound backup")
    rollback.add_argument("--region", choices=("cn", "us"), required=True)
    rollback.add_argument("--backup", required=True, type=Path)
    rollback.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    # Ensure TERM runs the watchdog-resume and rollback finally blocks. SIGKILL
    # is covered for watchdog resume by the independent pipe guard above.
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f"release interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        if args.command == "package":
            result = package(args.repo.resolve(), args.source_commit, args.destination.resolve(),
                             args.worker_file or ["clone_worker.py"])
        elif args.command == "apply":
            manifest = validate_bundle(args.bundle, args.source_commit, args.manifest_sha256)
            result = apply_release(region_config(args.region), args.bundle.resolve(), manifest,
                                   execute=args.execute)
        else:
            result = rollback_release(region_config(args.region), args.backup, execute=args.execute)
        print(json.dumps(result, sort_keys=True))
    except (ReleaseError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "release_aborted", "errors": diagnostic_exception_chain(error)}),
              file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
