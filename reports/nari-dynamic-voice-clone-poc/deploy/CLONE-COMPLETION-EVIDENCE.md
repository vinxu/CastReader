# Clone completion evidence — local candidate, NOT deployed

Status (2026-09-03): design and CPU implementation ready for root review. No commit,
production mutation, model inference, deployment, or off-host backup was performed.

Candidate: `/Users/xuxuheng/Documents/.worktrees/CastReader-clone-completion-evidence`,
branch `codex/clone-completion-evidence`, base
`068db5323cc47d60e9be0d5270f28414581ab555`. Sparse checkout contains only this report
tree and root `AGENTS.md`; the original dirty repository is unchanged.

## Authoritative contracts and observed production

- Read root `AGENTS.md`, production backup/inventory runbooks, the entire US Vast
  guide, and the locked web architecture at
  `e42b21ef2899f549f75d7a3bafda051dfed39a8c:docs/voice-clone-system-architecture.md`
  (SHA-256 `a348685e9d6c64ee44fe6577087690513155fcc11721b30290a1793dc31360ef`).
  No nested `AGENTS.md` was found under this source tree. The AutoDL CN host has no
  `/etc/vast-agents-guide.md` and no corresponding guide found under `/etc`/`/root`
  to depth 2; its inventory and locked regional deployment instructions apply.
- Read-only SSH checks found US and CN healthy, model
  `qwen3-tts-0.6b-base-nari`, runtime `x-vector`, ASR required=false, loaded=false.
- Both live worker files exactly matched local source SHA-256
  `9be8893828c8f559f94c9548c9b479108bd71b8760fd2db081463b13037d40e3`;
  both `adaptive_denoise.py` matched
  `1ddacd73ddcd3c9a175d302795f6f50da318fba13d1c63faadd64ff3f742695a`.
  Live Nari `api/app.py` and `model/text.py` also matched local source, respectively
  `9d31f3fd7b1967e76ebbd2f0ad16cb56977388688854a28f24dbc9b1edfe4d4d` and
  `dba56d8391256327e4b8ba7757166764cd982b48a5ff8f48143fb4ce73f73354`.
  This is selected-file evidence, not a full live-tree attestation.
- Current rollout record is `artifacts/fixed-deepfilter-rollout-20260903/ROLLOUT.json`;
  the earlier adaptive-denoise record is explicitly historical/superseded.
  Current recorded source commits: CN `08a34a4d1cad42ac1c8dceb52fc9dbb65c96104f`,
  US `7fcc6e1bb5692761a9ecd8271a6bb05cdf9669fe` (release-tool-only difference;
  worker bytes identical). This candidate is not either production release.

| Region | Clone worker | Nari source | Internal ports |
| --- | --- | --- | --- |
| US | `/workspace/castreader-clone/app` | `/workspace/nari-qwen3-tts-clean/src/nari_qwen3_tts` | worker 8890, Nari 8094 |
| CN | `/root/autodl-tmp/nari-staging/worker` | `/root/autodl-tmp/nari-staging/nari-qwen3-tts/src/nari_qwen3_tts` | worker 18890, Nari 18094 |

## Actual model and timing boundaries

`clone_worker.py` → selected `vc_*` prompt → Nari Qwen3 Base x-vector → PCM → WAV
quality checks → ffmpeg MP3 → legacy four-field response.

- The worker always selects speaker-embedding-only inference; legacy ICL prompt
  schemas remain readable but do not enable an ICL content path. The current
  x-vector path skips output ASR. Quality and overlong-output gates still apply.
- `model/text.py` wraps the request in Qwen assistant tokens and tokenizes it.
  This is not Kokoro G2P. No source-span/phoneme/word-duration contract is emitted.
- The worker accepts <=600 Python characters and does not implement public
  `processed_text`/`unprocessed_text`; the caller owns exact ordered continuation.
- The worker's input `.strip()` and lexical timing labels cannot serve as a v2
  exact-source proof. Numbers in clone timestamps are input labels; that is
  distinct from Kokoro spoken-number normalization.
- Alphabetic-language timestamps use final-WAV RMS activity/pauses and lexical
  weights. They are audio-aware approximations, not forced alignment. CJK returns
  empty timestamps and retains segment/sentence highlighting. Returning all input
  words does NOT prove that the model spoke all those words.
- Existing `apply_speed` reports WAV sample duration divided by requested speed,
  not measured final-MP3 duration. This candidate does not change that media-clock
  boundary. Final encoded-media validation remains a separate release gate.
- Selected voice ID is checked, resolves to its own prompt directory, and is part
  of request/coalescer identity. Prompt caches use file mtime. The new request
  fingerprint binds the requested voice ID, not acoustic speaker identity or an
  immutable prompt-content digest; do not claim those stronger guarantees.

## Concrete defect and additive interface

Before this candidate, `engine/pipeline.py::_talker_completion` reduced both EOS
and reaching `max_new_tokens` to one terminal boolean. `PCMStream.close()` and
HTTP PCM EOF carried no reason. The worker buffered PCM, checked quality/duration,
and returned it without direct model-completion evidence. Duration limits are
useful indirect protection but are not a terminal-reason contract.

The new internal endpoint is:

```text
POST /internal/v1/audio/speech-complete
Accept: application/vnd.castreader.nari-completion+jsonl
request: existing SpeechRequestBody, response_format=pcm, stream=true, ignore_eos=false
response: same media type; X-Nari-Completion-Protocol: nari-pcm-completion-v1

start(protocol, request_id, request_sha256, sample_rate, channels, sample_format)
pcm(sequence=0, data=base64) ... pcm(sequence=n, data=base64)
complete(request_id, stop_reason=eos|max_tokens, frames, pcm_bytes, pcm_sha256)
```

An engine failure/cancellation emits a terminal error frame when the connection is
still available. EOF without a complete EOS frame is always a failure. The worker
must finish reading EOF, reject trailing data, validate all frame identities,
sequence, format, count and SHA-256, and only then construct WAV. It does not return
partial PCM and never retries against the old raw endpoint. No words/timestamps
or semantic evidence are invented by this protocol.

Worker failures reuse the existing non-retryable `VOICE_GENERATED_AUDIO_REJECTED`
category, with reason `incomplete-nari-generation`; no new public error-code
contract or top-level success field is introduced.

The request digest covers canonical JSON of explicitly supplied request fields
(`SpeechRequestBody.model_dump(exclude_unset=True)` server-side). The controlled
worker always uses the same typed payload; tests cover its exact control set,
text, voice, language and seed. This is transaction binding, not authentication.
Nari remains loopback-only and existing worker authentication remains unchanged.

The canonical pipeline preserves EOS versus max_tokens, publishes that reason
through atomic commit and the request generation lane, and attaches it to PCM
only after the final codec delivery. Existing raw HTTP PCM/WAV and WebSocket wire
formats do not change. Legacy in-process `close()` remains available but produces
no trusted EOS evidence. A limit reached on the EOS boundary is conservatively
classified as max_tokens, preserving the previous termination decision.

New async stream reads are bounded at 250 ms, so disconnects can reach a shielded,
bounded engine-cancel cleanup even when no PCM is arriving. This does not add a
public streaming clone response: public captioned speech still waits for complete
inference, validation and MP3 encoding.

## Implementation scope and dependency

- `completion_protocol.py`: standard-library wire encoder/validator, one shared
  implementation for Nari and worker; no model dependency.
- `engine/{pipeline,commit,state,engine}.py`, `contract/stream.py`: preserve model
  termination provenance, without changing the legacy terminal boolean behavior.
- `api/{app,http}.py`: opt-in route and cancellable framing. `api/websocket.py`
  changes only an Engine annotation import to TYPE_CHECKING, not its behavior.
- `worker/nari_completion_client.py`: atomic internal consumer.
  `clone_worker.py` delegates only its internal x-vector stream collection.
- `tests/test_nari_completion.py`: 26 CPU tests, plus subcases.

No new pip dependency is required beyond the current Nari/worker environment.
However, **worker must be able to import the selected release's Nari package**.
Read-only US checks found it is not importable by that venv's default shell
environment. Both current worker runners only explicitly add `quality/deps` to
PYTHONPATH. A coordinated release must bind the exact Nari source path into worker
PYTHONPATH (or install that exact package), while preserving quality dependencies.
This environment/runner integration is PENDING; the candidate must not be deployed
by copying worker files alone.

## Verification status and executable commands

26/26 local CPU tests passed on 2026-09-03. The tests execute real protocol code,
FastAPI routes, worker decoder, PCMStream, Talker-completion method, atomic state
commit method and final engine PCM delivery, with controlled CPU tensors and a
fake GPU engine. They do not prove real model output, production timing or latency.

On a Linux candidate with the existing full dependencies:

```bash
cd <isolated-source-root>
PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH=reports/nari-dynamic-voice-clone-poc/nari-qwen3-tts/src:reports/nari-dynamic-voice-clone-poc/worker \
python -m unittest discover -s reports/nari-dynamic-voice-clone-poc/tests -p test_nari_completion.py -v
git diff --check
```

Local command used the already installed `/opt/anaconda3/bin/python`, adding the
existing safetensors cache `/Users/xuxuheng/.cache/uv/archive-v0/5l_F4imfVK4J0aEdob0f7`
to PYTHONPATH. No dependency/model downloads were made.

### Follow-up existing-worker CPU regression

The guarded local subset passed **52/52 tests** (0.584 s), comprising 26 existing
tests plus the 26 new completion tests:

| Module | Result |
| --- | --- |
| inference scheduler | 3/3 PASS |
| request coalescer | 4/4 PASS |
| x-vector activation | 6/6 PASS |
| Nari x-vector layout/prompt loader | 5/5 PASS |
| adaptive-denoise offline policy helpers | 8/8 PASS |
| new completion protocol/transport/CPU methods | 26/26 PASS |
| timestamps | BLOCKED at import: missing `qwen_tts` |
| semantic_contract | BLOCKED at import: missing `qwen_tts` |
| semantic_asr | BLOCKED at import: missing `opencc` |
| generated audio quality | BLOCKED at import: missing `qwen_tts` |
| fixed DeepFilter worker orchestration | BLOCKED at import: missing `qwen_tts` |

These missing packages were not downloaded or replaced by new dependency stubs.
Existing soundfile, multipart and safetensors caches were used; CPU torch/scipy
were already installed. The temporary runner
`/private/tmp/castreader-clone-regression.GS4cjz/run_existing.py` disabled model
warmups, bound all worker data/model/token paths to its own temporary directory,
set offline environment flags, and rejected real socket connects/DNS and CUDA
initialization/calls. The forbidden-call count was **0**. Test-created temporary
assets were removed by their existing TemporaryDirectory contexts.

The first run found one test-harness path issue: macOS `/tmp` resolves to
`/private/tmp`, while a directly constructed test prompt root had not been
canonicalized. Canonicalizing the runner's temporary root removed this mismatch;
no production path validator or product code was changed for it. The five blocked
modules remained blocked; they are not included in the 52 passing test count.

Two existing `test_semantic_contract.py` x-vector HTTP doubles still returned raw
PCM and had no `headers` parameter. They now emit the negotiated start/PCM/EOS
frames and expose the required response headers; the first test also asserts the
new internal endpoint and Accept header. This is a test-fixture protocol update,
not a product workaround. **Those two tests remain unexecuted** because their
module cannot import without `qwen_tts`; rerun them with the full real dependencies
before approval. No runtime files changed during this follow-up regression.

To replay the passing guarded subset on this machine:

```bash
PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH=reports/nari-dynamic-voice-clone-poc/nari-qwen3-tts/src:reports/nari-dynamic-voice-clone-poc/worker:reports/nari-dynamic-voice-clone-poc/tests:/Users/xuxuheng/.cache/uv/archive-v0/5l_F4imfVK4J0aEdob0f7:/Users/xuxuheng/.cache/uv/archive-v0/cXyzXNlChzIR_OZ97ollt:/Users/xuxuheng/.cache/uv/archive-v0/ksYpjOePB7MTO32OSFKvF \
/opt/anaconda3/bin/python /private/tmp/castreader-clone-regression.GS4cjz/run_existing.py \
test_inference_scheduler test_request_coalescer test_xvector_activation \
test_nari_xvector_layout test_nari_completion test_adaptive_denoise
```

PENDING before release: full worker and Nari regressions; actual GPU normal EOS,
forced low-token truncation, transport cut and disconnect tests; two voices and
10-language clone matrix; long input chunk ordering and post-first-chunk failure;
1x/2x final-MP3 duration; highlight/scroll and Explain; both-region latency/queue
baseline; old-client four-field success/failure and quota settlement behavior.

## Deployment, backup and rollback ordering — NOT executed

The fixed DeepFilter release tool allows only clone_worker.py/adaptive_denoise.py
and intentionally protects Nari/runner files. **Do not broaden or bypass it to
deploy this candidate.** A new coordinated release must bind both trees, the shared
wire module, worker import path, exact file hashes, process config and unchanged
voice prompt schemas in an immutable manifest.

1. Before any production change, complete immutable pre-change backups, off-host
   private uploads and full SHA-256 readback receipts with verified=true for the
   affected clone/Nari releases and required assets/config. Preserve user prompt
   assets under the existing private/encrypted recovery contract. R129's Kokoro
   archive and the monitoring-only receipt do not cover these clone/Nari trees.
   The on-host Sept-3 worker backups are selective; no current full off-host clone
   readback receipt was verified in this audit. Disk space and authenticated
   storage/quota verification are currently unresolved. Do not change Spend Cap.
2. Root reviews/tests one exact source commit for both regions. Stage immutable
   candidate trees; do not mutate active source or model assets. Validate imports
   and run real GPU tests on the candidate; do not use user voices as canaries.
3. Deploy the additive Nari reader/endpoint first while the old worker continues
   using old PCM. Verify old and new transports against the exact manifest.
4. Only then activate the worker that requires completion evidence, with its exact
   shared-module/PYTHONPATH binding and existing writer-marker safeguards. No mode
   flag may silently downgrade a failed completion request to legacy PCM.
5. Verify public four-field clone contracts, both-region client matrix and quotas.
   Complete immutable post-change off-host/readback receipts before declaring
   the rollout protected or removing any previous release.
6. Rollback order: restore the prior **worker and its import binding first**, then
   the prior Nari reader if necessary. Rolling Nari back while the new worker is
   active intentionally fails closed and is not a safe availability rollback.
   Keep current/previous/known-stable releases and their verified receipts.

Recorded current on-host rollback inputs (not full off-host recovery):

- CN `/root/autodl-tmp/nari-staging/backups/fixed-deepfilter-worker-20260903T045956Z-8485`
- US `/workspace/castreader-clone/backups/fixed-deepfilter-worker-20260903T051120Z-71772`

Those backups are only valid with their bound fixed-DeepFilter manifests/markers;
the existing tool refuses rollback if protected Nari/runner hashes change. A new
coordinated rollback plan is therefore required, not reuse of its --execute path.
