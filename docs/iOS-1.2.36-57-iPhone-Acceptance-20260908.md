# iOS 1.2.36 (57) iPhone acceptance — 2026-09-08

## Candidate and authorization

- App Store Connect readback: live 1.2.35, `READY_FOR_SALE`, attached build 56,
  `VALID`; maximum uploaded build 56. Candidate stays 1.2.36 (57) across retries.
- Base `e44894a` contains the complete submitted build 56. The candidate adds
  direct preset TTS and Kindle continuity changes from `6ea54f2`, plus the
  opt-in acceptance test recorded in `71ded20`.
- User authorized an overwrite installation on their iPhone, real preset and
  cloned-voice Read Aloud/Explain testing, and a reset of their own clone quota.
  The later “没问题就打包 提交的appstore” request conditionally authorizes
  archive/upload/submission after outstanding acceptance issues are resolved.
- Physical device: iPhone 15 Pro Max, iOS 26.6.1. It initially had 1.2.35 (55).
  The diagnostic 1.2.36 (57) app was installed without uninstalling or clearing
  login, Kindle or application data.
- Added stable accessibility identifiers for mode, voice selection and the
  Explain play/pause control, plus its playback state. These expose existing
  state to the opt-in test; playback behavior is unchanged.

## Authorized quota reset

The active global account was verified against the phone's current profile
and the backend user record. Its active subscription period was matched to the
server's SHA-256 quota period key, rather than modifying a legacy calendar or
membership bucket.

- Before: used 7,190,687 ms; reserved 0; remaining 9.313 seconds, displayed as
  zero whole minutes.
- After reset and database readback: used 0; reserved 0; remaining 7,200 seconds.
- Reset date stays 2026-09-14 13:08:57 UTC. Subscription and historical buckets
  were not changed; all 1,507 historical generation ledger entries were retained.
- The operation used the same per-account/period advisory lock as synthesis,
  required the inspected values to remain unchanged and no pending reservations,
  and saved before/after evidence under the ignored acceptance directory with
  private file permissions. Subsequent tests consume the restored allowance.

## Initial physical-device sample

Heart preset, existing 1.5× playback preference, eight automatic page turns.
The UI continuity test passed and paused explicitly at the end. This does not
mean that visual continuity or latency acceptance passed.

- 85 alignment events: 1,667/1,667 timestamp entries mapped. Entries include
  streaming recomputation and are not a unique spoken-word count.
- 101 clock diagnostics recorded 111 skipped display indexes. They indicate
  display updates missing short timestamp windows, not proof of missing audio.
- Four confirmed turns corrected a speculative prefetched audio target. The
  wrong page's audio was rejected and the actual next page's opening generated.
- Estimated extra handoff waits: 162, 418, 374, 2,548, 1,431, 2,004, 1,033 and
  1,262 ms. These subtract the rate-adjusted remaining old audio time from the
  handoff boundary time; they are not acoustic silence measurements.
- Frequent XCTest accessibility queries and a verbose device syslog stream
  affected this sample. The latter was stopped and only app-specific lines
  retained. A quiet sample is required before attributing the display misses
  or all of the additional delay to normal foreground use.

## Remaining acceptance

| Case | Status |
| --- | --- |
| Kokoro Read Aloud, eight turns | Continuous playback passed; display/latency acceptance open |
| Kokoro Read Aloud, quiet interval | Pending |
| Clone Read Aloud, quiet interval | Pending |
| Kokoro Explain, quiet interval | Pending |
| Clone Explain, quiet interval | Pending |

The first quiet-test attempt found an automation identifier mismatch: the
ReaderMode raw values are Chinese. Explicit language-independent identifiers
fixed the test selector. The next attempt could not start because the phone
became unavailable at 10:21 local time. The user was asked to reconnect/unlock
the phone. This is retained as an incomplete acceptance, not a passing test.

## Reproduction and artifacts

Ignored directory: `build/iphone-acceptance-20260908/`.

Build preflight, device Debug build-for-testing, Release archive, development
export, and signature/version verification passed. App, Share extension and
Widget are all 1.2.36 (57). Local artifacts are:

- `CastReader-1.2.36-57-iPhone-acceptance.ipa`: signed diagnostic package for
  the current global-account device acceptance; `packages.json` records its hash.
- `CastReader-1.2.36-57.xcarchive`: normal Release archive, with internal
  distribution overrides disabled.
- `release-device-export/CastReader.ipa`: development-signed Release export.
  It has not been installed or tested on the phone and follows production
  storefront routing, unlike the internal diagnostic package.

The physical device remains disconnected after the initial installed candidate
and failed selector setup attempt. The final selector correction is built and
packaged locally; its installation and remaining live cases await reconnection.
No App Store version/build was created or uploaded, and no TTS server code or
configuration was changed. Prior full unit-suite evidence for the direct-TTS
business changes is in `iOS-Direct-TTS-Kindle-20260908.md`; this turn's UI-state
identifiers and version changes do not constitute a new full-suite execution.

- `kokoro-read.xcresult`, `kokoro-read-build.json`, `kokoro-read-session.log`,
  `kokoro-read-summary.json`, `kokoro-read-handoffs.json`.
- `iphone-app-only.log`: app-specific subset of the first instrumented sample.
- `quota-reset-before-private.json`, `quota-reset-receipt-private.json`:
  private account evidence, never committed or included in installation packages.
- `preflight.json`, `online-build.json`: build and live baseline verification.

Only run the selected `CastReaderUITests` methods on the user's device. Do not
run account-mutating `CastReaderTests` there. The additional opt-in method is
`KindleLiveAcceptanceUITests/testAuthorizedKindleVoiceAndModeContinuousRead`:

```text
CASTREADER_KINDLE_LIVE_ACCEPTANCE=1
CASTREADER_ACCEPTANCE_MODE=read|explain
CASTREADER_ACCEPTANCE_VOICE=preset|clone
CASTREADER_ACCEPTANCE_QUIET_SECONDS=180|360
```

The method selects voices through the ordinary UI after resolving the mode's
actual language. During the quiet interval it does not query or interact with
the app UI. Collect the app's existing diagnostic files afterward and verify
page changes, generation continuity, alignment and final playback state.

The phone currently uses an internal global-region override while its cached
App Store storefront is China. A normal Release build follows storefront and
ignores that internal override. Global-account testing must preserve the
explicit internal testing configuration; it must not silently migrate account
credentials or weaken production region rules to force a passing test.


## Submission iteration after phone reconnection

The phone reconnected on 2026-09-08. Three Xcode runner attempts failed before
entering the App because the device's test control channel refused the IDE.
Restarting/unlocking the phone restored that channel. Two subsequent setup
failures exposed a zero-frame control during presentation and the user's visible
clipboard suggestion covering the shelf. The opt-in UI test now waits for
laid-out controls and dismisses the suggestion with **Ignore**, without reading
or changing clipboard contents. These failed runs are retained and never counted
as playback passes.

Intermediate evidence under `build/appstore-1.2.36-57/`:

- `pre-fix-unit.xcresult`: 1,474 tests, 7 conditional skips, zero failures.
- `handoff-targeted.xcresult`: four scheduling tests passed.
- `post-fix-unit.xcresult`: 1,475 tests, 7 conditional skips, zero failures.
- `explain-targeted.xcresult`: 56 page-turn, initial-start and settings ownership
  tests passed.
- `page-tail-targeted.xcresult`: scheduling and bounded prefetch tests passed,
  including two new production-VM tests for a short final paragraph and an
  unfinished future request.
- `simulator-clone-read.xcresult`: three quiet minutes, five automatic turns,
  498/498 timestamp entries mapped across 30 alignment events. Seven clock
  events involved nine missed display indexes (mostly 24–40 ms windows, one
  group immediately after a page boundary). One speculative miss produced an
  estimated 3.9 second extra handoff wait. This is the earlier 1.4 second build.
- `simulator-preset-explain.xcresult`: four quiet minutes, seven automatic turns,
  no automatic stop. Page preparation ranged 1,750–3,594 ms; the longest logged
  audio-end-to-next-playing interval was 11,662 ms. A “page advance success” log
  means the new VM started preparation, not necessarily that audio was audible.
- `simulator-clone-explain.xcresult`: four quiet minutes, six automatic turns,
  no automatic stop. Page preparation ranged 1,710–3,237 ms; the longest logged
  audio-end-to-next-playing interval was 10,750 ms.
- `iphone-preset-read-v3.xcresult`: four quiet minutes, six automatic turns,
  1,012/1,012 timestamp entries mapped across 57 alignment events, **zero clock
  misses**. Extra page handoff waits were 326, 314, 1,664, 2,084, 330 and 227 ms.
  This run used the intermediate four-second lead limited to the final segment.
  Its short final paragraphs exposed why increasing the constant alone was not
  sufficient. The longest logged audio interval (including paragraph boundaries)
  was 3,820 ms. These are log intervals, not acoustic recordings.

### Resulting client changes

1. Read preparation uses the generated remainder of the whole current page,
   including prefetched final paragraphs. Missing/in-flight paragraphs cannot
   count as zero remaining time. It may prepare under the held old-page image
   before the last paragraph, while that image's native word highlight continues.
2. Publishing next-page audio remains a separate step, allowed only when the
   actual final paragraph has installed its complete queue. Retargeting updates
   prepared state first and replaces pending audio only if it was appended.
   Existing exact-page, fingerprint, first-highlight, quota and one-action gates
   remain in force.
3. Explain shares the bounded twelve-candidate OCR cache used by Read. It still
   generates a speculative first Explain payload only for the first candidate;
   twelve OCR entries do not mean twelve LLM/TTS generations.
4. A prepared page already confirmed visible with stable geometry is not made
   to wait a second time for the same layout. A restoration/reflow still waits
   before installing the overlay.

The final full suite and subsequent device acceptance must be recorded before
submission. Existing intermediate archives remain immutable. The new archive is
`build/appstore-1.2.36-57/CastReader-1.2.36-57.xcarchive`. Build 57 has not yet
been uploaded at the time of this entry; no production TTS code was changed.


### Whole-page Read acceptance and Explain follow-up

`iphone-clone-read-final.xcresult` passed after five quiet minutes on the physical
iPhone (11:25:11–11:30:11 local). Seven automatic page transitions completed.
All 1,202 timestamp entries mapped across 65 alignment events. Nine individual
display indexes had 13–40 ms windows; there were no grouped clock misses. The
maximum logged audio-end-to-next-playing interval was 754 ms. Extra page handoff
waits were 218–478 ms. Playback was explicitly paused by the test at the end.

`final-unit.xcresult` and `explain-tail-full-unit.xcresult` each completed 1,477
tests with seven conditional skips and zero failures. `explain-tail-targeted.xcresult`
completed 34 page-turn, prefetch-horizon and fast-lane contract tests without
failures. The final cache-settings guard was added after that full run, so
`release-final-unit.xcresult` and the subsequent final UI matrix remain the
authoritative release checks.

Additional Explain fixes in this iteration:

- Voice changes immediately rewarm the actual/prepared successor. Each async
  request has a unique owner, so an older cancellation cannot clear its replacement.
- Prefetched payloads retain voice, requested output language and depth. They
  must still match at generation completion, cache consumption and VM adoption.
- Kindle now advances only from the VM's authoritative settled-plan completion.
  A temporary completed fast opening cannot skip later blocks of the same page.
- During the final ten seconds of a fully prepared final Explain block, the
  single-page reader may prepare the actual semantic next page. Its old OCR
  raster stays visible and the same timed marks continue through the native
  photo-anchor/ink renderer. Already drawn marks are not animated again.
- The semantic action and its dispatch evidence survive until completion. A
  delayed/lost confirmation cannot cause another speculative next action.
  The held page is released only after the confirmed successor is activated.

A read-only backend check after the clone Read test found 158 successful
requests for this account since 2026-09-08 00:00 UTC, used_ms=1,094,350 and
reserved_ms=0. No further quota reset or server changes were made.

The final archive is being rebuilt at
`build/appstore-1.2.36-57/CastReader-1.2.36-57-final.xcarchive`; earlier archives
remain immutable and build 57 is still unuploaded at this entry.


### 12:20 follow-up: Explain geometry and hidden session preflight

The 11:52–11:57 simulator preset Explain test kept playing across seven turns,
but the longest logged audio gap was still 8,736 ms. Only the first page entered
early preparation: the viewport rectangle was cached with the first page's key,
and subsequent pages did not refresh that evidence when their dimensions were
unchanged. Each Explain page now starts the existing two-sample, context-fenced
geometry measurement. The early-preparation eligibility continues to require an
exact current page key, stable single-page geometry and synchronized native marks.

The tail budget now includes every fully generated remaining Explain block, so
a short final block does not reduce the available preparation time. Any missing
block keeps the tail unavailable; speculative/unfinished plan counts never
permit an early semantic turn. Audio promotion still follows the normal block
queue and the complete authoritative plan.

The physical clone Explain run paused at 11:55:28 while segment 1-3 was only
partially consumed. The user subsequently confirmed **an incoming phone call**.
This run remains interrupted rather than an uninterrupted acceptance pass. No
change was made to automatically resume after a system interruption.

Opening a book exposed a different UI problem: warmShelfSession installed its
internal, normally sized shelf WebView without the auth-recovery cover on the
preflight path. A dedicated session-preflight flag now covers that surface with
the existing localized Opening message and hides its accessibility subtree. It
still uses the same Amazon session/account and canonical navigation gate; it does
not skip authentication or erase cookies. The temporary WebView stops loading
and is detached when the bounded preflight completes/cancels.

`explain-geometry-unit.xcresult` passed at 12:14:27 on the disposable QA simulator:
1,477 tests, seven conditional skips, zero failures. A fresh device test build
succeeded; six-minute clone Explain on the phone and preset Explain on the
logged-in simulator are running. Build 57 remains unuploaded and unsubmitted.


The six-minute geometry tests both passed uninterrupted:

- Simulator preset Explain (12:22:51–12:28:51): nine committed automatic turns,
  ten early preparations including the next pending page. Longest logged audio
  gap 1,140 ms. One 6.4-second cold preparation completed beneath the old page.
- Physical clone Explain (12:23:27–12:29:27): eight committed automatic turns,
  eight early preparations. Two cold successors required 10,946/12,654 ms,
  exceeding the ten-second preparation window; longest audio gap 3,162 ms.

These measurements use the pre-run reader-log line offset to exclude older
launches with the same clock times. Every committed old/new key forms a
continuous chain; test completion explicitly pauses playback.

The clone-specific preparation budget is now sixteen seconds (preset ten).
All remaining block audio must already be complete before either budget applies.
A separate review found that manual navigation during a held old page could
apply another native action relative to the hidden successor. The manual path
now cancels and observes the outstanding action first. Next adopts the stable
successor without another forward dispatch; Previous reverses that preparation,
verifies the displayed page by exact key or pixel fingerprint, then performs the
requested previous action. Stale navigation epochs and uncertain actions cannot
issue another forward action. The opt-in live UI matrix includes both actions
while a prepared old page is held. A full unit rerun precedes that UI test.


`held-navigation-unit.xcresult` passed at 12:40:43: 1,477 tests, seven conditional
skips, zero failures. The production archive
`build/appstore-1.2.36-57/CastReader-1.2.36-57-handoff.xcarchive` passed deep/strict
code-signature verification; App/Share/Widget are all 1.2.36 (57), minimum iOS
17.6, internal distribution controls are NO, and the app declares no non-exempt
encryption. The main executable SHA-256 is
`60d38da5c699d1197ed1f4f42258c10a682d81d1bbc8b3fe1bf2ed31762737ff`.
The archive remains immutable and unuploaded pending final device acceptance.

Both opt-in manual-navigation regressions passed on the logged-in simulator:
`simulator-explain-held-navigation.xcresult` (118.9 seconds) and
`simulator-read-held-navigation.xcresult` (138.2 seconds). Each waited for a
confirmed prepared successor while the old page was still held, pressed Next,
and asserted that the resulting page was exactly that successor. Each then
pressed Previous during a later hold; logs proved reversal back to the displayed
page before the requested previous action. Both resumed playback and ended with
an explicit Pause. This test polls UI only for navigation evidence; its display
timing is not used as a word-highlighting performance sample.


The physical clone regression with the sixteen-second budget passed:
`iphone-clone-explain-16s.xcresult`, six quiet minutes (12:42:01–12:48:01), eight
automatic commits and nine early preparations including the pending successor.
Cold preparations of 11.3–16.7 seconds were exercised. Longest logged audio gap
was 1,304 ms. No terminal handoff errors occurred and the old/new page-key chain
was continuous. A physical Kokoro Explain sample is now running as the last
release acceptance case; build 57 is still unuploaded.


The final physical preset run using the previous ten-second budget passed
continuous playback but still measured a 2,403 ms maximum audio gap. Cold preset
pipelines took up to 11.8 seconds because explanation planning is also part of
the critical path. The selected voice attachment identifies `presetVoiceSelect_zf_001`.
The final policy therefore uses sixteen seconds for the complete Explain
pipeline with either preset or cloned voices. This changes only the preparation
budget; the already validated page evidence, manual-navigation and mark ownership
gates remain the same. The affected core/Kindle/fast-lane suites passed in
`unified-explain-window-tests.xcresult`; another physical preset sample exercises
the final budget before upload. The replacement immutable archive is
`CastReader-1.2.36-57-verified.xcarchive`.

A scoped, read-only production check at 12:52:51 found 368 successful clone
requests since 2026-09-08 00:00 UTC, used_ms=3,706,729, reserved_ms=0. Ledger
actual_ms equals the bucket usage. No further quota reset, account changes or
production server edits were made.
