// O'Reilly Learning reader adapter.
//
// O'Reilly renders one semantic HTML chapter as a long, continuously
// scrollable document. CastReader still needs the same page transaction
// contract used by Google Play Books and Kobo, so this adapter defines one
// "visual page" as the complete text fragments inside the unobscured native
// viewport. A page turn keeps a small geometric overlap so a line clipped by
// the old viewport becomes complete in the new one, while a source-coordinate
// cursor removes every already-spoken character. Only at the end of a chapter
// does it follow O'Reilly's trusted status-bar chapter link.
//
// Important invariants:
//   * only descendants of #sbo-rt-content can become speech;
//   * clipped first/last lines, navigation, controls, and hidden DOM are out;
//   * source IDs + UTF-16 ranges remain stable across visual pages;
//   * old highlights/marks are cleared before a changed page is committed;
//   * compatibility events keep the existing googleBooks* wire names, but
//     every payload is tagged source=oreilly.

import { extendToSentenceEnd } from './play-books'

export type OReillyPara = {
  text: string
  element: HTMLElement
  exactText: true
  charOffset: number
  sourceParagraphIndex: number
  sourceStart: number
  sourceEnd: number
}

export type OReillyPagePreview = {
  paragraphs: OReillyPara[]
  contentFingerprint: string
}

export type OReillySpeechPreview = {
  text: string
  exactText: true
  sourceParagraphIndex: number
  sourceStart: number
  sourceEnd: number
  contentFingerprint: string
}

type Rect = { left: number; top: number; right: number; bottom: number }
type Poster = (type: string, payload?: Record<string, unknown>) => void
type TurnReason = 'auto' | 'manual' | 'refresh'

type AutomaticTurnMetadata = {
  turnID: string
  baselineSignature: string
  originFrameSessionID: string
}

type ManualTurnMetadata = {
  manualIntentID: string
  baselineSignature: string
  originFrameSessionID: string
}

type TurnMetadata = AutomaticTurnMetadata | ManualTurnMetadata

type ScrollSurface = {
  position: () => number
  maximum: () => number
  scrollTo: (position: number) => void
}

type PendingChange = {
  reason: TurnReason
  baselineSignature: string
  metadata: TurnMetadata | null
  direction?: 'next' | 'prev'
  method?: 'scroll' | 'chapter'
  startHref?: string
  chapterTargetHref?: string
  chapterBaselineContentFingerprint?: string
  chapterBaselineRoot?: HTMLElement | null
  chapterEntryPositionApplied?: boolean
  priorSourceCursor?: SourceCursor | null
  startedAt: number
}

type StoredChapterTurn = {
  version: 1
  bookID: string
  reason: 'auto' | 'manual'
  direction: 'next' | 'prev'
  baselineSignature: string
  metadata: TurnMetadata
  createdAt: number
}

type OReillyRestoreAnchor = {
  expectedHref: string
  scrollOffset: number | null
  scrollMaximum: number | null
  scrollRatio: number | null
  sourceParagraphIndex: number | null
  sourceUTF16Start: number | null
}

type SourceCursor = {
  direction: 'next' | 'prev'
  element: HTMLElement
  sourceParagraphIndex: number
  offset: number
}

const OREILLY_DIRECT_HOST = 'learning.oreilly.com'
const OREILLY_PROXY_HOST_PREFIX = 'learning-oreilly-com.'
const OREILLY_READER_PATH =
  /^\/library\/view\/[^/]+\/[^/]+(?:\/|$)/i
const CONTENT_ROOT_SELECTOR = '#sbo-rt-content'
const BOTTOM_INSET_ATTRIBUTE = 'data-castreader-oreilly-bottom-inset'
const FRAME_SESSION_PROPERTY = '__castreaderOReillyFrameSessionID'
const PENDING_CHAPTER_TURN_KEY = '__castreaderOReillyPendingChapterTurnV1'
const ADAPTER_VERSION = '2026-07-30-anchor-v2'
const MIN_TEXT_CHARS = 2
const COMPLETE_RECT_TOLERANCE = 0.75
const SETTLE_POLL_MS = 140
const SETTLE_STABLE_MS = 380
const SETTLE_STABLE_SAMPLES = 3
const TURN_TIMEOUT_MS = 6_500
const MANUAL_INTENT_DEBOUNCE_MS = 280
const CHAPTER_TURN_MAX_AGE_MS = 20_000
const MAX_SENTENCE_PREVIEW_CHARS = 260
const READABLE_SELECTOR = [
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'p',
  'li',
  'blockquote',
  'pre',
  'figcaption',
  'dt',
  'dd',
  'caption',
  'th',
  'td',
].join(',')
const EXCLUDED_ANCESTOR_SELECTOR = [
  'nav',
  'aside',
  'header',
  'footer',
  'button',
  '[role="navigation"]',
  '[role="button"]',
  '[role="banner"]',
  '[role="complementary"]',
  '[aria-hidden="true"]',
  '[hidden]',
  '[inert]',
  '[data-testid="statusBar"]',
].join(',')

let oreillyNativeBottomOcclusion = 0
let activeSourceCursor: SourceCursor | null = null

function stableHash32(value: string): number {
  let hash = 0x811C9DC5
  for (let index = 0; index < value.length; index++) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  return hash >>> 0
}

function protocolID(prefix: string): string {
  try {
    if (typeof crypto?.randomUUID === 'function') {
      return `${prefix}-${crypto.randomUUID()}`
    }
  } catch { /* older WKWebView */ }
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

function recordArg(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object'
    ? value as Record<string, unknown>
    : {}
}

function nonemptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0
    ? value.trim()
    : null
}

function nonemptyOpaqueString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

function finiteNumber(value: unknown): number | null {
  const number = Number(value)
  return Number.isFinite(number) ? number : null
}

function urlFrom(value: string | URL): URL | null {
  try {
    return value instanceof URL ? value : new URL(value)
  } catch {
    return null
  }
}

function parseOReillyRestoreAnchor(
  value: unknown
): OReillyRestoreAnchor | null {
  const input = recordArg(value)
  const expectedHref = nonemptyString(input.expectedHref)
  const expected = expectedHref ? urlFrom(expectedHref) : null
  const current = urlFrom(location.href)
  if (
    !expectedHref ||
    !expected ||
    !current ||
    !isSameOReillyChapterIdentity(expected, current)
  ) return null

  const rawParagraphIndex = finiteNumber(input.sourceParagraphIndex)
  const sourceParagraphIndex =
    rawParagraphIndex !== null &&
    Number.isSafeInteger(rawParagraphIndex) &&
    rawParagraphIndex >= 0
      ? rawParagraphIndex
      : null
  const rawSourceStart = finiteNumber(input.sourceUTF16Start)
  const sourceUTF16Start =
    rawSourceStart !== null &&
    Number.isSafeInteger(rawSourceStart) &&
    rawSourceStart >= 0
      ? rawSourceStart
      : null
  const rawOffset = finiteNumber(input.scrollOffset)
  const scrollOffset = rawOffset !== null && rawOffset >= 0
    ? rawOffset
    : null
  const rawMaximum = finiteNumber(input.scrollMaximum)
  const scrollMaximum = rawMaximum !== null && rawMaximum > 0
    ? rawMaximum
    : null
  const rawRatio = finiteNumber(input.scrollRatio)
  const scrollRatio = rawRatio !== null && rawRatio >= 0 && rawRatio <= 1
    ? rawRatio
    : null

  if (
    (sourceParagraphIndex === null || sourceUTF16Start === null) &&
    scrollRatio === null &&
    scrollOffset === null
  ) return null
  return {
    expectedHref: expected.href,
    scrollOffset,
    scrollMaximum,
    scrollRatio,
    sourceParagraphIndex,
    sourceUTF16Start,
  }
}

function trustedOReillyHost(hostname: string): boolean {
  const host = hostname.toLowerCase()
  if (host === OREILLY_DIRECT_HOST) return true
  if (!host.startsWith(OREILLY_PROXY_HOST_PREFIX)) return false

  // Match the native OReillyWebAccessPolicy contract exactly: the rewritten
  // suffix needs at least three valid DNS labels and one label before the
  // registrable-domain pair must explicitly identify a proxy. This rejects a
  // look-alike such as learning-oreilly-com.evil.com.
  const suffix = host.slice(OREILLY_PROXY_HOST_PREFIX.length)
  const labels = suffix.split('.')
  if (labels.length < 3) return false
  const safeDNSLabel = (label: string): boolean => (
    label.length >= 1 &&
    label.length <= 63 &&
    /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)
  )
  if (!labels.every(safeDNSLabel)) return false
  return labels.slice(0, -2).some((label) => label.includes('proxy'))
}

export function oReillyBookID(
  value: string | URL = location.href
): string | null {
  const url = urlFrom(value)
  if (!url) return null
  const match = url.pathname.match(
    /^\/library\/view\/[^/]+\/([^/]+)(?:\/|$)/i
  )
  if (!match) return null
  try {
    const id = decodeURIComponent(match[1]).trim()
    return id.length > 0 ? id : null
  } catch {
    return null
  }
}

export function isTrustedOReillyReaderURL(
  value: string | URL = location.href
): boolean {
  const url = urlFrom(value)
  if (!url) return false
  return (
    url.protocol === 'https:' &&
    trustedOReillyHost(url.hostname) &&
    OREILLY_READER_PATH.test(url.pathname) &&
    oReillyBookID(url) !== null
  )
}

function isSameOReillyChapterIdentity(
  leftValue: string | URL,
  rightValue: string | URL
): boolean {
  const left = urlFrom(leftValue)
  const right = urlFrom(rightValue)
  if (
    !left ||
    !right ||
    !isTrustedOReillyReaderURL(left) ||
    !isTrustedOReillyReaderURL(right)
  ) return false
  // Search/fragment are deliberately excluded: O'Reilly and institutional
  // proxies may canonicalize them after navigation. Origin, book, and exact
  // chapter pathname remain invariant and prevent cross-chapter restoration.
  return (
    left.origin === right.origin &&
    left.pathname === right.pathname &&
    oReillyBookID(left) === oReillyBookID(right)
  )
}

export function isTrustedOReillyChapterURL(
  currentValue: string | URL,
  targetValue: string | URL
): boolean {
  const current = urlFrom(currentValue)
  const target = urlFrom(targetValue)
  if (
    !current ||
    !target ||
    !isTrustedOReillyReaderURL(current) ||
    !isTrustedOReillyReaderURL(target)
  ) return false
  return (
    current.origin === target.origin &&
    oReillyBookID(current) === oReillyBookID(target) &&
    (
      current.pathname !== target.pathname ||
      current.search !== target.search ||
      current.hash !== target.hash
    )
  )
}

export function isOReillyReaderMainFrame(): boolean {
  return window === window.top && isTrustedOReillyReaderURL()
}

type OReillySessionWindow = Window & {
  __castreaderOReillyFrameSessionID?: string
}

export function oReillyFrameSessionID(): string {
  const target = window as OReillySessionWindow
  if (target[FRAME_SESSION_PROPERTY]) {
    return target[FRAME_SESSION_PROPERTY] as string
  }
  const id = `orf-${protocolID('frame')}`
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

export function setOReillyNativeBottomOcclusion(value: number): void {
  if (!Number.isFinite(value)) return
  const viewportHeight = Math.max(
    1,
    window.visualViewport?.height || window.innerHeight || 1
  )
  oreillyNativeBottomOcclusion = Math.max(
    0,
    Math.min(value, viewportHeight - 1)
  )
  const root = contentRoot()
  if (root) ensureBottomScrollInset(root)
}

function contentRoot(): HTMLElement | null {
  const node = document.querySelector(CONTENT_ROOT_SELECTOR)
  return node instanceof HTMLElement ? node : null
}

function ensureBottomScrollInset(root: HTMLElement): void {
  let inset = root.querySelector(
    `:scope > [${BOTTOM_INSET_ATTRIBUTE}]`
  )
  if (!(inset instanceof HTMLElement)) {
    inset = document.createElement('div')
    inset.setAttribute(BOTTOM_INSET_ATTRIBUTE, 'true')
    inset.setAttribute('aria-hidden', 'true')
    inset.style.cssText = [
      'display:block',
      'width:1px',
      'min-width:1px',
      'pointer-events:none',
      'user-select:none',
      'overflow:hidden',
    ].join(';')
    root.appendChild(inset)
  }
  inset.style.height = `${Math.ceil(oreillyNativeBottomOcclusion)}px`
}

function elementStyle(element: Element): CSSStyleDeclaration | null {
  try {
    return element.ownerDocument.defaultView?.getComputedStyle(element) || null
  } catch {
    return null
  }
}

function elementIsRendered(element: HTMLElement): boolean {
  if (element.closest(EXCLUDED_ANCESTOR_SELECTOR)) return false
  let node: HTMLElement | null = element
  while (node) {
    const style = elementStyle(node)
    if (
      style?.display === 'none' ||
      style?.visibility === 'hidden' ||
      Number(style?.opacity || '1') <= 0.01
    ) return false
    node = node.parentElement
  }
  const rects = element.getClientRects()
  return Array.from(rects).some((rect) => rect.width > 0 && rect.height > 0)
}

function hasReadableDescendant(element: HTMLElement): boolean {
  for (const child of Array.from(element.children)) {
    if (
      child.matches(READABLE_SELECTOR) ||
      child.querySelector(READABLE_SELECTOR)
    ) return true
  }
  return false
}

type ReadableEntry = {
  element: HTMLElement
  sourceOrdinal: number
}

function readableEntries(root: HTMLElement): ReadableEntry[] {
  return Array.from(root.querySelectorAll(READABLE_SELECTOR))
    .map((node, sourceOrdinal): ReadableEntry | null => (
      node instanceof HTMLElement ? { element: node, sourceOrdinal } : null
    ))
    .filter((entry): entry is ReadableEntry => entry !== null)
    .filter(({ element }) => {
      const text = element.textContent || ''
      if (text.trim().length < MIN_TEXT_CHARS) return false
      if (!elementIsRendered(element)) return false
      const style = elementStyle(element)
      // Fixed/sticky semantic-looking nodes are reader chrome, floating help,
      // or duplicated accessibility UI rather than chapter flow. Including
      // them is a common cause of one-word "mystery" speech at page end.
      if (style?.position === 'fixed' || style?.position === 'sticky') {
        return false
      }
      // A blockquote/li/table cell can contain real <p> children. Keep only
      // the deepest semantic block so one sentence is never spoken twice.
      if (hasReadableDescendant(element)) return false
      return true
    })
}

function fixedTopOcclusion(root: HTMLElement): number {
  let bottom = 0
  const candidates = Array.from(document.querySelectorAll(
    'header,[role="banner"],[data-testid*="header" i]'
  ))
  for (const candidate of candidates) {
    if (!(candidate instanceof HTMLElement) || root.contains(candidate)) continue
    const style = elementStyle(candidate)
    if (style?.position !== 'fixed' && style?.position !== 'sticky') continue
    if (
      style.display === 'none' ||
      style.visibility === 'hidden' ||
      Number(style.opacity || '1') <= 0.01
    ) continue
    const rect = candidate.getBoundingClientRect()
    if (
      rect.width < window.innerWidth * 0.35 ||
      rect.height <= 0 ||
      rect.top > 2 ||
      rect.bottom <= 0 ||
      rect.bottom >= window.innerHeight * 0.5
    ) continue
    bottom = Math.max(bottom, rect.bottom)
  }
  return bottom
}

export function oReillyViewportClip(): Rect | null {
  const root = contentRoot()
  if (!root) return null
  ensureBottomScrollInset(root)
  const viewportWidth = Math.max(
    1,
    window.visualViewport?.width || window.innerWidth || 1
  )
  const viewportHeight = Math.max(
    1,
    window.visualViewport?.height || window.innerHeight || 1
  )
  const rootRect = root.getBoundingClientRect()
  const left = Math.max(0, rootRect.left)
  const right = Math.min(viewportWidth, rootRect.right)
  const top = Math.max(0, fixedTopOcclusion(root))
  const bottom = Math.min(
    viewportHeight,
    viewportHeight - oreillyNativeBottomOcclusion
  )
  if (right <= left || bottom <= top) return null
  return { left, top, right, bottom }
}

type TextBoundary = { node: Node; offset: number }

function textBoundaryAt(
  element: HTMLElement,
  index: number
): TextBoundary | null {
  const walker = element.ownerDocument.createTreeWalker(
    element,
    NodeFilter.SHOW_TEXT
  )
  let offset = 0
  let node: Node | null
  while ((node = walker.nextNode())) {
    const length = node.textContent?.length || 0
    if (index <= offset + length) {
      return { node, offset: Math.max(0, index - offset) }
    }
    offset += length
  }
  return null
}

function textRange(
  element: HTMLElement,
  start: number,
  end: number
): Range | null {
  const length = (element.textContent || '').length
  if (start < 0 || end <= start || end > length) return null
  const startBoundary = textBoundaryAt(element, start)
  const endBoundary = textBoundaryAt(element, end)
  if (!startBoundary || !endBoundary) return null
  const range = element.ownerDocument.createRange()
  try {
    range.setStart(startBoundary.node, startBoundary.offset)
    range.setEnd(endBoundary.node, endBoundary.offset)
  } catch {
    return null
  }
  return range
}

function alignStartToCodePoint(text: string, index: number): number {
  if (
    index > 0 &&
    index < text.length &&
    text.charCodeAt(index) >= 0xdc00 &&
    text.charCodeAt(index) <= 0xdfff
  ) return index - 1
  return index
}

function alignEndToCodePoint(text: string, index: number): number {
  if (
    index > 0 &&
    index < text.length &&
    text.charCodeAt(index - 1) >= 0xd800 &&
    text.charCodeAt(index - 1) <= 0xdbff
  ) return index + 1
  return index
}

function rectFullyInsideClip(rect: DOMRect, clip: Rect): boolean {
  if (rect.width <= 0 || rect.height <= 0) return false
  return (
    rect.left + COMPLETE_RECT_TOLERANCE >= clip.left &&
    rect.right <= clip.right + COMPLETE_RECT_TOLERANCE &&
    rect.top + COMPLETE_RECT_TOLERANCE >= clip.top &&
    rect.bottom <= clip.bottom + COMPLETE_RECT_TOLERANCE
  )
}

function rangeHasCompleteFragment(
  range: Range | null,
  clip: Rect
): boolean {
  if (!range) return false
  for (const rect of Array.from(range.getClientRects())) {
    if (rectFullyInsideClip(rect, clip)) return true
  }
  return false
}

function rangeIsFullyVisible(
  range: Range | null,
  clip: Rect
): boolean {
  if (!range) return false
  let sawRect = false
  for (const rect of Array.from(range.getClientRects())) {
    if (rect.width <= 0 || rect.height <= 0) continue
    sawRect = true
    if (!rectFullyInsideClip(rect, clip)) return false
  }
  return sawRect
}

/**
 * O'Reilly is a normal continuous document, not a CSS-column pager. The Kobo
 * helper deliberately rejects <=18-character partial source slices touching a
 * column edge; that would discard a legitimate short heading line in a compact
 * landscape viewport. Keep the same complete-rect rule here without that
 * column-residue heuristic.
 */
function oReillyVisibleCharRanges(
  element: HTMLElement,
  clip: Rect
): Array<{ start: number; end: number }> {
  const text = element.textContent || ''
  if (!text) return []
  const ranges: Array<{ start: number; end: number }> = []

  const append = (start: number, end: number): void => {
    const alignedStart = alignStartToCodePoint(text, start)
    const alignedEnd = alignEndToCodePoint(text, end)
    if (alignedEnd <= alignedStart) return
    const prior = ranges[ranges.length - 1]
    if (prior && alignedStart <= prior.end) {
      prior.end = Math.max(prior.end, alignedEnd)
    } else {
      ranges.push({ start: alignedStart, end: alignedEnd })
    }
  }

  const visit = (start: number, end: number): void => {
    if (end <= start) return
    const range = textRange(element, start, end)
    if (!rangeHasCompleteFragment(range, clip)) return
    if (rangeIsFullyVisible(range, clip)) {
      append(start, end)
      return
    }
    if (end - start <= 16) {
      let cursor = start
      while (cursor < end) {
        const next = Math.min(
          end,
          Math.max(
            cursor + 1,
            alignEndToCodePoint(text, cursor + 1)
          )
        )
        if (
          rangeIsFullyVisible(
            textRange(element, cursor, next),
            clip
          )
        ) append(cursor, next)
        cursor = next
      }
      return
    }
    let middle = alignEndToCodePoint(
      text,
      start + ((end - start) >> 1)
    )
    if (middle <= start || middle >= end) middle = start + 1
    visit(start, middle)
    visit(middle, end)
  }

  visit(0, text.length)

  // Whitespace often has no own rect. Preserve a short whitespace-only source
  // gap between two visible runs so English words never concatenate.
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
  return merged
}

function normalizedIdentityText(text: string): string {
  const normalized = text.replace(/\s+/g, ' ').trim()
  return [
    normalized.length,
    normalized.slice(0, 80),
    normalized.slice(-80),
  ].join(':')
}

function elementLogicalIdentity(
  element: HTMLElement,
  ordinal: number
): string {
  const explicit = [
    element.id,
    element.getAttribute('data-testid') || '',
    element.getAttribute('data-id') || '',
    element.getAttribute('data-key') || '',
  ].filter(Boolean).join('|')
  return explicit || [
    element.tagName.toLowerCase(),
    ordinal,
    normalizedIdentityText(element.textContent || ''),
  ].join('|')
}

function chapterIdentity(): string {
  const id = oReillyBookID() || 'unknown'
  return `${id}|${location.pathname}`
}

function sourceID(
  element: HTMLElement,
  ordinal: number
): number {
  // Keep the value in positive signed-32 range for every native decoder.
  return stableHash32(
    `${chapterIdentity()}|${elementLogicalIdentity(element, ordinal)}`
  ) & 0x7fffffff
}

function trimmedSourceSlice(
  full: string,
  start: number,
  end: number
): { text: string; start: number; end: number } | null {
  const raw = full.slice(start, end)
  const withoutLeading = raw.trimStart()
  const leading = raw.length - withoutLeading.length
  const text = withoutLeading.trimEnd()
  if (text.length < MIN_TEXT_CHARS) return null
  const sourceStart = start + leading
  return {
    text,
    start: sourceStart,
    end: sourceStart + text.length,
  }
}

function extractOReillyParagraphsInClip(
  clip: Rect
): OReillyPara[] {
  const root = contentRoot()
  if (!root) return []
  const entries = readableEntries(root)
  const output: OReillyPara[] = []
  const seen = new Set<string>()

  entries.forEach(({ element, sourceOrdinal }) => {
    const rect = element.getBoundingClientRect()
    if (
      rect.right <= clip.left ||
      rect.left >= clip.right ||
      rect.bottom <= clip.top ||
      rect.top >= clip.bottom
    ) return
    const full = element.textContent || ''
    const id = sourceID(element, sourceOrdinal)
    for (const range of oReillyVisibleCharRanges(element, clip)) {
      const slice = trimmedSourceSlice(full, range.start, range.end)
      if (!slice) continue
      const key = `${id}:${slice.start}:${slice.end}`
      if (seen.has(key)) continue
      seen.add(key)
      output.push({
        text: slice.text,
        element,
        exactText: true,
        charOffset: slice.start,
        sourceParagraphIndex: id,
        sourceStart: slice.start,
        sourceEnd: slice.end,
      })
    }
  })
  return output
}

function sourceRelationship(
  cursor: SourceCursor,
  paragraph: OReillyPara
): -1 | 0 | 1 | null {
  const root = contentRoot()
  if (
    !root ||
    !cursor.element.isConnected ||
    !root.contains(cursor.element) ||
    !paragraph.element.isConnected ||
    !root.contains(paragraph.element)
  ) return null
  if (
    cursor.element === paragraph.element &&
    cursor.sourceParagraphIndex === paragraph.sourceParagraphIndex
  ) return 0
  const relationship = cursor.element.compareDocumentPosition(
    paragraph.element
  )
  if (relationship & Node.DOCUMENT_POSITION_FOLLOWING) return 1
  if (relationship & Node.DOCUMENT_POSITION_PRECEDING) return -1
  return null
}

function trimParagraphToRange(
  paragraph: OReillyPara,
  start: number,
  end: number
): OReillyPara | null {
  const full = paragraph.element.textContent || ''
  const slice = trimmedSourceSlice(full, start, end)
  if (!slice) return null
  return {
    ...paragraph,
    text: slice.text,
    charOffset: slice.start,
    sourceStart: slice.start,
    sourceEnd: slice.end,
  }
}

function paragraphsAfterCursor(
  paragraphs: OReillyPara[],
  cursor: SourceCursor
): OReillyPara[] {
  const output: OReillyPara[] = []
  for (const paragraph of paragraphs) {
    const relationship = sourceRelationship(cursor, paragraph)
    if (relationship === null) return paragraphs
    if (relationship < 0) continue
    if (relationship > 0) {
      output.push(paragraph)
      continue
    }
    if (paragraph.sourceEnd <= cursor.offset) continue
    const trimmed = trimParagraphToRange(
      paragraph,
      Math.max(paragraph.sourceStart, cursor.offset),
      paragraph.sourceEnd
    )
    if (trimmed) output.push(trimmed)
  }
  return output
}

function paragraphsBeforeCursor(
  paragraphs: OReillyPara[],
  cursor: SourceCursor
): OReillyPara[] {
  const output: OReillyPara[] = []
  for (const paragraph of paragraphs) {
    const relationship = sourceRelationship(cursor, paragraph)
    if (relationship === null) return paragraphs
    if (relationship > 0) continue
    if (relationship < 0) {
      output.push(paragraph)
      continue
    }
    if (paragraph.sourceStart >= cursor.offset) continue
    const trimmed = trimParagraphToRange(
      paragraph,
      paragraph.sourceStart,
      Math.min(paragraph.sourceEnd, cursor.offset)
    )
    if (trimmed) output.push(trimmed)
  }
  return output
}

function paragraphsApplyingCursor(
  paragraphs: OReillyPara[],
  cursor: SourceCursor | null = activeSourceCursor
): OReillyPara[] {
  if (!cursor) return paragraphs
  return cursor.direction === 'next'
    ? paragraphsAfterCursor(paragraphs, cursor)
    : paragraphsBeforeCursor(paragraphs, cursor)
}

export function extractOReillyParagraphs(): OReillyPara[] {
  const clip = oReillyViewportClip()
  return clip
    ? paragraphsApplyingCursor(extractOReillyParagraphsInClip(clip))
    : []
}

export function acceptOReillyHighlightRect(
  element: HTMLElement,
  rect: DOMRect
): boolean {
  const root = contentRoot()
  const clip = oReillyViewportClip()
  if (!root || !clip || !root.contains(element)) return false
  return (
    rect.width > 0 &&
    rect.height > 0 &&
    rect.left + COMPLETE_RECT_TOLERANCE >= clip.left &&
    rect.right <= clip.right + COMPLETE_RECT_TOLERANCE &&
    rect.top + COMPLETE_RECT_TOLERANCE >= clip.top &&
    rect.bottom <= clip.bottom + COMPLETE_RECT_TOLERANCE
  )
}

function paragraphFingerprint(paragraphs: OReillyPara[]): string {
  if (paragraphs.length === 0) return ''
  const value = paragraphs.map((paragraph) => [
    paragraph.sourceParagraphIndex,
    paragraph.sourceStart,
    paragraph.sourceEnd,
    normalizedIdentityText(paragraph.text),
  ].join(':')).join('|')
  return `orfp-${stableHash32(`${chapterIdentity()}|${value}`).toString(36)}-${paragraphs.length}`
}

export function oReillySignature(): string {
  const paragraphs = extractOReillyParagraphs()
  const fingerprint = paragraphFingerprint(paragraphs)
  return fingerprint
    ? `orpg-${stableHash32(`${chapterIdentity()}|${fingerprint}`).toString(36)}-${paragraphs.length}`
    : ''
}

function lineOverlap(paragraphs: OReillyPara[]): number {
  const tail = paragraphs[paragraphs.length - 1]
  if (!tail) return 28
  const style = elementStyle(tail.element)
  const lineHeight = Number.parseFloat(style?.lineHeight || '')
  const fontSize = Number.parseFloat(style?.fontSize || '')
  const estimated = Number.isFinite(lineHeight)
    ? lineHeight
    : Number.isFinite(fontSize)
      ? fontSize * 1.4
      : 28
  return Math.max(20, Math.min(72, estimated * 1.25))
}

function visualPageStep(): number {
  const clip = oReillyViewportClip()
  if (!clip) return Math.max(120, window.innerHeight * 0.7)
  const height = clip.bottom - clip.top
  // The cursor installed before a turn removes already-spoken source ranges.
  // Retaining roughly one line here prevents a line split by the viewport edge
  // from being skipped on both adjacent pages.
  return Math.max(120, height - lineOverlap(extractOReillyParagraphs()))
}

function shiftedClip(clip: Rect, dy: number): Rect {
  return {
    left: clip.left,
    right: clip.right,
    top: clip.top + dy,
    bottom: clip.bottom + dy,
  }
}

function isForwardPreview(
  current: OReillyPara[],
  candidate: OReillyPara[]
): boolean {
  const tail = current[current.length - 1]
  const head = candidate[0]
  if (!tail || !head) return false
  if (tail.sourceParagraphIndex === head.sourceParagraphIndex) {
    return head.sourceEnd > tail.sourceEnd
  }
  const relationship = tail.element.compareDocumentPosition(head.element)
  return (relationship & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
}

export function extractOReillyNextPagePreview(): OReillyPagePreview | null {
  const clip = oReillyViewportClip()
  if (!clip) return null
  const current = paragraphsApplyingCursor(
    extractOReillyParagraphsInClip(clip)
  )
  if (current.length === 0) return null
  const step = visualPageStep()
  const tail = current[current.length - 1]
  const previewCursor: SourceCursor = {
    direction: 'next',
    element: tail.element,
    sourceParagraphIndex: tail.sourceParagraphIndex,
    offset: tail.sourceEnd,
  }
  // Keep a small geometric overlap to rescue a line clipped by the current
  // bottom edge, then remove the complete source range already on this page.
  const candidate = paragraphsAfterCursor(
    extractOReillyParagraphsInClip(shiftedClip(clip, step)),
    previewCursor
  )
  if (!isForwardPreview(current, candidate)) return null
  const contentFingerprint = paragraphFingerprint(candidate)
  return contentFingerprint
    ? { paragraphs: candidate, contentFingerprint }
    : null
}

function nextSentenceAfter(
  element: HTMLElement,
  sourceParagraphIndex: number,
  start: number
): OReillySpeechPreview | null {
  const full = element.textContent || ''
  let sourceStart = Math.max(0, Math.min(start, full.length))
  while (sourceStart < full.length && /\s/.test(full[sourceStart])) {
    sourceStart++
  }
  if (sourceStart >= full.length) return null
  let sourceEnd = extendToSentenceEnd(
    full,
    Math.min(full.length, sourceStart + 1)
  )
  if (sourceEnd <= sourceStart + 1) {
    sourceEnd = Math.min(
      full.length,
      sourceStart + MAX_SENTENCE_PREVIEW_CHARS
    )
  }
  const raw = full.slice(sourceStart, sourceEnd)
  const text = raw.trimEnd()
  sourceEnd = sourceStart + text.length
  if (text.length < MIN_TEXT_CHARS) return null
  const fingerprintSource =
    `${chapterIdentity()}:${sourceParagraphIndex}:${sourceStart}:${sourceEnd}:${text}`
  return {
    text,
    exactText: true,
    sourceParagraphIndex,
    sourceStart,
    sourceEnd,
    // The native bounded-speech preload contract accepts an eight-character
    // lowercase hexadecimal digest. Keep the source coordinates and exact text
    // in the hash input, but use the shared wire representation so O'Reilly's
    // sentence fallback can actually enter the native preparation pipeline.
    contentFingerprint: stableHash32(fingerprintSource)
      .toString(16)
      .padStart(8, '0'),
  }
}

export function extractOReillyNextSpeechPreview():
OReillySpeechPreview | null {
  const root = contentRoot()
  const current = extractOReillyParagraphs()
  const tail = current[current.length - 1]
  if (!root || !tail) return null
  const sameElement = nextSentenceAfter(
    tail.element,
    tail.sourceParagraphIndex,
    tail.sourceEnd
  )
  if (sameElement) return sameElement

  const entries = readableEntries(root)
  const tailPosition = entries.findIndex(
    (entry) => entry.element === tail.element
  )
  if (tailPosition < 0) return null
  for (
    let position = tailPosition + 1;
    position < entries.length;
    position++
  ) {
    const { element, sourceOrdinal } = entries[position]
    const preview = nextSentenceAfter(
      element,
      sourceID(element, sourceOrdinal),
      0
    )
    if (preview) return preview
  }
  return null
}

function scrollableAncestor(root: HTMLElement): HTMLElement | null {
  let node: HTMLElement | null = root.parentElement
  while (node && node !== document.body && node !== document.documentElement) {
    const style = elementStyle(node)
    const overflow = style?.overflowY || ''
    if (
      /(auto|scroll|overlay)/.test(overflow) &&
      node.scrollHeight > node.clientHeight + 2
    ) return node
    node = node.parentElement
  }
  return null
}

function scrollSurface(): ScrollSurface {
  const root = contentRoot()
  const container = root ? scrollableAncestor(root) : null
  if (container) {
    return {
      position: () => container.scrollTop,
      maximum: () => Math.max(0, container.scrollHeight - container.clientHeight),
      scrollTo: (position) => {
        const top = Math.max(0, Math.min(position, container.scrollHeight))
        try { container.scrollTo({ top, behavior: 'auto' }) }
        catch { container.scrollTop = top }
      },
    }
  }

  const scrolling = (
    document.scrollingElement ||
    document.documentElement ||
    document.body
  ) as HTMLElement
  return {
    position: () => (
      window.scrollY ||
      scrolling.scrollTop ||
      document.documentElement.scrollTop ||
      document.body?.scrollTop ||
      0
    ),
    maximum: () => Math.max(
      0,
      scrolling.scrollHeight -
        (window.visualViewport?.height || window.innerHeight)
    ),
    scrollTo: (position) => {
      const top = Math.max(0, Math.min(position, scrolling.scrollHeight))
      try { window.scrollTo({ top, left: window.scrollX, behavior: 'auto' }) }
      catch { scrolling.scrollTop = top }
    },
  }
}

function oReillyContentMaximumPosition(): number {
  const surface = scrollSurface()
  const current = surface.position()
  const clip = oReillyViewportClip()
  const root = contentRoot()
  if (!clip || !root) return surface.maximum()
  const entries = readableEntries(root)
  let contentBottom = Number.NEGATIVE_INFINITY
  for (const { element } of entries) {
    for (const rect of Array.from(element.getClientRects())) {
      if (rect.width <= 0 || rect.height <= 0) continue
      contentBottom = Math.max(contentBottom, rect.bottom)
    }
  }
  if (!Number.isFinite(contentBottom)) return surface.maximum()
  return Math.max(
    0,
    Math.min(
      surface.maximum(),
      current + contentBottom - clip.bottom
    )
  )
}

/**
 * Return the earliest scroll position where the chapter's first semantic
 * block begins inside the unobscured viewport. A literal scroll position of
 * zero is not always readable: O'Reilly can place chapter content below its
 * fixed header while CastReader's landscape player leaves a short visual
 * viewport. In that layout the heading is only partially visible and the page
 * signature is empty, so a valid SPA chapter transition can never settle.
 *
 * Aligning (rather than skipping) the first semantic block preserves the
 * chapter heading and source offset zero while guaranteeing that extraction
 * has a complete first line to commit.
 */
function oReillyContentMinimumPosition(): number {
  const surface = scrollSurface()
  const current = surface.position()
  const clip = oReillyViewportClip()
  const root = contentRoot()
  if (!clip || !root) return 0
  const entries = readableEntries(root)
  let contentTop = Number.POSITIVE_INFINITY
  for (const { element } of entries) {
    for (const rect of Array.from(element.getClientRects())) {
      if (
        rect.width <= 0 ||
        rect.height <= 0 ||
        rect.right <= clip.left ||
        rect.left >= clip.right
      ) continue
      contentTop = Math.min(contentTop, rect.top)
    }
  }
  if (!Number.isFinite(contentTop)) return 0
  return Math.max(
    0,
    Math.min(
      surface.maximum(),
      current + contentTop - clip.top
    )
  )
}

function oReillySourceAnchorPosition(
  anchor: OReillyRestoreAnchor
): number | null {
  if (
    anchor.sourceParagraphIndex === null ||
    anchor.sourceUTF16Start === null
  ) return null
  const root = contentRoot()
  const clip = oReillyViewportClip()
  if (!root || !clip) return null
  const entry = readableEntries(root).find(
    ({ element, sourceOrdinal }) =>
      sourceID(element, sourceOrdinal) === anchor.sourceParagraphIndex
  )
  if (!entry) return null
  const text = entry.element.textContent || ''
  if (!text) return null

  let sourceStart = Math.max(
    0,
    Math.min(anchor.sourceUTF16Start, Math.max(0, text.length - 1))
  )
  sourceStart = alignStartToCodePoint(text, sourceStart)
  while (sourceStart < text.length && /\s/.test(text[sourceStart])) {
    sourceStart = alignEndToCodePoint(text, sourceStart + 1)
  }
  if (sourceStart >= text.length) return null
  const sourceEnd = Math.min(
    text.length,
    Math.max(
      sourceStart + 1,
      alignEndToCodePoint(text, sourceStart + 1)
    )
  )
  const range = textRange(entry.element, sourceStart, sourceEnd)
  const rect = range
    ? Array.from(range.getClientRects()).find(candidate => (
        candidate.width > 0 &&
        candidate.height > 0 &&
        candidate.right > clip.left &&
        candidate.left < clip.right
      ))
    : null
  if (!rect) return null
  const surface = scrollSurface()
  return Math.max(
    0,
    Math.min(
      surface.maximum(),
      surface.position() + rect.top - clip.top
    )
  )
}

function oReillyFallbackAnchorPosition(
  anchor: OReillyRestoreAnchor
): number | null {
  const surface = scrollSurface()
  const maximum = surface.maximum()
  if (anchor.scrollRatio !== null) {
    return maximum * anchor.scrollRatio
  }
  if (
    anchor.scrollOffset !== null &&
    anchor.scrollMaximum !== null
  ) {
    return maximum * Math.max(
      0,
      Math.min(1, anchor.scrollOffset / anchor.scrollMaximum)
    )
  }
  return anchor.scrollOffset === null
    ? null
    : Math.max(0, Math.min(maximum, anchor.scrollOffset))
}

function applyOReillyRestoreAnchor(
  anchor: OReillyRestoreAnchor
): boolean {
  const current = urlFrom(location.href)
  if (
    !current ||
    !isSameOReillyChapterIdentity(current, anchor.expectedHref) ||
    !contentRoot()
  ) {
    return false
  }
  const target =
    oReillySourceAnchorPosition(anchor) ??
    oReillyFallbackAnchorPosition(anchor)
  if (target === null || !Number.isFinite(target)) return false
  scrollSurface().scrollTo(target)
  return true
}

/**
 * Position a chapter entered through O'Reilly's status bar. Forward chapter
 * navigation starts at its first complete semantic line; backward navigation
 * starts at the final complete visual viewport.
 */
export function positionOReillyChapterEntry(
  direction: 'next' | 'prev'
): number {
  const surface = scrollSurface()
  const target = direction === 'prev'
    ? oReillyContentMaximumPosition()
    : oReillyContentMinimumPosition()
  surface.scrollTo(target)
  return target
}

function chapterContentFingerprint(): string {
  const root = contentRoot()
  if (!root) return ''
  const text = (root.textContent || '').replace(/\s+/g, ' ').trim()
  if (!text) return ''
  const middle = Math.max(0, (text.length >> 1) - 256)
  const sample = [
    text.length,
    text.slice(0, 512),
    text.slice(middle, middle + 512),
    text.slice(-512),
  ].join('|')
  return `orch-${stableHash32(sample).toString(36)}-${text.length}`
}

function trustedChapterLink(
  direction: 'next' | 'prev'
): HTMLAnchorElement | null {
  const currentBookID = oReillyBookID()
  if (!currentBookID) return null
  const testID = direction === 'next'
    ? 'statusBarNext'
    : 'statusBarPrevious'
  const selectors = [
    `[data-testid="${testID}"] a[href]`,
    `a[data-testid="${testID}"][href]`,
    `nav[data-testid="statusBar"] [data-testid="${testID}"] a[href]`,
  ]
  const candidates: HTMLAnchorElement[] = []
  for (const selector of selectors) {
    document.querySelectorAll(selector).forEach((node) => {
      if (node instanceof HTMLAnchorElement && !candidates.includes(node)) {
        candidates.push(node)
      }
    })
  }
  return candidates.find((anchor) => {
    const target = urlFrom(anchor.href)
    if (
      !target ||
      !isTrustedOReillyChapterURL(location.href, target) ||
      oReillyBookID(target) !== currentBookID
    ) return false
    const style = elementStyle(anchor)
    return !(
      anchor.getAttribute('aria-disabled') === 'true' ||
      anchor.hasAttribute('disabled') ||
      style?.display === 'none' ||
      style?.visibility === 'hidden'
    )
  }) || null
}

function clearPageVisuals(): void {
  const bridge = (window as unknown as {
    CR?: Record<string, (arg?: unknown) => unknown>
  }).CR
  try { bridge?.clearHighlight?.({}) } catch { /* stale bridge */ }
  try { bridge?.clearMarks?.({}) } catch { /* stale bridge */ }
}

function storePendingChapterTurn(
  value: StoredChapterTurn
): void {
  try {
    sessionStorage.setItem(PENDING_CHAPTER_TURN_KEY, JSON.stringify(value))
  } catch { /* storage disabled */ }
}

function clearPendingChapterTurn(): void {
  try {
    sessionStorage.removeItem(PENDING_CHAPTER_TURN_KEY)
  } catch { /* storage disabled */ }
}

function consumePendingChapterTurn(): StoredChapterTurn | null {
  try {
    const raw = sessionStorage.getItem(PENDING_CHAPTER_TURN_KEY)
    sessionStorage.removeItem(PENDING_CHAPTER_TURN_KEY)
    if (!raw) return null
    const value = JSON.parse(raw) as StoredChapterTurn
    if (
      value?.version !== 1 ||
      value.bookID !== oReillyBookID() ||
      Date.now() - Number(value.createdAt) > CHAPTER_TURN_MAX_AGE_MS ||
      (value.reason !== 'auto' && value.reason !== 'manual') ||
      (value.direction !== 'next' && value.direction !== 'prev') ||
      !value.metadata
    ) return null
    return value
  } catch {
    return null
  }
}

function automaticMetadata(
  arg: unknown,
  fallbackBaseline: string,
  frameSessionID: string
): AutomaticTurnMetadata {
  const value = recordArg(arg)
  return {
    turnID: nonemptyString(value.turnID) || protocolID('auto'),
    baselineSignature:
      nonemptyOpaqueString(value.baselineSignature) || fallbackBaseline,
    originFrameSessionID:
      nonemptyString(value.originFrameSessionID) || frameSessionID,
  }
}

function manualMetadata(
  arg: unknown,
  fallbackBaseline: string,
  frameSessionID: string
): ManualTurnMetadata {
  const value = recordArg(arg)
  return {
    manualIntentID:
      nonemptyString(value.manualIntentID) || protocolID('manual'),
    baselineSignature:
      nonemptyOpaqueString(value.baselineSignature) || fallbackBaseline,
    originFrameSessionID:
      nonemptyString(value.originFrameSessionID) || frameSessionID,
  }
}

function performVisualTurn(
  direction: 'next' | 'prev',
  beforeChapterClick?: (link: HTMLAnchorElement) => void
): {
  accepted: boolean
  method: 'scroll' | 'chapter' | 'none'
  targetHref?: string
} {
  const surface = scrollSurface()
  const current = surface.position()
  const contentMinimum = Math.min(
    current,
    oReillyContentMinimumPosition()
  )
  const contentMaximum = Math.max(
    current,
    oReillyContentMaximumPosition()
  )
  const step = visualPageStep()
  const target = direction === 'next'
    ? Math.min(contentMaximum, current + step)
    : Math.max(contentMinimum, current - step)
  if (Math.abs(target - current) > 2) {
    surface.scrollTo(target)
    return { accepted: true, method: 'scroll' }
  }

  const link = trustedChapterLink(direction)
  if (!link) return { accepted: false, method: 'none' }
  const targetHref = link.href
  beforeChapterClick?.(link)
  link.click()
  return { accepted: true, method: 'chapter', targetHref }
}

/**
 * Install O'Reilly's page transaction API. `requestExtract` must call the
 * shared cr-bridge extractor and include the supplied reason/metadata in its
 * pageMeta. The adapter intentionally has no native dependencies.
 */
export function installOReillyReader(
  post: Poster,
  requestExtract: (
    reason: string,
    metadata?: Record<string, unknown>
  ) => void,
  frameSessionID: string = oReillyFrameSessionID()
): void {
  const postForFrame = (
    type: string,
    payload: Record<string, unknown> = {}
  ): void => {
    post(type, {
      source: 'oreilly',
      ...payload,
      frameSessionID,
    })
  }

  postForFrame('log', {
    message: `adapter version=${ADAPTER_VERSION}`,
  })

  const restoredChapterTurn = consumePendingChapterTurn()
  activeSourceCursor = null
  let committedSignature = ''
  let observedSignature = ''
  let pendingChange: PendingChange | null = null
  let settleTimer: ReturnType<typeof setTimeout> | null = null
  let settleSignature = ''
  let settleSince = 0
  let settleSamples = 0
  let suppressManualUntil = 0
  let lastManualIntentAt = 0
  let lastScrollPosition = scrollSurface().position()
  let previewTimer: ReturnType<typeof setTimeout> | null = null
  let lastPreviewToken = ''
  let lastSpeechPreviewToken = ''
  let hasPublishedInitialPage = false
  let committedParagraphs: OReillyPara[] = []
  let pendingRestoreAnchor: OReillyRestoreAnchor | null = null
  let protectedRestoreAnchor: OReillyRestoreAnchor | null = null
  let restoreProtectionUntil = 0

  const payloadFor = (
    metadata: TurnMetadata | null
  ): Record<string, unknown> => metadata ? { ...metadata } : {}

  const cancelRestoreProtection = (): void => {
    pendingRestoreAnchor = null
    protectedRestoreAnchor = null
    restoreProtectionUntil = 0
  }

  const applyRestoreAnchor = (
    anchor: OReillyRestoreAnchor
  ): boolean => {
    // Suppress the scroll event before moving. Programmatic restore scrolls
    // are otherwise indistinguishable from a manual visual page transaction.
    suppressManualUntil = Math.max(suppressManualUntil, Date.now() + 900)
    const applied = applyOReillyRestoreAnchor(anchor)
    if (applied) {
      lastScrollPosition = scrollSurface().position()
    }
    return applied
  }

  const installCursorForTurn = (
    direction: 'next' | 'prev'
  ): void => {
    const paragraphs = committedParagraphs.length > 0
      ? committedParagraphs
      : extractOReillyParagraphs()
    const boundary = direction === 'next'
      ? paragraphs[paragraphs.length - 1]
      : paragraphs[0]
    activeSourceCursor = boundary
      ? {
          direction,
          element: boundary.element,
          sourceParagraphIndex: boundary.sourceParagraphIndex,
          offset: direction === 'next'
            ? boundary.sourceEnd
            : boundary.sourceStart,
        }
      : null
  }

  const postLocation = (signature: string): void => {
    const surface = scrollSurface()
    const position = surface.position()
    const maximum = surface.maximum()
    const paragraphs = extractOReillyParagraphs()
    const head = paragraphs[0]
    const tail = paragraphs[paragraphs.length - 1]
    postForFrame('googleBooksLocation', {
      href: location.href,
      signature,
      scrollOffset: Math.max(0, Math.round(position)),
      scrollMaximum: Math.max(0, Math.round(maximum)),
      scrollRatio: maximum > 0
        ? Math.max(0, Math.min(1, position / maximum))
        : 0,
      sourceParagraphIndex: head?.sourceParagraphIndex,
      sourceUTF16Start: head?.sourceStart,
      sourceUTF16End: tail?.sourceEnd,
    })
  }

  const schedulePreview = (): void => {
    if (previewTimer) clearTimeout(previewTimer)
    previewTimer = setTimeout(() => {
      previewTimer = null
      if (pendingChange) return
      const sourceSignature = committedSignature || oReillySignature()
      if (!sourceSignature) return
      const preview = extractOReillyNextPagePreview()
      if (preview?.paragraphs.length) {
        const token = `${sourceSignature}|${preview.contentFingerprint}`
        if (token === lastPreviewToken) return
        lastPreviewToken = token
        postForFrame('googleBooksPagePreview', {
          sourceSignature,
          contentFingerprint: preview.contentFingerprint,
          paragraphs: preview.paragraphs.map((paragraph, paragraphIndex) => ({
            paragraphIndex,
            text: paragraph.text,
            type: 'paragraph',
            sourceParagraphIndex: paragraph.sourceParagraphIndex,
            sourceUTF16Start: paragraph.sourceStart,
            sourceUTF16End: paragraph.sourceEnd,
          })),
        })
        return
      }
      const speech = extractOReillyNextSpeechPreview()
      if (!speech) return
      const token = `${sourceSignature}|${speech.contentFingerprint}`
      if (token === lastSpeechPreviewToken) return
      lastSpeechPreviewToken = token
      postForFrame('googleBooksSpeechPreview', {
        sourceSignature,
        originFrameSessionID: frameSessionID,
        exactText: true,
        sourceParagraphIndex: speech.sourceParagraphIndex,
        sourceUTF16Start: speech.sourceStart,
        sourceUTF16End: speech.sourceEnd,
        text: speech.text,
        contentFingerprint: speech.contentFingerprint,
      })
    }, 160)
  }

  const finishChange = (
    signature: string
  ): void => {
    const change = pendingChange
    if (!change) return
    clearPageVisuals()
    committedSignature = signature
    observedSignature = signature
    committedParagraphs = extractOReillyParagraphs()
    pendingChange = null
    if (change.method === 'chapter') clearPendingChapterTurn()
    postForFrame('googleBooksPageChanging', {
      reason: change.reason,
      phase: 'changed',
      signature,
      baselineSignature: change.baselineSignature,
      ...payloadFor(change.metadata),
    })
    requestExtract(change.reason, payloadFor(change.metadata))
    postLocation(signature)
    schedulePreview()
  }

  const failChange = (
    reason: string
  ): void => {
    const change = pendingChange
    if (!change) return
    pendingChange = null
    activeSourceCursor = change.priorSourceCursor ?? null
    if (change.method === 'chapter' || change.chapterTargetHref) {
      clearPendingChapterTurn()
    }
    if (change.reason === 'auto') {
      postForFrame('googleBooksTurnFailed', {
        method: change.method || 'scroll',
        reason,
        lateEligible: false,
        ...payloadFor(change.metadata),
      })
    } else if (change.reason === 'manual') {
      postForFrame('googleBooksPageChanging', {
        reason: 'manual',
        phase: 'cancelled',
        signature: oReillySignature(),
        baselineSignature: change.baselineSignature,
        ...payloadFor(change.metadata),
      })
    }
  }

  const chapterNavigationReady = (
    change: PendingChange
  ): boolean => {
    if (change.method !== 'chapter') return true
    const current = urlFrom(location.href)
    const start = change.startHref ? urlFrom(change.startHref) : null
    const target = change.chapterTargetHref
      ? urlFrom(change.chapterTargetHref)
      : null
    if (
      !current ||
      !target ||
      !isTrustedOReillyReaderURL(current) ||
      current.origin !== target.origin ||
      oReillyBookID(current) !== oReillyBookID(target) ||
      (start && current.href === start.href)
    ) return false
    const fingerprint = chapterContentFingerprint()
    if (!fingerprint) return false
    return (
      contentRoot() !== change.chapterBaselineRoot ||
      fingerprint !== change.chapterBaselineContentFingerprint
    )
  }

  const beginSettlement = (
    forceCommit = false
  ): void => {
    if (settleTimer) clearTimeout(settleTimer)
    settleSignature = oReillySignature()
    settleSince = Date.now()
    settleSamples = 1

    const verify = (): void => {
      settleTimer = setTimeout(() => {
        settleTimer = null
        const change = pendingChange
        if (!change) return
        if (change.method === 'chapter') {
          if (!chapterNavigationReady(change)) {
            if (Date.now() - change.startedAt > TURN_TIMEOUT_MS) {
              failChange('chapter-navigation-unchanged')
              return
            }
            verify()
            return
          }

          // A full document reload consumes the stored turn in the new
          // adapter. For a SPA transition the same adapter survives, so clear
          // the old-chapter cursor and enforce chapter-entry positioning here.
          activeSourceCursor = null
          const before = scrollSurface().position()
          const target = positionOReillyChapterEntry(
            change.direction || 'next'
          )
          const after = scrollSurface().position()
          lastScrollPosition = after
          suppressManualUntil = Date.now() + 500
          if (
            !change.chapterEntryPositionApplied ||
            Math.abs(after - before) > 1 ||
            Math.abs(after - target) > 2
          ) {
            change.chapterEntryPositionApplied = true
            settleSignature = ''
            settleSince = Date.now()
            settleSamples = 0
            verify()
            return
          }
        }
        const signature = oReillySignature()
        if (signature !== settleSignature) {
          settleSignature = signature
          settleSince = Date.now()
          settleSamples = 1
          if (signature) observedSignature = signature
          verify()
          return
        }
        settleSamples++
        if (
          !signature ||
          settleSamples < SETTLE_STABLE_SAMPLES ||
          Date.now() - settleSince < SETTLE_STABLE_MS
        ) {
          if (Date.now() - change.startedAt > TURN_TIMEOUT_MS) {
            failChange(signature ? 'page-unchanged' : 'page-empty')
            return
          }
          verify()
          return
        }
        if (
          signature === change.baselineSignature &&
          !forceCommit &&
          change.reason !== 'refresh'
        ) {
          if (Date.now() - change.startedAt > TURN_TIMEOUT_MS) {
            failChange('page-unchanged')
            return
          }
          verify()
          return
        }
        finishChange(signature)
      }, SETTLE_POLL_MS)
    }
    verify()
  }

  const announceManualIntent = (
    direction: 'next' | 'prev',
    intent: 'native-control' | 'scroll' | 'wheel' | 'touch' | 'page-key',
    arg?: unknown
  ): boolean => {
    const now = Date.now()
    if (!hasPublishedInitialPage || !committedSignature) return false
    if (pendingChange?.reason === 'manual') return true
    if (pendingChange) return false
    if (now - lastManualIntentAt < MANUAL_INTENT_DEBOUNCE_MS) return false
    lastManualIntentAt = now
    const baseline = committedSignature || oReillySignature()
    const metadata = manualMetadata(arg, baseline, frameSessionID)
    const priorSourceCursor = activeSourceCursor
    pendingChange = {
      reason: 'manual',
      baselineSignature: baseline,
      metadata,
      direction,
      priorSourceCursor,
      startedAt: now,
    }
    if (intent === 'native-control' || intent === 'page-key') {
      installCursorForTurn(direction)
    } else {
      // A drag/wheel can stop at an arbitrary offset rather than advancing a
      // full visual page. Its new visible viewport is authoritative, so do not
      // trim it with the prior page boundary.
      activeSourceCursor = null
    }
    clearPageVisuals()
    postForFrame('googleBooksPageChanging', {
      reason: 'manual',
      phase: 'intent',
      intent,
      direction,
      baselineSignature: baseline,
      ...metadata,
    })
    return true
  }

  const automaticTurn = (
    direction: 'next' | 'prev',
    arg?: unknown
  ): boolean => {
    if (pendingChange || !hasPublishedInitialPage) return false
    cancelRestoreProtection()
    const baseline = committedSignature || oReillySignature()
    if (!baseline) return false
    const metadata = automaticMetadata(arg, baseline, frameSessionID)
    const priorSourceCursor = activeSourceCursor
    pendingChange = {
      reason: 'auto',
      baselineSignature: baseline,
      metadata,
      direction,
      priorSourceCursor,
      startedAt: Date.now(),
    }
    installCursorForTurn(direction)
    suppressManualUntil = Date.now() + 1_200

    // Capture chapter identity before a trusted status link can synchronously
    // trigger either a SPA route change or a full document navigation.
    pendingChange.startHref = location.href
    pendingChange.chapterBaselineContentFingerprint =
      chapterContentFingerprint()
    pendingChange.chapterBaselineRoot = contentRoot()

    clearPageVisuals()
    const result = performVisualTurn(direction, (link) => {
      if (pendingChange) pendingChange.chapterTargetHref = link.href
      storePendingChapterTurn({
        version: 1,
        bookID: oReillyBookID() || '',
        reason: 'auto',
        direction,
        baselineSignature: baseline,
        metadata,
        createdAt: Date.now(),
      })
    })
    if (!result.accepted) {
      failChange('turn-control-missing')
      return false
    }
    if (pendingChange) {
      pendingChange.method = result.method
      if (result.method === 'chapter') {
        pendingChange.chapterTargetHref =
          pendingChange.chapterTargetHref || result.targetHref
      }
    }
    postForFrame('googleBooksTurnRequested', {
      method: result.method,
      direction,
      attempt: 1,
      ...metadata,
    })
    beginSettlement()
    return true
  }

  const manualTurn = (
    direction: 'next' | 'prev',
    arg?: unknown
  ): boolean => {
    if (!announceManualIntent(direction, 'native-control', arg)) return false
    cancelRestoreProtection()
    const change = pendingChange
    if (!change || change.reason !== 'manual' || !change.metadata) return false
    suppressManualUntil = Date.now() + 1_200
    change.startHref = location.href
    change.chapterBaselineContentFingerprint = chapterContentFingerprint()
    change.chapterBaselineRoot = contentRoot()
    const result = performVisualTurn(direction, (link) => {
      change.chapterTargetHref = link.href
      storePendingChapterTurn({
        version: 1,
        bookID: oReillyBookID() || '',
        reason: 'manual',
        direction,
        baselineSignature: change.baselineSignature,
        metadata: change.metadata,
        createdAt: Date.now(),
      })
    })
    if (!result.accepted) {
      failChange('turn-control-missing')
      return false
    }
    change.method = result.method
    if (result.method === 'chapter') {
      change.chapterTargetHref =
        change.chapterTargetHref || result.targetHref
    }
    beginSettlement()
    return true
  }

  const api = {
    nextPage(arg?: unknown): boolean {
      return automaticTurn('next', arg)
    },
    prevPage(arg?: unknown): boolean {
      return automaticTurn('prev', arg)
    },
    userPage(arg?: unknown): boolean {
      const value = recordArg(arg)
      const direction = value.direction
      if (direction !== 'next' && direction !== 'prev') return false
      return manualTurn(direction, arg)
    },
    restoreAnchor(arg?: unknown): boolean {
      if (restoredChapterTurn || pendingChange) return false
      const anchor = parseOReillyRestoreAnchor(arg)
      if (!anchor) return false
      activeSourceCursor = null
      pendingRestoreAnchor = anchor
      const applied = applyRestoreAnchor(anchor)
      if (!applied || !hasPublishedInitialPage) return true

      pendingRestoreAnchor = null
      protectedRestoreAnchor = anchor
      restoreProtectionUntil = Date.now() + 1_800
      const baseline = committedSignature || oReillySignature()
      pendingChange = {
        reason: 'refresh',
        baselineSignature: baseline,
        metadata: null,
        priorSourceCursor: activeSourceCursor,
        startedAt: Date.now(),
      }
      clearPageVisuals()
      beginSettlement(true)
      return true
    },
    refresh(arg?: unknown): void {
      if (pendingChange || !hasPublishedInitialPage) return
      const baseline = committedSignature || oReillySignature()
      const value = recordArg(arg)
      const turnID = nonemptyString(value.turnID)
      const manualIntentID = nonemptyString(value.manualIntentID)
      const reason: TurnReason = turnID
        ? 'auto'
        : manualIntentID
          ? 'manual'
          : 'refresh'
      const metadata = turnID
        ? automaticMetadata(arg, baseline, frameSessionID)
        : manualIntentID
          ? manualMetadata(arg, baseline, frameSessionID)
          : null
      pendingChange = {
        reason,
        baselineSignature: baseline,
        metadata,
        priorSourceCursor: activeSourceCursor,
        startedAt: Date.now(),
      }
      clearPageVisuals()
      beginSettlement(true)
    },
    relayout(arg?: unknown): boolean {
      const value = recordArg(arg)
      const bottomOcclusion = Number(value.bottomOcclusion)
      if (Number.isFinite(bottomOcclusion)) {
        setOReillyNativeBottomOcclusion(bottomOcclusion)
      }
      if (!hasPublishedInitialPage) return true
      if (pendingChange) return true
      const baseline = committedSignature || oReillySignature()
      pendingChange = {
        reason: 'refresh',
        baselineSignature: baseline,
        metadata: null,
        priorSourceCursor: activeSourceCursor,
        startedAt: Date.now(),
      }
      clearPageVisuals()
      beginSettlement(true)
      return true
    },
    retargetTurnBaseline(arg?: unknown): void {
      const value = recordArg(arg)
      const turnID = nonemptyString(value.turnID)
      const baseline = nonemptyOpaqueString(value.detectionBaselineSignature)
      if (
        !turnID ||
        !baseline ||
        pendingChange?.reason !== 'auto' ||
        (pendingChange.metadata as AutomaticTurnMetadata | null)?.turnID !==
          turnID
      ) return
      pendingChange.baselineSignature = baseline
    },
    completeTurn(_arg?: unknown): void {
      // Completion is owned by native after the rendered payload. No adapter
      // tombstone survives a committed O'Reilly visual page.
    },
  }

  ;(window as unknown as {
    CastReaderGoogleBooks?: typeof api
    CastReaderOReilly?: typeof api
  }).CastReaderGoogleBooks = api
  ;(window as unknown as {
    CastReaderOReilly?: typeof api
  }).CastReaderOReilly = api

  const bridge = (window as unknown as {
    CR?: Record<string, unknown>
  }).CR
  if (bridge) {
    Object.assign(bridge, {
      gbNextPage: api.nextPage,
      gbPrevPage: api.prevPage,
      gbManualPage: api.userPage,
      gbRestoreAnchor: api.restoreAnchor,
      gbRefresh: api.refresh,
      gbRelayout: api.relayout,
      gbRetargetTurnBaseline: api.retargetTurnBaseline,
      gbCompleteTurn: api.completeTurn,
    })
  }

  const directionFromPosition = (
    position: number
  ): 'next' | 'prev' => position >= lastScrollPosition ? 'next' : 'prev'

  const beginDetectedManualScroll = (
    intent: 'scroll' | 'wheel' | 'touch' | 'page-key',
    forcedDirection?: 'next' | 'prev'
  ): void => {
    const position = scrollSurface().position()
    if (!hasPublishedInitialPage) {
      lastScrollPosition = position
      return
    }
    const positionChanged = Math.abs(position - lastScrollPosition) > 1
    if (!forcedDirection && !positionChanged) {
      lastScrollPosition = position
      if (pendingChange?.reason === 'manual') beginSettlement()
      return
    }
    const direction = forcedDirection || directionFromPosition(position)
    if (!pendingChange && Date.now() >= suppressManualUntil) {
      announceManualIntent(direction, intent)
    }
    lastScrollPosition = position
    if (pendingChange?.reason === 'manual') beginSettlement()
  }

  let touchStart: { x: number; y: number } | null = null
  document.addEventListener('touchstart', (event) => {
    if (event.isTrusted) cancelRestoreProtection()
    if (!event.isTrusted || event.touches.length !== 1) {
      touchStart = null
      return
    }
    touchStart = {
      x: event.touches[0].clientX,
      y: event.touches[0].clientY,
    }
  }, { capture: true, passive: true })
  document.addEventListener('touchmove', (event) => {
    if (!event.isTrusted || event.touches.length !== 1 || !touchStart) return
    const touch = event.touches[0]
    const dx = touch.clientX - touchStart.x
    const dy = touch.clientY - touchStart.y
    if (Math.abs(dy) < 12 || Math.abs(dy) < Math.abs(dx) * 0.8) return
    beginDetectedManualScroll('touch', dy < 0 ? 'next' : 'prev')
    touchStart = null
  }, { capture: true, passive: true })
  document.addEventListener('touchend', () => {
    touchStart = null
    if (pendingChange?.reason === 'manual') beginSettlement()
  }, { capture: true, passive: true })
  document.addEventListener('touchcancel', () => {
    touchStart = null
    if (pendingChange?.reason === 'manual') beginSettlement()
  }, { capture: true, passive: true })

  document.addEventListener('wheel', (event) => {
    if (!event.isTrusted || Math.abs(event.deltaY) < 1) return
    cancelRestoreProtection()
    const direction = event.deltaY >= 0 ? 'next' : 'prev'
    if (!pendingChange && Date.now() >= suppressManualUntil) {
      announceManualIntent(direction, 'wheel')
    }
  }, { capture: true, passive: true })

  document.addEventListener('keydown', (event) => {
    if (!event.isTrusted || event.repeat) return
    const target = event.target as HTMLElement | null
    if (
      target?.isContentEditable ||
      target?.tagName === 'INPUT' ||
      target?.tagName === 'TEXTAREA'
    ) return
    const directions: Record<string, 'next' | 'prev'> = {
      ArrowDown: 'next',
      PageDown: 'next',
      ' ': event.shiftKey ? 'prev' : 'next',
      ArrowUp: 'prev',
      PageUp: 'prev',
    }
    const direction = directions[event.key]
    if (direction) cancelRestoreProtection()
    if (
      direction &&
      !pendingChange &&
      Date.now() >= suppressManualUntil
    ) {
      if (announceManualIntent(direction, 'page-key')) beginSettlement()
    }
  }, true)

  document.addEventListener('scroll', () => {
    beginDetectedManualScroll('scroll')
  }, { capture: true, passive: true })
  window.addEventListener('scroll', () => {
    beginDetectedManualScroll('scroll')
  }, { passive: true })

  const beginRelayout = (): void => {
    api.relayout({ reason: 'viewport-change' })
  }
  window.addEventListener('resize', beginRelayout, { passive: true })
  window.addEventListener('orientationchange', beginRelayout, { passive: true })
  window.visualViewport?.addEventListener(
    'resize',
    beginRelayout,
    { passive: true }
  )

  let waited = 0
  let bootCandidate = ''
  let bootCandidateSince = 0
  const boot = setInterval(() => {
    waited += 160
    if (
      restoredChapterTurn &&
      contentRoot() &&
      chapterContentFingerprint()
    ) {
      positionOReillyChapterEntry(restoredChapterTurn.direction)
      lastScrollPosition = scrollSurface().position()
    } else if (pendingRestoreAnchor) {
      applyRestoreAnchor(pendingRestoreAnchor)
    }
    const paragraphs = extractOReillyParagraphs()
    const signature = paragraphs.length > 0 ? oReillySignature() : ''
    if (signature && signature !== bootCandidate) {
      bootCandidate = signature
      bootCandidateSince = Date.now()
      return
    }
    if (
      signature &&
      Date.now() - bootCandidateSince >= SETTLE_STABLE_MS
    ) {
      clearInterval(boot)
      committedSignature = signature
      observedSignature = signature
      committedParagraphs = paragraphs
      hasPublishedInitialPage = true
      if (pendingRestoreAnchor) {
        protectedRestoreAnchor = pendingRestoreAnchor
        pendingRestoreAnchor = null
        restoreProtectionUntil = Date.now() + 1_800
        suppressManualUntil = Math.max(
          suppressManualUntil,
          restoreProtectionUntil
        )
      }
      if (restoredChapterTurn) {
        clearPageVisuals()
        postForFrame('googleBooksPageChanging', {
          reason: restoredChapterTurn.reason,
          phase: 'changed',
          signature,
          baselineSignature: restoredChapterTurn.baselineSignature,
          ...restoredChapterTurn.metadata,
        })
        requestExtract(
          restoredChapterTurn.reason,
          payloadFor(restoredChapterTurn.metadata)
        )
      } else {
        requestExtract('initial')
      }
      postLocation(signature)
      schedulePreview()
      return
    }
    if (waited < 15_000) return
    clearInterval(boot)
    hasPublishedInitialPage = true
    requestExtract('initial')
    postForFrame('error', {
      stage: 'oreilly-reader-layout',
      code: 'reader-content-unavailable',
      message: 'O’Reilly reader content did not become available.',
    })
  }, 160)

  // A site script can restore scroll position after our initial stable sample.
  // Observe only meaningful source-coordinate changes; resize is handled by
  // gbRelayout and automatic/native turns already own their transactions.
  setInterval(() => {
    const now = Date.now()
    if (
      protectedRestoreAnchor &&
      now < restoreProtectionUntil
    ) {
      if (applyRestoreAnchor(protectedRestoreAnchor)) {
        const restoredSignature = oReillySignature()
        if (restoredSignature) observedSignature = restoredSignature
        return
      }
    } else if (
      protectedRestoreAnchor &&
      now >= restoreProtectionUntil
    ) {
      protectedRestoreAnchor = null
      restoreProtectionUntil = 0
    }
    const signature = oReillySignature()
    if (!signature || signature === observedSignature) return
    observedSignature = signature
    if (pendingChange) {
      beginSettlement()
      return
    }
    if (Date.now() < suppressManualUntil) return
    const position = scrollSurface().position()
    if (Math.abs(position - lastScrollPosition) > 1) {
      beginDetectedManualScroll('scroll')
    } else {
      // Font/image reflow can change visible source ranges without any scroll.
      // It is a layout refresh, not a user gesture.
      api.relayout({ reason: 'content-reflow' })
    }
  }, 240)
}
