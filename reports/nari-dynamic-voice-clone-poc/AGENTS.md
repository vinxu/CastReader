# Voice-clone Worker agent rules

This directory is the production source for the CastReader GPU clone Worker and
its US/CN deployment scripts. Before changing any file under this directory,
read the complete system architecture first:

- Pinned immutable source:
  `https://github.com/scmyyan/readout-web/blob/e42b21ef2899f549f75d7a3bafda051dfed39a8c/docs/voice-clone-system-architecture.md`

The required architecture ID is `voice-clone-system-v1`.
The repository lock is `../../docs/contracts/voice-clone-architecture.lock.json`;
validate it from the repository root with
`python3 scripts/voice_clone_architecture_gate.py verify-lock --require-pinned`.
A local control-plane checkout is valid only when `--backend-checkout` also
confirms the pinned commit and SHA256 digest.

## Hard invariants

1. New creation is speaker-only x-vector. `reference_text` is optional,
   advisory-only and must not gate creation or enter online synthesis.
2. New `xvector_v1` prompts contain only the validated speaker embedding and
   mode/version metadata. They must not contain reference text or codec/decoder
   reference state.
3. All cloned speech, including legacy prompt assets, uses the speaker embedding
   at runtime so requested input is the only text content source.
4. The Worker API stays compatible with `captioned-speech-v1`; the control plane
   owns auth, voice access, persistent assets, Pro and quota.
5. A Worker cache miss is recoverable and is not proof that a persistent voice
   is missing.
6. Interactive, prefetch and voice-build work share one bounded single-GPU
   scheduler. Do not replace bounded queuing with an immediate non-blocking lock
   or unlimited concurrency.
7. US and CN must run reader-compatible code before either region enables a new
   writer schema. Marker/hash validation must fail closed for new writes while
   preserving reads.
8. Do not deploy one region from an uncommitted file or let two Agents deploy US
   and CN from different source hashes.

## Required verification

At minimum run the focused semantic, quality, scheduler, coalescer, timestamp and
activation suites affected by the change, plus:

```bash
python3 -m py_compile worker/*.py tests/*.py
bash -n deploy/us/*.sh deploy/cn/*.sh
git diff --check
```

Changes to prompt schema, request/response fields, error semantics, timeouts,
priority, recovery, quality gates or deployment ordering must update the
canonical architecture document in the control-plane repository in the same
change set. Related commits must contain:

`Voice-Clone-Architecture-Reviewed: voice-clone-system-v1`
