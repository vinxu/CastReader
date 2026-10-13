/** Offline UI verification only. All audio is a locally generated tone, never speech. */
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer } from '../server.mjs';

const audio = await readFile(new URL('fixtures/test-tone.mp3', import.meta.url));
const voiceId = 'voice_' + 'a'.repeat(32), jobs = new Map();
let submissions = 0;
const client = {
  async models() { return { data: [{ id: 'clone-v1', languages: ['en', 'zh'], max_characters: 120 }] }; },
  async capabilities() { return { maxCharacters: 500 }; },
  async voices() { return { data: [{ id: voiceId, name: 'OFFLINE TEST TONE — not speech', status: 'ready', default_voice_key: 'narrator' }] }; },
  async request(path, { body }) {
    if (path !== '/usage/estimate') throw new Error('Unexpected test operation');
    const n = Array.from(body.text).length;
    return { response: new Response(JSON.stringify({ billable_characters: n, trial_characters: n, maximum_charge_usd: (n * 8 / 1000000).toFixed(6), estimated_charge_usd: '0.000000', reservation_created: false, balance_sufficient: true })) };
  },
  async createJob(body, { idempotencyKey }) {
    submissions++;
    if (!jobs.has(idempotencyKey)) jobs.set(idempotencyKey, { id: `offline-${jobs.size}`, status: 'succeeded', chargedMicrousd: '0', billableCharacters: Array.from(body.text).length, trialCharacters: Array.from(body.text).length });
    console.log(`Offline submissions: ${submissions}; logical jobs: ${jobs.size}`);
    return jobs.get(idempotencyKey);
  },
  async getJob(id) { return [...jobs.values()].find(job => job.id === id); },
  async getJobAudio() { return { audio }; },
};
const dataDir = await mkdtemp(join(tmpdir(), 'voice-studio-offline-ui-'));
const app = await startServer({ port: 8792, dataDir, client });
console.log(`OFFLINE TEST ONLY — generated test tone, no live synthesis: ${app.origin}`);
console.log(`Temporary test data: ${dataDir}`);
let closing = false;
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
  if (!closing) { closing = true; await app.close(); }
});
