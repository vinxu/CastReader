import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
let source = fs.readFileSync(new URL('../../CastReader/WebAssets/KindleOCR/ocr.js', import.meta.url), 'utf8');
source = source.replace(/import\s+[\s\S]*?from\s+'[^']+';\n/g, '');
const engines = [];
let failingFetch = false, failingModel = false;
const context = vm.createContext({ window: {}, supportsFastBuild: () => true,
  fetch: async url => ({ ok: !failingFetch || !url.endsWith('.traineddata'), status: failingFetch ? 503 : 200,
    arrayBuffer: async () => new ArrayBuffer(4) }),
  createOCREngine: async () => {
    const engine = { destroyed: false, loadModel() { if (failingModel) throw new Error('bad model'); },
      setVariable() {}, destroy() { this.destroyed = true; } };
    engines.push(engine); return engine;
  },
});
vm.runInContext(source + '\nwindow.testEngine = getEngine;', context);
const first = await context.window.testEngine('eng');
failingFetch = true;
await assert.rejects(context.window.testEngine('fra'), /unavailable/);
assert.equal(first.destroyed, false); assert.equal(engines.length, 1);
failingFetch = false; failingModel = true;
await assert.rejects(context.window.testEngine('fra'), /bad model/);
assert.equal(first.destroyed, false); assert.equal(engines[1].destroyed, true);
assert.equal(await context.window.testEngine('eng'), first);
failingModel = false;
const next = await context.window.testEngine('fra');
assert.equal(first.destroyed, true); assert.equal(next.destroyed, false);
console.log('PASS: failed download/model swap preserves working OCR engine, destroys failed new engine, recovers on retry');
