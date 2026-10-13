import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readdir, readFile, writeFile, rm, lstat, symlink } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
// The same suite runs in the monorepo and at tests/ in the extracted starter.
const source = new URL(existsSync(new URL('../public/examples/flashcards/generate.mjs', import.meta.url)) ? '../public/examples/flashcards/' : '../', import.meta.url);
const { runCards, validateCards } = await import(new URL('generate.mjs', source));
const { startServer } = await import(new URL('server.mjs', source));

const voiceId = 'voice_' + 'a'.repeat(32);
const cards = [{ id: 'one-en', language: 'en', text: 'Hello.' }];
function fake() {
  const requests = [];
  const jobs = new Map();
  const client = {
    async createJob(body, options) {
      requests.push(options.idempotencyKey);
      if (!jobs.has(options.idempotencyKey)) jobs.set(options.idempotencyKey, { id: 'job-' + jobs.size, status: 'succeeded' });
      return jobs.get(options.idempotencyKey);
    },
    async getJob(id) { return [...jobs.values()].find(job => job.id === id); },
    async getJobAudio() { return { audio: Buffer.from('fixture-audio-not-for-publication'), chargedUSD: '0.000048', billableCharacters: 6, trialCharacters: 0 }; },
  };
  return { client, requests, jobs };
}
async function directory(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'voice-cards-test-'));
  try { await fn(dir); } finally { await rm(dir, { recursive: true, force: true }); }
}
test('validate whole input before work; preserve exact language and NFC metering', () => {
  assert.equal(validateCards([{ id: 'nfc-en', language: 'en', text: ' e\u0301\r\nHi ' }])[0].text, 'é\nHi');
  for (const value of [[], [...cards, ...cards], [{ ...cards[0], id: '../escape' }], [{ ...cards[0], language: 'xx' }], [{ ...cards[0], text: '\ud800' }], [{ ...cards[0], text: 'a'.repeat(501) }]]) assert.throws(() => validateCards(value));
});
test('completed rerun uses local checksum and makes no further API requests', () => directory(async output => {
  const { client, requests } = fake();
  const args = { client, cards, output, voiceId, log() {} };
  const result = await runCards(args);
  assert.equal(result.rows.length, 1);
  const original = await readFile(join(output, 'one-en.mp3'));
  client.getJob = client.getJobAudio = async () => { throw new Error('No API access permitted'); };
  await runCards(args);
  assert.equal(requests.length, 1);
  assert.deepEqual(await readFile(join(output, 'one-en.mp3')), original);
}));
test('unknown POST result persists and retries the same key, not a replacement job', () => directory(async output => {
  const { client, requests, jobs } = fake();
  const original = client.createJob;
  let first = true;
  client.createJob = async (...args) => { const result = await original(...args); if (first) { first = false; throw new Error('network lost after acceptance'); } return result; };
  const args = { client, cards, output, voiceId, log() {} };
  await assert.rejects(runCards(args), /network lost/);
  await runCards(args);
  assert.equal(requests.length, 2);
  assert.equal(requests[0], requests[1]);
  assert.equal(jobs.size, 1);
}));
test('download interruption and corrupt local files recover through the original job', () => directory(async output => {
  const { client, requests } = fake();
  const download = client.getJobAudio;
  client.getJobAudio = async () => { throw new Error('download interrupted'); };
  const args = { client, cards, output, voiceId, log() {} };
  await assert.rejects(runCards(args), /download interrupted/);
  client.getJobAudio = download;
  await runCards(args);
  await writeFile(join(output, 'one-en.mp3'), 'corrupt');
  await runCards(args);
  assert.equal(requests.length, 1);
}));
test('changed input fails closed; existing manifest and output are preserved', () => directory(async output => {
  const { client, requests } = fake();
  const args = { client, cards, output, voiceId, log() {} };
  await runCards(args);
  const original = await readFile(join(output, 'manifest.json'));
  await assert.rejects(runCards({ ...args, cards: [{ ...cards[0], text: 'Different text.' }] }), /Inputs or voice changed/);
  assert.deepEqual(await readFile(join(output, 'manifest.json')), original);
  assert.equal(requests.length, 1);
}));
test('failed job is never automatically replaced', () => directory(async output => {
  const { client, requests } = fake();
  const create = client.createJob;
  client.createJob = async (...args) => Object.assign(await create(...args), { status: 'failed', errorCode: 'worker_unavailable' });
  const args = { client, cards, output, voiceId, log() {} };
  await assert.rejects(runCards(args), /worker_unavailable/);
  await assert.rejects(runCards(args), /worker_unavailable/);
  assert.equal(requests.length, 1);
}));
test('concurrent invocation refuses a locked folder', () => directory(async output => {
  await writeFile(join(output, '.running'), 'existing process');
  await assert.rejects(runCards({ client: fake().client, cards, output, voiceId }), /locked/);
  assert.equal(await readFile(join(output, '.running'), 'utf8'), 'existing process');
}));

function webFake() {
  const fixture = fake();
  const calls = [];
  for (const key of ['createJob', 'getJob', 'getJobAudio']) {
    const original = fixture.client[key];
    fixture.client[key] = (...args) => { calls.push(key); return original(...args); };
  }
  Object.assign(fixture.client, {
    async models() { calls.push('models'); return { data: [{ id: 'clone-v1', languages: ['en', 'zh'], max_characters: 500 }] }; },
    async voices() { calls.push('voices'); return { data: [{ id: voiceId, name: 'Authorized fixture', status: 'ready', default_voice_key: 'narrator', secret: 'do-not-return' }, { id: 'voice_' + 'b'.repeat(32), status: 'pending' }] }; },
    async request(path, options) {
      calls.push(path);
      assert.equal(path, '/usage/estimate');
      assert.equal(options.method, 'POST'); assert.equal(options.retry, false);
      const n = Array.from(options.body.text).length;
      return { response: { async json() { return { billable_characters: n, trial_characters: n, maximum_charge_usd: (n * 8 / 1000000).toFixed(6), estimated_charge_usd: '0.000000', reservation_created: false, balance_sufficient: true }; } } };
    },
  });
  return { ...fixture, calls };
}
async function browser(app) {
  const response = await fetch(app.origin + '/api/session', { headers: { Origin: app.origin } });
  assert.equal(response.status, 200);
  const session = await response.json();
  return { session, async request(path, { body, headers = {}, raw, method = body || raw ? 'POST' : 'GET' } = {}) {
    return fetch(app.origin + path, { method, headers: { Origin: app.origin, 'X-CSRF-Token': session.csrfToken, ...(body || raw ? { 'Content-Type': 'application/json' } : {}), ...headers }, ...(body || raw ? { body: raw || JSON.stringify(body) } : {}) });
  } };
}
async function local(fn, fixture = webFake()) {
  return directory(async dataDir => {
    const app = await startServer({ port: 0, dataDir, client: fixture.client, waitMs: 1, timeoutMs: 10 });
    try { await fn({ app, dataDir, fixture, ...await browser(app) }); }
    finally { await app.close(); }
  });
}
async function plan(request, input = {}) {
  const response = await request('/api/batches', { body: { cards, voiceId, title: 'Offline batch', ...input } });
  assert.equal(response.status, 201, await response.clone().text());
  return response.json();
}
async function settled(request, id) {
  for (let i = 0; i < 200; i++) {
    const response = await request(`/api/batches/${id}`);
    assert.equal(response.status, 200);
    const value = await response.json();
    if (value.status !== 'running') return value;
    await new Promise(done => setTimeout(done, 5));
  }
  assert.fail('Local fake batch did not settle.');
}
async function start(request, id) {
  const response = await request(`/api/batches/${id}/start`, { body: { confirm: true } });
  assert.equal(response.status, 202, await response.clone().text());
}
test('local app binds loopback; exact Host, Origin and CSRF guard every API mutation', () => local(async ({ app, request, session, fixture }) => {
  assert.equal(app.server.address().address, '127.0.0.1');
  const page = await fetch(app.origin);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal(page.headers.get('cache-control'), 'no-store');
  assert.equal((await fetch(app.origin + '/api/session')).status, 403);
  for (const headers of [{ Host: 'evil.example' }, { Host: `localhost:${app.server.address().port}` }, { Origin: 'null' }, { Origin: 'https://evil.example' }, { 'X-CSRF-Token': '' }, { 'Sec-Fetch-Site': 'same-site' }, { 'X-Forwarded-Host': 'evil.example' }]) {
    const status = await new Promise((done, reject) => {
      const req = httpRequest(app.origin + '/api/batches', { method: 'POST', headers: { Origin: app.origin, 'X-CSRF-Token': session.csrfToken, 'Content-Type': 'application/json', ...headers } }, res => { res.resume(); done(res.statusCode); });
      req.on('error', reject); req.end(JSON.stringify({ cards, voiceId, title: 'Blocked' }));
    });
    assert.equal(status, 403, JSON.stringify(headers));
  }
  const noOrigin = await fetch(app.origin + '/api/batches', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': (await browser(app)).session.csrfToken }, body: '{}' });
  assert.equal(noOrigin.status, 403);
  assert.equal((await request('/api/batches', { method: 'OPTIONS' })).status, 404);
  assert.deepEqual(fixture.calls, []);
}));
test('only allowlisted UI and batch resources can be read; no paths or URLs are accepted', () => local(async ({ app, request, session, fixture }) => {
  for (const path of ['/server.mjs', '/.env', '/state.json', '/api/batches/../../state.json', '/api/batches?path=/etc/passwd', '/api/proxy?url=https://evil.example']) {
    // Raw HTTP avoids fetch's dot-segment normalization.
    const status = await new Promise((done, reject) => {
      const req = httpRequest(app.origin, { path, headers: { Origin: app.origin, 'X-CSRF-Token': session.csrfToken } }, res => { res.resume(); done(res.statusCode); });
      req.on('error', reject); req.end();
    });
    assert.equal(status, 404);
  }
  for (const extra of [{ apiKey: 'secret' }, { output: '/tmp/escape' }, { baseURL: 'https://evil.example' }, { path: '../escape' }]) assert.equal((await request('/api/batches', { body: { cards, voiceId, title: 'Unsafe', ...extra } })).status, 400);
  assert.deepEqual(fixture.calls, []);
}));
test('validate complete input and request size before API access, cap 500 code points', () => local(async ({ request, fixture }) => {
  for (const invalid of [[], Array.from({ length: 201 }, (_, n) => ({ ...cards[0], id: `card-${n}` })), [...cards, ...cards], [{ ...cards[0], id: 'constructor' }], [{ ...cards[0], id: '../escape' }], [{ ...cards[0], language: 'xx' }], [{ ...cards[0], text: '\ud800' }], [{ ...cards[0], text: 'a'.repeat(501) }], [{ ...cards[0], voiceId }]]) {
    assert.equal((await request('/api/batches', { body: { cards: invalid, voiceId, title: 'Invalid' } })).status, 400);
  }
  assert.equal((await request('/api/batches', { raw: '{broken' })).status, 400);
  assert.equal((await request('/api/batches', { raw: JSON.stringify({ text: 'x'.repeat(530000) }) })).status, 413);
  assert.equal((await request('/api/batches', { body: {}, headers: { 'Content-Type': 'text/plain' } })).status, 415);
  assert.deepEqual(fixture.calls, []);
  const value = await plan(request, { cards: [{ ...cards[0], text: '😀'.repeat(500) }] });
  assert.equal(value.estimate.characters, 500);
}));
test('backend-only ready voice discovery; plans aggregate maximum cost without double counting trial', () => local(async ({ request, fixture }) => {
  const catalog = await (await request('/api/catalog')).json();
  assert.equal(catalog.voices.length, 1);
  assert.equal(JSON.stringify(catalog).includes('do-not-return'), false);
  assert.equal((await request('/api/batches', { body: { cards, voiceId: 'voice_' + 'b'.repeat(32), title: 'Not ready' } })).status, 400);
  const value = await plan(request, { cards: [...cards, { id: 'two-zh', language: 'zh', text: '你好。' }] });
  assert.equal(value.estimate.maximumChargeUSD, '0.000072');
  assert.equal(value.status, 'planned'); assert.equal(fixture.requests.length, 0);
  assert.equal(fixture.calls.filter(call => call === '/usage/estimate').length, 2);
  assert.equal((await request(`/api/batches/${value.id}/start`, { body: {} })).status, 400);
  assert.equal((await request(`/api/batches/${value.id}/start`, { body: { confirm: true, cards } })).status, 400);
  assert.equal(fixture.requests.length, 0);
}));
test('generate, progress, replay and exports; completed resume never submits or downloads again', () => local(async ({ request, fixture, dataDir }) => {
  const value = await plan(request);
  await start(request, value.id);
  const result = await settled(request, value.id);
  assert.equal(result.status, 'complete'); assert.equal(result.rows[0].saved, true);
  const before = fixture.calls.slice();
  const response = await request(`/api/batches/${value.id}/audio/one-en`);
  const audio = Buffer.from(await response.arrayBuffer());
  assert.equal(createHash('sha256').update(audio).digest('hex'), result.rows[0].sha256);
  const manifest = await (await request(`/api/batches/${value.id}/manifest`)).json();
  assert.equal(manifest.rows[0].text, cards[0].text);
  for (const privateValue of ['jobId', 'idempotencyKey', voiceId]) assert.equal(JSON.stringify(manifest).includes(privateValue), false);
  const archive = await request(`/api/batches/${value.id}/archive`);
  const zipBytes = Buffer.from(await archive.arrayBuffer()), entries = new Map();
  let offset = 0;
  while (zipBytes.readUInt32LE(offset) === 0x04034b50) {
    assert.equal(zipBytes.readUInt16LE(offset + 8), 0, 'portable ZIP uses store format');
    const size = zipBytes.readUInt32LE(offset + 18), nameLength = zipBytes.readUInt16LE(offset + 26), extraLength = zipBytes.readUInt16LE(offset + 28);
    const name = zipBytes.subarray(offset + 30, offset + 30 + nameLength).toString();
    offset += 30 + nameLength + extraLength;
    entries.set(name, zipBytes.subarray(offset, offset + size)); offset += size;
  }
  assert.equal(zipBytes.readUInt32LE(offset), 0x02014b50);
  assert.deepEqual([...entries.keys()], ['manifest.json', 'one-en.mp3']);
  assert.deepEqual(entries.get('one-en.mp3'), audio);
  assert.deepEqual(JSON.parse(entries.get('manifest.json')), manifest);
  assert.deepEqual(fixture.calls, before);
  await start(request, value.id); await settled(request, value.id);
  assert.deepEqual(fixture.calls, before);
  assert.equal((await lstat(join(dataDir, 'batches', value.id, 'batch.json'))).mode & 0o777, 0o600);
}));
test('unknown submission resumes the same key after server restart; errors never reveal secrets', () => directory(async dataDir => {
  const fixture = webFake(), create = fixture.client.createJob;
  fixture.client.createJob = async (...args) => { await create(...args); throw new Error('secret-key-value PRIVATE upstream payload'); };
  let app = await startServer({ port: 0, dataDir, client: fixture.client, waitMs: 1 });
  let api = await browser(app), value;
  try {
    value = await plan(api.request); await start(api.request, value.id);
    const paused = await settled(api.request, value.id);
    assert.equal(paused.status, 'paused'); assert.equal(paused.rows[0].status, 'submission_unknown');
    assert.equal(JSON.stringify(paused).includes('secret-key-value'), false);
    assert.equal((await readFile(join(dataDir, 'batches', value.id, 'execution.json'), 'utf8')).includes('secret-key-value'), false);
  } finally { await app.close(); }
  fixture.client.createJob = create;
  app = await startServer({ port: 0, dataDir, client: fixture.client, waitMs: 1 });
  try {
    const next = await browser(app);
    assert.notEqual(next.session.csrfToken, api.session.csrfToken);
    assert.equal((await (await next.request('/api/batches')).json()).batches[0].id, value.id);
    await start(next.request, value.id); assert.equal((await settled(next.request, value.id)).status, 'complete');
    assert.equal(fixture.requests[0], fixture.requests[1]); assert.equal(fixture.jobs.size, 1);
  } finally { await app.close(); }
}));
test('progress and duplicate starts are serialized, timeout resumes the original queued job', () => local(async ({ request, fixture }) => {
  const create = fixture.client.createJob;
  fixture.client.createJob = async (...args) => Object.assign(await create(...args), { status: 'queued' });
  const first = await plan(request), second = await plan(request);
  const responses = await Promise.all([first.id, first.id, second.id].map(id => request(`/api/batches/${id}/start`, { body: { confirm: true } })));
  assert.deepEqual(responses.map(res => res.status).sort(), [202, 409, 409]);
  const paused = await settled(request, first.id);
  assert.equal(paused.status, 'paused'); assert.equal(fixture.requests.length, 1);
  for (const job of fixture.jobs.values()) job.status = 'succeeded';
  await start(request, first.id); assert.equal((await settled(request, first.id)).status, 'complete');
  assert.equal(fixture.requests.length, 1);
}));
test('download-only routes fail closed on corruption or symlinks; resume recovers original audio', () => local(async ({ request, fixture, dataDir }) => {
  const value = await plan(request); await start(request, value.id); await settled(request, value.id);
  const output = join(dataDir, 'batches', value.id, 'one-en.mp3');
  await writeFile(output, 'corrupt');
  const before = fixture.calls.slice();
  assert.equal((await request(`/api/batches/${value.id}/audio/one-en`)).status, 409);
  assert.equal((await request(`/api/batches/${value.id}/archive`)).status, 409);
  assert.deepEqual(fixture.calls, before);
  await start(request, value.id); assert.equal((await settled(request, value.id)).status, 'complete');
  assert.equal(fixture.requests.length, 1);
  await rm(output); await symlink(join(dataDir, 'batches', value.id, 'state.json'), output);
  assert.equal((await request(`/api/batches/${value.id}/audio/one-en`)).status, 409);
}));
test('terminal failed jobs, batch locks, missing checkpoints and app locks are preserved', () => local(async ({ request, fixture, dataDir }) => {
  await assert.rejects(startServer({ port: 0, dataDir, client: fixture.client }), /Another app/);
  const create = fixture.client.createJob;
  fixture.client.createJob = async (...args) => Object.assign(await create(...args), { status: 'failed', errorCode: 'worker_unavailable' });
  const value = await plan(request); await start(request, value.id); await settled(request, value.id);
  await start(request, value.id); const result = await settled(request, value.id);
  assert.equal(result.rows[0].status, 'failed'); assert.equal(fixture.requests.length, 1);
  const dir = join(dataDir, 'batches', value.id);
  await writeFile(join(dir, '.running'), 'do-not-delete');
  assert.equal((await request(`/api/batches/${value.id}/start`, { body: { confirm: true } })).status, 409);
  assert.equal(await readFile(join(dir, '.running'), 'utf8'), 'do-not-delete');
  await rm(join(dir, '.running')); await rm(join(dir, 'state.json'));
  assert.equal((await request(`/api/batches/${value.id}/start`, { body: { confirm: true } })).status, 409);
  assert.equal(fixture.requests.length, 1);
}));
test('history isolates incomplete, malformed and linked batches, preserves them and reveals only a count', () => local(async ({ request, dataDir, fixture }) => {
  const good = await plan(request);
  await start(request, good.id); await settled(request, good.id);
  const root = join(dataDir, 'batches');
  const [emptyId, malformedId, metadataId, linkedId] = Array.from({ length: 4 }, () => randomUUID());
  for (const id of [emptyId, malformedId, metadataId]) await mkdir(join(root, id));
  const secret = 'PRIVATE-RECOVERY-DATA-MUST-NOT-LEAK';
  await writeFile(join(root, emptyId, 'state.json'), secret);
  const malformed = `{invalid-json ${secret}`;
  await writeFile(join(root, malformedId, 'batch.json'), malformed);
  const metadata = JSON.stringify({ id: metadataId, title: secret, createdAt: null });
  await writeFile(join(root, metadataId, 'batch.json'), metadata);
  await symlink(join(root, good.id), join(root, linkedId));
  const calls = fixture.calls.slice();
  const response = await request('/api/batches');
  assert.equal(response.status, 200);
  const listing = await response.json();
  assert.deepEqual(Object.keys(listing).sort(), ['batches', 'skippedBatchCount']);
  assert.equal(listing.skippedBatchCount, 4);
  assert.deepEqual(listing.batches, [{ id: good.id, title: good.title, createdAt: good.createdAt }]);
  const serialized = JSON.stringify(listing);
  for (const privateValue of [secret, dataDir, emptyId, malformedId, metadataId, linkedId]) assert.equal(serialized.includes(privateValue), false);
  assert.equal((await (await request(`/api/batches/${good.id}`)).json()).status, 'complete');
  assert.equal((await request(`/api/batches/${good.id}/audio/one-en`)).status, 200);
  assert.deepEqual(fixture.calls, calls, 'history and existing audio stay local');
  assert.deepEqual((await readdir(root)).sort(), [good.id, emptyId, malformedId, metadataId, linkedId].sort());
  assert.equal(await readFile(join(root, emptyId, 'state.json'), 'utf8'), secret);
  assert.equal(await readFile(join(root, malformedId, 'batch.json'), 'utf8'), malformed);
  assert.equal(await readFile(join(root, metadataId, 'batch.json'), 'utf8'), metadata);
  assert.equal((await lstat(join(root, linkedId))).isSymbolicLink(), true);
}));
test('queued limit uses manifest even when synchronous model limit is 120', () => {
  const fixture = webFake();
  fixture.client.models = async () => ({ data: [{ id: 'clone-v1', languages: ['en'], max_characters: 120 }] });
  fixture.client.capabilities = async () => ({ maxCharacters: 500 });
  return local(async ({ request }) => {
    const catalog = await (await request('/api/catalog')).json();
    assert.equal(catalog.maxCharacters, 500);
    const value = await plan(request, { cards: [{ ...cards[0], text: 'a'.repeat(500) }] });
    assert.equal(value.estimate.characters, 500);
    assert.equal(value.estimate.rows[0].trialCharacters, 500);
  }, fixture);
});

test('request body and region survive an uncertain submission and a routing change', () => directory(async output => {
  const fixture = fake(), create = fixture.client.createJob;
  const pinned = [], originalBase = 'https://voice.castreader.cn/v1';
  fixture.client.baseURL = originalBase;
  fixture.client.forRegion = base => { pinned.push(base); return fixture.client; };
  let first = true;
  fixture.client.createJob = async (body, options) => {
    const state = JSON.parse(await readFile(join(output, 'state.json'), 'utf8'));
    assert.deepEqual(state.rows['one-en'].body, body);
    assert.equal(state.rows['one-en'].idempotencyKey, options.idempotencyKey);
    assert.equal(state.baseURL, originalBase);
    const result = await create(body, options);
    if (first) { first = false; throw new Error('accepted, response lost'); }
    return result;
  };
  const args = { client: fixture.client, cards, output, voiceId, log() {} };
  await assert.rejects(runCards(args), /response lost/);
  fixture.client.baseURL = 'https://voice.castreader.com/v1';
  await runCards(args);
  assert.deepEqual(pinned, [originalBase, originalBase]);
  assert.equal(fixture.jobs.size, 1);
}));

test('failed jobs retain partial charge receipts and show a specific recovery error', () => {
  const fixture = webFake(), create = fixture.client.createJob;
  fixture.client.createJob = async (...args) => Object.assign(await create(...args), {
    status: 'failed', chargedMicrousd: '24', trialCharacters: 0, billableCharacters: 3,
  });
  return local(async ({ request }) => {
    const value = await plan(request);
    await start(request, value.id);
    const result = await settled(request, value.id);
    assert.equal(result.error.code, 'job_failed');
    assert.equal(result.rows[0].chargedUSD, '0.000024');
    assert.equal(result.rows[0].trialCharacters, 0);
    assert.equal(result.rows[0].saved, false);
  }, fixture);
});

test('price increases after approval stop before the first paid job', () => local(async ({ request, fixture }) => {
  const value = await plan(request);
  fixture.client.request = async () => ({ response: new Response(JSON.stringify({ maximum_charge_usd: '1.000000', balance_sufficient: true, reservation_created: false })) });
  await start(request, value.id);
  const result = await settled(request, value.id);
  assert.equal(result.error.code, 'estimate_changed');
  assert.equal(fixture.requests.length, 0);
}));

test('starter source hashes match its exact files when running from the extracted ZIP', async () => {
  const path = new URL('source-checksums.json', source);
  if (!existsSync(path)) return;
  const hashes = JSON.parse(await readFile(path, 'utf8'));
  for (const [name, expected] of Object.entries(hashes)) assert.equal(createHash('sha256').update(await readFile(new URL(name, source))).digest('hex'), expected, name);
  for (const required of ['server.mjs', 'ui/index.html', 'ui/app.js', 'ui/style.css', 'tests/flashcards-example.test.mjs']) assert.ok(hashes[required]);
});
