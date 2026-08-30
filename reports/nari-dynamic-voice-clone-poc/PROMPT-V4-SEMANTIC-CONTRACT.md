# Legacy clone prompt v4 semantic incident contract

> Historical scope only. Current production creation writes speaker-only
> `qwen3_tts_base_voice_clone_prompt_xvector_v1`, and all online cloned speech
> uses only the speaker embedding. `reference_text` is optional and advisory;
> it does not gate creation or enter synthesis. The current end-to-end source of
> truth is `voice-clone-system-v1` in
> `readout-web/docs/voice-clone-system-architecture.md`.

## Root cause

`prompt_v4` stores three independent views of the reference utterance:

- `ref_text`: the complete script shown by the client;
- `reference_codec_embeddings`: acoustic conditioning consumed by the Talker;
- `decoder_reference_code`: decoder-only causal state for the same reference audio.

They must describe exactly the same utterance. The affected historical English
prompt contains the complete 21-word guide in `ref_text`, but only 69 codec
frames (about 5.52 seconds; measured speech was 4.224 seconds). A complete read
of that script cannot plausibly fit in the recorded speech. During ICL prefill,
the Talker therefore sees text whose acoustic continuation is missing and emits
the missing/reference words as newly generated tokens before the requested
`input`.

This is not a PCM trimming error. Nari admission passes v4
`decoder_reference_code` into `CodecExecutor.reference_state()` as decoder-only
state. The visible PCM starts at generated frame zero; reference PCM is not in
the returned slice. The leaked guide is already present in the newly generated
codec tokens, so changing `pcm_start_frame` cannot safely remove it.

## Legacy v4 containment contract

1. Historical v2/v3/v4 prompts stay readable but are never used as ICL online;
   runtime extracts only their speaker embedding.
2. New x-vector prompts contain no `ref_text`, reference codec embeddings or
   decoder reference state, removing the guide-leak path structurally.
3. Online x-vector synthesis does not depend on ASR. Final-audio acoustic
   quality, duration and EOS gates remain mandatory; ASR is available for
   offline audit and legacy incident analysis.
4. Letter-language word timestamps are audio-aware waveform estimates on the
   final WAV, not Whisper or forced alignment. Chinese, Japanese and Korean
   return an empty word timestamp array and keep segment timing.
5. `VOICE_OUTPUT_TEXT_MISMATCH` remains a compatibility error for legacy or
   explicitly audited paths; it must never be converted into playable audio.

## Existing prompt migration

Healthy v3/v4 prompts do not need regeneration. Runtime safely consumes only
their speaker embedding. Regenerating them changes voice identity and adds
migration risk without correcting the historical recording.

An affected prompt cannot reconstruct missing reference speech from
`prompt.pt`. It remains usable through the x-vector path without exposing the
reference transcript. Do not overwrite a historical prompt in place or
synthesize fake reference audio to rebuild it. A user may re-record naturally
to create a new x-vector voice, but no fixed guide is required.

If an operational inventory is produced, classify historical prompts as
`legacy-readable-xvector`, `legacy-corrupt`, or `re-record-recommended`;
do not label any prompt as eligible for online ICL. Classification comes from
the persisted prompt envelope and embedding integrity, not from client or
account region. Web and the browser extension use only the international
worker. iOS and Android may route to either the international or China worker;
both workers enforce the same prompt and final-audio contract.
