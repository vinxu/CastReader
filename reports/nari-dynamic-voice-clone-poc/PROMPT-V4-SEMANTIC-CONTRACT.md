# Clone prompt v4 semantic contract

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

## Runtime contract

1. New voices are rejected when measured VAD speech is too short to contain the
   complete `reference_text`.
2. Historical prompts with an implausible reference duration are quarantined
   from ICL and use speaker-embedding-only (`x-vector`) synthesis.
3. Every final WAV, including x-vector fallback output, is transcribed by the
   pinned local `openai/whisper-base` revision
   `e37978b90ca9030d5170a5c07aadb050351a65bb`.
4. Missing text, extra speech, a contiguous reference sequence, or insufficient
   similarity returns non-retryable `VOICE_OUTPUT_TEXT_MISMATCH`; the audio and
   timestamps are never returned.
5. For English and other letter languages, timestamps come only from Whisper's
   measured word boundaries on the final WAV. Multiple measured ASR words may
   be grouped onto one request token (for example `twenty` + `six` -> `26`), but
   one ASR word is never split by interpolation.
6. Chinese, Japanese, and Korean retain the existing segment-timing contract:
   ASR semantic validation is mandatory, while the word timestamp array is
   empty rather than fabricated.

## Existing prompt migration

Healthy v3/v4 prompts do not need regeneration. Regenerating them changes voice
identity and adds migration risk without correcting any contract violation.

An affected prompt cannot be repaired or rebuilt from `prompt.pt`: the missing
portion of the original recording is not present. It remains usable through the
x-vector safe path, subject to final-audio ASR validation. The durable quality
upgrade is user re-recording of the complete guide, which creates a new prompt
under the strict reference-duration gate. Do not overwrite a historical prompt
in place or synthesize fake reference audio to rebuild it.

Operational inventory should classify prompts as `healthy-icl`,
`quarantined-xvector`, or `re-record-required`; classification is computed from
the prompt's reference duration/codec frames and transcript, not from client or
account region. Web and the browser extension use only the international
worker. iOS and Android may route to either the international or China worker;
both workers enforce the same prompt and final-audio contract.
