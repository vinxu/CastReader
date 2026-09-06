# Vercel preset TTS event extraction

`collect_vercel_preset_events.py` reads the same `/api/logs/request-logs` endpoint used by installed official Vercel CLI code. The API query pins the caller-supplied deployment, production environment, explicit UTC request-start window, and `search=tts-preset`. It includes successes as well as failures. The local parser independently checks deployment, time and the five known TTS routes before parsing each nested log message as JSON lines. It exports only the reviewed `source=tts-preset` schema: fixed event/stage/error/transport-code enumerations, finite nonnegative numbers, attempt 0–3, Global/CN region, and 20-character anonymous request keys. Unknown fields, arbitrary messages, raw IDs, request/response bodies, URLs, tokens and exception text never reach the saved report.

The application key is `SHA256(x-request-id)[:20]`; use it together with `attempt` to join the US proxy's caller records. `vercelRequestKey` hashes Vercel's own ID and is a separate namespace. The report preserves separate provider requests even if application keys repeat. `attempt_failed`, `retry_scheduled` and `request_finished` can refer to the same fault; `terminalCodes` separately counts terminal outcomes.

The window is a **request-start cohort**. Vercel timestamps describe the incoming request; `elapsedMs` starts later in the application executor. Application events do not carry absolute wall time, so their times are not derived by adding elapsed time to the Vercel timestamp. Nested completion events can occur after the query end. Provider ingestion may be delayed, and a search miss/empty page cannot establish zero traffic or playback health. Caps, truncation, missing schema fields and missing start/finish records are explicit coverage fields. Complete pagination means only that the currently returned request cohort was read; ingestion completeness remains unverified.

The collector uses only the existing linked readout-web project and local Vercel CLI auth file; credentials remain in memory. HTTPS redirects are rejected to avoid credential forwarding, the default SSL context is supplemented with certifi CA roots, and certificate plus hostname validation remain enabled. This machine's Homebrew Python lacks certifi. Use the already installed framework Python below, which has certifi; no TLS bypass or package install is needed.

```sh
/Library/Frameworks/Python.framework/Versions/3.13/bin/python3 -B collect_vercel_preset_events.py \
  --start-utc 2026-09-06T16:45:55.382733Z \
  --end-utc 2026-09-06T16:54:27Z \
  --expected-deployment dpl_E3vhShktBut8yrPjXLViPqhp1zRt \
  --output vercel-preset-20260906T165427Z.json
```

Each output path must be new. The first live query showed that provider `page` increments returned the same 50 requests, so the collector now walks the original UTC window backwards using the earliest returned request timestamp plus a 1 ms overlap. Overlap rows are deduplicated. A timestamp boundary that cannot advance stops immediately with incomplete coverage; it never loops or silently skips tied requests. The original incomplete snapshot is retained as evidence. The default collection cap is 20 pages / 5,000 rows / 16 MiB per page / 16 KiB per log line, with explicit failure or incomplete coverage at limits. Seven local tests cover sanitization, malformed field types, deployment/path/window pinning, anonymous namespaces, duplicate/truncated logs, API parameters, and certifi with enforced TLS verification, time-window overlap, and stopping on a repeated timestamp boundary.
