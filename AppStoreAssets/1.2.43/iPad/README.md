# CastReader 1.2.43 iPad screenshots

These are new iPad assets. Keep the existing nine iPhone screenshot sets (45 images).

## Inventory and order

Each of `en-US` and `zh-Hans` contains exactly five screenshots:

1. `01-home.png` — the real, synchronized home shelves.
2. `02-kindle-read.png` — Kindle *A Journey to the Centre of the Earth*, actual Read playback and word highlighting.
3. `03-kindle-explain.png` — the same book, actual Explain playback and marks on the original text.
4. `04-voices.png` — the voice discovery page.
5. `05-import.png` — the plus menu with the file import entry and supported formats visible.

`raw/` holds original 1640 × 2360 simulator captures. `final/` holds the 2048 × 2732 App Store artwork. `manifest.json` records dimensions, hashes, version/build and application-source identity for every PNG.

## Source and verification

- Candidate: 1.2.43 (65), application source commit `3013b71`; source/config SHA-256 `a08ee45fbac599cf4e21e97fa6f136dcaf9c777e00ef539f14dd1c2ac8b30466`.
- One existing simulator only: `CastReader-iPad-11-Adaptation`, iPad Air 11-inch (M3), iPadOS 26.5, UDID `BFCF61DE-9C45-4467-8996-6F4E03AE7725`.
- Normal signed app with existing user login and linked shelves; no synthetic books or injected audio. Read progress and Explain marks were asserted before capture.
- English capture PASS: local evidence `reports/ios-release-1.2.43/capture-en-20260921T221924/`.
- Simplified Chinese capture PASS: local evidence `reports/ios-release-1.2.43/capture-zh-Hans-20260922T003214/`.
- All ten final images were visually inspected. The whole source screen is proportionally contained in the artwork, including the reader controls. Product UI was not redrawn. The English public-domain book and English explanation remain English in both UI locales.
- These images do not establish testing on a separate 13-inch device. Apple accepts a 2048 × 2732 portrait canvas for its required iPad screenshot slot: [official screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
- Planned iPad locale coverage: explicit `en-US` and `zh-Hans`; remaining version locales use the primary English iPad set. Verify the actual App Store Connect inventory/fallback after upload. These files have not yet been uploaded.

## Reproduction

`KindleLiveAcceptanceUITests/testCaptureIPadAppStoreFiveScreens` is opt-in with `CASTREADER_IPAD_STORE_CAPTURE=1` and `CASTREADER_CAPTURE_LANGUAGE=en` or `zh-Hans`. Run against the existing logged-in simulator and export its five named XCTest attachments to the corresponding `raw` directory. A successful capture test is required; retain failed attempts only as private test evidence.

From the repository root, render the complete real captures:

```sh
node scripts/render-ipad-app-store.cjs en-US
node scripts/render-ipad-app-store.cjs zh-Hans
```

The renderer uses the installed Playwright runtime (override its module path with `CASTREADER_PLAYWRIGHT`) and Google Chrome. The cream background and simple headline treatment follow the existing iPhone material. Regenerate the manifest if any file changes.

After the real-device release gate passes and the pending version exists, `scripts/upload-ipad-app-store.rb LOCALE_ID FINAL_DIR JOURNAL` reads the intended target and prints a dry run. `--execute` resumes the same journal, adding only this release's iPad set; exit 2 means Apple is processing the saved IDs. `--validate-only` checks local PNG files without ASC access. Never use the older iPhone asset replacement script for these iPad additions.
