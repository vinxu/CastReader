# Kindle explanation stops after a retained prefetch expires

## Observed failure

Device: iPhone 15 Pro Max, iOS 26.7. The installed candidate already contained
the automatic-page ownership correction from `5621151`.

The device logs establish this sequence on September 23 (UTC+8):

- 14:53:33: the next page's first-block prefetch becomes ready.
- 17:02:33: that page is activated successfully and its cached first block plays.
- 17:02:34: background extraction of block 1 returns HTTP 404.
- 17:02:45: block 0 audio completes normally.
- 17:02:46: foreground extraction of block 1 returns HTTP 404; the VM enters error.

This failure occurs after a successful page transition. The cache was retained
for approximately 129 minutes. The mobile QuickRead gateway uses a two-hour job
lifetime; the client previously checked settings/content but not cache age.
The original device file log did not preserve the structured 404 response code.

## Changes

- Stamp first-block prefetches before the plan request. Reject entries aged
  110 minutes or more, and entries from a future wall clock. Kindle checks this
  when selecting, warming and consuming a prefetch; the shared Explain VM checks
  again before activation.
- Recognize the gateway's exact `QUICKREAD_JOB_NOT_FOUND` response. Generic 404s
  retain their normal error behavior. Record only operation/status and whether
  that error code matched; no credentials, source text or job capability.
- Keep extracted narration sections locally so completed extraction is not
  repeated when only synthesis remains.
- For a Pro Kindle session, allow one renewal at a failed block boundary using
  the original plan request. Verify the language, block count and every already
  generated prefix section before adopting the new job and requesting the missing
  block. Already played audio is retained and is not queued again.
- Preserve Pause and page ownership while renewal is in flight. Closing or
  replacing the page invalidates its late response.
- If the replacement plan differs or renewal fails, show the localized retry
  state; do not skip content by assuming the old and new block indexes coincide.
  Free sessions do not automatically create an additional billable plan.

## Verification

The existing release-baseline check passed. The app and tests built for the
physical iPhone; no simulator was used.

Eight targeted XCTest cases passed on the iPhone at 17:23:53:

1. Prefetch age boundary and backward clock change.
2. A 129-minute-old prefetch is replanned before its cached opening can play.
3. Exact job-unavailable recovery plays the opening once and the missing block next.
4. A changed replacement prefix is rejected without replaying or skipping it.
5. A second unavailable response cannot cause an unbounded renewal loop.
6. A generic 404 does not start a new plan.
7. Pause during renewal remains paused until the user resumes.
8. Closing the page rejects the late renewal result.

Tests use controlled HTTP responses and an injected clock on the real device;
they do not claim that two hours elapsed in a live service test. The first run
caught a missing error-code whitelist entry, which was corrected. A subsequent
run lost its wireless debugger connection; the final complete run passed all
eight cases. Result bundle: `/tmp/CastReaderJobExpiryTests3.xcresult`.

Live iPhone Mirroring verification ran from 17:29 to 17:31 on the installed
1.2.43 development app (dylib UUID `41ABE662-5337-39DB-903A-D0F99253A15F`).
The real Kindle book and production services were used, with no fixture responses:

- Page `0eaeb1ee2730` played blocks 0, 1 and 2 to completion.
- At 17:30:12.391 it automatically advanced to `333172238ffc`; that page also
  played all three blocks to completion.
- At 17:30:51.076 it automatically advanced to `9b4f6d55ef99`; blocks 0 and 1
  completed and block 2 continued before the test was manually paused.
- Mirror screenshots showed the new page's matching narration subtitles and
  annotations. The audio log showed one ordered 0/1/2 sequence per page, with
  no old-page block re-enqueued in this window.
- All 10 live TTS responses were HTTP 200; no QuickRead continuation failure,
  foreground block error or background block miss occurred in this window.

Logs: `/tmp/kindle-jobexpiry-live-final.log` and
`/tmp/reader-jobexpiry-live-final.log`. Intermediate log copies sometimes lost
their wireless file-service connection; both final copies succeeded after pause.
The live run confirms ordinary continuity across two automatic page transitions;
the expired-job scenario is covered by the controlled-clock device tests above.

iPhone and iPad share these implementation paths. No iPad was connected, so this
change has no additional iPad hardware acceptance claim.
