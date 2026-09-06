# US Kokoro R132 repeated-digit G2P repair

## Finding

The six R132 HTTP 500 responses observed from `2026-09-05T17:32:59.753515Z` through `17:33:09.636921Z` failed before `KPipeline.infer`; no PCM was produced. They form two correlation groups with three HTTP attempts each. Every response made two complete model-unit attempts, and each attempt failed first in source-timestamp preparation and then in the audio-only fallback, producing the observed 24 `english_g2p_recovery_failed` events.

The retained diagnostic shape was exactly two ASCII characters, both alphanumeric. On the exact production source and production Python environment, an exhaustive check of all 3,844 two-character ASCII alphanumeric values for both American and British English found six values that initially need recovery, but only one value that remains unrecoverable after R132's full recovery path: a repeated ASCII `DIGIT ZERO` token. This is a uniquely matching reproduction in the exact environment and is strong causal evidence. It is not a claim that the original request text was read or recovered; that text was neither inspected nor retained.

spaCy classifies that repeated numeric token as `NFP`; Misaki treats that tag as punctuation and emits no phonemes. R132 correctly tries isolated and spelling recovery, but its spelling fallback sends ASCII digits back as bare digits. For the repeated token this creates two bare numeric items, the first of which is again classified as `NFP`; the candidate completeness check then rejects the whole unit. NFKC does not change ASCII text, so the nominal normalization branch is not involved in this case.

The production source matched the local base exactly before implementation:

- source commit: `dd613e1c6dab280d6110455f7b721301ddbbb857`
- `english_g2p_recovery.py`: `756be3fbe02d5f44bdbe756503f8d08dcb9fe09ee52db13c0be19bfaa791822a`
- `kokoro_v1.py`: `591f6d910fa7c02297cf46f9df9bbfdf7327222d2cce4e96c9c4580f66377d9f`
- `compatible_english_timestamps.py`: `5aaaa66e015772f8ffae73f915685b7fa58d48e9983e3e0135e2b345a31f3c99`

## Change

The isolated worktree is `/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-g2p-short-unit-r133`, branch `codex/kokoro-g2p-short-unit-r133`, commit `ca857ee91c3367999fb905de1f0924a6e28edd81`.

Only the existing final spelling fallback changed. At `api/src/inference/english_g2p_recovery.py:86-94`, ASCII letters retain their current uppercase spelling and ASCII digits are converted to their Unicode digit names (`ZERO` through `NINE`) before the same installed English frontend runs. Ordinary numbers that already work in the isolated or NFKC stages never enter this fallback. The model package, voice, speed, region, route, dependencies and wire response are unchanged. The new source SHA is `06953419d01f961c70b22b12b4d59ecdfaa187e699cc555b3be4109522368e4e`.

## Verification

- 62 source unit/integration tests passed: English G2P recovery, playback priority and atomic complete-audio generation. Eleven release-contract tests and four private-backup contract tests also passed, for 77 related checks in total.
- The new regression at `api/tests/test_english_g2p_recovery.py:51-55,135-180` verifies all ten digit names and the repeated-zero case on both American and British frontends.
- It proves the source label remains the original two-character token, both digits receive phonemes, the recovered pronunciation appears exactly once, source-timestamp preparation retains the complete text, and the audio-only fallback produces the same complete phoneme stream without loss or repetition.
- An exhaustive local post-change matrix checked all 3,844 two-character ASCII alphanumeric values for each English frontend: final unrecoverable count changed from 1 to 0 for both.
- `py_compile` and `git diff --check` passed. The worktree is clean after commit.
- A broader timestamp test class could not initialize because its inherited fixture path `api/src/models/v1_0/config.json` is absent from this thin source worktree. The new regression directly exercises the same `prepare_english_chunks` path using the repository's available `api/src/builds/v1_0/config.json`; no failing assertion was suppressed.

The immutable candidate was exercised with real model inference and audio synthesis on CPU at a loopback-only port. No production process was restarted, no production GPU model was replaced, and no public route was changed; R132 continued serving throughout.

## Prepared rollout

Release tooling is committed at `982023795bb132e61f3de9622068cdd28dfc91c3`. It built `/workspace/castreader-runtime/releases/20260906-kokoro-repeated-digits-us-r133` by copying the exact 828-file R132 snapshot into a new directory and overlaying only `api/src/inference/english_g2p_recovery.py`. The derived candidate manifest contains 778 non-bytecode files and has tree SHA-256 `d9bcd4d1f6f578eb90728dc82650ae7abc43e1756ffd63196baffcf1e7d508fe`.

Immediately before staging, all three private US recovery objects were fully downloaded again: the shared R130 base, exact R132 delta, and R132 recovery receipt. All 3,325,053,235 bytes matched their local SHA-256 values; this was a complete content read, not an object HEAD check. The candidate then ran at `127.0.0.1:18880` with `CUDA_VISIBLE_DEVICES` empty. Seven fixed operator cases covered American and British voices, timestamps on/off, audio-only trigger/control pairs, and a long 14-repeat tail-completeness input. Every result had non-empty fully decodable MP3, the timestamp cases retained the original `00` source label and final word, and the audio-only trigger added an audible interval over its control. The long case decoded 1,536,768 PCM samples and retained 145 timestamps. Candidate diagnostics contained seven expected `english_g2p_recovered` events, zero `english_g2p_recovery_failed`, zero `model_unit_retry`, and zero malformed rows. The candidate acquired no GPU context and was stopped after validation. Production Kokoro, Clone, and Nari identities remained unchanged.

The reviewed cutover payload SHA-256 is `7eba7a0ff855e1533d0c82b80194c8bbcc51df6899ec132bc0da71d7e7932fc1`. Cutover remains a separate guarded action: it requires this exact digest, the same current R132 tree and process identities, one Kokoro model owner, and rollback to R132 without forced kill. The post-cutover backup tool is also prepared; it creates a self-contained private recovery set from the shared R130 base plus the exact R133 delta, so intermediate R131/R132 deltas are unnecessary for restore.

Cut over only the Kokoro service with the existing immutable/CAS transaction. Keep clone and Nari process identities fixed, preserve the regional route and selected voice, record the measured supply window, and roll back on any health, audio, tail-completeness or identity failure. Post-cutover validation must exercise the same regional worker and public Global gateway separately; worker success alone is not end-to-end success.

Production was deliberately not switched. The Global Vercel gateway has not yet been restored to the complete-audio contract and this GPU has no warm Kokoro standby, so a model restart now would add a known supply window while the request path is still unhealthy. R132 remains current. Safe evidence is in `r133-baseline-recovery-readback.json`, `r133-stage.json`, `r133-cpu-canary.json`, `r133-release-readiness.json`, and `r133-capacity-cutover-assessment.json`; raw operator receipts are retained under the root-only local backup directory rather than this report.

The capacity check does not qualify the CPU canary as a standby. It was stopped after seven cases, has no listener or public mapping, and was not load-tested. At the read-only snapshot, the 24,564 MiB GPU had 10,137 MiB free while the three existing compute owners accounted for about 13,934 MiB. A second Kokoro model might fit nominally, but simultaneous inference peaks with Clone and Nari were not validated. The only active Kokoro exposure is public port `41228` to internal port `8880`; the candidate port `18880` has no public mapping.

Restoring the Global gateway is not authorization or a readiness signal to restart Kokoro automatically. Because uninterrupted playback is the release priority, the next production step is to provision and validate continuous same-US supply first: either a separate warm worker, or a reviewed proxy plus dual-model-port design whose peak GPU use has been proven safe alongside Clone and Nari. That validation must include real audio, concurrency, health, drain and rollback through the intended route. Only then should an explicit reviewed transaction move new traffic to R133 while R132 drains. The 23.095-second interval belongs to the earlier R132 switch and is historical evidence of the current single-owner restart path; it is not a prediction, target or promise for R133. R133 has not been switched and its production cutover duration is unknown.

## Diagnostic audit note

A forensic subtask accidentally invoked the standalone G2P recovery function against the production source environment. The diagnostics module appended 12 `request_id=internal` events from `2026-09-06T01:29:31.417946Z` through `01:29:32.160114Z`; it did not synthesize audio or alter a service. The safe receipt is `post-cutoff-g2p-forensic-probe.json`. Those events precede the planned 24-hour observation window and must remain classified as operator diagnostics.
