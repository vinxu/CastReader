import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { RegionalVoiceAPI } from '../api-client.mjs';

const voice = 'voice_' + 'a'.repeat(32), jobId = 'job_' + 'b'.repeat(32);
const baseURL = 'https://voice.castreader.cn/v1';
test('official SDK uses the pinned region, pages voices, preserves headers, and downloads audio', async t => {
  const clip = await readFile(new URL('fixtures/test-tone.mp3', import.meta.url));
  const calls = [];
  t.mock.method(globalThis, 'fetch', async (url, options = {}) => {
    calls.push({ url: String(url), options });
    const json = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });
    if (String(url).includes('/route?voice_id=')) return json({ base_url: baseURL });
    if (String(url).endsWith('/integration-manifest.json')) return json({ capabilities: { service_enabled: true, new_work_admission_enabled: true, queued_jobs: true, max_characters_per_queued_job: 500 } });
    assert.ok(String(url).startsWith(baseURL));
    assert.equal(options.headers.Authorization, 'Bearer offline-test-key');
    assert.equal(options.redirect, 'error');
    if (String(url).endsWith('/voices?limit=100')) return json({ data: [], has_more: true, next_cursor: 'page-2' });
    if (String(url).endsWith('/voices?limit=100&cursor=page-2')) return json({ data: [{ id: voice, status: 'ready' }], has_more: false });
    if (String(url).endsWith('/jobs')) {
      assert.equal(options.headers['Idempotency-Key'], 'saved-operation-key');
      assert.equal(JSON.parse(options.body).language, 'zh');
      return json({ id: jobId, status: 'queued' });
    }
    if (String(url).endsWith('/audio')) return new Response(clip, { headers: { 'Content-Type': 'audio/mpeg', 'X-Charged-USD': '0.000000', 'X-Trial-Characters': '3', 'X-Billable-Characters': '3' } });
    if (String(url).endsWith(jobId)) return new Response(JSON.stringify({ id: jobId, status: 'succeeded' }), { headers: { 'Retry-After': '7' } });
    assert.fail('Unexpected upstream request');
  });
  const api = new RegionalVoiceAPI({ apiKey: 'offline-test-key', baseURL });
  assert.equal(api.maxRetries, 0);
  await api.verifyVoiceRegion(voice);
  assert.equal((await api.capabilities()).maxCharacters, 500);
  assert.equal((await api.voices()).data[0].id, voice);
  const job = await api.createJob({ voice_id: voice, text: '你好。', language: 'zh' }, { idempotencyKey: 'saved-operation-key' });
  assert.equal(job.id, jobId);
  assert.equal((await api.getJob(jobId)).retryAfterMs, 7000);
  assert.deepEqual((await api.getJobAudio(jobId)).audio, clip);
  assert.equal(calls.filter(call => call.options.method === 'POST').length, 1);
});

test('untrusted execution origins and non-audio downloads fail closed', async t => {
  assert.throws(() => new RegionalVoiceAPI({ apiKey: 'offline-test-key', baseURL: 'https://other.example/v1' }), /invalid_route/);
  t.mock.method(globalThis, 'fetch', async () => new Response('{}', { headers: { 'Content-Type': 'application/json' } }));
  const api = new RegionalVoiceAPI({ apiKey: 'offline-test-key', baseURL });
  await assert.rejects(api.getJobAudio(jobId), { code: 'invalid_audio' });
});
