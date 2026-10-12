# iPhone Duo screenshot campaign

The Duo campaign reuses the released 28-language copy and five genuine scenes
from `../1.2.48`: connected Kindle shelf, Read Aloud, Explain, Kindle library,
and Quick Import. As of 2026-10-12, all 28 × 5 local images are complete,
with native-size, opacity, scene-order, hash and layout checks plus representative
visual review. Evidence lives in the private `reports/ios-duo-20261011`
`duo-artwork-manifest.json` and `campaign-status.json`. The first 29-locale Duo revision is uploaded to iOS 1.2.49; see the release
report for the pending final navigation revision and sixth-image replacement.

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

Use `sync-screenshots.rb` for this combined 1.2.49 draft only. The current
App Store Connect slot is `APP_IPHONE_DUO`; its first six-image revision reached
174 COMPLETE assets across 29 locales. `--replace-folded` stages a reviewed
sixth image before replacing its prior owned revision. It preserves the five
other Duo images and all iPhone/iPad sets.

The final ordinary iPad navigation revision affects only scenes 1, 4 and 5.
Capture them with `CASTREADER_STORE_NAVIGATION_ONLY=1` into the Duo report's
`raw/ipad` directory, then render with `--ipad --navigation-only` and
`--report=<absolute Duo report directory>`. `--replace-ipad-navigation` checks
that existing scenes 2 and 3 match their local hashes, preserves their IDs,
and stages only the three revised navigation scenes before ordering the set.
Both replacement modes support dry-run and locale selection. Always inspect
representative English, Chinese and RTL outputs before upload, and require
exact checksum/order/COMPLETE readback. Neither screenshot completion nor a
draft review is a completed App Store submission; see the release report.
