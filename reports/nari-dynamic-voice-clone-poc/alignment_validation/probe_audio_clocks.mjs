import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const [evaluationRoot, fixtureFile, outputFile] = process.argv.slice(2).map(value => resolve(value));
const require = createRequire(`${evaluationRoot}/package.json`);
const puppeteer = require('puppeteer');
const browser = await puppeteer.launch({
  headless: true,
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
});
try {
  const page = await browser.newPage();
  const rows = JSON.parse(readFileSync(fixtureFile, 'utf8'));
  const result = await page.evaluate(async fixtures => {
    const context = new OfflineAudioContext(1, 1, 24000);
    const records = [];
    for (const fixture of fixtures) {
      const bytes = Uint8Array.from(atob(fixture.response.audio), character => character.charCodeAt(0));
      const decoded = await context.decodeAudioData(bytes.buffer);
      records.push({ id: fixture.id, duration: decoded.duration, expected: fixture.duration,
        errorSamples: Math.round((decoded.duration - fixture.duration) * decoded.sampleRate),
        sampleRate: decoded.sampleRate });
    }
    return records;
  }, rows);
  writeFileSync(outputFile, JSON.stringify(result, null, 2) + '\n');
  const failures = result.filter(row => Math.abs(row.errorSamples) > 1);
  console.log(JSON.stringify({ samples: result.length, failures: failures.length }));
  if (failures.length) process.exitCode = 1;
} finally {
  await browser.close();
}
