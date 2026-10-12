# iPhone Duo screenshot campaign

The Duo campaign reuses the released 28-language copy and five genuine scenes
from `../1.2.48`: connected Kindle shelf, Read Aloud, Explain, Kindle library,
and Quick Import. As of 2026-10-12, all 28 × 5 local images are complete,
with native-size, opacity, scene-order, hash and layout checks plus representative
visual review. Evidence lives in the private `reports/ios-duo-20261011`
`duo-artwork-manifest.json` and `campaign-status.json`. No images have been
uploaded and no store version has yet been allocated to this candidate.

Capture with `LocalizedStoreCaptureUITests`, `CASTREADER_STORE_DEVICE=duo`, and
`CASTREADER_STORE_OUTPUT` pointing to the private `reports/ios-duo-20261011/raw/duo`
directory. Start the actual Duo simulator unfolded in landscape. Run `capture-host.py --output <same directory> --device <Duo UDID> --display <inner display UUID>` before the test. The host answers uniquely identified capture requests using `simctl io screenshot`, since XCUIScreen currently rounds this display down by one pixel. Both host and test assert the native screenshot is 2853 × 2007; an ordinary iPhone or iPad image
cannot silently pass as a Duo capture. Keep the connected shelf above the
Continue module; book text remains in its original language.

Render the three review samples first. Use the bundled Node runtime/packages returned
by the workspace-dependencies tool (set `NODE_PATH` to its Node packages directory);
`playwright` and `sharp` must resolve before rendering. For the full campaign, use
separate small locale batches and an explicit host timeout covering the batch.

```sh
node store/app-store/1.2.48/render-screenshots.cjs --duo en zh-Hans ar
```

The renderer preserves raw UI pixels, uses the approved side-caption campaign
composition, requires all five genuine captures for each selected language,
and emits opaque 2853 × 2007 PNG files with source/output hashes and layout
bounds in `reports/ios-duo-20261011`. Only after reviewing the three samples
should a new capture/render campaign expand to all 28 languages (140 local images).
The current campaign has completed this sequence; reuse its unchanged outputs.

Do not run the historical 1.2.48 screenshot uploader for this campaign. Its
version ID and device enums belong to that completed release. The current
Apple public ScreenshotDisplayType schema inspected on 2026-10-11 does not
list a Duo enum; discover the supported slot from current App Store Connect
before implementing upload. A read-only Chrome inspection on 2026-10-12
confirmed the actual iPhone Duo tab and optional media-manager group on the
released 1.2.48 page, with no assets present. It does not identify the API enum
or prove upload acceptance. The unrelated 1.2.49 draft remains Ready for Review.
Preserve existing iPhone/iPad sets and any
unrelated draft. No API enum or review acceptance is assumed.
