# iOS reading generation control — 2026-10-15

## Scope and baseline

Baseline: `73f6fd3e2821bc943460236be649a064b34bda8e` on the isolated `codex/ios-bounded-preloading` worktree. This change preserves the baseline version, build number, account routing, voice catalog, source extraction, timing/highlight mapping and playback ownership contracts. No App Store or backend release is included.

The same controller covers native uploaded PDF/EPUB and text reading, the built-in Web reader, and Kindle/WeRead/Google Play Books/Kobo speech. Explain uses the same audio-service controller; its bounded complete-unit exception is documented in `Explain-Bounded-Generation-2026-10-15.md`.

## Existing gaps

The existing paragraph streams already retained producers across prefetch adoption, but each stream measured its own buffer. Separate page preparations and complete narration fallback paths could synthesize beyond the visible queue. Pausing media did not cancel the active URLSession request. A long `partly` loop could therefore keep producing paid audio while playback was paused, and separate streams could each satisfy their own admission check.

## Admission and ownership

`AudioPlayerService.speechGeneration` is the shared owner for one audio service. `ParagraphSpeechGenerating.controlled(by:)` installs its task-local context without replacing the existing reader or extractor. `APIService` applies admission to every actual part, including retries and collected fallback paths.

* One HTTP attempt owns the permit. The permit is released only when the real transport exits; a noncooperative cancelled callback cannot overlap the resumed attempt.
* Pause cancels that attempt and closes admission. The producer, exact remaining text, published audio and logical `X-Request-ID` survive. Resume starts a new transport for that same logical part. Seek/stop cancels the producer, so old checkpoints and callbacks cannot publish into a new reader epoch.
* Known pending audio is measured in audible seconds, including playback speed and the current decoder position. At 30 seconds admission closes; at 10 seconds or less it reopens. Budget waits do not pause AVPlayer. An unknown duration reserves 30 seconds until decoded metadata is available.
* Pending foreground audio, read-ahead streams, unadopted page audio, Explain reservations and the queue share this budget. `AudioSegment.generationIdentity` survives paragraph/index rebasing and prevents double counting during adoption. Queue identities include consumed items so a retained cache cannot count already consumed audio again.
* A completed HTTP result holds a receipt before its permit is released. Its duration remains reserved until the consumer has published the resulting segment; this closes the actor handoff window where another producer could otherwise enter early.
* An explicit audible-demand predicate identifies the current reader epoch/session/target, promoted stream or current Explain block. If its actual playable queue falls to 10 seconds or less, that owner may refill despite an unadopted future-page reservation. Future audio remains fully counted. The exception ends as soon as the current playable queue is sufficient; speculative work receives no exception. It also wins over nominal request priority to avoid a blocked future producer starving the audible owner. Pause, cancellation, one real transport and the unique atomic owner always take precedence.
* Providers weakly reference their owner. Explicit discarded page preparation removes its contribution and wakes waiters, even when its original source epoch remains retained.

## Input and page preparation

Each controlled request is limited to 560 UTF-16 units, or 160 for Chinese/Japanese/Korean. The splitter preserves surrogate pairs and prefers a natural boundary. Local and server `partly` tails are reconstructed from exact source suffixes, preserving separators; source coverage validation still rejects invalid responses. This limits one in-flight overshoot instead of treating the 30-second watermark as an exact duration guarantee.

Legacy page helpers that collect a whole result before publishing only accept one bounded input window. Long pages keep their prepared source/OCR and use the existing foreground streaming path after confirmed placement. They are never silently truncated, and no system-TTS or missing-highlight fallback is introduced.

Current and next page source/OCR preparation remains independent of paid speech. Kindle normally keeps one hidden successor. Its existing bounded scan can inspect up to three source pages when empty pages or an unfinished cross-page sentence require it; `prepareKindleSentencePage` performs source/OCR/mapping work, not TTS. Reducing that scan mechanically would break page-end sentences. All resulting speech still uses the single shared budget.

## Verification boundary

Reproducible Xcode logs, `.xcresult` bundles and a final source manifest live in `reports/ios-bounded-preloading-20261015/`. The local HTTP tests use the real API/TTS/reader/player code with isolated URLProtocol responses and real AVPlayer decoding. These prove client admission, cancellation, continuity and playback behavior; they do not prove a production GPU stopped or a production ledger released a reservation.

Production consumer cancellation protocol deployment, real-account quota settlement and physical-device online reading remain separate acceptance evidence. No customer account, synthetic production allowance or paid GPU generation is used by this change's controlled tests.
