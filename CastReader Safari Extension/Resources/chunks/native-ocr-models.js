// iOS-only adapter. Native storage is durable and shared with the containing app.
// The existing loader still verifies the exact pinned byte count and SHA-256.
export async function loadNativeOCRModel(model, asset) {
  const runtime = globalThis.browser?.runtime || globalThis.chrome?.runtime;
  const bundled = new Set(['eng', 'hin', 'ell', 'heb', 'fin', 'hun', 'fil']);
  if (bundled.has(model)) {
    const response = await fetch(runtime.getURL(`tesseract-wasm/${model}.traineddata`));
    if (!response.ok) throw new Error('ocr_bundled_model_missing');
    return response.arrayBuffer();
  }
  // Preserve pre-upgrade downloads during an offline update. Do not delete a
  // verified legacy cache until a durable replacement exists. All NEW downloads
  // use native storage; this path never writes/evicts browser caches.
  if (typeof caches !== 'undefined') {
    try {
      const old = await (await caches.open('castreader-ocr-model-data-v1')).match(asset.url);
      if (old) {
        const data = await old.arrayBuffer();
        if (data.byteLength === asset.bytes) {
          const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', data)), b => b.toString(16).padStart(2, '0')).join('');
          if (hash === asset.sha256) return data;
        }
      }
    } catch { /* unavailable/corrupt browser cache: continue to durable store */ }
  }
  if (!runtime?.sendNativeMessage) throw new Error('ocr_native_bridge_unavailable');
  // Every request has a deadline even if iOS terminates the extension host.
  async function message(payload, timeout = 10000) {
    let timer;
    try {
      const reply = await Promise.race([
        runtime.sendNativeMessage('com.same.castreader', payload),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('ocr_native_timeout')), timeout); }),
      ]);
      if (!reply?.ok) throw new Error('ocr_native_unavailable');
      return reply;
    } finally { clearTimeout(timer); }
  }
  const ready = await message({ type: 'OCR_MODEL_PREPARE', model }, 250000);
  if (ready.bytes !== asset.bytes || ready.sha256 !== asset.sha256) throw new Error('ocr_native_identity_mismatch');
  const transferDeadline = Date.now() + 60000;
  const buffer = new Uint8Array(asset.bytes);
  for (let offset = 0; offset < buffer.length;) {
    const count = Math.min(256 * 1024, buffer.length - offset);
    const remaining = transferDeadline - Date.now();
    if (remaining <= 0) throw new Error('ocr_native_timeout');
    const part = await message({ type: 'OCR_MODEL_READ', model, offset, count }, Math.min(10000, remaining));
    if (part.offset !== offset || typeof part.data !== 'string' || part.data.length > 350000) throw new Error('ocr_native_invalid_chunk');
    const decoded = atob(part.data);
    if (decoded.length !== count) throw new Error('ocr_native_invalid_chunk');
    for (let i = 0; i < count; i++) buffer[offset + i] = decoded.charCodeAt(i);
    offset += count;
  }
  return buffer.buffer;
}
