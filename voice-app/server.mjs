/** Local Node.js 22+ app. The browser never supplies a key, path or upstream URL. */
import { createServer } from 'node:http';
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { readFile, writeFile, mkdir, rename, readdir, lstat, open, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runCards, validateCards } from './generate.mjs';

const root = import.meta.dirname;
const languageNames = { en: 'English', zh: '中文', ja: '日本語', es: 'Español', de: 'Deutsch', fr: 'Français', ko: '한국어', pt: 'Português', ru: 'Русский', it: 'Italiano' };
const uuid = '[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}';
const batchRoute = new RegExp(`^/api/batches/(${uuid})(?:/(start|manifest|archive|audio/([a-z0-9][a-z0-9-]{0,70})))?$`);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const statuses = new Set(['queued', 'running', 'succeeded', 'failed', 'expired', 'cancelled']);
class AppError extends Error {
  constructor(status, code, message) { super(message); Object.assign(this, { status, code }); }
}
const fail = (status, code, message) => { throw new AppError(status, code, message); };
const safeErrors = {
  invalid_api_key: 'Check CASTREADER_API_KEY in the server environment.',
  expired_api_key: 'Update the expired key in the server environment.',
  insufficient_scope: 'The key needs speech:generate, voices:read and usage:read permissions.',
  insufficient_balance: 'The current balance cannot cover this input. No top-up was attempted.',
  voice_not_found: 'This voice is unavailable to the configured key.',
  voice_language_unverified: 'The selected voice is not enabled for one of these languages.',
  text_language_mismatch: 'Check that each language matches its text.',
  unsupported_language: 'One of these languages is unavailable in this region.',
  rate_limit_exceeded: 'The API rate limit was reached. Wait before resuming the same batch.',
  admission_paused: 'New work is paused by the service. Keep this batch for later.',
  job_failed: 'Audio generation failed. Resume checks the original job; it will not create a replacement. Review any partial charges below.',
  job_expired: 'The original job expired. Saved audio is still playable. A new generation requires a new project and cost review.',
  job_cancelled: 'The original job was cancelled. Any completed chunks can still have a charge. Resume does not replace it.',
  regional_voice_required: 'This voice belongs to a different region. Reload your available voices before planning.',
  invalid_route: 'The API did not return an approved CastReader region.',
  network_outcome_unknown: 'The connection was interrupted. Resume the saved project to check its original job.',
  configuration_unavailable: 'Service configuration could not be loaded. Try loading voices again.',
  estimate_changed: 'Pricing or balance changed before submission. Preview a new project and review its cost. Existing jobs are preserved.',
};
function publicError(error) {
  if (error instanceof AppError) return { code: error.code, message: error.message };
  // Never relay SDK messages, request headers, response bodies or stack traces.
  const code = Object.hasOwn(safeErrors, error?.code) ? error.code : 'operation_stopped';
  return { code, message: safeErrors[code] || 'Operation stopped. Keep this batch and resume its original jobs; check the API console if it remains stopped.' };
}
function fields(value, allowed) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !allowed.includes(key))) fail(400, 'invalid_input', 'Unexpected request fields.');
}
function cardsInput(value) {
  if (!Array.isArray(value)) fail(400, 'invalid_input', 'Use an array of card rows.');
  for (const row of value) {
    fields(row, ['id', 'text', 'language']);
    if (typeof row.id !== 'string' || Object.hasOwn(Object.prototype, row.id)) fail(400, 'invalid_input', 'Every card needs a unique, non-reserved text ID.');
  }
  try { return validateCards(value); }
  catch { fail(400, 'invalid_input', 'Use 1–200 rows with unique lowercase IDs, supported languages and 1–500 normalized characters each.'); }
}
async function readJson(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
async function atomicJson(path, value) {
  const temporary = `${path}.tmp-${randomUUID()}`;
  await writeFile(temporary, JSON.stringify(value, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  await rename(temporary, path);
}
async function privateDirectory(path) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink()) fail(409, 'unsafe_directory', 'The app data directory must be a real directory, not a symbolic link.');
}
async function bodyJson(request) {
  if (!/^application\/json(?:;\s*charset=utf-8)?$/i.test(request.headers['content-type'] || '')) fail(415, 'content_type', 'Use application/json.');
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 512 * 1024) fail(413, 'body_limit', 'The request exceeds 512 KiB.');
    chunks.push(chunk);
  }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); }
  catch { fail(400, 'invalid_json', 'Use valid UTF-8 JSON.'); }
}
const microUSD = value => {
  if (typeof value !== 'string' || !/^\d{1,10}\.\d{6}$/.test(value)) fail(502, 'invalid_estimate', 'The API returned an invalid estimate.');
  return BigInt(value.replace('.', ''));
};
const usd = value => `${value / 1000000n}.${String(value % 1000000n).padStart(6, '0')}`;

// ZIP store format, no external executable or library. Entries come only from verified files.
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function zip(entries) {
  let offset = 0;
  const parts = [], central = [];
  for (const { name, bytes } of entries) {
    const filename = Buffer.from(name);
    const crc = crc32(bytes);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(33, 12); local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(bytes.length, 18); local.writeUInt32LE(bytes.length, 22); local.writeUInt16LE(filename.length, 26);
    const record = Buffer.alloc(46);
    record.writeUInt32LE(0x02014b50); record.writeUInt16LE(20, 4); record.writeUInt16LE(20, 6); record.writeUInt16LE(0x800, 8);
    record.writeUInt16LE(33, 14); record.writeUInt32LE(crc, 16);
    record.writeUInt32LE(bytes.length, 20); record.writeUInt32LE(bytes.length, 24); record.writeUInt16LE(filename.length, 28); record.writeUInt32LE(offset, 42);
    parts.push(local, filename, bytes); central.push(record, filename);
    offset += local.length + filename.length + bytes.length;
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...parts, directory, end]);
}

/** Injection options are for offline tests, never accepted from HTTP or environment URLs. */
export async function startServer({ port = 8791, dataDir = join(homedir(), '.castreader-voice-studio'), client: injectedClient, waitMs = 3000, timeoutMs = 660000 } = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('Use a valid local port.');
  await privateDirectory(dataDir);
  const batchesDir = join(dataDir, 'batches');
  await privateDirectory(batchesDir);
  const lockPath = join(dataDir, '.server-running');
  let lock;
  try { lock = await open(lockPath, 'wx', 0o600); }
  catch (error) { if (error.code === 'EEXIST') fail(409, 'server_locked', 'Another app may be running. Stop it before removing the .server-running lock described in README.md.'); throw error; }
  await lock.writeFile(String(process.pid));
  const token = randomBytes(32).toString('hex');
  let clientPromise, active = null, closing = false, origin;
  const progress = new Map();
  function client() {
    if (injectedClient) return Promise.resolve(injectedClient);
    if (!process.env.CASTREADER_API_KEY || /[\r\n]/.test(process.env.CASTREADER_API_KEY)) fail(503, 'missing_key', 'Set CASTREADER_API_KEY in your terminal, then restart the app.');
    clientPromise ||= import('./api-client.mjs').then(({ RegionalVoiceAPI }) => RegionalVoiceAPI.connect()).catch(error => {
      clientPromise = null;
      if (error.code === 'ERR_MODULE_NOT_FOUND') fail(503, 'sdk_unavailable', 'Run npm install in the app folder, then restart the app.');
      throw error;
    });
    return clientPromise;
  }
  async function catalog() {
    const api = await client();
    const [models, voices, capabilities] = await Promise.all([api.models(), api.voices(), api.capabilities?.()]);
    const model = models.data?.find(item => item.id === 'clone-v1');
    if (!Array.isArray(model?.languages) || !Number.isSafeInteger(model.max_characters) || model.max_characters < 1 || !Array.isArray(voices.data)) fail(502, 'invalid_catalog', 'The API returned an invalid model or voice list.');
    return {
      languages: Object.keys(languageNames).filter(language => model.languages.includes(language)),
      // /models describes short synchronous requests; queued jobs have a separate limit.
      maxCharacters: capabilities?.maxCharacters ?? Math.min(500, model.max_characters),
      baseURL: api.baseURL,
      voices: voices.data.filter(voice => voice.status === 'ready' && /^voice_[a-f0-9]{32}$/.test(voice.id)).map(voice => ({ id: voice.id, name: String(voice.name || 'Ready voice').slice(0, 100), default: voice.default_voice_key === 'narrator' })),
      // Production client follows all voice pages in the selected region.
      hasMoreVoices: voices.has_more === true,
    };
  }
  async function batch(id) {
    const dir = join(batchesDir, id);
    try { if (!(await lstat(dir)).isDirectory() || (await lstat(dir)).isSymbolicLink()) throw new Error(); }
    catch { fail(404, 'not_found', 'Batch not found.'); }
    if ((await readdir(dir, { withFileTypes: true })).some(entry => entry.isSymbolicLink())) fail(409, 'unsafe_directory', 'A batch contains a symbolic link. Restore its original regular files before continuing.');
    const config = await readJson(join(dir, 'batch.json'));
    if (!config || config.id !== id) fail(404, 'not_found', 'Batch not found.');
    return { dir, config };
  }
  async function snapshot(id) {
    const { dir, config } = await batch(id);
    const state = await readJson(join(dir, 'state.json'));
    const execution = await readJson(join(dir, 'execution.json'));
    const rows = await Promise.all(config.cards.map(async card => {
      const row = state?.rows?.[card.id];
      const file = await lstat(join(dir, `${card.id}.mp3`)).catch(() => null);
      const saved = Boolean(row?.sha256 && file?.isFile() && !file.isSymbolicLink() && file.size === row.bytes);
      return { ...card, status: saved ? 'saved' : progress.get(id)?.[card.id] || (row?.status === 'succeeded' ? 'download_pending' : row?.status) || (row?.jobId ? 'pending' : row?.idempotencyKey ? 'submission_unknown' : 'not_started'), saved, sha256: saved ? row.sha256 : null, bytes: saved ? row.bytes : null, chargedUSD: row?.chargedUSD ?? null, trialCharacters: row?.trialCharacters ?? null, billableCharacters: row?.billableCharacters ?? null };
    }));
    const completed = rows.filter(row => row.saved).length;
    return { ...config, rows, completed, status: active?.id === id ? 'running' : completed === rows.length ? 'complete' : execution ? 'paused' : 'planned', error: execution?.error || null };
  }
  async function audio(dir, card, row) {
    if (!row?.sha256 || !/^[a-f0-9]{64}$/.test(row.sha256)) fail(409, 'audio_missing', 'This clip is not saved yet. Resume its original batch.');
    let file;
    try { file = await open(join(dir, `${card.id}.mp3`), constants.O_RDONLY | constants.O_NOFOLLOW); }
    catch { fail(409, 'audio_missing', 'The local clip is missing. Resume its original batch to recover the original result.'); }
    try {
      const info = await file.stat();
      if (!info.isFile() || info.size > 16 * 1024 * 1024) fail(409, 'invalid_audio', 'The local clip is not a valid saved file.');
      const bytes = await file.readFile();
      if (hash(bytes) !== row.sha256) fail(409, 'checksum_mismatch', 'The local clip failed its checksum. Resume this batch to download the original result.');
      return bytes;
    } finally { await file.close(); }
  }
  async function exportEntries(id, includeAudio) {
    const { dir, config } = await batch(id);
    const state = await readJson(join(dir, 'state.json'));
    const entries = [], rows = [];
    let size = 0;
    for (const card of config.cards) {
      const row = state?.rows?.[card.id];
      const bytes = await audio(dir, card, row);
      size += bytes.length;
      if (includeAudio && size > 128 * 1024 * 1024) fail(413, 'archive_limit', 'The batch exceeds the 128 MiB ZIP limit. Download individual clips and the manifest.');
      rows.push({ ...card, file: `${card.id}.mp3`, sha256: row.sha256, bytes: bytes.length, chargedUSD: row.chargedUSD, trialCharacters: row.trialCharacters, billableCharacters: row.billableCharacters });
      if (includeAudio) entries.push({ name: `${card.id}.mp3`, bytes });
    }
    const manifest = { version: 1, voice: 'Your selected voice', model: 'clone-v1', outputFormat: 'mp3', rows };
    entries.unshift({ name: 'manifest.json', bytes: Buffer.from(JSON.stringify(manifest, null, 2) + '\n') });
    return entries;
  }
  const staticFiles = { '/': ['ui/index.html', 'text/html'], '/app.js': ['ui/app.js', 'text/javascript'], '/i18n.js': ['ui/i18n.js', 'text/javascript'], '/style.css': ['ui/style.css', 'text/css'] };
  function send(response, status, value, type = 'application/json', filename) {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(JSON.stringify(value));
    response.writeHead(status, { 'Content-Type': `${type}${type.startsWith('text/') || type === 'application/json' ? '; charset=utf-8' : ''}`, 'Content-Length': bytes.length, ...(filename ? { 'Content-Disposition': `attachment; filename="${filename}"` } : {}) });
    response.end(bytes);
  }
  const server = createServer(async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; media-src blob:; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    try {
      if (closing) fail(503, 'closing', 'The local app is shutting down.');
      if (request.headers.host !== new URL(origin).host || request.headers['x-forwarded-host'] || request.headers.forwarded) fail(403, 'host_denied', 'Open the exact 127.0.0.1 address printed by the server.');
      if (request.headers.origin !== undefined && request.headers.origin !== origin) fail(403, 'origin_denied', 'Cross-origin requests are blocked.');
      const site = request.headers['sec-fetch-site'];
      if (site && !['same-origin', 'none'].includes(site)) fail(403, 'origin_denied', 'Cross-origin requests are blocked.');
      // Match the raw path. No URL normalization, filesystem mapping or query parameters.
      const path = request.url;
      if (Object.hasOwn(staticFiles, path) && request.method === 'GET') {
        const [file, type] = staticFiles[path];
        return send(response, 200, await readFile(join(root, file)), type);
      }
      if (path === '/api/session' && request.method === 'GET') {
        if (site !== 'same-origin' && request.headers.origin !== origin) fail(403, 'origin_required', 'Session setup requires a same-origin browser request.');
        return send(response, 200, { csrfToken: token, configured: Boolean(injectedClient || process.env.CASTREADER_API_KEY), languages: languageNames, cards: cardsInput(await readJson(join(root, 'cards.json'))) });
      }
      const provided = Buffer.from(request.headers['x-csrf-token'] || '');
      if (provided.length !== token.length || !timingSafeEqual(provided, Buffer.from(token))) fail(403, 'csrf_denied', 'Reload the local app to establish a new session.');
      if (request.method === 'POST' && request.headers.origin !== origin) fail(403, 'origin_required', 'Writes require an exact Origin header.');
      if (path === '/api/catalog' && request.method === 'GET') return send(response, 200, await catalog());
      if (path === '/api/batches' && request.method === 'GET') {
        const ids = (await readdir(batchesDir)).filter(id => new RegExp(`^${uuid}$`).test(id));
        const results = await Promise.allSettled(ids.map(async id => {
          const { config } = await batch(id);
          // Bad metadata must be isolated before sorting or rendering the list.
          if (typeof config.title !== 'string' || !config.title.trim() || config.title.length > 80 || !config.title.isWellFormed()
            || typeof config.createdAt !== 'string' || !Number.isFinite(Date.parse(config.createdAt))) fail(409, 'invalid_batch', 'Batch metadata is incomplete.');
          return { id, title: config.title, createdAt: config.createdAt };
        }));
        const items = results.filter(result => result.status === 'fulfilled').map(result => result.value);
        // Preserve every directory; expose only a count, never rejected IDs, paths or errors.
        return send(response, 200, { batches: items.sort((a, b) => b.createdAt.localeCompare(a.createdAt)), skippedBatchCount: results.length - items.length });
      }
      if (path === '/api/batches' && request.method === 'POST') {
        const input = await bodyJson(request);
        fields(input, ['cards', 'voiceId', 'title']);
        const cards = cardsInput(input.cards);
        if (typeof input.voiceId !== 'string' || !/^voice_[a-f0-9]{32}$/.test(input.voiceId)) fail(400, 'invalid_voice', 'Choose a ready voice from the server list.');
        if (typeof input.title !== 'string' || !input.title.trim() || input.title.length > 80 || !input.title.isWellFormed()) fail(400, 'invalid_title', 'Use a batch title of 1–80 characters.');
        const available = await catalog();
        const voice = available.voices.find(item => item.id === input.voiceId);
        if (!voice) fail(400, 'invalid_voice', 'Choose a ready voice returned for this key.');
        if (cards.some(card => !available.languages.includes(card.language) || Array.from(card.text).length > available.maxCharacters)) fail(400, 'model_limit', 'The selected region does not support one of these languages or text lengths.');
        let maximum = 0n;
        const estimates = [];
        const api = await client();
        await api.verifyVoiceRegion?.(voice.id);
        for (const card of cards) {
          const { response: result } = await api.request('/usage/estimate', { method: 'POST', retry: false, body: { model: 'clone-v1', voice_id: voice.id, language: card.language, text: card.text, output_format: 'mp3' } });
          const estimate = await result.json();
          if (estimate.reservation_created !== false || estimate.balance_sufficient !== true) fail(409, 'estimate_unavailable', 'An input did not pass the non-reserving balance estimate. No generation was submitted.');
          if (estimate.billable_characters !== Array.from(card.text).length) fail(502, 'invalid_estimate', 'The API character count differs from the local plan.');
          maximum += microUSD(estimate.maximum_charge_usd);
          microUSD(estimate.estimated_charge_usd);
          if (!Number.isSafeInteger(estimate.trial_characters) || estimate.trial_characters < 0 || estimate.trial_characters > estimate.billable_characters) fail(502, 'invalid_estimate', 'The API returned invalid trial usage.');
          estimates.push({ id: card.id, trialCharacters: estimate.trial_characters, estimatedChargeUSD: estimate.estimated_charge_usd, maximumChargeUSD: estimate.maximum_charge_usd });
        }
        const id = randomUUID(), dir = join(batchesDir, id);
        const config = { version: 1, id, title: input.title.trim(), createdAt: new Date().toISOString(), voiceId: voice.id, voiceName: voice.name, baseURL: available.baseURL, cards, estimate: { characters: cards.reduce((n, card) => n + Array.from(card.text).length, 0), maximumChargeUSD: usd(maximum), rows: estimates, note: 'Before trial credit. Estimates are balance snapshots, not reservations. Trial allowance shown per clip may overlap; it is not added across clips.' } };
        await privateDirectory(dir);
        await atomicJson(join(dir, 'batch.json'), config);
        return send(response, 201, await snapshot(id));
      }
      const match = batchRoute.exec(path);
      if (match) {
        const [, id, action, cardId] = match;
        if (!action && request.method === 'GET') return send(response, 200, await snapshot(id));
        if (action === 'start' && request.method === 'POST') {
          const input = await bodyJson(request);
          fields(input, ['confirm']);
          if (input.confirm !== true) fail(400, 'confirmation_required', 'Explicitly confirm generation or recovery of this saved batch.');
          if (active) fail(409, 'batch_running', 'A batch is already running. Wait for it before starting another.');
          // Reserve synchronously before any await so rapid clicks cannot race.
          const operation = { id, promise: null };
          active = operation;
          try {
            const { dir, config } = await batch(id);
            if (await lstat(join(dir, '.running')).catch(() => null)) fail(409, 'batch_locked', 'This batch has a .running lock. Confirm the earlier process stopped before manually removing that exact lock.');
            if (await readJson(join(dir, 'execution.json')) && !await readJson(join(dir, 'state.json'))) fail(409, 'checkpoint_missing', 'This started batch has lost its checkpoint. Restore the original files before continuing.');
            const api = await client();
            progress.set(id, {});
            await atomicJson(join(dir, 'execution.json'), { startedAt: new Date().toISOString() });
            operation.promise = runCards({ client: api, baseURL: config.baseURL, approvedEstimates: config.estimate.rows, cards: config.cards, voiceId: config.voiceId, output: dir, waitMs, timeoutMs, log(line) {
              const found = /^([a-z0-9-]+): ([a-z_]+)$/.exec(line);
              if (found && statuses.has(found[2])) progress.get(id)[found[1]] = found[2];
            } }).then(() => atomicJson(join(dir, 'execution.json'), { completedAt: new Date().toISOString() })).catch(error => atomicJson(join(dir, 'execution.json'), { stoppedAt: new Date().toISOString(), error: publicError(error) })).finally(() => { if (active === operation) active = null; progress.delete(id); });
            // Observe persistence failures without printing potentially sensitive SDK errors.
            operation.promise.catch(() => {});
            return send(response, 202, { id, status: 'running' });
          } catch (error) { if (active === operation) active = null; throw error; }
        }
        if (request.method === 'GET' && action?.startsWith('audio/')) {
          const { dir, config } = await batch(id);
          const card = config.cards.find(row => row.id === cardId);
          if (!card) fail(404, 'not_found', 'Clip not found.');
          const state = await readJson(join(dir, 'state.json'));
          return send(response, 200, await audio(dir, card, state?.rows?.[card.id]), 'audio/mpeg', `${card.id}.mp3`);
        }
        if (request.method === 'GET' && ['manifest', 'archive'].includes(action)) {
          const entries = await exportEntries(id, action === 'archive');
          return action === 'archive' ? send(response, 200, zip(entries), 'application/zip', 'voice-studio-results.zip') : send(response, 200, entries[0].bytes, 'application/json', 'manifest.json');
        }
      }
      fail(404, 'not_found', 'Route not found.');
    } catch (error) {
      if (!response.headersSent) send(response, error instanceof AppError ? error.status : 502, { error: publicError(error) });
      else response.end();
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  async function releaseLock() { await lock.close(); await unlink(lockPath); }
  try {
    await new Promise((done, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', done); });
    origin = `http://127.0.0.1:${server.address().port}`;
  } catch (error) { await releaseLock(); throw error; }
  return { server, origin, async close() {
    closing = true;
    await new Promise(done => server.close(done));
    await active?.promise;
    await releaseLock();
  } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length > 2) { console.error('Use npm start. Optional PORT, VOICE_STUDIO_DATA_DIR and CASTREADER_API_KEY belong in the server environment.'); process.exitCode = 2; }
  else {
    const dataDir = process.env.VOICE_STUDIO_DATA_DIR ? resolve(process.env.VOICE_STUDIO_DATA_DIR) : join(homedir(), '.castreader-voice-studio');
    startServer({ port: process.env.PORT === undefined ? 8791 : Number(process.env.PORT), dataDir }).then(app => {
      console.log(`Voice Studio: ${app.origin}\nPrivate batches: ${join(dataDir, 'batches')}\nGenerate only after reviewing and confirming a plan in the browser.`);
      let stopping = false;
      const stop = () => {
        if (stopping) return;
        stopping = true;
        console.log('Finishing the active batch before shutdown. Keep checkpoints if this process is interrupted.');
        app.close().catch(() => { console.error('Shutdown interrupted; preserve the app data and locks for recovery.'); process.exitCode = 1; });
      };
      process.on('SIGINT', stop); process.on('SIGTERM', stop);
    }).catch(error => { console.error(publicError(error).message); process.exitCode = 1; });
  }
}
