# Verification — 2026-09-15

- `npm test`: **24 passed, 0 failed**. Requests in these tests use local fakes;
  the official SDK contract test intercepts network calls in its test process.
- Syntax checks: `ui/app.js` and `ui/i18n.js` passed Node parsing.
- Normal server launched at `http://127.0.0.1:8791` with no API key. The editor
  rendered, generation remained unavailable, and voice loading showed a clear
  server-key setup error.
- Browser flow on the separate offline test server: load voice → reject a
  501-character input → preview → approve → generate fixture → load player.
  The fake provider recorded **one submission and one logical job**.
- Saved project reopened successfully. Browser audio reported `readyState=4`,
  `duration=2`, then `currentTime=2`, `ended=true`, and no media error after
  keyboard playback. Reopening and playback made no new synthesis submission.
- The test file is a locally created 440 Hz tone, explicitly labeled as offline
  test audio. FFprobe verified MP3, mono, 24 kHz, duration 2 seconds.
- Switching the interface to Chinese preserved English as the clip language.
- Normal window layout was visually inspected; document width matched viewport.
- A native accessibility click on the embedded browser's play control crashed
  that preview once. Reopening the saved project and using keyboard playback
  completed successfully. This is recorded separately from synthesis checks.

## Live verification still needed

`node connection-check.mjs` returned `missing_key`. No live synthesis or voice
quality was tested, and no production API job was submitted. Actual API charge:
**$0**. Configure the backend `CASTREADER_API_KEY`, restart the server, preview
one short clip, and generate it to verify the account's live service.

Public contract was checked using the current integration manifest, OpenAPI,
and integration guide from `voice.castreader.com`. The SDK remains pinned to
its official 0.2.2 download. Source changes are confined to `voice-app/`.
