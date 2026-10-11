# iPhone Duo adaptation and App Store delivery

## Scope and source

- User authorized implementation and acceptance of all five stages: development environment, adaptive UI, reading continuity, 28-language screenshots, and App Store submission.
- Reuse the verified iOS checkout at `/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader`; branch `codex/ios-duo-adaptation` starts at remote `main` / `d48a9af` (iOS 1.2.48 build 75).
- The user authorizes removal of Xcode 26.6 after the replacement download. Keep the working toolchain until the replacement can run on the installed macOS. Preserve logged-in simulators, connected libraries, signing credentials, release archives, and private acceptance evidence.
- Mac 1.2.48 work remains on its own branch. Selectively integrate its shared allowance-sheet improvement; do not replace unrelated iOS reading subsystems or the project configuration with Mac files.

## 1. Development environment — IN PROGRESS

Observed on 2026-10-11:

- Host macOS 26.2 (25C56); Xcode 26.6 (17F113), SDK/runtime iOS 26.5. No Duo runtime installed.
- Xcode 27.1 Release Candidate is available from Apple (2026-10-05). Official page lists a 1.89 GB XIP and requires Apple silicon / macOS 26.6 or later.
- Official download completed in the existing authenticated Chrome session; extracted and installed at `/Applications/Xcode-27.1.app`. Version 27.1, build 27A9275; bundle minimum macOS is 26.6. `codesign --verify --deep --strict` passed and Gatekeeper returned `accepted; source=Apple System`. Launch/SDK setup remains pending the host update.
- XIP: 2,027,369,056 bytes; SHA-256 `038ad29cc2cd87e7762aac596833943000fd3d5fb64be530e2ecdbe5449cd660`. The duplicate downloaded archive can be removed after verified extraction to recover its space; the installed application is retained.
- Software Update offers macOS Tahoe 26.7.1 (25G241), 7,617,861 KiB, restart required. Download-only preparation requested; installation/restart not yet performed. This meets the Xcode minimum without moving to macOS 27.
- Initial free disk space approximately 26 GiB; Xcode.app 3.7 GB, default DerivedData 4.3 GB. CoreSimulator directory reports 39 GB, including mounted runtimes; this is not a promise of reclaimable disk space.

Finish this stage by updating the host, launching Xcode 27.1, installing only the necessary iOS runtime, and confirming a Duo device can boot. Then remove the superseded Xcode application and measure actual free space. A user question requesting permission for installation/restart is pending because that interrupts other applications and agents. Do not treat elapsed time as approval. Old Xcode 26.6 remains selected and usable until then.

The release ancestry check and existing 28-language Safari verification both pass on the unchanged iOS baseline. No Duo application code or screenshots have been marked accepted.

## 2. Adaptive UI — NOT RUN

The source audit found device/size assumptions in 24 Swift files. These are review candidates, not 24 confirmed defects.

- `AdaptiveLayout` and `MainTabView`: choose layout from available space and size classes; retain navigation selection and reader identity when the layout changes. Account for the iOS 27.1 vertical system bars and safe areas.
- Home, library, voice browser, import, login/settings and purchase panels: compact outer display, expanded inner display, landscape, constrained windows, keyboard and large type. Reuse existing localized labels.
- Reader and mini-player controls: adapt to width/height without depending on iPad identity. Keep controls reachable and text unclipped.
- Do not infer platform capabilities (for example, multiple scenes) merely from regular width.

## 3. Reading continuity — NOT RUN

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
