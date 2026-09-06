# iOS playback recovery verification — 2026-09-07

Base: `47f9541a0a9d08ff9d415a1692005b2d81c35eec`, retaining `09dcb64` and `814030a`.

The patch addresses confirmed client recovery defects. It does not claim to recover the exact original NSError or failing audio bytes for the two build 53 incidents.

## Behavior

- Rebuild a failing local item once from its existing in-memory AudioSegment bytes. Rewrite a fresh atomic temp file, recreate AVPlayer, seek to the previous segment-local seconds, preserve queue and playback ownership, and honor an explicit pause during recovery.
- Release the old asset/observers before removing its temp file. A resume detects a missing file or failed item/player instead of attempting to reuse it.
- The retry budget remains consumed after readiness. A second failure becomes terminal; subsequent Play cannot revive that item. An explicit reader retry may select/regenerate audio afresh.
- After terminal playback failure, Read/Explain cancel their producers and increment their generation fences. Old callbacks cannot replace an error with streaming/ready. Synchronous staging failures now propagate a false result through queue-loading calls.
- Time observer callbacks require both the registered item and player identity. First-audio telemetry requires two consecutive samples with advancing time while AVPlayer actually plays; initial/recovery seeking resets the evidence and suppresses interim zero-position ticks.
- Diagnostic error stages distinguish file write, item status, failed-to-end, readiness timeout, and resume failure. Remote read_end/explain_end retains existing schema and carries only a bounded safe errorCode (`[a-z0-9_]{1,64}`; signed numeric NSError codes use n/p prefixes).
- Up to 48 local diagnostic rows survive Release builds in Application Support/audio-playback-diagnostics.jsonl. They contain only timestamps, whitelisted NSError domain aliases/numeric codes, media-kind enum, byte/file sizes, file existence and player states/position. They contain no descriptions, paths, URLs, document text, raw account identity or audio bytes. These richer local fields are **not** uploaded as remote event properties.
- No TTS route, voice, timestamp/highlighting gate, model, subscription configuration or app version changed.

## Verification

Simulator: iPhone 17 Pro, UDID `6A08602F-01D6-4B70-979D-5A5028E894E6`, iOS 26.5. Workspace/scheme: CastReader.xcworkspace / CastReader.

- `Verified.xcresult` / `verified.log`: 39 tests passed (7 new AudioPlaybackFailureRecoveryTests, 6 ownership, 25 ProductAnalytics, 1 queue-drain regression).
- `Kindle.xcresult` / `kindle.log`: existing `testKindleNineLanguageAndPageEvidenceContracts` passed, including delayed confirmed-page recovery, one retry only before semantic dispatch, and no repeat click after dispatch.
- `FinalRecovery.xcresult` / `final-recovery.log`: final seven-test recovery pass, adding actual AVPlayerItem position verification and long safe-code truncation coverage.
- `git diff --check`: passed.
- The new tests use generated silence and corrupt local fixtures. No production TTS calls or speech synthesis are part of the test cases.

## Release integration

Release worktree HEAD `578bd91` (1.2.34/build54 already WAITING_FOR_REVIEW) already contains 09dcb64 and 814030a. At review, its AudioPlayerService and ReadAloudViewModel matched this patch's parent; its KindleBookView did not contain 47f9541 ownership guard changes. Integrate this patch and 47f9541 on top of the full release branch, retaining release-only Kobo/GoogleBooks/routing/localization changes. Do not replace the release branch wholesale with this worktree.

Build 53's new Kindle `page_turn_failed` with cumulative 3243 seconds identifies a page-navigation failure rather than a player-item error. Existing 814030a covers some confirmation/dispatch failure paths and 47f9541 protects ownership changes. The aggregate event does not establish which branch occurred, so these patches must not be described as a verified reproduction of that individual failure.

Release archive/sign/upload/review changes are delegated to the parent release coordinator. This worktree does not change App Store Connect, version numbers, or review state.
