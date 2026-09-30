# Resume after user-requested iPhone break

User explicitly took phone away at2026-09-30 12:51 Asia/Shanghai; resume mirror testing one hour later. One-time thread heartbeat `iphone` scheduled13:51. Do not install, launch or manipulate phone during break. If still unavailable at follow-up, request connection once; never use simulator. No iPad.

## Where to resume

- Worktree `/Users/xuxuheng/.codex/worktrees/ios-release-1.2.47/CastReader`, branch `codex/ios-four-platform-pagination-20260929`, baseline f1c423e312cdcfbf121b11428aa7867b35488a84. Preserve prior changes and untracked files. Default cwd `/Users/xuxuheng/Documents/CastReader` is NOT release worktree.
- Phone currently installed candidate87 (1.2.48/71), UUID7453F086-D5C0-3C4C-AF1D-A51E9A9612D9. Normal app console `/tmp/castreader-pagination-live87.log`, exec session3919 may still be attached. Reader diagnostic file from its initial `diagnostic file=` line; don't guess filename.
- Candidate88 built successfully (build-for-testing), NOT installed/tested. DD `/tmp/CastReaderPagination20260929`, manifestcandidate-88.json. Whole-page prepared successor now sends the exact first real cue with owned native turn, extending85 carry-only atomic paint. Added two physical tests for whole-page exact cue/mismatch fallback in PaginationContinuityTests. Run selected physical tests before installing normal88 and sampling real books.
- Existing `/tmp/castreader-pagination-isolated85.xctestrun` deliberately resolves CURRENT Build/Products. It has test-host `-CastReaderUnitTestsNoWindowRestore`, absolute __TESTROOT__ replacements and no stored OnlyTestIdentifiers. Use CLI `-only-testing:CastReaderTests/PaginationContinuityTests` or selected tests, no parallel,40/60s timeout. No simultaneous build/test using same DD.
- Physical UDID00008130-001C64800C60001C, CoreDevice8D96EFB3-DBC1-52E3-B10D-412C1059D28E. TeamKQW6UNZE8J.
- Normal launch `xcrun devicectl device process launch --device CORE --terminate-existing --console com.same.castreader -- -CastReaderLivePlatformAcceptance` with new per-candidate log. Do not confuse currently compiled88 with installed87.

## Last real-phone actions

Opened Kindle A Journey to the Centre of the Earth around12:49 on87. Native recent-location dialog: selectedNo to retain2832. StartedRead around12:50, actual1.5× in console and visible matching word highlights; at least one automatic page changed before user break. This is a short sample, NOT full Kindle acceptance. Explain has not yet been verified this turn. User specifically asked to revalidate Kindle despite previous optimization; prioritize that after break.

Stopped test before handoff: clicked pause, returned home, verified mini-player explicitly `Paused`, then closed mini-player withX. Final screenshot home with listening position saved, no active mini-player. First immediate pause screenshots still showed progress; investigate event timeline if needed rather than assume instantaneous pause worked. No more phone actions after this.

## Latest confirmed regression/fix

- Candidate86 physical10/10 for atomic carry paint, mismatch, ended-page bookend drain etc. RealGoogleRead12:38–12:41 had an abandoned first hold: ended12:38:51.624→next playing12:38:56.281=4657ms. Repeated `foreground-first-audio` invalidation canceled next-page partly producer during current AVPlayer part transitions.
- The initial isolated regression incorrectly passed because it lacked SwiftUI repeated setActive. Added read.objectWillChange→RunLoop→bridge.setActive to reproduce productionhost. Unchanged86 then synthesized same successor3times: `/tmp/CastReaderPagination-preload86-redb-20260930.xcresult` (original retained).
- Candidate87 removes cancellation on transient foreground waiting; defers NEW speculative work only. Explicit source/voice/mode/navigation cancellation still owns invalidation. Full physicalPagination61/61 passed `/tmp/CastReaderPagination-preload87-20260930.xcresult`.
- Real87 sameGooglebook/samefailurepage: next-page3parts ready12:47:09.503, armed12:47:26.355, old ended/hold12:47:32.161, nativecommit32.240, release32.310, next playing32.395 =>234ms, eliminating4.657s regen. Overall3turn cutoff12:48:45 release max139ms/native165/hold245; reportlive87-googleBooks-read-metrics.json. Still performance/duration/acoustic acceptance incomplete.
- Candidate88 addresses remaining whole-page secondhostpaint roundtrip; generatedsourceorigins account for consumed prefix via actual parsed readDOM−explainDOM offsets. JS validates exact source intersection and paint before native may release. Physical88 tests pending.

## Unfinished scope / evidence limits

All8 platform×Read/Explain final cells remain unaccepted. Follow docs/iOS-four-platform-final-acceptance-2026-09-29.md and user's three extensionguide/audit files. Final candidate each≥30min,≥3completechapters,≥20autoturns,core≥2h; actual listeningA/B+semantic controls. Never combine candidate duration or declare fixtures/acoustic success.

Kobo nativeFade untouched; existing short metrics still abovetarget. New extension KindleK13–K16 response validation/shared retry budget/generation cancellation still need mobile migration/audit. Private Chineseclone source timing production backend blocked by missing verified off-hostbackup; do not bypass. Explain short-page/chapter summary/cancellation fullmatrix open. No iPad/Android claims. No new AppStore submission/commit/push this phase; prior1.2.47 frozen release stays separate.

CUA persistent binding paginationMirror=com.apple.ScreenContinuity; first action aftercompaction cua.rewriteDocumentation(). Coordinates screenshot696×1536: back[61,205],Read[460,207],Explain[595,207],play[189,1410],prev[103,1410],next[270,1410],TOC[389,1410],voice[454,1410],speed[549,1410]. Home Kindlefirst[122,934]; currentContinueListeningKindlefirst. Freshscreenshots for actions. Existing listening-feedback question pending: toolcannothearphone; userfeedbacknotreceived. Don'trepeatuntilresumed anduseful.
