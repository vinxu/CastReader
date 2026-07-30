// Google Play Books（play.google.com/books/reader）适配。
//
// 页面结构（与扩展 readout-desktop/src/extractors/play-books.ts 同一套契约）：
//
//   top: play.google.com/books/reader?id=<id>            ← 只有壳，没有正文
//    ↳ iframe: books.googleusercontent.com/books/reader/frame   ← 跨源，正文在这里
//       <reader-app>
//         <reader-rendered-page>          ← 一「页」；双栏时同时有两个
//           <div class="gb-segment">      ← 一个 segment（章）整段 DOM
//             <p class="para0">…</p>
//
// iOS 与扩展的两点关键差异：
//
// 1. **跨源 iframe**：native 的 `evaluateJavaScript` 只落在主帧。所以主帧装一个
//    `window.CR` 转发壳（postMessage → 子帧），阅读帧装真正的 `window.CR`。
//    子帧回 native 走 `webkit.messageHandlers`（子帧可用），不需要反向转发。
//
// 2. **可见区裁剪**：Google 把整个 segment 渲进 `reader-rendered-page` 再靠裁剪
//    分页，所以 `<p>.textContent` 往往是整段而不是当前页可见的那几行。朗读必须
//    只读可见部分，否则一页就把整章读完、翻页与高亮全错位。这里对每个段落用
//    二分查找求出可见字符区间 [sourceStart, sourceEnd)，并把最后一段延长到句末
//    （speechText）交给 native 做跨页断句。

export type PlayBooksPara = {
  text: string
  element: HTMLElement
  /** 已按可见区裁剪，cr-bridge 不得用 element.textContent 覆盖。 */
  exactText: true
  /** 可见文字在 element.textContent 内的起点（高亮字符偏移要加上它）。 */
  charOffset: number
  /** 同一 `<p>` 元素的稳定 id，跨页保持不变 → native 据此裁掉已读前缀。 */
  sourceParagraphIndex: number
  sourceStart: number
  sourceEnd: number
  /** 仅末段：补到自然句末的朗读文本（跨页断句）。 */
  speechText?: string
}

export type PlayBooksSpeechPreview = {
  /** DOM 原文的精确切片；不做空白归一化，坐标可直接交给 NSRange。 */
  text: string
  exactText: true
  sourceParagraphIndex: number
  /** UTF-16 code-unit offsets in the source `<p>.textContent`. */
  sourceStart: number
  sourceEnd: number
  contentFingerprint: string
}

const READER_PATH_SEGMENT = /(?:^|\/)books\/reader(?:\/|$)/
const PAGE_SEL = 'reader-rendered-page'
const SEGMENT_SEL = '.gb-segment'
const MIN_PARA_CHARS = 2
/** 跨页把句子补完时最多多读的字符数，防止碰到没有终止符的长段落。 */
const MAX_SENTENCE_LOOKAHEAD = 260
const FRAME_SESSION_PROPERTY = '__castreaderGBFrameSessionID'
const PAGE_EDGE_GUARD_CLASS = 'cr-gb-page-edge-guard'
/** A fragment must be essentially a whole text line/column before it belongs
 * to the current visual page. The 0.5px allowance absorbs device-pixel
 * rounding without accepting the visibly clipped line at Google's page edge. */
const COMPLETE_BLOCK_FRAGMENT_RATIO = 0.98
const COMPLETE_BLOCK_FRAGMENT_TOLERANCE = 0.5

/**
 * esbuild replaces this constant for each artifact:
 * - app/Release bundle: false, and the fixture branch is eliminated;
 * - CastReaderTests-only bundle: true.
 */
declare const __CASTREADER_XCTEST_FIXTURES__: boolean

type PlayBooksSessionWindow = Window & {
  __castreaderGBFrameSessionID?: string
}

/**
 * 一个 reader document 对应一个会话 id。Google 在换页/重排时会重建正文 DOM，但
 * window 不变，所以 id 必须挂在 window 而不能挂在 reader-rendered-page 上。
 * 同一 bundle 被意外重复注入时也复用已有值；不同 sibling frame 各有自己的 window，
 * 因而得到不同 id。
 */
export function playBooksFrameSessionID(): string {
  const target = window as PlayBooksSessionWindow
  if (target[FRAME_SESSION_PROPERTY]) return target[FRAME_SESSION_PROPERTY] as string
  let token = ''
  try {
    const cryptoObject = globalThis.crypto
    if (typeof cryptoObject?.randomUUID === 'function') {
      token = cryptoObject.randomUUID()
    } else if (cryptoObject?.getRandomValues) {
      const words = new Uint32Array(4)
      cryptoObject.getRandomValues(words)
      token = Array.from(words, (word) => word.toString(36)).join('-')
    }
  } catch { /* Math.random fallback below */ }
  if (!token) {
    token = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
  }
  const id = `gbf-${token}`
  try {
    Object.defineProperty(target, FRAME_SESSION_PROPERTY, {
      value: id,
      writable: false,
      configurable: false,
    })
  } catch {
    target[FRAME_SESSION_PROPERTY] = id
  }
  return id
}

export function isPlayBooksReaderFrame(): boolean {
  return (
    location.hostname === 'books.googleusercontent.com' &&
    READER_PATH_SEGMENT.test(location.pathname)
  )
}

/** 顶层壳。这里**永远不提取正文** —— Play 图书的主帧只有阅读器 UI，
 * 一旦交给通用 Visual Zone 提取器就会把按钮和菜单当成正文读出来。
 * 判定放宽到整个 play.google.com：跳转到书架/商店中间页时同样不能提取。 */
export function isPlayBooksShell(): boolean {
  return location.hostname === 'play.google.com'
}

function isGoogleRelayOrigin(origin: string): boolean {
  return /^https:\/\/([a-z0-9-]+\.)*(google\.com|googleusercontent\.com)$/.test(origin)
}

/**
 * Google 偶尔把真正 reader 再包进一个同属 Google 的容器 frame。跨源父页面不能
 * 继续读取该 WindowProxy 的 `.frames`，所以容器自己必须装逐层 forwarder。
 * `about:srcdoc` 分支也让离线 WKWebView fixture 能覆盖同一拓扑。
 */
export function isPlayBooksRelayContainer(): boolean {
  if (isPlayBooksShell()) return true
  if (isPlayBooksReaderFrame() || window === window.top) return false
  const host = location.hostname
  if (
    host === 'books.googleusercontent.com' ||
    host === 'books.google.com'
  ) {
    return true
  }
  if (location.protocol === 'about:') {
    try {
      const referrer = new URL(document.referrer)
      if (
        referrer.hostname === 'play.google.com' &&
        referrer.pathname.indexOf('/books') >= 0
      ) {
        return true
      }
    } catch { /* no referrer */ }
    // about:srcdoc 可没有 document.referrer，但会继承父 frame 的 origin。
    // 仅同源时读取 parent.location；真实跨源容器走上面的 host 分支。
    try {
      return window.parent.location.hostname === 'play.google.com' &&
        window.parent.location.pathname.indexOf('/books') >= 0
    } catch { /* cross-origin parent */ }
  }
  return false
}

// ---------------------------------------------------------------- 可见页选择

type Rect = { left: number; top: number; right: number; bottom: number }

function intersect(a: Rect, b: Rect): Rect | null {
  const left = Math.max(a.left, b.left)
  const top = Math.max(a.top, b.top)
  const right = Math.min(a.right, b.right)
  const bottom = Math.min(a.bottom, b.bottom)
  if (right <= left || bottom <= top) return null
  return { left, top, right, bottom }
}

function viewportRect(): Rect {
  return { left: 0, top: 0, right: window.innerWidth, bottom: window.innerHeight }
}

/** 可见的 rendered page（双栏返回两个，按 left 排序）。Google 会用多个候选尺寸
 * 渲同一 segment 做排版测量，测量副本几乎完全在屏外，用「交集/自身面积」筛掉。 */
export function pickVisiblePages(pages: HTMLElement[]): HTMLElement[] {
  if (pages.length === 0) return []
  const vp = viewportRect()
  const minArea = (vp.right - vp.left) * (vp.bottom - vp.top) * 0.05
  const cands: Array<{ el: HTMLElement; left: number }> = []
  for (const page of pages) {
    const r = page.getBoundingClientRect()
    if (r.width <= 0 || r.height <= 0) continue
    const hit = intersect(r, vp)
    if (!hit) continue
    const area = (hit.right - hit.left) * (hit.bottom - hit.top)
    if (area < minArea) continue
    if (area / (r.width * r.height) < 0.5) continue
    cands.push({ el: page, left: r.left })
  }
  if (cands.length === 0) {
    let best: HTMLElement | null = null
    let bestArea = -1
    for (const page of pages) {
      const r = page.getBoundingClientRect()
      if (r.width <= 0 || r.height <= 0) continue
      const hit = intersect(r, vp)
      const area = hit ? (hit.right - hit.left) * (hit.bottom - hit.top) : 0
      if (area > bestArea) { bestArea = area; best = page }
    }
    return best ? [best] : []
  }
  cands.sort((a, b) => a.left - b.left)
  return cands.map((c) => c.el)
}

function paragraphNodes(page: HTMLElement): HTMLElement[] {
  const tries = [
    `${SEGMENT_SEL} > p`,
    `${SEGMENT_SEL} p`,
    'p',
  ]
  for (const sel of tries) {
    const found = Array.from(page.querySelectorAll(sel)) as HTMLElement[]
    // 只保留最内层 p（`.gb-segment p` 在嵌套结构里可能重复命中祖先）。
    const leaves = found.filter((el) => !el.querySelector('p'))
    if (leaves.length > 0) return leaves
  }
  return []
}

// ------------------------------------------------------------ 可见字符区间

type TextBoundary = { node: Node; offset: number }

/** JavaScript 字符串、DOM Range 与 native 的 NSRange 都以 UTF-16 code unit 计数。 */
function textBoundaryAt(el: HTMLElement, index: number): TextBoundary | null {
  const doc = el.ownerDocument
  const walker = doc.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  let offset = 0
  let node: Node | null
  while ((node = walker.nextNode())) {
    const len = node.textContent?.length ?? 0
    if (index <= offset + len) return { node, offset: Math.max(0, index - offset) }
    offset += len
  }
  return null
}

function textRange(el: HTMLElement, start: number, end: number): Range | null {
  if (start < 0 || end <= start) return null
  const textLength = (el.textContent || '').length
  if (end > textLength) return null
  const startBoundary = textBoundaryAt(el, start)
  const endBoundary = textBoundaryAt(el, end)
  if (!startBoundary || !endBoundary) return null
  const range = el.ownerDocument.createRange()
  try {
    range.setStart(startBoundary.node, startBoundary.offset)
    range.setEnd(endBoundary.node, endBoundary.offset)
  } catch {
    return null
  }
  return range
}

function writingModeFor(el: HTMLElement): string {
  try {
    // Kobo reuses this geometry helper for elements owned by a same-origin
    // chapter iframe. Ask that element's own Window for style so cross-realm
    // nodes do not get measured against the top document.
    const style = el.ownerDocument.defaultView?.getComputedStyle(el) as
      (CSSStyleDeclaration & {
      webkitWritingMode?: string
      }) | undefined
    return style?.writingMode || style?.webkitWritingMode || 'horizontal-tb'
  } catch {
    return 'horizontal-tb'
  }
}

function isVerticalWritingMode(writingMode: string): boolean {
  return /^(vertical|sideways)/i.test(writingMode)
}

function rectHasCompleteBlockCoverage(
  rect: Rect,
  clip: Rect,
  writingMode: string
): boolean {
  const hit = intersect(rect, clip)
  if (!hit) return false
  const vertical = isVerticalWritingMode(writingMode)
  const full = vertical
    ? Math.max(0, rect.right - rect.left)
    : Math.max(0, rect.bottom - rect.top)
  const visible = vertical
    ? Math.max(0, hit.right - hit.left)
    : Math.max(0, hit.bottom - hit.top)
  if (full <= 0 || visible <= 0) return false
  return visible + COMPLETE_BLOCK_FRAGMENT_TOLERANCE >=
    full * COMPLETE_BLOCK_FRAGMENT_RATIO
}

/** 必须逐个 fragment 判断；Range.getBoundingClientRect() 会把左右两列之间的空洞
 * 也并入包围盒，导致水平 columns 的屏外文字被误判为可见。只露出页底一部分的
 * fragment 也不能算当前页，否则页面会显示/朗读/高亮半行文字。 */
function rangeHasCompleteBlockFragment(
  range: Range | null,
  clip: Rect,
  writingMode: string
): boolean {
  if (!range) return false
  const rects = range.getClientRects()
  for (let i = 0; i < rects.length; i++) {
    const r = rects[i]
    if (r.width <= 0 || r.height <= 0) continue
    if (rectHasCompleteBlockCoverage(r, clip, writingMode)) return true
  }
  return false
}

function alignStartToCodePoint(text: string, index: number): number {
  if (index <= 0 || index >= text.length) return index
  const current = text.charCodeAt(index)
  const previous = text.charCodeAt(index - 1)
  return current >= 0xDC00 && current <= 0xDFFF &&
    previous >= 0xD800 && previous <= 0xDBFF
    ? index - 1
    : index
}

function alignEndToCodePoint(text: string, index: number): number {
  if (index <= 0 || index >= text.length) return index
  const current = text.charCodeAt(index)
  const previous = text.charCodeAt(index - 1)
  return current >= 0xDC00 && current <= 0xDFFF &&
    previous >= 0xD800 && previous <= 0xDBFF
    ? index + 1
    : index
}

/**
 * 段落在 clip 内的 UTF-16 字符区间。
 *
 * Google 会用 translateY、translateX/CSS columns，日文还可能用 vertical writing。
 * 单个字符的 top/bottom 或 left/right 在这些布局间没有统一单调轴。这里改用两个
 * 与书写方向无关的单调问题：
 *   1. 最短的 DOM 前缀，何时第一次有 fragment 与 clip 相交；
 *   2. 最晚的 DOM 后缀起点，仍有 fragment 与 clip 相交。
 * Range.getClientRects() 已包含 transform 后的真实碎片坐标，因此同一算法覆盖三种布局。
 */
export function visibleCharRange(el: HTMLElement, clip: Rect): { start: number; end: number } | null {
  const text = el.textContent || ''
  if (text.length === 0) return null
  const writingMode = writingModeFor(el)
  if (!rangeHasCompleteBlockFragment(
    textRange(el, 0, text.length),
    clip,
    writingMode
  )) return null

  // prefix [0,end) 首次命中时，end - 1 就是第一个可见 code unit。
  let low = 1
  let high = text.length
  let firstPrefixEnd = text.length
  while (low <= high) {
    const mid = low + ((high - low) >> 1)
    if (rangeHasCompleteBlockFragment(
      textRange(el, 0, mid),
      clip,
      writingMode
    )) {
      firstPrefixEnd = mid
      high = mid - 1
    } else {
      low = mid + 1
    }
  }

  // suffix [start,length) 最晚仍命中时，start 就是最后一个可见 code unit。
  low = 0
  high = text.length - 1
  let lastSuffixStart = 0
  while (low <= high) {
    const mid = low + ((high - low) >> 1)
    if (rangeHasCompleteBlockFragment(
      textRange(el, mid, text.length),
      clip,
      writingMode
    )) {
      lastSuffixStart = mid
      low = mid + 1
    } else {
      high = mid - 1
    }
  }

  const start = alignStartToCodePoint(text, Math.max(0, firstPrefixEnd - 1))
  const end = alignEndToCodePoint(text, Math.min(text.length, lastSuffixStart + 1))
  return end > start ? { start, end } : null
}

/**
 * Returns every disjoint visible UTF-16 slice in DOM/source order.
 *
 * A CSS-column reflow can temporarily paint the beginning and end of one
 * paragraph in the viewport while an intervening column remains off screen.
 * `visibleCharRange` intentionally returns one bounding source interval, which
 * is useful for the stable single-column Google layout but would include that
 * invisible middle text. Kobo uses this stricter variant during rotation.
 */
export function visibleCharRanges(
  el: HTMLElement,
  clip: Rect
): Array<{ start: number; end: number }> {
  const text = el.textContent || ''
  if (text.length === 0) return []
  const writingMode = writingModeFor(el)
  const ranges: Array<{ start: number; end: number }> = []

  const hasVisibleFragment = (start: number, end: number): boolean =>
    rangeHasCompleteBlockFragment(
      textRange(el, start, end),
      clip,
      writingMode
    )

  const isFullyVisible = (start: number, end: number): boolean => {
    const range = textRange(el, start, end)
    if (!range) return false
    const rects = range.getClientRects()
    let sawRect = false
    for (let index = 0; index < rects.length; index++) {
      const rect = rects[index]
      if (rect.width <= 0 || rect.height <= 0) continue
      sawRect = true
      const hit = intersect(rect, clip)
      if (!hit) return false
      const blockComplete = rectHasCompleteBlockCoverage(
        rect,
        clip,
        writingMode
      )
      if (!blockComplete) return false
      // A range fragment may span several words. Requiring its inline extent
      // to remain inside the clip lets us accept whole visible chunks without
      // inspecting every character, while still splitting at column edges.
      if (
        hit.left > rect.left + 0.5 ||
        hit.right + 0.5 < rect.right ||
        hit.top > rect.top + 0.5 ||
        hit.bottom + 0.5 < rect.bottom
      ) return false
    }
    return sawRect
  }

  const append = (start: number, end: number): void => {
    const alignedStart = alignStartToCodePoint(text, start)
    const alignedEnd = alignEndToCodePoint(text, end)
    if (alignedEnd <= alignedStart) return
    const prior = ranges[ranges.length - 1]
    if (prior && alignedStart <= prior.end) {
      prior.end = Math.max(prior.end, alignedEnd)
      return
    }
    ranges.push({ start: alignedStart, end: alignedEnd })
  }

  const visit = (start: number, end: number): void => {
    if (end <= start || !hasVisibleFragment(start, end)) return
    if (isFullyVisible(start, end)) {
      append(start, end)
      return
    }
    if (end - start <= 16) {
      let cursor = start
      while (cursor < end) {
        const next = alignEndToCodePoint(text, cursor + 1)
        // A glyph whose rect merely grazes the viewport boundary belongs to
        // the adjacent CSS column. Treating that sliver as visible created a
        // run of 2–5 character "paragraphs" after Kobo rotated to landscape.
        if (isFullyVisible(cursor, Math.min(end, next))) {
          append(cursor, Math.min(end, next))
        }
        cursor = Math.max(cursor + 1, next)
      }
      return
    }
    let middle = start + ((end - start) >> 1)
    middle = alignEndToCodePoint(text, middle)
    if (middle <= start || middle >= end) middle = start + 1
    visit(start, middle)
    visit(middle, end)
  }

  visit(0, text.length)

  // Whitespace can have no client rect even when it merely separates two
  // visible words on the same line. Preserve a short whitespace-only gap so
  // independent slices never concatenate English words.
  const merged: Array<{ start: number; end: number }> = []
  for (const range of ranges) {
    const prior = merged[merged.length - 1]
    const gap = prior ? text.slice(prior.end, range.start) : ''
    if (prior && gap.length <= 8 && /^\s*$/.test(gap)) {
      prior.end = range.end
    } else {
      merged.push({ ...range })
    }
  }

  // Kobo's animated column transform can leave a few completely painted
  // glyphs from the neighbouring page just inside the clip. They form a very
  // short partial source slice flush against the viewport edge. A real short
  // paragraph has start=0/end=text.length and is retained; only partial edge
  // slivers are discarded.
  return merged.filter((range) => {
    const partial = range.start > 0 || range.end < text.length
    if (!partial || range.end - range.start > 18) return true
    const domRange = textRange(el, range.start, range.end)
    if (!domRange) return false
    const rects = domRange.getClientRects()
    if (rects.length === 0) return false
    let inlineStart = Number.POSITIVE_INFINITY
    let inlineEnd = Number.NEGATIVE_INFINITY
    for (let index = 0; index < rects.length; index++) {
      const rect = rects[index]
      if (rect.width <= 0 || rect.height <= 0) continue
      if (isVerticalWritingMode(writingMode)) {
        inlineStart = Math.min(inlineStart, rect.top)
        inlineEnd = Math.max(inlineEnd, rect.bottom)
      } else {
        inlineStart = Math.min(inlineStart, rect.left)
        inlineEnd = Math.max(inlineEnd, rect.right)
      }
    }
    if (!Number.isFinite(inlineStart) || !Number.isFinite(inlineEnd)) {
      return false
    }
    const clipStart = isVerticalWritingMode(writingMode)
      ? clip.top
      : clip.left
    const clipEnd = isVerticalWritingMode(writingMode)
      ? clip.bottom
      : clip.right
    const edgeTolerance = 8
    return inlineStart > clipStart + edgeTolerance &&
      inlineEnd < clipEnd - edgeTolerance
  })
}

// ------------------------------------------------------------------ 句界

const SENTENCE_ENDERS = '。！？；…!?;.।॥'
const TRAILING = '”"\'’」』）)】》〉]'

function endsAtSentence(text: string): boolean {
  for (let i = text.length - 1; i >= 0; i--) {
    const ch = text[i]
    if (/\s/.test(ch) || TRAILING.indexOf(ch) >= 0) continue
    return SENTENCE_ENDERS.indexOf(ch) >= 0
  }
  return true
}

/** 可见文字止于句中时，向后补到自然句末（上限 MAX_SENTENCE_LOOKAHEAD）。 */
export function extendToSentenceEnd(full: string, visibleEnd: number): number {
  if (visibleEnd >= full.length) return visibleEnd
  const limit = Math.min(full.length, visibleEnd + MAX_SENTENCE_LOOKAHEAD)
  for (let i = visibleEnd; i < limit; i++) {
    if (SENTENCE_ENDERS.indexOf(full[i]) >= 0) {
      let end = i + 1
      while (end < full.length && TRAILING.indexOf(full[end]) >= 0) end++
      return end
    }
  }
  return visibleEnd
}

// ------------------------------------------------------------------ 提取

function normalizedIdentityText(text: string): string {
  const normalized = text.replace(/\s+/g, ' ').trim()
  return `${normalized.length}:${normalized.slice(0, 96)}:${normalized.slice(-96)}`
}

/** 只取逻辑属性，明确排除 style/transform 与 CR 自己写入的临时属性。 */
function logicalAttributes(el: HTMLElement): string {
  const out: string[] = []
  for (const attr of Array.from(el.attributes)) {
    const name = attr.name.toLowerCase()
    if (name.indexOf('data-cr-') === 0) continue
    const logicalData = name.indexOf('data-') === 0 &&
      /(id|key|index|chapter|segment|spine|para)/.test(name)
    if (name === 'id' || name === 'class' || logicalData) {
      out.push(`${name}=${attr.value}`)
    }
  }
  return out.sort().join('&')
}

function stableHash32(value: string): number {
  let hash = 0x811C9DC5
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }
  return hash >>> 0
}

/**
 * Google 在翻页或字号变化时会 clone/recreate 整个 segment，元素属性上的自增 id 会丢失。
 * 用「segment 逻辑身份 + 段落序号/内容身份」算确定性哈希，DOM clone 后仍是同一来源段。
 */
function sourceID(el: HTMLElement): number {
  const segment = el.closest(SEGMENT_SEL) as HTMLElement | null
  const scope = segment || el.parentElement || el
  const paragraphs = Array.from(scope.querySelectorAll('p'))
    .filter((p) => !p.querySelector('p'))
  const ordinal = Math.max(0, paragraphs.indexOf(el))
  const segmentIdentity = [
    logicalAttributes(scope),
    normalizedIdentityText(scope.textContent || ''),
  ].join('|')
  const paragraphIdentity = [
    ordinal,
    logicalAttributes(el),
    normalizedIdentityText(el.textContent || ''),
  ].join('|')
  return stableHash32(`segment:${segmentIdentity}\u241Fparagraph:${paragraphIdentity}`) || 1
}

type PlayBooksPageClip = {
  page: HTMLElement
  clip: Rect
}

function currentPlayBooksPageClips(): PlayBooksPageClip[] {
  const pages = pickVisiblePages(Array.from(document.querySelectorAll(PAGE_SEL)) as HTMLElement[])
  const vp = viewportRect()
  return pages.flatMap((page): PlayBooksPageClip[] => {
    const pr = page.getBoundingClientRect()
    const clip = intersect(
      { left: pr.left, top: pr.top, right: pr.right, bottom: pr.bottom },
      vp
    )
    return clip ? [{ page, clip }] : []
  })
}

function clearPlayBooksPageEdgeGuards(): void {
  document.querySelectorAll(`.${PAGE_EDGE_GUARD_CLASS}`).forEach((node) => {
    node.remove()
  })
}

function opaquePageBackground(page: HTMLElement): string | null {
  let element: HTMLElement | null = page
  while (element) {
    try {
      const style = getComputedStyle(element)
      if (style.backgroundImage && style.backgroundImage !== 'none') return null
      const color = style.backgroundColor
      const rgb = color.match(/^rgba?\(\s*[\d.]+\s*,\s*[\d.]+\s*,\s*[\d.]+(?:\s*,\s*([\d.]+))?\s*\)$/i)
      if (rgb && (rgb[1] === undefined || Number(rgb[1]) >= 0.999)) {
        return color
      }
    } catch {
      return null
    }
    element = element.parentElement
  }
  return null
}

/**
 * Google occasionally leaves the final text fragment crossing its own
 * rendered-page clip. Cover only that dynamically measured fragment so the
 * whole line moves to the next page visually; never resize or restyle Google's
 * page/segment, because doing so would invalidate its pagination coordinates.
 */
function refreshPlayBooksPageEdgeGuards(
  pageClips: PlayBooksPageClip[]
): void {
  clearPlayBooksPageEdgeGuards()
  const seen = new Set<string>()

  for (const { page, clip } of pageClips) {
    const background = opaquePageBackground(page)
    if (!background) continue
    for (const el of paragraphNodes(page)) {
      const fullRange = textRange(el, 0, (el.textContent || '').length)
      if (!fullRange) continue
      const writingMode = writingModeFor(el)
      const vertical = isVerticalWritingMode(writingMode)
      for (const rect of Array.from(fullRange.getClientRects())) {
        if (rect.width <= 0 || rect.height <= 0) continue
        const hit = intersect(rect, clip)
        if (!hit || rectHasCompleteBlockCoverage(rect, clip, writingMode)) continue

        const crossesLeadingEdge = vertical
          ? rect.left < clip.left && rect.right > clip.left
          : rect.top < clip.top && rect.bottom > clip.top
        const crossesTrailingEdge = vertical
          ? rect.left < clip.right && rect.right > clip.right
          : rect.top < clip.bottom && rect.bottom > clip.bottom
        if (!crossesLeadingEdge && !crossesTrailingEdge) continue

        const guardRect: Rect = vertical
          ? {
              left: crossesLeadingEdge ? clip.left : Math.max(rect.left, clip.left),
              right: crossesLeadingEdge ? Math.min(rect.right, clip.right) : clip.right,
              top: clip.top,
              bottom: clip.bottom,
            }
          : {
              left: clip.left,
              right: clip.right,
              top: crossesLeadingEdge ? clip.top : Math.max(rect.top, clip.top),
              bottom: crossesLeadingEdge ? Math.min(rect.bottom, clip.bottom) : clip.bottom,
            }
        const width = guardRect.right - guardRect.left
        const height = guardRect.bottom - guardRect.top
        if (width <= 0 || height <= 0) continue
        const key = [
          Math.round(guardRect.left * 2),
          Math.round(guardRect.top * 2),
          Math.round(guardRect.right * 2),
          Math.round(guardRect.bottom * 2),
        ].join(':')
        if (seen.has(key)) continue
        seen.add(key)

        const guard = document.createElement('div')
        guard.className = PAGE_EDGE_GUARD_CLASS
        guard.setAttribute('aria-hidden', 'true')
        guard.style.cssText =
          `position:fixed;left:${guardRect.left}px;top:${guardRect.top}px;` +
          `width:${width}px;height:${height}px;background:${background};` +
          'pointer-events:none;z-index:2147483646'
        document.body.appendChild(guard)
      }
    }
  }
}

/** Shared with the native-driven overlay renderer: extended cross-page speech
 * may address source text beyond the visible slice, but a clipped fragment
 * must never receive a highlight on the current visual page. */
export function acceptPlayBooksHighlightRect(
  el: HTMLElement,
  rect: DOMRect
): boolean {
  const page = el.closest(PAGE_SEL) as HTMLElement | null
  if (!page) return false
  const visiblePages = pickVisiblePages(
    Array.from(document.querySelectorAll(PAGE_SEL)) as HTMLElement[]
  )
  if (!visiblePages.includes(page)) return false
  const pageRect = page.getBoundingClientRect()
  const clip = intersect(
    {
      left: pageRect.left,
      top: pageRect.top,
      right: pageRect.right,
      bottom: pageRect.bottom,
    },
    viewportRect()
  )
  return !!clip && rectHasCompleteBlockCoverage(
    rect,
    clip,
    writingModeFor(el)
  )
}

/**
 * Extract against explicit clipping rectangles. Preview uses virtual clips
 * adjacent to the current viewport, so this helper must not mutate
 * `data-cr-para` or any bridge/highlight state.
 */
function extractPlayBooksParagraphsFromClips(
  pageClips: PlayBooksPageClip[]
): PlayBooksPara[] {
  const out: PlayBooksPara[] = []
  const seen = new Set<string>()

  for (const { page, clip } of pageClips) {
    for (const el of paragraphNodes(page)) {
      const full = el.textContent || ''
      if (full.trim().length < MIN_PARA_CHARS) continue
      const range = visibleCharRange(el, clip)
      if (!range) continue
      const raw = full.slice(range.start, range.end)
      const withoutLeading = raw.trimStart()
      const leadingUTF16 = raw.length - withoutLeading.length
      const text = withoutLeading.trimEnd()
      if (text.length < MIN_PARA_CHARS) continue
      const sourceStart = range.start + leadingUTF16
      const sourceEnd = sourceStart + text.length
      const id = sourceID(el)
      const key = `${id}:${sourceStart}:${sourceEnd}`
      if (seen.has(key)) continue
      seen.add(key)
      out.push({
        text,
        element: el,
        exactText: true,
        charOffset: sourceStart,
        sourceParagraphIndex: id,
        sourceStart,
        sourceEnd,
      })
    }
  }

  // 末段跨页断句：可见文字停在句中时补到句末，native 用它决定「多读一句再翻页」。
  const tail = out[out.length - 1]
  if (tail && !endsAtSentence(tail.text)) {
    const full = tail.element.textContent || ''
    const extendedEnd = extendToSentenceEnd(full, tail.sourceEnd)
    if (extendedEnd > tail.sourceEnd) {
      tail.speechText = full.slice(tail.sourceStart, extendedEnd).trimEnd()
    }
  }
  return out
}

export function extractPlayBooksParagraphs(): PlayBooksPara[] {
  const pageClips = currentPlayBooksPageClips()
  refreshPlayBooksPageEdgeGuards(pageClips)
  return extractPlayBooksParagraphsFromClips(pageClips)
}

function shiftedClip(value: PlayBooksPageClip, dx: number, dy: number): PlayBooksPageClip {
  return {
    page: value.page,
    clip: {
      left: value.clip.left + dx,
      right: value.clip.right + dx,
      top: value.clip.top + dy,
      bottom: value.clip.bottom + dy,
    },
  }
}

function isForwardPreview(
  current: PlayBooksPara[],
  candidate: PlayBooksPara[]
): boolean {
  const tail = current[current.length - 1]
  const head = candidate[0]
  if (!tail || !head) return false
  if (tail.sourceParagraphIndex === head.sourceParagraphIndex) {
    // Range fragments can share one UTF-16 boundary at a clipped line edge.
    return head.sourceStart >= tail.sourceEnd - 2
  }
  const position = tail.element.compareDocumentPosition(head.element)
  return (position & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
}

function previewAdvanceRank(
  current: PlayBooksPara[],
  candidate: PlayBooksPara[]
): number {
  const tail = current[current.length - 1]
  const head = candidate[0]
  if (!tail || !head) return Number.MAX_SAFE_INTEGER
  if (tail.sourceParagraphIndex === head.sourceParagraphIndex) {
    return Math.max(0, head.sourceStart - tail.sourceEnd)
  }
  // A later paragraph is preferable to a much later virtual column/page.
  let hops = 1
  let node: Element | null = tail.element
  while (node && node !== head.element && hops < 1000) {
    node = node.nextElementSibling
    hops++
  }
  return hops * 1_000_000 + head.sourceStart
}

function candidateFingerprint(paras: PlayBooksPara[]): string {
  const value = paras.map((p) => [
    p.sourceParagraphIndex,
    p.sourceStart,
    p.sourceEnd,
    p.text,
  ].join(':')).join('\u241E')
  return stableHash32(value).toString(16).padStart(8, '0')
}

function sourceSpeechEnd(para: PlayBooksPara): number {
  if (!para.speechText) return para.sourceEnd
  return Math.min(
    (para.element.textContent || '').length,
    para.sourceStart + para.speechText.length
  )
}

function skipSentenceBoundary(text: string, cursor: number): number {
  let start = alignEndToCodePoint(text, Math.max(0, Math.min(text.length, cursor)))
  while (start < text.length) {
    const ch = text[start]
    // `sourceEnd` can land immediately before a closing quote at the page edge.
    // That quote belongs to the sentence just spoken, never to the next preview.
    if (!/\s/.test(ch) && TRAILING.indexOf(ch) < 0) break
    start++
  }
  return alignEndToCodePoint(text, start)
}

/**
 * Returns one complete, exact source sentence. A short paragraph without an
 * explicit terminator is itself a natural speech unit; a long unterminated
 * remainder fails closed so a preview can never skip unread source text.
 */
function nextNaturalSentenceRange(
  text: string,
  cursor: number
): { start: number; end: number } | null {
  const start = skipSentenceBoundary(text, cursor)
  if (text.slice(start).trim().length < MIN_PARA_CHARS) return null
  const limit = Math.min(text.length, start + MAX_SENTENCE_LOOKAHEAD)
  for (let i = start; i < limit; i++) {
    if (SENTENCE_ENDERS.indexOf(text[i]) < 0) continue
    let end = i + 1
    while (end < text.length && TRAILING.indexOf(text[end]) >= 0) end++
    return { start, end: alignEndToCodePoint(text, end) }
  }

  let paragraphEnd = text.length
  while (paragraphEnd > start && /\s/.test(text[paragraphEnd - 1])) paragraphEnd--
  if (
    paragraphEnd > start &&
    paragraphEnd - start <= MAX_SENTENCE_LOOKAHEAD
  ) {
    return { start, end: alignEndToCodePoint(text, paragraphEnd) }
  }
  return null
}

/**
 * Geometry preview can miss when Google has not materialized the next CSS
 * column yet. In that case this read-only fallback follows the current tail's
 * *same real `.gb-segment` source stream* and returns only its next natural
 * sentence. It never scrolls, turns, focuses, styles, or writes to the DOM.
 */
export function extractPlayBooksNextSpeechPreview(): PlayBooksSpeechPreview | null {
  const current = extractPlayBooksParagraphs()
  const tail = current[current.length - 1]
  if (!tail) return null
  const segment = tail.element.closest(SEGMENT_SEL) as HTMLElement | null
  if (!segment) return null
  const leafParagraphs = (candidate: HTMLElement): HTMLElement[] =>
    Array.from(candidate.querySelectorAll('p'))
      .filter((el) => !el.querySelector('p')) as HTMLElement[]
  const previewFrom = (
    paragraphs: HTMLElement[],
    firstIndex: number,
    firstCursor: number
  ): { preview: PlayBooksSpeechPreview | null; blocked: boolean } => {
    for (let index = firstIndex; index < paragraphs.length; index++) {
      const element = paragraphs[index]
      const full = element.textContent || ''
      const cursor = index === firstIndex ? firstCursor : 0
      const readableStart = skipSentenceBoundary(full, cursor)
      if (full.slice(readableStart).trim().length < MIN_PARA_CHARS) continue

      // Do not jump across a long unterminated remainder into a later
      // paragraph or segment. Exact native verification is a second fence,
      // never permission to skip unread source here.
      const range = nextNaturalSentenceRange(full, cursor)
      if (!range) return { preview: null, blocked: true }
      const text = full.slice(range.start, range.end)
      if (text.trim().length < MIN_PARA_CHARS) {
        return { preview: null, blocked: true }
      }
      const sourceParagraphIndex = sourceID(element)
      const value = [
        sourceParagraphIndex,
        range.start,
        range.end,
        text,
      ].join(':')
      return {
        preview: {
          text,
          exactText: true,
          sourceParagraphIndex,
          sourceStart: range.start,
          sourceEnd: range.end,
          contentFingerprint: stableHash32(value).toString(16).padStart(8, '0'),
        },
        blocked: false,
      }
    }
    return { preview: null, blocked: false }
  }

  const paragraphs = leafParagraphs(segment)
  const tailIndex = paragraphs.indexOf(tail.element)
  if (tailIndex < 0) return null
  const sameSegment = previewFrom(
    paragraphs,
    tailIndex,
    sourceSpeechEnd(tail)
  )
  if (sameSegment.preview || sameSegment.blocked) {
    return sameSegment.preview
  }

  // Production sometimes keeps the next immutable source block in a later
  // `.gb-segment` while withholding all off-viewport Range geometry. Walk
  // forward in document order only. Measurement clones of the current/next
  // segment are skipped by deterministic paragraph identity; a wrong future
  // block still cannot become audible because native must match these exact
  // source coordinates against the real automatic commit.
  const allSegments = Array.from(
    document.querySelectorAll(`${PAGE_SEL} ${SEGMENT_SEL}`)
  ) as HTMLElement[]
  const currentIndex = allSegments.indexOf(segment)
  if (currentIndex < 0) return null
  const seenSourceHeads = new Set<number>()
  const currentHead = paragraphs[0]
  if (currentHead) seenSourceHeads.add(sourceID(currentHead))
  for (let index = currentIndex + 1; index < allSegments.length; index++) {
    const candidateParagraphs = leafParagraphs(allSegments[index])
    const head = candidateParagraphs[0]
    if (!head) continue
    const headID = sourceID(head)
    if (seenSourceHeads.has(headID)) continue
    seenSourceHeads.add(headID)
    const result = previewFrom(candidateParagraphs, 0, 0)
    if (result.preview || result.blocked) return result.preview
  }
  return null
}

/**
 * Google normally keeps at least one adjacent CSS column in the same segment.
 * Read that virtual clip without turning the page. Some layouts instead keep
 * a nearby off-screen `reader-rendered-page`, which is considered as a second
 * source. Far-away measurement clones are deliberately ignored.
 */
export function extractPlayBooksNextPagePreview(): {
  paragraphs: PlayBooksPara[]
  contentFingerprint: string
} | null {
  const currentClips = currentPlayBooksPageClips()
  const current = extractPlayBooksParagraphsFromClips(currentClips)
  if (currentClips.length === 0 || current.length === 0) return null

  const vp = viewportRect()
  const viewportWidth = Math.max(1, vp.right - vp.left)
  const viewportHeight = Math.max(1, vp.bottom - vp.top)
  const firstSegment = currentClips[0].page.querySelector(SEGMENT_SEL) as HTMLElement | null
  const style = firstSegment
    ? (firstSegment.ownerDocument.defaultView || window).getComputedStyle(firstSegment)
    : null
  const columnWidth = style ? Number.parseFloat(style.columnWidth) : Number.NaN
  const columnGap = style ? Number.parseFloat(style.columnGap) : Number.NaN
  const horizontalStep =
    Number.isFinite(columnWidth) && columnWidth > 0
      ? columnWidth + (Number.isFinite(columnGap) ? Math.max(0, columnGap) : 0)
      : viewportWidth

  const candidateClips: PlayBooksPageClip[][] = [
    currentClips.map((value) => shiftedClip(value, horizontalStep, 0)),
    currentClips.map((value) => shiftedClip(value, 0, viewportHeight)),
    // RTL / vertical Japanese layouts can advance towards the visual left.
    currentClips.map((value) => shiftedClip(value, -horizontalStep, 0)),
    currentClips.map((value) => shiftedClip(value, 0, -viewportHeight)),
  ]

  const visibleSet = new Set(currentClips.map((value) => value.page))
  const maxNearX = viewportWidth * 1.75
  const maxNearY = viewportHeight * 1.75
  for (const page of Array.from(document.querySelectorAll(PAGE_SEL)) as HTMLElement[]) {
    if (visibleSet.has(page)) continue
    const r = page.getBoundingClientRect()
    if (r.width <= 0 || r.height <= 0) continue
    const horizontalDistance =
      r.left >= vp.right ? r.left - vp.right
        : r.right <= vp.left ? vp.left - r.right
          : 0
    const verticalDistance =
      r.top >= vp.bottom ? r.top - vp.bottom
        : r.bottom <= vp.top ? vp.top - r.bottom
          : 0
    if (horizontalDistance > maxNearX || verticalDistance > maxNearY) continue
    candidateClips.push([{
      page,
      clip: { left: r.left, top: r.top, right: r.right, bottom: r.bottom },
    }])
  }

  const currentKey = candidateFingerprint(current)
  const candidates = candidateClips
    .map((clips) => extractPlayBooksParagraphsFromClips(clips))
    .filter((paras) =>
      paras.length > 0 &&
      candidateFingerprint(paras) !== currentKey &&
      isForwardPreview(current, paras)
    )
    .sort((left, right) =>
      previewAdvanceRank(current, left) - previewAdvanceRank(current, right)
    )
  const paragraphs = candidates[0]
  return paragraphs?.length
    ? { paragraphs, contentFingerprint: candidateFingerprint(paragraphs) }
    : null
}

// --------------------------------------------------------------- 翻页 / 监听

function clickablePageButton(direction: 'next' | 'prev'): HTMLElement | null {
  const selectors = direction === 'next'
    ? [
        'button[aria-label="Next Page"]',
        'button[aria-label*="next page" i]',
        '[role="button"][aria-label*="next page" i]',
        '[aria-label*="次のページ"]',
        '[aria-label*="下一页"]',
        '[aria-label*="下一頁"]',
        '.next-page-button',
        '#next-page',
      ]
    : [
        'button[aria-label="Previous Page"]',
        'button[aria-label*="previous page" i]',
        'button[aria-label*="prev page" i]',
        '[role="button"][aria-label*="previous page" i]',
        '[aria-label*="前のページ"]',
        '[aria-label*="上一页"]',
        '[aria-label*="上一頁"]',
        '.previous-page-button',
        '.prev-page-button',
        '#previous-page',
        '#prev-page',
      ]
  for (const sel of selectors) {
    const el = document.querySelector(sel)
    if (!(el instanceof HTMLElement)) continue
    if (el.getAttribute('aria-disabled') === 'true') continue
    if (el instanceof HTMLButtonElement && el.disabled) continue
    const style = (el.ownerDocument.defaultView || window).getComputedStyle(el)
    if (style.display === 'none' || style.visibility === 'hidden') continue
    const rect = el.getBoundingClientRect()
    if (!intersect(
      { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom },
      viewportRect()
    )) continue
    return el
  }
  return null
}

export type PlayBooksTurnMethod = 'button' | 'key' | 'hotspot' | 'none'

/** **一次只做一种动作。** 三种手段同时发出去会翻两页 —— 一整页书就这样被跳过了。
 * 升级到下一种手段是调用方的事，且必须先确认可见区指纹没有变化。 */
export function turnPlayBooksPage(
  direction: 'next' | 'prev',
  method: PlayBooksTurnMethod
): PlayBooksTurnMethod {
  if (method === 'button') {
    const button = clickablePageButton(direction)
    if (!button) return 'none'
    button.click()
    return 'button'
  }
  if (method === 'key') {
    const key = direction === 'next' ? 'ArrowRight' : 'ArrowLeft'
    const code = direction === 'next' ? 39 : 37
    const target = document.activeElement instanceof HTMLElement ? document.activeElement : document.body
    const opts = { key, code: key, keyCode: code, which: code, bubbles: true, cancelable: true }
    try {
      target.dispatchEvent(new KeyboardEvent('keydown', opts as KeyboardEventInit))
      target.dispatchEvent(new KeyboardEvent('keyup', opts as KeyboardEventInit))
    } catch { return 'none' }
    return 'key'
  }
  if (method === 'hotspot') {
    // 移动端阅读器通常只认页面左右两侧的点击热区。
    const x = direction === 'next' ? window.innerWidth * 0.9 : window.innerWidth * 0.1
    const y = window.innerHeight * 0.5
    const hit = document.elementFromPoint(x, y)
    if (!(hit instanceof HTMLElement)) return 'none'
    const common = { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window }
    try {
      hit.dispatchEvent(new MouseEvent('mousedown', common))
      hit.dispatchEvent(new MouseEvent('mouseup', common))
      hit.dispatchEvent(new MouseEvent('click', common))
    } catch { return 'none' }
    return 'hotspot'
  }
  return 'none'
}

/** 便宜的页面指纹：不做二分，只看可见 page 的几何 + segment 位移 + 文本头尾。 */
export function playBooksSignature(): string {
  const pages = pickVisiblePages(Array.from(document.querySelectorAll(PAGE_SEL)) as HTMLElement[])
  if (pages.length === 0) return ''
  const parts: string[] = []
  for (const page of pages) {
    const r = page.getBoundingClientRect()
    const segment = page.querySelector(SEGMENT_SEL) as HTMLElement | null
    const sr = segment ? segment.getBoundingClientRect() : null
    const text = (page.textContent || '')
    parts.push(
      [
        Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height),
        sr ? Math.round(sr.top) : 0,
        sr ? Math.round(sr.left) : 0,
        text.length,
        text.slice(0, 48).replace(/\s+/g, ' '),
      ].join(',')
    )
  }
  return parts.join('|')
}

type Poster = (type: string, payload?: Record<string, unknown>) => void

type PlayBooksAutomaticTurnMetadata = {
  turnID: string
  baselineSignature: string
  originFrameSessionID: string
}

type PlayBooksManualTurnMetadata = {
  manualIntentID: string
  baselineSignature: string
  originFrameSessionID: string
}

type PlayBooksTurnMetadata =
  | PlayBooksAutomaticTurnMetadata
  | PlayBooksManualTurnMetadata

type PlayBooksLateAutomaticTurn = {
  metadata: PlayBooksAutomaticTurnMetadata
  /** Geometry baseline used only to detect the next visual departure. */
  detectionBaselineSignature: string
  expiresAt: number
}

const AUTO_TURN_TOMBSTONE_TTL_MS = 30_000

function protocolID(prefix: string): string {
  try {
    if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
      return `${prefix}-${crypto.randomUUID()}`
    }
  } catch { /* older WKWebView */ }
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

function recordArg(arg: unknown): Record<string, unknown> {
  return arg && typeof arg === 'object' ? arg as Record<string, unknown> : {}
}

function nonemptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null
}

/**
 * Page signatures are opaque geometry/content identities, not user text.
 * Whitespace at either edge is significant because the final signature field
 * is a literal DOM-text slice. Use trim only to reject an empty value, then
 * preserve every code unit for the native round-trip comparison.
 */
function nonemptyOpaqueString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

function announceTurnOwner(metadata: PlayBooksTurnMetadata): void {
  if (window === window.parent) return
  try {
    window.parent.postMessage({
      __castreaderGB: 1,
      kind: 'turn-owner',
      arg: metadata,
    }, '*')
  } catch { /* parent can disappear during iframe replacement */ }
}

/** 阅读帧：装 CR.gb* API + 翻页/手动翻页监听。`requestExtract` 由 cr-bridge 提供。 */
export function installPlayBooksReader(
  post: Poster,
  requestExtract: (reason: string, metadata?: Record<string, unknown>) => void,
  frameSessionID: string = playBooksFrameSessionID()
): void {
  const postForFrame = (type: string, payload: Record<string, unknown> = {}): void => {
    post(type, { ...payload, frameSessionID })
  }
  const STABILITY_POLL_MS = 180
  const MIN_STABLE_MS = 420
  let committedSignature = playBooksSignature()
  let observedSignature = committedSignature
  let pendingAuto = false
  let pendingAutoMetadata: PlayBooksAutomaticTurnMetadata | null = null
  let lateAutoTurn: PlayBooksLateAutomaticTurn | null = null
  let settleTimer: ReturnType<typeof setTimeout> | null = null
  let turnConfirmationTimer: ReturnType<typeof setTimeout> | null = null
  let lastManualIntentAt = 0
  let pendingManualIntent = false
  let manualIntentExpiresAt = 0
  let manualIntentBaseline = ''
  let manualIntentMetadata: PlayBooksManualTurnMetadata | null = null
  let pendingTurnMethod: PlayBooksTurnMethod | null = null
  let pendingTurnBaseline = ''
  // CSS 翻页动画可能连续改变多次几何；整段动画只能保留第一次判定出的 auto/manual 原因。
  let changeReasonInFlight: string | null = null
  let changeBaseline = ''
  let changeMetadata: PlayBooksTurnMetadata | null = null
  let settleCandidate = ''
  let settleCandidateSince = 0
  let settleStableSamples = 0
  let manualSwipeActive = false
  let previewTimer: ReturnType<typeof setTimeout> | null = null
  let lastPreviewToken = ''
  let lastGeometryPreviewMissToken = ''
  let lastSpeechPreviewToken = ''

  const clearPageVisuals = (): void => {
    const bridge = (window as unknown as {
      CR?: Record<string, (arg?: unknown) => void>
    }).CR
    try { bridge?.clearHighlight?.({}) } catch { /* stale frame */ }
    try { bridge?.clearMarks?.({}) } catch { /* stale frame */ }
    clearPlayBooksPageEdgeGuards()
  }

  // 上一次经「指纹确实变化」证明有效的手段；请求发出时不能提前认定成功。
  let preferredMethod: PlayBooksTurnMethod | null = null

  const scheduleNextPagePreview = (attempt = 0): void => {
    if (previewTimer) clearTimeout(previewTimer)
    previewTimer = setTimeout(() => {
      previewTimer = null
      if (
        pendingAuto ||
        pendingManualIntent ||
        manualSwipeActive ||
        changeReasonInFlight !== null
      ) return
      const sourceSignature = committedSignature || playBooksSignature()
      if (!sourceSignature) return
      const preview = extractPlayBooksNextPagePreview()
      if (!preview || preview.paragraphs.length === 0) {
        if (sourceSignature !== lastGeometryPreviewMissToken) {
          lastGeometryPreviewMissToken = sourceSignature
          postForFrame('googleBooksPreviewDiagnostic', {
            event: 'geometry-miss',
            sourceSignature,
            attempt,
          })
        }
        const speechPreview = extractPlayBooksNextSpeechPreview()
        if (speechPreview) {
          const speechToken =
            `${sourceSignature}|${speechPreview.contentFingerprint}`
          if (speechToken !== lastSpeechPreviewToken) {
            lastSpeechPreviewToken = speechToken
            postForFrame('googleBooksSpeechPreview', {
              sourceSignature,
              originFrameSessionID: frameSessionID,
              exactText: true,
              sourceParagraphIndex: speechPreview.sourceParagraphIndex,
              sourceUTF16Start: speechPreview.sourceStart,
              sourceUTF16End: speechPreview.sourceEnd,
              text: speechPreview.text,
              contentFingerprint: speechPreview.contentFingerprint,
            })
            postForFrame('googleBooksPreviewDiagnostic', {
              event: 'source-preview',
              sourceSignature,
              sourceParagraphIndex: speechPreview.sourceParagraphIndex,
              sourceUTF16Start: speechPreview.sourceStart,
              sourceUTF16End: speechPreview.sourceEnd,
              contentFingerprint: speechPreview.contentFingerprint,
            })
          }
        }
        // Google often materializes the adjacent CSS column shortly after the
        // visible one. Keep observing for the whole spoken page instead of
        // giving up after ~2 seconds; long pages frequently materialize their
        // neighbour only after fonts/images settle. Observation is read-only:
        // never click, synthesize a key, scroll, or alter the page transform.
        scheduleNextPagePreview(attempt + 1)
        return
      }
      const token = `${sourceSignature}|${preview.contentFingerprint}`
      if (token === lastPreviewToken) return
      lastPreviewToken = token
      const paragraphs = preview.paragraphs.map((p, paragraphIndex) => {
        const row: Record<string, unknown> = {
          paragraphIndex,
          text: p.text,
          type: 'paragraph',
          sourceParagraphIndex: p.sourceParagraphIndex,
          sourceUTF16Start: p.sourceStart,
          sourceUTF16End: p.sourceEnd,
        }
        if (p.speechText && p.speechText !== p.text) {
          row.boundaryUTF16Offset = p.text.length
          row.extendedUTF16Length = p.speechText.length
          row.speechText = p.speechText
        }
        return row
      })
      postForFrame('googleBooksPagePreview', {
        sourceSignature,
        contentFingerprint: preview.contentFingerprint,
        paragraphs,
      })
    }, attempt === 0 ? 120 : attempt <= 6 ? 320 : 1000)
  }

  const clearManualIntent = (): void => {
    pendingManualIntent = false
    manualIntentExpiresAt = 0
    manualIntentBaseline = ''
    manualIntentMetadata = null
    manualSwipeActive = false
  }

  const clearAutoTurn = (): void => {
    pendingAuto = false
    pendingAutoMetadata = null
    pendingTurnMethod = null
    pendingTurnBaseline = ''
    if (turnConfirmationTimer) clearTimeout(turnConfirmationTimer)
    turnConfirmationTimer = null
  }

  const clearSettledChange = (reason: string): void => {
    if (changeReasonInFlight === reason) changeReasonInFlight = null
    changeBaseline = ''
    changeMetadata = null
    settleCandidate = ''
    settleCandidateSince = 0
    settleStableSamples = 0
  }

  const liveLateAutoTurn = (): PlayBooksLateAutomaticTurn | null => {
    if (lateAutoTurn && Date.now() <= lateAutoTurn.expiresAt) return lateAutoTurn
    lateAutoTurn = null
    return null
  }

  const automaticMetadata = (
    arg: unknown,
    fallbackBaseline: string
  ): PlayBooksAutomaticTurnMetadata => {
    const value = recordArg(arg)
    return {
      turnID: nonemptyString(value.turnID) || protocolID('auto'),
      baselineSignature:
        nonemptyOpaqueString(value.baselineSignature) || fallbackBaseline,
      originFrameSessionID:
        nonemptyString(value.originFrameSessionID) || frameSessionID,
    }
  }

  const manualMetadata = (
    arg: unknown,
    fallbackBaseline: string
  ): PlayBooksManualTurnMetadata | null => {
    const value = recordArg(arg)
    const manualIntentID = nonemptyString(value.manualIntentID)
    if (!manualIntentID) return null
    return {
      manualIntentID,
      baselineSignature:
        nonemptyOpaqueString(value.baselineSignature) || fallbackBaseline,
      originFrameSessionID:
        nonemptyString(value.originFrameSessionID) || frameSessionID,
    }
  }

  const payloadFor = (
    metadata: PlayBooksTurnMetadata | null
  ): Record<string, unknown> => metadata ? { ...metadata } : {}

  const rememberLateAutoTurn = (
    metadata: PlayBooksAutomaticTurnMetadata | null,
    detectionBaselineSignature: string
  ): void => {
    if (!metadata) return
    lateAutoTurn = {
      metadata,
      detectionBaselineSignature,
      expiresAt: Date.now() + AUTO_TURN_TOMBSTONE_TTL_MS,
    }
  }

  /**
   * 不能在首次 geometry mutation 后固定等 260ms 就提取：iOS edge swipe 的
   * rubber-band 会先移动、再弹回，CSS columns 动画也会分多阶段更新。只有同一签名
   * 连续采样且稳定至少 420ms 才提交。
   */
  const commit = (
    reason: string,
    attempt = 0,
    forceExtract = false
  ): void => {
    if (settleTimer) clearTimeout(settleTimer)
    settleCandidate = playBooksSignature()
    settleCandidateSince = Date.now()
    settleStableSamples = 1

    const verifyStable = (): void => {
      settleTimer = setTimeout(() => {
        settleTimer = null
        const current = playBooksSignature()
        if (current !== settleCandidate) {
          observedSignature = current || observedSignature
          settleCandidate = current
          settleCandidateSince = Date.now()
          settleStableSamples = 1
          verifyStable()
          return
        }

        settleStableSamples += 1
        if (
          settleStableSamples < 2 ||
          Date.now() - settleCandidateSince < MIN_STABLE_MS
        ) {
          verifyStable()
          return
        }

        // edge swipe 时手指可能在某个中间位移停留很久；抬手前的“稳定”不是新页。
        if (reason === 'manual' && manualSwipeActive) {
          verifyStable()
          return
        }

        // 跨 segment 时新章可能先给空 DOM；保持同一 reason 等可读内容，而不是
        // 把空页提交给 native 或额外再做一次物理翻页。
        if (extractPlayBooksParagraphs().length === 0 && attempt < 6) {
          settleCandidateSince = Date.now()
          settleStableSamples = 1
          commit(reason, attempt + 1, forceExtract)
          return
        }

        const finalSignature = current
        const returnedToBaseline =
          changeBaseline.length > 0 && finalSignature === changeBaseline

        if (returnedToBaseline && !forceExtract) {
          if (reason === 'manual') {
            postForFrame('googleBooksPageChanging', {
              reason: 'manual',
              phase: 'cancelled',
              signature: finalSignature,
              baselineSignature: changeBaseline,
              ...payloadFor(changeMetadata || manualIntentMetadata),
            })
            clearManualIntent()
          } else if (reason === 'auto') {
            const failedMethod = pendingTurnMethod || 'none'
            const failedMetadata =
              changeMetadata as PlayBooksAutomaticTurnMetadata | null
                || pendingAutoMetadata
            clearAutoTurn()
            postForFrame('googleBooksTurnFailed', {
              method: failedMethod,
              reason: 'returned-to-baseline',
              lateEligible: false,
              ...payloadFor(failedMetadata),
            })
          }
          observedSignature = finalSignature || observedSignature
          clearSettledChange(reason)
          return
        }

        const committedMetadata =
          changeMetadata
            || (reason === 'auto' ? pendingAutoMetadata : null)
            || (reason === 'manual' ? manualIntentMetadata : null)
        if (reason === 'auto') {
          if (pendingTurnMethod) preferredMethod = pendingTurnMethod
          clearAutoTurn()
        } else if (reason === 'manual') {
          clearManualIntent()
        }
        committedSignature = finalSignature || committedSignature
        observedSignature = finalSignature || observedSignature
        if (!forceExtract) {
          postForFrame('googleBooksPageChanging', {
            reason,
            phase: 'changed',
            signature: finalSignature,
            baselineSignature: changeBaseline,
            ...payloadFor(committedMetadata),
          })
        }
        requestExtract(reason, payloadFor(committedMetadata))
        clearSettledChange(reason)
        scheduleNextPagePreview()
      }, STABILITY_POLL_MS)
    }
    verifyStable()
  }

  const methodAvailable = (method: PlayBooksTurnMethod, direction: 'next' | 'prev'): boolean => {
    if (method === 'button') return clickablePageButton(direction) !== null
    if (method === 'key') return true
    if (method === 'hotspot') {
      const x = direction === 'next' ? window.innerWidth * 0.9 : window.innerWidth * 0.1
      return document.elementFromPoint(x, window.innerHeight * 0.5) instanceof HTMLElement
    }
    return false
  }

  /** 只“选择”一个手段，然后只执行一次。若 5.2s 内指纹没变就把失败交回 native；
   * 绝不在同一次请求里继续发 key/hotspot，慢动画时 ladder 会造成双翻。 */
  const attemptTurn = (direction: 'next' | 'prev', arg?: unknown): boolean => {
    if (pendingAuto) return false
    const visualBaseline = playBooksSignature() || committedSignature
    const metadata = automaticMetadata(arg, visualBaseline)
    const coarsePointer = (() => {
      try { return window.matchMedia('(pointer: coarse)').matches } catch { return false }
    })()
    const candidates: PlayBooksTurnMethod[] = [
      ...(preferredMethod ? [preferredMethod] : []),
      'button',
      coarsePointer ? 'hotspot' : 'key',
    ]
    const method = candidates.find(
      (candidate, index) =>
        candidates.indexOf(candidate) === index && methodAvailable(candidate, direction)
    ) || 'none'
    if (method === 'none') {
      postForFrame('googleBooksTurnFailed', {
        method,
        lateEligible: false,
        ...metadata,
      })
      return false
    }

    pendingAuto = true
    pendingAutoMetadata = metadata
    lateAutoTurn = null
    clearManualIntent()
    pendingTurnBaseline = visualBaseline
    announceTurnOwner(metadata)
    // Body-level overlays do not participate in Google's page transform.
    // Clear inside the same reader-frame task that performs the physical turn
    // so the old overlay cannot survive until native's stable-page commit.
    clearPageVisuals()
    pendingTurnMethod = turnPlayBooksPage(direction, method)
    if (pendingTurnMethod === 'none') {
      clearAutoTurn()
      postForFrame('googleBooksTurnFailed', {
        method,
        lateEligible: false,
        ...metadata,
      })
      return false
    }
    postForFrame('googleBooksTurnRequested', {
      method: pendingTurnMethod,
      attempt: 1,
      ...metadata,
    })
    if (turnConfirmationTimer) clearTimeout(turnConfirmationTimer)
    turnConfirmationTimer = setTimeout(() => {
      turnConfirmationTimer = null
      if (!pendingAuto) return
      if (playBooksSignature() !== pendingTurnBaseline) return
      const failedMethod = pendingTurnMethod || method
      const failedMetadata = pendingAutoMetadata
      const failedBaseline = pendingTurnBaseline
      rememberLateAutoTurn(failedMetadata, failedBaseline)
      clearAutoTurn()
      postForFrame('googleBooksTurnFailed', {
        method: failedMethod,
        lateEligible: true,
        ...payloadFor(failedMetadata),
      })
    }, 5200)
    return true
  }

  const attemptManualTurn = (direction: 'next' | 'prev'): boolean => {
    if (pendingAuto || pendingManualIntent) return false
    const coarsePointer = (() => {
      try { return window.matchMedia('(pointer: coarse)').matches } catch { return false }
    })()
    const candidates: PlayBooksTurnMethod[] = [
      ...(preferredMethod ? [preferredMethod] : []),
      'button',
      coarsePointer ? 'hotspot' : 'key',
    ]
    const method = candidates.find(
      (candidate, index) =>
        candidates.indexOf(candidate) === index &&
        methodAvailable(candidate, direction)
    ) || 'none'
    // At the first/last page there may be no usable control. Do not suspend
    // the current queue when no physical action can even be attempted.
    if (method === 'none') return false
    if (!postManualIntent('native-control', direction)) return false

    changeReasonInFlight = 'manual'
    changeBaseline = manualIntentBaseline || committedSignature
    changeMetadata = manualIntentMetadata
    const performed = turnPlayBooksPage(direction, method)
    // The signature observer resolves a successful turn. Edge/no-op recovery
    // is deliberately left to the native identity probe so a slow commercial
    // page cannot be cancelled while it is still rendering.
    if (performed === 'none') {
      commit('manual')
      return false
    }
    return true
  }

  const api = {
    nextPage(arg?: unknown): boolean {
      return attemptTurn('next', arg)
    },
    prevPage(arg?: unknown): boolean {
      return attemptTurn('prev', arg)
    },
    userPage(arg?: unknown): boolean {
      const direction = recordArg(arg).direction
      if (direction !== 'next' && direction !== 'prev') return false
      return attemptManualTurn(direction)
    },
    refresh(arg?: unknown): void {
      const fallbackBaseline = committedSignature || playBooksSignature()
      const automatic = nonemptyString(recordArg(arg).turnID)
        ? automaticMetadata(arg, fallbackBaseline)
        : null
      const manual = manualMetadata(arg, fallbackBaseline)
      if (automatic) {
        changeReasonInFlight = 'auto'
        changeBaseline =
          liveLateAutoTurn()?.detectionBaselineSignature || fallbackBaseline
        changeMetadata = automatic
        commit('auto', 0, true)
      } else if (manual) {
        changeReasonInFlight = 'manual'
        changeBaseline = manual.baselineSignature
        changeMetadata = manual
        commit('manual', 0, true)
      } else {
        commit('refresh', 0, true)
      }
    },
    retargetTurnBaseline(arg?: unknown): void {
      const value = recordArg(arg)
      const turnID = nonemptyString(value.turnID)
      const baseline = nonemptyOpaqueString(value.detectionBaselineSignature)
      if (!turnID || !baseline) return
      if (pendingAutoMetadata?.turnID === turnID) {
        pendingTurnBaseline = baseline
        if (
          changeReasonInFlight === 'auto'
            && (changeMetadata as PlayBooksAutomaticTurnMetadata | null)?.turnID === turnID
        ) {
          changeBaseline = baseline
        }
      }
      const late = liveLateAutoTurn()
      if (late?.metadata.turnID === turnID) {
        late.detectionBaselineSignature = baseline
        late.expiresAt = Date.now() + AUTO_TURN_TOMBSTONE_TTL_MS
      }
    },
    completeTurn(arg?: unknown): void {
      const turnID = nonemptyString(recordArg(arg).turnID)
      if (turnID && lateAutoTurn?.metadata.turnID === turnID) lateAutoTurn = null
    },
  }
  CASTREADER_XCTEST_ONLY: if (__CASTREADER_XCTEST_FIXTURES__) {
    // This entire branch is removed from the app bundle. The DOM marker is an
    // additional fixture check, not a production security boundary.
    Object.assign(api, {
      __fixtureManualIntent(direction: 'next' | 'prev'): boolean {
        if (document.documentElement.getAttribute('data-cr-test-fixture') !== '1') return false
        return postManualIntent('swipe', direction)
      },
      __fixtureBeginManualSwipe(direction: 'next' | 'prev'): boolean {
        if (document.documentElement.getAttribute('data-cr-test-fixture') !== '1') return false
        beginManualSwipe(direction)
        return manualSwipeActive
      },
      __fixtureEndManualSwipe(): boolean {
        if (document.documentElement.getAttribute('data-cr-test-fixture') !== '1') return false
        const wasActive = manualSwipeActive
        finishManualSwipe()
        return wasActive
      },
    })
  }
  ;(window as unknown as { CastReaderGoogleBooks: typeof api }).CastReaderGoogleBooks = api

  /**
   * 手动翻页 intent 必须在 DOM 真正换页前通知 native 停掉旧页音频，但普通点正文不能误停：
   * - 仅接受 isTrusted 的水平 swipe；
   * - 仅接受左右边缘点击（中间区域的菜单/选词点击忽略）；
   * - 仅接受明确翻页键，输入框里的按键忽略。
   * synthetic button.click()/KeyboardEvent（自动翻页）isTrusted=false，不会被归为手动。
   */
  function postManualIntent(
    intent: 'swipe' | 'edge-click' | 'page-key' | 'native-control',
    direction: 'next' | 'prev'
  ): boolean {
    const now = Date.now()
    if (now - lastManualIntentAt < 350) return pendingManualIntent
    lastManualIntentAt = now
    if (pendingAuto) {
      clearAutoTurn()
    }
    if (changeReasonInFlight && changeReasonInFlight !== 'manual') {
      if (settleTimer) clearTimeout(settleTimer)
      settleTimer = null
      clearSettledChange(changeReasonInFlight)
      observedSignature = playBooksSignature() || observedSignature
    }
    pendingManualIntent = true
    manualIntentExpiresAt = now + 2400
    manualIntentBaseline = committedSignature || playBooksSignature()
    manualIntentMetadata = {
      manualIntentID: protocolID('manual'),
      baselineSignature: manualIntentBaseline,
      originFrameSessionID: frameSessionID,
    }
    announceTurnOwner(manualIntentMetadata)
    clearPageVisuals()
    postForFrame('googleBooksPageChanging', {
      reason: 'manual',
      phase: 'intent',
      intent,
      direction,
      baselineSignature: manualIntentBaseline,
      ...manualIntentMetadata,
    })
    return true
  }

  function beginManualSwipe(direction: 'next' | 'prev'): void {
    if (manualSwipeActive) return
    if (postManualIntent('swipe', direction)) manualSwipeActive = true
  }

  function finishManualSwipe(): void {
    if (!manualSwipeActive) return
    manualSwipeActive = false
    if (!pendingManualIntent) return
    if (changeReasonInFlight === null) {
      changeReasonInFlight = 'manual'
      changeBaseline = manualIntentBaseline || committedSignature
      changeMetadata = manualIntentMetadata
    }
    // 即便 gesture 从未改变 geometry，也要稳定确认 baseline 并回报 cancelled，
    // 让 native 恢复刚被 intent 暂停的旧页音频。
    commit('manual')
  }

  type TouchOrigin = { x: number; y: number; intentPosted: boolean }
  let touchOrigin: TouchOrigin | null = null
  window.addEventListener('touchstart', (event: TouchEvent) => {
    if (!event.isTrusted || event.touches.length !== 1) { touchOrigin = null; return }
    const touch = event.touches[0]
    touchOrigin = { x: touch.clientX, y: touch.clientY, intentPosted: false }
  }, { capture: true, passive: true })

  const detectManualSwipe = (touch: Touch): void => {
    const origin = touchOrigin
    if (!origin || origin.intentPosted) return
    const dx = touch.clientX - origin.x
    const dy = touch.clientY - origin.y
    const threshold = Math.max(44, window.innerWidth * 0.11)
    if (Math.abs(dx) < threshold || Math.abs(dx) < Math.abs(dy) * 1.25) return
    beginManualSwipe(dx < 0 ? 'next' : 'prev')
    origin.intentPosted = manualSwipeActive
  }

  window.addEventListener('touchmove', (event: TouchEvent) => {
    if (!event.isTrusted || event.touches.length !== 1) return
    detectManualSwipe(event.touches[0])
  }, { capture: true, passive: true })
  window.addEventListener('touchend', (event: TouchEvent) => {
    if (event.isTrusted && touchOrigin && event.changedTouches.length === 1) {
      detectManualSwipe(event.changedTouches[0])
    }
    touchOrigin = null
    finishManualSwipe()
  }, { capture: true, passive: true })
  window.addEventListener('touchcancel', () => {
    touchOrigin = null
    finishManualSwipe()
  }, { capture: true, passive: true })

  window.addEventListener('click', (event: MouseEvent) => {
    if (!event.isTrusted) return
    const edge = Math.min(72, Math.max(42, window.innerWidth * 0.16))
    const target = event.target instanceof Element ? event.target : null
    const interactive = target?.closest('a,button,input,textarea,select,[contenteditable="true"]')
    const label = interactive
      ? [
          interactive.getAttribute('aria-label') || '',
          interactive.getAttribute('class') || '',
          interactive.id || '',
        ].join(' ')
      : ''
    const pagerControl = /(next|prev|previous|次のページ|下一页|下一頁|前のページ|上一页|上一頁)/i.test(label)
    if (!pagerControl && event.clientX > edge && event.clientX < window.innerWidth - edge) return
    if (interactive) {
      if (!pagerControl) return
    }
    const previousControl = /(prev|previous|前のページ|上一页|上一頁)/i.test(label)
    postManualIntent('edge-click', previousControl || event.clientX < edge ? 'prev' : 'next')
  }, true)

  window.addEventListener('keydown', (event: KeyboardEvent) => {
    if (!event.isTrusted || event.repeat) return
    const target = event.target instanceof HTMLElement ? event.target : null
    if (target?.isContentEditable || target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) return
    const directions: Record<string, 'next' | 'prev'> = {
      ArrowRight: 'next',
      PageDown: 'next',
      ArrowLeft: 'prev',
      PageUp: 'prev',
    }
    const direction = directions[event.key]
    if (direction) postManualIntent('page-key', direction)
  }, true)

  setInterval(() => {
    const signature = playBooksSignature()
    if (!signature || signature === observedSignature) return
    observedSignature = signature
    const isFirstGeometryChange = changeReasonInFlight === null
    const hasFreshManualIntent = pendingManualIntent && Date.now() <= manualIntentExpiresAt
    const late = liveLateAutoTurn()
    const isLateAutomaticDeparture =
      !!late && signature !== late.detectionBaselineSignature
    const reason = changeReasonInFlight ||
      (
        pendingAuto
          ? 'auto'
          : hasFreshManualIntent
            ? 'manual'
            : isLateAutomaticDeparture
              ? 'auto'
              : 'refresh'
      )
    changeReasonInFlight = reason
    if (isFirstGeometryChange) {
      clearPageVisuals()
      changeBaseline = reason === 'auto'
        ? (
            pendingTurnBaseline
              || late?.detectionBaselineSignature
              || committedSignature
          )
        : reason === 'manual'
          ? (manualIntentBaseline || committedSignature)
          : committedSignature
      changeMetadata = reason === 'auto'
        ? (pendingAutoMetadata || late?.metadata || null)
        : reason === 'manual'
          ? manualIntentMetadata
          : null
    }
    commit(reason)
  }, 250)

  // 首屏：等 reader-rendered-page 出现再提取。
  let waited = 0
  const boot = setInterval(() => {
    waited += 200
    if (document.querySelector(`${PAGE_SEL} ${SEGMENT_SEL}`) || waited >= 15000) {
      clearInterval(boot)
      committedSignature = playBooksSignature()
      observedSignature = committedSignature
      requestExtract('initial')
      scheduleNextPagePreview()
    }
  }, 200)
}

/** 顶层壳/中间容器：`window.CR` 只做逐层转发。native 的 evaluateJavaScript 只到主帧，
 * 真正的 CR 在跨源 reader 里，靠每一层 frame 自己 postMessage 给直接子帧。 */
export function installPlayBooksRelay(): void {
  const FNS = [
    'init', 'extract', 'highlightRange', 'highlightWord', 'clearHighlight',
    'setColor', 'setActive', 'scrollTo', 'setAutoScroll', 'showMark', 'clearMarks',
    'gbNextPage', 'gbPrevPage', 'gbManualPage', 'gbRefresh', 'gbRetargetTurnBaseline',
    'gbCompleteTurn',
  ]
  type RelayTurnContext = {
    arg: Record<string, unknown>
    ownerSource: WindowProxy | null
    inherited: boolean
    expiresAt: number
  }
  let turnContext: RelayTurnContext | null = null

  const protocolArg = (arg: unknown): Record<string, unknown> | null => {
    const value = recordArg(arg)
    const hasIdentity =
      !!nonemptyString(value.turnID) || !!nonemptyString(value.manualIntentID)
    return hasIdentity
        && !!nonemptyString(value.baselineSignature)
        && !!nonemptyString(value.originFrameSessionID)
      ? value
      : null
  }
  const liveTurnContext = (): RelayTurnContext | null => {
    if (turnContext && Date.now() <= turnContext.expiresAt) return turnContext
    turnContext = null
    return null
  }
  const sameProtocolID = (
    left: Record<string, unknown>,
    right: Record<string, unknown>
  ): boolean => {
    const leftID =
      nonemptyString(left.turnID) || nonemptyString(left.manualIntentID)
    const rightID =
      nonemptyString(right.turnID) || nonemptyString(right.manualIntentID)
    return !!leftID && leftID === rightID
  }
  const rememberOutboundContext = (fn: string, arg: unknown): void => {
    if (fn === 'gbCompleteTurn') {
      const value = recordArg(arg)
      if (turnContext && sameProtocolID(value, turnContext.arg)) {
        turnContext = null
      }
      return
    }
    const value = protocolArg(arg)
    if ((fn === 'gbNextPage' || fn === 'gbPrevPage') && value) {
      turnContext = {
        arg: value,
        ownerSource: null,
        inherited: false,
        expiresAt: Date.now() + AUTO_TURN_TOMBSTONE_TTL_MS,
      }
    }
  }
  const forwardToChildren = (message: unknown): void => {
    let count = 0
    try { count = window.frames.length } catch { return }
    for (let i = 0; i < count; i++) {
      try {
        window.frames[i].postMessage(message, '*')
      } catch { /* child 可能在转场中销毁 */ }
    }
  }
  const relay = (fn: string, arg: unknown): void => {
    rememberOutboundContext(fn, arg)
    forwardToChildren({ __castreaderGB: 1, fn, arg })
  }
  const CR: Record<string, (arg?: unknown) => void> = {}
  FNS.forEach((fn) => { CR[fn] = (arg?: unknown): void => relay(fn, arg === undefined ? {} : arg) })
  ;(window as unknown as { CR: unknown }).CR = CR

  // 跨源 WindowProxy 只能 postMessage，不能安全递归读取 `.frames`。中间 Google frame
  // 收到父层消息后再交给自己的直接子帧，因此任意嵌套深度都只跨一层访问。
  window.addEventListener('message', (event: MessageEvent) => {
    const data = event.data as {
      __castreaderGB?: number
      fn?: string
      kind?: string
      arg?: unknown
      frameSessionID?: unknown
    } | null
    if (!data || data.__castreaderGB !== 1) return
    if (!isGoogleRelayOrigin(event.origin)) return
    const source = event.source as WindowProxy | null

    if (data.kind === 'turn-owner') {
      const value = protocolArg(data.arg)
      if (!value || !source) return
      turnContext = {
        arg: value,
        ownerSource: source,
        inherited: false,
        expiresAt: Date.now() + AUTO_TURN_TOMBSTONE_TTL_MS,
      }
      if (window !== window.parent) {
        try { window.parent.postMessage(data, '*') } catch { /* */ }
      }
      return
    }

    if (data.kind === 'turn-context') {
      const value = protocolArg(data.arg)
      if (!value) return
      turnContext = {
        arg: value,
        ownerSource: null,
        inherited: true,
        expiresAt: Date.now() + AUTO_TURN_TOMBSTONE_TTL_MS,
      }
      return
    }

    if (data.kind === 'reader-ready' || data.kind === 'relay-ready') {
      const context = liveTurnContext()
      if (!context || !source) return
      if (!context.inherited && context.ownerSource !== source) return
      if (data.kind === 'relay-ready') {
        try {
          source.postMessage({
            __castreaderGB: 1,
            kind: 'turn-context',
            arg: context.arg,
          }, '*')
        } catch { /* replacement disappeared again */ }
        return
      }
      const targetID = nonemptyString(data.frameSessionID)
      if (!targetID) return
      try {
        source.postMessage({
          __castreaderGB: 1,
          fn: 'gbRefresh',
          arg: {
            ...context.arg,
            __gbFrameSessionID: targetID,
          },
        }, '*')
      } catch { /* replacement disappeared again */ }
      return
    }

    if (typeof data.fn !== 'string') return
    rememberOutboundContext(data.fn, data.arg)
    forwardToChildren(data)
  })

  if (window !== window.parent) {
    try {
      window.parent.postMessage({
        __castreaderGB: 1,
        kind: 'relay-ready',
      }, '*')
    } catch { /* */ }
  }

  if (window === window.top) {
    // 阅读位置：Play Books 是 SPA，翻页只改 URL 的 pg 参数。只允许顶层壳上报，
    // 中间容器的 about:srcdoc / frame URL 不能覆盖用户真正的续读地址。
    let lastHref = ''
    setInterval(() => {
      const href = location.href
      if (href === lastHref) return
      lastHref = href
      try {
        ;(window as unknown as {
          webkit?: { messageHandlers?: Record<string, { postMessage: (m: unknown) => void }> }
        }).webkit?.messageHandlers?.castreader?.postMessage({
          type: 'googleBooksLocation',
          payload: { href },
        })
      } catch { /* */ }
    }, 1500)
  }
}

type PlayBooksRelayArg = {
  __gbFrameSessionID?: unknown
}

function relayTargetID(arg: unknown): string | null {
  if (!arg || typeof arg !== 'object') return null
  const value = (arg as PlayBooksRelayArg).__gbFrameSessionID
  return typeof value === 'string' && value.length > 0 ? value : null
}

/**
 * 有目标 id 的调用只交给匹配的 reader frame。未指定目标的 gbRefresh 是首次探测：
 * shell 尚不知道活跃 frame id 时需要让各 reader 上报 rendered。翻页则 fail-closed，
 * 防止旧调用或目标 id 丢失时 sibling reader 同时前进。
 */
export function playBooksRelayTargetsFrame(
  fn: string,
  arg: unknown,
  frameSessionID: string
): boolean {
  const targetID = relayTargetID(arg)
  if (targetID) return targetID === frameSessionID
  if (
    fn === 'gbNextPage'
      || fn === 'gbPrevPage'
      || fn === 'gbManualPage'
  ) return false
  return true
}

/** 阅读帧：接收主帧转发的 CR 调用。 */
export function installPlayBooksRelayReceiver(
  frameSessionID: string = playBooksFrameSessionID()
): void {
  window.addEventListener('message', (event: MessageEvent) => {
    const data = event.data as { __castreaderGB?: number; fn?: string; arg?: unknown } | null
    if (!data || data.__castreaderGB !== 1 || typeof data.fn !== 'string') return
    // 只接受来自 Google 自己页面的转发；中间容器帧可能是 googleusercontent。
    if (!isGoogleRelayOrigin(event.origin)) return
    if (!playBooksRelayTargetsFrame(data.fn, data.arg, frameSessionID)) return
    const target = window as unknown as {
      CR?: Record<string, (arg: unknown) => void>
      CastReaderGoogleBooks?: Record<string, (arg?: unknown) => void>
    }
    const fn = data.fn
    if (
      fn === 'gbNextPage'
        || fn === 'gbPrevPage'
        || fn === 'gbManualPage'
        || fn === 'gbRefresh'
        || fn === 'gbRetargetTurnBaseline'
        || fn === 'gbCompleteTurn'
    ) {
      const method =
        fn === 'gbNextPage'
          ? 'nextPage'
          : fn === 'gbPrevPage'
            ? 'prevPage'
            : fn === 'gbManualPage'
              ? 'userPage'
            : fn === 'gbRefresh'
              ? 'refresh'
              : fn === 'gbRetargetTurnBaseline'
                ? 'retargetTurnBaseline'
                : 'completeTurn'
      target.CastReaderGoogleBooks?.[method]?.(data.arg)
      return
    }
    target.CR?.[fn]?.(data.arg)
  })
  if (window !== window.parent) {
    try {
      window.parent.postMessage({
        __castreaderGB: 1,
        kind: 'reader-ready',
        frameSessionID,
      }, '*')
    } catch { /* parent can be replaced during boot */ }
  }
}
