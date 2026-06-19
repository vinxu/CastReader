// 把 src/entry.ts（含扩展 readout-desktop 的 highlight-sync / handwritten-marks）
// 编译成单个 IIFE bundle，输出到 app 源码目录的 WebAssets/，随 app bundle 打包。
import * as esbuild from 'esbuild'
import { mkdirSync } from 'node:fs'

const OUT_DIR = '../CastReader/WebAssets'
mkdirSync(OUT_DIR, { recursive: true })

const minify = process.argv.includes('--minify')

await esbuild.build({
  entryPoints: ['src/entry.ts'],
  bundle: true,
  format: 'iife',
  globalName: '__CRWeb',
  target: 'es2017',
  platform: 'browser',
  outfile: `${OUT_DIR}/bundle.js`,
  tsconfig: 'tsconfig.json',
  legalComments: 'none',
  logLevel: 'info',
  minify,
})

console.log(`✅ built ${OUT_DIR}/bundle.js (minify=${minify})`)
