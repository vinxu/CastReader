#!/usr/bin/env python3
"""Exercise release stop/start against a new, isolated real supervisord only.

No default Supervisor socket is ever addressed. Every supervisorctl invocation
is forced to the newly generated test configuration, including calls made by
the imported release module. No production source, config, or service is edited.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def require(value, message):
    if not value:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-tool", required=True, type=Path)
    parser.add_argument("--execute-isolated", action="store_true")
    args = parser.parse_args()
    require(args.execute_isolated, "Add --execute-isolated after review")
    require(sys.platform == "linux", "Real /proc integration requires Linux")
    require(args.release_tool.is_file(), "Release tool missing")
    supervisord = shutil.which("supervisord")
    supervisorctl = shutil.which("supervisorctl")
    require(supervisord and supervisorctl, "Supervisor binaries missing")
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("isolated_release_test", args.release_tool)
    release = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(release)
    real_run, real_popen = subprocess.run, subprocess.Popen
    daemon = None
    result = {"ok": False}
    calls = []
    started = time.monotonic()
    # Runtime-generated config and dummy-process logs are deleted by this scope.
    with tempfile.TemporaryDirectory(prefix="castreader-supervisor-isolated-") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        configuration = root / "supervisord.conf"
        configuration.write_text(f"""[unix_http_server]
file={root}/supervisor.sock
chmod=0700

[supervisord]
nodaemon=true
logfile={root}/supervisord.log
pidfile={root}/supervisord.pid
childlogdir={root}
umask=0077

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://{root}/supervisor.sock

[program:castreader-clone]
command=/usr/bin/python3 -c "import time;time.sleep(300)"
autostart=true
autorestart=unexpected
startsecs=25
startretries=3
stopwaitsecs=10
stdout_logfile={root}/dummy.stdout.log
stderr_logfile={root}/dummy.stderr.log
""")
        configuration.chmod(0o600)
        (root / "voices").mkdir(mode=0o700)
        result["isolated_runtime"] = str(root)
        print(json.dumps({"stage": "isolated-config-ready", "directory": str(root)}), flush=True)

        def route(argv):
            require(isinstance(argv, (list, tuple)), "Shell or non-list subprocess calls forbidden")
            argv = [str(part) for part in argv]
            if Path(argv[0]).name == "supervisorctl":
                if argv[1:3] == ["-c", str(configuration)]:
                    routed = [supervisorctl, *argv[1:]]
                else:
                    require(not any(part in {"-c", "--configuration", "-s", "--serverurl"}
                                    or part.startswith("--serverurl=") for part in argv[1:]),
                            "Unexpected Supervisor config/server override")
                    routed = [supervisorctl, "-c", str(configuration), *argv[1:]]
                calls.append(routed)
                return routed
            # Release guard subprocess only; it signals a validated test-child PID.
            require(argv[:2] == [sys.executable, "-c"], "Unexpected non-Supervisor child command")
            return argv

        def guarded_run(argv, *positional, **keywords):
            require(not keywords.get("shell"), "Shell execution forbidden")
            return real_run(route(argv), *positional, **keywords)

        def guarded_popen(argv, *positional, **keywords):
            require(not keywords.get("shell"), "Shell execution forbidden")
            return real_popen(route(argv), *positional, **keywords)

        def control(*arguments, timeout=5):
            # Explicit -c even before installing/after restoring the guards.
            return real_run([supervisorctl, "-c", str(configuration), *arguments],
                            capture_output=True, text=True, timeout=timeout)

        def timed_out(*_):
            raise TimeoutError("Isolated lifecycle exceeded 95 seconds")

        previous_alarm = signal.signal(signal.SIGALRM, timed_out)
        previous_term = signal.signal(signal.SIGTERM, timed_out)
        previous_hup = signal.signal(signal.SIGHUP, timed_out)
        try:
            daemon = real_popen([supervisord, "-n", "-c", str(configuration)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
            result["isolated_supervisord_pid"] = daemon.pid
            signal.alarm(95)
            subprocess.run, subprocess.Popen = guarded_run, guarded_popen
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                require(daemon.poll() is None, "Isolated supervisord exited during startup")
                try:
                    state, first_pid = release.supervisor_worker_state()
                    if state == "RUNNING" and first_pid > 1:
                        break
                except (release.ReleaseError, ValueError, subprocess.SubprocessError):
                    pass
                time.sleep(0.2)
            else:
                raise TimeoutError("Isolated dummy never reached RUNNING")
            result["original_test_worker_pid"] = first_pid
            print(json.dumps({"stage": "initial-running", "elapsed_s": round(time.monotonic() - started, 2)}), flush=True)

            # The only patched behavior is CLI destination routing. All state,
            # signals, child replacement, /proc checks, and waits are real.
            config = {"region": "us", "port": 18991, "data": root}
            release.stop_worker_for_swap(config, first_pid)
            stopped = release.supervisor_worker_state()
            require(stopped == ("STOPPED", 0), "Release did not reach administrative STOPPED/PID0")
            stopped_status = control("status", "castreader-clone")
            stopped_pid = control("pid", "castreader-clone")
            result["stopped"] = {"state": stopped[0], "pid": stopped[1],
                                 "status_returncode": stopped_status.returncode,
                                 "pid_returncode": stopped_pid.returncode,
                                 "pid_stdout": stopped_pid.stdout.strip()}
            require(not release.process_alive(first_pid), "Original test child remains alive")
            print(json.dumps({"stage": "administratively-stopped", **result["stopped"]}), flush=True)

            release.start_worker(config)
            final_state, final_pid = release.supervisor_worker_state()
            require(final_state == "RUNNING" and final_pid > 1 and final_pid != first_pid,
                    "Release did not explicitly start a fresh test child")
            result["restarted_test_worker_pid"] = final_pid
            result["ok"] = True
            result["all_control_commands_isolated"] = all(
                command[1:3] == ["-c", str(configuration)] for command in calls)
            result["control_call_count"] = len(calls)
        except BaseException as error:
            result["error_type"] = type(error).__name__
            result["error"] = str(error)
        finally:
            signal.alarm(0)
            subprocess.run, subprocess.Popen = real_run, real_popen
            # Only this newly created daemon is addressed. It owns the dummy
            # process and cleans that child on shutdown (including stopwaitsecs).
            if daemon is not None:
                try:
                    control("shutdown", timeout=5)
                except (OSError, subprocess.SubprocessError):
                    pass
                try:
                    daemon.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    daemon.terminate()  # exact Popen-owned daemon, never production
                    try:
                        daemon.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        result["cleanup_error"] = "Isolated daemon did not exit; temp directory retained"
                        # Do not erase a still-live daemon's config/logs.
                        root.rename(root.with_name(root.name + "-needs-cleanup"))
                result["isolated_daemon_exited"] = daemon.poll() is not None
            signal.signal(signal.SIGALRM, previous_alarm)
            signal.signal(signal.SIGTERM, previous_term)
            signal.signal(signal.SIGHUP, previous_hup)
            result["elapsed_s"] = round(time.monotonic() - started, 3)
    print(json.dumps(result, indent=2), flush=True)
    return 0 if result["ok"] and result.get("isolated_daemon_exited") else 1


if __name__ == "__main__":
    raise SystemExit(main())
