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
  let svg: SVGSVGElement | null = null
  let color = initialColor
  const shown = new Set<string>()

  function ensureSvg(): SVGSVGElement {
    if (svg && svg.isConnected) return svg
    const el = document.createElementNS(SVG_NS, 'svg')
    el.style.position = 'absolute'
    el.style.left = '0'
    el.style.top = '0'
    el.style.width = `${document.documentElement.scrollWidth}px`
    el.style.height = `${document.documentElement.scrollHeight}px`
    el.style.pointerEvents = 'none'
    el.style.zIndex = '2147483646'
    el.setAttribute('data-cr-marks', '1')
    document.body.appendChild(el)
    svg = el
    return el
  }

  // 在 element 的 textContent 第 [start,end) 字符建 Range（按 text node 累积偏移）。
  function charRange(el: HTMLElement, start: number, end: number): Range | null {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
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
    const r = document.createRange()
    try { r.setStart(startNode, Math.max(0, startOff)); r.setEnd(endNode, Math.max(0, endOff)) } catch { return null }
    return r
  }

  function appendPath(s: SVGSVGElement, d: string, strokeWidth: number, opacity: number): void {
    const path = document.createElementNS(SVG_NS, 'path')
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
      requestAnimationFrame(() => { path.style.strokeDashoffset = '0' })
    } catch { /* getTotalLength 不可用时直接显示 */ }
  }

  function show(m: MarkData): void {
    if (shown.has(m.id)) return
    shown.add(m.id)
    const el = getParaEl(m.paragraphIndex)
    if (!el) return
    const range = charRange(el, m.charStart, m.charEnd)
    if (!range) return
    const rects = Array.from(range.getClientRects())
    if (!rects.length) return

    const s = ensureSvg()
    const rng = mulberry32(m.seed >>> 0)
    const sx = window.scrollX
    const sy = window.scrollY

    // 跨行词组/句子：getClientRects 每行返回一个 rect。下划线/删除线/荧光笔要逐行画，
    // 否则只画第一行、换行处就断了。末尾符号用最后一行右端，圈用所有行并集 bbox 圈住整段。
    const lineRects = rects.filter((rc) => rc.width >= 2 && rc.height >= 2)
    if (!lineRects.length) return
    const last = lineRects[lineRects.length - 1]
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    lineRects.forEach((rc) => {
      minX = Math.min(minX, rc.left); minY = Math.min(minY, rc.top)
      maxX = Math.max(maxX, rc.right); maxY = Math.max(maxY, rc.bottom)
    })

    switch (m.action) {
      case 'underline':
        lineRects.forEach((rc) => {
          const lx = rc.left + sx, ly = rc.top + sy + rc.height * 1.02
          appendPath(s, handDrawnLine(lx, ly, lx + rc.width, ly, 4, rng), 2.5, 0.95)
        })
        break
      case 'strike':
        lineRects.forEach((rc) => {
          const lx = rc.left + sx, ly = rc.top + sy + rc.height * 0.6
          appendPath(s, handDrawnLine(lx, ly, lx + rc.width, ly, 3, rng), 2.5, 0.95)
        })
        break
      case 'circle': {
        const cx = (minX + maxX) / 2 + sx, cy = (minY + maxY) / 2 + sy
        appendPath(s, handDrawnLoop(cx, cy, (maxX - minX) / 2 + 8, (maxY - minY) / 2 + 5, 12, rng), 2.5, 0.95)
        break
      }
      case 'star':
        appendPath(s, handDrawnStar(last.right + sx + 14, last.top + sy + last.height / 2, 10, rng), 2.5, 0.95)
        break
      case 'question':
        appendPath(s, handDrawnQuery(last.right + sx + 12, last.top + sy + last.height / 2, 14, rng), 2.5, 0.95)
        break
      case 'exclaim':
        appendPath(s, handDrawnExclaim(last.right + sx + 12, last.top + sy + last.height / 2, 14, rng), 2.5, 0.95)
        break
      case 'highlight':
      default:
        // 荧光笔：每行画一条粗半透明线覆盖文字
        lineRects.forEach((rc) => {
          const lx = rc.left + sx
          const ly = rc.top + sy + rc.height / 2
          appendPath(s, handDrawnLine(lx, ly, lx + rc.width, ly, 3, rng), rc.height * 0.85, 0.3)
        })
        break
    }
  }

  function clear(): void {
    shown.clear()
    if (svg) { svg.remove(); svg = null }
  }

  function setColor(hex: string): void { color = hex }

  return { show, clear, setColor }
}
