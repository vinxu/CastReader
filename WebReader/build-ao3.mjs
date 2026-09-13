// AO3 uses its own entry so the fix does not rebuild the other live readers or
// pull unrelated changes from the sibling browser-extension extractor.
import * as esbuild from 'esbuild'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
const root = fileURLToPath(new URL('.', import.meta.url))
const extension = resolve(process.env.READOUT_DESKTOP_SOURCE || resolve(root, '../../MyProject/readout-desktop/src'))
await esbuild.build({
  absWorkingDir: root, entryPoints: ['src/ao3-entry.ts'], bundle: true,
  format: 'iife', target: 'es2017', platform: 'browser', legalComments: 'none', minify: true,
  // Keep dependency string literals escaped; their significant whitespace
  // should not look like source whitespace errors in the generated artifact.
  supported: { 'template-literal': false },
  outfile: '../CastReader/WebAssets/ao3-bundle.js', logLevel: 'info',
  tsconfigRaw: { compilerOptions: { baseUrl: root, paths: { '@/*': [extension + '/*'] } } },
})
