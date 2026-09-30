import fs from 'node:fs'
import vm from 'node:vm'
import assert from 'node:assert/strict'
import { transform } from 'esbuild'

// Exercise the native hook's actual paint callback and provider navigation.
const { code } = await transform(fs.readFileSync(new URL('./src/weread-native.ts', import.meta.url), 'utf8'),
  { loader: 'ts', format: 'cjs' })
const attrs = new Map(), canvas = {}, listeners = new Map()
let nextClicks = 0
const nextButton = { disabled: false, click() { nextClicks++; reader.leftRenderPageIdx++; reader.paintPageFinish({ canvas }) } }
const context = vm.createContext({ module: { exports: {} }, exports: {}, console,
  document: {
    documentElement: { setAttribute: (k, v) => attrs.set(k, v), getAttribute: k => attrs.get(k), removeAttribute: k => attrs.delete(k) },
    querySelectorAll: () => [canvas], querySelector: () => nextButton,
    addEventListener(name, fn) { listeners.set(name, fn) }, dispatchEvent() {},
  }, requestAnimationFrame() {}, Event: class {}, window: {}, setTimeout, clearTimeout })
vm.runInContext(code, context)
const pages = [0, 1, 2, 3].map(i => ({ pageIdx: i, chapterUid: '6',
  contents: [{ type: 1, text: 'Page ' + i, _offset: String(120 + i * 300), canvasX: 0, rect: { y: 0, w: 60, h: 20 } }] }))
const calls = []
const reader = {
  $options: { name: 'HorizontalReader', methods: { getCurrentChapterPages() { return pages.filter(p => p.chapterUid === this.currentChapterUid) } } },
  $el: { isConnected: true }, bookInfo: { bookId: 'bookA' }, pageWidth: 390, pageHeight: 700,
  fontSizeLevel: 1, fontFamily: 'a', displayColumnCount: 1, extraRenderPagesInfo: pages,
  isSinglePage: true, isLastPage: false, leftRenderPageIdx: 0, paintPageFinish() {},
  scrollTo(args) {
    calls.push(args)
    const target = pages.find(p => Number(p.contents[0]._offset) === args.chapterOffset)
    if (!target) return
    // Real provider changePage always floors to a spread, including iPhone.
    this.leftRenderPageIdx = target.pageIdx % 2 ? target.pageIdx - 1 : target.pageIdx
    this.paintPageFinish({ canvas })
  },
}
const api = context.module.exports.installWeReadNativeBridge(reader)
assert.equal(api.readerPosition(), null, 'unpainted preloaded text cannot become a bookmark')
reader.paintPageFinish({ canvas })
assert.deepEqual(JSON.parse(JSON.stringify(api.readerPosition())), { chapterUID: '6', chapterOffset: 120 })
assert.equal(api.restorePosition({ chapterUID: '7', chapterOffset: 420 }), false)
assert.equal(api.restorePosition({ chapterUID: '6', chapterOffset: -1 }), false)
assert.equal(calls.length, 0)
assert.equal(api.restorePosition({ chapterUID: '6', chapterOffset: 420 }), true)
assert.equal(calls.length, 1)
assert.deepEqual(JSON.parse(JSON.stringify(api.readerPosition())), { chapterUID: '6', chapterOffset: 420 })
assert.equal(nextClicks, 1, 'odd-page restore needs exactly one semantic native correction')
assert.equal(api.restorePosition({ chapterUID: '6', chapterOffset: 720 }), true)
assert.equal(nextClicks, 1, 'even-page restore must not advance')
assert.deepEqual(JSON.parse(JSON.stringify(api.readerPosition())), { chapterUID: '6', chapterOffset: 720 })
nextButton.disabled = true
assert.equal(api.restorePosition({ chapterUID: '6', chapterOffset: 1020 }), true)
assert.equal(nextClicks, 1, 'disabled native Next must not be bypassed')
assert.deepEqual(JSON.parse(JSON.stringify(api.readerPosition())), { chapterUID: '6', chapterOffset: 720 })
nextButton.disabled = false
const normalScroll = reader.scrollTo
reader.scrollTo = function(args) { calls.push(args); this.leftRenderPageIdx = 2 }
assert.equal(api.restorePosition({ chapterUID: '6', chapterOffset: 1020 }), true)
listeners.get('pointerdown')()
reader.paintPageFinish({ canvas })
assert.equal(nextClicks, 1, 'manual intent cancels a correction before paint')
reader.scrollTo = normalScroll
reader._isDestroyed = true
assert.equal(api.restorePosition({ chapterUID: '6', chapterOffset: 120 }), false)
console.log('Native painted-position and same-chapter restore contract passed')
