# iPad adaptation execution

User authorized the complete plan on 2026-09-21, with a simulator UI gate after each module and mandatory rotation support. No App Store submission is requested.

- Branch: `codex/ipad-adaptation`, independent managed worktree.
- Base: `8298f84` / application source `1ce1e56` (1.2.42 build 64).
- Required ancestor gate passed before edits.
- Primary simulator: iPad Air 11-inch (M3), iOS 26.5, `BFCF61DE-9C45-4467-8996-6F4E03AE7725`.
- DerivedData: `/tmp/CastReader-iPad-Adaptation`.

| Module | Status | Gate |
| --- | --- | --- |
| 1. Universal configuration, navigation and window geometry | Passed | `module1-live-ipad11-retry-20260921T053304`: navigation + 4 orientations + 14 screen captures; manually reviewed Home, Library, Voice, Settings, import |
| 2. Native readers, rotation, semantic position and marks | Passed | Text/EPUB/PDF/scanned PDF/photo/DOCX/web Read and Explain; final zoom gate `module2-zoom-verified-20260921T062423` 3/3 passed |
| 3. Commercial readers, offline and YouTube | Passed | Live Kindle final gate 174/174; platform fixtures 86/86; offline 3/3 and YouTube rotation passed |
| 4. All surfaces, import, voice, account and presentations | Passed | Actual imports/forms/recording UI; final overlay gate 3/3 and Kindle dismissal 1/1, screenshots reviewed |
| 5. Playback ownership and multiple windows | In progress | Ownership and lifecycle tests + multiple scene UI |
| 6. Input, accessibility, performance, upgrade and regression | Pending | iPad sizes + iPhone regression + release resource audit |

Passing simulator fixtures is evidence of UI and deterministic behavior only. Live commercial accounts, actual purchase authorization, hardware camera/Pencil/audio routes and production audio require separate evidence; never report these as passed from fixture screenshots.

## Execution notes

- User completed CastReader sign-in and Kindle binding on the 11-inch simulator. Preserve its app and keychain data.
- User requested a single simulator. The temporary 13-inch simulator was shut down; all subsequent verification uses the existing 11-inch simulator. The cancelled 13-inch run is not a pass.
- Screen captures use `XCUIScreen.main.screenshot()`; `app.screenshot()` cropped landscape captures on this runtime.
- The first real-account navigation run was interrupted by the system review dialog. The test now dismisses “Not Now” without submitting a rating. The rerun passed.
- The reviewed Home includes the actual Kindle shelf and saved listening entry. Production Read/Explain verification remains in module 3.
- Test reports and account screenshots stay local and are excluded from source control.

## Module 2 investigation

- Text/EPUB reading columns now use the container proposal (800 pt maximum on iPad), with native glyph geometry invalidation and semantic Explain range following.
- Native text and EPUB four-orientation Read/Explain tests passed in `module2-native-20260921T054044`; that overall run failed because PDF/photo/web lost the paused anchor and DOCX Explain centered the whole long paragraph. Those failures remain recorded and require a fresh pass.
- The surface preference reported 0x0 on this runtime, while iPad stayed in regular vertical size class. Recovery now observes the reader GeometryReader directly.
- Web marks retain their IDs and deterministic seeds while recomputing SVG geometry after resize; a completed drawing is not replayed.
- Web bundles are rebuilt against readout-desktop commit `2f060971136c61b3b7f407a155fbbb65ed43ce80`, exported to `/tmp/CastReader-iPad-WebDependencies`. The currently dirty sibling checkout changed extraction behavior, so it was not used. Node dependencies come from the existing CastReader installation.
- `WebReader/build.mjs` accepts `READOUT_DESKTOP_SOURCE` and normalizes generated module paths for reviewable worktree builds. The production bundle continues to exclude fixture-only APIs.
- UIKit sizing references: [UIViewRepresentable.sizeThatFits](https://developer.apple.com/documentation/swiftui/uiviewrepresentable/sizethatfits(_:uiview:context:)), [PDFView.currentDestination](https://developer.apple.com/documentation/pdfkit/pdfview/currentdestination).

- `module2-recovery-20260921T054809`: PDF/photo/DOCX/web all passed (4 tests); reviewed their landscape Explain images and verified exact underline placement.
- `module2-final-20260921T055514`: 80 passed, 1 skipped (optional private PDF file), 1 failed (new PDF pinch/rotation test). Text, EPUB and mixed scanned PDF rotation/marks passed. The manual PDF zoom test remains the module gate; subsequent diagnostic runs retain their failures.

- PDF pinch investigation: the iPadOS 26.5 simulator delivered `.began/.changed/.ended` and increasing pinch scale, but both PDFView.scaleFactor and its UIScrollView.zoomScale stayed at 1.32258. The same failure reproduced with the original automatic scaling policy (`module2-pdf-baseline-20260921T060800`) and with viewport probing suppressed during the gesture. Recovery observes the existing recognizer and uses the public [PDFView.scaleFactor API](https://developer.apple.com/documentation/pdfkit/pdfview/scalefactor) only if native scaling stalls; it preserves the page point under the fingers. Resizing is handled by the outer container without overriding PDFKit's internal layout. Pinch in/out and rotation must pass before this is accepted.

- Final module 2 zoom gate: `module2-zoom-verified-20260921T062423`, 3/3 passed. Reviewed PDF word-follow at 2.03×, photo zoom at 2.03×, and PDF manual-browsing landscape/portrait screenshots. Manual PDF center remained page 91, y≈431.8–431.9 points; zoom-out passed. Read/Explain page-space marks and paused audio identity remain unchanged. Prior unit gate: 80 passed, 1 skipped for unavailable optional private PDF, with the single zoom failure now resolved.

## Module 3 investigation

- iPad no longer inherits the iPhone-only portrait locks for WeRead/YouTube or the minimized-reader orientation lock. Kindle viewport observations now use the measured reader surface directly, retaining the existing page-identity recovery.
- YouTube keeps the same transcript session while changing between stacked and side-by-side artwork/transcript layout; artwork height and transcript line length are bounded.
- Offline reader hiding uses its own container height. Original-page zoom retains relative scale and normalized position when the sheet/window resizes.
- `module3-offline-youtube-20260921T063012`: YouTube rotation/minimize/reopen passed and landscape screenshot reviewed. Three offline tests failed because the center of a wide plain book row fell outside its text/image hit region. Added a rectangular hit region to the entire book row.
- `module3-offline-row-recovery-20260921T063432`: all three offline tests passed, including real system speech start/pause through mini player, full tall-page fit, speed selection, pinch zoom, landscape/portrait scale preservation. Reviewed whole-page landscape, speed sheet, zoom sheet, and mini-player captures. The tall synthetic page contains a large empty middle region, which remains empty when pinching around its center.
- `module3-platform-viewports-20260921T063845`: 86/86 tests passed. Includes actual WKWebView reflow at 400, 820, 1180 pt; Kobo same-origin iframe marks, O'Reilly semantic-page marks, Google Books refresh-vs-manual-turn separation, WeRead paused Read state and DOM highlights/marks, Kindle font/viewport ownership and page-turn evidence. Reviewed the four wide-viewport screenshots. These are local page-contract fixtures, not live logins to Kobo/O'Reilly/Google/WeRead.

- Live Kindle `module3-kindle-live-final-20260921T065021` completed its UI assertions, but manual screenshot review found a missing Explain mark after rotation. It is **not** the module pass. The initial assertions checked retained model marks too early, so the gate now requires visible SVG ink, stable geometry, unchanged VM identity and paused audio time.
- The previous iPhone layout restart stopped the active Explain session on iPad rotation. The iPad path now preserves the VM/audio, matches original words into a fresh OCR projection and redraws the existing mark seeds. Sparse projected paragraph IDs must be resolved semantically rather than as array offsets. New geometry coverage checks prevent drawing a different paragraph.
- The miniature reader title is now a real accessible button with a 44 pt target. The earlier “missing mini player” test was a query/type mismatch; screenshot evidence showed the player was already visible.
- `module3-kindle-semantic-reflow-20260921T065358` preserved the Read VM and restored word highlighting, but its pause action did not pause while the generic start path remained gated. Read Pause now directly invokes the existing cancellation/pause action. Awaiting the stronger combined gate.
- `module3-kindle-adjacent-reflow-20260921T071713`: 6 tests passed. Real Read retained its VM, confirmed a native adjacent-page turn and reprojected the spoken word. Explain paused time/VM/visible ink survived portrait and minimized-landscape expansion. Screenshot review found that a hyphen join truncated the last part of a mark, so this was not yet the final module pass.
- `module3-kindle-word-alignment-20260921T072510`: 97/97 passed (Kindle layout/navigation/ownership/turn evidence, animation clock, appearance holds, OCR geometry and live UI). Reviewed landscape/portrait Explain images: the same full sentence is marked at its new position. Projection now uses sequence alignment for split/joined tokens and missing OCR words; native mark geometry keeps original word identity and allows multiple line boxes per word.
- Follow-up work before completing module 3: preserve the first unread/unexplained word across a changed page boundary, handle short dialogue paragraphs using neighboring context, and prevent stale pre-reflow routes/queued page handoffs from being used. A deliberate audio hold currently protects the semantic anchor while Kindle/OCR reflow; its latency is not a continuous-audio performance pass.
- `module3-kindle-continuation-20260921T074024`: the Read/Explain rotation UI gate and ReadingResume/OCR tests passed. New source-word cursor tests verify both exact seeking and rejection of changed text; the longer natural-completion path was still pending.
- `module3-kindle-live-continuous-20260921T074501`: the longer real Read run failed. Crossing to an unprojected new-layout page paused during an audio-item transition; the appearance hold had no resumable active item. The replacement preserves an image with native word/mark overlays while audio continues and matches the latest playback anchor into new OCR geometry. Natural completion is deferred until geometry settles, then resumes the first unread source word (or next actual page). Pausing during recovery retains the user pause intent.

- Final module 3 gate `module3-kindle-final-gate-20260921T080128`: 174/174 passed, zero skips. Manually reviewed landscape word highlighting, natural continuation after reflow, portrait Explain mark and minimized/expanded landscape mark. Rotation keeps audio advancing, the same Read VM until natural completion, and the same paused Explain VM/time/ink. The native snapshot overlay covers OCR recovery without pausing the live audio. Source-word resume is tested with actual synthetic audio seeking; live natural continuation reached the next page. Natural completion of a full live Explain page after reflow has not been separately timed; its continuation boundary and mark-drain contracts have unit coverage.

## Module 4 investigation

- Forms use NavigationStack, reader settings use anchored iPad popovers, TOC panels have bounded side widths, voice panels are being checked against available height including the keyboard, and long voice/Pro surfaces have centered columns. Recording introduction and controls can scroll in short windows. The photo-library fallback uses PHPicker with one-shot/main-thread delivery and teardown cancellation.
- `module4-surfaces-20260921T081428`: 3 passed, 2 failed. Text/URL draft + keyboard + rotation, Files, old-system sidebar and the timer/Aa workflow passed; reviewed their screenshots. Two new tests used stale UI selectors (the adaptable sidebar exposes cells and the personal tab is now “My Voices”). Correcting those selectors and adding photo picker and player voice-panel coverage before the next gate.
- API references: [PHPickerViewController](https://developer.apple.com/documentation/photosui/phpickerviewcontroller), [SwiftUI popover](https://developer.apple.com/documentation/swiftui/view/popover(item:attachmentanchor:arrowedge:content:)).

- `module4-complete-surfaces-20260921T081949`: 3 passed, 2 failed. Reviewed recording intro/control landscape and portrait images. The simulator reports VisionKit scanner support despite having no usable camera, leaving the native scanner black; availability now requires actual camera support. The voice-panel test attempted to use the language-gated control before starting any reading; it now prepares and pauses real local fixture audio first. Photo picker landscape screenshot shows the public seeded page and system sample photos; add actual import coverage, not just cancel.

- `module4-workflows-recovery-20260921T082613`: 2 passed, 2 failed. Actual PHPicker → Vision OCR → native photo reading passed in landscape and portrait. Voice-panel assertions passed, but screenshot review caught results behind the keyboard; the root now ignores only the container safe area, and Search dismisses the keyboard. The next gate checks the result row, not only Done. Simulator camera APIs still claimed availability, so simulator fallback is explicit. Privacy-only cloud disclosure now precedes provider configuration checks; this does not claim Dropbox/OneDrive OAuth verification.

- `module4-keyboard-share-cloud-20260921T083521`: account/Pro/cloud forms and both photo entry paths passed. Three failures exposed parent accessibility-identifier inheritance, system share cells rather than buttons, and a nested NavigationStack subtracting keyboard height twice. Cloud test classes requested in this invocation are excluded from the release-baseline test target: zero unit tests ran, so they are not counted as coverage.
- `module4-overlay-confirmation-20260921T084217`: 3/3 passed. Real Kindle TOC/Aa, player voice search (portrait/landscape keyboard and result row), native speed/timer/Aa, and actual system share → CastReader extension → Save all passed. Screenshots manually reviewed; keyboard avoidance measures the intersection in the hosting window and avoids double subtraction.
- `module4-kindle-dismissal-20260921T084631`: 1/1 passed. Closing Aa after rotation returns to fully rendered, paused Kindle text; reviewed the final landscape page. Together with the earlier import, recording and legacy-sidebar passes, this completes the simulator surface gate. Camera capture, purchase authorization and provider OAuth are not represented by these presentation tests.
