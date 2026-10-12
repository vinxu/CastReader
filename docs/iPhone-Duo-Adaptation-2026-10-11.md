# iPhone Duo adaptation and App Store delivery

## Scope and source

- User authorized implementation and acceptance of all five stages: development environment, adaptive UI, reading continuity, 28-language screenshots, and App Store submission.
- Reuse the verified iOS checkout at `/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader`; branch `codex/ios-duo-adaptation` starts at remote `main` / `d48a9af` (iOS 1.2.48 build 75).
- The user authorizes removal of Xcode 26.6 after the replacement download. Keep the working toolchain until the replacement can run on the installed macOS. Preserve logged-in simulators, connected libraries, signing credentials, release archives, and private acceptance evidence.
- Mac 1.2.48 work remains on its own branch. Selectively integrate its shared allowance-sheet improvement; do not replace unrelated iOS reading subsystems or the project configuration with Mac files.

## 1. Development environment — IN PROGRESS

Observed on 2026-10-11:

- Host updated and restarted successfully: macOS 26.7.1 (25G241). Xcode 27.1 (27A9275) first-launch components and iOS 27.1 SDK are ready; command-line tools now select `/Applications/Xcode-27.1.app/Contents/Developer`. iOS 27.1 (24A94232) runtime is installed and the actual Duo simulator boots successfully.
- Xcode 27.1 Release Candidate is available from Apple (2026-10-05). Official page lists a 1.89 GB XIP and requires Apple silicon / macOS 26.6 or later.
- Official download completed in the existing authenticated Chrome session; extracted and installed at `/Applications/Xcode-27.1.app`. Version 27.1, build 27A9275; bundle minimum macOS is 26.6. `codesign --verify --deep --strict` passed and Gatekeeper returned `accepted; source=Apple System`. First-launch and SDK verification passed after the host update.
- XIP: 2,027,369,056 bytes; SHA-256 `038ad29cc2cd87e7762aac596833943000fd3d5fb64be530e2ecdbe5449cd660`. The duplicate downloaded archive can be removed after verified extraction to recover its space; the installed application is retained.
- Software Update offers macOS Tahoe 26.7.1 (25G241), 7,617,861 KiB, restart required. Download-only preparation completed (softwareupdate exited 0 at 100%); installation/restart subsequently completed and verified. This meets the Xcode minimum without moving to macOS 27.
- Initial free disk space approximately 26 GiB; Xcode.app 3.7 GB, default DerivedData 4.3 GB. CoreSimulator directory reports 39 GB, including mounted runtimes; this is not a promise of reclaimable disk space.

Finish this stage by completing the necessary iOS runtime download and confirming a Duo device can boot. Then remove the superseded Xcode application and measure actual free space. The user explicitly approved installation and restart: “允许，保存工作后更新并重启”. Save the execution checkpoint before invoking the system installer. Do not ask for the same restart permission again. Old Xcode 26.6 is no longer selected; remove it after the new runtime has booted successfully.

The release ancestry check and existing 28-language Safari verification both pass on the unchanged iOS baseline. No Duo application code or screenshots have been marked accepted.

## 2. Adaptive UI — IMPLEMENTED, ACCEPTANCE IN PROGRESS

The source audit found device/size assumptions in 24 Swift files. These are review candidates, not 24 confirmed defects.

- `AdaptiveLayout` and `MainTabView`: choose layout from available space and size classes; retain navigation selection and reader identity when the layout changes. Account for the iOS 27.1 vertical system bars and safe areas.
- Home, library, voice browser, import, login/settings and purchase panels: compact outer display, expanded inner display, landscape, constrained windows, keyboard and large type. Reuse existing localized labels.
- Reader and mini-player controls: adapt to width/height without depending on iPad identity. Keep controls reachable and text unclipped.
- Do not infer platform capabilities (for example, multiple scenes) merely from regular width.

## 3. Reading continuity — IMPLEMENTED, ACCEPTANCE IN PROGRESS

- PDF container currently guards zoom/anchor preservation with `AdaptiveLayout.isPad`; generalize the resize behavior and check the page-space anchor and relative zoom.
- Kindle viewport projection/recovery currently guards active playback with `AdaptiveLayout.isPad`; preserve accepted audio, original reading location, generated explanation and pause intent across reflow. Do not restart the whole reader on a size transition.
- Preserve the single structural reader surface that already prevents WKWebView recreation on rotation. Recompute text/photo/PDF highlights and original-text explanation annotations for the new geometry.
- Cover actual Read and Explain across Kindle, EPUB, PDF and Web; fold/unfold, rotate, pause/resume, next paragraph/block and voice switching. English reading direction remains independent of Arabic/Hebrew interface direction.
- Apply the existing core-service release gate to affected pipelines, including CN and Global and ordinary/community/private voices. Reuse only evidence that remains valid for the final source/configuration.

## 4. 28-language screenshot campaign — NOT RUN

- Five genuine scenes per language: connected Kindle shelf (avoid Continue), Read Aloud, Explain, library, Quick Import. Total local delivery: 140 images.
- Start with English, Simplified Chinese and Arabic samples. Freeze the composition before expanding to all languages.
- Apple Duo accepted sizes: outer 1398 × 2034 / 2034 × 1398; inner 2007 × 2853 / 2853 × 2007. Prefer expanded-screen composition after actual device capture.
- Add Duo profiles to capture, rendering and upload tooling. Discover the actual ASC screenshot display type; do not invent an enum or upload to the ordinary iPhone/iPad slot.
- Verify original captures, localizations, source hashes, opaque PNGs, exact dimensions, text bounds, visual quality and ordering. Existing iPhone/iPad screenshots remain the baseline.
- Existing campaign has 28 app languages, 27 matching ASC locales and 29 retained store entries with es-MX/zh-Hant. Recheck current ASC locale availability before applying the existing Filipino fallback.

## 5. Release acceptance and submission — NOT RUN

- Read-only ASC snapshot is saved privately in `reports/ios-duo-20261011/asc-baseline.json`.
- Snapshot already contains an iOS 1.2.49 READY_FOR_REVIEW draft and highest uploaded build 77. Readback describes localized App Store information updates and binds build 77; it is not this Duo candidate. Do not overwrite that draft or bind its build without establishing its scope. No version/build has been allocated for Duo yet.
- Preserve current titles, subscriptions, prices, regions, privacy and legal text. Add only the confirmed Duo support description/release-note changes and new screenshot sets.
- Run targeted suites after each fix; one full unit pass on the frozen candidate, plus required actual regional playback evidence and Duo resize verification. Do not multiply live generation by every UI language.
- Archive immutable final source, verify all four products and 28-language resources, upload, wait for the exact build to be VALID / APP_STORE_ELIGIBLE, apply intended metadata and complete review submission/readback.
- Report PASS / FAIL / NOT_RUN separately; simulator results do not constitute physical Duo testing.

## Official references

- https://developer.apple.com/iphone-duo/prepare/
- https://developer.apple.com/xcode/system-requirements
- https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
- https://developer.apple.com/news/?id=kkphp5qo

This is the execution checkpoint, not a completed acceptance report. Resume the first unfinished stage rather than repeating completed checks.

## Restart checkpoint

- Work saved in branch `codex/ios-duo-adaptation`; application source unchanged. Xcode 27.1 is installed and signature-verified at `/Applications/Xcode-27.1.app`.
- First action after restart: read `sw_vers`, verify the requested macOS update completed, and launch Xcode 27.1. Then finish SDK/runtime setup, switch developer tools and remove the authorized superseded 26.6 application.
- Resume stage 2 only after recording the new toolchain/runtime status. Stage 2–5 are not accepted or submitted.

- Installer invoked through System Settings for **26.7.1** (not the separate macOS 27 offer). Current gate: the system password sheet requires the user to enter their Mac login password locally. User has already authorized installation/restart; do not ask again. No credentials were requested in chat or stored.

## Post-restart progress

- User confirmed the restart; `sw_vers` verifies 26.7.1 / 25G241. Free disk space is approximately 64 GiB before downloading the new runtime.
- User separately approved the Xcode and Apple SDKs Agreement at the actual dialog; accepted through Xcode. Shared components installed, `-checkFirstLaunchStatus` succeeds, and `-showsdks` lists iOS 27.1.
- Official iOS 27.1 Simulator (24A94232), approximately 7.85 GB, finished downloading and installing. Existing logged-in 26.5 devices remain intact. Old Xcode 26.6 remains pending removal until simulator setup is verified.
- Exported Apple app-resizability skill locally; its requested subagent audits cover reader continuity, UI surfaces and scene/navigation behavior. Source changes are tracked in the three audit documents below; runtime acceptance remains incomplete.


## Source and regression checkpoint after Xcode setup

- Reader, UI-surface and scene/navigation audits: [reader](duo-reader-audit-2026-10-11.md), [surfaces](duo-surfaces-audit-2026-10-11.md), [scene](duo-scene-audit-2026-10-11.md). Per-view traits and actual bounds replace layout-only device checks. Reader ownership and accepted audio remain stable across resizing; PDF anchor recovery now applies to resized phones as well as iPads.
- The iOS quota sheet selectively includes the reviewed Mac improvement: distinguish unknown balance from confirmed zero, display combined monthly/purchased minutes, and provide a concise native purchase sheet. No pricing or entitlement contract was changed.
- Simulator build with Xcode 27.1: PASS. Focused units: 190 executed, 178 PASS, 12 SKIP, zero failures. The skipped cases include actual StoreKit transactions; these results do not establish purchase or production-service acceptance.
- Existing 26.5 runtime initially conflicted with the still-running Xcode 26.6 Simulator UI. Closing the old Simulator and using 27.1 Device Hub restored actual rotation. Keep logged-in simulator data intact.
- iPad navigation in four orientations and Import text/URL keyboard+rotation: PASS. Legacy compact-window acceptance found and fixed a missing Home import action. PDF and popover runs initially inherited a 375 × 486 floating window; their full-screen test initialization has been corrected without removing playback/zoom assertions. Rerun pending.
- Login form keyboard testing found a genuine compact-sheet scrollability regression. Fix and affected rerun are in progress. Recording-panel acceptance encountered modal interference; this is still under investigation, not PASS.
- Duo capture profile and 28-language release-note addendum are prepared under `store/app-store/duo`. No genuine Duo screenshot exists yet and no screenshot or store metadata has been uploaded.
- Apple's current public ScreenshotDisplayType reference does not enumerate Duo. A September DTS forum answer predates the user's now-visible Duo slot. Resolve the actual current upload path after the first genuine images are ready; do not infer that the current UI slot is unavailable from the older answer.
- Evidence is private under `reports/ios-duo-20261011/`. No release version/build has been allocated, no physical-device package installed and no App Store submission performed for Duo.


### Duo runtime ready

- Actual Duo device: `2F655B89-D1D5-4869-930F-B4AF9C512176`, iOS 27.1 (24A94232). Boot and Device Hub Open/Closed controls are verified.
- Genuine simulator displays: outer 1398 × 2034; unfolded inner landscape 2853 × 2007. `simctl` defaults to the outer display even unfolded, so screenshot capture must explicitly select the expanded screen rather than stretch the default image. The store capturer now selects the active XCUIScreen with native inner dimensions.
- Latest simulator application and test targets rebuilt successfully after import/keyboard/modal fixes. Candidate installed on Duo with the normal Global route and Simplified Chinese UI. User confirmed Global Pro login and all four libraries synchronized on Duo; actual Home shows Kindle, Google Play Books, Kobo and WeRead shelves. Existing logged-in iPad/phone simulators remain intact.
- Post-fix iPad Login keyboard/Pro/cloud-form rotation: PASS. Legacy Library compact destination: core assertion PASS, full-screen restoration helper has a remaining orientation-coordinate mismatch; remaining checks are not accepted until the helper is corrected and rerun.
- Xcode 26.6 removal remains pending system-owned application permissions. Selected CLI/toolchain is 27.1. Do not remove logged-in simulator data to reclaim disk space.


### Fold regression checkpoint — 2026-10-12

- User screenshots reproduced three defects: ordinary outer-screen controls stacked unnecessarily; minimizing a phone-idiom reader kept Home locked sideways; tab-bar visibility preferences allowed both native and custom navigation. Source fixes restore a 72-point single row at widths ≥360, release the minimized reader orientation lock while retaining hidden surface geometry, and centralize tab visibility. System safe-area padding remains intact.
- Build-for-testing PASS. Reader ownership/container focused tests: 64 passed, zero failures. Actual iPad modern compact navigation/selection/import, PDF manual zoom/location through rotation and reader/voice panels: PASS. Legacy compact destination and recording authorization/background-return tests now PASS after correcting the test's full-screen precondition and scrolling the virtualized Settings form. No assertion of document ownership or playback was relaxed.
- Actual Duo: installed without erasing account data. Expanded reader → minimize → close now shows upright Home and one compact navigation bar (`fold-fixed-home.png`). Outer reader shows the single-row playback bar (`fold-fixed-reader-closed.png`). Genuine English Kindle Read ran approximately six minutes and preserved playback/highlights when opening the inner display (`fold-fixed-playing-open.png`).
- Outstanding: minimizing while playing, closing, then reopening the reader exposed a race between the old expand-refocus request and the new viewport recovery. Fix/targeted recheck is in progress; this continuity path is not accepted yet.
- First English genuine store-capture sample started; no completed Duo campaign or App Store mutation is claimed.

### Expanded source coverage — user confirmed 2026-10-12

Duo acceptance includes genuine webpage import/read, uploaded files (PDF, EPUB, and supported text/document formats), and all four connected platforms: Kindle, WeRead, Kobo, Google Play Books. Existing shelf synchronization must remain intact. Each source must cover compact/expanded surfaces, rotation, Read playback/highlights, pause/resume, minimization/reopening and preserved position. Cover Explain wherever the product supports it. A Kindle-only result is not overall acceptance. Record each source separately as PASS, FAIL or NOT_RUN; the current runtime evidence only establishes the explicitly listed Kindle and iPad cases.


### Six-source acceptance checkpoint — 2026-10-12 01:36 CST

- Scope now explicitly covers webpages, uploaded files (PDF/EPUB and the common text/document import path), Kindle, WeRead, Kobo, and Google Play Books. The user confirmed all four Duo shelves are synchronized; preserve their sessions.
- Latest genuine Kindle Read run retained the speaking VM through inner-display playback, minimization, closing to the outer display, and reopening. The outer Home stayed upright with one navigation bar; the reader recovered visible word highlighting without restarting audio. An earlier pause was the genuine book ending, then testing continued from Chapter 3. Evidence: `fold-final-playing-home.png`, `fold-final-reopened-playing.png`, and private reader-refocus logs.
- Two cancellation regressions now PASS: an obsolete stable-page reply or anchor reply cannot continue positioning after task cancellation. `cancelled-refocus.xcresult`: 2 tests, zero failures. Final source/test build succeeds.
- Three genuine public samples downloaded/selected: NASA Solar System Facts webpage, NASA Hubble Focus PDF (76.3 MiB), and Project Gutenberg Alice EPUB. Private manifest records source URLs and hashes. Three-minute Read/Explain with actual Device Hub fold handshake is prepared; not yet accepted.
- WeRead, Kobo, and Google Play Books live test variants preserve genuine sessions/clock/highlight/ink assertions and now wait for actual Open/Closed operations. Ack alone is insufficient: the window size must change. Existing synchronized books were selected from observed shelf accessibility, with no fixture or account reset. Not yet run.
- Native Duo screenshot capture now uses a host request protocol and the actual inner-display framebuffer (2853 × 2007), avoiding XCUIScreen's one-pixel rounding. Genuine Home/library screenshots captured; five-scene campaign remains incomplete. Updated the test locator for the new system-rail BackButton. Home screenshot scrolling is still being verified so Continue Listening does not enter the final campaign.
- Code coverage audit: original 27-file scan has 25 changed source files; the other two are documented false-positive/already-scene-scoped cases. Full independent scene rotation policy remains explicitly deferred in AppOrientationLock; current fold acceptance must not be described as complete multi-window policy migration.

### Live source acceptance — 2026-10-12 02:08 CST

- Genuine NASA webpage: Read **180.61 s** and Explain **181.81 s** observed audio progression, both with real pause/resume. Read survived Open → Closed → Open; Explain preserved its segment, time, block and marks while paused/minimized, closed, reopened and unfolded, then resumed. Native screenshots show aligned word highlighting and original-text annotations on both displays. Source-specific result: **PASS**; this is not acceptance of the remaining sources or the entire release.
- Evidence: private `live-samples/playback-report.json`, `long-sources-v3` test artifacts, `web-read-closed.png`, `web-read-open.png`, and `web-explain-reopened-closed.png`. Application source identity is recorded in `live-candidate-identity.json`; later test-helper-only changes do not alter the tested application.
- EPUB and PDF runs are in progress. Common TXT and DOCX import samples were derived from the downloaded public-domain Alice chapter with provenance and SHA-256 recorded in `live-samples/manifest-common.json`. These still exercise the production import/rendering pipeline and live services, not injected audio or generated UI.
- Test preparation initially failed while scrolling Settings on the inner screen; the outer-screen run successfully disabled the real Auto-play preference but failed while closing an already dismissed sheet. The preference was verified as stored `false`; subsequent setup skips only this completed step. Restore the user's original default Auto-play setting after acceptance. These preparation failures are not counted as live service failures.

### Expanded source acceptance — 2026-10-12 02:34 CST

- Scope includes webpage URLs, PDF/EPUB/TXT/DOCX uploads, and all four synchronized platforms: Kindle, WeRead, Kobo, Google Play Books. Existing sessions and shelves are preserved.
- Genuine Alice EPUB: Read **182.61 s**, Explain **182.51 s** effective audio progression; actual fold, pause/minimize/reopen/resume checks PASS. Additional real inner-screen portrait and reverse-landscape rotation retained live reading/highlight. Evidence is retained in `live-samples/playback-report.json` and `epub-*.png`.
- NASA PDF exposed an actual visual defect: native multiply-blended Read highlights and handwritten Explain highlights disappeared on black backgrounds. A regression using real PDF rendering reproduced two failures on black pages while white pages passed. Translucent normal-blended annotations now preserve visibility on both backgrounds, including OCR rectangles. Focused PDF/image/viewport tests: **28 passed, 2 conditional skips, zero failures**. Native live screenshots `pdf-read-fixed-open.png` and `pdf-read-fixed-closed.png` now show visible paragraph and word highlights. Full PDF live acceptance is still running.
- The earlier combined live run was stopped at the PDF visual defect. Its completed webpage and EPUB rows remain valid; neither the cancellation nor the unfinished PDF row is counted as an overall PASS. Only the affected PDF rendering is rerun after this fix.

### PDF live fix verified — 2026-10-12 02:48 CST

- Read **181.31 s** and Explain **181.05 s** effective playback now PASS. Read retained highlighting through actual Open/Closed/Open; Explain retained segment, clock, block and original-text marks through pause/minimize/close/reopen/open, then resumed. Native PDF screenshots show visible dark-page reading overlays and aligned Explain annotations.
- The combined post-fix test preserved a successful Read result but failed its test-only first-page navigation requirement before Explain began. The retry explicitly selected Explain only and used the real restored body page (paragraph 43); it did not alter account, content or playback state. Evidence: `live-samples/pdf-postfix-report.json` (Read result), `live-samples/pdf-explain-postfix-report.json` and `pdf-explain-postfix.xcresult` (Explain/fold result). Do not label the earlier aggregate test as green.
- Source and binary identity for the PDF fix are in `pdf-fix-candidate-identity.json`; subsequent selected-mode retry changes only the UI test. Integration ancestor check, Safari 28-language package verification and `git diff --check` PASS.
- Chrome read-only inspection confirms iOS 1.2.48 remains distributable, iOS 1.2.49 remains Ready for Review, and the released page/media manager has an empty iPhone Duo group. No store mutation occurred and the API upload enum is still unresolved.

### Common file acceptance — 2026-10-12 03:03 CST

- TXT: Read **47.27 s**, Explain **45.70 s** effective playback. DOCX: Read **46.86 s**, Explain **45.70 s**. These are additional format smoke checks, not three-minute language acceptance claims.
- Both use genuine imported files and live services; both passed actual Read Open/Closed/Open and paused Explain minimize/close/reopen/open/resume with unchanged segment/clock/block/marks. Native images show correct word highlighting and source annotations. `common-files-live.xcresult` and `live-samples/common-report.json` PASS.
- The second webpage sample is an original Chinese science article from the Chinese Academy of Sciences. Language detection selects `zh` and voice `zf_001`. Its sentence-level display follows the existing `TTSHighlightPolicy` for Chinese/Japanese; do not describe this as word-level timing or change the established timing policy as part of Duo layout work. Three-minute Read/Explain acceptance is still running.

### Chinese webpage duration boundary — 2026-10-12 03:16 CST

- The real Chinese article completed normally at paragraph 25/26: `readFinished=true`, no playback error. Directly sampled playback totals **167.82 s**, plus ongoing speech during both actual fold handshakes, whose time is deliberately excluded. Detection selected `zh`, voice `zf_001`; sentence highlighting, pause/resume and both fold transitions were observed.
- The optional 180-second test failed after normal completion because its generic Read watchdog treated the completed source as a stall. The failure/result remains preserved; **do not claim this exact 180-second gate passed**. The test now reports normal early completion explicitly instead of a player stall. Keep this useful full-article supplemental coverage without repeating an already completed reading solely to fill the conservative timer; the English webpage already met the 180-second gate.
- Evidence: `chinese-web-live.xcresult`, `live-samples/web-zh-report.json`, `chinese-web-observations/99031E04-865D-4665-81EC-956773F22B66.json`. Xcode subsequently hung collecting optional `simctl diagnose --timeout=600`; that diagnostic child alone was terminated after four minutes, allowing Xcode to finalize the actual test evidence. Future UI runs retain screenshots/metrics but disable this optional verbose system diagnostic collection.
- Chinese Explain is rerunning independently. The new Kindle Duo-specific Read/Explain fold acceptance helper builds successfully and preserves all genuine session, audio-clock and ink checks; no product source changed for this helper.

### Chinese webpage Explain verified — 2026-10-12 03:24 CST

- Actual Chinese Explain passed **180.04 s** of sampled playback and preserved its segment, time, block and 20 original-text marks through pause/minimize/close/reopen/open/resume. `chinese-web-explain.xcresult` and `live-samples/web-zh-explain-report.json` PASS; native `chinese-web-explain-reopened-open.png` shows aligned source highlights and circle marks.
- The earlier Chinese Read duration boundary remains as documented; this Explain success does not relabel that 167.82-second Read run as a passed 180-second gate. Four-platform acceptance is now next.

### Kindle compact controls and fold checkpoint — 2026-10-12 03:37 CST

- The first Kindle fold run exposed missing accessibility IDs/state on the existing compact landscape controls. Audio remained active, but the outer-screen controls were not consistently identifiable to assistive technology or XCTest. Empty/Read/Explain controls now expose the same IDs and status as their expanded equivalents; Explain planning reports loading. No click action or playback ownership was changed.
- The second run passed actual Read Open → Closed → Open with the same live session and forward clock/highlight. Explain generated real marks, paused and minimized. Device Hub's CUA connection then lost its accessibility tree and rejected the visible Closed-button action with `noWindowsAvailable`; no fold acknowledgment was fabricated. `kindle-fold-live-v2.xcresult` retains this 180-second handoff timeout and is not an aggregate PASS.
- CUA session reset restored the actual window controls. The incomplete Explain fold section will run independently; completed Read evidence remains valid. Independent source review found no PDF rendering lifecycle regression and identified the planning accessibility state correction included above.

### Kindle live fold accepted — 2026-10-12 03:52 CST

- Read fold evidence remains the completed Read stages in `kindle-fold-live-v2.xcresult`. Explain-only `kindle-explain-fold-v3.xcresult` now PASS: real marked audio paused/minimized, actual Closed, reopened on outer, actual Open, same VM/segment/time (±0.4 s), marks/shown/ink restored, then audio resumed and paused successfully.
- The handoff helper now waits only on the uniquely identified filesystem acknowledgment; its previous repeated Amazon-dialog AX queries interfered with the external Device Hub controller on the minimized shelf. Actual viewport-change and playback assertions remain mandatory. The initial Explain-only retry also needed to use the real shared empty-console button before a VM exists; no product session or audio was injected. Earlier incomplete/failing bundles are preserved and are not aggregate PASS results.
- Application source remains digest `289066219fcbd29c8c8d208b57f0383079ed4b85b4bab9ed3f96b5182f7fa2be`; subsequent platform resume assertions are test-only.

### Google Books pagination defect — 2026-10-12 04:15 CST

- The genuine Google Books run reached the synchronized book and passed the first physical fold. Natural page continuation then stalled at 7.095416 seconds of a 10.368-second audio item, without a user Pause. Same VM/session/item remained active. Evidence: `google-books-fold-live-v2.xcresult` and `google-fold-diagnostics/reader-pagination-20261012-035531.log`.
- Root cause: page paint acknowledged before AVFoundation delivered its artificial endpoint notification. The acknowledgement saw `suspended=false`; the later endpoint was correctly excluded from real completion but did not resume the now-stopped decoder. `AudioPlayerService` now retains an item/session-bound acknowledgement, resumes only the same eligible decoder, preserves successor-page limits and clears receipts on media replacement. No seek or new user Play intent is introduced.
- A deterministic real-AVPlayer ordering regression reproduced the old failure (clock stuck at 0.35, natural completion never delivered), then passed with the fix. Successor-page protection also passed. Pause/sleep/new-owner assertions passed; an invalid global-interruption injection into an unregistered isolated player was removed rather than counted as coverage.
- Review exposed an additional pending-play appearance window: the published playing state may lag an already requested native Play. Appearance suspension now includes retained play intent, using the existing session/intent-revision resume handle. A separate real-clock regression checks suspension, normal restore and user Pause priority. Affected audio/pagination tests and genuine platform reruns remain in progress; prior source acceptance is historical until mapped to the final candidate.

- Pagination suite: **86/86 PASS**; ownership **6/6**, streaming-pause **9/9**, sleep **8/8** PASS. One older initial-play readiness test exceeded its five-second cold-start wait in the combined run, whose aggregate remains failed; its unchanged two-test class then passed on the final build. Final appearance/endpoint focused rerun **6/6 PASS**. Application digest: `bf8e317e526803fe09c1fc3da2f3a1438d10d356efa09c039e566e87436e96f4`, retained with binary hashes in `audio-page-ack-candidate-identity.json`. Genuine Google Books revalidation is now running.

### Google resize/turn ownership fixed — 2026-10-12 04:35 CST

- The first audio-fixed live rerun passed the previously stuck artificial endpoint and naturally completed its audio item. A subsequent expansion exposed a separate page-turn ownership race: an older resize refresh committed the next physical page without its automatic turn identity, so the native bridge correctly rejected it and reached `anchor_ack_timeout`. The failure is retained in `google-books-fold-postfix.xcresult`; successful TTS responses exclude a network/TTS cause.
- The Google web reader now retires an obsolete resize settlement when an automatic turn takes ownership and ignores an unowned refresh while that turn is pending. Native identity validation remains unchanged. Real headless DOM regressions reproduced the failure then passed both stable-geometry and native-paint paths, including stale-frame rejection and one physical click/commit.
- Generated bundles use the clean, previously documented extension commit `9694b2c3dd368b959012309cadf508ab2cad4b67`, avoiding unrelated changes in its current checkout. Independent source/generated-diff review and final Google bridge/contract/WebReader evaluation tests PASS. Final application identity: `7367ef358f56782061a4943185483ccc672971fa78f982366d5c780d34b38c1b`. Real Google Books fold revalidation is in progress.
- Kobo currently stops at a real Cloudflare CAPTCHA; one-time authorization is pending, with account/shelf intact. WeRead first opened a recommendation page; the live helper now chooses its real body chapter before requiring readable text. Neither is claimed as accepted.

### Final-source platform Read checkpoint — 2026-10-12 04:50 CST

- Google Books completed genuine Read Open/Closed/Open with the same VM, forward audio, two natural page turns, visible words, then paused source/time preservation. The remaining test failed at the first font adjustment because its WK button was reported hittable outside the clipped scroll panel; video shows the font controls were not visible. No font change was demonstrated, so this is not accepted appearance coverage. The test now scrolls within the real panel, requires visible control bounds, and verifies the provider’s displayed font/line-height percentages change and restore. Body AX is suppressed while the provider modal is open, so hidden body elements are not used as an assertion.
- WeRead reached the real first chapter and continued through four natural page turns and Open/Closed/Open with the same VM and visible sentence highlighting. The old cross-fold assertion rejected a normal page-local segment reset from `4-0` to `0-0` after the automatic turn counter advanced from 2 to 4. The corrected assertion also requires a new committed page, no pending turn, and ready state; same-session/audio/highlight checks remain. Failed aggregate results are retained rather than relabeled.
- Device Hub showed the outer shell upside down, but WeRead native screenshots and AX independently show an upright `466×678` app. Duo device configuration has native rotation 0° on the outer display and 270° on the inner display. Test setup/teardown no longer inject whole-device portrait into Duo; a real Device Hub rotation established an upright outer screen and normal unfolded inner screen. Product orientation masks remain unchanged.
- Remaining-phase configuration runs Appearance and Explain without repeating accepted Read stages. This source's page acknowledgement change is called only by WebReaderBridge, and pending-reader-appearance suspension only by the Kindle container; prior native webpage/PDF/EPUB/TXT/DOCX import/render evidence is preserved and shared audio regression results supplement it.

### WeRead source-reveal and compact controls verified — 2026-10-12 05:20 CST

- A genuine Explain run returned five marks but painted none. Source review and a production-script DOM regression reproduced synchronous native-paint reentry before `revealBusy` was set. The native reveal branch now claims its busy state, deadline and bounded attempt before calling `turn`, and restores the previous state when a turn is rejected. The new fixture passes both immediate paint and four rejected-attempt recovery, preserves source identity, and ultimately paints only on the correct page. No provider/vendor bundle or native identity checks changed.
- Post-fix genuine WeRead `weread-explain-reveal-fixed.xcresult` PASS: font increase/restoration, visible Explain ink, paused/minimized Closed, reopening on outer, Open, retained VM/segment/time/mark IDs, resumed audio, and manual next page while paused. Prior real Read fold/page-continuity evidence is retained alongside native glyph/reflow regressions.
- Google real appearance values changed/restored and visible Explain ink passed. The following fold test found compact mini-player title height34.333pt. Title, play and close hit targets now remain44pt in compact layouts; visual bar height grows only4pt. Post-fix Google Explain fold is running. The earlier appearance run timed out awaiting host fold control and is preserved as an aggregate failure.
- `weread-pdf-focused.xcresult`: **4/4 PASS**, covering previously conditional Finnish/Czech PDF fixtures and native WeRead glyph/Canvas reflow. Latest application digest `695b632e9693eb20a52bcc369c556c658ea804ff4b492c092193245a2ea7ac92`; only WeRead reveal and mini-player hit targets differ from the preceding candidate.
- Screenshot preparation now skips artificial Duo orientation injection and uses the stable Home identifier across languages. Capture still requires real unfolded951×669 app geometry and2853×2007 native pixels. Continue Listening exclusion and all five scenes remain required; no finished140-image campaign or submission is claimed.

### Google Explain recovery and store sample checkpoint — 2026-10-12 05:56 CST

- Full genuine Kindle Read/Explain fold acceptance passed on candidate695b (`kindle-final-source-fold.xcresult`,408s). Google-only recovery changes below do not touch Kindle.
- Google Explain could retain paused audio but lose source ink when expansion reset the provider to an earlier spread with no visible source neighbors. Native bridge now reuses the existing verified exact-source recovery only for Google, preserving frame/signature and turn ownership. Missing-source refreshes retain a three-attempt budget; the latest mark actually mapping a visible UTF-16 DOM fragment releases it. Kobo and generated bundles are unchanged. Application digest `a98cfb24fd2773354c36527cde099622ad8f2da99a2790eb47d3536ade0d08e3`.
- Real WK bridge regressions reproduced the prior source-recovery failure. After fixing fixture timing to wait for the provider420ms commit rather than180ms, all8 targeted checks pass across `google-explain-recovery-green.xcresult` (7 completed passes, aggregate failure retained) and `google-explain-missing-green.xcresult` (1/1). Checks include two successive successful recoveries, missing/repeated/short source guards, paused session/clock preservation, frame/baseline ownership and resize classification.
- Genuine Google Explain Closed/reopen/Open now restores visible source annotations and preserves the same paused session and clock. The final resume/manual-next test is still completing; do not claim full live acceptance yet. Native `google-explain-recovery-closed.png` and `google-explain-recovery-open.png` show correctly anchored marks.
- Five genuine English Duo scenes captured and rendered as opaque2853×2007 files. The home-only recapture `store-home-en-v5.xcresult` passes with every Continue card above the visible viewport; native home image visually reviewed. `render-qa-duo-en.json` records source/output hashes and no copy overflow. Only English is currently complete; no140-image campaign or App Store submission is claimed.

- 06:02 CST: `google-explain-recovery-live.xcresult` **PASS**, including both physical folds, source ink, retained paused session/time/mark IDs, resumed audio and manual next while paused. Xcode added repeated60s animation-notification waits after unfold; these are test-driver delays and are retained in the765s aggregate. Eight source paths now have scoped evidence; Kobo remains unverified behind CAPTCHA.

## 2026-10-12 campaign and release checkpoint

- Application source is frozen at `af94c512cfd9230cb796ef02cf005c5721a1dfc5`, manifest `a98cfb24fd2773354c36527cde099622ad8f2da99a2790eb47d3536ade0d08e3`. The full voice/TOC and reader integration ancestry checks pass. Subsequent screenshot processing, metadata proposals and this checkpoint do not change application files.
- Eight languages have all five genuine Duo captures and rendered images: English, Simplified Chinese, Arabic, Japanese, German, French, Spanish and Brazilian Portuguese (40 of140). Native capture assertions require the active inner-display window and2853×2007 pixels; render checks require the same dimensions, opaque PNGs, hashes and in-bounds copy. Representative images across all five scenes were visually reviewed. The remaining20-language campaign is in progress; no remote screenshot upload is claimed.
- A read-only snapshot of the existing1.2.49 draft contains29 ASC localizations. Local Duo proposals preserve the original description paragraphs and legal links, insert the localized Duo paragraph and prepare new release notes. Names/subtitles, keywords, promotional text and existing iPhone/iPad assets remain untouched. Maximum proposed description length is3672 characters. Filipino remains a complete local-artwork/copy deliverable without an ASC locale.
- The current ASC UI displays the empty Duo slot but disables uploading while1.2.49 is attached to its unrelated review draft. A read-only API filter probe did not expose the Duo enum. Discover the actual supported type from the first authorized UI upload/readback once an editable target exists; do not invent an enum or alter the other draft.
- The development-signed physical candidate built successfully with SDK27.1 and passed strict signature verification. It is still1.2.48(75), solely for source-matched acceptance; no release number or build has been allocated. Installation/playback remains NOT_RUN because Xcode reports the physical phone locked. One user request for USB/unlock is pending; existing accounts are preserved.
- The first full-unit attempt on a newly booted iOS27.0 simulator had41–44-second WebKit process starts, three AO3 fixture failures and a stuck Kindle fixture. It was interrupted and retained as infrastructure triage, never reported green. A full run on the established iOS26.5 test simulator is in progress, with one delayed-shelf fixture failure to investigate. These fixtures do not replace real source/core acceptance.
- Removed only this task's reconstructable compiler intermediates/module/index caches after builds finished, recovering approximately3GiB. Built products, signed package, authenticated simulators, shelves and all acceptance evidence remain. Superseded system-owned Xcode26.6 removal is still pending its existing permission limitation.

### Frozen candidate regression follow-up — 2026-10-12 06:59 CST

- The completed iOS26.5 frozen unit run contains2,213 passes,26 explicit skips and2 failed cases (`frozen-full-unit-265.xcresult`). It is not an all-green run. The delayed Google shelf test subsequently passed unchanged by itself and its complete six-test class passed unchanged (`binding-focus-unchanged.xcresult`, `binding-suite-unchanged.xcresult`). No production or test assertion was modified. WebKit suspension messages occurred in both outcomes and are not proof of the root cause.
- The other case audits14,592 language rows and exceeded the runner's imposed120-second allowance. A focused600-second run is in progress with unchanged accuracy/misroute thresholds. Previously documented Indonesian/Malay conservative detection limits remain explicit; do not imply this is a new OCR or playback failure.
- Eighteen languages now have five genuine Duo raw captures each. The third25-image batch is rendering; the final10-language campaign remains in progress. All29 localized Duo metadata proposals passed exact preservation of the original description/EULA, intended-field checks and length limits. These are local files, not a store upload.


### Local deliverables and remaining acceptance — 2026-10-12 07:50 CST

- All **28 languages × 5 Duo scenes = 140 local images** are complete. Each output is an opaque native-size2853×2007 PNG; count, scene order, layout bounds and SHA-256 were validated. Representative visual review includes the final Turkish Home and Vietnamese Quick Import, and Arabic/Hebrew UI around English content retains left-to-right book progression. Home artwork begins at Kindle, with Continue cards outside the captured viewport. `duo-artwork-manifest.json` and `campaign-status.json` retain file-level evidence. No image has been uploaded.
- All29 ASC metadata proposals are locally prepared and validated against the original description/EULA and field limits. `duo-upload-plan.json` maps the five files per supported ASC locale, preserves the released Spanish-Mexico→Spanish and Traditional-Chinese→Simplified-Chinese artwork fallback policies, and keeps Filipino's five files as a local deliverable because ASC has no Filipino locale. The target version and actual Duo API display type remain unresolved; the plan performs no writes.
- The bounded native audit completed in247.416s with the same two pre-existing conservative automatic-detection coverage failures as release1.2.48: Indonesian0.5855263157894737 and Malay0.5361842105263158. There were no misroute assertion failures or newly failing coverage assertions. Thresholds were unchanged. These values describe this language-classification audit, not OCR accuracy or TTS availability. The full run remains honestly reported as2,213 passes,26 skips and2 initial failed cases; unchanged Google hydration focused/class reruns passed.
- The user-requested source matrix includes webpage, PDF, EPUB, TXT, DOCX, Kindle, Google Play Books, Kobo and WeRead. Eight paths have the scoped live evidence listed above; TXT/DOCX are45-second format checks rather than three-minute language coverage. Kobo still has no playback acceptance because a real Cloudflare challenge requires the already-requested confirmation.
- A separate actual-UI file-entry check opened Home→Quick Import→Upload file, browsed the system picker and cancelled normally. Recents and On My iPhone were empty; a self-authored574-byte TXT rendered in Safari, but downloading did not provide a selectable file. Safari's system Share opened CastReader's localized extension and its Add action dismissed, but inbox import/playback was not verified. Neither route is labeled an end-to-end PASS. Prior file tests call the real DocumentImportPipeline through a DEBUG launch argument with security-scoped access disabled; they prove format/render/playback/folding, not system-picker permission/handoff. See `file-entry-ui-status.json`; finish the short handoff check on an available file-provider/device environment without repeating accepted long playback cases.
- Restored only the original non-sensitive preferences `interfaceLanguage=zh-Hans` and `auto_play=true` with the app stopped, then relaunched. Exact preference comparison confirms no other persisted key changed. Chinese Home and a paused Kindle mini-player were visually verified; no account or library was cleared. The temporary capture/file servers have exited.
- Source remains `af94c512cfd9230cb796ef02cf005c5721a1dfc5`, application digest `a98cfb24fd2773354c36527cde099622ad8f2da99a2790eb47d3536ade0d08e3`. Draft review: https://github.com/vinxu/CastReader/pull/7. The signed physical candidate is still1.2.48(75), not installed/accepted. Final CN/Global actual-device core playback, Kobo, file-picker handoff and an editable ASC target remain outstanding. The unrelated1.2.49 review draft is preserved. No new version/build, archive upload, review submission or completed delivery is claimed.

### Actual file-picker handoff accepted — 2026-10-12 08:00 CST

- Prepared a self-authored, non-private 574-byte TXT in the Duo simulator's existing local File Provider storage. The production Home → Quick Import → Upload file → Browse → On My iPhone UI displayed the file, and selecting it opened all ten paragraphs in CastReader. Selection used the system picker and normal security-scoped import path; no debug document launch argument or source change was used.
- Actual Play advanced word highlighting through the text to its final paragraph. Returning Home showed the imported document and the completed-playback state. The native screenshots `file-picker-read-highlight.png`, `file-picker-read-final-paragraph.png` and `file-picker-read-completed-home.png` plus fixture hashes are recorded in `file-entry-ui-status.json`. This is a short entry/handoff smoke test, not a three-minute language-coverage claim. The earlier Safari-share inbox route remains unverified and is not needed to establish this picker result.
- Compared the actual English iPad and Duo Home artwork: Duo uses the same cream/orange palette, brand and caption hierarchy, five-scene order and iPad caption source, with genuine Duo UI and native dimensions. It is not a resized iPad screenshot. The 140 existing deliverables require no recapture for this test-only checkpoint.
- Chinese interface and original autoplay preference remain intact; the test document finished naturally. No account or synchronized shelf was cleared. Application source and digest remain unchanged. Kobo and final physical core acceptance still precede any upload/submission; the existing1.2.49 ASC draft remains preserved.
