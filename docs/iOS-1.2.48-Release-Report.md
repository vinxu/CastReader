# iOS 1.2.48 (74) release record

Status: **IN PROGRESS — not submitted**. This record is updated as the release gates finish; uploaded marketing assets are not a submitted binary.

## Scope and source

The requested release expands the international app to 28 interface/reading languages and refreshes five product screenshots for both iPhone and iPad in every language, following the current Android campaign's composition. China retains its existing nine-language service scope.

Verified checkout: `/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader`, branch `codex/ios-28-languages`. Application changes are `ac1acd1`, `d42e9b3` and the direction repair `9e44067`, based on the released `09456f1` main line. The current release version bump sets App, Share, Widget and Safari to 1.2.48 (74). The revised 466-file application/configuration manifest is `b791a94673d917181cb402bd3661f9a94ac52a8a1a0124239ac11248f6a6d576`. The ancestry/integration gate and release preflight passed. Main-line merge, immutable archive and official upload are still pending.

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

App: `6757636395`. iOS version: `968ba86c-0722-43fa-b55c-ff0425533966`, PREPARE_FOR_SUBMISSION, release after approval. Shared Mac App Info is IN_REVIEW and was not altered or withdrawn. No changes to price, subscriptions, territories, App Privacy, age rating or legal declarations.

## Validation

The single full candidate run executed **2219 tests: 2191 passed, 26 skipped, 2 failed test cases (15 assertions)**. The localization test's literal-token rule incorrectly rejected native translations of Amazon, URL and SLA; narrow explicit equivalents corrected the test, and **all 51 LocalizationCatalogTests subsequently passed**. Product translations were not changed to satisfy this rule.

`NativeLanguageAuditTests.testNativeRegressionCorpus` retains the documented conservative automatic-detection coverage limit for Indonesian (0.5855) and Malay (0.5362), below the test's 0.9 threshold. Its threshold was not lowered and the full run is not reported as green. Prior acceptance documents the manual, persisted language selection for uncertain cases and actual three-minute Read/Explain verification. The existing 114/114 language playback matrix and d42e9b3 UI/voice/quota evidence remain valid for unchanged application code; they do not replace this release's two-region core gate.

The 26 skips comprise 10 disposable PostgreSQL/StoreKit integration cases,
3 StoreKitTest cases unavailable in this host (`notEntitled`), 8 optional private
or publication-document fixture cases, and 5 opt-in network/live cases. Their
exact reasons are preserved in `unit-skips-summary.json`; skipped cases are not
counted as passing.

The current frozen-candidate Global/English live playback matrix is complete on the physical iPhone. Read passed normal `af_heart` → community `vl_d1efb23a380bdaa2f6b0` → private `vc_62934fe77f764051aa341b4b076bbb85` → normal, with real progress, paragraph continuation, highlighting and pause/resume. Explain passed the same sequence using newly generated QuickRead commentary, automatic blocks 0 → 1 → 2 → 3, and visible original-text marks (1 → 3 → 5 → 7, then 8). Final normal playback advanced to 3.5 seconds. Actual TTS routing IDs match the selected voices. Evidence: `core-global-live-r2.xcresult`, `core-global-explain-live.xcresult`, scoped console logs and exported attachments. The first combined run's Explain automation paused auto-started playback; the test-only timing fix was followed by a successful Explain-only run, retaining the valid Read evidence.

CN/Chinese remains **NOT_RUN** beyond startup: the phone has no authenticated China-route account, while its existing Global account is intact. The attempted startup selected the persisted private voice and correctly returned “Voice cloning sign-in is not ready yet”; no CN audio played. Local StoreKit Pro alone does not establish a regional server session. The phone was opened on the Chinese sign-in flow and the user was asked to sign into the existing China Pro test account. No entitlement, session or balance was injected.

Exact production-ledger reconciliation is not yet verified: the existing analytics read-only role was denied SELECT on the new `voice_clone_credit_request` table. No permission or balance was changed. Successful generation responses use `credits-v1` and omit the legacy remaining-seconds header; this is an unknown legacy value, not evidence of zero credits. Previously passing balance-state regression checks remain valid, but are not claimed as a live server-ledger reconciliation. The complete regional core gate therefore remains pending.

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
The updated source manifest replaces the pre-fix identity. The separate overall
release core-service gate remains pending.

## Evidence and remaining work

Private raw logs, xcresults, live-account screenshots, metadata snapshots, receipts and resumable upload journals are local under `reports/ios-release-1.2.48/` and are deliberately excluded from Git. Capture automation is opt-in. The release-scoped audit checks the actual 29-locale scope, both device families, exact five-image order, title preservation, review details and exact eligible build; it requires genuine core evidence before passing.

Complete: all intended captures, composition, visual review, metadata and screenshot uploads. Pending: China authenticated live core cells and final quota evidence, final source merge, signed Release archive/upload, exact build VALID / APP_STORE_ELIGIBLE, review audit, submission and version/submission WAITING_FOR_REVIEW readback.
