from __future__ import annotations

import importlib.util
import json
import stat
import sys
import types
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
WORKER_ROOT = ROOT / "worker"
if str(WORKER_ROOT) not in sys.path:
    sys.path.insert(0, str(WORKER_ROOT))

import xvector_activation


SOURCE_COMMIT = "a" * 40


class XVectorActivationTests(unittest.TestCase):
    def _layout(self, root: Path) -> dict[str, Path]:
        worker_root = root / "worker"
        nari_root = root / "nari_qwen3_tts"
        releases = root / "releases"
        worker_root.mkdir(parents=True)
        nari_root.mkdir()
        releases.mkdir()
        paths = {
            "worker": worker_root / "clone_worker.py",
            "builder": worker_root / "build_prompt.py",
            "activation_validator": worker_root / "xvector_activation.py",
            "reader": nari_root / "model" / "text.py",
            "releases": releases,
            "record": releases / "fast-hotpath-20260830T000000Z.json",
            "marker": root / "clone" / ".xvector-writer-v1-enabled",
        }
        paths["reader"].parent.mkdir()
        paths["worker"].write_text("worker-v1\n", encoding="utf-8")
        paths["builder"].write_text("builder-v1\n", encoding="utf-8")
        paths["activation_validator"].write_text(
            "activation-validator-v1\n", encoding="utf-8"
        )
        paths["reader"].write_text("reader-v1\n", encoding="utf-8")
        record = {
            "source_commit": SOURCE_COMMIT,
            "hotpath": "nari-x-vector-only",
            "writer_activation": "requires-bound-release-marker-v1",
            "worker_sha256": {
                "clone_worker.py": xvector_activation.sha256_file(paths["worker"]),
                "build_prompt.py": xvector_activation.sha256_file(paths["builder"]),
                "xvector_activation.py": xvector_activation.sha256_file(
                    paths["activation_validator"]
                ),
            },
            "nari_sha256": {
                "model/text.py": xvector_activation.sha256_file(paths["reader"])
            },
        }
        paths["record"].write_text(json.dumps(record), encoding="utf-8")
        return paths

    @staticmethod
    def _schema_probe() -> dict[str, object]:
        return {
            "schema": xvector_activation.PROMPT_SCHEMA,
            "embedding_size": 1024,
            "storage": "temporary-only",
        }

    def _activate(self, paths: dict[str, Path]) -> dict[str, object]:
        return xvector_activation.activate_xvector_writer(
            marker=paths["marker"],
            source_commit=SOURCE_COMMIT,
            release_record=paths["record"],
            releases_dir=paths["releases"],
            worker=paths["worker"],
            builder=paths["builder"],
            activation_validator=paths["activation_validator"],
            reader=paths["reader"],
            schema_probe=self._schema_probe,
        )

    def test_activation_binds_marker_to_current_release_and_never_creates_voice(self) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            paths = self._layout(root)
            production_voice_root = root / "voices"

            payload = self._activate(paths)

            self.assertFalse(production_voice_root.exists())
            self.assertEqual(payload["source_commit"], SOURCE_COMMIT)
            self.assertEqual(payload["release_record"], str(paths["record"].resolve()))
            self.assertEqual(payload["dry_run"]["storage"], "temporary-only")
            self.assertEqual(
                stat.S_IMODE(paths["marker"].stat().st_mode),
                0o600,
            )
            self.assertTrue(
                xvector_activation.marker_matches_current_release(
                    paths["marker"],
                    worker=paths["worker"],
                    builder=paths["builder"],
                    activation_validator=paths["activation_validator"],
                )
            )

    def test_marker_fails_closed_after_builder_or_release_record_changes(self) -> None:
        with TemporaryDirectory() as directory:
            paths = self._layout(Path(directory))
            self._activate(paths)

            paths["builder"].write_text("builder-v2\n", encoding="utf-8")
            self.assertFalse(
                xvector_activation.marker_matches_current_release(
                    paths["marker"],
                    worker=paths["worker"],
                    builder=paths["builder"],
                    activation_validator=paths["activation_validator"],
                )
            )

            paths = self._layout(Path(directory) / "third")
            self._activate(paths)
            marker = json.loads(paths["marker"].read_text(encoding="utf-8"))
            marker["dry_run"]["embedding_size"] = 1
            paths["marker"].write_text(json.dumps(marker), encoding="utf-8")
            self.assertFalse(
                xvector_activation.marker_matches_current_release(
                    paths["marker"],
                    worker=paths["worker"],
                    builder=paths["builder"],
                    activation_validator=paths["activation_validator"],
                )
            )

            paths = self._layout(Path(directory) / "second")
            self._activate(paths)
            with paths["record"].open("a", encoding="utf-8") as handle:
                handle.write("\n")
            self.assertFalse(
                xvector_activation.marker_matches_current_release(
                    paths["marker"],
                    worker=paths["worker"],
                    builder=paths["builder"],
                    activation_validator=paths["activation_validator"],
                )
            )

    def test_invalid_release_or_schema_probe_never_writes_marker(self) -> None:
        with TemporaryDirectory() as directory:
            paths = self._layout(Path(directory))
            paths["builder"].write_text("unreleased-builder\n", encoding="utf-8")
            with self.assertRaises(xvector_activation.ActivationError):
                self._activate(paths)
            self.assertFalse(paths["marker"].exists())

        with TemporaryDirectory() as directory:
            paths = self._layout(Path(directory))
            record = json.loads(paths["record"].read_text(encoding="utf-8"))
            record["source_commit"] = "b" * 40
            paths["record"].write_text(json.dumps(record), encoding="utf-8")
            with self.assertRaises(xvector_activation.ActivationError):
                self._activate(paths)
            self.assertFalse(paths["marker"].exists())

        with TemporaryDirectory() as directory:
            paths = self._layout(Path(directory))
            with self.assertRaises(xvector_activation.ActivationError):
                xvector_activation.activate_xvector_writer(
                    marker=paths["marker"],
                    source_commit=SOURCE_COMMIT,
                    release_record=paths["record"],
                    releases_dir=paths["releases"],
                    worker=paths["worker"],
                    builder=paths["builder"],
                    activation_validator=paths["activation_validator"],
                    reader=paths["reader"],
                    schema_probe=lambda: {
                        "schema": "legacy-icl",
                        "embedding_size": 1024,
                        "storage": "temporary-only",
                    },
                )
            self.assertFalse(paths["marker"].exists())

    def test_legacy_plain_sha_marker_is_never_an_activation(self) -> None:
        with TemporaryDirectory() as directory:
            paths = self._layout(Path(directory))
            paths["marker"].parent.mkdir()
            paths["marker"].write_text(SOURCE_COMMIT + "\n", encoding="utf-8")
            self.assertFalse(
                xvector_activation.marker_matches_current_release(
                    paths["marker"],
                    worker=paths["worker"],
                    builder=paths["builder"],
                    activation_validator=paths["activation_validator"],
                )
            )

    def test_build_prompt_dry_run_round_trips_only_in_temporary_storage(self) -> None:
        class FakeTensor:
            def __init__(self, size: int, dtype: object) -> None:
                self._size = size
                self.dtype = dtype
                self.ndim = 1

            def detach(self):
                return self

            def cpu(self):
                return self

            def to(self, dtype):
                self.dtype = dtype
                return self

            def numel(self) -> int:
                return self._size

            def contiguous(self):
                return self

        class FakeTruth:
            def all(self):
                return self

            @staticmethod
            def item() -> bool:
                return True

        fake_torch = types.ModuleType("torch")
        fake_torch.float32 = object()
        fake_torch.Tensor = FakeTensor
        fake_torch.zeros = lambda size, dtype: FakeTensor(size, dtype)
        fake_torch.isfinite = lambda _tensor: FakeTruth()
        fake_torch.inference_mode = lambda: (lambda function: function)
        saved: dict[str, object] = {}

        def save(value, destination) -> None:
            path = Path(destination)
            path.write_bytes(b"temporary-schema-probe")
            saved[str(path)] = value

        def load(source, **_kwargs):
            return saved[str(Path(source))]

        fake_torch.save = save
        fake_torch.load = load
        fake_qwen = types.ModuleType("qwen_tts")
        fake_qwen.Qwen3TTSModel = type("FakeQwen3TTSModel", (), {})
        module_name = "build_prompt_activation_contract_test"
        spec = importlib.util.spec_from_file_location(
            module_name,
            WORKER_ROOT / "build_prompt.py",
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(
            sys.modules,
            {
                "torch": fake_torch,
                "qwen_tts": fake_qwen,
                module_name: module,
            },
        ):
            spec.loader.exec_module(module)
            result = module.dry_run_xvector_prompt_schema()

        self.assertEqual(result, xvector_activation.EXPECTED_DRY_RUN)
        self.assertTrue(saved)
        self.assertTrue(all("castreader-xvector-schema-" in path for path in saved))

    def test_us_and_cn_activation_scripts_enforce_the_same_contract(self) -> None:
        required_fragments = (
            'release_record="${2:?pass the fast-hotpath release record path}"',
            'incoming}/worker/build_prompt.py',
            'incoming}/worker/xvector_activation.py',
            '--source-commit "${source_commit}"',
            '--release-record "${release_record}"',
            '--releases-dir',
            '--builder "${builder}"',
            '--activation-validator "${activation_validator}"',
            '--reader "${reader}"',
        )
        for region in ("us", "cn"):
            with self.subTest(region=region):
                source = (
                    ROOT / "deploy" / region / "activate-xvector-writer.sh"
                ).read_text(encoding="utf-8")
                for fragment in required_fragments:
                    self.assertIn(fragment, source)
                self.assertLess(
                    source.index("trap rollback ERR"),
                    source.index('  --marker "${marker}"'),
                )
                deploy_source = (
                    ROOT / "deploy" / region / "deploy-fast-clone-hotpath.sh"
                ).read_text(encoding="utf-8")
                self.assertIn("xvector_activation.py", deploy_source)
                self.assertIn('${name}.absent', deploy_source)
                self.assertIn(
                    'chown --reference="$(dirname "${destination_file}")"',
                    deploy_source,
                )
                self.assertIn('chmod 0644 "${destination_file}.next"', deploy_source)
                self.assertIn(
                    '"writer_activation": "requires-bound-release-marker-v1"',
                    deploy_source,
                )


if __name__ == "__main__":
    unittest.main()
