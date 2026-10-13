# CastReader Voice Studio

A standalone text-to-speech app with a Node.js backend and a browser interface.
Write a script, select a language and an authorized voice, preview the cost,
then generate, play, and download MP3s. Projects and original jobs survive restarts.

## Run

Requires **Node.js 22+**. From this directory:

```sh
npm install
npm start
```

Open **http://127.0.0.1:8791**. The editor and saved-audio playback work without
an API key. Live synthesis requires an activated [CastReader Voice API
workspace](https://voice.castreader.com/request-access) and a backend key with
`voices:read`, `speech:generate`, and `usage:read` permissions. CastReader Pro
is separate from API usage.

Set `CASTREADER_API_KEY` through your server environment or secret manager,
then restart the server. Never enter it into this page or into a chat.
For a hidden terminal prompt that works from bash or zsh:

```sh
bash -c 'read -r -s -p "CastReader API key: " CASTREADER_API_KEY; printf "\n"; export CASTREADER_API_KEY; exec npm start'
```

The key itself is not written in shell history. `.env.example` documents the
variable; `.env` files are **not** loaded automatically. Stop an existing server
with Ctrl-C before starting another one. Use `PORT=8793 npm start` for a different
port and `VOICE_STUDIO_DATA_DIR=/absolute/private/directory npm start` for a
separate data directory. The default is `~/.castreader-voice-studio`.

`npm run check` performs metadata, permission, routing and estimate checks;
it never synthesizes. Its small check text uses the short-request limit.

## Use

1. **Load ready voices.** The server resolves the region and loads every page
   of authorized, ready voices. It reads current queued limits from the manifest.
2. Write your text and choose its spoken language explicitly. Language selection
   does not translate. Each clip accepts up to 500 NFC-normalized Unicode code
   points, or a smaller current queued limit. Add up to 200 clips per project.
3. **Preview cost.** This validates the entire project and saves immutable inputs.
   It shows the API maximum before trial credit and the per-clip trial estimate.
   Trial snapshots can overlap and are not added together. Estimates do not
   reserve funds or guarantee future balance, pricing, or service availability.
   Before each first submission the server rechecks the maximum and stops if it
   exceeds the approved estimate. Uncertain submissions keep their original keys.
4. Review the estimate, check the approval box, and select **Generate audio**.
5. **Load player**, then use the native play/pause and seek controls. Download
   individual MP3s, the usage manifest, or a ZIP of the whole project. Results
   show actual returned charges and trial usage, including partial failed jobs.

Changing text or voice after a preview requires a new preview. Generation is
sequential. Closing the page does not stop it while the server remains running.
Ctrl-C finishes the active project before shutting down.

## Recovery and data

Private data is stored outside the source tree:

```text
~/.castreader-voice-studio/
  .server-running
  batches/<project-uuid>/
    batch.json       # text, voice, region and estimates
    execution.json   # local status and sanitized errors
    state.json       # exact request bodies, original job IDs, idempotency keys
    .running         # present only while this project is active
    <clip-id>.mp3
    manifest.json
```

After a restart, select the original entry under **Saved projects**. Resume keeps
its execution region and exact request body/key. Completed files are reused;
missing or corrupt files are fetched from the original job. Failed, cancelled,
or expired jobs are never silently replaced. A deliberate new project can incur
new charges. Download promptly: upstream results are retained for at most 24 hours.

A hard kill can leave lock files. Read the PID and confirm that the process has
stopped before removing only that installation's `.server-running` or that
project's `.running`. Preserve `state.json` and the full project folder.
A started project with a missing checkpoint is blocked to avoid duplicate work.

This server is for one user on **127.0.0.1**. It checks Host, Origin and CSRF
headers, allowlists static paths, checks audio hashes, and never returns the API
key. Do not expose it publicly without adding account authentication, ownership
checks and usage limits. Exported manifests omit private voice IDs and job keys.

## Implementation

- `server.mjs`: local HTTP API, validation, estimates, storage and audio exports.
- `api-client.mjs`: official SDK 0.2.2, region pinning, paginated voice listing,
  current queued limits, and polling hints. The SDK is pinned to the official
  download URL with a lockfile; it is not an unpublished npm registry package.
- `generate.mjs`: sequential MP3 jobs, private checkpoints and same-job recovery.
- `ui/`: responsive, accessible English/Chinese editor and native audio players.
- `voice.mjs`: bundled dependency-free client and optional single-job CLI.
- `connection-check.mjs`: non-generating setup diagnostic.

`npm run plan` is an offline reference estimate for `cards.json`. Its reference
rate is not a live quote; use the browser's authenticated cost preview for actual
work. `npm run generate` is an explicit billable CLI operation over `cards.json`;
set `VOICE_ID`, `CARDS_FILE` and `OUTPUT_DIR` as needed. Keep the same output
folder when recovering an existing CLI run.

## Verification

```sh
npm test
```

24 automated tests cover validation, region pinning, SDK request contracts,
voice pagination, queued versus synchronous limits, saved bodies and keys,
interrupted submission/download recovery, partial receipts, local security,
replay without generation, and ZIP/manifest exports. All use offline fixtures.

For a browser walkthrough without credentials:

```sh
node tests/preview.mjs
```

Open **http://127.0.0.1:8792**. This separate test server uses an explicitly labeled
**440 Hz test tone, not synthesized speech**, and temporary private data. It
never calls CastReader or charges anything. `tests/fixtures/test-tone.mp3` was
created locally with FFmpeg, lasts approximately two seconds, and is only a
playback fixture. The normal app never substitutes this fixture for live speech.

Live synthesis has not been verified: `CASTREADER_API_KEY` was absent during
implementation. No paid API generation was submitted; actual charge was **$0**.

## API references

[Integration manifest](https://voice.castreader.com/integration-manifest.json) ·
[OpenAPI](https://voice.castreader.com/openapi.json) ·
[Pricing](https://voice.castreader.com/pricing)
