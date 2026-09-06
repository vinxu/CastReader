# Direct gateway production rollout completed

**2026-09-06 16:52:02.916 UTC: production verified and candidate drained/stopped.** Source `1213fcd3`, runtime SHA `2ca971e8f61fd004cb638a9740a6dcd459423fbcdb16956261154ed580ec282d`. First new traffic 16:51:50.889 UTC. Caddy and QuickRead PIDs retained, exact Caddy configuration restored; before/after private backup readback verified. See [status receipt](status-receipt.json). The collector compatibility patch was applied by the parent and tested before deployment. The preparation notes below are historical and do not describe current deployment status.

## Reviewed candidate

Code commit `1213fcd3f9f616e92e9fd3a8f1e817b5095986c5` is based only on the deployed Direct commit `b9e7e9129e49f882398289511bbb90dbda8c6c08`. Candidate gateway SHA-256: `2ca971e8f61fd004cb638a9740a6dcd459423fbcdb16956261154ed580ec282d`.

The gateway retains the 120-second budget, US stable ingress, listener, request payload and voice/continuation behavior. It records the first abort source and stage, separately records downstream disconnection, cancels abandoned upstream transport, and does not attempt an HTTP response after the downstream connection closes. Only the local timeout establishes a 504. An upstream AbortError without that evidence returns 502. This improves cancellation correctness and attribution; it does not prove who closed the connection, fix an iOS player failure, or increase successful audio under upstream overload.

Logs use the existing cross-service hash convention: SHA-256 of request ID, first 20 hex characters. Raw IDs stay in request/response correlation headers and are omitted from logs. No text, audio, credentials or exception messages are logged. `status: null` means no HTTP headers were sent. A sent 200 is not proof of playback or final network delivery.

Validation completed locally: 17 gateway tests, `node --check`, clean git diff; 5 inherited deployment fault tests, 2 collector compatibility tests, all prepared Python sources parse. The gateway tests cover true timeout during headers/body, actual local upstream socket closure after downstream disconnect, no attempted 504 on a disconnected socket, unknown AbortError as 502, incomplete upload with no synthesis dispatch, regional pinning, and complete audio across legacy stream contracts. No production access, synthesis, candidate staging or deployment was performed during preparation.

## Collector compatibility before gateway deployment

`collector-compat.patch` applies only to `reports/backend-audio-iteration-20260906/monitoring/remote_tts_gateway_snapshot.py`; `remote_tts_gateway_snapshot.candidate.py` is its full reviewable result. The active collector and all previous observations remain untouched.

- Existing `requestId` is hashed exactly as before. New `requestKey` is validated as 20 hex characters and used directly, avoiding a second hash and preserving de-duplication keys.
- Closed requests with `status: null` remain in request totals and `no_response` counts, with separate abort-source/disconnection counts and up to 200 sanitized non-HTTP request rows for de-duplication. They count as neither HTTP success nor HTTP 504; `nonHttpRequestsTruncated` reports any cap.
- New fixed error codes distinguish `downstream_closed`, `upstream_timeout`, `upstream_aborted`, and `upstream_unavailable`. Old `timeout_or_abort` classification remains unchanged. The previous four historical Direct 504s retain their original status and ambiguous cause; no new fields are inferred retrospectively. The four Global 28-second application-budget 504s are a separate source and are unchanged.
- Monitoring must inspect the new disconnection/non-HTTP counts as an outcome alongside HTTP 5xx; they must not disappear merely because 504 counts fall. The 2-test compatibility fixture verifies that four old ambiguous 504s survive unchanged while a new close is independently counted.

## Prepared release sequence for parent review

The operator pins the exact clean worktree and HEAD, source bytes and SHA. `plan` is local only. `baseline` is read-only production access, verifies current source/unit/Caddy hashes and owning PID, and saves a new immutable baseline. It deliberately refuses to reuse the earlier rollout PID or allow changed configuration. If a baseline comparison fails, review the changed identity instead of relaxing the gate.

Run from this directory after review:

```sh
python3 operate-release.py plan
python3 operate-release.py baseline
python3 operate-release.py stage
python3 backup-same-region.py baseline
python3 operate-release.py apply
python3 operate-release.py status
python3 backup-same-region.py production
```

`stage` creates a distinct loopback candidate on 17778 and performs the existing fixed non-user audio/ffmpeg probes. `apply` first validates candidate digest/PID/unit, production baseline CAS, and verified private Global backup, then enables the candidate for restart survival, changes only the existing Direct Caddy target, waits for old in-flight work to drain, replaces/restarts the permanent process, verifies complete audio, restores exact Caddy bytes, commits a durable receipt, drains the candidate and stops it. Same-region backup data and credentials follow the existing reviewed US-host-to-private-Global-storage path. No credential is embedded in these artifacts.

The inherited failure path keeps the candidate available until old production is restored and verified, refuses to overwrite independently changed Caddy bytes, and never rolls back already committed production for cleanup-only failure. The inherited drain signal is the gateway handler's `in_flight` count, not proof of audio playback or TCP acknowledgement at the end device. This candidate does not change that existing release contract.
