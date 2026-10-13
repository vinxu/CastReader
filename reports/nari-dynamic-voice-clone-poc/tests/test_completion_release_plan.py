"""Read-only deployment plan guards; no network, GPU, install, or production writes."""

import importlib.util
import json
import tempfile
import tarfile
import hashlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("completion_release_plan", ROOT / "deploy/completion-release-plan.py")
PLAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLAN)


class CompletionReleasePlanTests(unittest.TestCase):
    def test_both_regions_are_isolated_and_remain_unapproved(self):
        for region in ["us", "cn"]:
            with self.subTest(region=region):
                plan = PLAN.build_plan(ROOT, region, "clone-eos-1236-candidate")
                self.assertFalse(plan["production_mutation_allowed"])
                protected = plan["protected"]
                worker = plan["worker"]
                nari = plan["nari"]
                self.assertNotEqual(worker["argv"][worker["argv"].index("--port") + 1], str(protected["worker_port"]))
                self.assertNotEqual(nari["argv"][nari["argv"].index("--port") + 1], str(protected["nari_port"]))
                env = worker["environment"]
                self.assertNotIn(protected["prompt_root"], json.dumps(env))
                self.assertTrue(env["CLONE_DATA_ROOT"].startswith(plan["state_root"]))
                self.assertEqual(env["NARI_VOICE_PROMPT_ROOT"], nari["environment"]["NARI_VOICE_PROMPT_ROOT"])
                self.assertIn(plan["release_root"] + "/nari-qwen3-tts/src", env["PYTHONPATH"])
                self.assertNotIn("__pycache__", json.dumps(plan["source_files_sha256"]))
                self.assertEqual(len(plan["source_tree_sha256"]), 64)

    def test_source_manifest_is_complete_and_reproducible(self):
        one = PLAN.build_plan(ROOT, "us", "clone-eos-1236-candidate")
        two = PLAN.build_plan(ROOT, "cn", "clone-eos-1236-candidate")
        self.assertEqual(one["source_tree_sha256"], two["source_tree_sha256"])
        self.assertGreater(len(one["source_files_sha256"]), 50)

    def test_missing_source_tree_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                PLAN.build_plan(Path(temp), "us", "clone-eos-1236-candidate")

    def test_path_escape_and_unknown_region_rejected(self):
        for value in ["../current", "/workspace", "latest;restart", "", "a b", "x" * 100]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                PLAN.build_plan(ROOT, "us", value)
        with self.assertRaises(ValueError):
            PLAN.build_plan(ROOT, "unknown", "clone-eos-1236-candidate")

    def test_local_archive_binds_both_regions_without_private_runtime_assets(self):
        plans = [PLAN.build_plan(ROOT, region, "clone-eos-1236-candidate") for region in ["us", "cn"]]
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "candidate.tar.gz"
            receipt = PLAN.package_candidate(ROOT, plans, target)
            self.assertFalse(receipt["production_mutation_allowed"])
            self.assertEqual(receipt["sha256"], hashlib.sha256(target.read_bytes()).hexdigest())
            with tarfile.open(target) as archive:
                manifest = json.load(archive.extractfile("clone-completion-manifest.json"))
                self.assertFalse(manifest["models_dependencies_secrets_and_private_prompts_included"])
                self.assertEqual({p["region"] for p in manifest["plans"]}, {"us", "cn"})
                for name, expected in manifest["files_sha256"].items():
                    self.assertEqual(hashlib.sha256(archive.extractfile(name).read()).hexdigest(), expected)
                    self.assertNotIn(".api-token", name)
                    self.assertNotIn("prompt.pt", name)
            with self.assertRaises(FileExistsError):
                PLAN.package_candidate(ROOT, plans, target)


if __name__ == "__main__":
    unittest.main()
