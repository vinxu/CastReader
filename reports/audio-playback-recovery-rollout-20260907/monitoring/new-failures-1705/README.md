# 17:05 cumulative-window failure delta

The cumulative count is **12 = 9 known + 3 newly observed**. All three new client events and all three Direct 400s occurred **before** the proxy, Global API and Direct gateway releases. They are not evidence of a regression in the newly deployed versions.

The client query read all 90 selected end events in the original 05:01:25–17:05:27.598373 UTC window and reproduced the acceptance snapshot's 12 technical failures. The three new events belong to one anonymous Android installation running **1.0.45 / build 52**, using Global routing. Their same-session read starts identify URL/Web input. No text, URLs, raw identities or request bodies were queried or exported.

| Client event key | Occurred UTC | Same-session input / language | Playback seconds | Failure |
|---|---|---|---:|---|
| e08918341c4265a32e2a | 16:04:04.923 | URL/Web / en | 44 | tts_failed / generation_failed / tts |
| 798ead151458637a016f | 16:04:17.983 | Same content, resumed / es | 0 | tts_failed / generation_failed / tts |
| 855d7b43d4f616193757 | 16:13:12.965 | Another URL/Web content session / es | 48 | tts_failed / generation_failed / tts |

Each reading session has a preceding first-audio event (reported latency 1963 / 1327 / 1342 ms respectively). The second session reports failure about 551 ms after first audio with 0 playback seconds. These are client events, not proof of successful decoding or complete playback. Later starts or completed sessions sharing a content session are separate sessions and do not erase these failures.

The Direct journal query is complete: 43,627 rows / 4,354 logical blocks, with no truncation or parser gaps. Its three 400 records are:

| Direct anonymous key | Completion/log UTC | Elapsed | Request bytes | Client metadata |
|---|---|---:|---:|---|
| 7fe6315b3454e3737bc7 | 16:04:04.896206 | 14 ms | 583 | Android 1.0.45 |
| e4331852bd595754975e | 16:04:17.957222 | 13 ms | 583 | Android 1.0.45 |
| 8a0585d2909dc89be5b7 | 16:13:12.950192 | 357 ms | 165 | Android 1.0.45 |

These respectively precede the client occurrence timestamps by 26.794 / 25.778 / 14.808 ms. The timing and platform/version agreement make them strong association candidates. They are **not exact request joins**: the selected client request/trace properties are absent, and occurrence time is client supplied. Server receipt timestamps (16:04:07.099 / 16:04:20.322 / 16:13:15.168) independently establish that all three client failures were received before every deployment.

The model evidence now establishes the **Direct → R133 model link exactly** for all three anonymous request keys. Each key has a `complete_audio_failed` event with `ValueError` at `tts_service.py / generate_audio:595`, followed by model `request_failed / status 400` in 2 ms. Model failure timestamps are 16:04:04.890209 / 16:04:17.951893 / 16:13:12.943763 UTC. The pinned R133 service source (SHA-256 `ac1ec2b158f4b2fd9857bf53d743631419eb934729070c5df73d285430b1a910`) raises the fixed `no_speakable_content` error at that exact line when generation has produced no audio and its existing `_requires_generated_audio(text)` guard is false. The pinned router maps that `ValueError` to HTTP 400. These three Direct 400s therefore came from the model; Direct local input validation is excluded for these records.

This proves the **failing model branch**, not the original text. No original text was queried. It does not prove that all three inputs were pure punctuation, one character long, or used a particular model language or voice. The bounded 16 MiB ordinary log tail begins at 16:13:12.943049 UTC: it has no ordinary log rows for the first two windows. In the third window, same-second logs interleave several text lengths and language routes and have no request ID/PID. The adjacent `textChars=1`, language and voice fields are unjoined context and are not assigned to any of the three requests.

The **client → Direct link remains a strong temporal association only**. The exact model join does not supply the missing client request key. The old Direct source also omits the response body/error code, abort stage and disconnection state; those gateway fields remain unavailable, not false. The 13–357 ms Direct durations and the 2 ms model failures are not evidence of timeout, cancellation or user intent.

Deployment boundaries used: proxy verified 16:36:52.292087; Global identity readback 16:45:55.382733; Direct first new traffic 16:51:50.888941, verified 16:52:02.458777 UTC. The four historical Direct 504s and four historical Global 504s remain unchanged.

Artifacts: `client-delta.json` retains the allowed session metadata and completeness checks; `client-summary.json` is the compact client table; `direct400.json` contains the sanitized journal evidence and current Direct identity; `model400-windows.json` contains the existing three bounded model windows, exact request-key joins and pinned source evidence; `combined-summary.json` distinguishes the exact model links from the candidate client links. US incident review used existing evidence and performed no new historical log reads. Active notification state and production configuration were not modified.

A separately authorized CN static check at 17:42:48.781694 UTC followed the existing domestic gateway jump route. CN remains on `20260904-kokoro-playback-cn-r131b` with PID 640207 / start ticks 2020118568. Its service and captioned-speech router source SHA-256 values exactly match US R133, so the same no-audio failure branch exists there. `cn-static-path.json` records this source/process evidence. No CN incident logs or production synthesis were queried; shared source risk is not evidence that CN experienced these failures.

## Candidate implementation review

The independent source review found no remaining blocker in the candidate at `/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-silent-separators-20260907`. The silence predicate uses an explicit sentence/wrapping-mark allowlist plus whitespace. Readable text, numbers, currency/math/emoji, fullwidth percent/ampersand, section/paragraph signs, unknown punctuation, combining marks and format controls retain their original model/error path. A complete silent request produces 2,400 zero PCM samples (100 ms at 24 kHz); encoding retains both the initial write and the final flush in one asset. Internal separator-only units are skipped without discarding either surrounding speech unit.

A necessary Opus writer correction closes the Ogg muxer before retrieving its final bytes, retaining the last page for short assets; the other codec orders remain unchanged. The implementing agent reports **43 passing local tests**, including actual decoding of **6 codecs × 3 stream settings (omitted/true/false) × 2 silent inputs**, ordinary multi-unit PCM/WAV/MP3/Opus full and streaming output, and readable-symbol failure cases. This reviewer checked the actual allowlist through AST, both encoder paths, the streaming tail collection, and the existing Global/Direct gateway behavior. The gateways accept valid nonempty audio with empty timestamps; explicit consumed text and an empty remainder preserve completion. `silent_request_audio_ready` records audio readiness, with an `encoded` flag; it is not an HTTP-success or playback-completion event.

This verifies a bounded recovery benefit for the listed silent separators. The original three inputs remain unknown, and the old guard's false branch is broader than the new conservative allowlist. These tests do not reproduce the historical documents or guarantee that all three historical inputs would use the new recovery. No production synthesis or deployment was performed by this reviewer.

## CN release capability and deferred synchronization

CN remains on **r131b; this model fix is not deployed there**. The latest existing gateway deployment receipt describes `api.castreader.cn → CN Next :3000 → gateway loopback Kokoro tunnel :18880 → CN model :8880`; current monitor metadata still reports `cn-environment / revision 0`. The fresh static check independently confirms model PID 640207 and r131b on the model process. Gateway identity/port details above come from the existing deployment evidence, not a fresh gateway process read.

The existing model canary is **model-host loopback :18880**, a different host from the gateway's tunnel port of the same number. `deployment/r131_host.py` and `r131_canary_bootstrap.py` support a temporary isolated candidate with complete model lifespan and explicit VRAM gates; this is not a routable, continuously available standby slot. Current spare capacity was not sampled in this review.

`deployment/r131_cutover_host.py` preserves the old source and atomically changes `current`, then signals the exact old PID with TERM and waits up to 180 seconds for natural Uvicorn drain; it does not force-kill a request. The original watchdog subsequently starts the replacement on :8880. **It cannot keep accepting new synthesis during drain and model startup**: no admission switch, request queue or alternative serving slot is provided by these tools. Existing active requests may finish; new paragraph synthesis can fail even while a client is playing previously buffered audio. Therefore the current tooling does not establish uninterrupted CN synchronization, and a blind restart is not an acceptable substitute. The operator and host guards also pin the old r130 → r131b transition, so they cannot be executed unchanged for this new patch.

The reusable same-region recovery evidence is `/Users/xuxuheng/Backups/CastReader/tts/20260904-r131-cn-post-cos.9zabgg5k/`: `backup-receipt.json` SHA-256 `aabe42617e7a7c8869b48e20bbbd9b1e8cec341e91d8ef46642ecf109fbe6522`, `source-snapshot.json`, `recipe.json`, `base-cos-readback.json`, `runtime-delta.tar.gz`, `delta-readback.json`, and the receipt-publication readback. Their local receipt/snapshot/recipe/base bindings were checked. The private Shanghai COS base is 3,324,807,745 bytes (SHA-256 `659b6a46de3e86bad826657ffd64fb3e53490e951e991cba9f6c4c074c12b441`) plus the exact r131b delta; restore does not require a US object. These are existing September 4 readback receipts, not a newly downloaded backup.

The reference operator/backup files are under `/Users/xuxuheng/Documents/MyProject/.worktrees/castreader-tts-inflight-diagnostics-20260907/deployment/`: `r131_operator.py`, `r131_host.py`, `r131_cutover_host.py`, `r131_backup.py`, and `r131_cn_cos.py`. Parent rollout scope therefore keeps CN unchanged this round and finishes the US path with observed failures first. CN's shared static risk and lack of an interruption-free model handoff remain open; no additional CN incident scan or new deployment tool was created.
