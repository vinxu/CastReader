# CN core-audio monitor legacy-contract upgrade — 2026-09-06

This receipt covers only the independent CN continuity monitor on `106.54.47.163`. The same reviewed 9-file artifact used for US was staged and verified before the active link changed.

## Result

- Source commit: `f6eb669178c665defff239fd8a60210b54894aeb`.
- Artifact SHA-256: `7ec7b782a08d5d287b7b6feba253ec4e2472dc104f1ed2d9f3d9d24d89290eeb` (13,326 bytes).
- Release tree SHA-256: `7a2c0b1f0715d4db766a26fe84a5899a1c77b3107f2119d0907d766cef12236a`.
- `current` changed atomically from `/opt/castreader-core-audio-monitor/releases/272d3148-5c085a61` to `/opt/castreader-core-audio-monitor/releases/f6eb6691-7a2c0b1f`.
- The existing service and timer unit files were unchanged. The timer is active, waiting, and enabled afterward.

The authorized fixed Chinese probe exercised the first legacy request with `stream` omitted. It recorded `supply_failed`, `http_502`, and `failedRequestContract=stream_omitted` after two same-contract attempts in 6.702 seconds. This is an observed public CN gateway contract failure. The monitor remained on the corrected release because it persisted and classified the supply failure correctly; the run was not retried with a different contract to manufacture a healthy result.

The fresh CAS used the rolled-back production Next process PID 1621449 and its exact start ticks, target, descriptor, symlink identity and 7,216-file/36-symlink release material. Before and after also match for QuickRead PID 1608646, Kokoro tunnel PID 1029281, clone tunnel PID 2090236, Nginx PID 12692, restart counters, process identities, and configuration hashes. Next, QuickRead, Kokoro and clone health endpoints all returned HTTP 200 after the monitor run. No business service was restarted, and no user text, audio or credentials were recorded.

The result verifies that the new monitor detects the omitted-stream regression. Because the first request failed before audio, this particular run cannot claim successful full-text audio continuity. Resolving the gateway failure and observing a later timer run are separate from this monitor-only deployment.
