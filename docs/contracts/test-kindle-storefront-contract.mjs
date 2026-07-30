#!/usr/bin/env node

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const contractDirectory = path.dirname(fileURLToPath(import.meta.url));
const catalog = JSON.parse(
  fs.readFileSync(path.join(contractDirectory, 'kindle-storefronts-v1.json'), 'utf8'),
);
const cases = JSON.parse(
  fs.readFileSync(
    path.join(contractDirectory, 'kindle-storefront-contract-cases-v1.json'),
    'utf8',
  ),
);

function normalizeHost(rawHost) {
  if (typeof rawHost !== 'string' || rawHost !== rawHost.trim()) return null;

  let host = rawHost.toLowerCase();
  if (host.endsWith('.')) host = host.slice(0, -1);
  if (
    host.length === 0 ||
    host.endsWith('.') ||
    !/^[a-z0-9.-]+$/.test(host)
  ) {
    return null;
  }
  return host;
}

const storefrontByID = new Map();
const storefrontByHost = new Map();
for (const storefront of catalog.storefronts) {
  assert.match(storefront.id, /^[a-z]{2}$/);
  assert.ok(!storefrontByID.has(storefront.id), `duplicate storefront id: ${storefront.id}`);
  storefrontByID.set(storefront.id, storefront);

  assert.match(storefront.marketplaceRegion, /^[A-Z]{2}$/);
  assert.equal(typeof storefront.displayName, 'string');
  assert.ok(storefront.displayName.length > 0);
  assert.equal(typeof storefront.entryEnabled, 'boolean');

  const hosts = [storefront.canonicalHost, ...storefront.aliasHosts];
  assert.equal(new Set(hosts).size, hosts.length, `duplicate host inside ${storefront.id}`);
  for (const rawHost of hosts) {
    const host = normalizeHost(rawHost);
    assert.equal(host, rawHost, `catalog host must already be normalized: ${rawHost}`);
    assert.ok(!storefrontByHost.has(host), `host belongs to multiple storefronts: ${host}`);
    storefrontByHost.set(host, storefront);
  }
}

function storefrontForHost(rawHost) {
  const host = normalizeHost(rawHost);
  return host === null ? null : storefrontByHost.get(host) ?? null;
}

function storefrontForHTTPSURL(rawURL) {
  let url;
  try {
    url = new URL(rawURL);
  } catch {
    return null;
  }
  if (
    url.protocol !== 'https:' ||
    url.username.length > 0 ||
    url.password.length > 0 ||
    (url.port.length > 0 && url.port !== '443')
  ) {
    return null;
  }
  return storefrontForHost(url.hostname);
}

assert.equal(catalog.contractID, 'castreader-kindle-storefronts');
assert.equal(catalog.schemaVersion, 1);
assert.equal(catalog.fallbackStorefrontID, 'us');
assert.equal(catalog.readerRef, 'kwl_kr_iv_rec_1');
assert.equal(cases.schemaVersion, 1);
assert.equal(catalog.paths.library, '/kindle-library');
assert.equal(catalog.paths.reader, '/');
assert.equal(catalog.storefronts.length, cases.expectedStorefrontCount);
assert.equal(storefrontByHost.size, cases.expectedRecognizedHostCount);
assert.equal(
  catalog.storefronts.filter(({ entryEnabled }) => entryEnabled).length,
  cases.expectedEntryEnabledStorefrontCount,
);
assert.equal(
  storefrontByID.get(catalog.fallbackStorefrontID)?.entryEnabled,
  true,
  'fallback storefront must be entry-enabled',
);

const disabledStorefronts = catalog.storefronts.filter(({ entryEnabled }) => !entryEnabled);
assert.deepEqual(
  disabledStorefronts.map(({ id }) => id),
  ['cn'],
  'Amazon.cn must remain recognition-only and must not be offered as an entry',
);
assert.equal(disabledStorefronts[0].entryDisabledReason, 'kindle_china_shutdown');

assert.equal(storefrontByID.get('de').canonicalHost, 'lesen.amazon.de');
assert.deepEqual(storefrontByID.get('de').aliasHosts, ['read.amazon.de']);
assert.equal(storefrontByID.get('fr').canonicalHost, 'lire.amazon.fr');
assert.deepEqual(storefrontByID.get('fr').aliasHosts, ['read.amazon.fr']);
assert.equal(storefrontByID.get('it').canonicalHost, 'leggi.amazon.it');
assert.deepEqual(storefrontByID.get('it').aliasHosts, ['read.amazon.it']);
assert.equal(storefrontByID.get('es').canonicalHost, 'leer.amazon.es');
assert.deepEqual(storefrontByID.get('es').aliasHosts, ['read.amazon.es']);
assert.equal(storefrontByID.get('br').canonicalHost, 'ler.amazon.com.br');
assert.deepEqual(storefrontByID.get('br').aliasHosts, ['read.amazon.com.br']);
assert.equal(storefrontByID.get('mx').canonicalHost, 'leer.amazon.com.mx');
assert.deepEqual(storefrontByID.get('mx').aliasHosts, ['read.amazon.com.mx']);
assert.equal(storefrontByID.get('nl').canonicalHost, 'lezen.amazon.nl');
assert.deepEqual(storefrontByID.get('nl').aliasHosts, ['read.amazon.nl']);

const expectedRegionMap = {
  US: 'us',
  GB: 'uk',
  CA: 'ca',
  AU: 'au',
  JP: 'jp',
  DE: 'de',
  FR: 'fr',
  IT: 'it',
  ES: 'es',
  IN: 'in',
  BR: 'br',
  MX: 'mx',
  NL: 'nl',
};
assert.deepEqual(catalog.regionToStorefront, expectedRegionMap);
for (const [region, id] of Object.entries(catalog.regionToStorefront)) {
  assert.match(region, /^[A-Z]{2}$/);
  assert.equal(
    storefrontByID.get(id)?.entryEnabled,
    true,
    `device region ${region} must never suggest a recognition-only storefront`,
  );
}

const expectedLanguageCandidateOrder = {
  en: ['us', 'uk', 'ca', 'au', 'in'],
  es: ['es', 'mx', 'us'],
  'pt-BR': ['br', 'us'],
  ja: ['jp', 'us'],
  de: ['de', 'us'],
  fr: ['fr', 'ca', 'us'],
  it: ['it', 'us'],
  hi: ['in', 'us'],
};
assert.deepEqual(catalog.languageCandidateOrder, expectedLanguageCandidateOrder);
assert.deepEqual(catalog.excludedAppLanguages, ['zh', 'zh-Hans']);
for (const [language, ids] of Object.entries(catalog.languageCandidateOrder)) {
  assert.equal(new Set(ids).size, ids.length, `duplicate candidate for language ${language}`);
  for (const id of ids) {
    assert.equal(
      storefrontByID.get(id)?.entryEnabled,
      true,
      `${language} candidate ${id} must be entry-enabled`,
    );
  }
}

for (const testCase of cases.positiveHostCases) {
  assert.equal(
    storefrontForHost(testCase.input)?.id,
    testCase.expectedStorefrontID,
    `positive host case failed: ${testCase.input}`,
  );
}
for (const host of cases.securityNegativeHosts) {
  assert.equal(storefrontForHost(host), null, `unsafe host matched: ${host}`);
}
for (const testCase of cases.positiveURLCases) {
  assert.equal(
    storefrontForHTTPSURL(testCase.input)?.id,
    testCase.expectedStorefrontID,
    `positive URL case failed: ${testCase.input}`,
  );
}
for (const url of cases.securityNegativeURLs) {
  assert.equal(storefrontForHTTPSURL(url), null, `unsafe URL matched: ${url}`);
}

function extensionRootFromArguments(argv) {
  const flagIndex = argv.indexOf('--extension-root');
  if (flagIndex === -1) return null;
  assert.ok(argv[flagIndex + 1], '--extension-root requires a directory');
  return path.resolve(argv[flagIndex + 1]);
}

const extensionRoot = extensionRootFromArguments(process.argv.slice(2));
if (extensionRoot !== null) {
  const expectedExtensionHosts = [...storefrontByHost.keys()].sort();
  const expectedExtensionPatterns = expectedExtensionHosts.map(
    (host) => `https://${host}/*`,
  ).sort();
  const assertExtensionHostParity = (label, hosts) => {
    assert.deepEqual(
      [...new Set(hosts)].sort(),
      expectedExtensionHosts,
      `${label} must exactly equal the shared recognized-host set`,
    );
  };

  const storefrontSource = fs.readFileSync(
    path.join(extensionRoot, 'src/shared/kindle-storefront.ts'),
    'utf8',
  );
  const extensionContractTestOutput = execFileSync(
    process.execPath,
    ['scripts/test-kindle-storefront.mjs'],
    {
      cwd: extensionRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        CASTREADER_KINDLE_STOREFRONT_CONTRACT: path.join(
          contractDirectory,
          'kindle-storefronts-v1.json',
        ),
      },
    },
  );
  assert.match(
    extensionContractTestOutput,
    /PASS Kindle storefront: full canonical contract/,
    'extension runtime must deep-compare every catalog field with the canonical JSON',
  );
  const runtimeCanonicalHosts = [
    ...storefrontSource.matchAll(/canonicalHost:\s*['"]([^'"]+)['"]/g),
  ].map((match) => match[1]);
  const runtimeAliasHosts = [
    ...storefrontSource.matchAll(/aliasHosts:\s*\[([^\]]*)\]/g),
  ].flatMap((match) =>
    [...match[1].matchAll(/['"]([^'"]+)['"]/g)].map((hostMatch) => hostMatch[1]),
  );
  assertExtensionHostParity(
    'extension runtime Kindle catalog',
    [...runtimeCanonicalHosts, ...runtimeAliasHosts],
  );
  assert.match(
    storefrontSource,
    /KINDLE_MATCH_PATTERNS[\s\S]*KINDLE_STOREFRONT_HOSTS\.map/,
    'extension match patterns must be derived from the runtime host catalog',
  );
  assert.match(
    storefrontSource,
    /`https:\/\/\$\{host\}\/\*`/,
    'extension Kindle manifest and content-script projections must be HTTPS-only',
  );
  assert.doesNotMatch(
    storefrontSource,
    /`\*:\/\/\$\{host\}\/\*`/,
    'extension Kindle match projections must not accept HTTP',
  );

  const configSource = fs.readFileSync(path.join(extensionRoot, 'wxt.config.ts'), 'utf8');
  assert.match(
    configSource,
    /KINDLE_MATCHES\s*=\s*KINDLE_MATCH_PATTERNS/,
    'extension wxt.config.ts must derive Kindle matches from the runtime catalog',
  );

  const pipelineSource = fs.readFileSync(
    path.join(extensionRoot, 'src/extractors/extraction-pipeline.ts'),
    'utf8',
  );
  assert.match(
    pipelineSource,
    /\.\.\.KINDLE_STOREFRONT_HOSTS\.map/,
    'extension SPECIAL_EXTRACTORS must derive Kindle entries from the runtime catalog',
  );
  assert.match(
    pipelineSource,
    /extractor === kindleExtractor[\s\S]*hostname === domain/,
    'extension SPECIAL_EXTRACTORS must match derived Kindle hosts by exact equality',
  );

  const extractorSource = fs.readFileSync(
    path.join(extensionRoot, 'src/extractors/kindle.ts'),
    'utf8',
  );
  assert.match(
    extractorSource,
    /matches:\s*\[\.\.\.KINDLE_STOREFRONT_HOSTS\]/,
    'extension kindleExtractor.matches must derive from the runtime catalog',
  );
  assert.match(
    extractorSource,
    /kindleStorefrontForHTTPSURL\(sourceURL\)/,
    'extension Kindle iframe discovery must validate localized iframe hosts structurally',
  );
  assert.doesNotMatch(
    extractorSource,
    /iframe\[src\*=['"]read\.amazon/,
    'extension Kindle iframe discovery must not keep a US-prefix selector',
  );

  for (const entrypoint of [
    'src/entrypoints/kindle-intercept.content.ts',
    'src/entrypoints/kindle-hook.content.ts',
  ]) {
    const source = fs.readFileSync(path.join(extensionRoot, entrypoint), 'utf8');
    assert.match(
      source,
      /matches:\s*KINDLE_MATCH_PATTERNS/,
      `${entrypoint} must derive matches from the runtime catalog`,
    );
  }

  const exactMatcherConsumers = [
    'src/entrypoints/background.ts',
    'src/entrypoints/content.ts',
    'src/core/tts-orchestrator.ts',
    'src/shared/analytics.ts',
    'src/ui/pro-moments.ts',
    'src/ui/quickread-overlay.ts',
    'src/shared/user-segment.ts',
  ];
  for (const consumer of exactMatcherConsumers) {
    const source = fs.readFileSync(path.join(extensionRoot, consumer), 'utf8');
    assert.match(
      source,
      /isKindleStorefrontHost|kindleStorefrontForHost|kindleStorefrontForHTTPSURL/,
      `${consumer} must consume the exact Kindle storefront helper`,
    );
    assert.doesNotMatch(
      source,
      /\.includes\(\s*['"](?:read|leer|ler)\.amazon|\.startsWith\(\s*['"](?:read|leer|ler)\.amazon|\^read\\\.amazon/i,
      `${consumer} must not reintroduce a prefix/substring Kindle matcher`,
    );
  }

  const analyticsSource = fs.readFileSync(
    path.join(extensionRoot, 'src/shared/analytics.ts'),
    'utf8',
  );
  assert.match(
    analyticsSource,
    /delete next\.storefront[\s\S]*kindleStorefrontForHost\(next\.url_domain\)[\s\S]*next\.storefront = storefront\.id/,
    'extension analytics must derive a controlled storefront id inside the privacy boundary',
  );

  const builtManifestPath = path.join(
    extensionRoot,
    '.output/chrome-mv3/manifest.json',
  );
  if (fs.existsSync(builtManifestPath)) {
    const manifest = JSON.parse(fs.readFileSync(builtManifestPath, 'utf8'));
    const kindleHostPermissions = (manifest.host_permissions ?? []).filter((pattern) =>
      expectedExtensionPatterns.includes(pattern),
    );
    assert.deepEqual(
      [...new Set(kindleHostPermissions)].sort(),
      expectedExtensionPatterns,
      'built manifest Kindle host_permissions must equal the shared contract',
    );

    for (const scriptName of ['kindle-hook.js', 'kindle-intercept.js']) {
      const script = (manifest.content_scripts ?? []).find((item) =>
        (item.js ?? []).some((file) => file.endsWith(scriptName)),
      );
      assert.ok(script, `built manifest is missing ${scriptName}`);
      assert.deepEqual(
        [...new Set(script.matches ?? [])].sort(),
        expectedExtensionPatterns,
        `built ${scriptName} matches must equal the shared contract`,
      );
    }
    console.log(
      `PASS extension host parity: ${expectedExtensionHosts.length} runtime hosts ` +
        'projected into the built manifest; 12 consumers share the exact catalog',
    );
  } else {
    console.log(
      `PASS extension source parity: ${expectedExtensionHosts.length} runtime hosts; ` +
        '12 consumers share the exact catalog; run pnpm build to validate the final manifest',
    );
  }
}

function androidRootFromArguments(argv) {
  const flagIndex = argv.indexOf('--android-root');
  if (flagIndex === -1) return null;
  assert.ok(argv[flagIndex + 1], '--android-root requires a directory');
  return path.resolve(argv[flagIndex + 1]);
}

const androidRoot = androidRootFromArguments(process.argv.slice(2));
if (androidRoot !== null) {
  const sourcePath = path.join(
    androidRoot,
    'app/src/main/java/com/same/castreader/kindle/KindleStorefront.kt',
  );
  const source = fs.readFileSync(sourcePath, 'utf8');
  const runtimeStorefronts = [];
  const storefrontPattern =
    /KindleStorefront\(\s*"([a-z]{2})",\s*"([A-Z]{2})",\s*"([^"]+)",([\s\S]*?)displayName\s*=\s*"([^"]+)"(?:,\s*entryEnabled\s*=\s*(true|false))?\s*\)/g;
  for (const match of source.matchAll(storefrontPattern)) {
    const aliasBlock = match[4].match(/aliasHosts\s*=\s*listOf\(([^)]*)\)/)?.[1] ?? '';
    runtimeStorefronts.push({
      id: match[1],
      marketplaceRegion: match[2],
      canonicalHost: match[3],
      aliasHosts: [...aliasBlock.matchAll(/"([^"]+)"/g)].map((alias) => alias[1]),
      displayName: match[5],
      entryEnabled: match[6] === undefined ? true : match[6] === 'true',
    });
  }
  assert.deepEqual(
    runtimeStorefronts,
    catalog.storefronts.map(
      ({ id, marketplaceRegion, canonicalHost, aliasHosts, displayName, entryEnabled }) => ({
        id,
        marketplaceRegion,
        canonicalHost,
        aliasHosts,
        displayName,
        entryEnabled,
      }),
    ),
    'Android runtime storefront catalog must equal the shared canonical JSON',
  );

  const runtimeRegionMap = Object.fromEntries(
    runtimeStorefronts
      .filter(({ entryEnabled }) => entryEnabled)
      .map(({ marketplaceRegion, id }) => [marketplaceRegion, id]),
  );
  assert.deepEqual(
    runtimeRegionMap,
    catalog.regionToStorefront,
    'Android enabled marketplace regions must equal the shared canonical JSON',
  );

  const languageMapBlock = source.match(
    /private val languageCandidateOrder\s*=\s*mapOf\(([\s\S]*?)\n\s*\)/,
  )?.[1];
  assert.ok(languageMapBlock, 'Android languageCandidateOrder map was not found');
  const runtimeLanguageOrder = Object.fromEntries(
    [...languageMapBlock.matchAll(/"([^"]+)"\s+to\s+listOf\(([^)]*)\)/g)].map(
      ([, language, values]) => [
        language,
        [...values.matchAll(/"([^"]+)"/g)].map((value) => value[1]),
      ],
    ),
  );
  assert.deepEqual(
    runtimeLanguageOrder,
    catalog.languageCandidateOrder,
    'Android eight-language ordering must equal the shared canonical JSON',
  );
  assert.match(
    source,
    /fun entry\(id: String\?\)[\s\S]*takeIf\(KindleStorefront::entryEnabled\)/,
    'Android must separate recognition from entry-enabled navigation',
  );
  assert.match(
    source,
    /if \(tag\.startsWith\("zh", ignoreCase = true\)\) return null/,
    'Android must exclude Chinese app languages from storefront suggestions',
  );
  console.log(
    `PASS Android catalog parity: ${runtimeStorefronts.length} storefronts, ` +
      `${Object.keys(runtimeLanguageOrder).length} language orders, exact regions and aliases`,
  );
}

console.log(
  `PASS Kindle storefront contract: ${catalog.storefronts.length} storefronts, ` +
    `${storefrontByHost.size} recognized hosts, ` +
    `${catalog.storefronts.filter(({ entryEnabled }) => entryEnabled).length} entries, ` +
    `${Object.keys(catalog.languageCandidateOrder).length} non-Chinese language orders`,
);
