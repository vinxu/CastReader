# Playback priority

Continuous usable speech is the primary output. Spectral, clipping and pitch scores are advisory observations, not an admission policy for a whole spoken paragraph. They emit `generated_audio_quality_warning` with `blocking=false` and do not trigger regeneration or change the audio.

Word-timing computation runs after encoding and is optional. Any timing exception preserves the MP3 and voice, returns `timestamps: []`, and logs `captioned_word_timing_unavailable`. Existing clients can use sentence highlighting. Do not add ASR to the synthesis hot path.

Unparseable or non-finite samples, empty/near-silent audio, and genuinely failed generation/conversion still require recovery. Existing voice identity, source recording quality, creation denoising, authentication, regional routing and quota policies are unchanged.

Regression: the 2026-09-03 global Kindle first paragraph generated two 5-second candidates with independent ASR similarity 0.9753 and 1.0. Both were discarded by a prefix spectral percentile heuristic. The final greedy candidate was near-silent. Repeated fixed-parameter requests reproduced the same failures and stopped the next page. Valid candidates must survive uncertain quality scoring, and optional word timing must never veto audio.
