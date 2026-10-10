# CastReader 1.2.48 store campaign

This directory contains the reproducible copy and composition sources for the
requested 28-language iPhone and iPad campaign. Each language has five scenes:
connected Kindle shelf, Read Aloud, Explain, Kindle library, and Quick Import.
The Android reference files are frozen inputs; they are not uploaded as iOS copy.

`ios-copy.json` supplies the authored iOS platform, privacy, regional-availability,
and release-note paragraphs. `build-metadata.py` combines those with the reference
and the current public App Store baseline, checks field limits, and emits
`metadata.json`, `asc-metadata.json`, and the reviewable Markdown copy. Existing
names and subtitles are preserved. Shared App Info is not written by these tools.

There are 28 local deliverable languages and 27 matching App Store locales.
Filipino has local files only because Apple does not offer a Filipino metadata
locale. Existing Mexican Spanish and Traditional Chinese entries are retained;
their screenshots explicitly reuse Spanish and Simplified Chinese respectively.
Thus the submitted inventory has 29 locales, each with five iPhone and five iPad
images. The China service catalog remains separate from the international catalog.

`LocalizedStoreCaptureUITests` captures genuine UI with the user's existing signed-in
library and actual playback. It is opt-in and does not inject accounts, Pro,
books, audio, or marks. Raw captures, account-related logs, xcresults, and upload
receipts stay in the private local `reports/ios-release-1.2.48/` directory and are
not committed. Original book content remains in its original language; interface
controls and campaign captions use the chosen interface language.

From the repository root:

```sh
python3 store/app-store/1.2.48/build-metadata.py
node store/app-store/1.2.48/render-screenshots.cjs --ipad en zh-Hans
node store/app-store/1.2.48/render-screenshots.cjs --iphone en zh-Hans
ruby store/app-store/1.2.48/sync-screenshots.rb --profile ipad --locales en-US,zh-Hans
```

Rendering requires Playwright, Chrome, and Sharp. The render tool checks opaque
PNG output, dimensions, text overflow, frame bounds, and hashes. Every output set
also requires visual review before upload. Passing `--execute` to the screenshot
synchronizer performs the intended replacement: retain old images until all five
new images are COMPLETE with matching checksums, then delete the recorded old
images, order the replacements, and read back. Journals permit exact-ID recovery.

`audit-release.rb --build-id <verified-build-id>` checks the actual 29-locale
inventory, exact copy, preserved App Info, review details, eligible build 74, and
the completed regional core-service evidence. Asset upload is not submission.
The release report and project release SOP own the remaining archive and review
gates. Do not run historical full-copy synchronizers over these versioned sources.
