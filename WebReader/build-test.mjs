// 把 play-books.ts 单独打成全局 bundle，供 fixture 页面直接验证提取/裁剪算法。
// 产物不进 app（输出到 scratchpad），日常构建不需要跑。
import * as esbuild from 'esbuild'

const out = process.argv[2] || '/tmp/play-books-test.js'

await esbuild.build({
  entryPoints: ['src/test-entry.ts'],
  bundle: true,
  format: 'iife',
  globalName: 'PlayBooks',
  target: 'es2017',
  platform: 'browser',
  outfile: out,
  tsconfig: 'tsconfig.json',
  logLevel: 'info',
  define: {
    __CASTREADER_XCTEST_FIXTURES__: 'true',
  },
})
console.log(`built ${out}`)
