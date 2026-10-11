# iOS 1.2.49 (77) release record

Status: **READY_FOR_REVIEW — submission blocked by Apple’s two in-flight iOS review limit**, verified 2026-10-11. The build is uploaded, eligible and bound; formal submission was attempted and rejected with HTTP 409. This release has **not** entered WAITING_FOR_REVIEW.

## Scope and source

This release carries the reviewed 29-locale App Store search and description iteration. The store catalog contains localized names, subtitles, keywords, search-query hypotheses and terminology references; every full iOS description has an individual review note. These are wording hypotheses, not measured search volumes or promised ranking improvements. Filipino has no dedicated ASC locale and is handled through the Philippine storefront's English listing. The international app retains 28 languages and China retains nine.

Archive source: `0be026c0ed6cb8e97f12d6b0aa13857941ecfd70`, on `codex/ios-1249-aso-release`, based on fetched `origin/main` `d48a9af144bfef1d07af0e81c7a847b283d8bbf0`. Checkout: `/Users/xuxuheng/.codex/worktrees/ios-1249-aso-release/CastReader`. Of 466 application/configuration files, 465 are byte-identical to released Build 75; the project file differs only in eight marketing-version/build configuration values. App, Share, Widget and Safari are all **1.2.49 (77)**, iPhone/iPad families 1/2. The unchanged ignored local signing configuration was copied from the verified release checkout and hashed privately. No OCR-download or language-identification experiment is included.

Application/configuration manifest: `7329abb65a24afacd6f404325d375f4fde911fae123bff141dca6f7bb4c8da61`. The archive is `/Users/xuxuheng/Library/Developer/Xcode/Archives/2026-10-11/CastReader-1.2.49-77.xcarchive`, built with its own DerivedData. The first archive attempt stopped because the ignored local configuration was absent; after restoring the exact verified file, the clean retry succeeded. The four signed arm64 products, production endpoints, compiled language resources, encryption declaration and release-fixture exclusion passed. The archive uses development signatures; official App Store export signs its distribution copy.

## Verification and evidence reuse

The ancestry gate, Safari packaging validator, 29-locale preflight, 203-field store-copy audit and ASO regression suite passed (17 tests, 34 assertions). No functional source or packaged language resource changed, so the existing real-device CN/Global Read/Explain × regular/community/private voice evidence and quota evidence were reused under the release SOP. All 12 cells and their evidence paths are present; archive/source equivalence is independently recorded. This is not a claim of a new live service test or of running the eventual App Store-distributed binary.

The previous full suite was not completely green: it initially recorded 2,191 passed, 26 skipped and two failed cases; the localized literal assertion was corrected and its affected suite passed 51/51. The remaining Indonesian/Malay automatic language-detection coverage limitation and manual selection fallback remain as documented for 1.2.48. This metadata release neither changes the detection model nor lowers test thresholds. Warm community voices are not claimed as cold-start coverage.

## Store metadata and screenshots

All 29 update notes now accurately describe the App Store information update. Full descriptions and search fields match the reviewed catalogs exactly; promotional text, URLs, contacts, demo credentials and legal statements are preserved. Stale prior-version resubmission paragraphs in the private review notes were replaced with the current release explanation; the remaining review instructions are retained. Both the pending 29-locale App Info and historical App Info are checked against the pre-release snapshots.

The 290 inherited screenshots comprise five iPhone and five iPad images in each store locale. Their ordered upload checksums match the previously visually reviewed artwork, whose local SHA-256 values were also checked. Apple generated new asset IDs for the new version; image content is unchanged. All six unique public support/privacy/marketing URLs returned HTTP 200 using system curl with TLS verification. An initial Python link probe failed because that interpreter lacked a trusted local CA chain; its failed diagnostic is retained separately.

Private evidence is under `reports/ios-release-1.2.49/` in the release checkout and is not committed. It includes source identity, preflight, core-evidence links, archive verification, immutable payload checks, metadata snapshots, screenshot identity, exact eligible build, upload receipt, final release audit and review-submission readback. Credentials and private account content are excluded from this report and Git.

## Submission

- Official Xcode upload succeeded **2026-10-11 18:34:13 +08:00**. Build `682ca796-eb90-4340-a055-eca64c0c74a4` is **77 / VALID / APP_STORE_ELIGIBLE**, with `usesNonExemptEncryption=false`, and belongs to iOS 1.2.49.
- Version `680b0b6d-968f-4a0c-a5a2-b8c25496e078` is bound to that exact build. Release mode remains `AFTER_APPROVAL`.
- Final audit passed at **18:40:08 +08:00**: exact 29-locale copy, 290 COMPLETE screenshots, preserved App Info and review attributes, 12 source-compatible core cells, trusted-TLS links and immutable archive payload.
- Export changed only archive-level `Info.plist`; all 403 product/dSYM files were unchanged. Stable payload manifest SHA-256: `1f803946d8c24799e7bcfdba38a2c402dbb18f129746f454a15e201ae793e747`.
- Prepared review submission `e3d5c230-c7e0-4a1c-91ca-2c2ba2b68d78` contains exactly this version. Both the version and its submission remain **READY_FOR_REVIEW**. The normal submit helper passed its explicit-submission dry run, then Apple rejected `submitted=true` with `STATE_ERROR.MAX_IN_REVIEW_SUBMISSIONS_PER_PLATFORM_LIMIT_REACHED`: the maximum is two in-flight iOS submissions. The failure is an Apple API concurrency limit, not an approval-policy rejection or metadata/build validation error.
- Two existing submissions remain untouched: `238ef1b0-762a-4e34-872d-b9e16742cd3f` (three non-version items; their resource type is not exposed by the reviewed public API relationships) and `c3c2a6cc-598f-4196-9f5d-1188fd743ea2` (Books, Documents and Study custom product pages). Both were WAITING_FOR_REVIEW at inspection. The Mac version/review was not modified.
- The user has been asked whether to preserve the existing queue or withdraw the identified custom-product-page submission to prioritize this app version. No withdrawal is authorized yet; the known item identifiers and snapshots are saved. Releasing capacity is the sole remaining external dependency.

Resume by re-reading these exact objects and the saved final audit; reuse Build 77 and review submission `e3d5c230-c7e0-4a1c-91ca-2c2ba2b68d78`. Do not upload a duplicate build or create another version/submission. Recheck affected metadata and invoke the normal submit helper with that `--submission-id`; require both version and submission to reach WAITING_FOR_REVIEW or later before calling the release submitted.

Apple documents a maximum of two concurrent submissions per platform: [Overview of submitting for review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/overview-of-submitting-for-review).
