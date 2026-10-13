import fs from 'node:fs';
const models = JSON.parse(fs.readFileSync(new URL('./models.json', import.meta.url)));
const path = new URL('../../CastReader/Services/OCRModelCatalog.swift', import.meta.url);
const rows = Object.entries(models).map(([id, x]) => `        "${id}": OCRModelAsset(id: "${id}", bytes: ${x.bytes}, sha256: "${x.sha256}", sources: [${[x.url, ...x.fallbackUrls].map(url => 'URL(string: ' + JSON.stringify(url) + ')!').join(', ')}]),`).join('\n');
const current = fs.readFileSync(path, 'utf8');
const generated = current.replace(/(static let assets: \[String: OCRModelAsset\] = \[\n)[\s\S]*?(\n    \]\n})/, '$1' + rows + '$2');
if (process.argv.includes('--check')) {
  if (current !== generated) throw new Error('Run node scripts/ocr/generate-catalog.mjs');
} else fs.writeFileSync(path, generated);
