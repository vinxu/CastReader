import ast
import base64
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
SOURCE_PATH = ROOT / "release-host.py"
OLD_SOURCE = b"old-gateway-source"
NEW_SOURCE = b"new-gateway-source"


def load_namespace():
    source = SOURCE_PATH.read_text()
    payload = {
        "sourceBase64": base64.b64encode(NEW_SOURCE).decode(),
        "sourceSha256": hashlib.sha256(NEW_SOURCE).hexdigest(),
        "sourceCommit": "test-commit",
        "baseline": {"files": [{"sha256": hashlib.sha256(OLD_SOURCE).hexdigest()}]},
    }
    namespace = {"PAYLOAD": payload}
    prefix = source.split("action = PAYLOAD['action']", 1)[0]
    exec(compile(prefix, str(SOURCE_PATH), "exec"), namespace)

    module = ast.parse(source)
    action_branch = next(
        node
        for node in module.body
        if isinstance(node, ast.If)
        and isinstance(node.test, ast.Compare)
        and isinstance(node.test.left, ast.Name)
        and node.test.left.id == "action"
    )
    apply_branch = action_branch.orelse[0]
    function = ast.FunctionDef(
        name="exercise_apply",
        args=ast.arguments(
            posonlyargs=[], args=[], kwonlyargs=[], kw_defaults=[], defaults=[]
        ),
        body=apply_branch.body,
        decorator_list=[],
    )
    ast.fix_missing_locations(function)
    exec(
        compile(ast.Module(body=[function], type_ignores=[]), str(SOURCE_PATH), "exec"),
        namespace,
    )
    return namespace


class FakeSignal:
    SIGINT = 2
    SIGTERM = 15
    SIGHUP = 1
    SIG_IGN = object()

    @staticmethod
    def signal(_number, _handler):
        return None


class ReleaseHostFaultTests(unittest.TestCase):
    def test_dead_old_gateway_routes_to_shadow_until_original_is_verified(self):
        namespace = load_namespace()
        with tempfile.TemporaryDirectory() as raw:
            folder = Path(raw)
            live = folder / "live.mjs"
            live.write_bytes(OLD_SOURCE)
            backup = folder / "backup"
            backup.mkdir()
            (backup / "gateway.mjs").write_bytes(OLD_SOURCE)
            release = folder / "release"
            release.mkdir()
            (release / "gateway.mjs").write_bytes(NEW_SOURCE)
            caddy = folder / "Caddyfile"
            old_caddy = b"old-caddy"
            shadow_caddy = b"shadow-caddy"
            caddy.write_bytes(old_caddy)
            staged = {
                "sourceSha256": hashlib.sha256(NEW_SOURCE).hexdigest(),
                "protectedPids": {"caddy": "1", "quickreadListeners": ["2"]},
            }
            events = []
            state = {"mainReady": False}

            def gateway_identity(_name, port, _path, sha256):
                if port == 7778 and not state["mainReady"]:
                    raise RuntimeError("old owner is dead")
                events.append(("verify", port, sha256))
                return {"MainPID": "10" if port == 7778 else "20"}

            def reload_caddy(before, after):
                self.assertEqual(caddy.read_bytes(), before)
                events.append(("route", after))
                caddy.write_bytes(after)

            def run(*args):
                events.append(("run", args))
                if args[:2] == ("systemctl", "restart"):
                    state["mainReady"] = True
                if args[:2] == ("systemctl", "is-active"):
                    return "active\n"
                return ""

            namespace.update(
                root=folder,
                live=live,
                backup=backup,
                release=release,
                caddy=caddy,
                expected={"files": [{"sha256": hashlib.sha256(OLD_SOURCE).hexdigest()}]},
                new_source=NEW_SOURCE,
                shadow_name="shadow.service",
                gateway_identity=gateway_identity,
                reload_caddy=reload_caddy,
                healthy=lambda _port: False,
                drain=lambda port: events.append(("drain", port)),
                run=run,
                wait_health=lambda _port: None,
                caddy_ready=lambda _raw: None,
                protected_pids=lambda: staged["protectedPids"],
            )
            restored = namespace["restore_original"](
                old_caddy, shadow_caddy, staged, False
            )

            self.assertEqual(restored["MainPID"], "10")
            route_shadow = events.index(("route", shadow_caddy))
            restart = next(
                index
                for index, event in enumerate(events)
                if event[0] == "run" and event[1][:2] == ("systemctl", "restart")
            )
            route_old = events.index(("route", old_caddy))
            disable = next(
                index
                for index, event in enumerate(events)
                if event[0] == "run"
                and event[1][:3] == ("systemctl", "disable", "--now")
            )
            self.assertLess(route_shadow, restart)
            self.assertLess(restart, route_old)
            self.assertLess(route_old, disable)
            self.assertEqual(caddy.read_bytes(), old_caddy)

    def test_independent_caddy_change_is_not_overwritten_and_shadow_is_not_stopped(self):
        namespace = load_namespace()
        with tempfile.TemporaryDirectory() as raw:
            folder = Path(raw)
            caddy = folder / "Caddyfile"
            caddy.write_bytes(b"independent-caddy")
            namespace.update(caddy=caddy)
            with self.assertRaisesRegex(RuntimeError, "independently"):
                namespace["restore_original"](
                    b"old-caddy",
                    b"shadow-caddy",
                    {"sourceSha256": "x", "protectedPids": {}},
                    False,
                )

    def exercise_apply_fault(self, kind):
        namespace = load_namespace()
        with tempfile.TemporaryDirectory() as raw:
            folder = Path(raw)
            backup = folder / "backup"
            backup.mkdir()
            release = folder / "release"
            release.mkdir()
            live = folder / "live.mjs"
            live.write_bytes(OLD_SOURCE)
            shadow_unit = folder / "shadow.unit"
            shadow_unit.write_bytes(b"unit")
            caddy = folder / "Caddyfile"
            old_caddy = (
                b"reverse_proxy 127.0.0.1:7778\n"
                b"reverse_proxy 127.0.0.1:7778\n"
            )
            shadow_caddy = old_caddy.replace(
                b"127.0.0.1:7778", b"127.0.0.1:17778"
            )
            caddy.write_bytes(old_caddy)
            (backup / "Caddyfile").write_bytes(old_caddy)
            staged = {
                "sourceSha256": hashlib.sha256(NEW_SOURCE).hexdigest(),
                "shadowPid": "20",
                "shadowUnitSha256": hashlib.sha256(b"unit").hexdigest(),
                "protectedPids": {"caddy": "1", "quickreadListeners": ["2"]},
                "privateBackupBytes": 1,
                "privateBackupSha256": "x",
            }
            (backup / "stage.json").write_text(json.dumps(staged))
            (release / "gateway.mjs").write_bytes(NEW_SOURCE)
            events = []
            stored = []

            def reload_caddy(before, after):
                self.assertEqual(caddy.read_bytes(), before)
                caddy.write_bytes(after)
                events.append(("route", after))

            def persist(name, data):
                stored.append(name)
                if kind == "persist" and name == "production.json":
                    raise OSError("injected production receipt failure")
                (backup / name).write_text(json.dumps(data))

            def drain(port):
                events.append(("drain", port))
                if kind == "cleanup" and port == 17778:
                    raise RuntimeError("injected shadow cleanup failure")

            def restore(*_args):
                events.append(("restore",))
                return {"MainPID": "30"}

            namespace.update(
                backup=backup,
                release=release,
                live=live,
                shadow_unit=shadow_unit,
                caddy=caddy,
                expected={"files": [{"sha256": hashlib.sha256(OLD_SOURCE).hexdigest()}]},
                new_source=NEW_SOURCE,
                shadow_name="shadow.service",
                signal=FakeSignal,
                check_baseline=lambda: None,
                check_offhost_backup=lambda _staged: {"verified": True},
                pid=lambda _name: "20",
                protected_pids=lambda: staged["protectedPids"],
                reload_caddy=reload_caddy,
                drain=drain,
                run=lambda *_args: "active\n",
                wait_health=lambda _port: None,
                probe=lambda _port, _label: {"ok": True},
                verify_production=lambda _sha, _raw: {"MainPID": "30"},
                persist=persist,
                restore_original=restore,
                now=lambda: "fixed",
            )
            with redirect_stdout(io.StringIO()):
                with self.assertRaises(BaseException):
                    namespace["exercise_apply"]()
            return {
                "events": events,
                "stored": stored,
                "production": (backup / "production.json").exists(),
                "cleanupFailure": (backup / "cleanup-failure.json").exists(),
            }

    def test_production_receipt_failure_rolls_back_before_commit(self):
        result = self.exercise_apply_fault("persist")
        self.assertIn(("restore",), result["events"])
        self.assertFalse(result["production"])
        self.assertIn("failure.json", result["stored"])

    def test_postcommit_cleanup_failure_does_not_roll_back_verified_production(self):
        result = self.exercise_apply_fault("cleanup")
        self.assertNotIn(("restore",), result["events"])
        self.assertTrue(result["production"])
        self.assertTrue(result["cleanupFailure"])

    def test_caddy_dial_parser_binds_only_the_selected_host(self):
        namespace = load_namespace()
        config = {
            "routes": [
                {
                    "match": [{"host": ["tts.castreader.ai"]}],
                    "handle": [{"upstreams": [{"dial": "127.0.0.1:7778"}]}],
                },
                {
                    "match": [{"host": ["other.example"]}],
                    "handle": [{"upstreams": [{"dial": "127.0.0.1:9999"}]}],
                },
            ]
        }
        self.assertEqual(
            namespace["caddy_dials"](config, "tts.castreader.ai"),
            ["127.0.0.1:7778"],
        )


if __name__ == "__main__":
    unittest.main()
