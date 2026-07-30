// 把 src/entry.ts（含扩展 readout-desktop 的 highlight-sync / handwritten-marks）
// 编译成单个 IIFE bundle，输出到 app 源码目录的 WebAssets/，随 app bundle 打包。
import * as esbuild from 'esbuild'
import { mkdirSync, readFileSync } from 'node:fs'
import { dirname } from 'node:path'

const APP_OUT = '../CastReader/WebAssets/bundle.js'
const XCTEST_OUT = '../CastReaderTests/Fixtures/google-books-webreader-xctest.js'
const FIXTURE_API_NAMES = [
  '__fixtureManualIntent',
  '__fixtureBeginManualSwipe',
  '__fixtureEndManualSwipe',
]

const minify = process.argv.includes('--minify')

async function buildBundle(outfile, enableXCTestFixtures) {
  mkdirSync(dirname(outfile), { recursive: true })
  await esbuild.build({
    entryPoints: ['src/entry.ts'],
    bundle: true,
    format: 'iife',
    globalName: '__CRWeb',
    target: 'es2017',
    platform: 'browser',
    outfile,
    tsconfig: 'tsconfig.json',
    legalComments: 'none',
    logLevel: 'info',
    minify,
    treeShaking: true,
    // Targeted dead-code removal keeps the readable checked-in app bundle
    // stable while guaranteeing that the labeled fixture branch is not
    // emitted at all. `define=false` remains the compile-time feature gate.
    dropLabels: enableXCTestFixtures ? [] : ['CASTREADER_XCTEST_ONLY'],
    define: {
      __CASTREADER_XCTEST_FIXTURES__: enableXCTestFixtures ? 'true' : 'false',
    },
  })
}

function assertFixtureAPIMembership(path, shouldContainFixtures) {
  const source = readFileSync(path, 'utf8')
  const unexpected = FIXTURE_API_NAMES.filter(
    (name) => source.includes(name) !== shouldContainFixtures
  )
  if (unexpected.length > 0) {
    const expectation = shouldContainFixtures ? 'contain' : 'exclude'
    throw new Error(
      `${path} must ${expectation} XCTest fixture APIs; mismatch: ${unexpected.join(', ')}`
    )
  }
}

await buildBundle(APP_OUT, false)
assertFixtureAPIMembership(APP_OUT, false)
console.log(`✅ built ${APP_OUT} (production, minify=${minify}, fixture APIs absent)`)

await buildBundle(XCTEST_OUT, true)
assertFixtureAPIMembership(XCTEST_OUT, true)
console.log(`✅ built ${XCTEST_OUT} (CastReaderTests only, fixture APIs present)`)
