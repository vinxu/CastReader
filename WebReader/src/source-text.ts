// One UTF-16 coordinate space for Kobo extraction, word highlights and marks.
// The chapter body can be off screen because Kobo preloads it; only descendants
// of a source paragraph determine whether an inline text node is hidden.
type Position = { node: Text; offset: number }
type Source = { text: string; starts: Position[]; ends: Position[] }
const cache = new WeakMap<HTMLElement, { signature: string; nodes: Text[]; source: Source }>()

export function usesMappedSource(el: HTMLElement): boolean {
  if (el.dataset.crNativeNormalized === 'true') return true
  try { return el.ownerDocument.defaultView?.top?.location.hostname === 'readnow.kobo.com' }
  catch { return false }
}

export function mappedSource(el: HTMLElement): Source {
  const doc = el.ownerDocument, win = doc.defaultView
  const walker = doc.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  const nodes: Text[] = []
  let node: Node | null
  while ((node = walker.nextNode())) {
    let hidden = false
    // Native Google pagination already owns the raw fragment; normalize its
    // whitespace without changing the provider's measured source coverage.
    for (let p = node.parentElement; p && el.dataset.crNativeNormalized !== 'true'; p = p.parentElement) {
      const style = win?.getComputedStyle(p)
      if (['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(p.tagName) || p.hidden ||
          style?.display === 'none' || /^(hidden|collapse)$/.test(style?.visibility || '') ||
          Number(style?.opacity || '1') === 0) { hidden = true; break }
      if (p === el) break
    }
    if (!hidden) nodes.push(node as Text)
  }
  // Node identity also matters: the provider can replace a paragraph's text
  // nodes with identical text when changing font/layout.
  const signature = nodes.map(n => n.data).join('\u0000')
  const prior = cache.get(el)
  if (prior?.signature === signature && prior.nodes.length === nodes.length &&
      prior.nodes.every((node, i) => node === nodes[i])) {
    return prior.source
  }
  const source: Source = { text: '', starts: [], ends: [] }
  for (const text of nodes) {
    for (let i = 0; i < text.data.length; i++) {
      const char = text.data[i]
      if (/[\u00ad\u200b\ufeff]/.test(char)) continue
      if (/\s/.test(char)) {
        if (!source.text || source.text.endsWith(' ')) continue
        source.text += ' '
      } else source.text += char
      source.starts.push({ node: text, offset: i })
      source.ends.push({ node: text, offset: i + 1 })
    }
  }
  if (source.text.endsWith(' ')) { source.text = source.text.slice(0, -1); source.starts.pop(); source.ends.pop() }
  cache.set(el, { signature, nodes, source })
  return source
}

export function sourceText(el: HTMLElement): string {
  return usesMappedSource(el) ? mappedSource(el).text : el.textContent || ''
}

export function sourceRange(el: HTMLElement, start: number, end: number): Range | null {
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end <= start) return null
  if (usesMappedSource(el)) {
    const source = mappedSource(el), a = source.starts[start], b = source.ends[end - 1]
    if (!a || !b) return null
    const range = el.ownerDocument.createRange()
    range.setStart(a.node, a.offset); range.setEnd(b.node, b.offset)
    return range
  }
  const walker = el.ownerDocument.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  let cursor = 0, node: Node | null, a: Position | undefined, b: Position | undefined
  while ((node = walker.nextNode())) {
    const text = node as Text, next = cursor + text.length
    if (!a && start >= cursor && start < next) a = { node: text, offset: start - cursor }
    if (a && end <= next) { b = { node: text, offset: end - cursor }; break }
    cursor = next
  }
  if (!a || !b) return null
  const range = el.ownerDocument.createRange()
  range.setStart(a.node, a.offset); range.setEnd(b.node, b.offset)
  return range
}
