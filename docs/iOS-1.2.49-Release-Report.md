# iOS 1.2.49 ASO candidate (77) — handed off for Duo integration

Status: **HANDED OFF — DO NOT SUBMIT BUILD 77 FROM THIS TASK**, recorded 2026-10-12. The user chose to merge Duo into 1.2.49 and coordinate the original submission task. The hourly submission automation is confirmed **PAUSED**. This task will make no further writes to the prepared App Store version or review submission and will not upload or submit the old candidate. Earlier build and audit results below are historical evidence, not a final Duo release approval.

## Release ownership transfer

- The iPhone Duo task `01a119b5-7862-7fd0-a0bd-438d30fdecc5` relayed the user's explicit decision: “合并到 1.2.49，协调原任务的自动提交”. Its release checkout is `/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader`.
- That task owns the Duo implementation, a new Build, 28 languages × five Duo screenshots, updated release notes and final submission. It will retain the reviewed 29-locale ASO copy, existing iPhone/iPad screenshots and the two independent in-flight content submissions.
- The user permits release after Duo simulator acceptance without a physical Duo device. The receiving task must verify its changed implementation and final release; the old candidate's unchanged-source service evidence does not by itself certify the new Duo code.
- Automation `castreader-ios-1-2-49` was paused by the receiving task and verified PAUSED here. Do not resume it. The original instruction to submit Build 77 as soon as review capacity becomes available is superseded by this handoff.
- The last read-only check before handoff was **2026-10-12 08:14:24 +08:00**: version and own review were READY_FOR_REVIEW, Build 77 was VALID / APP_STORE_ELIGIBLE, and the two other review slots were still occupied. This handoff did not re-query or change App Store Connect. Any later state must be established by the receiving release task.
- Preserve this checkout, its ASO catalogs and private evidence for the receiving task. No review was withdrawn, no duplicate upload occurred, and no successful submission is claimed by this report.

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

## Original submission attempt (historical)

- Official Xcode upload succeeded **2026-10-11 18:34:13 +08:00**. Build `682ca796-eb90-4340-a055-eca64c0c74a4` is **77 / VALID / APP_STORE_ELIGIBLE**, with `usesNonExemptEncryption=false`, and belongs to iOS 1.2.49.
- Version `680b0b6d-968f-4a0c-a5a2-b8c25496e078` is bound to that exact build. Release mode remains `AFTER_APPROVAL`.
- Final audit passed at **18:40:08 +08:00**: exact 29-locale copy, 290 COMPLETE screenshots, preserved App Info and review attributes, 12 source-compatible core cells, trusted-TLS links and immutable archive payload.
- Export changed only archive-level `Info.plist`; all 403 product/dSYM files were unchanged. Stable payload manifest SHA-256: `1f803946d8c24799e7bcfdba38a2c402dbb18f129746f454a15e201ae793e747`.
- Prepared review submission `e3d5c230-c7e0-4a1c-91ca-2c2ba2b68d78` contains exactly this version. Both the version and its submission remain **READY_FOR_REVIEW**. The normal submit helper passed its explicit-submission dry run, then Apple rejected `submitted=true` with `STATE_ERROR.MAX_IN_REVIEW_SUBMISSIONS_PER_PLATFORM_LIMIT_REACHED`: the maximum is two in-flight iOS submissions. The failure is an Apple API concurrency limit, not an approval-policy rejection or metadata/build validation error.
- Two existing submissions remain untouched: `238ef1b0-762a-4e34-872d-b9e16742cd3f` (three non-version items; their resource type is not exposed by the reviewed public API relationships) and `c3c2a6cc-598f-4196-9f5d-1188fd743ea2` (Books, Documents and Study custom product pages). Both were WAITING_FOR_REVIEW at inspection. The Mac version/review was not modified.
- The user's earlier choice was to preserve existing reviews and wait for capacity. The heartbeat performed read-only hourly checks and no submission writes while both slots remained occupied. On 2026-10-12, the later Duo integration decision superseded this continuation plan; the heartbeat is now PAUSED and release ownership has transferred as recorded above.

The original Build 77 submission instructions are no longer active. Only the receiving Duo release task may proceed with the version and review draft under its updated scope, new Build and acceptance evidence. This task must not bind, submit, cancel or otherwise modify those objects or restore the paused automation.

Apple documents a maximum of two concurrent submissions per platform: [Overview of submitting for review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/overview-of-submitting-for-review).
