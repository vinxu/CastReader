#!/usr/bin/env node
/** CastReader plugin: Node 22+, no dependencies. Private, restartable audio jobs. */
import { readFile, writeFile, mkdir, rename, open, unlink, lstat } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const ORIGIN = 'https://voice.castreader.com';
const BASES = new Set([`${ORIGIN}/v1`, 'https://voice.castreader.cn/v1']);
const TERMINAL = new Set(['succeeded', 'failed', 'cancelled', 'expired']);
const hash = data => createHash('sha256').update(data).digest('hex');
const sleep = ms => new Promise(done => setTimeout(done, ms));
export class VoiceError extends Error {
  constructor(code, fields = {}) { super(code); Object.assign(this, { code }, fields); }
}
const fail = (code, fields) => { throw new VoiceError(code, fields); };
export function money(value) {
  if (typeof value !== 'string' || !/^\d{1,8}(?:\.\d{1,6})?$/.test(value)) fail('invalid_usd_amount');
  const [whole, fraction = ''] = value.split('.');
  return BigInt(whole) * 1000000n + BigInt(fraction.padEnd(6, '0'));
}
export const usd = micro => `${BigInt(micro) / 1000000n}.${String(BigInt(micro) % 1000000n).padStart(6, '0')}`;
export function inputBody(input) {
  if (!input || Object.keys(input).some(k => !['text', 'language', 'voice_id', 'output_format', 'speed', 'return_timestamps', 'model'].includes(k))) fail('invalid_input_fields');
  if (typeof input.text !== 'string' || !input.text.isWellFormed()) fail('invalid_text');
  const text = input.text.replace(/\r\n/g, '\n').normalize('NFC').trim();
  if (!text || [...text].length > 500) fail('text_limit_500');
  if (!['en','zh','de','ja','fr','es','ko','pt','ru','it'].includes(input.language)) fail('explicit_language_required');
  if (input.voice_id && !/^voice_[a-f0-9]{32}$/.test(input.voice_id)) fail('invalid_voice_id');
  if (input.model && input.model !== 'clone-v1') fail('unsupported_model');
  const output_format = input.output_format || 'mp3';
  if (!['mp3', 'wav'].includes(output_format)) fail('unsupported_format');
  if (input.return_timestamps !== undefined && typeof input.return_timestamps !== 'boolean') fail('invalid_timestamps');
  if (input.return_timestamps && input.language !== 'en') fail('timestamps_english_only');
  if (input.speed !== undefined && (typeof input.speed !== 'number' || input.speed < 0.5 || input.speed > 2)) fail('invalid_speed');
  return { model: 'clone-v1', ...input, text, output_format };
}
async function bounded(response, max) {
  if (!response.body || Number(response.headers.get('content-length')) > max) { await response.body?.cancel(); fail('response_size'); }
  const reader = response.body.getReader(), chunks = []; let size = 0;
  try { for (;;) { const { done, value } = await reader.read(); if (done) break; size += value.length; if (size > max) fail('response_size'); chunks.push(Buffer.from(value)); } }
  finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  return Buffer.concat(chunks, size);
}
export class Client {
  constructor({ apiKey = process.env.CASTREADER_API_KEY, fetchImpl = fetch } = {}) {
    if (!apiKey || /\s/.test(apiKey)) fail('missing_api_key');
    this.apiKey = apiKey; this.fetch = fetchImpl;
  }
  async request(base, path, body, key, audio = false) {
    if (!BASES.has(base) || !/^\/[a-zA-Z0-9_/?=&%.-]*$/.test(path) || path.includes('..')) fail('invalid_route');
    let response;
    try { response = await this.fetch(base + path, { redirect: 'error', signal: AbortSignal.timeout(30000), method: body ? 'POST' : 'GET', headers: { Authorization: `Bearer ${this.apiKey}`, ...(body ? { 'Content-Type': 'application/json' } : {}), ...(key ? { 'Idempotency-Key': key } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) }); }
    catch { fail('network_outcome_unknown'); }
    const retry = response.headers.get('retry-after');
    const retryAfterMs = retry ? Math.max(0, /^\d+$/.test(retry) ? Number(retry) * 1000 : Date.parse(retry) - Date.now()) : 3000;
    if (!response.ok) {
      let payload; try { payload = JSON.parse((await bounded(response, 1048576)).toString()); } catch {}
      const code = /^[a-z0-9_]{1,70}$/.test(payload?.error?.code || '') ? payload.error.code : 'api_error';
      fail(code, { httpStatus: response.status, retryAfterMs: Number.isFinite(retryAfterMs) ? retryAfterMs : 3000 });
    }
    if (audio) {
      if (!/^audio\//.test(response.headers.get('content-type') || '')) fail('invalid_audio_type');
      const bytes = await bounded(response, 16777216);
      if (bytes.length < 12 || !(bytes.subarray(0,3).toString() === 'ID3' || (bytes[0] === 255 && (bytes[1] & 224) === 224) || (bytes.subarray(0,4).toString() === 'RIFF' && bytes.subarray(8,12).toString() === 'WAVE'))) fail('invalid_audio_bytes');
      return bytes;
    }
    let data; try { data = JSON.parse((await bounded(response, 1048576)).toString()); } catch { fail('invalid_json_response'); }
    return { data, retryAfterMs: Number.isFinite(retryAfterMs) ? retryAfterMs : 3000 };
  }
  async json(base, path, body, key) { return (await this.request(base, path, body, key)).data; }
  async route(voiceId) {
    const route = await this.json(`${ORIGIN}/v1`, '/route' + (voiceId ? '?voice_id=' + encodeURIComponent(voiceId) : ''));
    if (!BASES.has(route.base_url)) fail('invalid_route');
    return route.base_url;
  }
  async voices(base) {
    const voices = [], seen = new Set(); let cursor = '';
    for (let page = 0; page < 50; page++) {
      const list = await this.json(base, '/voices?limit=100' + (cursor ? '&cursor=' + encodeURIComponent(cursor) : ''));
      if (!Array.isArray(list.data)) fail('invalid_voices');
      voices.push(...list.data);
      if (!list.has_more) return voices;
      if (typeof list.next_cursor !== 'string' || seen.has(list.next_cursor)) fail('invalid_pagination');
      cursor = list.next_cursor; seen.add(cursor);
    }
    fail('pagination_limit');
  }
  async prepare(input) {
    const body = inputBody(input), base = await this.route(body.voice_id);
    const models = await this.json(base, '/models');
    const model = models.data?.find(m => m.id === 'clone-v1');
    if (!model?.languages?.includes(body.language)) fail('unsupported_regional_language');
    const voices = await this.voices(base);
    const voice = body.voice_id ? voices.find(v => v.id === body.voice_id && v.status === 'ready') : voices.find(v => v.default_voice_key === 'narrator' && v.status === 'ready') || voices.find(v => v.status === 'ready');
    if (!voice || !/^voice_[a-f0-9]{32}$/.test(voice.id)) fail('no_ready_voice');
    body.voice_id = voice.id;
    if (await this.route(voice.id) !== base) fail('regional_voice_required');
    const estimate = await this.json(base, '/usage/estimate', body);
    if (estimate.reservation_created !== false) fail('invalid_estimate');
    money(estimate.maximum_charge_usd); money(estimate.estimated_charge_usd);
    if (estimate.balance_sufficient !== true) fail('insufficient_balance');
    return { body, base, voiceName: voice.name, estimate };
  }
}
async function readJson(path) { try { return JSON.parse(await readFile(path, 'utf8')); } catch (e) { if (e.code === 'ENOENT') return null; throw e; } }
async function atomic(path, bytes) {
  const temp = `${path}.tmp-${randomUUID()}`;
  const file = await open(temp, 'wx', 0o600);
  try { await file.writeFile(bytes); await file.sync(); } finally { await file.close(); }
  await rename(temp, path);
  const parent = await open(resolve(path, '..'), 'r');
  try { await parent.sync(); } finally { await parent.close(); }
}
const saveJson = (path, data) => atomic(path, JSON.stringify(data, null, 2) + '\n');
async function privateDir(dir) {
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const stat = await lstat(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail('unsafe_output_directory');
}
export async function createPlan({ client, input, output, maxUSD }) {
  const cap = money(maxUSD), dir = resolve(output);
  await privateDir(dir);
  const lock = await open(join(dir, '.lock'), 'wx', 0o600).catch(() => fail('output_locked'));
  try {
    await lock.writeFile(String(process.pid));
    if (await readJson(join(dir, 'state.json'))) fail('output_exists_resume_original');
    const prepared = await client.prepare(input);
    if (money(prepared.estimate.maximum_charge_usd) > cap) fail('budget_exceeded');
    const state = { version: 1, createdAt: new Date().toISOString(), ...prepared, maxUSD, idempotencyKey: `castreader-${randomUUID()}`, status: 'planned', job: null };
    state.bodyHash = hash(JSON.stringify(state.body));
    await saveJson(join(dir, 'state.json'), state);
    return { status: 'planned', output: dir, voiceName: state.voiceName, region: state.base.includes('.cn/') ? 'cn' : 'us', characters: [...state.body.text].length, estimate: state.estimate, maxUSD, generated: false };
  } finally { await lock.close(); await unlink(join(dir, '.lock')); }
}
export async function runPlan({ client, output, waitMs = 45000, sleepImpl = sleep }) {
  if (!Number.isFinite(waitMs) || waitMs < 0 || waitMs > 660000) fail('invalid_wait');
  const dir = resolve(output); await privateDir(dir);
  const lock = await open(join(dir, '.lock'), 'wx', 0o600).catch(() => fail('output_locked'));
  try {
    await lock.writeFile(String(process.pid));
    const statePath = join(dir, 'state.json'), state = await readJson(statePath);
    if (!state || state.version !== 1 || !BASES.has(state.base) || hash(JSON.stringify(state.body)) !== state.bodyHash || !/^castreader-[a-f0-9-]{36}$/.test(state.idempotencyKey)) fail('invalid_checkpoint');
    inputBody(state.body); const cap = money(state.maxUSD);
    const audioPath = join(dir, `audio.${state.body.output_format}`);
    if (state.sha256) {
      try { if (hash(await readFile(audioPath)) === state.sha256) return { ...state.receipt, path: audioPath, reused: true }; } catch (e) { if (e.code !== 'ENOENT') throw e; }
    }
    const checkpoint = () => saveJson(statePath, state);
    if (!state.job) {
      // Recheck an unsubmitted plan. An uncertain submission must reuse its saved body and key.
      if (state.status === 'planned') {
        const estimate = await client.json(state.base, '/usage/estimate', state.body);
        if (estimate.reservation_created !== false || estimate.balance_sufficient !== true) fail('insufficient_balance');
        if (money(estimate.maximum_charge_usd) > cap) fail('budget_exceeded');
        state.estimate = estimate; state.status = 'submission_unknown'; await checkpoint();
      }
      state.job = await client.json(state.base, '/jobs', state.body, state.idempotencyKey);
      if (!/^job_[a-f0-9]{32}$/.test(state.job?.id)) fail('invalid_job_response');
      state.status = state.job.status; await checkpoint();
    } else if (!/^job_[a-f0-9]{32}$/.test(state.job.id)) fail('invalid_checkpoint');
    const deadline = Date.now() + waitMs;
    while (!TERMINAL.has(state.job.status)) {
      let result;
      try { result = await client.request(state.base, `/jobs/${state.job.id}`); }
      catch (e) {
        if (e.httpStatus !== 429 && e.httpStatus !== 503) throw e;
        if (Date.now() + e.retryAfterMs > deadline) return { status: 'pending', output: dir, jobStatus: state.job.status, retryAfterMs: e.retryAfterMs, recover: 'resume' };
        await sleepImpl(e.retryAfterMs); continue;
      }
      if (result.data.id !== state.job.id) fail('job_identity_changed');
      state.job = result.data; state.status = state.job.status; await checkpoint();
      if (TERMINAL.has(state.job.status)) break;
      if (Date.now() + result.retryAfterMs > deadline) return { status: 'pending', output: dir, jobStatus: state.status, recover: 'resume' };
      await sleepImpl(result.retryAfterMs);
    }
    if (state.job.status !== 'succeeded') return { status: state.job.status, errorCode: state.job.errorCode, chargedUSD: /^\d+$/.test(state.job.chargedMicrousd) ? usd(state.job.chargedMicrousd) : null, output: dir, recover: 'Inspect the original job. No replacement was generated.' };
    const bytes = await client.request(state.base, `/jobs/${state.job.id}/audio`, undefined, undefined, true);
    await atomic(audioPath, bytes);
    if (!/^\d+$/.test(state.job.chargedMicrousd)) fail('invalid_charge_receipt');
    state.sha256 = hash(bytes);
    state.receipt = { status: 'succeeded', file: `audio.${state.body.output_format}`, bytes: bytes.length, sha256: state.sha256, chargedUSD: usd(state.job.chargedMicrousd), trialCharacters: state.job.trialCharacters, billableCharacters: state.job.billableCharacters, language: state.body.language, region: state.base.includes('.cn/') ? 'cn' : 'us', completedAt: state.job.completedAt };
    if (state.body.return_timestamps) {
      const timestamps = [];
      for (const chunk of state.job.chunks || []) if (/^req_[a-f0-9]{32}$/.test(chunk.requestId)) {
        try { timestamps.push({ requestId: chunk.requestId, alignment: await client.json(state.base, `/requests/${chunk.requestId}/timestamps`) }); }
        catch { timestamps.push({ requestId: chunk.requestId, alignment: { status: 'unavailable', reason: 'retrieval_failed' } }); }
      }
      await saveJson(join(dir, 'timestamps.json'), { segments: timestamps, note: 'Segment-relative seconds; alignment may be unavailable. Do not invent offsets.' });
    }
    await saveJson(join(dir, 'receipt.json'), state.receipt); await checkpoint();
    return { ...state.receipt, path: audioPath, reused: false };
  } finally { await lock.close(); await unlink(join(dir, '.lock')); }
}
export async function main(args = process.argv.slice(2)) {
  const [command, ...rest] = args, options = {};
  if (!command || command === 'help' || command === '--help') return { usage: ['capabilities', 'voices', 'plan --input input.json --output ./audio-run --max-usd 0.01', 'run --output ./audio-run [--wait-ms 45000]', 'resume --output ./audio-run [--wait-ms 45000]'], key: 'CASTREADER_API_KEY environment only. run/resume may use the API wallet; planning never generates.', limits: 'One clip per plan, up to 500 normalized characters. Keep state.json private and intact.' };
  if (command === 'capabilities') { const res = await fetch(`${ORIGIN}/integration-manifest.json`, { redirect: 'error', signal: AbortSignal.timeout(20000) }); if (!res.ok) fail('capabilities_unavailable'); return JSON.parse((await bounded(res,1048576)).toString()); }
  for (let i=0;i<rest.length;i+=2) { if (!['--input','--output','--max-usd','--wait-ms'].includes(rest[i]) || !rest[i+1] || options[rest[i]]) fail('invalid_arguments'); options[rest[i]] = rest[i+1]; }
  const client = new Client();
  if (command === 'voices') { const base = await client.route(); return { region: base.includes('.cn/') ? 'cn' : 'us', voices: (await client.voices(base)).filter(v=>v.status === 'ready').map(v=>({id:v.id,name:v.name,status:v.status,default:v.default_voice_key})), generated: false }; }
  if (!options['--output']) fail('output_required');
  if (command === 'plan') { if (!options['--input'] || !options['--max-usd']) fail('input_and_budget_required'); return createPlan({ client, input: JSON.parse(await readFile(resolve(options['--input']), 'utf8')), output: options['--output'], maxUSD: options['--max-usd'] }); }
  if (command === 'run' || command === 'resume') return runPlan({ client, output: options['--output'], waitMs: Number(options['--wait-ms'] || 45000) });
  fail('unknown_command');
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().then(result => { console.log(JSON.stringify(result,null,2)); if (['failed','cancelled','expired'].includes(result.status)) process.exitCode=1; }).catch(error => { console.error(JSON.stringify({ error: /^[a-z0-9_]{1,70}$/.test(error.code || '') ? error.code : 'operation_stopped', retryAfterMs: error.retryAfterMs, action: 'Keep the output folder. Resume the original plan; do not create a replacement for an uncertain request. Never paste an API key into chat.' })); process.exitCode=1; });
}
