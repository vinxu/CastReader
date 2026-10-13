import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const repo = '/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-tts-ip-recovery-20261012';
const evidence = '/Users/xuxuheng/Documents/CastReader/reports/tts-ip-change-20261012';
const require = createRequire(`${repo}/package.json`);
const { parse } = require('dotenv');
const env = parse(readFileSync('/Users/xuxuheng/Documents/MyProject/readout-web/.env.local'));
process.env.DATABASE_URL = env.DATABASE_URL;
process.env.DB_SINGLETON_ENABLED = 'true';
process.env.CASTREADER_SERVICE_ROUTE = 'global';
process.env.TTS_UPSTREAM_URL = 'http://71.175.237.66:41209/dev/captioned_speech';
const { getTTSUpstreamRoutingState, updateTTSUpstreamRoutingState } = require(`${repo}/src/shared/ops/tts-upstream-routing-store.ts`);
const { closeDb } = require(`${repo}/src/core/db/index.ts`);

try {
  const capabilities = await fetch('https://api.castreader.ai/api/capabilities', {
    signal: AbortSignal.timeout(15000),
  }).then(response => response.json());
  assert.equal(capabilities.commitSha, '227b932f3d402a15924e00b566bf69206f708296');
  assert.equal(capabilities.releaseId, 'dpl_6E5r9yeq9oGLYYUC6RSYGWJTySyF');
  const before = JSON.parse(JSON.parse(readFileSync(`${evidence}/routing-before.json`, 'utf8'))[0].value);
  const current = await getTTSUpstreamRoutingState();
  assert.deepEqual(current, before, 'persisted route changed since incident baseline');
  const target = { ...current.current, url: process.env.TTS_UPSTREAM_URL };
  // Reuse the production transaction, revision CAS and append-only audit writer.
  const after = await updateTTSUpstreamRoutingState({
    action: 'switch', expectedRevision: 2,
    incidentId: 'incident-20261012-public-ip-change', target,
  });
  assert.equal(after.revision, 3);
  assert.deepEqual(await getTTSUpstreamRoutingState(), after);
  const receipt = { verified: true, releaseSha: capabilities.commitSha, before, after,
    method: 'production updateTTSUpstreamRoutingState with advisory lock, expectedRevision=2 and append-only audit' };
  writeFileSync(`${evidence}/routing-after.json`, JSON.stringify(receipt, null, 2));
  console.log(JSON.stringify({ verified: true, revision: after.revision, target: after.current.url }));
} finally {
  await closeDb();
}
