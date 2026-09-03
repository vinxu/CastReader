"""No SSH, processes, or production writes: worker-only release safety contracts."""

from __future__ import annotations

import hashlib
from contextlib import nullcontext
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch


DEPLOY_SCRIPT = Path(__file__).parents[1] / "deploy/release-fixed-deepfilter-worker.py"
SPEC = importlib.util.spec_from_file_location("fixed_worker_release", DEPLOY_SCRIPT)
assert SPEC and SPEC.loader
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class FixedWorkerReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.addCleanup(self.temporary.cleanup)

    def make_bundle(self, files=None):
        bundle = self.root / "bundle"
        (bundle / "worker").mkdir(parents=True)
        files = files or {"clone_worker.py": b"POLICY = 'fixed'\n"}
        for name, value in files.items():
            (bundle / "worker" / name).write_bytes(value)
        manifest = {
            "bundle_version": 1,
            "release_type": "fixed-deepfilter-worker-only",
            "source_commit": "a" * 40,
            "policy": release.POLICY,
            "files": {name: hashlib.sha256(value).hexdigest() for name, value in files.items()},
            "tool_sha256": release.digest(DEPLOY_SCRIPT),
        }
        release.write_json(bundle / "manifest.json", manifest)
        return bundle, manifest

    def validate(self, bundle, commit="a" * 40):
        return release.validate_bundle(bundle, commit, release.digest(bundle / "manifest.json"))

    def test_valid_bundle(self):
        bundle, expected = self.make_bundle()
        self.assertEqual(self.validate(bundle), expected)

    def test_wrong_manifest_hash_aborts(self):
        bundle, _ = self.make_bundle()
        with self.assertRaisesRegex(release.ReleaseError, "Manifest checksum"):
            release.validate_bundle(bundle, "a" * 40, "b" * 64)

    def test_wrong_source_commit_aborts(self):
        bundle, _ = self.make_bundle()
        with self.assertRaisesRegex(release.ReleaseError, "Source commit mismatch"):
            self.validate(bundle, "b" * 40)

    def test_short_commit_aborts(self):
        bundle, _ = self.make_bundle()
        with self.assertRaisesRegex(release.ReleaseError, "source commit"):
            self.validate(bundle, "abcdef")

    def test_modified_worker_aborts(self):
        bundle, _ = self.make_bundle()
        (bundle / "worker/clone_worker.py").write_text("changed = True\n")
        with self.assertRaisesRegex(release.ReleaseError, "Bundle checksum"):
            self.validate(bundle)

    def test_cannot_replace_builder_or_nari(self):
        for filename in ("build_prompt.py", "text.py", "xvector_activation.py", "run-worker.sh"):
            with self.subTest(filename=filename):
                manifest = {"clone_worker.py": "a" * 64, filename: "b" * 64}
                with patch.object(release, "digest", return_value="c" * 64), patch.object(
                    release, "load_object", return_value={"bundle_version": 1,
                    "release_type": "fixed-deepfilter-worker-only", "source_commit": "a" * 40,
                    "policy": release.POLICY, "files": manifest}):
                    with self.assertRaisesRegex(release.ReleaseError, "out-of-scope"):
                        release.validate_bundle(self.root, "a" * 40, "c" * 64)

    def test_wrong_tool_aborts(self):
        bundle, manifest = self.make_bundle()
        manifest["tool_sha256"] = "c" * 64
        release.write_json(bundle / "manifest.json", manifest)
        with self.assertRaisesRegex(release.ReleaseError, "included in this immutable bundle"):
            self.validate(bundle)

    def test_symlink_worker_aborts(self):
        bundle, _ = self.make_bundle()
        target = bundle / "worker/clone_worker.py"
        target.rename(bundle / "elsewhere.py")
        target.symlink_to(bundle / "elsewhere.py")
        with self.assertRaisesRegex(release.ReleaseError, "Invalid bundle file"):
            self.validate(bundle)

    def test_idle_requires_no_outer_build(self):
        health = {"status": "healthy", "voice_creation_enabled": True,
                  "busy": False, "queue_depth": 0, "active_voice_tasks": 1}
        self.assertFalse(release.idle_health(health, 0, False))
        health["active_voice_tasks"] = 0
        self.assertTrue(release.idle_health(health, 0, False))
        self.assertFalse(release.idle_health(health, 1, False))
        self.assertFalse(release.idle_health(health, 0, True))

    def test_old_worker_idle_still_requires_no_connections(self):
        health = {"status": "healthy", "voice_creation_enabled": True,
                  "busy": False, "queue_depth": 0}
        self.assertTrue(release.idle_health(health, 0, False))
        self.assertFalse(release.idle_health(health, 1, False))

    def test_rollback_can_drain_when_creation_is_disabled(self):
        health = {"status": "healthy", "voice_creation_enabled": False,
                  "busy": False, "queue_depth": 0, "active_voice_tasks": 0}
        self.assertFalse(release.idle_health(health, 0, False))
        self.assertTrue(release.idle_health(health, 0, False, require_creation_enabled=False))
        self.assertFalse(release.idle_health(health, 1, False, require_creation_enabled=False))
        health["active_voice_tasks"] = 1
        self.assertFalse(release.idle_health(health, 0, False, require_creation_enabled=False))

    def test_fixed_health_requires_enabled_writer_and_actual_dependencies(self):
        health = {"status": "healthy", "voice_creation_enabled": True,
                  "voice_prompt_writer_schema": "xvector_v1", "adaptive_denoise": {
                  "selector_version": release.POLICY, "mode": "on", "all_recordings": True,
                  "raw_fallback": False, "deepfilter": {"ready": True},
                  "diarization": {"ready": True}}}
        self.assertTrue(release.fixed_health(health))
        health["voice_creation_enabled"] = False
        self.assertFalse(release.fixed_health(health))
        health["voice_creation_enabled"] = True
        health["adaptive_denoise"]["deepfilter"]["ready"] = False
        self.assertFalse(release.fixed_health(health))

    def test_atomic_copy_keeps_destination_mode(self):
        source, destination = self.root / "source", self.root / "destination"
        source.write_text("new")
        destination.write_text("old")
        destination.chmod(0o640)
        release.atomic_copy(source, destination)
        self.assertEqual(destination.read_text(), "new")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o640)

    def test_atomic_copy_rejects_absent_target(self):
        source = self.root / "source"
        source.write_text("new")
        with self.assertRaisesRegex(release.ReleaseError, "unexpected replacement"):
            release.atomic_copy(source, self.root / "absent")

    def test_package_reads_commit_not_dirty_worktree(self):
        repo = self.root / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        worker = repo / release.PREFIX / "worker/clone_worker.py"
        worker.parent.mkdir(parents=True)
        worker.write_text("version = 'committed'\n")
        tool = repo / release.TOOL_PATH
        tool.parent.mkdir(parents=True)
        tool.write_bytes(DEPLOY_SCRIPT.read_bytes())
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Release Test",
                        "-c", "user.email=release@example.invalid", "commit", "-qm", "source"], check=True)
        commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
        worker.write_text("version = 'dirty-and-unreviewed'\n")
        bundle = self.root / "committed-bundle"
        result = release.package(repo, commit, bundle, ["clone_worker.py"])
        self.assertEqual((bundle / "worker/clone_worker.py").read_text(), "version = 'committed'\n")
        self.assertEqual(result["source_commit"], commit)
        self.assertEqual(release.validate_bundle(bundle, commit, result["manifest_sha256"])["source_commit"], commit)

    def test_restart_never_signals_nari_or_forces_kill(self):
        with patch.object(release, "process_alive", side_effect=[True, False, False]), \
             patch.object(release.os, "kill") as kill, patch.object(release, "run") as run:
            release.graceful_stop(321)
        kill.assert_called_once_with(321, release.signal.SIGTERM)
        run.assert_not_called()

    def test_china_restart_is_worker_term_only(self):
        with patch.object(release, "process_alive", side_effect=[True, False, False]), \
             patch.object(release.os, "kill") as kill, patch.object(release, "run") as run:
            release.graceful_restart({"region": "cn"}, 654)
        kill.assert_called_once_with(654, release.signal.SIGTERM)
        run.assert_not_called()

    def test_china_watchdog_always_resumed_on_failure(self):
        config = {"region": "cn", "base": self.root}
        command = f"/bin/bash\0{self.root}/deploy/watchdog-china-staging.sh\0".encode()
        guard = MagicMock()
        with patch.object(release, "process_identity", side_effect=[(333, "nari"),
             (333, "worker"), (1, "watchdog-start"), (1, "watchdog-start")]), \
             patch.object(release, "process_alive", return_value=True), \
             patch.object(release, "wait_process_stopped"), \
             patch.object(release.Path, "read_bytes", return_value=command), \
             patch.object(release.subprocess, "Popen", return_value=guard) as popen, \
             patch.object(release.os, "kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "swap failed"):
                with release.paused_watchdog(config, {"worker": 111, "nari": 222, "tts": 444}):
                    raise RuntimeError("swap failed")
        self.assertEqual(kill.call_args_list, [unittest.mock.call(333, release.signal.SIGSTOP),
                                              unittest.mock.call(333, release.signal.SIGCONT)])
        guard.stdin.close.assert_called_once()
        guard.wait.assert_called_once_with(timeout=3)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_failed_health_restores_exact_original_worker_and_marker(self):
        bundle, manifest = self.make_bundle()
        base = self.root / "live"
        worker, nari = base / "worker", base / "nari"
        worker.mkdir(parents=True)
        (nari / "model").mkdir(parents=True)
        (worker / "clone_worker.py").write_text("old_worker = True\n")
        (worker / "build_prompt.py").write_text("builder = True\n")
        (worker / "xvector_activation.py").write_text("activation = True\n")
        (nari / "model/text.py").write_text("reader = True\n")
        (base / "runner.sh").write_text("unchanged-runner")
        marker = base / ".xvector-writer-v1-enabled"
        original_marker = b'{"release_record":"/original/release.json","source_commit":"old"}\n'
        marker.write_bytes(original_marker)
        config = {"region": "us", "base": base, "worker": worker, "nari": nari,
                  "data": base, "port": 8890, "nari_port": 8094, "runner": base / "runner.sh"}
        old = {"worker": 111, "nari": 222, "tts": 333}
        stopped = {"worker": 0, "nari": 222, "tts": 333}
        candidate = {"worker": 444, "nari": 222, "tts": 333}
        restored = {"worker": 555, "nari": 222, "tts": 333}
        validator = MagicMock()
        validator.marker_matches_current_release.return_value = True
        validator.activate_xvector_writer.side_effect = lambda **args: args["marker"].write_text("candidate-marker")
        with patch.object(release, "service_pids", side_effect=[old, old, stopped, candidate]), \
             patch.object(release, "process_alive", return_value=True), \
             patch.object(release, "http_json", return_value={"ready": True}), \
             patch.object(release, "preflight", return_value={"deepfilter_applied": True}), \
             patch.object(release, "protected_snapshot", return_value={"untouched": "same"}), \
             patch.object(release, "wait_idle"), patch.object(release, "stop_worker_for_swap"), \
             patch.object(release, "start_worker"), \
             patch.object(release, "activation_module", return_value=validator), \
             patch.object(release, "wait_restarted", side_effect=[release.ReleaseError("bad candidate"),
                          {"pids": restored, "health": {"status": "healthy", "voice_creation_enabled": True}}]):
            with self.assertRaisesRegex(release.ReleaseError, "original worker/marker restored"):
                release.apply_release(config, bundle, manifest, execute=True)
        self.assertEqual((worker / "clone_worker.py").read_text(), "old_worker = True\n")
        self.assertEqual(marker.read_bytes(), original_marker)
        self.assertEqual((nari / "model/text.py").read_text(), "reader = True\n")
        self.assertEqual((base / "runner.sh").read_text(), "unchanged-runner")

    def rollback_fixture(self):
        base = self.root / "rollback-live"
        worker, nari = base / "worker", base / "nari"
        backup = base / "backups/fixed-deepfilter-worker-20260903T000000Z-123"
        for directory in (worker, nari / "model", backup, base / "releases"):
            directory.mkdir(parents=True, exist_ok=True)
        (worker / "clone_worker.py").write_text("version = 'original'\n")
        (worker / "build_prompt.py").write_text("unchanged_builder = True\n")
        (worker / "xvector_activation.py").write_bytes(
            (DEPLOY_SCRIPT.parents[1] / "worker/xvector_activation.py").read_bytes())
        (nari / "model/text.py").write_text("unchanged_reader = True\n")
        (base / "runner.sh").write_text("unchanged_runner")
        config = dict(region="us", base=base, worker=worker, nari=nari, data=base,
                      port=8890, nari_port=8094, runner=base / "runner.sh", extra_protected=[])
        marker = base / ".xvector-writer-v1-enabled"
        validator = release.activation_module(worker)
        def activate(record_path, commit):
            validator.activate_xvector_writer(marker=marker, source_commit=commit,
                release_record=record_path, releases_dir=base / "releases",
                worker=worker / "clone_worker.py", builder=worker / "build_prompt.py",
                activation_validator=worker / "xvector_activation.py", reader=nari / "model/text.py",
                schema_probe=lambda: validator.EXPECTED_DRY_RUN)
        def record(commit):
            return {"source_commit": commit, "hotpath": "nari-x-vector-only",
                    "writer_activation": "requires-bound-release-marker-v1",
                    "worker_sha256": {path.name: release.digest(path) for path in worker.glob("*.py")},
                    "nari_sha256": {"model/text.py": release.digest(nari / "model/text.py")}}
        original = base / "releases/fast-hotpath-original.json"
        release.write_json(original, record("a" * 40))
        activate(original, "a" * 40)
        (backup / "writer-marker.json").write_bytes(marker.read_bytes())
        (backup / "clone_worker.py").write_bytes((worker / "clone_worker.py").read_bytes())
        current = base / "releases/fast-hotpath-fixed-deepfilter-current.json"
        info = {"region": "us", "release_record": str(current), "source_commit": "b" * 40,
                "changed_files": ["clone_worker.py"],
                "worker_sha256": {"clone_worker.py": release.digest(backup / "clone_worker.py")},
                "writer_marker_sha256": release.digest(backup / "writer-marker.json"),
                "protected_before": release.protected_snapshot(config, {"clone_worker.py"})}
        release.write_json(backup / "backup-info.json", info)
        release.write_json(backup / "source-manifest.json", {"source_commit": "b" * 40})
        (worker / "clone_worker.py").write_text("version = 'candidate'\n")
        candidate = record("b" * 40)
        candidate.update(release_type="fixed-deepfilter-worker-only", backup=str(backup),
                         changed_files=["clone_worker.py"],
                         backup_info_sha256=release.digest(backup / "backup-info.json"),
                         source_manifest_sha256=release.digest(backup / "source-manifest.json"))
        release.write_json(current, candidate)
        activate(current, "b" * 40)
        return config, backup

    def test_manual_rollback_validates_both_actual_release_markers(self):
        config, backup = self.rollback_fixture()
        result = release.rollback_release(config, backup, execute=False)
        self.assertTrue(result["rollback_ready"])
        self.assertFalse(result["executed"])

    def test_manual_rollback_rejects_arbitrary_backup_root(self):
        config, backup = self.rollback_fixture()
        with self.assertRaisesRegex(release.ReleaseError, "direct, named"):
            release.validate_rollback(config, backup.parent)

    def test_manual_rollback_rejects_old_worker_tampering(self):
        config, backup = self.rollback_fixture()
        (backup / "clone_worker.py").write_text("not_original = True\n")
        with self.assertRaisesRegex(release.ReleaseError, "original bound release"):
            release.validate_rollback(config, backup)

    def test_manual_rollback_rejects_protected_reader_drift(self):
        config, backup = self.rollback_fixture()
        (config["nari"] / "model/text.py").write_text("reader_changed = True\n")
        with self.assertRaisesRegex(release.ReleaseError, "Current writer marker"):
            release.validate_rollback(config, backup)

    def test_manual_rollback_restores_old_marker_and_keeps_reader(self):
        config, backup = self.rollback_fixture()
        old_marker = (backup / "writer-marker.json").read_bytes()
        pids = {"worker": 111, "nari": 222, "tts": 333}
        with patch.object(release, "wait_idle"), patch.object(release, "service_pids", return_value=pids), \
             patch.object(release, "fatal_recovery_without_http", return_value=False), \
             patch.object(release, "stop_worker_for_swap"), patch.object(release, "start_worker"), \
             patch.object(release, "wait_restarted", return_value={"pids": {**pids, "worker": 444},
                          "health": {"status": "healthy", "voice_creation_enabled": True}}):
            result = release.rollback_release(config, backup, execute=True)
        self.assertTrue(result["rolled_back"])
        self.assertEqual((config["data"] / ".xvector-writer-v1-enabled").read_bytes(), old_marker)
        self.assertEqual((config["worker"] / "clone_worker.py").read_text(), "version = 'original'\n")
        self.assertEqual((config["nari"] / "model/text.py").read_text(), "unchanged_reader = True\n")

    def test_us_start_requires_supervisor_stopped(self):
        with patch.object(release, "supervisor_worker_state", return_value=("STOPPED", 0)), \
             patch.object(release, "run") as run:
            release.start_worker({"region": "us"})
        run.assert_called_once_with(["supervisorctl", "start", "castreader-clone"], timeout=60)
        with patch.object(release, "supervisor_worker_state", return_value=("STARTING", 444)), \
             patch.object(release, "run") as run:
            with self.assertRaisesRegex(release.ReleaseError, "supervisor STOPPED"):
                release.start_worker({"region": "us"})
        run.assert_not_called()

    def test_us_respawn_is_frozen_and_supervised_stopped_before_swap(self):
        command = MagicMock()
        states = [("STARTING", 444), ("STARTING", 444), ("STOPPING", 444), ("STOPPED", 0)]
        with patch.object(release, "graceful_stop") as drain, \
             patch.object(release, "supervisor_worker_state", side_effect=states), \
             patch.object(release, "process_alive", return_value=True), \
             patch.object(release, "paused_process", side_effect=lambda pid: nullcontext()) as pause, \
             patch.object(release, "worker_port_sockets", return_value=set()), \
             patch.object(release, "begin_supervisor_stop", return_value=command) as stop:
            release.stop_worker_for_swap({"region": "us", "port": 8890, "data": self.root}, 111)
        drain.assert_called_once_with(111)
        pause.assert_called_once_with(444)
        stop.assert_called_once()
        command.communicate.assert_called_once_with(timeout=25)

    def test_us_serving_replacement_is_drained_not_short_timeout_stopped(self):
        command = MagicMock()
        states = [("RUNNING", 444), ("RUNNING", 444), ("STARTING", 555),
                  ("STARTING", 555), ("STOPPING", 555), ("STOPPED", 0)]
        with patch.object(release, "graceful_stop") as drain, \
             patch.object(release, "supervisor_worker_state", side_effect=states), \
             patch.object(release, "process_alive", return_value=True), \
             patch.object(release, "paused_process", side_effect=lambda pid: nullcontext()), \
             patch.object(release, "worker_port_sockets", return_value=set()), \
             patch.object(release, "begin_supervisor_stop", return_value=command) as stop:
            release.stop_worker_for_swap({"region": "us", "port": 8890, "data": self.root}, 111)
        self.assertEqual(drain.call_args_list, [unittest.mock.call(111), unittest.mock.call(444)])
        stop.assert_called_once()

    def test_us_starting_listener_is_drained_before_catching_next_respawn(self):
        command = MagicMock()
        states = [("STARTING", 444), ("STARTING", 444), ("STARTING", 555),
                  ("STARTING", 555), ("STOPPING", 555), ("STOPPED", 0)]
        with patch.object(release, "graceful_stop") as drain, \
             patch.object(release, "supervisor_worker_state", side_effect=states), \
             patch.object(release, "process_alive", return_value=True), \
             patch.object(release, "paused_process", side_effect=lambda pid: nullcontext()), \
             patch.object(release, "worker_port_sockets", side_effect=[{"0A"}, set()]), \
             patch.object(release, "begin_supervisor_stop", return_value=command):
            release.stop_worker_for_swap({"region": "us", "port": 8890, "data": self.root}, 111)
        self.assertEqual(drain.call_args_list, [unittest.mock.call(111), unittest.mock.call(444)])

    def test_us_process_free_transient_states_never_send_stop_rpc(self):
        with patch.object(release, "graceful_stop"), \
             patch.object(release, "supervisor_worker_state", side_effect=[("EXITED", 0),
                          ("BACKOFF", 0), ("STOPPING", 0), ("STOPPED", 0)]), \
             patch.object(release.time, "sleep"), \
             patch.object(release, "begin_supervisor_stop") as stop:
            release.stop_worker_for_swap({"region": "us"}, 111)
        stop.assert_not_called()

    def test_us_fatal_fails_before_source_swap_without_ineffective_stop_rpc(self):
        with patch.object(release, "graceful_stop"), \
             patch.object(release, "supervisor_worker_state", return_value=("FATAL", 0)), \
             patch.object(release, "begin_supervisor_stop") as stop:
            with self.assertRaisesRegex(release.ReleaseError, "FATAL; source was not replaced"):
                release.stop_worker_for_swap({"region": "us"}, 111)
        stop.assert_not_called()

    def test_us_recovery_allows_stable_fatal_without_stop_rpc(self):
        with patch.object(release, "graceful_stop"), \
             patch.object(release, "supervisor_worker_state", return_value=("FATAL", 0)), \
             patch.object(release.time, "sleep"), \
             patch.object(release, "begin_supervisor_stop") as stop:
            release.stop_worker_for_swap({"region": "us"}, 0, recovery=True)
        stop.assert_not_called()

    def test_actual_candidate_start_fatal_recovers_original_source_and_marker(self):
        config, _ = self.rollback_fixture()
        bundle, manifest = self.make_bundle()
        original_source = (config["worker"] / "clone_worker.py").read_bytes()
        original_marker = (config["data"] / ".xvector-writer-v1-enabled").read_bytes()
        state = {"state": "RUNNING", "pid": 111, "starts": 0}
        def pids(_config):
            return {"worker": state["pid"], "nari": 222, "tts": 333}
        def drain(pid):
            if pid:
                state.update(state="STOPPED", pid=0)
        def supervisor_start(argv, **kwargs):
            self.assertEqual(argv, ["supervisorctl", "start", "castreader-clone"])
            state["starts"] += 1
            if state["starts"] == 1:
                state.update(state="FATAL", pid=0)
                raise subprocess.CalledProcessError(1, argv)
            self.assertEqual(state["state"], "FATAL")
            self.assertEqual((config["worker"] / "clone_worker.py").read_bytes(), original_source)
            self.assertEqual((config["data"] / ".xvector-writer-v1-enabled").read_bytes(), original_marker)
            state.update(state="RUNNING", pid=444)
            return "started"
        with patch.object(release, "service_pids", side_effect=pids), \
             patch.object(release, "process_alive", side_effect=lambda pid: pid > 0), \
             patch.object(release, "http_json", return_value={"ready": True}), \
             patch.object(release, "preflight", return_value={"deepfilter_applied": True}), \
             patch.object(release, "wait_idle"), patch.object(release, "graceful_stop", side_effect=drain), \
             patch.object(release, "supervisor_worker_state", side_effect=lambda: (state["state"], state["pid"])), \
             patch.object(release, "run", side_effect=supervisor_start), patch.object(release.time, "sleep"), \
             patch.object(release, "wait_restarted", side_effect=lambda *args, **kwargs: {
                          "pids": pids(config), "health": {"status": "healthy", "voice_creation_enabled": True}}):
            with self.assertRaisesRegex(release.ReleaseError, "original worker/marker restored"):
                release.apply_release(config, bundle, manifest, execute=True)
        self.assertEqual(state["starts"], 2)
        self.assertEqual((config["worker"] / "clone_worker.py").read_bytes(), original_source)
        self.assertEqual((config["data"] / ".xvector-writer-v1-enabled").read_bytes(), original_marker)

    def test_manual_fatal_rollback_skips_http_idle_only_at_verified_fatal_gate(self):
        config, backup = self.rollback_fixture()
        pids = {"worker": 0, "nari": 222, "tts": 333}
        with patch.object(release, "fatal_recovery_without_http", return_value=True), \
             patch.object(release, "wait_idle") as idle, \
             patch.object(release, "service_pids", return_value=pids), \
             patch.object(release, "stop_worker_for_swap") as stop, patch.object(release, "start_worker") as start, \
             patch.object(release, "wait_restarted", return_value={"pids": {**pids, "worker": 444},
                          "health": {"status": "healthy", "voice_creation_enabled": True}}):
            release.rollback_release(config, backup, execute=True)
        idle.assert_not_called()
        stop.assert_called_once_with(config, 0, recovery=True)
        start.assert_called_once_with(config, recovery=True)


if __name__ == "__main__":
    unittest.main()
