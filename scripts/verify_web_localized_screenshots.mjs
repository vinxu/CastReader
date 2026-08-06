#!/usr/bin/env node

import { readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, '..');
const ASSET_ROOT = join(REPO_ROOT, 'AppStoreAssets', 'web-localized-originals');
const MANIFEST_PATH = join(ASSET_ROOT, 'cos-manifest.json');
const REPORT_PATH = join(ASSET_ROOT, 'cos-verification.json');

async function verify(entry) {
  const response = await fetch(entry.url, { method: 'HEAD', redirect: 'follow' });
  const contentType = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() ?? '';
  const contentLength = Number(response.headers.get('content-length') ?? -1);
  const passed = response.status === 200 && contentType === 'image/png' && contentLength === entry.bytes;
  return {
    locale: entry.locale,
    scene: entry.scene,
    url: entry.url,
    expectedBytes: entry.bytes,
    status: response.status,
    contentType,
    contentLength,
    passed,
  };
}

async function main() {
  const manifest = JSON.parse(await readFile(MANIFEST_PATH, 'utf8'));
  const entries = Object.entries(manifest.locales).flatMap(([locale, scenes]) =>
    Object.entries(scenes).map(([scene, asset]) => ({ locale, scene, ...asset })),
  );

  const results = [];
  const concurrency = 8;
  for (let index = 0; index < entries.length; index += concurrency) {
    const batch = entries.slice(index, index + concurrency);
    results.push(...(await Promise.all(batch.map(verify))));
  }

  const failures = results.filter((result) => !result.passed);
  const report = {
    checkedAt: new Date().toISOString(),
    total: results.length,
    passed: results.length - failures.length,
    failed: failures.length,
    results,
  };
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, 'utf8');

  if (failures.length > 0) {
    for (const failure of failures) {
      process.stderr.write(`${failure.locale}/${failure.scene}: HTTP ${failure.status}, ${failure.contentType}, ${failure.contentLength}/${failure.expectedBytes}\n`);
    }
    throw new Error(`${failures.length} of ${results.length} COS objects failed verification`);
  }

  process.stdout.write(`Verified ${results.length}/${results.length} public COS PNG objects.\n`);
  process.stdout.write(`Report: ${REPORT_PATH}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
