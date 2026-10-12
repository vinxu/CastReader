# iOS 1.2.49 release report

Updated 2026-10-12. **In progress: Build 79 adds the requested closed-screen right navigation and fixes tab-selection rebound. Build 78 is eligible but will not be submitted.**

## Scope and identity

Combined approved ASO update and iPhone Duo adaptation. Version 1.2.49, Build 78 across App, Share, Widget and already-released Safari extension. Source branch `codex/ios-duo-adaptation`, PR https://github.com/vinxu/CastReader/pull/7. Application/config digest: `fe97839334f7002b03ef755093715cf037b3db071ac1cd0bc3621f298c9b6f1a` (356 tracked files, private manifest `reports/ios-duo-20261011/kobo-final-candidate-identity.json`). PR #7 merged into main as `c348089cddda8a4b450ed6a97e431a7d2082ebab`; the archive was built from that commit.

The user authorized merging with the existing 1.2.49 version and coordinating its automatic submission. The original task confirmed its automation is PAUSED and it will not submit old Build 77. App Store version ID: `680b0b6d-968f-4a0c-a5a2-b8c25496e078`. Existing unrelated review submissions are preserved.

## Acceptance

Full history and bounded failures: [Duo adaptation record](iPhone-Duo-Adaptation-2026-10-11.md). Real regional endpoints and real simulator playback covered web, PDF, EPUB, TXT, DOCX, Kindle, Google Play Books, Kobo and WeRead; fold, resume, highlights and original-source Explain annotations are recorded per source. TXT/DOCX are short format smokes, not three-minute coverage. Actual system file-picker selection and security-scoped import also pass.

Final Kobo code passes 44/44 affected unit tests. Final-source live Read and Explain fold phases pass; a separate manual-paused rerun passes after correcting the harness autoplay precondition. Earlier failing attempts remain preserved. The single frozen full unit run reported 2,213 pass, 26 skip and two failures; unchanged Google follow-ups pass, while the completed 14,592-row native-language audit retains historical Indonesian/Malay conservative-coverage failures with no misroute assertion failures. No all-green full-run claim is made.

Physical core playback for this Duo release remains NOT_RUN after device/IDE connection failures. The user explicitly approved simulator Duo acceptance as sufficient to release; this is a task-specific override, not fabricated physical evidence. Prior 1.2.48 CN/Global normal/community/private voice acceptance is preserved as historical evidence; unchanged TTS, authentication and quota logic is reused. See [1.2.48 report](iOS-1.2.48-Release-Report.md).

## Store assets and metadata

All 29 merged descriptions and What's New entries were applied and exactly read back. Original ASO paragraphs, names/subtitles/keywords, legal links, untouched fields and release behavior are preserved. Pending App Info: `988607e7-fe9f-45ad-9432-86fca303d591`.

Original five native Duo scenes are COMPLETE for all 29 ASC locales. The additional sixth image requested by the user combines genuine closed and expanded views, with 28 localized captions. Target 168 local images; 174 Duo ASC assets. Filipino uses the existing English storefront, Traditional Chinese uses Simplified Chinese imagery, and Mexican Spanish uses Spanish imagery. Existing 290 iPhone/iPad images remain untouched.

## Final navigation revision

Closed Duo now uses the system's right-side navigation region, detected through the public `toolbarVerticalEdge` environment value. Ordinary compact phones retain their existing bottom navigation. The native tab selection uses immediate view state, with SceneStorage retaining only the restoration record. This removes the observed Home → Voice → Home → Voice highlight rebound without disabling system animations.

The real simulator navigation test passed, including Library, Settings, import and three Home/Voice cycles (`selection-state-test.xcresult`). A second recorded pass confirms a direct selection transition at 15 sampled frames per second (`closed-rail-nav/selection-state2.mp4`, `state2-voice-transition.png`). Its test case passed; Xcode hung while closing that second result bundle and was terminated, so that bundle is not reported as a completed runner success. A direct Device Hub recheck then passed Closed → Open → Closed with Voice still selected and search text unchanged (`closed-rail-nav/manual-fold-verification.json`). The earlier automated fold attempt remains FAIL: its recording shows extra Home/Library navigation outside the test script before the final selection assertion. Ordinary iPhone navigation passed (`nav79-phone2.xcresult`); the prior run was blocked by a StoreKit rating prompt. iPad follow-up is pending. Navigation changes do not alter the previously verified reading, explanation, authentication or quota pipelines.

The first sixth-image revision had reached 174 COMPLETE Duo assets. It will be replaced only after new closed-screen captures are reviewed. The staged review item for Build 78 was removed from this task's own draft; the version is back in PREPARE_FOR_SUBMISSION. No final submission has occurred.

## Delivery state

Official Xcode archive/upload succeeded. Build `514de937-a890-4ece-98e8-9bc7e12f697d` is VALID / APP_STORE_ELIGIBLE, non-exempt encryption false. Archive `reports/ios-duo-20261011/CastReader-1.2.49-78.xcarchive`; uploaded IPA SHA-256 `7b2fd9087a63a943c712842e751ec872c8b2c46e9db67c6d7d19ab1eb50bf0f2`. Exported App/Share/Widget/Safari signatures verify with get-task-allow=false, version1.2.49(78) and device families1/2. All28 language resources are present, plus the existing pt fallback; no test fixtures are bundled.

All378 current local/remote copy fields and review notes pass the final content audit. Original review instructions after the updated release intro, contacts and account settings are preserved. The independent custom-page review is COMPLETE; the other store-asset review remains WAITING_FOR_REVIEW and is untouched. Final screenshot inventory and submission/readback remain pending.
