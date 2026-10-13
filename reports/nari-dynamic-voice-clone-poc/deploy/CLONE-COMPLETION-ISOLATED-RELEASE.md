# Clone completion 1.2.36 — isolated release preparation

2026-09-03 08:37 UTC. **Local candidate only; not deployed, not GPU-accepted.**
No production upload, install, process start/restart/stop, inference, route change,
or rental was performed. Existing US/CN clone, Nari and Kokoro remain untouched.

## Contract and source preservation

Reviewed complete candidate AGENTS, the two production backup/inventory runbooks,
the full US Vast guide, and immutable architecture
`e42b21ef2899f549f75d7a3bafda051dfed39a8c:docs/voice-clone-system-architecture.md`.
Canonical SHA-256:
`a348685e9d6c64ee44fe6577087690513155fcc11721b30290a1793dc31360ef`.
CN does not have `/etc/vast-agents-guide.md`.

Only opt-in public `required_clone_completion: "eos-v1"` requests may use the new
gateway target. Old requests, preview and management/create keep the old worker.
The candidate accepts absent opt-in without an ACK; unknown values fail 422.
An opt-in success must carry `X-CastReader-Clone-Completion: eos-v1`, after verified
Nari EOS, PCM order/count/hash, complete EOF, request text/voice/language binding,
unchanged WAV evidence, quality gates and successful final encoding. Failure has
no ACK and no audio. Request/content-cache identity includes the opt-in field.
The success JSON remains exactly audio/audio_format/timestamps/voice_code.
Completion is not ASR, word alignment, or acoustic speaker-identity evidence.

The current candidate was based on `068db5323cc47d60e9be0d5270f28414581ab555`.
Fresh read-only comparison discovered newer live `clone_worker.py` on BOTH nodes:
`68646719e50829286c8ce132a147f2376082a56ef5e496e87d0c0c6e0c6e55b7`.
Its exact independent change is `speaker-consistency warn-only-v1`: the relative
minimum-window comparison warns instead of rejecting; raw competing-speaker and
audio-quality gates remain mandatory. Root authorized preserving those exact
small sections in this candidate. Do not restore the older behavior during
cold reference recovery. The older completion document's 9be889… worker hash is
historical, not current production identity.

Live Nari app hash on BOTH nodes remains
`9d31f3fd7b1967e76ebbd2f0ad16cb56977388688854a28f24dbc9b1edfe4d4d`.
Live engine config on BOTH nodes is
`9ba01129b7f083572bd66feb07b476d3ef1075076c291b6fcd64fd4df703d89e`.
These selected-file hashes do not attest a complete runtime tree.

## Observed topology and proposed isolation

| Region | Existing worker / Nari | Proposed worker / Nari | Candidate root |
| --- | --- | --- | --- |
| US | 127.0.0.1:8890 / :8094 | :18990 / :18095 | `/workspace/castreader-clone-completion` |
| CN | 127.0.0.1:18890 / :18094 | :28890 / :28095 | `/root/autodl-tmp/clone-completion` |

Both proposed port pairs were free during the read-only check; recheck before
any start. Existing worker `/health` and Nari `/ready` both returned 200.
US uses Supervisor `castreader-clone` and `castreader-nari-base`. CN uses a bash
watchdog, `/root/autodl-tmp/nari-staging/deploy/watchdog-china-staging.sh`; CN has
neither supervisorctl nor ss on its ordinary SSH PATH. Do not repurpose that
watchdog or its PID files.

Each candidate uses `releases/<immutable-id>` for the entire worker and Nari tree,
and `state/<immutable-id>` for voices, token file, writer marker and caches. No
symlink to old voices, marker, cache, runner or source is allowed. In particular,
worker startup cleans staging paths and prompt imports/writes mutate the prompt
root. Sharing old data would violate isolation even with different ports.

Worker PYTHONPATH must include BOTH the exact new worker and Nari source trees,
followed by region quality/deps. The current worker default shell cannot import
Nari; copying only clone_worker.py will break. Nari uses the exact new source tree,
local-only model loading, the copied/pinned single-request engine config and
fresh cache roots. Reuse existing model/quality/native dependency bytes READ-ONLY,
bound to preflight digests and recoverable backups; never install into their venv.

Cold restore for a new request must call import/register/export on the SAME new
candidate selected for synthesis. Target identity participates in restore
coalescing. A 404 must not populate the old worker or silently switch to it.
New writer activation needs its own marker bound to the candidate hashes and
two-region compatibility gates; never copy the old writer marker. Importing
existing compatible prompts and writer activation are distinct operations.

## Capacity is a HARD DEPLOYMENT BLOCKER

Read-only `nvidia-smi` samples (MiB):

| Node | Used | Free | Total | Utilization |
| --- | ---: | ---: | ---: | ---: |
| US | 14602 | 9491 | 24564 | 0% |
| CN | 15639 | 8442 | 24564 | 0% |

CN process IDs are directly attributable: existing Nari 959622 uses 5616 MiB,
clone worker 60040 uses 2708 MiB, and Kokoro 129484 uses 7294 MiB. Thus an added
same-profile warm Nari+worker has an **8324 MiB steady-state reference**, before
additional peak workspace/allocator use. Keeping the existing CN watchdog's
2500 MiB floor would require at least 10824 MiB free, exceeding both current free
samples. This is NOT a measured candidate peak. The existing CN startup gate
itself requires 14000 MiB free before starting a whole Nari+worker pair.

US reports host GPU PIDs not directly mappable to container /proc; its 6118,
5656,2706 MiB process values must not be labeled as particular services without
additional evidence. Current source/engine similarity is not a peak-memory proof.

The CN watchdog continuously stops its OWN OLD Nari and worker if global free
memory drops below 2500 MiB. A differently named candidate can therefore take
old clients down through shared-GPU pressure. Disabling candidate warmup avoids
initial prompt-builder loading but does not solve full cold restore/create;
that path loads the builder later. Do not use warmup=0 to claim capacity safety.

**No same-card blind double-start, lower threshold, old process shutdown or new
machine rental is authorized.** Full deployment needs existing independent GPU
capacity, or an explicitly approved alternative whose measured startup, normal,
long-text and cold-restore peak preserves all active workloads and safety floors.

## Required pre-change recovery inventory

This is independent of the Kokoro R129 backup. Current on-host selective worker
backups are insufficient; no fresh full clone/Nari off-host readback receipt was
verified by this task. Both pre- and post-change receipts must be verified=true.

| Asset | US | CN |
| --- | --- | --- |
| Complete worker source | `/workspace/castreader-clone/app` | `/root/autodl-tmp/nari-staging/worker` |
| Complete Nari tree, profile, launcher | `/workspace/nari-qwen3-tts-clean` excluding separately listed venv | `/root/autodl-tmp/nari-staging/nari-qwen3-tts` plus `deploy/` |
| Qwen base/tokenizer/codec/model configs | `/workspace/qwen3-tts-base/model-0.6b-base` | `/root/autodl-tmp/nari-staging/model-0.6b-base` |
| Quality ONNX + deps/native libs | `/workspace/castreader-clone/quality` | `/root/autodl-tmp/nari-staging/quality` |
| Fixed DeepFilter binary | `/workspace/castreader-clone/denoise` | `/root/autodl-tmp/nari-staging/denoise` |
| Actual venv, interpreter/native dependencies, freeze | `/workspace/nari-qwen3-tts-clean/venv` | `/root/autodl-tmp/nari-staging/venv` |
| Optional existing ASR checkpoint | `/workspace/.hf_home/hub/models--openai--whisper-base/snapshots/e37978b90ca9030d5170a5c07aadb050351a65bb` | `/root/.cache/huggingface/hub/models--openai--whisper-base/snapshots/e37978b90ca9030d5170a5c07aadb050351a65bb` |
| Private prompts, metadata, writer/config markers, token recovery | `/workspace/castreader-clone/voices` and protected sibling state | `/root/autodl-tmp/nari-staging/clone` |
| Process/ingress config | new and old Supervisor .conf, `run-clone-worker.sh`, `run-nari-base.sh`, private TLS/Caddy config and secret-store recovery | `deploy/run-clone-china-staging.sh`, `run-nari-china-staging.sh`, watchdog, managed ingress and secret-store recovery |

Prompts, references, keys and tokens are private; keep the existing regional
encrypted/private recovery policy. Do not put them in this source archive or
stdout. Record marker contents only in protected recovery metadata. Dereference
model symlinks in immutable archives; SHA both the file tree and complete compressed
archive, private upload, then complete download SHA readback. Preserve active,
previous and known-stable recovery points. Region models differ by 193 bytes in
the observed directory totals, so same-model names are not a parity proof.

Observed approximate uncompressed totals: model 2.516 GB in each region,
quality 105 MB, DeepFilter 36 MB; US venv 9.64 GB versus CN 8.24 GB. These file-walk
sizes include pyc and are inventory estimates, not archive sizes. Free disk was
US 121.8 GB / CN 35.6 GB. Upload quota/account approval remains root's gate.

Both live envs: torch/torchaudio 2.11.0+cu128, transformers 4.57.3, qwen-tts 0.1.1,
fastapi 0.136.3, httpx 0.28.1, soundfile 0.14.0, safetensors 0.8.0,
flashinfer-python 0.6.14, triton 3.6.0, uvicorn 0.52.4.
NumPy differs: US 2.3.5 / CN 2.5.2. The repository pyproject's torch 2.13.0 and
other pins DO NOT describe current production. Reinstalling from it would be a
separate dependency migration, not deployment of this small protocol change.

## Local package and CPU commands (safe; no GPU)

From the candidate repository root:

```bash
PYTHONDONTWRITEBYTECODE=1 /opt/anaconda3/bin/python \
  reports/nari-dynamic-voice-clone-poc/deploy/completion-release-plan.py \
  --region us --release-id clone-eos-1236-candidate

PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH=reports/nari-dynamic-voice-clone-poc/nari-qwen3-tts/src:reports/nari-dynamic-voice-clone-poc/worker:reports/nari-dynamic-voice-clone-poc/tests:/Users/xuxuheng/.cache/uv/archive-v0/5l_F4imfVK4J0aEdob0f7 \
/opt/anaconda3/bin/python -m unittest \
  test_nari_completion test_clone_completion_ack test_completion_release_plan -v
```

`--archive <new-local-file.tar.gz>` creates the coordinated source/tests/manifest
package for both regions and refuses overwrite. It contains NO models, venv,
private voices or secrets and is not an independently recoverable runtime backup.
Its manifest explicitly keeps production_mutation_allowed=false. The plan emits
exact source hashes, new environment/argv, required read-only asset paths and
every remaining gate; it does not install/start/copy over any service.

## GPU / full-chain acceptance — NOT RUN, only after root unlocks gates

1. Bind the reviewed exact source commit/tree, region backup receipt, full dependency
   hashes, engine config SHA and approved independent-capacity evidence. Stage a
   fresh release/state directory; use new managed process names and candidate-only
   rollback. Start additive new Nari first, then new worker after readiness. Never
   load the old semantic/fixed-deepfilter overwrite scripts.
2. In each candidate's own region, restore two operator-owned canary prompts
   through the candidate import API with normal authentication. Exercise absent
   prompt recovery on the candidate; never select a customer's voice as a canary.
3. On the isolated candidate node, the executable command is:

   ```bash
   <region-python> <release-root>/deploy/probe-completion-candidate.py \
     --region us --token-file <candidate-state>/.api-token \
     --voice-a vc_owned_canary_a --voice-b vc_owned_canary_b \
     --allow-gpu-after-backup-and-capacity-approval
   ```

   Use `--region cn` only in CN. Ports are hard-coded to the NEW loopback pairs.
   It runs real Nari EOS, forced low-token rejection, in-flight transport cut, then
   2 voices × 10 languages × 1x/2x worker generation with ACK/four-field identity
   and final ffmpeg-decoded duration/cue bounds. It writes no audio and emits only
   hashes/counts/timings. GPU negative cases must not produce prefix audio.
   Disconnect-follow-up success is not a direct engine-cancel trace; also inspect
   candidate-only queue cleanup and bounded cancellation telemetry.
4. Through the authenticated candidate control plane, verify opt-in -> same-target
   restore -> worker ACK -> exact four fields -> extension decode, highlighter,
   auto-scroll and QuickRead. Test >600-character ordered continuation, failure
   after first part, cancellation, two-voice switching, no ACK, old-worker
   misconfiguration, quota reservation release and old-client unchanged routes.
5. Compare old/new per-region latency/queue baselines and measure startup/long/cold
   restore GPU peaks. Keep the old API/PIDs/config/file hashes unchanged throughout.
   No gate is satisfied merely by capability/401/health responses. Finish protected
   post-change off-host backup/readback before any production-complete claim.

Current result: CPU/ASGI protocol guards pass; full worker environment, GPU,
authenticated DB/storage/quota recovery, final media and client production chain
remain release gates. Lack of independent GPU capacity and unverified full
pre-change clone/Nari off-host backup are explicit deployment blockers.

Final read-only alternate-capacity check: `castreader-train6000` resolves through
the configured SSH alias to `connect.westd.seetacloud.com:24130`, but TCP connection
was refused before authentication. Its remote guide, GPU occupancy and running
jobs could not be inspected. It is **not verified as online/idle capacity**; a
platform status check requires the user's direction, not automatic instance start.
The fixed-DeepFilter test fixture was updated to preserve the exact live warn-only
behavior; full-module execution still requires qwen_tts unavailable locally and
is not counted among this task's passing CPU/ASGI tests.

Final local run: **39/39 tests PASS** in 0.610 s (26 Nari protocol/ASGI, 8 worker
ACK/ASGI with controlled scheduler/quality/encoder boundaries, 5 release-plan and
archive guards). Archive tests re-hash every member and verify both regional plans
match; overwrite is refused. `git diff --check` passed. Running the GPU probe
without its explicit approval flag refused before token-file access or HTTP.
