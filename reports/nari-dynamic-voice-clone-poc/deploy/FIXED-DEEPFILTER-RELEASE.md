# Fixed DeepFilter worker releases

Production creation uses `fixed-deepfilter-atten24-v1`: input quality and single-speaker checks, exactly one DeepFilter atten24 pass, enhanced-reference validation, and one x-vector prompt. It never selects raw audio or atten100, and never generates selection probes.

`CLONE_DENOISE_MODE`, canary percentages, and `.adaptive-denoise-mode` are obsolete and ignored by this worker. **Setting the old mode file to `off` is not a rollback.** Existing stored prompts and cached previews are not rewritten.

## Release boundary

Use `release-fixed-deepfilter-worker.py`. Package only committed Git blobs from an explicit full SHA, with an explicit manifest checksum. The allowlist is `clone_worker.py` and optionally `adaptive_denoise.py`; Nari, TTS, runners, credentials, and the Web control plane are not deployed.

The default `apply` operation is preflight-only. `--execute` additionally waits for an idle window, saves the previous files and writer marker, drains the worker, installs the exact bundle, rebinds the x-vector marker, restarts only the worker, and verifies creation readiness. China watchdog pause/resume prevents a restart during the source/marker swap; an independent resume guard covers interrupted releases.

## Verification order

1. Run worker unit tests in the existing Linux dependency environment.
2. Run `fixed_deepfilter_reference_preflight.py` on consented clean, noisy, mechanical, and short recordings. This does not create production voices.
3. Commit the scoped changes and package the immutable source with the release tool.
4. Run release preflight in both regions, without `--execute`.
5. Apply in China, then run `fixed-deepfilter-smoke.py` on loopback. The smoke test verifies actual DeepFilter execution from response and persisted metadata, builds a prompt, generates the exact Chinese preview text, validates its WAV, and deletes only the test IDs it generated.
6. Repeat apply and the smoke test in the global region. Check the same worker SHA, zero active creation tasks, and unchanged Nari/TTS processes.

The smoke fixture set includes `00-clean.wav`, `01-kitchen.wav`, `03-washing-machine.wav`, `04-meeting-room.wav`, and `short-4s.wav`. The last is a four-second crop of the consented clean sample. Tokens stay on the destination host. No user account, entitlement, or existing voice is modified by the smoke test. Its deleted voices may leave inaccessible embeddings in Nari's bounded LRU until normal eviction; no Nari restart is needed.

## Errors and recovery

- Invalid raw or enhanced recordings return a non-retryable 422 with recording guidance.
- DeepFilter runtime/dependency failure returns retryable 503 `VOICE_DENOISE_UNAVAILABLE`, without publishing a raw prompt.
- Creation dependency failure does not disable existing-voice playback health.
- The release tool automatically restores the exact old files and writer marker if activation or readiness fails. Retain its backup path for post-release rollback if creation/preview smoke fails.

For a post-release rollback, run the same bundled tool with `rollback --region cn|us --backup <exact-returned-backup>` to validate recovery first, then repeat with `--execute`. It only accepts the backup associated with the currently active release and verifies the original file and marker hashes. The rollback idle check does not require creation readiness, so a creation dependency failure does not itself block recovery.

The historical adaptive pipeline's 12-sample blind-listening win rate is not a measured win rate for this simplified fixed pipeline. Creation/preview smoke verifies functionality, not subjective audio quality.
