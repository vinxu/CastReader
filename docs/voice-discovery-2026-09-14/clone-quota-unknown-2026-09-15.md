# Clone allowance unknown-state repair — 2026-09-15

The status endpoint returned HTTP 200 with `clonePolicy: unavailable`, but fabricated `cloneCanApply: false`, zero usage/remaining allowance and a fallback reset date when the quota lookup threw. iOS ignored the unavailable policy and treated that zero as confirmed exhaustion. A later valid status or speech response could restore the balance. This defect was reproduced by injecting a lookup failure into the actual route handler; the historical popup's immediate status payload was not captured, so that precise incident attribution remains inferred. The account's ledger and subsequent successful new generation requests were inconsistent with genuine exhaustion.

## Final behavior

- The backend returns null for unknown clone eligibility, usage, remaining allowance and reset date. The unavailable policy remains explicit, while valid Pro and regular-voice information is retained. Known zero remains zero. Normal synthesis still enforces the server quota; no quota grant, reset or pricing change is part of this repair.
- iOS preserves its last confirmed allowance when clone status is unavailable, including compatibility with the previous server's erroneous zero-valued fallback. An unknown response also cannot clear confirmed exhaustion. A fresh account with unknown allowance is not locally misclassified as exhausted; the generation endpoint remains authoritative.
- Status, voice-list and speech requests take a sequence number when they start. An older read cannot overwrite a later applied quota snapshot; account invalidation advances the boundary. This is local response-order protection, not a server-side ledger revision protocol.
- Background prefetch failures no longer present the global quota alert over current playback. Interactive requests still report confirmed exhaustion. Status request IDs and quota-state logs improve correlation without logging credentials or reading text.
- No extra status request is added to selecting a voice or starting playback. No schema, model, discovery layout or synthesis scheduling change is included.

## Verification

- Backend: 33 status/entitlement/public-library tests passed; TypeScript passed. The route test covers lookup failure, recovery to 78 minutes and confirmed zero.
- iOS simulator: 161 tests executed, 158 passed and 3 StoreKit tests skipped because the local XCTest host returned `notEntitled`. No failures. The skipped cases are purchase, restore and expiry.
- Attached iPhone: two focused tests passed with isolated local stores, covering unknown status, confirmed exhaustion, stale reads/429s and account invalidation. These are device unit tests, not live backend fault injection or a complete playback UI test.
- Both canonical production APIs were checked using disposable regional mobile sessions and fixture quota buckets: 78 minutes returned 4,680 seconds, then a fully used bucket returned zero. The fixtures and subscriptions were removed and bucket cleanup confirmed. No audio was generated and no existing user's quota was modified by these checks. Production database failure was not injected.

## Deployed sources

| Component | Application source | Runtime |
| --- | --- | --- |
| Global | `00ef5c566d830fe42266eb1bb6746fb741437a3c` | `dpl_DyQXckktVvKQz7xRiVn4sTNrSvXr`, `api.castreader.ai` |
| China | `2251845f60d96ba4a2d4dc9368714dcb549b6771` | `/opt/castreader/release-20260915180927` |
| iPhone | `9f946ac42c2952f7ca4dced49f937f22f3e84b1c` | 1.2.40 (61), local development build |

The global candidate retained exactly the prior voice entries, languages, collections and discovery modules in both regions: 1,606 voices, including 1,323 community voices, and seven collections per region. All 14 crons matched. Both discovery flags remained enabled. The API alias was checked against the previous deployment immediately before assignment; only `api.castreader.ai` was moved. Its capability probe confirms the new source and unchanged regional Voice Gift contract. China deployment passed billing continuity, ingress and capability checks.

Global rollback target is `https://readout-il9sss2xx-castreader.vercel.app` (`dpl_Df3t4UccxmoydN9qJyUU9coqFajZ`); China predecessor is `/opt/castreader/release-20260915170844`. Roll back only the intended regional API if necessary, retaining regional billing configuration.

The iOS integration script built clean source `9f946ac` in `/tmp/CastReaderCloneLatencyDevice20260915`, preserving all checked release ancestors, EPUB TOC `ad4b885`, concurrency repair `24b28e3` and growth commits `48998e7`/`f94b41d`. The normal app was installed at 18:34:37 and launched at 18:34:39 (Asia/Shanghai), preserving app data. Debug dylib UUID: `05B062F6-09BE-3EFB-8D85-0AB458D7B31D`. Normal startup subsequently logged three successful nonzero quota snapshots. This does not update the App Store version.

Local detailed logs use `/tmp/castreader-quota-unknown-*`; the accompanying JSON contains the durable redacted acceptance results. The diagnosis reproduction is `/tmp/castreader-clone-quota-status-reproduction-20260915.json` and the diagnosis note is `/tmp/castreader-clone-quota-diagnosis-20260915.md`.
