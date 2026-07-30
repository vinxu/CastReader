// 解读手写标注渲染：复用扩展 handwritten-marks 的画笔，把 native 下发的
// {paragraphIndex, charStart, charEnd, action, seed} 在 DOM 段落上定位 Range → SVG 叠层手写动画。
// SVG 用 document 绝对坐标（随页面滚动），覆盖全文。

import {
  handDrawnLoop, handDrawnLine, handDrawnStar, handDrawnQuery, handDrawnExclaim,
  mulberry32, MARK_EASE,
} from '@/ui/handwritten-marks'

const SVG_NS = 'http://www.w3.org/2000/svg'

export interface MarkData {
  id: string
  paragraphIndex: number
  charStart: number
  charEnd: number
  action: string
  n?: number
  seed: number
  weight?: string   // P1：重要度分层（primary/secondary/tertiary）→ 笔触粗细
  role?: string     // P1：语义角色，透传
}

/// 重要度 → 笔触粗细倍率（与 native HandwrittenMark.weightMultiplier 对齐）。
function weightMul(weight?: string): number {
  if (weight === 'primary' || weight === 'high') return 1.6
  if (weight === 'tertiary' || weight === 'low') return 0.65
  return 1.0
}

/// 手绘正弦波浪线（风险/警示语义；扩展画笔无 wave，本地合成）。
function handDrawnWave(x0: number, y: number, x1: number, amp: number, rng: () => number): string {
  const width = x1 - x0
  const wavelength = Math.max(7, amp * 4)
  const phase = rng() * Math.PI
  const steps = Math.max(4, Math.round(width / 3))
  let d = `M ${x0.toFixed(1)} ${y.toFixed(1)}`
  for (let s = 1; s <= steps; s++) {
    const t = s / steps
    const x = x0 + width * t
    const yy = y + amp * Math.sin(((x - x0) / wavelength) * 2 * Math.PI + phase)
    d += ` L ${x.toFixed(1)} ${yy.toFixed(1)}`
  }
  return d
}

export interface MarkRenderer {
  show: (m: MarkData) => void
  clear: () => void
  setColor: (hex: string) => void
}

export function createMarkRenderer(
  getParaEl: (i: number) => HTMLElement | undefined,
  initialColor: string,
): MarkRenderer {
  // 分页商业阅读器常把正文放在同源 iframe。每个 ownerDocument 使用自己的 SVG，
  // 否则 iframe 内 Range 的 viewport 坐标会被错误画到顶层页面。
  const svgs = new Map<Document, SVGSVGElement>()
  let color = initialColor
  const shown = new Set<string>()

  function ensureSvg(doc: Document): SVGSVGElement | null {
    const root = doc.documentElement
    const body = doc.body
    const host = body || root
    if (!host) return null
    const width = Math.max(root?.scrollWidth || 0, body?.scrollWidth || 0, 1)
    const height = Math.max(root?.scrollHeight || 0, body?.scrollHeight || 0, 1)
    const existing = svgs.get(doc)
    if (existing && existing.isConnected) {
      existing.style.width = `${width}px`
      existing.style.height = `${height}px`
      return existing
    }
    const el = doc.createElementNS(SVG_NS, 'svg')
    el.style.position = 'absolute'
    el.style.left = '0'
    el.style.top = '0'
    el.style.width = `${width}px`
    el.style.height = `${height}px`
    el.style.pointerEvents = 'none'
    el.style.zIndex = '2147483646'
    el.setAttribute('data-cr-marks', '1')
    host.appendChild(el)
    svgs.set(doc, el)
    return el
  }

  // 在 element 的 textContent 第 [start,end) 字符建 Range（按 text node 累积偏移）。
  function charRange(el: HTMLElement, start: number, end: number): Range | null {
    const doc = el.ownerDocument
    const walker = doc.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    let offset = 0
    let startNode: Node | null = null
    let startOff = 0
    let endNode: Node | null = null
    let endOff = 0
    let node: Node | null
    while ((node = walker.nextNode())) {
      const len = node.textContent?.length ?? 0
      if (!startNode && offset + len > start) { startNode = node; startOff = start - offset }
      if (offset + len >= end) { endNode = node; endOff = end - offset; break }
      offset += len
    }
    if (!startNode || !endNode) return null
    const r = doc.createRange()
    try { r.setStart(startNode, Math.max(0, startOff)); r.setEnd(endNode, Math.max(0, endOff)) } catch { return null }
    return r
  }

  function appendPath(s: SVGSVGElement, d: string, strokeWidth: number, opacity: number): void {
    const path = s.ownerDocument.createElementNS(SVG_NS, 'path')
    path.setAttribute('d', d)
    path.setAttribute('stroke', color)
    path.setAttribute('stroke-width', String(strokeWidth))
    path.setAttribute('stroke-opacity', String(opacity))
    path.setAttribute('fill', 'none')
    path.setAttribute('stroke-linecap', 'round')
    path.setAttribute('stroke-linejoin', 'round')
    s.appendChild(path)
    try {
      const len = path.getTotalLength?.() ?? 120
      path.style.strokeDasharray = String(len)
      path.style.strokeDashoffset = String(len)
      void path.getBoundingClientRect()   // 强制 reflow：让初始 dashoffset=len（落笔起点）先落地，
      // 否则 WebKit 把 len→0 合并成一帧、跳过落笔过渡（与 native MarkInkView 首帧问题同源）。
      path.style.transition = `stroke-dashoffset 700ms ${MARK_EASE}`
      const ownerWindow = s.ownerDocument.defaultView
      if (ownerWindow) ownerWindow.requestAnimationFrame(() => { path.style.strokeDashoffset = '0' })
      else requestAnimationFrame(() => { path.style.strokeDashoffset = '0' })
    } catch { /* getTotalLength 不可用时直接显示 */ }
  }

  function show(m: MarkData): void {
    if (shown.has(m.id)) return
    const el = getParaEl(m.paragraphIndex)
    if (!el) return
    const range = charRange(el, m.charStart, m.charEnd)
    if (!range) return
    const rects = Array.from(range.getClientRects())
    if (!rects.length) return

    const ownerDocument = el.ownerDocument
    const ownerWindow = ownerDocument.defaultView
    if (!ownerWindow) return
    const s = ensureSvg(ownerDocument)
    if (!s) return
    const rng = mulberry32(m.seed >>> 0)
    const sx = ownerWindow.scrollX
    const sy = ownerWindow.scrollY

    // 跨行词组/句子：getClientRects 每行返回一个 rect。下划线/删除线/荧光笔要逐行画，
    // 否则只画第一行、换行处就断了。末尾符号用最后一行右端，圈用所有行并集 bbox 圈住整段。
    const lineRects = rects.filter((rc) => rc.width >= 2 && rc.height >= 2)
    if (!lineRects.length) return
    shown.add(m.id)
    const last = lineRects[lineRects.length - 1]
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    lineRects.forEach((rc) => {
      minX = Math.min(minX, rc.left); minY = Math.min(minY, rc.top)
      maxX = Math.max(maxX, rc.right); maxY = Math.max(maxY, rc.bottom)
    })

    const wm = weightMul(m.weight)   // P1：重要度 → 笔触粗细倍率
    switch (m.action) {
      case 'underline':
        lineRects.forEach((rc) => {
          const lx = rc.left + sx, ly = rc.top + sy + rc.height * 1.02
          appendPath(s, handDrawnLine(lx, ly, lx + rc.width, ly, 4, rng), 2.5 * wm, 0.95)
        })
        break
      case 'wave':
        // 波浪线：风险/警示语义（P1）。
        lineRects.forEach((rc) => {
          const lx = rc.left + sx, ly = rc.top + sy + rc.height * 1.0
          appendPath(s, handDrawnWave(lx, ly, lx + rc.width, Math.max(1.6, rc.height * 0.12), rng), 2.2 * wm, 0.9)
        })
        break
      case 'strike':
        lineRects.forEach((rc) => {
          const lx = rc.left + sx, ly = rc.top + sy + rc.height * 0.6
          appendPath(s, handDrawnLine(lx, ly, lx + rc.width, ly, 3, rng), 2.5 * wm, 0.95)
        })
        break
      case 'circle': {
        const cx = (minX + maxX) / 2 + sx, cy = (minY + maxY) / 2 + sy
        appendPath(s, handDrawnLoop(cx, cy, (maxX - minX) / 2 + 8, (maxY - minY) / 2 + 5, 12, rng), 2.5 * wm, 0.95)
        break
      }
      case 'star':
        appendPath(s, handDrawnStar(last.right + sx + 14, last.top + sy + last.height / 2, 10, rng), 2.5 * wm, 0.95)
        break
      case 'question':
        appendPath(s, handDrawnQuery(last.right + sx + 12, last.top + sy + last.height / 2, 14, rng), 2.5 * wm, 0.95)
        break
      case 'exclaim':
        appendPath(s, handDrawnExclaim(last.right + sx + 12, last.top + sy + last.height / 2, 14, rng), 2.5 * wm, 0.95)
        break
      case 'highlight':
      default:
        // 荧光笔：每行画一条粗半透明线覆盖文字
        lineRects.forEach((rc) => {
          const lx = rc.left + sx
          const ly = rc.top + sy + rc.height / 2
          appendPath(s, handDrawnLine(lx, ly, lx + rc.width, ly, 3, rng), rc.height * 0.85 * wm, 0.3)
        })
        break
    }
  }

  function clear(): void {
    shown.clear()
    svgs.forEach((svg) => {
      try { svg.remove() } catch { /* detached/replaced frame */ }
    })
    svgs.clear()
  }

  function setColor(hex: string): void { color = hex }

  return { show, clear, setColor }
}
