// Execute the shipped extension service with an offline transport. No account,
// browser profile or production request is used. Inputs contain real phone MP3s.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
const [sourceRoot, fixturePath, outputPath] = process.argv.slice(2).map(p => resolve(p));
const modules = join(sourceRoot, 'node_modules/.pnpm');
const esbuildDir = readdirSync(modules).find(n => n.startsWith('esbuild@'));
const require = createRequire(join(modules, esbuildDir, 'node_modules/esbuild/package.json'));
const { outputFiles } = await require('esbuild').build({
  stdin: { contents: `export { TTSService } from './src/core/tts-service';
    export { evaluateWordTimestampGranularity } from './src/shared/timestamp-quality';`,
    loader: 'ts', resolveDir: sourceRoot },
  tsconfig: join(sourceRoot, 'tsconfig.json'), bundle: true, write: false,
  format: 'esm', platform: 'node', target: 'node22',
  define: { __CASTREADER_IOS_SAFARI__: 'false', 'import.meta.env': '{}' },
  drop: ['console'], logLevel: 'silent',
});
const { TTSService, evaluateWordTimestampGranularity } = await import(
  `data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString('base64')}`);
globalThis.chrome = { runtime: { getURL: p => `chrome-extension://offline/${p}` },
  storage: { local: { get: async () => ({}), set: async () => {} } } };
globalThis.fetch = () => { throw new Error('Unexpected network request'); };
const output = [];
for (const row of JSON.parse(readFileSync(fixturePath, 'utf8'))) {
  let calls = 0;
  const transport = async () => { calls++; return Response.json(row.response); };
  const service = new TTSService('https://offline.invalid', transport);
  try {
    const result = await service._doGenerate('https://offline.invalid', {
      input: row.text, voice: row.response.voice_code, language: row.language,
      speed: 1, requestId: `alignment-${row.id}`,
    }, 1);
    assert.equal(result.audioUrl, `data:audio/mpeg;base64,${row.response.audio}`);
    const quality = evaluateWordTimestampGranularity(row.text, result.timestamps,
      result.duration, row.language, { clonedVoice: true });
    output.push({ id:row.id, accepted:true, timestamps:result.timestamps.length,
      wordQuality:quality.reliable, qualityReason:quality.reason, duration:result.duration, calls });
  } catch (error) {
    output.push({ id:row.id, accepted:false, errorType:error.errorType, message:error.message, calls });
  }
  assert.equal(calls, 1, 'No synthesis retry for the fixture');
}
writeFileSync(outputPath, JSON.stringify(output,null,2)+'\n');
console.log(`Extension actual service replay: ${output.length} cases`);
