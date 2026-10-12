# iOS 1.2.49 release report

Updated 2026-10-12. **In progress: archive, sixth screenshots and final submission pending.**

## Scope and identity

Combined approved ASO update and iPhone Duo adaptation. Version 1.2.49, Build 78 across App, Share, Widget and already-released Safari extension. Source branch `codex/ios-duo-adaptation`, PR https://github.com/vinxu/CastReader/pull/7. Application/config digest: `fe97839334f7002b03ef755093715cf037b3db071ac1cd0bc3621f298c9b6f1a` (356 tracked files, private manifest `reports/ios-duo-20261011/kobo-final-candidate-identity.json`). Archive will follow mainline merge.

The user authorized merging with the existing 1.2.49 version and coordinating its automatic submission. The original task confirmed its automation is PAUSED and it will not submit old Build 77. App Store version ID: `680b0b6d-968f-4a0c-a5a2-b8c25496e078`. Existing unrelated review submissions are preserved.

## Acceptance

Full history and bounded failures: [Duo adaptation record](iPhone-Duo-Adaptation-2026-10-11.md). Real regional endpoints and real simulator playback covered web, PDF, EPUB, TXT, DOCX, Kindle, Google Play Books, Kobo and WeRead; fold, resume, highlights and original-source Explain annotations are recorded per source. TXT/DOCX are short format smokes, not three-minute coverage. Actual system file-picker selection and security-scoped import also pass.

Final Kobo code passes 44/44 affected unit tests. Final-source live Read and Explain fold phases pass; a separate manual-paused rerun passes after correcting the harness autoplay precondition. Earlier failing attempts remain preserved. The single frozen full unit run reported 2,213 pass, 26 skip and two failures; unchanged Google follow-ups pass, while the completed 14,592-row native-language audit retains historical Indonesian/Malay conservative-coverage failures with no misroute assertion failures. No all-green full-run claim is made.

Physical core playback for this Duo release remains NOT_RUN after device/IDE connection failures. The user explicitly approved simulator Duo acceptance as sufficient to release; this is a task-specific override, not fabricated physical evidence. Prior 1.2.48 CN/Global normal/community/private voice acceptance is preserved as historical evidence; unchanged TTS, authentication and quota logic is reused. See [1.2.48 report](iOS-1.2.48-Release-Report.md).

## Store assets and metadata

All 29 merged descriptions and What's New entries were applied and exactly read back. Original ASO paragraphs, names/subtitles/keywords, legal links, untouched fields and release behavior are preserved. Pending App Info: `988607e7-fe9f-45ad-9432-86fca303d591`.

Original five native Duo scenes are COMPLETE for all 29 ASC locales. The additional sixth image requested by the user combines genuine closed and expanded views, with 28 localized captions. Target 168 local images; 174 Duo ASC assets. Filipino uses the existing English storefront, Traditional Chinese uses Simplified Chinese imagery, and Mexican Spanish uses Spanish imagery. Existing 290 iPhone/iPad images remain untouched.

## Delivery state

No Build 78 upload or review submission is claimed yet. Exact archive, build eligibility, final screenshot inventory and submission/readback will be recorded here when completed.
