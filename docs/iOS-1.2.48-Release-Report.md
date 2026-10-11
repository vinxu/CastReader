# iOS 1.2.48 (75) release record

Status: **SUBMITTED — WAITING_FOR_REVIEW**, verified 2026-10-10. Version and Review Submission both reached WAITING_FOR_REVIEW at **20:42:21 Beijing time** (12:42:21 UTC). Release is automatic after approval; approval/live availability is not claimed.

## Scope and source

The requested release expands the international app to 28 interface/reading languages and refreshes five product screenshots for both iPhone and iPad in every language, following the current Android campaign's composition. China retains its existing nine-language service scope.

Verified checkout: `/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader`. The release is archived from the merged main commit **`60b0973c5dd7e3a922349fb157c5ec0af96cc53b`** (PRs #5 and #6). Application changes are `ac1acd1`, `d42e9b3` and direction repair `9e44067`, based on the released `09456f1` main line. The final Safari-description validation repair is `3acdf10`. App, Share, Widget and Safari all use **1.2.48 (75)** and device families 1/2.

The final 466-file application/configuration manifest is **`5991aa3ba1bd6f8fbd86ac476319376e24a83af9b4d6c3f37cc40330b085feba`**. Live core evidence was collected with Build 74, manifest `b791a94673d917181cb402bd3661f9a94ac52a8a1a0124239ac11248f6a6d576`. A semantic compatibility audit proves the only later embedded changes are 17 Safari manifest descriptions and the build-number increment; all functional source remains identical. The ancestry gate, preflight and source/archive checks passed. No isolated feature branch or stale primary checkout was used for the release.

## Store content

Source copy and reproducible composition/upload tools are in `store/app-store/1.2.48/`. Captures use the user's actual connected library and real Read/Explain playback; no fabricated books, audio, entitlement or reader marks are injected. Book content remains its original language. Captions and native interface controls use the target interface language.

Apple supports 27 of the 28 requested store languages. Filipino has complete local copy/artwork deliverables but no supported ASC locale. The existing Traditional Chinese and Mexican Spanish entries remain, yielding **29 ASC localizations**, with explicit screenshot fallback to Simplified Chinese and Spanish. The requested international languages do not expand the China service catalog.

All 29 descriptions, keywords, release notes, support/marketing URLs and intended promotional text were saved and exactly read back. Existing names/subtitles and shared Mac App Info are preserved. All four unique support/marketing URLs returned HTTP 200 with TLS verification. iPad renders are 2732 × 2048; iPhone renders are 1320 × 2868. Each set has five opaque PNGs with raw/final hashes. Replacement uploads retain old assets until all five new assets are COMPLETE, then verify exact ordering.

iPad capture previously covered all 28 languages (140 deliverable images), and
all 29 supported/preserved App Store entries have five COMPLETE iPad images in
the verified order (145 uploads). Arabic/Hebrew scenes were recaptured after the
direction repair, visually reviewed and replaced in ASC with verified COMPLETE
assets and ordering. All 28 iPad home/import backgrounds were reviewed to start
at the Kindle shelf, with the Continue Listening section scrolled out of the
main composition. A trial with tighter scrolling overlapped the shelf heading
with the floating navigation; it was rejected, preserving the approved framing.
iPhone has all 28 complete language sets (140 images), visually reviewed; all
29 supported/preserved ASC entries contain five COMPLETE ordered images (145 uploads).
The campaign totals 280 local deliverables and 290 ASC images. Physical capture uses the existing iPhone 15 Pro Max via USB, retaining
the user's sessions. English shelf/library captures with an exposed search
keyboard were rejected and replaced with genuine unobscured captures from the
same device and candidate; reader images retain actual playback effects.

App: `6757636395`. iOS version: `968ba86c-0722-43fa-b55c-ff0425533966`, WAITING_FOR_REVIEW, release after approval. Shared Mac App Info is IN_REVIEW and was not altered or withdrawn. No changes to App Store prices, subscription products, territories, App Privacy, age rating or legal declarations.

## Validation

The single full candidate run executed **2219 tests: 2191 passed, 26 skipped, 2 failed test cases (15 assertions)**. The localization test's literal-token rule incorrectly rejected native translations of Amazon, URL and SLA; narrow explicit equivalents corrected the test, and **all 51 LocalizationCatalogTests subsequently passed**. Product translations were not changed to satisfy this rule.

`NativeLanguageAuditTests.testNativeRegressionCorpus` retains the documented conservative automatic-detection coverage limit for Indonesian (0.5855) and Malay (0.5362), below the test's 0.9 threshold. Its threshold was not lowered and the full run is not reported as green. Prior acceptance documents the manual, persisted language selection for uncertain cases and actual three-minute Read/Explain verification. The existing 114/114 language playback matrix and d42e9b3 UI/voice/quota evidence remain valid for unchanged application code; they do not replace this release's two-region core gate.

The 26 skips comprise 10 disposable PostgreSQL/StoreKit integration cases,
3 StoreKitTest cases unavailable in this host (`notEntitled`), 8 optional private
or publication-document fixture cases, and 5 opt-in network/live cases. Their
exact reasons are preserved in `unit-skips-summary.json`; skipped cases are not
counted as passing.

The current frozen-candidate Global/English live playback matrix is complete on the physical iPhone. Read passed normal `af_heart` → community `vl_d1efb23a380bdaa2f6b0` → private `vc_62934fe77f764051aa341b4b076bbb85` → normal, with real progress, paragraph continuation, highlighting and pause/resume. Explain passed the same sequence using newly generated QuickRead commentary, automatic blocks 0 → 1 → 2 → 3, and visible original-text marks (1 → 3 → 5 → 7, then 8). Final normal playback advanced to 3.5 seconds. Actual TTS routing IDs match the selected voices. Evidence: `core-global-live-r2.xcresult`, `core-global-explain-live.xcresult`, scoped console logs and exported attachments. The first combined run's Explain automation paused auto-started playback; the test-only timing fix was followed by a successful Explain-only run, retaining the valid Read evidence.

CN/Chinese also passed on the physical iPhone: normal `zf_001` → community `vl_65b2c4daaea282b057a7` → private `vc_63a448ca35794f57b0aea0e189a68cb3` → normal in both modes. Read regular/community evidence is retained from `core-cn-live-r3.xcresult`; private Read and all Explain cells passed in `core-cn-live-r4.xcresult` (208.713 seconds). The interrupted run exposed a test selector difference between China My Voices and the Global panel; only the harness was corrected. Fresh China QuickRead plan/block/compose and actual TTS output, advancing playback/blocks, pause/resume and visible original-text underlines were verified. All China core launches explicitly disabled the pre-existing DEBUG simulated Pro setting. The user changed to a phone account and authorized a seven-day Pro gift, confirmed by real server responses; expiry is 2026-10-17 19:29 Beijing time. No purchase, auto-renewal or historical usage reset was made.

Quota reconciliation passed. China read-only server-ledger evidence shows 28 successful generations totaling **166,728 ms**, equal to their charged duration and bucket usage, with zero reserved balance left. This includes read-ahead and preparation, not just audible listening. The physical development device uses Sandbox billing. Separately, a live Global iPad generation in **Production** reduced the server-refreshed balance from **2,256,862 ms to 2,250,094 ms**, exactly the **6,768 ms** decoded audio duration. Two complete playbacks used one generation; cached rewind/replay incurred no extra deduction. Numeric response fields were inspected read-only in the running app; no credentials or balances were injected. Global direct SQL reconciliation was unavailable to the existing read-only role, so it is not claimed. Evidence: `cn-quota-evidence.json`, `global-quota-evidence.json`, scoped logs and balance observations.

Both regional core matrices are **PASS**. They use the frozen candidate's real services and a signed development build; they are not claimed as execution of the future App Store-distributed binary. The final Release archive subsequently passed signature, resource, endpoint and fixture checks. Existing quota unknown/confirmed-zero, scheduler, cancellation and ownership regressions apply; community voices were warm, not claimed as a cold-start observation.

### Mixed-language reading direction regression

The user observed English highlighting moving in the wrong direction while the
interface was Arabic. Real-device logs still identified the book as `en`, with
`reading=ltr` and `progressionFallback=ltr`. The native held-page overlay inherited
SwiftUI's RTL layout and mirrored physical OCR coordinates. A rendered regression
test reproduced zero highlight coverage at the actual spoken word under RTL UI.

The fix isolates Kindle held images, word highlights, held explanation origins,
and photo reading canvases in their physical coordinate system. Arabic/Hebrew
logical word order and mark stroke direction remain determined by the document.
Kindle page buttons and held-page swipe gestures use the book's progression,
including explicit publication metadata and the existing document correction.
Interface menus retain their selected language and direction.

The affected container/multilingual suites passed **51/51** tests; language,
manual page queue, and held-explanation-origin checks passed **34/34**. Real-device
Arabic/Hebrew UI with English Read/Explain passed on the physical iPhone and iPad
simulator. Paused word samples matched their actual OCR locations; English page
buttons remained LTR and resumed playback advanced through words/segments.
The updated source manifest replaces the pre-fix identity. The same-source regional core-service gate subsequently passed.

## Evidence and remaining work

Private raw logs, xcresults, live-account screenshots, metadata snapshots, receipts and resumable upload journals are local under `reports/ios-release-1.2.48/` and are deliberately excluded from Git. Capture automation is opt-in. The release-scoped audit checks the actual 29-locale scope, both device families, exact five-image order, title preservation, review details and exact eligible build; it requires genuine core evidence before passing.

Complete: requested captures, composition, visual review, metadata/screenshots, both regional core matrices, quota reconciliation, source merge, Release archive, official upload, exact eligible build binding, final audit, formal submission and version/submission readback. Apple's review decision is the only external step remaining.

## Upload validation repair

The immutable Build 74 archive passed local signature/resources/fixture checks, but Apple upload validation rejected 17 Safari extension locale descriptions exceeding its 112-character limit (error 90862). Those resolved `extDescription` strings were shortened without changing behavior or other locale messages. The packaging validator now enforces the 112 UTF-16-unit maximum across all 28 locales. All four product build numbers advance to **75**; Build 74 is retained as rejected evidence and will not be submitted.

The regional playback and quota evidence remains applicable: the only embedded-resource changes are Safari manifest descriptions plus the build-number increment. No TTS, QuickRead, account, quota, route, rendering or screenshot-source logic changed. A fresh source manifest and Build 75 archive were produced; no signed product was edited in place.

## Final archive, audit and submission

- Build **`b5fe510d-5916-44aa-99b7-bd573abd98fb`** is **VALID / APP_STORE_ELIGIBLE**, with `usesNonExemptEncryption=false`. Official Xcode export/upload succeeded at 20:27:40 Beijing time with zero errors and zero warnings.
- Archive: `/Users/xuxuheng/Library/Developer/Xcode/Archives/2026-10-10/CastReader-1.2.48-75.xcarchive`. All four arm64 products have the correct identities, versions, device families and Team `KQW6UNZE8J`; all 28 requested compiled main-string tables are present, production regional endpoints match, and the 391-file fixture scan found no test payloads.
- Stable archive product/dSYM payload manifest: **`17d1cb7ac8b1c3669a69e104dfdcfb140c86a56daf3f8231768d581e520c0c88`**. Official Xcode export updated only archive-level `Info.plist` distribution metadata; every archived signed-product and dSYM byte remained unchanged. The original pre-upload manifest and the post-upload integrity proof are preserved.
- Final campaign audit: exact **29** version localizations, **290** ordered COMPLETE screenshots, exact Build 75, source-matched core results, review details and original fields in both App Info objects passed. The historical App Info has 11 locales and the pending shared App Info has 29. The generic legacy helper's only findings were its hard-coded 11-locale expectations; the release-scoped audit verifies the user's expanded scope explicitly. A Ruby 2.6 `filter_map` compatibility issue in the audit tool was repaired without changing any app resource or uploaded binary.
- Review Submission **`0e9aa3ea-588c-47fa-a38f-56fe017bbc34`**, submitted **2026-10-10 20:42:21 +08:00**. It contains exactly this iOS version and no unrelated item. Both version and submission are **WAITING_FOR_REVIEW**. The exact Build and all 29 intended metadata entries were read back again after submission. The concurrent Mac review was not modified or withdrawn.

## Device delivery

The same Build 75 Release-configuration archived app, signed for development, was installed over the existing `com.same.castreader` on the user's iPhone 15 Pro Max. Device inventory confirms **1.2.48 / 75**, and launch succeeded. This is the development-signed Release product, not an already-approved App Store installation. Existing app storage and accounts were retained, and the binary contains no simulated Pro code.

The screenshot campaign had persisted Vietnamese despite later temporary launch-language overrides. Only the non-sensitive `interfaceLanguage` preference was restored to `zh-Hans` with the exact app process stopped; all other preference values were preserved. After an ordinary launch without overrides, both app preferences and AppLanguageManager's runtime-mirrored Share Extension language read back `zh-Hans`. Final mirror screenshot verification was unavailable because the phone was in use; it is not claimed. The iPad's Chinese normal voice `zf_001` was restored through native UI and playback was stopped.

Evidence: `submission-final-readback.json`, `submission-execute.json`, `official-upload75-receipt.json`, `final-release-audit.json`, `release-audit-resolution.json`, `archive-verification.json`, `post-upload-archive-integrity.json`, `core-evidence-compatibility-75.json` and `device-language-restoration.json` in the private release evidence directory.
