// window.CR：native↔JS 桥（句子级高亮用 overlay div，不用 CSS Custom Highlight——
// iOS WKWebView 的 CSS.highlights set/clear 后旧像素不重绘、会残留，overlay 用 DOM 元素确定清除）。

import { createMarkRenderer } from './mark-renderer'
import { hexToRgba } from '@/shared/highlight-palette'
import mammoth from 'mammoth'
import ePub from 'epubjs'

type ExtractedPara = {
  text: string
  element: HTMLElement
  /** 提取器已给出最终文本（例如 Play Books 的可见区裁剪），不得用 element.textContent 覆盖。 */
  exactText?: boolean
  /** text 在 element.textContent 内的起始偏移；高亮字符位置要加上它。 */
  charOffset?: number
  /** 跨页断句：补到自然句末的朗读文本。 */
  speechText?: string
  /** 跨页裁剪已读前缀用的稳定来源坐标。 */
  sourceParagraphIndex?: number
  sourceStart?: number
  sourceEnd?: number
}
interface CRDeps {
  extract: () => ExtractedPara[]
  /** Optional site geometry guard for overlay fragments. Google Books uses it
   * to reject a line that crosses its dynamic page clip. */
  acceptHighlightRect?: (el: HTMLElement, rect: DOMRect) => boolean
  /** 每次 rendered 附带的页面级信息（Play Books 的 reason/signature）。 */
  pageMeta?: () => Record<string, unknown>
  /** 由站点适配自行触发首次/后续提取（Play Books 靠翻页监听驱动）。 */
  autoExtract?: boolean
  /** initBridge 完成后回调，交出 doExtract 供站点适配调用。 */
  onInstalled?: (api: { extract: (reason?: string) => void }) => void
}

function dbg(s: string): void { try { console.log('[CRDBG]', s) } catch { /* */ } }

// 诊断：仅回传 native 统一日志（CRDBG）。页面红条已撤（功能稳定）；如需再开调试，
// 恢复创建 #cr-dbg2 div 并 d.textContent = s 即可。
function showDbg(s: string): void {
  try {
    ;(window as unknown as { webkit?: { messageHandlers?: Record<string, { postMessage: (m: unknown) => void }> } })
      .webkit?.messageHandlers?.castreader?.postMessage({ type: 'log', payload: { message: s } })
  } catch { /* */ }
}

// 在 element 的 textContent 第 [start,end) 字符建 Range（用 element 所在文档）。
function charRangeInElement(el: HTMLElement, start: number, end: number): Range | null {
  const doc = el.ownerDocument
  const walker = doc.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  let offset = 0
  let sNode: Node | null = null, sOff = 0
  let eNode: Node | null = null, eOff = 0
  let node: Node | null
  while ((node = walker.nextNode())) {
    const len = node.textContent?.length ?? 0
    if (!sNode && offset + len > start) { sNode = node; sOff = start - offset }
    if (offset + len >= end) { eNode = node; eOff = end - offset; break }
    offset += len
  }
  if (!sNode) return null
  if (!eNode) { eNode = sNode; eOff = (sNode.textContent?.length ?? 0) }
  const r = doc.createRange()
  try { r.setStart(sNode, Math.max(0, sOff)); r.setEnd(eNode, Math.max(0, eOff)) } catch { return null }
  return r
}

function isCJKCh(ch: string): boolean {
  if (!ch) return false
  const c = ch.charCodeAt(0)
  return (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0x3000 && c <= 0x303F) || (c >= 0xFF00 && c <= 0xFFEF)
}

// 折叠段内空白（HTML 源码换行/缩进进了 textContent → TTS 会在此停顿）：连续空白 → CJK 之间删除（中文连续）、
// 其余单空格（保英文词边界）。同步改 text node，使 textContent 与 TTS 输入一致、高亮 charRange 不受影响。
function normalizeWhitespace(el: HTMLElement): void {
  const walker = el.ownerDocument.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  const nodes: Text[] = []
  let n: Node | null
  while ((n = walker.nextNode())) nodes.push(n as Text)
  for (const node of nodes) {
    const t = node.textContent || ''
    if (!/\s/.test(t)) continue
    const c = t.replace(/\s+/g, (m: string, off: number): string => {
      const prev = off > 0 ? t[off - 1] : ''
      const next = off + m.length < t.length ? t[off + m.length] : ''
      return (isCJKCh(prev) && isCJKCh(next)) ? '' : ' '
    })
    if (c !== t) node.textContent = c
  }
}

export function initBridge(deps: CRDeps): void {
  const { extract } = deps
  const paraElements = new Map<number, HTMLElement>()
  // Canonical mapping from the latest extraction. Native can split one exact
  // source paragraph into multiple TTS paragraphs, so CR.init rebuilds
  // `paraElements` from this immutable page-local snapshot instead of aliasing
  // an alias and accidentally pointing the following paragraph at the wrong
  // DOM node.
  const extractedParaElements = new Map<number, HTMLElement>()
  // Play Books 的段落只取可见片段，DOM 里的 element.textContent 还包含前后不可见
  // 的部分；所有字符偏移都要加上这个基准。其余源恒为 0。
  const paraOffsets = new Map<number, number>()
  let color = '#FD5F01'
  const markRenderer = createMarkRenderer((i) => paraElements.get(i), color)
  // Kobo 等分页阅读器会把正文放在同源 iframe 里。Range 的矩形坐标属于它自己的
  // Document/Window，overlay 也必须放回同一个 Document；同时保留节点引用，确保
  // iframe 换页或被移除后仍能清掉上一页高亮。
  const overlayNodes = new Set<HTMLElement>()
  const overlayDocuments = new Set<Document>()

  const post = (type: string, payload: Record<string, unknown> = {}): void => {
    try {
      ;(window as unknown as { webkit?: { messageHandlers?: Record<string, { postMessage: (m: unknown) => void }> } })
        .webkit?.messageHandlers?.castreader?.postMessage({ type, payload })
    } catch { /* */ }
  }
  const log = (message: string): void => post('log', { message })

  // overlay 高亮：清掉旧矩形 div，按 range 各行 rect 画半透明矩形（跳过零宽，避免残留线）。
  function clearOverlay(): void {
    overlayNodes.forEach((node) => {
      try { node.remove() } catch { /* detached/replaced frame */ }
    })
    overlayNodes.clear()
    // 兼容页面脚本移动/复制 overlay 或旧 bundle 留下的节点；所有曾绘制过的
    // ownerDocument 都要清理，不能只查 bridge 所在的顶层 document。
    overlayDocuments.forEach((doc) => {
      try { doc.querySelectorAll('.cr-hl-ov').forEach((n) => n.remove()) } catch { /* detached frame */ }
    })
    overlayDocuments.clear()
  }
  function paintOverlay(range: Range, el?: HTMLElement): number {
    clearOverlay()
    const ownerDocument = range.startContainer.ownerDocument || el?.ownerDocument || document
    const ownerWindow = ownerDocument.defaultView
    const host = ownerDocument.body || ownerDocument.documentElement
    if (!ownerWindow || !host) return 0
    const rects = Array.from(range.getClientRects())
    const sx = ownerWindow.scrollX, sy = ownerWindow.scrollY
    overlayDocuments.add(ownerDocument)
    let n = 0
    rects.forEach((rc) => {
      if (rc.width < 2 || rc.height < 2) return
      if (
        el &&
        deps.acceptHighlightRect &&
        !deps.acceptHighlightRect(el, rc)
      ) return
      const d = ownerDocument.createElement('div')
      d.className = 'cr-hl-ov'
      d.style.cssText =
        `position:absolute;left:${rc.left + sx}px;top:${rc.top + sy}px;width:${rc.width}px;height:${rc.height}px;` +
        `background:${hexToRgba(color, 0.34)};pointer-events:none;z-index:2147483000;border-radius:3px;mix-blend-mode:multiply`
      host.appendChild(d)
      overlayNodes.add(d)
      n++
    })
    return n
  }
  function setOverlay(el: HTMLElement, charStart: number, charEnd: number): number {
    const range = charRangeInElement(el, charStart, charEnd)
    if (!range) { clearOverlay(); return 0 }
    return paintOverlay(range, el)
  }

  // 词级高亮（对齐扩展 highlight-sync）：JS 在段落 textContent 虚拟全文里按词文本前向匹配，
  // 不靠 native 字符偏移（消除 TTS 文本 vs DOM 原文的错位）。Range 按 (段落,segment序号) 缓存。
  let wcPara = -1, wcSeg = -1, wcRanges: Array<Range | null> = [], paraCursor = 0

  // 从 from 起前向找 word：精确 → 不分大小写 → 去首尾标点。返回命中位置与实际匹配长度。
  function findWordPos(text: string, lower: string, word: string, from: number): { pos: number; len: number } | null {
    let p = text.indexOf(word, from); if (p >= 0) return { pos: p, len: word.length }
    const lw = word.toLowerCase()
    p = lower.indexOf(lw, from); if (p >= 0) return { pos: p, len: word.length }
    const stripped = word.replace(/^[^\w一-鿿]+|[^\w一-鿿]+$/g, '')
    if (stripped && stripped !== word) {
      p = lower.indexOf(stripped.toLowerCase(), from); if (p >= 0) return { pos: p, len: stripped.length }
    }
    return null
  }

  // segment 的词序列 → 在 el 虚拟全文里从 startCursor 前向逐词匹配成 Range[]（失配推 null，连续失配向前找长词重锚）。
  function buildWordRanges(el: HTMLElement, words: string[], startCursor: number): { ranges: Array<Range | null>; cursor: number } {
    const fullText = el.textContent || ''
    const lower = fullText.toLowerCase()
    const ranges: Array<Range | null> = []
    let searchPos = Math.max(0, Math.min(startCursor, fullText.length))
    let misses = 0
    const MAX_GAP = 150
    for (let wi = 0; wi < words.length; wi++) {
      const word = words[wi] || ''
      if (!word.trim()) { ranges.push(null); continue }
      const maxDist = word.length <= 2 ? 30 : word.length <= 4 ? 50 : MAX_GAP
      let m = findWordPos(fullText, lower, word, searchPos)
      if (m && m.pos - searchPos > maxDist) m = null
      if (!m) {
        misses++
        if (misses >= 2) {   // 连续失配 → 向前找长词重新锚定，防级联丢词
          const lookahead = misses >= 5 ? 15 : 5
          for (let ah = wi + 1; ah < Math.min(wi + 1 + lookahead, words.length); ah++) {
            const fw = (words[ah] || '').toLowerCase()
            if (fw.length < (misses >= 5 ? 5 : 3)) continue
            const ap = lower.indexOf(fw, searchPos)
            if (ap >= 0) { searchPos = Math.max(searchPos, ap - 10); misses = 0; break }
          }
        }
        ranges.push(null)
        continue
      }
      misses = 0
      ranges.push(charRangeInElement(el, m.pos, m.pos + m.len))
      searchPos = m.pos + m.len
    }
    return { ranges, cursor: searchPos }
  }

  function doExtract(reason?: string): void {
    let paras: ExtractedPara[] = []
    try { paras = extract() } catch (e) { post('error', { stage: 'extract', message: String(e) }) }
    // A page-local mapping and its overlay must have the same lifetime.
    // Google can rebuild paragraph nodes or replace the reader frame during a
    // turn; retaining body-level overlays here would leave old-page rectangles
    // floating above the newly extracted page.
    clearOverlay()
    wcPara = -1
    wcSeg = -1
    wcRanges = []
    paraCursor = 0
    paraElements.clear()
    extractedParaElements.clear()
    paraOffsets.clear()
    const out: Array<Record<string, unknown>> = []
    paras.forEach((p, i) => {
      const el = p.element
      try { el.setAttribute('data-cr-para', String(i)) } catch { /* */ }
      // 折叠段内空白：HTML 源码换行/缩进否则会让 TTS 停顿；charRange 与 textContent 同步。
      // exactText 的提取器已经在自己的坐标系里量过可见区间，再改文本节点会让偏移错位。
      if (!p.exactText) normalizeWhitespace(el)
      paraElements.set(i, el)
      extractedParaElements.set(i, el)
      paraOffsets.set(i, p.charOffset || 0)
      const text = p.exactText ? p.text : (el.textContent || p.text || '').trim()
      const row: Record<string, unknown> = { paragraphIndex: i, text, type: 'paragraph' }
      if (p.speechText && p.speechText !== text) {
        row.boundaryUTF16Offset = text.length
        row.extendedUTF16Length = p.speechText.length
        row.speechText = p.speechText
      }
      if (typeof p.sourceParagraphIndex === 'number') row.sourceParagraphIndex = p.sourceParagraphIndex
      if (typeof p.sourceStart === 'number') row.sourceUTF16Start = p.sourceStart
      if (typeof p.sourceEnd === 'number') row.sourceUTF16End = p.sourceEnd
      out.push(row)
    })
    const payload: Record<string, unknown> = { paragraphs: out }
    if (reason) payload.reason = reason
    if (deps.pageMeta) {
      try { Object.assign(payload, deps.pageMeta()) } catch { /* */ }
    }
    post('rendered', payload)
    ;(window as unknown as { __crLastRendered?: unknown }).__crLastRendered = out
    log(`extracted ${out.length} paragraphs${reason ? ' reason=' + reason : ''}`)
  }

  const CR = {
    version: 'm1',
    extract: doExtract,
    // 本地 DOCX：native 传 base64 字节 → mammoth 转 HTML 注入 DOM → 复用 Visual Zone 提取（不上传后端）。
    renderDocx(arg: { base64: string }): void {
      try {
        const bin = atob(arg.base64)
        const bytes = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
        // 兼容 esbuild 对 CJS 的 default interop：convertToHtml 可能在 default 上。
        const anyM = mammoth as unknown as Record<string, unknown>
        const mm = (typeof anyM.convertToHtml === 'function'
          ? anyM
          : (anyM.default as Record<string, unknown>)) as { convertToHtml?: (o: { arrayBuffer: ArrayBuffer }) => Promise<{ value: string }> }
        if (!mm || typeof mm.convertToHtml !== 'function') {
          showDbg('docx noConv keys=' + Object.keys(anyM || {}).slice(0, 10).join(','))
          post('error', { stage: 'docx', message: 'convertToHtml missing' })
          return
        }
        mm.convertToHtml({ arrayBuffer: bytes.buffer })
          .then((res) => {
            const article = document.createElement('article')
            article.style.cssText = 'max-width:680px;margin:0 auto;padding:16px 18px;font-size:18px;line-height:1.8;text-align:justify;overflow-wrap:break-word;hyphens:auto'
            article.innerHTML = res.value
            document.body.style.cssText = ''   // 清掉 loadHTMLString 的 loading flex+100vh 样式，否则 article 被居中裁切、高亮坐标偏
            document.body.innerHTML = ''
            document.body.appendChild(article)
            showDbg('docx ok html=' + res.value.length)
            setTimeout(doExtract, 120)
          })
          .catch((e) => { showDbg('docx ERR ' + String(e)); post('error', { stage: 'docx', message: String(e) }) })
      } catch (e) {
        showDbg('docx EXC ' + String(e))
        post('error', { stage: 'docx', message: String(e) })
      }
    },
    // 本地 EPUB：native 传 base64 → epub.js 解 zip → 逐章 spine 取 HTML 拼接注入 → 复用 Visual Zone 提取。
    renderEpub(arg: { base64: string }): void {
      try {
        const bin = atob(arg.base64)
        const bytes = new Uint8Array(bin.length)
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
        const mk = ePub as unknown as (input: ArrayBuffer) => Record<string, unknown>
        const book = mk(bytes.buffer)
        const ready = book.ready as Promise<unknown>
        ready.then(() => {
          const spine = book.spine as { spineItems?: unknown[]; items?: unknown[] } | undefined
          const items = (spine?.spineItems || spine?.items || []) as Array<{
            load: (req: unknown) => Promise<unknown>; unload?: () => void
          }>
          const loadFn = (book.load as { bind: (b: unknown) => unknown }).bind(book)
          return Promise.all(items.map((it) =>
            it.load(loadFn)
              .then((c: unknown) => {
                const el = c as { body?: { innerHTML?: string }; documentElement?: { innerHTML?: string }; innerHTML?: string }
                return el.body?.innerHTML || el.documentElement?.innerHTML || el.innerHTML || ''
              })
              .catch(() => '')
              .then((html) => { try { it.unload?.() } catch { /* */ } return html })
          ))
        }).then((htmls) => {
          const list = (htmls as string[]) || []
          const article = document.createElement('article')
          article.style.cssText = 'max-width:680px;margin:0 auto;padding:16px 18px;font-size:18px;line-height:1.8;text-align:justify;overflow-wrap:break-word;hyphens:auto'
          article.innerHTML = list.join('\n')
          document.body.style.cssText = ''   // 清掉 loadHTMLString 的 loading flex+100vh 样式，否则 article 被居中裁切、高亮坐标偏
          document.body.innerHTML = ''
          document.body.appendChild(article)
          showDbg('epub chapters=' + list.length + ' len=' + article.innerHTML.length)
          setTimeout(doExtract, 180)
        }).catch((e: unknown) => { showDbg('epub ERR ' + String(e)); post('error', { stage: 'epub', message: String(e) }) })
      } catch (e) {
        showDbg('epub EXC ' + String(e)); post('error', { stage: 'epub', message: String(e) })
      }
    },
    init(arg: {
      segments?: Array<{
        paragraphIndex: number
        text: string
        /** Native paragraph may alias a source DOM paragraph after an exact split. */
        domParagraphIndex?: number
        /** native 裁掉跨页已读前缀后，可把新文本在原 DOM 中的绝对 UTF-16 起点传回来。 */
        domCharOffset?: number
        /** 兼容早期调用方字段名。 */
        charOffset?: number
      }>
      color?: string
    }): void {
      if (arg.color) { color = arg.color; markRenderer.setColor(color) }
      const segments = arg.segments || []
      if (segments.length > 0) {
        paraElements.clear()
        paraOffsets.clear()
      }
      for (const segment of segments) {
        const domParagraphIndex =
          segment.domParagraphIndex ?? segment.paragraphIndex
        const sourceElement = extractedParaElements.get(domParagraphIndex)
        if (sourceElement) {
          paraElements.set(segment.paragraphIndex, sourceElement)
        }
        const override = segment.domCharOffset ?? segment.charOffset
        if (
          Number.isFinite(override) &&
          typeof override === 'number' &&
          override >= 0 &&
          paraElements.has(segment.paragraphIndex)
        ) {
          paraOffsets.set(segment.paragraphIndex, override)
        }
      }
      // offset 变化后旧的前向词游标/Range 缓存失效。
      wcPara = -1
      wcSeg = -1
      paraCursor = 0
      wcRanges = []
      log(`init segments=${arg.segments?.length ?? 0}`)
    },
    highlightRange(arg: {
      paragraphIndex: number
      charStart: number
      charEnd: number
      /** Absolute source-DOM range used while one immutable audio sentence
       * carries across a visual page boundary. */
      domCharStart?: number
      domCharEnd?: number
    }): void {
      const el = paraElements.get(arg.paragraphIndex)
      const info = 'p' + arg.paragraphIndex + ' ' + arg.charStart + '-' + arg.charEnd
      if (!el) { clearOverlay(); showDbg(info + ' NOEL'); return }
      const base = paraOffsets.get(arg.paragraphIndex) || 0
      const hasAbsoluteRange =
        typeof arg.domCharStart === 'number' &&
        Number.isFinite(arg.domCharStart) &&
        typeof arg.domCharEnd === 'number' &&
        Number.isFinite(arg.domCharEnd)
      const start = hasAbsoluteRange ? (arg.domCharStart as number) : arg.charStart + base
      const end = hasAbsoluteRange ? (arg.domCharEnd as number) : arg.charEnd + base
      const n = setOverlay(el, start, end)
      showDbg(info + ' ov=' + n)
    },
    // 词级高亮（英文）：native 下发当前 segment 的词数组 + 词索引，JS 在 DOM 虚拟全文前向匹配定位（不靠字符偏移）。
    highlightWord(arg: { paragraphIndex: number; segSeq: number; words: string[]; wordIndex: number }): void {
      const el = paraElements.get(arg.paragraphIndex)
      if (!el) { clearOverlay(); showDbg('w NOEL'); return }
      if (arg.paragraphIndex !== wcPara) {
        wcPara = arg.paragraphIndex
        // 可见区裁剪的段落要从可见起点开始前向匹配，否则会命中上一页的同名词。
        paraCursor = paraOffsets.get(arg.paragraphIndex) || 0
        wcSeg = -1
      }
      if (arg.segSeq !== wcSeg) {
        wcSeg = arg.segSeq
        const built = buildWordRanges(el, arg.words || [], paraCursor)
        wcRanges = built.ranges
        paraCursor = built.cursor
      }
      const r = wcRanges[arg.wordIndex]
      if (r && !r.collapsed) {
        const n = paintOverlay(r, el)
        showDbg('w p' + arg.paragraphIndex + ' s' + arg.segSeq + ' #' + arg.wordIndex + ' ov=' + n)
      } else {
        showDbg('w p' + arg.paragraphIndex + ' #' + arg.wordIndex + ' MISS')
      }
    },
    clearHighlight(): void { clearOverlay(); wcPara = -1; wcSeg = -1; paraCursor = 0 },
    // Play Books 之类分页阅读器由页面自己控制视口，滚动会破坏分页几何。
    disableScroll: false,
    setColor(arg: { hex: string }): void { color = arg.hex; markRenderer.setColor(arg.hex) },
    setActive(arg: { active: boolean }): void { if (arg.active) markRenderer.clear(); else clearOverlay() },
    scrollTo(arg: { paragraphIndex: number }): void {
      if (CR.disableScroll) return
      paraElements.get(arg.paragraphIndex)?.scrollIntoView({ block: 'center', behavior: 'auto' })
    },
    setAutoScroll(_arg: { enabled: boolean }): void { /* M2 */ },
    showMark(arg: { id: string; paragraphIndex: number; charStart: number; charEnd: number; action: string; n?: number; seed: number; weight?: string; role?: string }): void {
      const base = paraOffsets.get(arg.paragraphIndex) || 0
      markRenderer.show({
        ...arg,
        charStart: arg.charStart + base,
        charEnd: arg.charEnd + base,
      })
    },
    clearMarks(): void { markRenderer.clear() },
  }
  ;(window as unknown as { CR: typeof CR }).CR = CR

  document.addEventListener('click', (e) => {
    const t = e.target as HTMLElement | null
    const el = t?.closest?.('[data-cr-para]') as HTMLElement | null
    if (el) post('paragraphTapped', { paragraphIndex: Number(el.getAttribute('data-cr-para')) })
  }, true)

  deps.onInstalled?.({ extract: doExtract })

  function ready(): void {
    post('ready', { version: 'm1' })
    if (deps.autoExtract === false) return
    setTimeout(doExtract, 350)
  }
  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', ready)
  } else {
    ready()
  }
}
