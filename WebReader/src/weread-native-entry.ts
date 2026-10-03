import { installWeReadNativeBridge, readWeReadNativeState, type WeReadColumn, WEREAD_TURN_ATTR, WEREAD_TURN_EVENT, WEREAD_TURN_RESULT, WEREAD_NAVIGATION_EVENT } from './weread-native'

// This runs in WKContentWorld.page at document start, before the renderer.
// Keep the iOS geometry adapter separate from the renderer observation hook.
type Word = { text: string; start: number; end: number; column: WeReadColumn; glyph: WeReadColumn['glyphs'][number] }
type Unit = { text: string; chapter: number; offset: number; words: Word[] }
// Match the extension's sentence boundary rule without rewriting source
// offsets or native glyph geometry. Invisible format characters are not text
// that continues a sentence after its punctuation/closing quote.
const terminal = (text: string) => /[。！？.!?][”’"'」』）)]*\s*$/u.test(text.replace(/[\u200b-\u200d\ufeff]/g, ''))

function units(columns: WeReadColumn[]): Unit[] {
  const result: Unit[] = []
  let unit: Unit | undefined
  let previousHeight = 0
  let previousIndex: number | undefined
  for (const column of columns) {
    // Missing +1 never permits stitching across a resource hole.
    if (previousIndex !== undefined && column.index !== previousIndex + 1) unit = undefined
    for (const glyph of column.glyphs) {
      if (!unit || unit.chapter !== column.chapter ||
          (terminal(unit.text) && !/^[”’"'」』）)]/.test(glyph.text)) ||
          (previousHeight > 0 && Math.abs(previousHeight - glyph.height) > 6)) {
        unit = { text: '', chapter: column.chapter, offset: glyph.offset, words: [] }
        result.push(unit)
      }
      const start = unit.text.length
      unit.text += glyph.text
      unit.words.push({ text: glyph.text, start, end: unit.text.length, column, glyph })
      previousHeight = glyph.height
    }
    previousIndex = column.index
  }
  return result
}

let observedNativeState = false
function snapshot(host: HTMLElement, successor = false) {
  const state = readWeReadNativeState()
  if (!state) return observedNativeState ? { ready: false, items: [] } : null
  observedNativeState = true
  if (!state.ready || !state.current.length || !host?.isConnected) return { ready: false, items: [] }
  const first = state.columns.find(p => p.id === state.current[0])
  if (!first) return { ready: false, items: [] }
  const start = first.index + (successor ? state.count : 0)
  const selected = successor
    ? state.columns.filter(p => p.index >= start && p.index < start + state.count)
    : state.current.map(id => state.columns.find(p => p.id === id)!).filter(Boolean)
  if (!selected.length || selected[0].index !== start ||
      selected.some((p, i) => p.index !== start + i)) return { ready: false, items: [] }
  const ids = selected.map(p => p.id)
  const hr = host.getBoundingClientRect()
  const canvases = [...document.querySelectorAll<HTMLCanvasElement>('.wr_canvasContainer canvas')]
  const all = units(state.columns)
  const items = all.flatMap(unit => {
    const visible = unit.words.filter(w => ids.includes(w.column.id))
    if (!visible.length) return []
    const from = visible[0].start, to = visible[visible.length - 1].end
    const text = unit.text.slice(from, to)
    if (!text.trim()) return []
    const entries = successor ? [] : visible.flatMap(word => {
      const slot = ids.indexOf(word.column.id), canvas = canvases[slot]
      if (!canvas?.isConnected) return []
      const r = canvas.getBoundingClientRect(), g = word.glyph
      if (r.width <= 0 || r.height <= 0) return []
      const x = r.left + g.x * r.width / word.column.width
      const y = r.top + g.y * r.height / word.column.height
      const right = x + g.width * r.width / word.column.width
      const bottom = y + g.height * r.height / word.column.height
      const leftClip = Math.max(x, r.left, hr.left, 0), topClip = Math.max(y, r.top, hr.top, 0)
      const rightClip = Math.min(right, r.right, hr.right, innerWidth)
      const bottomClip = Math.min(bottom, r.bottom, hr.bottom, innerHeight)
      if (rightClip <= leftClip || bottomClip <= topClip) return []
      return [{ charStart: word.start - from, charEnd: word.end - from,
        bbox: { x: leftClip - hr.left, y: topClip - hr.top, width: rightClip - leftClip, height: bottomClip - topClip } }]
    })
    if (!successor && !entries.length) return []
    const left = Math.min(...entries.map(e => e.bbox.x)), top = Math.min(...entries.map(e => e.bbox.y))
    return [{ text, style: '', entries,
      bounds: successor ? { x: 0, y: 0, width: 0, height: 0 } : { x: left, y: top,
        width: Math.max(...entries.map(e => e.bbox.x + e.bbox.width)) - left,
        height: Math.max(...entries.map(e => e.bbox.y + e.bbox.height)) - top },
      sourceLayoutFingerprint: `${state.book}:${unit.chapter}:${state.layout}`,
      sourceParagraphIndex: unit.offset, sourceParagraphText: unit.text,
      // Chapter offsets are stable across font/column changes; sentence units
      // can begin earlier/later when the provider replaces its cached columns.
      nativeSourceIdentity: `${state.book}:${unit.chapter}`,
      sourceAnchors: unit.words.map(w => ({ start: w.start - from, end: w.end - from,
        offset: w.glyph.offset, text: w.text })),
      sourceCharStart: from, sourceCharEnd: to,
      sourcePageEnds: unit.words.filter((w, i, a) => i === a.length - 1 || a[i + 1].column.id !== w.column.id).map(w => w.end),
      geometrySource: 'native-glyphs', nativePages: ids,
    }]
  })
  return { ready: true, items, pageIdentity: `${state.layout}|${ids.join('|')}`,
    layout: state.layout, revision: state.revision, last: state.last, count: state.count }
}

function turn(direction: 'next' | 'prev') {
  const state = readWeReadNativeState()
  if (!state?.ready) return false
  const from = state.columns.find(p => p.id === state.current[0])
  const to = from && state.columns.find(p => p.index === from.index + (direction === 'next' ? state.count : -state.count))
  if (!from || !to) return false
  const requestId = `ios-${state.revision}-${from.index}-${to.index}`
  document.documentElement.setAttribute(WEREAD_TURN_ATTR, JSON.stringify({ requestId, from: from.id, to: to.id }))
  document.dispatchEvent(new Event(WEREAD_TURN_EVENT))
  try {
    const result = JSON.parse(document.documentElement.getAttribute(WEREAD_TURN_RESULT) || 'null')
    return result?.requestId === requestId && result.accepted === true
  } catch { return false }
}

const prepareNavigation = () => document.dispatchEvent(new Event(WEREAD_NAVIGATION_EVENT))
const root = window as unknown as { __castReaderWeReadNative?: { snapshot: typeof snapshot; turn: typeof turn; prepareNavigation: typeof prepareNavigation; version: string } & ReturnType<typeof installWeReadNativeBridge> }
if (!root.__castReaderWeReadNative && location.hostname === 'weread.qq.com') {
  root.__castReaderWeReadNative = { snapshot, turn, prepareNavigation,
    ...installWeReadNativeBridge(), version: 'ios-native-pages-20260930-5' }
}
