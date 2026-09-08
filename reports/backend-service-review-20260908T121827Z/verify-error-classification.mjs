// Offline reproduction against source files whose hashes match production.
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
const provider = '/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-quickread-cancellation-recovery-20260905/scripts/video-pipeline/tools/llm-provider.mjs';
const probe = '/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-service-isolation-20260905/scripts/core-audio-monitor/probe-core.mjs';
const files = [
  [provider, '7c0370aff30427bf5d85f47595c7b14c1a2dd1aff486c970f877a7926098e9d2'],
  [probe, '51c38ca9c4a9c4b5c4f0af9dbe78510e90809eb39574f6f1ff9cff7c7e5ee964'],
];
for (const [path, expected] of files) {
  assert.equal(createHash('sha256').update(await readFile(path)).digest('hex'), expected);
}
globalThis.fetch = async () => { throw new Error('Unexpected outbound request forbidden in offline test'); };
const { deepSeekMessage } = await import(pathToFileURL(provider));
const { runContinuityProbe } = await import(pathToFileURL(probe));
const results = [];
for (const exception of [new SyntaxError('fixture'), new TypeError('fixture'), new DOMException('fixture', 'AbortError')]) {
  let calls = 0;
  await assert.rejects(() => deepSeekMessage('local fixture', {
    env: { DEEPSEEK_API_KEY: 'offline-placeholder' },
    fetchImpl: async () => { calls++; return { ok: true, json: async () => { throw exception; } }; },
  }), { message: 'DeepSeek (deepseek-v4-pro) returned an invalid JSON envelope' });
  assert.equal(calls, 1);
  results.push({ component: 'DeepSeek response.json', injectedError: exception.name, observedCode: 'invalid JSON envelope', fetchAttempts: calls });
}
for (const exception of [new TypeError('fixture'), new DOMException('fixture', 'AbortError')]) {
  let calls = 0;
  const result = await runContinuityProbe({
    region: 'cn', retryDelayMs: 0,
    fetchImpl: async () => { calls++; return {
      ok: true, headers: new Headers({ 'content-type': 'application/json', 'x-castreader-upstream-region': 'cn' }),
      arrayBuffer: async () => { throw exception; },
    }; },
    decodeAudio: async () => { throw new Error('Decoder must not be called'); },
  });
  assert.equal(result.failureCode, 'unexpected_monitor_error');
  assert.equal(result.status, 'monitor_error');
  assert.equal(result.supplyOk, false);
  assert.equal(calls, 2);
  results.push({ component: 'Monitor response.arrayBuffer', injectedError: exception.name, observedCode: result.failureCode, status: result.status, fetchAttempts: calls });
}
const out = { productionModified: false, outboundRequests: 0, passed: results.length, sourceHashesVerified: files.map(([path, sha256]) => ({ path, sha256 })), results, limitation: 'Shows classification ambiguity in exact production source; does not establish the original exceptions for historical requests.' };
await writeFile(new URL('./offline-error-classification.json', import.meta.url), JSON.stringify(out, null, 2) + '\n', { flag: 'wx' });
console.log(JSON.stringify(out));
