# Growth first-batch release — 2026-09-14

## Source and scope

- iOS: 1.2.40 (61), isolated branch `codex/ios-growth-release-1.2.40`, based on `b10d83ced9b450e63c1d5f4e021849122e2d59d0`; submitted 1.2.39 application baseline `64c2dbd934d34e7b000c8def1a4c8ee5dc94ab23` is an ancestor.
- Preserve shipped Kindle offline, AO3, source resume, reader More/Aa/sleep timer, and existing released voice functionality. Do not incorporate the main checkout's unfinished work.
- Existing US assignment only: setup card starts reading once, does not count as a trial impression; the real 30-second playback milestone enables the trial prompt. GB assignment, prices, quota, and activation-source eligibility are unchanged.
- Apple verification request includes captured analytics/stable device identity, iOS platform, version/build and storefront. Identity context is preserved over session refresh. Successful Pro verification remains successful if the optional growth bridge cannot link.
- DEBUG-only UI harness tests the actual coordinator, offer overlay and paywall using synthetic milestones, not live audio, library synchronization, or payments. Release archive must not contain its markers.

## Production backend: deployed and verified

- Runtime commit: `12901dc2228a703a0d2166e2970c3c30c54c9543`, PR https://github.com/scmyyan/readout-web/pull/33.
- Deployment: `dpl_3SfBuDdYewLAXNs3WxmaSmLfnxLX` / `https://readout-3famri55i-castreader.vercel.app`.
- Both `api.castreader.ai` and `castreader.ai` capability endpoints returned the expected release ID and commit after promotion. Existing capability values were preserved.
- Candidate and production unauthenticated probes of purchase/identity/config boundaries returned expected authentication errors. These are negative boundary checks, not a real production purchase.
- No schema/environment/pricing/CN/ad changes and no synthetic production database rows. Production error/warning scans were empty at the recorded observation time, not a permanent monitoring guarantee.
- 160 backend tests passed with isolated PostgreSQL. Concurrent immutable linking and conflict preservation were verified through the actual receipt route and SQL implementation, with Apple verification/authentication/subscription adapters injected. This is not Apple billing validation.
- Production gap audit is aggregate-only and read-only. Historical unresolved attribution/identity gaps remain unresolved.

## iOS verification

- Default-signed full unit suite: 1,696 passed, 0 failed, 8 skipped; `/tmp/CastReader1240-unit-signed.xcresult`.
- Focused signed routing suite: 103 passed, 0 failed, 1 skipped; `/tmp/CastReader1240-routing-signed.xcresult`.
- Initial unsigned unit run exposed seven Keychain-dependent routing failures; all passed with normal simulator signing. No source assertion was removed.
- Eight full-suite skips: opt-in live Explain, Play Books, service routing and YouTube tests; missing user PDF fixture; three StoreKit tests requiring unavailable SKTestSession authorization. No successful real StoreKit purchase is claimed.
- Initial UI run: growth path, onboarding and ordinary import passed (6/7); legacy Google Drive argument test failed at opening the import sheet. The unit-test simulator retained unrelated system rating state. A subsequent run had no rating window but still failed to open the sheet; clean-simulator recheck is required before treating this as environment-only.

## App Store gate

At preparation, 1.2.39 (60) remains `WAITING_FOR_REVIEW` (version `97b00cc5-b9eb-4bcf-9425-78e1faffc8c3`, review `d9065521-1b02-4bc9-9825-54e8871ab7e9`). Apple blocks creating 1.2.40 while that state remains. Do not withdraw it without explicit permission. Uploading a future build is allowed but does not constitute submission or availability to users.

11-locale What's New is prepared in `docs/AppStore-Whats-New-1.2.40.json`. Existing listing titles/subtitles, screenshots and legal declarations are to be preserved. Metadata and review submission must be verified separately after Apple permits the new version.
