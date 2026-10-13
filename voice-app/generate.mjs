import { readFile, writeFile, mkdir, rename, open, unlink } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const digest = value => createHash('sha256').update(value).digest('hex');
const terminal = new Set(['succeeded', 'failed', 'expired', 'cancelled']);
const languages = new Set(['en', 'zh', 'de', 'ja', 'fr', 'es', 'ko', 'pt', 'ru', 'it']);
const sleep = ms => new Promise(done => setTimeout(done, ms));

export function validateCards(input) {
  if (!Array.isArray(input) || !input.length || input.length > 200) throw new Error('Use 1–200 card rows.');
  const ids = new Set();
  return input.map(row => {
    if (!row || !/^[a-z0-9][a-z0-9-]{0,70}$/.test(row.id) || ids.has(row.id)) throw new Error('Use unique, filename-safe card IDs.');
    if (!languages.has(row.language) || typeof row.text !== 'string' || !row.text.isWellFormed()) throw new Error('Check the text and supported language for every card.');
    ids.add(row.id);
    const text = row.text.replace(/\r\n/g, '\n').normalize('NFC').trim();
    if (!text || Array.from(text).length > 500) throw new Error(`${row.id}: use 1–500 normalized characters.`);
    return { id: row.id, language: row.language, text };
  });
}

async function json(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
async function atomicJson(path, value) {
  const temporary = `${path}.tmp-${randomUUID()}`;
  await writeFile(temporary, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
  await rename(temporary, path);
}

/** Sequential jobs; checkpoints precede writes so uncertain calls reuse their key. */
export async function runCards({ client, baseURL, approvedEstimates, cards: input, output, voiceId, waitMs = 3000, timeoutMs = 660000, log = console.log }) {
  const cards = validateCards(input);
  if (!/^voice_[a-f0-9]{32}$/.test(voiceId)) throw new Error('Use a ready voice ID.');
  const dir = resolve(output);
  await mkdir(dir, { recursive: true });
  const lockPath = join(dir, '.running');
  let lock;
  try { lock = await open(lockPath, 'wx', 0o600); }
  catch (error) { if (error.code === 'EEXIST') throw new Error('This output folder is locked. Ensure its earlier process has stopped before removing .running.'); throw error; }
  try {
    await lock.writeFile(String(process.pid));
    const statePath = join(dir, 'state.json');
    const inputHash = digest(JSON.stringify({ cards, voiceId, model: 'clone-v1', output_format: 'mp3' }));
    let state = await json(statePath);
    if (state && state.inputHash !== inputHash) throw new Error('Inputs or voice changed. Keep this folder to recover old jobs; choose a new output folder for new generations.');
    state ||= { version: 1, runId: randomUUID(), inputHash, rows: {} };
    state.baseURL ||= baseURL || client.baseURL;
    if (state.baseURL) client = client.forRegion(state.baseURL);
    await atomicJson(statePath, state);
    const checkpoint = () => atomicJson(statePath, state);
    for (const card of cards) {
      const row = state.rows[card.id] ||= { idempotencyKey: `cards-${state.runId}-${card.id}` };
      if (row.sha256) {
        try { if (digest(await readFile(join(dir, `${card.id}.mp3`))) === row.sha256) { log(`${card.id}: saved, no API request`); continue; } }
        catch (error) { if (error.code !== 'ENOENT') throw error; }
      }
      const body = {
        model: 'clone-v1', voice_id: voiceId, text: card.text,
        language: card.language, output_format: 'mp3',
      };
      if (row.body && JSON.stringify(row.body) !== JSON.stringify(body)) throw new Error('The saved request changed. Restore its original checkpoint.');
      row.body ||= body;
      await checkpoint();
      // Check fresh prices only before a first submission. An uncertain POST must
      // retain its original body/key and may already have incurred a charge.
      if (!row.jobId && !row.submissionAttempted && approvedEstimates) {
        const approved = approvedEstimates.find(estimate => estimate.id === card.id);
        const { response } = await client.request('/usage/estimate', { method: 'POST', retry: false, body: row.body });
        const fresh = await response.json();
        const amount = value => typeof value === 'string' && /^\d{1,10}\.\d{6}$/.test(value) ? BigInt(value.replace('.', '')) : null;
        const cap = amount(approved?.maximumChargeUSD), current = amount(fresh.maximum_charge_usd);
        if (cap === null || current === null || current > cap || fresh.balance_sufficient !== true || fresh.reservation_created !== false) throw Object.assign(new Error('The approved estimate changed before submission.'), { code: 'estimate_changed' });
      }
      if (!row.jobId) { row.submissionAttempted = true; await checkpoint(); }
      let job = row.jobId ? await client.getJob(row.jobId) : await client.createJob(row.body, { idempotencyKey: row.idempotencyKey });
      row.jobId = job.id;
      await checkpoint();
      const deadline = Date.now() + timeoutMs;
      let lastStatus;
      while (true) {
        if (lastStatus !== job.status) { log(`${card.id}: ${job.status}`); lastStatus = job.status; }
        if (terminal.has(job.status)) break;
        if (Date.now() >= deadline) throw new Error(`${card.id}: waiting stopped; rerun this folder to follow the saved job, not create a replacement.`);
        const delay = Math.max(waitMs, job.retryAfterMs || 0);
        if (Date.now() + delay >= deadline) throw new Error(`${card.id}: waiting stopped; resume the original job later.`);
        await sleep(delay);
        job = await client.getJob(job.id);
      }
      row.status = job.status;
      // A terminal job can contain charged successful chunks even if its final status failed.
      if (typeof job.chargedMicrousd === 'string' && /^\d+$/.test(job.chargedMicrousd)) {
        const micro = BigInt(job.chargedMicrousd);
        row.chargedUSD = `${micro / 1000000n}.${String(micro % 1000000n).padStart(6, '0')}`;
        row.trialCharacters = job.trialCharacters;
        row.billableCharacters = job.billableCharacters;
      }
      await checkpoint();
      if (job.status !== 'succeeded') throw Object.assign(new Error(`${card.id}: ${job.status} (${job.errorCode || 'no code'}). Inspect the saved job; no replacement generation was submitted.`), { code: `job_${job.status}` });
      const result = await client.getJobAudio(job.id);
      if (!result.audio?.length) throw new Error(`${card.id}: empty audio response.`);
      await writeFile(join(dir, `${card.id}.mp3`), result.audio);
      Object.assign(row, {
        sha256: digest(result.audio), bytes: result.audio.length,
        chargedUSD: row.chargedUSD ?? result.chargedUSD, trialCharacters: row.trialCharacters ?? result.trialCharacters,
        billableCharacters: row.billableCharacters ?? result.billableCharacters,
      });
      await checkpoint();
    }
    const manifest = {
      version: 1, completedAt: new Date().toISOString(), voice: 'Your selected voice',
      model: 'clone-v1', outputFormat: 'mp3',
      rows: cards.map(card => {
        const row = state.rows[card.id];
        return { ...card, file: `${card.id}.mp3`, sha256: row.sha256, bytes: row.bytes, billableCharacters: row.billableCharacters, trialCharacters: row.trialCharacters, chargedUSD: row.chargedUSD };
      }),
    };
    await atomicJson(join(dir, 'manifest.json'), manifest);
    log(`Saved ${cards.length} MP3 files and manifest.json. Keep state.json private for recovery.`);
    return manifest;
  } finally { await lock.close(); await unlink(lockPath); }
}

async function main() {
  const cards = validateCards(JSON.parse(await readFile(process.env.CARDS_FILE || 'cards.json', 'utf8')));
  const characters = cards.reduce((total, card) => total + Array.from(card.text).length, 0);
  console.log(`${cards.length} files; ${characters} normalized characters; estimated USD ${(characters * 8 / 1000000).toFixed(6)} before any available trial credit, at USD 8 / million. Confirm current pricing before running.`);
  if (!process.argv.includes('--run')) { console.log('Plan only. No API calls. Use --run to generate and incur normal usage charges.'); return; }
  const { RegionalVoiceAPI } = await import('./api-client.mjs');
  const client = await RegionalVoiceAPI.connect();
  const models = await client.models();
  const enabled = models.data.find(model => model.id === 'clone-v1')?.languages || [];
  for (const card of cards) if (!enabled.includes(card.language)) throw new Error(`${card.language} is not enabled in this processing region.`);
  const voices = await client.voices();
  const voice = process.env.VOICE_ID
    ? voices.data.find(item => item.id === process.env.VOICE_ID && item.status === 'ready')
    : voices.data.find(item => item.default_voice_key === 'narrator' && item.status === 'ready');
  if (!voice) throw new Error('The selected voice is not ready or available in your project.');
  await client.verifyVoiceRegion(voice.id);
  await runCards({ client, cards, voiceId: voice.id, output: process.env.OUTPUT_DIR || 'output' });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => { console.error(error.code || error.name, error.message); process.exitCode = 1; });
}
