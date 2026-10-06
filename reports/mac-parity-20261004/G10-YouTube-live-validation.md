# G10 YouTube Mac / iOS parity verification

Updated 2026-10-05 16:54 CST. **IN_PROGRESS / fresh extraction BLOCKED_PROVIDER_VERIFICATION**. Actual provider/network results are separate from deterministic contracts.

## Scope

Current iOS supports public-video URL/share import, official embed subtitle extraction, track/language selection, TTS with word highlighting and scrolling, saved listening history and position, cancellation/retry, and transcript/artwork caches. Production persistent YouTube audio caching is disabled in the current iOS baseline; the Cached badge does not promise offline audio. There is no current YouTube Explain toggle. Mac must match those behaviors and fit normal/narrow windows.

## Current evidence

- Earlier normal Mac playback of `MdIL4rxiYDM` obtained 656 Chinese cues / 2 tracks, and reached paragraph 15 with Chinese voice and visible highlighting/scroll. The earlier 651 raw service paragraphs are not the final UI grouping: this run uses 84 Chinese / 125 English readable paragraphs. This is historical successful live evidence; it does not prove every video.
- Earlier `NHHPNMIK-fY` failed official player bootstrap on Mac while iOS obtained 270 cues and 11 tracks. That earlier difference prompted current retest.
- **16:12 normal Mac retest fails** after 13.416 seconds. Exact-video preview detected; `cueVideoById` then the single muted `official_player_playVideo` action executed; no correlated player response and no caption tracks arrived. Actual UI displays clear initialization/access failure plus Open in YouTube, Cancel and Retry; no fake transcript or endless spinner. Evidence frozen in `g10-youtube-live/english-retest-*`.
- **16:14 simultaneous isolated-host retest now fails on BOTH Mac and iPad** with the same `player_bootstrap_failed`, absent player response and zero tracks. Current results cannot establish a Mac-only failure. Source has not been changed to work around this result. `mac/ios-english-current-summary.json` and events retain the paired result.
- A fresh two-platform Chinese-video probe and official public-page observation are underway to separate content availability, current provider behavior and app extraction compatibility.

## Remaining verification

1. Live extraction with a currently playable public video; then repeat the original failure.
2. Narrow/wide transcript layout, language switching with preserved video-time anchor, visible word highlight/scroll, pause/resume, history reopen, transcript/artwork-cache replay.
3. Error/retry/cancel contracts and stale request ownership; real provider restrictions remain explicit and must not be bypassed.
4. Final affected Mac/iPad regressions and normal-app replay for any repair.


## 16:25 — Initialization timing investigation

- The official public watch page plays the English video in the existing signed-in Safari session; that observation does not establish identical profile behavior inside the isolated app extractor. Closed only this task's newly opened video tab afterward.
- Fresh Chinese-video extraction also fails with `player_bootstrap_failed` on both test hosts; prior cached playback success remains valid but is not a fresh extraction pass.
- Test-only, opt-in diagnostics compare original 0.01-opacity and fully opaque hosts. Both report document visibility `visible`; both fail. Opacity alone is not the root-cause evidence. No product extraction behavior changed for these diagnostic runs.
- Real player probes show exact embed documents, a muted cued player (`state=5`), video with no source/readyState 0, no correlated player response, and a play overlay appearing after the single API request. Existing one-shot gate prevents retry through that newly mounted official control. Executable adapter regression is being added before a bounded readiness repair.
- API reference consulted: [YouTube official IFrame API](https://developers.google.com/youtube/iframe_api_reference). Actual behavior and validation above come from local runtime observations, not inferred from the API documentation.


## 16:33 — Delayed control repair and test-host correction

- Executable adapter tests reproduce four assertions on the old single-shot timing. The candidate allows up to 1.5 seconds after cueing for the preferred official overlay to mount, while retaining immediate exact-button activation when present and a single muted API fallback when no control arrives. Two targeted cases pass on both Mac/iPad. The native/adapter outer deadlines and origin trust checks are unchanged.
- The first paired repaired live run progressed to explicit provider results: Mac `LOGIN_REQUIRED / youtube_verification_required`; iPad `OK / playable`, 11 tracks, but no usable cues from two HTTP 200 timedtext bodies, classified `transcript_access_failed`. This is **not a successful extraction** and no account challenge was solved or bypassed.
- Expanded contract tests found three fixture failures on each host: the test-isolation script rewrote the stable public Embed origin along with private bundle/storage identifiers. Corrected both isolation scripts to preserve literal and URL-encoded public origin while retaining private app, group and keychain identities; restored the production-identical model in both existing hosts. Earlier isolated network observations used the rewritten origin, so they are historical host-specific evidence, not a controlled production-origin comparison. The normal-app 16:12 failure used the production origin and remains valid.
- First broad selection accidentally named the source filename `YouTubeTranscriptTests` rather than its ten concrete classes. The corrected full selection explicitly enumerates all **13 actual classes** across the four files. Final broad rerun and normal candidate replay are in progress. Initial failure summaries are retained.

## 16:54 — Actual playback, cold recovery and mouse-wheel repair

- Full contracts after correcting Mac test target membership: **Mac 246 PASS / 0 FAIL / 1 SKIP; iPad 246 PASS / 0 FAIL / 1 SKIP**. The skip is the existing opt-in provider network test. Mac's selection now includes the source file containing all ten model classes; project sync rejects unknown selected test classes instead of silently leaving them out. See `mac-full-contract-complete-summary.json`, `ios-full-contract-summary.json` and `origin-isolation-check.json` in `g10-youtube-live/`.
- Normal production-identity candidate `NHHPNMIK-fY` returned `LOGIN_REQUIRED / youtube_verification_required` after **12.340 s** at 16:36. Accurate failure explanation and Open / Cancel / Retry remain usable at 1024×768 and 800×600. Cancel returned to history. `normal-candidate-run.json` is frozen as BLOCKED_PROVIDER_VERIFICATION, not successful extraction.
- Cached `MdIL4rxiYDM`: Chinese → English → Chinese switches resolved without new extraction. 06:02 Chinese mapped to the containing 05:57 English paragraph; 06:59 English mapped to 06:53 Chinese. This matches the shared iOS paragraph-start timeline policy, not sample-exact translation seeking. Voice changed Xiaoxuan → Bella → Xiaoxuan. Track selection starts playback even when previously paused, matching the unchanged baseline behavior.
- English words such as “liquid” and “becomes” visibly highlighted individually; automatic scrolling and natural paragraph advance worked. Chinese displayed segment-level fallback. Shared `hasReliableWordHighlight` gates word timestamps; do not report Chinese word-level highlighting as passed from this run.
- Pause and cold quit/reopen recovered paragraph index 35 / video timestamp **07:19**. Opened paused, then explicit Play restored audio **6.397236250 → 6.413560418 s** (16.324 ms first-play difference) and advanced normally. TTS was generated online; cached artwork does not establish offline audio. See frozen `cached-playback-run.json` and bounded events.
- ±15 s buttons use current TTS segment bounds, exactly as current iOS `AudioPlayerService`; they are not a video-timeline seek. Forward reached the segment endpoint and advanced; backward while paused returned to segment start without resuming.
- 800×600 uses a stacked header/transcript layout; 1024×768 uses side-by-side layout. Controls and language options fit both. Restored 1024×768 at the end.
- **New actual Mac defect:** scroll-wheel movement did not activate SwiftUI `DragGesture`, so manual transcript browsing did not expose Return to current position. Added a scoped observer of the enclosing `UIScrollView.panGestureRecognizer`, without replacing its delegate or intercepting clicks. Programmatic word-follow does not activate that recognizer. The normal rebuilt/signed candidate passed paused scroll → Return, playing scroll with the manual viewport retained across audio advances, Return → automatic follow, and the same flow in 800×600. This is real UI regression evidence; existing contracts are being rerun after the view change.
- API basis for indirect scrolling: [Apple UIPanGestureRecognizer scroll types](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask). Provider verification and Chinese timestamp-quality effects remain separate open results.


### 16:55 regression closure

Mouse-wheel repair candidate passed the complete same YouTube selection: Mac/iPad **246 PASS, 0 FAIL, 1 network opt-in SKIP each**. Summary files are `mac-scroll-regression-summary.json` and `ios-scroll-regression-summary.json`. The playing manual viewport remained around 10:53–11:59 while playback advanced 08:02→08:28; Return restored the active 08:43 paragraph and automatic follow. Small-window replay also passed. No new live extraction claim is made.


## 2026-10-06 核心收敛补验

未缓存视频 NHHPNMIK-fY 在正常 Release 单次提取仍返回官方字幕访问临时限流；取消恢复通过，新提取继续 BLOCKED_PROVIDER。 详见 `core-convergence-20261006/README.md`。
