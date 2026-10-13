# G09 Google Play Books Mac 实测验收

状态：执行中，Google 书架核心已通过；正文重排修复正在回归，长时间朗读与解读尚未验收。Kobo 的通过不能代替 Google 通过。

## 验收范围

- M070：现有已登录会话，五本书架刷新、搜索、排序、打开和返回；窄窗搜索/菜单/同步关闭按钮。
- M071：真实 Read 至少 30 分钟，跨页/跨章、短段、暂停和显式续播，大小窗口变化；最终另验书尾。
- M072：真实 Explain 至少 15 分钟，单栏/双栏字幕和原文 marks，手动操作不误触正文。
- M073：深处保存、冷退出后再次打开与定位；以实际 locator/内容匹配而非页码相等验收。
- M074：取消刷新和当前账号缓存合同；真实不同账号隔离只有获得可用第二会话后才记录通过。

## 预先可见书架

Moody's Addresses (`ayBBEQAAQBAJ`)、The Enchanted Isles (`b_40EQAAQBAJ`)、Sasha's Secret Life (`QrpAEQAAQBAJ`)、The Way to God (`utwyDwAAQBAJ`)、According to Promise (`WaOcDwAAQBAJ`)。此前仅确认首页可见，没有 G09 正文验收结果。

## 12:00 shelf validation and fixes

- Existing Google session is valid. Refresh detected five books; explicit Sync 5 Books returned to the native shelf with all five.
- Search Moody returned both books by Dwight L. Moody; Promise returned According to Promise. Title and author sorting matched visible metadata. Search/sort/refresh remained usable at 800x600.
- The connection sheet Close label was clipped to Cl... by the long title. Applied the same plain/fixedSize button treatment as Kobo and added a stable accessibility identifier. Live retest pending.
- Recent order changed after cold opens and syncs. Dictionary values with identical sync dates had no stable tie breaker; newer sync timestamps also placed unread books ahead of read ones. One comparator now prioritizes actual opening dates, then sync dates and stable IDs, across sorting, merge and reload.
- The new old-code Mac regression failed with three assertions: unstable ties, opened-book priority after sync, and cold reload order. The initial attempt ran zero cases because Google shelf tests had not yet been included in the Mac test target; it is not accepted evidence. Four existing iOS Google shelf classes are now registered in the Mac target using Ruby and its shared test selection. Project verification preserves original iOS settings.
- iPad affected integration: 127 passed, zero failures/skips. Mac selection is running.


### 12:30 - Google reflow and late artificial endpoint investigation

- Live shelf replay: full Close label is visible and cancellation preserves all five books. The opened book sorts above unread books in Recent.
- The first Read run is **not a pass**. At 12:04:43, font 100 to 113 percent during carried audio requested native source reveal, then regenerated an earlier 1199-character source. Unmatched segment recovery fell back to the paragraph opening at 12:05:02. Original events are retained in `g09-google-long-read/initial-font-failure-events.log`.
- Temporary DEBUG diagnostics record source IDs, UTF-16 ranges and states, not book text or credentials. Ordinary reflow at 12:16:47 successfully remapped the audio source; reflow at 12:20:02 used native reveal before remapping. Paused carried-source reflow at 12:25:33 also remapped correctly. The original repeat still needs an exact reproduction and repair.
- A separate actual defect is confirmed: at 12:19:38 and 12:24:44, the native page acknowledgement precedes AVPlayer's artificial didEnd notification. The callback is ignored after the hold is removed and leaves the current item stopped at its page edge. This explains the apparent Play/Pause discrepancy; do not classify it as a button defect without additional evidence.
- A real AVPlayer regression blocks the main executor through the artificial endpoint, acknowledges paint, then delivers the queued didEnd. Old code stops at 0.25 seconds instead of passing 0.6 seconds (Mac red result). A companion case verifies explicit Pause wins. The first red also contained an overly early player-identity snapshot assertion, corrected to snapshot the decoder at its boundary; the observed clock failure remains valid.
- Candidate change resumes the acknowledged decoder only while playback intent, ownership and automatic-play gates still permit it. Shared Mac/iPad targeted verification is in progress.


### 12:49 - Endpoint fix verified; repeat fallback rejected

- Late artificial endpoint tests: Mac 2/2 and iPad 2/2 pass. Expanded shared regression: Mac 203/203 and iPad 203/203, zero failures/skips, including actual WKWebView pagination and AVPlayer recovery.
- Two new unmatched-reflow tests failed against old iPad code: the unchanged opening prefix selected the paragraph, but the missing old sentence fell back to newly generated opening audio. The paused case silently queued that prefix; the playing case actually started it.
- `finishPendingLiveWebResumeIfNeeded` now pauses and reports an unavailable exact cursor instead of loading unmatched audio. The producer completion cannot overwrite that error. iPad affected integration 105/105 passes, including 101 ReadingResume tests and existing valid paused/later-part/carried-source reflows. Mac matching selection is running.
- The ordinary same-provider 125 -> 113 -> 100 percent font replay remapped or revealed the matching source and retained its audio segment. This does not yet close the original carried-source issue.
- A direct repeat at the original page (100 percent, next carry length 86) was too late: the UI action reached after the carried sentence had completed; its successful remap is not the target reproduction.
- **Temporary local DEBUG instrumentation currently freezes every Google carry immediately after a verified visual commit, writes bounded source snapshots on a remap miss, and prints numeric reflow diagnostics. Remove all three before any acceptance candidate or release. This frozen build is diagnostic-only.**


### 13:05 - Exact carried-source cause and signed-origin repair

- The frozen diagnostic reproduces the original 86-character carried tail at 12:53:02. At 12:54:06, 100 -> 113 percent font reflow retains an 800-character immutable audio source while Google recreates its paragraph with a new source ID and zero origin.
- The new 1199-character visible paragraph begins at character 207 of the old audio source. Its first 593 characters are an **exact** match to the old suffix. The required old-audio origin is therefore -207 in this new DOM. The old nonnegative-only remapper rejected the valid overlap, and native reveal returned the same visible page. The new unmatched-anchor protection stops instead of replaying the beginning, but that protection alone is not the feature fix.
- The remapper now accepts a signed virtual origin only through its existing unique, substantial, exact overlap proof. Ambiguous repeated passages remain rejected. DOM fragments still clip their effective range to visible characters. Retained carry timing can preserve that signed origin across further page transitions.
- The JS reader keeps the immutable source for negative-offset word alignment, then maps matches into the new DOM. Prior offscreen words cannot consume repeated visible words. Direct character highlights also use the signed offset.
- Old Mac tests failed on both the mapping and actual WKWebView highlighter. Corrected implementation passes 2/2 on Mac and 2/2 on iPad, zero skips. Expanded WKWebView/AVPlayer/shared-resume regression is pending. The earlier unmatched protection expanded result also passed 105/105 on Mac, matching iPad.
- Added an end-to-end native refresh step asserting retained source, paused clock and queued unread suffix after source-ID change and prefix removal. The generated bundle replaced only the second cr-bridge.ts block; all prefix/suffix modules are hash-preserved in `signed-origin-generated-verification.json`.
- One red build was accidentally started from the Mac parity checkout into the private Mac DerivedData directory. It was terminated before execution. Rebuilt from the private workspace and verified `com.same.castreader.releasechecksmac` before running tests; no normal-account test process was launched from that intermediate output.


### 13:12 - Expanded signed-origin regression

- iPad: 321 passed, zero failures, one explicitly skipped opt-in network shell smoke case (`testRealPlayBooksShellInstallsRelayOnly`). This is 322 selected cases across Google contracts, actual WKWebView bridging, pagination and resume; the skip is not counted as a pass. The normal-account live Google run separately exercises the real service.
- The extended native refresh case with changed source ID and removed paragraph prefix passes on both Mac and iPad. Mac remaining pagination/resume cases are still running.
- Saved the two targeted signed-origin summaries: Mac 2/2 and iPad 2/2, zero skips.

- Mac expanded selection completed: 321 passed, zero failures, the same one network opt-in skip. Clean source now matches both private tested hosts byte-for-byte for all five affected runtime files. Removed the three temporary diagnostic source blocks and three raw snapshots; normal binary still frozen until rebuilt after exact-condition replay.


### 13:22 - Original live condition succeeds with signed origin

- Frozen diagnostic reaches the original `GBS.PT58.w.0.1.130_37` carry (86 UTF-16 characters). The 100 -> 113 percent change at 13:20:24 recreates the same source IDs and 800-character retained source as the original failure.
- Remap now succeeds; the 605-character unread suffix is kept as a separate item. The final old audio part is restored paused at progress 0.677, with its visible word `are` correctly highlighted in the reflowed paragraph. No source reveal or unavailable-anchor notice is needed.
- Explicit Play continues the old part and then the verified unread suffix; visible highlighter advances into both suffix parts. This closes the exact-condition diagnostic, **not** the normal-package long-run acceptance.
- Removed all three temporary diagnostic source blocks, checked affected runtime hashes match the tested hosts, and removed the three agent-created raw source snapshots. The normal candidate is rebuilding without the freeze or snapshot writer. Filtered local events and numeric/hash evidence are retained under `g09-google-reflow`.


### 13:39 - Normal run fails double-page shrink; investigation continues

- Clean normal candidate starts at 13:24:14.131. Light theme and switching from Auto to Double Page retain ongoing reading and complete one real automatic carry/turn.
- At 13:26:22, dragging the 1024x768 window to 800x600 resets Google from `GBS.PT59_20` to earlier `GBS.PT58.w.0.1.203_162`. Native source reveal returns no direction, then the missing paragraph branch clears the old queue and leaves the reader paused.
- **This run is FAIL, not long-read PASS.** Kept candidate identity and bounded failure events in `g09-google-clean-long-read`; do not reuse its status script as a new long-run result.
- Secondary UI defect: `resumeNotice` exists in the VM but is never shown by the shared reader host. Added a material notice above the reading surface, using an overlay so showing it cannot repaginate the live reader again. UI build/replay pending.
- Compact JS diagnostic logs only native page IDs, block lengths and substring indices (no book text); currently temporary in `play-books.ts` and both generated bundles. Remove before final candidate. It is unrelated to the removed frozen-carry/source-snapshot instrumentation.
- Independent pre-resize-fix Release build succeeds for x86_64 and arm64, minimum macOS 14.6; deep strict code-sign verification succeeds. That binary contains no diagnostic tokens. This is build-only evidence, not final runtime/release approval.


### 13:53 - Partial native source and ordered-context recovery

- Live diagnostic confirms the shrunk spread exposes only verified native pages 22–25 while the active source can lie farther ahead. The original whole-paragraph search cannot locate even an available partial source. Numeric structural metadata is saved; no source text was written by this diagnostic.
- Recovery now accepts one substantial exact source overlap with a unique origin, including a partial measured prefix/suffix. If the target is beyond the finite native cache, an exact unique earlier/later neighbor wholly beyond the visible spread can prove one physical turn direction. Conflicting or repeated evidence yields no turn; the existing owned-frame, current-baseline and bounded retries remain in force.
- Native supplies ordered previous-page context for this proof. The generated update replaces only the play-books.ts module, preserving every other generated module. All temporary reveal diagnostics are removed again.
- Old Mac regression fails the two new positive cases. New iPad affected regression: 97/97, zero failures/skips. Mac selection pending. Additional pure contract checks pass six cases covering reverse recovery, contradictory directions, repeated overlap, already-visible targets and changed neighbor text; Kobo JS fixture also passes.
- Recovery notice is visible in real UI and clears after explicit paragraph selection. Its overlay preserves the provider viewport dimensions.


### 14:03 - Normal partial-source replay and new long run

- The final affected automated selection completes with **97/97 on Mac and 97/97 on iPad**, zero failures/skips. Both use the normal source after all temporary diagnostics were removed.
- At 13:56:15, the same 1024x768 -> 800x600 double-page shrink now obtains a verified native reveal. The old 534-character source restores **part 1 at progress 0.640, playing** at 13:56:24, then advances naturally to the next paragraph. This preserves the retained source/part rather than restarting the opening.
- Subsequent automatic page changes retain visible word highlights. At 13:56:44, the previously tested late artificial endpoint also fires in the real run and `acknowledged_endpoint_continued` keeps the same decoder advancing.
- Explicit Pause at 14:00:51 followed by enlargement restores the same part at progress 0.744 **paused**, with the word `receive` highlighted in the new DOM. No new playback starts until explicit Play. Structural events are saved in `g09-google-reflow/live-partial-reveal-events.log`.
- A fresh normal one-times-speed Read run starts at 14:03:01.860. Its independent identity/offset/status live under `g09-google-reveal-long-read`; the earlier failed run remains failed. Long Read/Explain are still pending.


### 14:20 - Ongoing live layout coverage

- The new run has crossed Chapters 13–16 with no manual page jump. At 14:18 it reaches 912 seconds and 15 distinct full automatic locators. Truncated signature prefixes can repeat across different pages; the status collector now compares full saved locators instead.
- Single-page selection during playback restores the old part at progress 0.205 and naturally turns onward. Line height 100 -> 113 -> 100 also restores the same source part and continues. Font 113 -> 100 retains the 113-character unread suffix separately, then restores the active part at progress 0.082.
- Six zero-overlay events so far occur during provider DOM replacement: four immediately before the first line-height refresh and two in the later refresh; subsequent stable-page screenshots visibly show correct orange word highlights. No sustained loss is accepted as passing.
- One settings-scroll tool observation returned AXError.noValue. The original app process stayed alive, word events continued, and the next observation showed the actual open panel. This is not a crash or a long-run restart.
- Font/line height are restored to 100 percent, Light theme remains original, and Auto layout has been selected. The 800x600 automatic-layout replay is underway.
- Independent final Release build and static scans pass: universal arm64/x86_64, macOS 14.6 minimum, strict deep signature valid, 54 fixture markers absent across 107 files; actual private test app serves as positive control. Scanner now handles both iOS root Info.plist and Mac Contents/Info.plist and rejects embedded xctest path components. Details in `g10-release/final-build-static.json` and `final-fixture-scan.json`. This is a local development-signed candidate, not distribution or runtime approval.


### 14:34 - Long Read duration and pagination pass

- **1857.509 seconds**, 14:03:01.860–14:33:59.369, **31 automatic commits / 31 different full locators**, 18 carried-source commits, six verified reflows, no manual page jumps, no detected timeout/repeat/recovery error. Explicit Pause ends the run with the current word `ended` at `GBS.PT75.w.0.2.105_52`.
- Twelve zero-overlay events are all within 1.3 seconds of deliberate DOM reflows. Stable-page visuals show correct highlights. The reader has crossed Chapters 13–17.
- Explicit retained-decoder hold samples: median about 83 ms, max about 393 ms. These are **not all speech waits**. Four chapter queue replacements omit explicit hold-release events; actual first-word intervals also include cold TTS/opening buffering. The full gap audit retains 5.8–9.5 second chapter intervals and 3.8–10.4 second layout-regeneration intervals, with no unbounded stall. The initial collector omitted carry DOM-range paint events; corrected collection includes them, removing its false 40-second apparent highlighter gap.
- Computer-use native pipe briefly disconnected at the end. Rebinding showed the same live process (PID 1405), unchanged reader and ongoing playback. No app restart occurred until the intentional cold-recovery test at 14:34:51.
- This closes the long Read duration/pagination/layout scope. Cold reopen, second book, terminal page and 15-minute Explain are still separate pending items. `g09-google-reveal-long-read/result.json` is frozen; earlier failed runs remain failed.


### 14:50 - Cold-resume regression and repair

- Cold launch returns to the same native locator and visible text but rejects the saved word (`ended`). The pre-quit checkpoint has `visual=true, reflow=false`. This is a separate FAIL; the frozen long Read result remains scoped to duration/pagination/layout.
- Google Books was missing both hashed-context capture and strict context relocation in the shared durable resume pipeline. Added the same exact, unique context checks as Kobo/WeRead; no OCR correction or nearest-word fallback is permitted.
- Two new production-VM regression tests reproduce six assertions on the old Mac source: accepting unchanged unique word context after boundaries change, and capturing a real played word then reopening an expanded paragraph. Changed and repeated contexts must remain rejected; opening must remain paused.
- Repair builds for isolated Mac/iPad and normal Mac succeed. Full `ReadingResumeTests` on both isolated hosts and real cold replay are in progress. No runtime PASS claimed yet. Legacy checkpoints lacking context remain subject to the existing exact-paragraph requirement.


### 14:57 - Cold source/audio recovery passes; initial paint gap remains

- `ReadingResumeTests`: **Mac 103/103, iPad 103/103**, zero failures/skips. The two new tests fail on old code and pass on repaired code. Normal Debug and universal Release builds are separate; Release is rebuilding.
- Real replay: 1024x768 -> 800x600 while playing, auto-page, pause on `Lord` at 14:51:12, then quit. Saved checkpoint now has `visual=true, reflow=true`, semantic word `096b3764d961`, fraction 1.0. Cold launch returns at 1024x768; at 14:52:40 strict context relocation succeeds despite changed paragraph boundaries, stays paused, and clears the mismatch notice.
- Explicit Play at 14:54 resolves regenerated audio at 2.995291667 seconds; first audible tick is 3.002103167 at the same semantic word/fraction. No paragraph restart. Source/audio cold recovery is therefore verified.
- Two UI observations remain: (1) paused cold opening does not yet paint its verified source word until Play; shared bridge fix and regression are in progress; (2) this cold page takes about 40 seconds before its first page commit, leaving the source area blank without progress feedback. It eventually recovers, but the initial loading feedback needs adaptation. These observations are not hidden by the resume pass.


### 15:08 - Cold opening visuals and loading feedback pass

- Shared bridge now paints only the verified source range before TTS exists. It does not scroll the provider surface or invent speech timestamps. The production-bridge regression fails three paint assertions on old code and passes after repair; its bounded wait was corrected for cold WebKit startup before interpreting the red result.
- Full affected selection on both Mac and iPad: **158 PASS, 0 FAIL, 1 SKIP** out of 159 tests. The skipped case is the opt-in network shell probe. Final loading-indicator delta: **4/4 each**, no failures/skips.
- A nine-language `Opening book…` progress overlay is visible on actual cold entry at 15:07:18. It disappears when the verified reading frame commits; a decoded image-only cover also releases it. It does not alter pagination geometry or intercept user controls, and the existing error overlay takes priority.
- Actual cold reopen then immediately highlights the saved word `is` in the Psalm sentence while remaining paused, matching the preceding quit position. No Play or paragraph tap was needed. Initial loading and paused word visuals are therefore PASS on the normal candidate.
- Began native 101/101 terminal-page Read/Explain testing; independent long Explain remains pending. Final source/binary identity is in `g09-google-cold-resume/final-candidate-identity.json`.


### 15:19 - Terminal completion and second-book long Explain

- According to Promise final-page Read drains at 15:09:28 into the provider's confirmed book-end screen. Switching to Explain at that terminal screen finishes without another next-page request; recommendations are never adopted as source.
- Returning to the last original page and explicitly starting Explain shows two ISBN underlines and the print-run number circle with spoken explanation/subtitles, then naturally returns to the end screen and `Explanation complete`. Scoped terminal result: `g09-google-terminal/result.json`.
- Moody’s Addresses opens with a fresh loading indicator, uses its own native saved location, and automatically reads at Bella 1x according to the existing auto-play setting. Visible word highlighter verified. It is the second real Google volume; no manual shelf data or history editing.
- Independent Explain run starts audible playback at **15:15:15.674**, using `g09-google-long-explain`. 1024x768 -> 800x600 at a chapter boundary continues normally. The small Aa panel scrolls to its controls; font 100 -> 113 restores marks to the newly paginated source while narration continues.
- Final local universal Release builds and strict deep signature/fixture scan pass; 107 files and 54 markers with real debug positive control. Credential-pattern scans find no matches, with pattern positive controls. Source/project validation keeps 228 shared Swift files, 14 resources and unchanged original iOS settings/extensions. This remains local development signing and does not claim distribution, notarization or Intel runtime validation. See `g09-google-cold-resume/final-release-static.json`.


### 15:27–15:37 - Explain long run fails at overlapping source reveal

- The first independent Explain run is **FAIL**, stopped after 669.707 seconds with 16 unique automatic commits and 128 subtitle cues. It does not satisfy M072. Evidence is frozen under `g09-google-long-explain`, including the full structural failure window.
- At 15:26:25.441 the final annotation requests a source-reveal turn after a double-page reflow. At 15:26:25.956 page completion dispatches another automatic turn before that reveal settles. The provider reports the new page as `refresh`; native correctly refuses an unowned refresh while an automatic turn is pending, then times out at 15:26:41.804. The UI incorrectly reports completion at native pages 34–35/177.
- Two real WKWebView/production-bridge regressions reproduce four assertions on old code: an extra premature turn, a stale turn baseline, and continuation surviving a mode switch. Initial repaired Mac/iPad selections pass both cases.
- The candidate serializes annotation source reveal and page completion. Only a changed, trusted owner-frame refresh releases the reveal gate; its unexplained visible remainder is consumed before any further physical turn. Mode switch, valid manual navigation and reader invalidation cancel deferred continuation. The reveal has a bounded timeout and surfaces an error if a completed explanation was waiting. Additional stale-refresh/remainder regression and actual replay remain pending.


### 15:40 - Explain reveal delta passes on both platforms

- Final targeted selection: Mac **3/3**, iPad **3/3**, no failures/skips. The additional case proves newly exposed, unexplained source is staged for explanation while the already narrated source is removed; no extra physical turn is requested. Repeated old-baseline refresh and switching back to Read cannot release deferred Explain continuation.
- Normal candidate builds and deep strict signature verification pass. Candidate identity is in `g09-google-explain-reveal/candidate-identity.json`; the generated Web bundle is unchanged. Broader bridge/source-contract/page-availability regression is running before real-provider replay.


### 15:48 - Shared integration passes; real replay begins

- Final affected suites (`GoogleBooksWebBridgeTests`, `GoogleBooksContractTests`, `WeReadPageAvailabilityTests`): **Mac 163 PASS / 0 FAIL / 1 SKIP; iPad 163 PASS / 0 FAIL / 1 SKIP**. The one skip is the existing opt-in network shell probe. No computer-use actions ran concurrently with Mac XCTest.
- Universal Release rebuild, strict deep signature and 107-file/54-marker scan with a private test-app positive control pass. Runtime claims still belong to the normal Debug candidate and actual observations.
- Quit the old app and launched the rebuilt normal candidate for live replay. The previous failed Explain run remains frozen.


### 15:54 - Actual reflow remainder resumes; new long run

- On the normal candidate, opened Moody’s Addresses at the prior failure region, returned to native page 33, set Auto, started Explain and switched back to Double. At 15:53:07.417 the annotation reveals the next source page; at 15:53:18.336 the completed narration consumes its newly visible remainder and resumes at 15:53:25.962. Marks/subtitles align on the new page. This actual replay verifies remainder continuation; the exact subsecond overlap is established by the targeted WK regression, since this generated narration revealed earlier than the original failure.
- A 4.58-second pause before the layout change had no transport-toggle log and is not attributed to an app cause. Explicit Play resumed the same audio. This replay is therefore not used as uninterrupted duration evidence. The cold first-audio wait was about 43.8 seconds and remains a performance observation.
- Cold Read also correctly declined to force its older reading checkpoint into the provider locator advanced by Explain; the mismatch notice cleared after explicit page selection. Mixed-mode cold-position policy remains separate from the passed same-mode exact cold-word recovery.
- New isolated long-run log range starts with actual playback **15:53:25.962**, under `g09-google-serialized-long-explain`. Double layout, font/line-height 100 percent, Light theme, 1024x768, Bella 1x. It remains IN_PROGRESS.


### 16:10 — G09 core gate passes

- The repaired normal candidate completed **1011.180 seconds** from first playback to last advancing subtitle, with **933.44 seconds of fully finished media** at 1x (52 completed items; current unfinished item excluded). **22 automatic commits / 22 unique full native locators**, 194 subtitle cues, zero manual navigation and no detected pagination/reveal timeout or repeat guard. It naturally crossed from THERE IS NO DIFFERENCE into GOOD NEWS. Evidence is frozen with `endLogByteOffset` under `g09-google-serialized-long-explain`; subsequent activity cannot enter this result.
- During the run: Double 1024x768 -> 800x600, Light -> Dark -> Light, reader minimize/expand across an automatic page turn, return to 1024x768 and Double -> Auto. Actual subtitles, orange highlights, circles and underlines remained visible against the current source. One source reveal and one newly visible remainder continuation occurred. The exact overlapping callback race remains established by the failing-then-passing WK tests, not claimed from this timing.
- Fifty queue-completion-to-next-playing intervals: median **41 ms**, maximum **10.603 seconds**. Several cold preparation waits were 7.5–10.6 seconds. This measures inter-queue waits, not every possible in-item buffering interval. Cold replay first-audio wait approximately 43.8 seconds remains a performance item. No unbounded stall or explicit user resume occurred within this frozen long run.
- **CORE_PASS** for the current Mac/account: five-book shelf/search/sort and narrow controls; two actual books; 1857.509-second Read; repaired 15-minute Explain; same-mode exact cold source/audio/paused-word restore; loading UI; book-end Read/Explain and original marks. Relevant final shared suites remain Mac/iPad **163 PASS, 0 FAIL, 1 opt-in network SKIP each**.
- Scope exclusions remain real second-account isolation/rebinding, mixed Read/Explain cold-position policy, source timing performance, actual cross-device synchronization, Intel/minimum macOS runtime, distribution and full-app release acceptance. These are not inferred from this core pass. Preferences restored to Light/Auto, font and line-height 100%; playback paused after evidence freeze.
