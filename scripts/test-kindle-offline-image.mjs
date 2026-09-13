import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../CastReader/Services/KindleWebScripts.swift', import.meta.url), 'utf8');
const code = source.slice(source.indexOf('window.__crKindleOfflineImageIdentity ='), source.indexOf('window.__crKindleCurrentPageSnapshot ='));
const bytes = Buffer.from('the-original-image-bytes');
const blob = new Blob([bytes], { type: 'image/png' });
const img = { complete: true, naturalWidth: 1296, naturalHeight: 2142, currentSrc: 'blob:revoked-original' };
const candidate = { key: 'content-key', img };
class Reader {
  readAsDataURL(value) {
    value.arrayBuffer().then(buffer => {
      this.result = `data:${value.type};base64,${Buffer.from(buffer).toString('base64')}`;
      this.onload();
    });
  }
}
const sandbox = { window: null, FileReader: Reader,
  __crOfflineSourceRead: () => JSON.stringify({start:100, end:199, loading:false}),
  currentReadingCandidate: () => candidate, keyForUrl: () => 'key',
  __crKindleProbe: { keyToLiveUrl: new Map([['key', 'blob:retained-image']]) },
  document: { createElement() { throw Error('Offline capture must not re-encode a canvas'); } },
  fetch: async url => { assert.equal(url, 'blob:retained-image'); return { blob: async () => blob }; }
};
sandbox.window = sandbox;
vm.runInNewContext(code, sandbox);
const saved = JSON.parse(await sandbox.__crKindleOfflineImage());
assert.deepEqual(Buffer.from(saved.image.split(',')[1], 'base64'), bytes);
assert.equal(saved.originalBytes, bytes.length);
assert.deepEqual(saved.source, {start:100, end:199, loading:false});
sandbox.fetch = async () => { img.naturalWidth += 1; return { blob: async () => blob }; };
await assert.rejects(sandbox.__crKindleOfflineImage(), /offline-image-changed/);
sandbox.__crKindleProbe.keyToLiveUrl.clear();
await assert.rejects(sandbox.__crKindleOfflineImage(), /offline-original-image-unavailable/);
console.log('Original image bytes preserved; no canvas re-encoding; changed/missing images rejected.');
