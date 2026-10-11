# Mac 28-language adaptation — 2026-10-11

User scope: match released iOS 1.2.48 language behavior; 28 locales, five genuine Mac screenshots per locale and Mac-specific App Store descriptions; build and submit Mac update. Global-only Mac product; no iOS re-release or Safari standalone changes.

- ASC baseline read: Mac 1.2.47 (73), version b4c6afe6-bf93-475e-ae52-0af7b5bee9ab READY_FOR_SALE. iOS 1.2.48 (75), version 968ba86c-0722-43fa-b55c-ff0425533966 READY_FOR_SALE.
- Source: new managed worktree /Users/xuxuheng/.codex/worktrees/mac-28-languages/CastReader, branch codex/mac-28-languages; Mac baseline 295c2f49cae830a24257c8e9b1b92cb31b12a4e0; merging released iOS d48a9af144bfef1d07af0e81c7a847b283d8bbf0. No modifications to old worktrees.
- Candidate: Mac 1.2.48 (76), subject to final ASC max-build recheck. iOS source integration stays at 75.
- Merge preserves Mac window/scene routing, sentence request planner, import controls and minimum Explain-content checks; adds 28-language detection/voices/translations and physical-coordinate RTL fixes. Catalogs semantically merged; four conflicting cloud translations use reviewed iOS values.

Pending: finish Mac-only translations and source/target audit; focused isolated Mac tests and build; genuine Mac language/RTL/voice/quota/core playback checks; 140 local screenshots and metadata (Filipino has no ASC locale, preserve local); signed universal archive and VALID upload; strict campaign audit and submission readback.

Historical Mac 73 gaps are not new passes: YouTube provider rate limiting, WeRead paid-session recheck and real Mac purchases. iOS id/ms automatic detection limitations remain explicit; manual language fallback retained.

## Completed implementation and first checks

- Semantic merge conflicts resolved; Mac project graph verification and release ancestry gate PASS. Mac-only camera/offline/WeRead/color strings directly translated into the added languages. Six catalogs, 28 languages, 0 missing/placeholder findings.
- Mac menu rebuild requested on language changes (Catalyst-only); UIKit import added.
- Isolated test helper corrected to use a valid `group.` test-only App Group with automatic provisioning; production data namespaces remain untouched. Reuses an explicit isolated workspace for incremental repair.
- Focused Mac run: 226 total, 223 passed, 1 locale-set failure, 2 opt-in external PDF fixture skips. The extra share_cancel aliases were fixed; full LocalizationCatalogTests rerun: 51/51 PASS. Remaining selected tests reused from the same functional source.
- Candidate Mac version created: e9065422-ce33-4ff5-81e1-a7b7aef4f7b4, 1.2.48, PREPARE_FOR_SUBMISSION, candidate Build 76. All 29 intended Mac metadata entries written and exact readback verified. Shared App Info, existing links/keywords/promotional copy, pricing and legal settings preserved.
- Current normal Mac 73 is signed in with an existing Pro account; Kindle, Google Books, Kobo and WeRead shelves are available. No new login required at this point.
- Release arm64 Mac 76 built, all three signed components verified with 28 compiled locales, and installed at ~/Applications/CastReader for Mac.app without changing user storage. Previous Mac 73 app retained in CastReader-Releases/Mac-1.2.48-76-20261011.
- All 28 app-language / voice-panel states recorded from the real signed-in Mac app. Home and Library screenshots captured for all 28 languages; most Import screenshots also captured. Genuine Read/Explain captures and final 140-image completion still pending. Initial five-language composition sample: 15 opaque 2560×1600 images passed layout checks.
- Expanded the Mac Import sheet to 760×680 points; actual German long-text layout verified. iOS/iPad layout unchanged.
- Full isolated test execution completed 1,959 cases (4 conditional skips), with 22 failing cases primarily caused by inherited iOS fixture assumptions about whole-paragraph requests, cold-start buffering and client platform. No blanket passing claim: the xcresult summary failed to write when the disk filled, so detailed stdout is retained. Fixtures now exercise provider tails within one sentence, retained multi-sentence audio explicitly, and Mac immediate cold playback while preserving pause/no-replay checks. Affected-suite rerun pending after a test-host link also hit disk exhaustion; no user's data or archives deleted.
- User priority update: finish Mac voice browsing against iOS/iPad adaptive presentation before Explain work. Single Czech preset, four Filipino presets and rich English catalog observed. Mac content column now capped at 720 points, matching the player voice panel; Release r3 built, signed and installed; Czech single-voice, Filipino four-voice and rich English layouts visually verified. Existing count-based behavior suppresses empty recommendation groups and unnecessary search. All 28 voice layout states retained for comparison.
- Real account allowance panel reads monthly 0 min plus purchased 44 min; purchased balance is visible separately. No credit or membership mutation performed for Mac.
- Current code beyond e43f0ab remains uncommitted until affected tests/UI pass. No Mac build upload or review submission yet.

Private evidence: reports/mac-28-languages-20261011/. Store source: store/app-store/mac-1.2.48/.

- Korean interface with English text: real Read playback showed word highlighting, and its player voice panel opened English (not Korean). Release r3 public-clone Explain generated six real blocks; progression from block 1 to block 3 and timed original-text circles/highlights/underlines observed. Detailed request-correlated core matrix remains pending.
- Affected-suite repair-r6 test build succeeded with disk space recovered; cases are running.

- repair-r6: 391 cases, 390 PASS / 0 FAIL / 1 opt-in network fixture SKIP. All 22 previously failing cases passed in their full affected suites. Platform-specific Mac assertions retain the original iOS expectations behind Catalyst conditions; fixture input adjustments remain portable. No second full-suite generation run needed.

- All 140 genuine raw Mac screenshots now exist. Scene 2 retakes preserve a real paused word highlight; Arabic/Hebrew mode controls were selected by visible coordinates because Catalyst accessibility segment actions mirrored their hit positions. Physical clicks work; English text/mark coordinates remain LTR under RTL UI. Final composition/audit/upload pending.
