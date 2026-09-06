# US backend observation methodology

The fixed cutoff is `2026-09-06T00:24:11Z`. All time comparisons use UTC.

## Sources read

- US QuickRead host `140.82.14.49`: live PM2 process metadata, `/root/.pm2/logs/quickread-out.log`, `/root/.pm2/logs/quickread-error.log`, `/root/.url-video-agent/jobs/quickread-state/*.json`, Caddy configuration, and the Caddy system journal.
- US GPU host `castreader-us4090`: Supervisor status and lifecycle log, `/workspace/castreader-runtime/logs/playback.jsonl`, `/var/log/portal/castreader-clone.log`, deployed model-registry metadata, voice-file presence, and read-only health endpoints.

Before querying the GPU, the complete `/etc/vast-agents-guide.md` operating guide was read. No service was restarted, no configuration was changed, and no synthesis request was made.

## Privacy and counting rules

- Submitted text, source URLs, request/correlation IDs, user identifiers, IPs, tokens, email addresses, audio, and raw log lines were neither copied into this evidence directory nor included in the report.
- QuickRead job documents were reduced to state, section counts, total block counts, and timestamps. Their source URLs and content were not retained.
- GPU diagnostics were reduced to fixed stage names, HTTP status, elapsed time, event time, and numeric counts. Exception messages and fingerprints were not retained.
- Two failed Kokoro correlation values were placed briefly in a mode-0600 local temporary file solely for exact matching against 127 existing release receipt files. Only the zero-match result was retained, and the temporary file was deleted.
- A diagnostic-event count is not a request denominator. Kokoro records failures and selected recovery/degradation events, while QuickRead lacks a Caddy access log. The report therefore avoids manufactured success rates.
- `pro-gate allow` means identity and entitlement admission. It does not mean that the client played the complete result.
- A QuickRead state with all blocks means the server generated and checkpointed all explanation blocks. It does not prove downstream TTS or playback completion.
- Post-cutoff health snapshots are labeled separately and never counted as in-window outcomes.

## Source-classification rules

Known deployment fixtures occurred before the QuickRead observation window. Retained production logs do not carry a reliable human/monitor/operator marker, so production jobs are described as identity-bearing or source-unclassified rather than as confirmed human sessions. The two Kokoro failure groups did not match retained release receipts, but lack of a match is not proof of user origin.

## Observability gaps

- Caddy has no access-log directive on the QuickRead host, so total HTTP traffic, status distribution, and request latency cannot be reconstructed.
- Kokoro diagnostics omit ordinary successful requests. They can prove recorded errors and selected recoveries, but not total throughput or an overall error rate.
- Clone structured events cover scheduled jobs, while old unstructured lines do not have a trustworthy timestamp for the fixed-window query.
- Client and server records do not share a trace ID in the supplied telemetry. Time proximity is reported only as proximity and never treated as causal linkage.
