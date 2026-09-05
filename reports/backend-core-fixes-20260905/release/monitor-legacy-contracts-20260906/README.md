# US core-audio monitor legacy-contract upgrade — 2026-09-06

This receipt covers only the independent US continuity monitor on `140.82.14.49`. It did not change or restart TTS, QuickRead, clone, Nari, Caddy, Node, ffmpeg, or any CN service.

## Result

- Source commit: `f6eb669178c665defff239fd8a60210b54894aeb`.
- Immutable 9-file artifact SHA-256: `7ec7b782a08d5d287b7b6feba253ec4e2472dc104f1ed2d9f3d9d24d89290eeb` (13,326 bytes).
- Release tree SHA-256: `7a2c0b1f0715d4db766a26fe84a5899a1c77b3107f2119d0907d766cef12236a`.
- `current` changed atomically from `/opt/castreader-core-audio-monitor/releases/272d3148-5c085a61` to `/opt/castreader-core-audio-monitor/releases/f6eb6691-7a2c0b1f`.
- The existing service and timer unit files were not reinstalled or edited. The timer was stopped only for the CAS/symlink window and is active, waiting, and still enabled afterward.

The one authorized fixed-text US run exercised the legacy **omitted `stream`** contract. It correctly recorded `supply_failed`, `http_502`, and `failedRequestContract=stream_omitted` after two attempts (one retry) in 14.909 seconds. This is a real upstream contract failure detected by the corrected monitor; it is not reported as monitor health, and it did not trigger rollback because the monitor program and persisted receipt worked as designed. No audio or diagnostic prose was stored in this evidence.

The before/after CAS proves the QuickRead target, symlink identity, PM2 PID/uptime/restart counter, process start ticks/argv/cwd, 65-file source tree, Caddy configuration, Node binary, ffmpeg binary, and monitor unit hashes were unchanged. QuickRead remained HTTP 200, `ok=true`, idle with queue zero. No business service was restarted.

## Verification boundary

The local source suite passed 21/21. During staging, the production host's Node 22 passed 20 non-stalled tests and a separate deadline smoke; the original synthetic stalled-fetch test otherwise let Node 22 exit because it owned no referenced socket or timer. A test-only correction then made that fake request hold a referenced timer like a real pending socket. The complete Node 22 suite passed 21/21 with zero failures, cancellations, or skips in a disposable directory. The deployed production files and immutable release were not changed for this additional test.

The run confirms the monitor now sees the legacy omitted-stream failure. It does not claim that the old Global gateway is healthy; the observed 502 remains a separate gateway deployment issue. CN was not touched.
