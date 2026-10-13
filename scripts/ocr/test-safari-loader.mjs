import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
const path = new URL('../../CastReader Safari Extension/Resources/chunks/native-ocr-models.js', import.meta.url);
const source = fs.readFileSync(path, 'utf8').replace('export async function', 'async function');
const bytes = Uint8Array.from({ length: 600000 }, (_, i) => i % 251);
const sha256 = Buffer.from(await webcrypto.subtle.digest('SHA-256', bytes)).toString('hex');
const asset = { url: 'https://models.invalid/test', bytes: bytes.length, sha256 };
function loader(overrides = {}) {
  const context = vm.createContext({ Uint8Array, ArrayBuffer, crypto: webcrypto, atob, setTimeout, clearTimeout, ...overrides });
  vm.runInContext(source, context);
  return (model, asset) => context.loadNativeOCRModel(model, asset);
}
let requests = [];
const runtime = { sendNativeMessage: async (host, m) => {
  assert.equal(host, 'com.same.castreader'); requests.push(m);
  if (m.type === 'OCR_MODEL_PREPARE') return { ok: true, bytes: bytes.length, sha256 };
  return { ok: true, offset: m.offset, data: Buffer.from(bytes.slice(m.offset, m.offset + m.count)).toString('base64') };
}};
let result = await loader({ browser: { runtime } })('test', asset);
assert.deepEqual(new Uint8Array(result), bytes);
assert.equal(requests.length, 4);
assert(requests.slice(1).every(x => x.count <= 262144));
const oldCache = { open: async () => ({ match: async () => ({ arrayBuffer: async () => bytes.buffer }) }) };
result = await loader({ caches: oldCache })('test', asset);
assert.deepEqual(new Uint8Array(result), bytes, 'Pre-upgrade cache must work with native host offline');
await assert.rejects(loader({ caches: oldCache })('test', { ...asset, sha256: '0'.repeat(64) }), /bridge_unavailable/);
await assert.rejects(loader({ browser: { runtime: { sendNativeMessage: async () => ({ ok: false }) } } })('test', asset), /native_unavailable/);
await assert.rejects(loader({ browser: { runtime: { sendNativeMessage: async () => ({ ok: true, bytes: 1, sha256 }) } } })('test', asset), /identity_mismatch/);
const badChunk = { sendNativeMessage: async (_, m) => m.type === 'OCR_MODEL_PREPARE'
  ? { ok: true, bytes: bytes.length, sha256 } : { ok: true, offset: m.offset + 1, data: '' } };
await assert.rejects(loader({ browser: { runtime: badChunk } })('test', asset), /invalid_chunk/);
await assert.rejects(loader({ browser: { runtime: { sendNativeMessage: () => new Promise(() => {}) } },
  setTimeout: (fn) => setTimeout(fn, 5) })('test', asset), /native_timeout/);
let downloads = 0;
result = await loader({ chrome: { runtime: { getURL: path => path } }, fetch: async path => {
  assert.equal(path, 'tesseract-wasm/eng.traineddata'); downloads++; return { ok: true, arrayBuffer: async () => bytes.buffer };
} })('eng', asset);
assert.equal(downloads, 1); assert.deepEqual(new Uint8Array(result), bytes);
console.log('PASS: Safari chunks, offline upgrade cache, corrupt cache, host failure/timeout, identity mismatch, invalid chunk, bundled English');

const classic = fs.readFileSync(new URL('../../CastReader Safari Extension/Resources/chunks/native-ocr-models-background.js', import.meta.url), 'utf8');
const classicContext = vm.createContext({ Uint8Array, ArrayBuffer, crypto: webcrypto, atob, setTimeout, clearTimeout, browser: { runtime }, It: { test: asset }, Gr: async (id, data) => {
  assert.equal(id, 'test'); assert.equal(Buffer.from(await webcrypto.subtle.digest('SHA-256', data)).toString('hex'), sha256);
} });
vm.runInContext(classic, classicContext);
const backgroundSource = fs.readFileSync(new URL('../../CastReader Safari Extension/Resources/background.js', import.meta.url), 'utf8');
const loaderStart = backgroundSource.indexOf('async function Si(t){');
vm.runInContext(backgroundSource.slice(loaderStart, backgroundSource.indexOf('const Ri=', loaderStart)), classicContext);
assert.deepEqual(new Uint8Array(await classicContext.Si('test')), bytes);
console.log('PASS: actual Safari classic background loader -> generated adapter -> native chunks -> SHA verification');
