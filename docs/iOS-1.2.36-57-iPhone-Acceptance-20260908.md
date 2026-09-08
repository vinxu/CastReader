# iOS 1.2.36 (57) iPhone acceptance — 2026-09-08

## Candidate and authorization

- App Store Connect readback: live 1.2.35, `READY_FOR_SALE`, attached build 56,
  `VALID`; maximum uploaded build 56. Candidate stays 1.2.36 (57) across retries.
- Base `e44894a` contains the complete submitted build 56. The candidate adds
  direct preset TTS and Kindle continuity changes from `6ea54f2`, plus the
  opt-in acceptance test recorded in `71ded20`.
- User authorized an overwrite installation on their iPhone, real preset and
  cloned-voice Read Aloud/Explain testing, and a reset of their own clone quota.
  App Store upload/submission is outside this request.
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
