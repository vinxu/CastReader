#!/usr/bin/env python3
"""Voice-clone architecture guard for the iOS and GPU Worker repository.

The GitHub workflow runs for every pull request and merge group.  This script
decides whether the diff touches the voice-clone contract, validates the exact
review trailer on each authored sensitive commit, and validates the pinned
control-plane architecture lock.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable, Sequence


ARCHITECTURE_ID = "voice-clone-system-v1"
TRAILER_KEY = "Voice-Clone-Architecture-Reviewed"
LOCK_PATH = Path("docs/contracts/voice-clone-architecture.lock.json")
PENDING_LOCK_STATUS = "pending"
PINNED_LOCK_STATUS = "pinned"

# Keep this list intentionally broader than the currently named VoiceClone
# files.  Routing, session ownership, TTS wire models, playback orchestration,
# quota and project membership can all break clone creation or consumption.
SENSITIVE_PATH_PATTERNS: tuple[str, ...] = (
    "AGENTS.md",
    "CLAUDE.md",
    ".github/CODEOWNERS",
    ".github/workflows/voice-clone-architecture-gate.yml",
    "docs/contracts/voice-clone-architecture.lock.json",
    "scripts/voice_clone_architecture_gate.py",
    "scripts/test_voice_clone_architecture_gate.py",
    "CastReader.xcodeproj/project.pbxproj",
    "CastReader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "CastReader.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "CastReader/CastReaderApp.swift",
    "CastReader/Localizable.xcstrings",
    "CastReader/Models/AppSettings.swift",
    "CastReader/Models/PhoneAuthModels.swift",
    "CastReader/Models/TTSTimestamp.swift",
    "CastReader/Models/UserAccount.swift",
    "CastReader/Models/Voice*.swift",
    "CastReader/Services/APIService.swift",
    "CastReader/Services/AppRegion.swift",
    "CastReader/Services/AudioPlayerService.swift",
    "CastReader/Services/AuthService*.swift",
    "CastReader/Services/KeychainStore.swift",
    "CastReader/Services/MobileSessionService.swift",
    "CastReader/Services/OwnedAPINetworking.swift",
    "CastReader/Services/PhoneAuthService.swift",
    "CastReader/Services/ProBackendService.swift",
    "CastReader/Services/ProManager.swift",
    "CastReader/Services/QuotaManager.swift",
    "CastReader/Services/ServiceRouting.swift",
    "CastReader/Services/TTSEndpoint.swift",
    "CastReader/Services/TTSService.swift",
    "CastReader/Services/Voice*.swift",
    "CastReader/Utils/Constants.swift",
    "CastReader/ViewModels/ExplainViewModel.swift",
    "CastReader/ViewModels/ReadAloudViewModel.swift",
    "CastReader/Views/Home/HomeView.swift",
    "CastReader/Views/MainTabView.swift",
    "CastReader/Views/**/Voice*.swift",
    "CastReaderTests/AppRegionTests.swift",
    "CastReaderTests/ServiceRoutingTests.swift",
    "CastReaderTests/*Voice*.swift",
    "reports/nari-dynamic-voice-clone-poc/**",
)


class GateError(RuntimeError):
    """A contract violation that should fail the architecture gate."""


def is_sensitive_path(path: str) -> bool:
    normalized = path.removeprefix("./")
    return any(
        fnmatch.fnmatchcase(normalized, pattern)
        for pattern in SENSITIVE_PATH_PATTERNS
    )


def _run_git(
    arguments: Sequence[str],
    *,
    input_text: str | None = None,
    binary: bool = False,
) -> str | bytes:
    result = subprocess.run(
        ["git", *arguments],
        input=None if input_text is None else input_text.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise GateError(f"git {' '.join(arguments)} failed: {stderr}")
    if binary:
        return result.stdout
    return result.stdout.decode("utf-8", errors="strict")


def _resolve_commit(revision: str) -> str:
    resolved = str(_run_git(["rev-parse", "--verify", f"{revision}^{{commit}}"]))
    return resolved.strip()


def _merge_base(base: str, head: str) -> str:
    return str(_run_git(["merge-base", base, head])).strip()


def _nul_paths(arguments: Sequence[str]) -> list[str]:
    output = bytes(_run_git([*arguments, "-z"], binary=True))
    return [part.decode("utf-8", errors="strict") for part in output.split(b"\0") if part]


def changed_paths(base: str, head: str) -> tuple[str, list[str]]:
    base_sha = _resolve_commit(base)
    head_sha = _resolve_commit(head)
    common = _merge_base(base_sha, head_sha)
    paths = _nul_paths(
        [
            "diff",
            "--no-renames",
            "--name-only",
            "--diff-filter=ACMRDTUXB",
            f"{common}...{head_sha}",
        ]
    )
    return common, paths


def _commit_parents(commit: str) -> list[str]:
    line = str(_run_git(["rev-list", "--parents", "-n", "1", commit])).strip()
    return line.split()[1:]


def _commit_paths(commit: str) -> list[str]:
    parents = _commit_parents(commit)
    if not parents:
        return _nul_paths(
            [
                "diff-tree",
                "--root",
                "--no-renames",
                "--no-commit-id",
                "--name-only",
                "-r",
                commit,
            ]
        )
    # For an authored merge commit, compare with its first parent. This makes a
    # merge that introduces sensitive files carry the same acknowledgement as
    # a normal commit.
    return _nul_paths(
        [
            "diff",
            "--no-renames",
            "--name-only",
            "--diff-filter=ACMRDTUXB",
            parents[0],
            commit,
        ]
    )


def _is_ancestor(ancestor: str, descendant: str) -> bool:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def _is_deterministic_base_sync_merge(
    commit: str,
    parents: Sequence[str],
    base: str,
) -> bool:
    if len(parents) != 2 or not _is_ancestor(parents[1], base):
        return False
    result = subprocess.run(
        ["git", "merge-tree", "--write-tree", parents[0], parents[1]],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        # Conflicted or manually resolved base updates can alter the contract,
        # so they must carry the same acknowledgement as any authored change.
        return False
    merged_tree = result.stdout.splitlines()[0].strip() if result.stdout else ""
    if re.fullmatch(r"[0-9a-f]{40}", merged_tree) is None:
        return False
    actual_tree = str(_run_git(["show", "-s", "--format=%T", commit])).strip()
    return merged_tree == actual_tree


def parsed_trailers(message: str) -> list[tuple[str, str]]:
    output = str(
        _run_git(
            ["interpret-trailers", "--parse"],
            input_text=message,
        )
    )
    parsed: list[tuple[str, str]] = []
    for line in output.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        parsed.append((key.strip(), value.strip()))
    return parsed


def validate_trailer_message(message: str, *, commit: str) -> None:
    candidates = [
        (key, value)
        for key, value in parsed_trailers(message)
        if key.casefold() == TRAILER_KEY.casefold()
    ]
    expected = (TRAILER_KEY, ARCHITECTURE_ID)
    if candidates != [expected]:
        rendered = ", ".join(f"{key}: {value}" for key, value in candidates)
        if not rendered:
            rendered = "missing"
        raise GateError(
            f"sensitive commit {commit} must contain exactly one trailer "
            f"'{TRAILER_KEY}: {ARCHITECTURE_ID}'; found {rendered}"
        )


def verify_sensitive_commit_trailers(
    base: str,
    head: str,
    *,
    synthetic_head: str | None = None,
) -> list[str]:
    base_sha = _resolve_commit(base)
    head_sha = _resolve_commit(head)
    common = _merge_base(base_sha, head_sha)
    synthetic_sha: str | None = None
    if synthetic_head is not None:
        if re.fullmatch(r"[0-9a-f]{40}", synthetic_head) is None:
            raise GateError("synthetic merge-group head must be a full commit SHA")
        synthetic_sha = _resolve_commit(synthetic_head)
        if synthetic_sha != head_sha:
            raise GateError("synthetic merge-group head must equal the compared head")
    commits = str(
        _run_git(["rev-list", "--reverse", "--topo-order", f"{common}..{head_sha}"])
    ).splitlines()
    sensitive_commits: list[str] = []
    skipped_commits: list[str] = []

    for commit in commits:
        parents = _commit_parents(commit)
        if commit == synthetic_sha:
            skipped_commits.append(commit)
            continue
        if _is_deterministic_base_sync_merge(commit, parents, base_sha):
            skipped_commits.append(commit)
            continue
        paths = _commit_paths(commit)
        if not any(is_sensitive_path(path) for path in paths):
            continue
        message = str(_run_git(["show", "-s", "--format=%B", commit]))
        validate_trailer_message(message, commit=commit)
        sensitive_commits.append(commit)

    if skipped_commits:
        print(
            "Skipped immutable synthetic head or deterministic base sync: "
            + ", ".join(commit[:12] for commit in skipped_commits)
        )
    return sensitive_commits


def _require_exact_keys(
    value: dict[str, Any],
    expected: set[str],
    *,
    label: str,
) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise GateError(f"{label} keys mismatch; missing={missing}, extra={extra}")


def validate_lock_payload(payload: Any, *, require_pinned: bool = False) -> str:
    if not isinstance(payload, dict):
        raise GateError("architecture lock root must be an object")
    _require_exact_keys(
        payload,
        {"lockVersion", "architectureId", "status", "source"},
        label="architecture lock",
    )
    if payload["lockVersion"] != 1:
        raise GateError("architecture lockVersion must be 1")
    if payload["architectureId"] != ARCHITECTURE_ID:
        raise GateError(
            f"architectureId must be exactly {ARCHITECTURE_ID!r}"
        )
    source = payload["source"]
    if not isinstance(source, dict):
        raise GateError("architecture lock source must be an object")
    _require_exact_keys(
        source,
        {
            "repository",
            "branch",
            "documentPath",
            "backendCommit",
            "documentSha256",
        },
        label="architecture lock source",
    )
    if source["repository"] != "https://github.com/scmyyan/readout-web":
        raise GateError("architecture lock repository is not the canonical control plane")
    if source["branch"] != "beta":
        raise GateError("architecture lock branch must be beta")
    if source["documentPath"] != "docs/voice-clone-system-architecture.md":
        raise GateError("architecture lock documentPath is not canonical")

    status = payload["status"]
    commit = source["backendCommit"]
    digest = source["documentSha256"]
    if status == PENDING_LOCK_STATUS:
        if commit is not None or digest is not None:
            raise GateError("pending architecture lock must leave both pin fields null")
        if require_pinned:
            raise GateError(
                "architecture lock is pending; fill backendCommit and documentSha256 "
                "and change status to pinned"
            )
        return PENDING_LOCK_STATUS
    if status != PINNED_LOCK_STATUS:
        raise GateError("architecture lock status must be pending or pinned")
    if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise GateError("pinned backendCommit must be 40 lowercase hexadecimal characters")
    if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise GateError("pinned documentSha256 must be 64 lowercase hexadecimal characters")
    return PINNED_LOCK_STATUS


def load_and_validate_lock(
    path: Path,
    *,
    require_pinned: bool = False,
    backend_checkout: Path | None = None,
) -> str:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise GateError(f"architecture lock is missing: {path}") from error
    except json.JSONDecodeError as error:
        raise GateError(f"architecture lock is invalid JSON: {error}") from error
    status = validate_lock_payload(payload, require_pinned=require_pinned)
    if backend_checkout is None:
        return status
    if status != PINNED_LOCK_STATUS:
        raise GateError("backend checkout verification requires a pinned lock")

    source = payload["source"]
    checkout = backend_checkout.resolve()
    result = subprocess.run(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise GateError(f"backend checkout is not a Git repository: {checkout}")
    actual_commit = result.stdout.strip()
    if actual_commit != source["backendCommit"]:
        raise GateError(
            f"backend checkout commit {actual_commit} does not match locked "
            f"commit {source['backendCommit']}"
        )
    document = checkout / source["documentPath"]
    try:
        actual_digest = hashlib.sha256(document.read_bytes()).hexdigest()
    except FileNotFoundError as error:
        raise GateError(f"locked architecture document is missing: {document}") from error
    if actual_digest != source["documentSha256"]:
        raise GateError(
            f"architecture document SHA256 {actual_digest} does not match locked "
            f"digest {source['documentSha256']}"
        )
    return status


def _write_github_output(path: str | None, values: dict[str, str]) -> None:
    if path is None:
        return
    output_path = Path(path)
    with output_path.open("a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def command_classify(arguments: argparse.Namespace) -> None:
    common, paths = changed_paths(arguments.base, arguments.head)
    sensitive = sorted(path for path in paths if is_sensitive_path(path))
    print(f"Merge base: {common}")
    print(f"Sensitive change: {'yes' if sensitive else 'no'}")
    for path in sensitive:
        print(f"  - {path}")
    _write_github_output(
        arguments.github_output,
        {
            "sensitive": "true" if sensitive else "false",
            "merge_base": common,
            "sensitive_count": str(len(sensitive)),
        },
    )


def command_trailers(arguments: argparse.Namespace) -> None:
    commits = verify_sensitive_commit_trailers(
        arguments.base,
        arguments.head,
        synthetic_head=arguments.synthetic_head,
    )
    print(
        "Validated architecture trailer on "
        f"{len(commits)} sensitive authored commit(s)."
    )


def command_lock(arguments: argparse.Namespace) -> None:
    status = load_and_validate_lock(
        Path(arguments.lock),
        require_pinned=arguments.require_pinned,
        backend_checkout=(
            Path(arguments.backend_checkout)
            if arguments.backend_checkout is not None
            else None
        ),
    )
    if status == PENDING_LOCK_STATUS:
        print(
            "Architecture lock schema is valid but pending. Fill the backend "
            "commit and document SHA256 after the canonical document is committed."
        )
    else:
        print("Architecture lock is pinned and valid.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify = subparsers.add_parser("classify", help="classify a Git diff")
    classify.add_argument("--base", required=True)
    classify.add_argument("--head", required=True)
    classify.add_argument("--github-output", default=os.getenv("GITHUB_OUTPUT"))
    classify.set_defaults(handler=command_classify)

    trailers = subparsers.add_parser(
        "verify-trailers", help="verify sensitive authored commit trailers"
    )
    trailers.add_argument("--base", required=True)
    trailers.add_argument("--head", required=True)
    trailers.add_argument(
        "--synthetic-head",
        help="skip only this immutable merge-group head (must equal --head)",
    )
    trailers.set_defaults(handler=command_trailers)

    lock = subparsers.add_parser("verify-lock", help="validate the architecture lock")
    lock.add_argument("--lock", default=str(LOCK_PATH))
    lock.add_argument("--require-pinned", action="store_true")
    lock.add_argument(
        "--backend-checkout",
        help="also verify the checkout HEAD and architecture document digest",
    )
    lock.set_defaults(handler=command_lock)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(list(argv) if argv is not None else None)
    try:
        arguments.handler(arguments)
    except GateError as error:
        print(f"voice-clone architecture gate failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
