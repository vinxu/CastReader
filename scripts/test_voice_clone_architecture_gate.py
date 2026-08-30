#!/usr/bin/env python3

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import voice_clone_architecture_gate as gate


class SensitivePathTests(unittest.TestCase):
    def test_covers_runtime_routing_identity_playback_and_worker_paths(self) -> None:
        sensitive = (
            "CastReader/Services/VoiceCloneService.swift",
            "CastReader/Models/TTSTimestamp.swift",
            "CastReader/Models/PhoneAuthModels.swift",
            "CastReader/Services/AppRegion.swift",
            "CastReader/Services/AudioPlayerService.swift",
            "CastReader/Services/KeychainStore.swift",
            "CastReader/Services/MobileSessionService.swift",
            "CastReader/Services/ProBackendService.swift",
            "CastReader/Utils/Constants.swift",
            "CastReader/ViewModels/ReadAloudViewModel.swift",
            "CastReader/Localizable.xcstrings",
            "CastReader/Views/Settings/VoiceBrowserView.swift",
            "CastReaderTests/ServiceRoutingTests.swift",
            "reports/nari-dynamic-voice-clone-poc/worker/clone_worker.py",
            ".github/workflows/voice-clone-architecture-gate.yml",
            ".github/CODEOWNERS",
            "docs/contracts/voice-clone-architecture.lock.json",
        )
        for path in sensitive:
            with self.subTest(path=path):
                self.assertTrue(gate.is_sensitive_path(path))

    def test_unrelated_product_file_does_not_trigger_expensive_jobs(self) -> None:
        self.assertFalse(gate.is_sensitive_path("docs/aso/unrelated-campaign.md"))


class TrailerTests(unittest.TestCase):
    def test_accepts_one_exact_trailer_in_the_final_trailer_block(self) -> None:
        gate.validate_trailer_message(
            "Subject\n\nReason.\n\n"
            "Voice-Clone-Architecture-Reviewed: voice-clone-system-v1\n",
            commit="test-commit",
        )

    def test_rejects_missing_wrong_case_wrong_value_and_duplicate_trailers(self) -> None:
        invalid_messages = (
            "Subject only\n",
            "Subject\n\nvoice-clone-architecture-reviewed: voice-clone-system-v1\n",
            "Subject\n\nVoice-Clone-Architecture-Reviewed: voice-clone-system-v2\n",
            "Subject\n\n"
            "Voice-Clone-Architecture-Reviewed: voice-clone-system-v1\n"
            "Voice-Clone-Architecture-Reviewed: voice-clone-system-v1\n",
            "Subject\n\n"
            "Voice-Clone-Architecture-Reviewed: voice-clone-system-v1\n"
            "voice-clone-architecture-reviewed: voice-clone-system-v1\n",
        )
        for message in invalid_messages:
            with self.subTest(message=message):
                with self.assertRaises(gate.GateError):
                    gate.validate_trailer_message(message, commit="test-commit")


class WorkflowTests(unittest.TestCase):
    def test_missing_gate_classification_fails_closed(self) -> None:
        source = Path(
            ".github/workflows/voice-clone-architecture-gate.yml"
        ).read_text(encoding="utf-8")
        self.assertIn('case "$SENSITIVE" in', source)
        self.assertIn("true|false)", source)
        self.assertIn(
            "voice-clone architecture gate did not emit sensitive=true|false",
            source,
        )


class MergeTrailerIntegrationTests(unittest.TestCase):
    """Exercise merge exceptions against real commit graphs and Git trees."""

    def setUp(self) -> None:
        self.original_cwd = Path.cwd()
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary_directory.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Voice Clone Gate Tests")
        self.git("config", "user.email", "voice-clone-gate@example.invalid")
        os.chdir(self.repository)
        self.write("CastReader/Services/VoiceCloneService.swift", "initial\n")
        self.write("CastReader/Services/KeychainStore.swift", "initial\n")
        self.write("docs/unrelated.md", "initial\n")
        self.initial_commit = self.commit("Initial state")

    def tearDown(self) -> None:
        os.chdir(self.original_cwd)
        self.temporary_directory.cleanup()

    def git(
        self,
        *arguments: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", *arguments],
            cwd=self.repository,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(
                f"git {' '.join(arguments)} failed ({result.returncode}): "
                f"{result.stderr.strip()}"
            )
        return result

    def write(self, relative_path: str, content: str) -> None:
        path = self.repository / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, subject: str, *, reviewed: bool = False) -> str:
        self.git("add", "-A")
        message = subject
        if reviewed:
            message += (
                "\n\nVoice-Clone-Architecture-Reviewed: "
                "voice-clone-system-v1"
            )
        self.git("commit", "-m", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def checkout(self, branch: str, *, create: bool = False) -> None:
        arguments = ["checkout"]
        if create:
            arguments.append("-b")
        arguments.append(branch)
        self.git(*arguments)

    def make_reviewed_feature_commit(self) -> str:
        self.checkout("feature", create=True)
        self.write(
            "CastReader/Services/VoiceCloneService.swift",
            "reviewed feature\n",
        )
        return self.commit("Update clone contract", reviewed=True)

    def test_only_exact_synthetic_head_is_skipped(self) -> None:
        feature_commit = self.make_reviewed_feature_commit()
        self.checkout("main")
        self.write("docs/unrelated.md", "new base\n")
        base_commit = self.commit("Advance base")
        self.git("merge", "--no-ff", "feature", "-m", "Synthetic merge head")
        synthetic_head = self.git("rev-parse", "HEAD").stdout.strip()

        self.assertEqual(
            gate.verify_sensitive_commit_trailers(
                base_commit,
                synthetic_head,
                synthetic_head=synthetic_head,
            ),
            [feature_commit],
        )

        with self.assertRaisesRegex(
            gate.GateError,
            "synthetic merge-group head must equal the compared head",
        ):
            gate.verify_sensitive_commit_trailers(
                base_commit,
                synthetic_head,
                synthetic_head=feature_commit,
            )

    def test_synthetic_head_does_not_hide_unreviewed_authored_commit(self) -> None:
        self.checkout("feature", create=True)
        self.write(
            "CastReader/Services/VoiceCloneService.swift",
            "unreviewed feature\n",
        )
        self.commit("Unreviewed clone contract")
        self.checkout("main")
        self.write("docs/unrelated.md", "new base\n")
        base_commit = self.commit("Advance base")
        self.git("merge", "--no-ff", "feature", "-m", "Synthetic merge head")
        synthetic_head = self.git("rev-parse", "HEAD").stdout.strip()

        with self.assertRaisesRegex(gate.GateError, "must contain exactly one trailer"):
            gate.verify_sensitive_commit_trailers(
                base_commit,
                synthetic_head,
                synthetic_head=synthetic_head,
            )

    def test_deterministic_conflict_free_base_sync_is_skipped(self) -> None:
        feature_commit = self.make_reviewed_feature_commit()
        self.checkout("main")
        self.write("CastReader/Services/KeychainStore.swift", "new base auth\n")
        base_commit = self.commit("Advance base auth")
        self.checkout("feature")
        self.git("merge", "--no-ff", "main", "-m", "Sync base")
        merge_commit = self.git("rev-parse", "HEAD").stdout.strip()
        parents = gate._commit_parents(merge_commit)

        self.assertTrue(
            gate._is_deterministic_base_sync_merge(
                merge_commit,
                parents,
                base_commit,
            )
        )
        self.assertEqual(
            gate.verify_sensitive_commit_trailers(base_commit, merge_commit),
            [feature_commit],
        )

    def test_manually_changed_merge_tree_is_not_skipped(self) -> None:
        self.make_reviewed_feature_commit()
        self.checkout("main")
        self.write("CastReader/Services/KeychainStore.swift", "new base auth\n")
        base_commit = self.commit("Advance base auth")
        self.checkout("feature")
        self.git("merge", "--no-ff", "--no-commit", "main")
        self.write(
            "CastReader/Services/KeychainStore.swift",
            "new base auth with manual merge edit\n",
        )
        merge_commit = self.commit("Manually adjusted base sync")
        parents = gate._commit_parents(merge_commit)

        self.assertFalse(
            gate._is_deterministic_base_sync_merge(
                merge_commit,
                parents,
                base_commit,
            )
        )
        with self.assertRaisesRegex(gate.GateError, "must contain exactly one trailer"):
            gate.verify_sensitive_commit_trailers(base_commit, merge_commit)

    def test_conflict_resolved_merge_tree_is_not_skipped(self) -> None:
        self.checkout("feature", create=True)
        self.write("CastReader/Services/VoiceCloneService.swift", "feature version\n")
        self.commit("Update clone contract", reviewed=True)
        self.checkout("main")
        self.write("CastReader/Services/VoiceCloneService.swift", "base version\n")
        base_commit = self.commit("Advance base clone contract")
        self.checkout("feature")
        merge_result = self.git("merge", "--no-ff", "main", check=False)
        self.assertNotEqual(merge_result.returncode, 0)
        self.write(
            "CastReader/Services/VoiceCloneService.swift",
            "manually resolved version\n",
        )
        merge_commit = self.commit("Resolve base sync conflict")
        parents = gate._commit_parents(merge_commit)

        self.assertFalse(
            gate._is_deterministic_base_sync_merge(
                merge_commit,
                parents,
                base_commit,
            )
        )
        with self.assertRaisesRegex(gate.GateError, "must contain exactly one trailer"):
            gate.verify_sensitive_commit_trailers(base_commit, merge_commit)


class LockTests(unittest.TestCase):
    @staticmethod
    def payload(*, status: str, commit: str | None, digest: str | None):
        return {
            "lockVersion": 1,
            "architectureId": "voice-clone-system-v1",
            "status": status,
            "source": {
                "repository": "https://github.com/scmyyan/readout-web",
                "branch": "beta",
                "documentPath": "docs/voice-clone-system-architecture.md",
                "backendCommit": commit,
                "documentSha256": digest,
            },
        }

    def test_pending_lock_is_explicit_and_can_be_made_required(self) -> None:
        payload = self.payload(status="pending", commit=None, digest=None)
        self.assertEqual(gate.validate_lock_payload(payload), "pending")
        with self.assertRaises(gate.GateError):
            gate.validate_lock_payload(payload, require_pinned=True)

    def test_pinned_lock_requires_exact_commit_and_digest_shapes(self) -> None:
        payload = self.payload(status="pinned", commit="a" * 40, digest="b" * 64)
        self.assertEqual(gate.validate_lock_payload(payload), "pinned")

        payload["source"]["documentSha256"] = "B" * 64
        with self.assertRaises(gate.GateError):
            gate.validate_lock_payload(payload)

    def test_partial_pending_lock_is_rejected(self) -> None:
        payload = self.payload(status="pending", commit="a" * 40, digest=None)
        with self.assertRaises(gate.GateError):
            gate.validate_lock_payload(payload)


if __name__ == "__main__":
    unittest.main()
