#!/usr/bin/env node

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, '..');
const SOURCE_ROOT = join(REPO_ROOT, 'AppStoreAssets', 'web-localized-originals');
const OUTPUT_PATH = join(SOURCE_ROOT, 'cos-manifest.json');
const REMOTE_BASE_KEY = 'web-localized-screenshots/2026-08-02';
const LOCALES = ['en-US', 'pt-BR', 'ja-JP', 'it-IT', 'es-ES', 'zh-Hans', 'fr-FR', 'de-DE', 'hi-IN'];
const SCENES = ['kindle', 'read-aloud', 'explain', 'import', 'voices'];

async function getSts() {
  const response = await fetch('https://api.castreader.ai/sts');
  if (!response.ok) throw new Error(`STS HTTP ${response.status}`);
  const data = await response.json();
  if (!data.success || !data.sts) throw new Error('STS response did not contain credentials');
  return data.sts;
}

function cosSignature(secretKey, method, pathname, headers, signTime) {
  const signKey = crypto.createHmac('sha1', secretKey).update(signTime).digest('hex');
  const httpString = [
    method.toLowerCase(),
    pathname,
    '',
    Object.entries(headers)
      .map(([key, value]) => `${key.toLowerCase()}=${encodeURIComponent(value)}`)
      .join('&'),
    '',
  ].join('\n');
  const httpHash = crypto.createHash('sha1').update(httpString).digest('hex');
  const stringToSign = `sha1\n${signTime}\n${httpHash}\n`;
  return crypto.createHmac('sha1', signKey).update(stringToSign).digest('hex');
}

function uploadPng(sts, localPath, key) {
  const fullKey = `${sts.prefix}${key}`;
  const pathname = `/${fullKey}`;
  const accelerated = Boolean(sts.endpoint?.includes('accelerate'));
  const host = accelerated
    ? `${sts.bucket}.${sts.endpoint}`
    : `${sts.bucket}.cos.${sts.region}.myqcloud.com`;
  const url = `https://${host}${pathname}`;
  const now = Math.floor(Date.now() / 1000);
  const signTime = `${now};${now + 600}`;
  const signature = cosSignature(sts.secretAccessKey, 'PUT', pathname, { host }, signTime);
  const authorization = [
    'q-sign-algorithm=sha1',
    `q-ak=${sts.accessKeyId}`,
    `q-sign-time=${signTime}`,
    `q-key-time=${signTime}`,
    'q-header-list=host',
    'q-url-param-list=',
    `q-signature=${signature}`,
  ].join('&');

  const output = execFileSync(
    'curl',
    [
      '-sS',
      '--max-time', '90',
      '--retry', '2',
      '--retry-delay', '1',
      '-w', '\n%{http_code}',
      '-X', 'PUT',
      '-H', `Host: ${host}`,
      '-H', 'Content-Type: image/png',
      '-H', `Authorization: ${authorization}`,
      '-H', `x-cos-security-token: ${sts.sessionToken}`,
      '--data-binary', `@${localPath}`,
      url,
    ],
    { maxBuffer: 5 * 1024 * 1024 },
  ).toString();

  const lines = output.split('\n');
  const status = lines.at(-1)?.trim();
  if (status !== '200') {
    const body = lines.slice(0, -1).join('\n').slice(0, 300);
    throw new Error(`COS upload failed for ${key}: HTTP ${status} ${body}`);
  }
  return url;
}

async function main() {
  const rootEntries = await readdir(SOURCE_ROOT, { withFileTypes: true });
  const presentLocales = rootEntries.filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
  const expectedLocales = [...LOCALES].sort();
  if (JSON.stringify(presentLocales) !== JSON.stringify(expectedLocales)) {
    throw new Error(`Locale mismatch. Expected ${expectedLocales.join(', ')}, got ${presentLocales.join(', ')}`);
  }

  const sts = await getSts();
  const manifest = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    note: 'Raw, unprocessed iPhone screenshots supplied by the user. No App Store marketing headline or composite frame.',
    sourceRoot: SOURCE_ROOT,
    remoteBaseKey: REMOTE_BASE_KEY,
    dimensions: { pixelWidth: 1290, pixelHeight: 2796 },
    localeAliases: {
      en: 'en-US',
      pt: 'pt-BR',
      ja: 'ja-JP',
      it: 'it-IT',
      es: 'es-ES',
      zh: 'zh-Hans',
      fr: 'fr-FR',
      de: 'de-DE',
      hi: 'hi-IN',
    },
    locales: {},
  };

  let completed = 0;
  const total = LOCALES.length * SCENES.length;
  for (const locale of LOCALES) {
    manifest.locales[locale] = {};
    for (const scene of SCENES) {
      const localPath = join(SOURCE_ROOT, locale, `${scene}.png`);
      const buffer = await readFile(localPath);
      const sha256 = crypto.createHash('sha256').update(buffer).digest('hex');
      const key = `${REMOTE_BASE_KEY}/${locale}/${scene}.png`;
      const url = uploadPng(sts, localPath, key);
      manifest.locales[locale][scene] = {
        localPath,
        repoRelativePath: relative(REPO_ROOT, localPath),
        bytes: buffer.length,
        sha256,
        pixelWidth: 1290,
        pixelHeight: 2796,
        url,
      };
      completed += 1;
      process.stdout.write(`[${completed}/${total}] ${locale}/${scene}.png\n`);
    }
  }

  await writeFile(OUTPUT_PATH, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  process.stdout.write(`Manifest: ${OUTPUT_PATH}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
