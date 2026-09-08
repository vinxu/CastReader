# iOS preset TTS direct routing and Kindle continuity

## Scope and baseline

- Branch: `codex/ios-direct-tts-kindle-20260908`.
- Baseline: `e44894a`, the complete iOS 1.2.35 (56) submission, including the
  previous Kindle settings, viewport and drained-queue replay fixes.
- Local simulator builds retain 1.2.35 (56). This is development acceptance,
  not an App Store submission. No server deployment or production configuration
  was changed.
- The signed-in Kindle simulator is iPhone 17 Pro. Account-mutating unit tests
  run on a separate disposable simulator, preserving the user's WebKit login.

## Routing and response contract

Global preset synthesis now uses `https://tts.castreader.ai/api/captioned_speech_partly`
through a dedicated anonymous, redirect-rejecting URLSession. Changing only
`TTSEndpoint.globalBase` would not have migrated the actual APIService caller;
that caller now uses `PresetTTSTransport` too.

The frozen account region still selects global or China compute. China stays
on `api.castreader.cn`. Clone synthesis, My Voices, account, entitlement and
QuickRead endpoints keep their existing authenticated routes.

The preset operation has a 125-second read timeout and a 140-second total
deadline. It permits at most one same-region fallback to `api.castreader.ai`
only after DNS/connect failure or a 503 carrying all four gateway headers that
prove zero upstream attempts. Timeout, lost response, cancellation, ambiguous
5xx, malformed success and invalid audio do not trigger duplicate synthesis.
The same request ID and body are retained for an allowed fallback. A user's
explicit retry remains possible through the existing continuation checkpoint.

Responses are decoded and audio is inspected off MainActor. Actual decoded
duration is authoritative; MP3 and existing WAV compatibility are preserved.
Both timestamp key spellings are accepted. Existing language-specific timestamp
quality and segment highlighting policy remain in force.

Source consumption is separate from spoken tokens: exact wire-prefix/tail
validation maps trimming and repeated-hyphen normalization back to the source.
Requests over 5,000 UTF-16 units preserve the unsent tail and avoid splitting
Unicode graphemes or an available word boundary. Empty progress and inconsistent
partitions fail explicitly.

## Kindle causes and fixes

1. Held prefetch images are detached from the DOM. Their old fingerprint helper
   required a visible candidate, yielding an empty fingerprint. Confirmed page
   turns therefore discarded prepared OCR and repeated it. The shared raster
   fingerprint now works for both held and visible images; reuse still requires
   matching page identity and nonempty matching pixels.
2. The old capture loop finished OCR for up to 12 candidates before caching the
   first page or warming its audio. Each prepared page now becomes available
   immediately, and the first two candidates can warm audio before later OCR.
   Previously prepared OCR and matching voice/text audio are reused.
   Candidate discovery now sends only identities and small pixel fingerprints;
   raster encoding/transfer happens one image at a time, only for OCR cache
   misses. This avoids transferring twelve full PNGs during every warm prefetch.
   A real WebKit regression checks zero PNG encodes for discovery, exactly one
   for a requested raster, matching fingerprints, and unchanged visible pixels.
3. A TTS token such as `imprisoned-bound` can correspond to multiple OCR boxes
   across a line break. Alignment now preserves the complete ordered range,
   including the first highlight at a page handoff. Repeated later occurrences
   cannot displace an earlier matching compound. No synthetic word timing is
   introduced.

Page-turn confirmation, visible-pixel validation and the short display/highlight
gate remain in place. `KINDLE_HANDOFF` records preparation stage duration;
`-CastReaderTTSClockDiagnostics` optionally records skipped timestamp indexes in
debug runs. Stage duration is not an acoustic measurement of silence.

## Evidence

Artifacts are in ignored `build/direct-tts/` (local book logs are not committed).

- Baseline actual book: *A Journey to the Centre of the Earth*, B002RKRMSY.
  Seven automatic turns: zero prepared-page cache hits, seven misses.
- Iteration 2 actual book: five automatic turns, five cache hits, zero misses.
  Turn/preparation/overlay stages took 1,012–1,082 ms, within the existing
  1,400 ms audio-tail preparation lead. All 36 sampled synthesis requests used
  `tts.castreader.ai`, returned 200 and had `fallback=false`.
- Focused iteration 4: 149 test methods, 147 passed, 2 conditional skips,
  zero failures. Includes real AVPlayer continuation/pause tests, prefetch
  horizon, OCR compound order and transport cancellation/error contracts.
- Full suite plus live multilingual contract: 1,474 methods, 1,468 passed,
  6 conditional skips, zero failures (`final-full-live-contract.xcresult`).
  Eleven real requests across nine languages all used the direct host with no
  fallback. German preserved `Dr.` and `3.14`, English citations were silent,
  all source was consumed, and timestamp intervals fit decoded audio duration.
- Interactive Kindle regression passed (`final-kindle-live.xcresult`): three
  manual next turns, one previous turn, orientation round trip, font/footnote
  changes, two automatic turns, minimize/expand, pause, relaunch and preference
  restoration. Both automatic turns hit the prepared-page cache; preparation
  took 1,066/1,109 ms; display/highlight gate waits were 112/114 ms.
- A debug clock sample reported one skipped timestamp index during warm
  prefetch. The subsequent metadata-first optimization and expanded duration
  diagnostics require the final continuity audit below; index coverage alone
  is not a claim that every short word was visible on screen.
- Metadata-first continuity sample (`metadata-live-summary.json`): four
  automatic turns, four cache hits, zero misses; preparation 996–1,042 ms,
  highlight gates 88–112 ms. Across 29 alignment events, 588/588 timestamps
  mapped in order, with no skipped clock indexes in this sample. All 37
  synthesis responses were direct-host 200 without fallback. This measured
  portrait sample was collected before running the separate unit suite.
- A subsequent stable landscape view displayed both columns and controls
  correctly (`landscape-stable.png`). Playback was terminated after testing;
  the same final build was relaunched at the home screen with login data intact.
- Final whole-suite rerun after metadata-first capture passed
  (`metadata-final-full.xcresult`): 1,474 methods, 1,468 passed,
  6 conditional skips, zero failures. Includes another successful real
  multilingual transport probe and the metadata/raster WebKit regression.

At the initial audit, the simulator had an Amazon/Kindle session but its
CastReader settings showed Sign In / Sign Up. The user subsequently signed in
and requested the eight-page run below. Neither preset playback nor unit
coverage should be represented as real authenticated clone voice acceptance.

## Signed-in eight-page acceptance, 2026-09-08

The user's existing iPhone 17 Pro simulator ran the final candidate, still
1.2.35 (56), using the selected Heart preset and the same Kindle book. The
installed debug binary matched the built candidate by SHA-256. The app was
briefly relaunched to enable timestamp-clock diagnostics; no login data was
cleared and no voice, font or reading preference was changed by this test.

`testAuthorizedKindleEightPageContinuousRead` passed in 378.563 seconds:
eight automatic page transitions, nine distinct visible page identities, and
an explicit successful pause at the end. The test did not press next-page
controls. Reading began from the saved position, rather than resetting the
book to the start of a page.

Local evidence is in `build/direct-tts/logged-in-eight-pages/`:

- `preset.xcresult`: one test passed, zero failures or skips, with page-state
  and screenshot attachments.
- `preset-summary.json` and `preset-kindle.log`: eight prepared-page OCR cache
  hits, zero misses. Across 46 alignment events, all 939 timestamp entries
  mapped; no skipped clock indexes or nonmonotonic alignment was recorded.
  These are alignment entries, including streaming recomputation, not a count
  of unique spoken words or an acoustic transcription of the entire run.
- `preset-transport-only.log`: 57 synthesis responses, deduplicated by request
  ID for the test app process, all direct `tts.castreader.ai` HTTP 200 with
  `fallback=false`.

Continuous playback and timestamp alignment passed this sample. Page handoff
latency is **not yet consistently seamless**. Turns 6 and 7 found that warmed
audio belonged to a different speculative held page than the actual confirmed
next page. The correct page already had OCR cached, but its opening audio had
to be synthesized after confirmation. Identity checks correctly rejected the
other page's audio; playback resumed with the confirmed page's first highlight.

| Turn | Preparation stage | Estimated wait after previous audio end |
| --- | ---: | ---: |
| 1–5, 8 | 1,031–1,190 ms | 131–430 ms |
| 6 | 2,089 ms | 829 ms |
| 7 | 2,121 ms | 912 ms |

The estimated waits subtract the logged remaining audio time at the tail
trigger from elapsed time to the audio handoff boundary. They are not direct
measurements of acoustic silence. Total preparation time includes work while
the old page is still playing. A verbose simulator log stream was active for
most of the sample, so these are instrumented simulator timings.

The remaining issue is next-page audio candidate selection, not missing TTS
timestamps or an OCR cache miss. Held-image ordering is speculative and must
not replace confirmed visible-page identity. This test adds no production
code changes; clone playback and other devices remain outside this sample.

## Reproduction

Build with `CastReader.xcworkspace`, scheme `CastReader`; retain the local
ignored `Secrets.xcconfig` from the complete baseline. Never uninstall or erase
the user's simulator. Use a separate simulator for `CastReaderTests`, whose
existing tests intentionally change account snapshots and defaults.

The opt-in unit method
`ServiceRoutingTests/testLiveDirectPresetNineLanguagesAndSourceBoundaries`
requires runner environment `CASTREADER_DIRECT_TTS_LIVE=1`. It exercises eleven
short synthetic cases, including German abbreviations/decimal, English citation
suppression, compound words and all nine supported languages, through the real
iOS transport and audio decoder. Evidence is attached as JSON to the xcresult.

The existing
`KindleLiveAcceptanceUITests/testAuthorizedKindleReadTurnSettingsMinimizeAndRelaunch`
requires `CASTREADER_KINDLE_LIVE_ACCEPTANCE=1` and the already-authorized Kindle
simulator. It checks manual next/previous, rotation, settings and restored
preferences, two automatic page turns and process relaunch. Set the expected
installed version with `CASTREADER_TEST_APP_VERSION`; it does not sign in or
clear user data.

`KindleLiveAcceptanceUITests/testAuthorizedKindleEightPageContinuousRead`
uses the same opt-in environment and authorized simulator. It preserves the
selected voice, enables clock diagnostics, observes eight automatic changes
without repeated page identities, and pauses playback after the eighth turn.
