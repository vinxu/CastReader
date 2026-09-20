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
| 3. Commercial readers, offline and YouTube | In progress | Platform fixtures + rotation and restore tests |
| 4. All surfaces, import, voice, account and presentations | Pending | UI workflows and keyboard/sheet validation |
| 5. Playback ownership and multiple windows | Pending | Ownership and lifecycle tests + multiple scene UI |
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
