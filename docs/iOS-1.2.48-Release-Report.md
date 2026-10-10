# iOS 1.2.48 (74) release record

Status: **IN PROGRESS — not submitted**. This record is updated as the release gates finish; uploaded marketing assets are not a submitted binary.

## Scope and source

The requested release expands the international app to 28 interface/reading languages and refreshes five product screenshots for both iPhone and iPad in every language, following the current Android campaign's composition. China retains its existing nine-language service scope.

Verified checkout: `/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader`, branch `codex/ios-28-languages`. Application changes are `ac1acd1` and `d42e9b3`, based on the released `09456f1` main line. The current release version bump sets App, Share, Widget and Safari to 1.2.48 (74). The ancestry/integration gate and release preflight passed. Main-line merge, immutable archive and official upload are still pending.

## Store content

Source copy and reproducible composition/upload tools are in `store/app-store/1.2.48/`. Captures use the user's actual connected library and real Read/Explain playback; no fabricated books, audio, entitlement or reader marks are injected. Book content remains its original language. Captions and native interface controls use the target interface language.

Apple supports 27 of the 28 requested store languages. Filipino has complete local copy/artwork deliverables but no supported ASC locale. The existing Traditional Chinese and Mexican Spanish entries remain, yielding **29 ASC localizations**, with explicit screenshot fallback to Simplified Chinese and Spanish. The requested international languages do not expand the China service catalog.

All 29 descriptions, keywords, release notes, support/marketing URLs and intended promotional text were saved and exactly read back. Existing names/subtitles and shared Mac App Info are preserved. All four unique support/marketing URLs returned HTTP 200 with TLS verification. iPad renders are 2732 × 2048; iPhone renders are 1320 × 2868. Each set has five opaque PNGs with raw/final hashes. Replacement uploads retain old assets until all five new assets are COMPLETE, then verify exact ordering.

iPad capture previously covered all 28 languages (140 deliverable images), and
all 29 supported/preserved App Store entries have five COMPLETE iPad images in
the verified order (145 uploads). **Arabic/Hebrew reader scenes were invalidated
by the reported RTL highlight bug and are being recaptured after the fix.**
iPhone has 13 unaffected language sets (65 images); remaining sets and uploads
are in progress. Physical capture uses the existing iPhone 15 Pro Max via USB, retaining
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

The current core gate is pending. Required cells are CN/Chinese and Global/English × Read/Explain × regular/community/private voices, including actual continuation, original-text marks, voice ownership and quota. No historical build's PASS is claimed for this candidate.

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
Arabic/Hebrew UI with English Read/Explain and affected iPad scenes are pending
visual readback. The earlier source manifest and affected screenshot acceptance
must not authorize submission of the revised source.

## Evidence and remaining work

Private raw logs, xcresults, live-account screenshots, metadata snapshots, receipts and resumable upload journals are local under `reports/ios-release-1.2.48/` and are deliberately excluded from Git. Capture automation is opt-in. The release-scoped audit checks the actual 29-locale scope, both device families, exact five-image order, title preservation, review details and exact eligible build; it requires genuine core evidence before passing.

Pending: remaining captures/uploads and visual review, full current core gate, final source merge, signed Release archive/upload, exact build VALID / APP_STORE_ELIGIBLE, review audit, submission and version/submission WAITING_FOR_REVIEW readback.
