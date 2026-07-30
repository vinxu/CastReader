// Kobo Web Reader (readnow.kobo.com) adapter.
//
// Kobo keeps reflowable EPUB chapters in same-origin srcdoc iframes.  A frame
// can contain several CSS-column pages and the shell can preload many future
// chapter frames.  The important contract is therefore deliberately narrow:
//
//   * current extraction = text fragments that are actually visible now;
//   * preview = at most the immediately adjacent visual page / one sentence;
//   * stable source coordinates = koboSpan/chapter identity + UTF-16 offsets;
//   * page turns use the proven Google Books private wire protocol so native
//     owns one shared playback/pagination state machine.
//
// Do not change this into "current iframe and every iframe after it".  Those
// later frames are Kobo's prefetch buffer, not the user's current page.

import { extendToSentenceEnd, visibleCharRanges } from './play-books'

export type KoboPara = {
  text: string
  element: HTMLElement
  exactText: true
  charOffset: number
  sourceParagraphIndex: number
  sourceStart: number
  sourceEnd: number
  speechText?: string
  /** Internal ordering coordinates. They are never serialized by cr-bridge. */
  frameIndex?: number
  paragraphOrdinal?: number
}

export type KoboSpeechPreview = {
  text: string
  exactText: true
  sourceParagraphIndex: number
  sourceStart: number
  sourceEnd: number
  contentFingerprint: string
}

export type KoboPagePreview = {
  paragraphs: KoboPara[]
  contentFingerprint: string
}

export type KoboTurnMethod =
  'semantic' | 'slider' | 'button' | 'key' | 'hotspot' | 'none'

type Rect = { left: number; top: number; right: number; bottom: number }

type KoboFrame = {
  iframe: HTMLIFrameElement
  doc: Document
  frameIndex: number
  outerRect: DOMRect
  clip: Rect
  scaleX: number
  scaleY: number
  visibleArea: number
}

type Poster = (type: string, payload?: Record<string, unknown>) => void

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

type LateAutomaticTurn = {
  metadata: AutomaticTurnMetadata
  detectionBaselineSignature: string
  expiresAt: number
}

const KOBO_HOST = 'readnow.kobo.com'
const MIN_PARA_CHARS = 2
const MIN_FRAME_TEXT_CHARS = 2
const FRAME_SESSION_PROPERTY = '__castreaderKoboFrameSessionID'
const TYPOGRAPHY_STYLE_ID = 'castreader-kobo-typography'
const KOBO_ADAPTER_VERSION = '2026-07-30-landscape-v3'
const COMPLETE_BLOCK_FRAGMENT_RATIO = 0.98
const COMPLETE_BLOCK_FRAGMENT_TOLERANCE = 0.5
const AUTO_TURN_TOMBSTONE_TTL_MS = 30_000
const REFLOW_MIN_STABLE_MS = 1_250
const REFLOW_MIN_STABLE_SAMPLES = 5
const INITIAL_LAYOUT_MIN_STABLE_MS = 800
const MAX_TRANSIENT_PARTIAL_CHARS = 18
const MAX_CONSECUTIVE_SHORT_PARTIALS = 2
const PARAGRAPH_SELECTOR = [
  'h1.element-title',
  'h2.element-title',
  'h3.element-title',
  '.text p',
  '[id$="-text"] p',
  'section[role="doc-chapter"] p',
  'section[role="doc-part"] p',
  'body p',
].join(',')

type KoboMessageBus = {
  publish: (
    channel: unknown,
    topic: string,
    data: unknown
  ) => unknown | Promise<unknown>
  hasSubscribers?: (channel: unknown, topic: string) => boolean
}

type KoboLocalConfigService = {
  getLocalConfig: () => unknown
}

type KoboURReaderAPI = {
  turnRight?: () => unknown | Promise<unknown>
  turnLeft?: () => unknown | Promise<unknown>
  getCurrentReadingRange?: () => unknown
  goToPageByBookPercentage?: (
    percentage: number
  ) => unknown | Promise<unknown>
  bookView?: unknown
}

type KoboReadingRange = {
  percentageOfBook?: number
  pagesOfBook?: number
  begin?: {
    pageIndexInBook?: number
  }
  end?: {
    pageIndexInBook?: number
  }
}

type KoboSemanticTransport =
  | {
      kind: 'ur-engine'
      service: Record<string, unknown>
      moduleLabel: string
    }
  | {
      kind: 'message-bus'
      bus: KoboMessageBus
      readerChannel: unknown
      moduleLabel: string
    }

let koboSemanticTransport: KoboSemanticTransport | null = null
let koboSemanticTransportPromise: Promise<boolean> | null = null
let koboSemanticTransportFailure = 'not-discovered'
let koboNativeBottomOcclusion = 0

function koboReaderModuleURLs(): string[] {
  const values: string[] = []
  try {
    document.querySelectorAll('script[type="module"][src]').forEach((node) => {
      const src = (node as HTMLScriptElement).src
      if (src) values.push(src)
    })
  } catch { /* partially mounted shell */ }

  const seen = new Set<string>()
  return values
    .filter((raw) => {
      try {
        const url = new URL(raw, location.href)
        return url.origin === location.origin &&
          /\.m?js(?:[?#]|$)/i.test(url.href)
      } catch {
        return false
      }
    })
    .map((raw) => new URL(raw, location.href).href)
    .filter((url) => {
      if (seen.has(url)) return false
      seen.add(url)
      return true
    })
    // The current service getter lives in index.*. Keep every declared module
    // as a bounded fallback, but never guess or import dynamic EPUB chunks.
    .sort((left, right) => {
      const leftIndex = /\/index\./i.test(left) ? 0 : 1
      const rightIndex = /\/index\./i.test(right) ? 0 : 1
      return leftIndex - rightIndex
    })
}

function koboServiceGetters(
  module: Record<string, unknown>
): Array<(name: string) => unknown> {
  const explicit = module.ai
  const output: Array<(name: string) => unknown> = []
  const seen = new Set<unknown>()
  const consider = (value: unknown, trustedAlias: boolean): void => {
    if (typeof value !== 'function' || seen.has(value)) return
    seen.add(value)
    let source = ''
    try { source = Function.prototype.toString.call(value) }
    catch { /* callable proxy */ }
    if (!trustedAlias && !source.includes('UNKNOWN_SERVICE')) return
    output.push(value as (name: string) => unknown)
  }
  consider(explicit, true)
  Object.values(module).forEach((value) => consider(value, value === explicit))
  return output
}

function readerChannelFrom(value: unknown): unknown {
  if (!value || typeof value !== 'object') return null
  const config = value as Record<string, unknown>
  const messageBus = config.MESSAGE_BUS
  if (!messageBus || typeof messageBus !== 'object') return null
  const channels = (messageBus as Record<string, unknown>).CHANNEL
  if (!channels || typeof channels !== 'object') return null
  return (channels as Record<string, unknown>).READER ?? null
}

/**
 * Kobo mobile deliberately omits the desktop previous/next buttons. Both its
 * edge gestures and desktop buttons eventually publish these reader messages,
 * so use that same semantic transport instead of manufacturing untrusted input.
 *
 * Kobo hashes chunk names every release. Discover the already-loaded same-
 * origin EPUB module rather than pinning a filename or export name. `ai` is the
 * current getter alias; the UNKNOWN_SERVICE signature keeps the fallback
 * bounded if minification renames it.
 */
export async function prepareKoboSemanticTransport(): Promise<boolean> {
  if (koboSemanticTransport?.kind === 'ur-engine') return true
  if (koboSemanticTransportPromise) return koboSemanticTransportPromise

  koboSemanticTransportPromise = (async () => {
    const moduleURLs = koboReaderModuleURLs()
    if (moduleURLs.length === 0) {
      if (koboSemanticTransport) return true
      koboSemanticTransportFailure = 'reader-module-not-loaded'
      return false
    }
    const registries: Array<{
      getService: (name: string) => unknown
      moduleLabel: string
    }> = []
    for (const url of moduleURLs) {
      try {
        const imported = await import(url) as Record<string, unknown>
        for (const getService of koboServiceGetters(imported)) {
          registries.push({
            getService,
            moduleLabel: new URL(url).pathname.split('/').pop() || 'index',
          })
        }
      } catch {
        // A resource-timing entry can disappear during Kobo route changes.
      }
    }

    // Kobo's current default `ur` renderer exposes its actual controller API.
    // Prefer it: the legacy message topic intentionally has no UR subscriber.
    for (const registry of registries) {
      try {
        const rawService = registry.getService('UR/engine')
        if (!rawService || typeof rawService !== 'object') continue
        const rawAPI = (rawService as Record<string, unknown>).api
        if (!rawAPI || typeof rawAPI !== 'object') continue
        const api = rawAPI as KoboURReaderAPI
        const hasDirectionalTurn =
          typeof api.turnRight === 'function' &&
          typeof api.turnLeft === 'function'
        const hasExactProgressTurn =
          typeof api.getCurrentReadingRange === 'function' &&
          typeof api.goToPageByBookPercentage === 'function'
        if (!hasDirectionalTurn && !hasExactProgressTurn) continue
        koboSemanticTransport = {
          kind: 'ur-engine',
          service: rawService as Record<string, unknown>,
          moduleLabel: registry.moduleLabel,
        }
        koboSemanticTransportFailure = ''
        return true
      } catch {
        // The legacy renderer registers this service before its API exists.
      }
    }

    if (koboSemanticTransport?.kind === 'message-bus') return true
    for (const registry of registries) {
      try {
        const rawBus = registry.getService('messageBus')
        const rawLocalConfig = registry.getService('localConfig')
        if (
          !rawBus ||
          typeof rawBus !== 'object' ||
          typeof (rawBus as KoboMessageBus).publish !== 'function' ||
          !rawLocalConfig ||
          typeof rawLocalConfig !== 'object' ||
          typeof (rawLocalConfig as KoboLocalConfigService)
            .getLocalConfig !== 'function'
        ) continue
        const readerChannel = readerChannelFrom(
          (rawLocalConfig as KoboLocalConfigService).getLocalConfig()
        )
        if (readerChannel === null || readerChannel === undefined) continue
        koboSemanticTransport = {
          kind: 'message-bus',
          bus: rawBus as KoboMessageBus,
          readerChannel,
          moduleLabel: registry.moduleLabel,
        }
        koboSemanticTransportFailure = ''
        return true
      } catch {
        // This export matched the signature but is not the live registry.
      }
    }
    koboSemanticTransportFailure = 'service-registry-not-found'
    return false
  })().finally(() => {
    koboSemanticTransportPromise = null
  })
  return koboSemanticTransportPromise
}

function koboURReaderIsRTL(api: KoboURReaderAPI): boolean {
  try {
    const bookView = api.bookView as Record<string, unknown> | undefined
    const readingOrderView = bookView?.readingOrderView as
      Record<string, unknown> | undefined
    const bookContext = readingOrderView?.bookContext as
      Record<string, unknown> | undefined
    const isRTL = bookContext?.isRTL
    if (typeof isRTL === 'function') {
      const value = isRTL.call(bookContext)
      if (typeof value === 'boolean') return value
    }
  } catch { /* renderer internals changed */ }
  const visibleFrame = currentKoboFrameClips()[0]
  return documentDirection(visibleFrame?.doc || document) === 'rtl'
}

function currentKoboURAPI(
  transport: Extract<KoboSemanticTransport, { kind: 'ur-engine' }>
): KoboURReaderAPI | null {
  try {
    const raw = transport.service.api
    return raw && typeof raw === 'object'
      ? raw as KoboURReaderAPI
      : null
  } catch {
    return null
  }
}

type KoboExactPageTarget = {
  currentPage: number
  targetPage: number
  pagesOfBook: number
  currentPercentage: number
  targetPercentage: number
}

function exactPageTargetFromRange(
  value: unknown,
  direction: 'next' | 'prev'
): KoboExactPageTarget | null {
  if (!value || typeof value !== 'object') return null
  const range = value as KoboReadingRange
  const pages = Number(range.pagesOfBook)
  const currentPercentage = Number(range.percentageOfBook)
  if (
    !Number.isInteger(pages) ||
    pages <= 1 ||
    !Number.isFinite(currentPercentage) ||
    currentPercentage < 0 ||
    currentPercentage > 1
  ) return null

  const begin = Number(range.begin?.pageIndexInBook)
  const end = Number(range.end?.pageIndexInBook)
  const hasBegin = Number.isInteger(begin) && begin >= 0 && begin < pages
  const hasEnd = Number.isInteger(end) && end >= 0 && end < pages
  // A spread can expose two physical pages at once. Do not guess whether the
  // user expects one leaf or one spread; directional page controls remain the
  // safe fallback for that desktop-only shape.
  if (hasBegin && hasEnd && begin !== end) return null

  const currentPage = hasBegin
    ? begin
    : hasEnd
      ? end
      : Math.floor((pages - 1) * currentPercentage)
  const targetPage = currentPage + (direction === 'next' ? 1 : -1)
  if (targetPage < 0 || targetPage >= pages) return null

  // Kobo reports the current range at the end boundary of the visible page,
  // then maps a requested percentage using floor((pages - 1) * percentage).
  // (targetPage + 1) / pages therefore resolves to exactly targetPage for
  // every valid page, including the final page at 100%.
  const targetPercentage = (targetPage + 1) / pages
  return {
    currentPage,
    targetPage,
    pagesOfBook: pages,
    currentPercentage,
    targetPercentage,
  }
}

function exactPageTargetFromAPI(
  api: KoboURReaderAPI,
  direction: 'next' | 'prev'
): KoboExactPageTarget | null {
  if (
    typeof api.getCurrentReadingRange !== 'function' ||
    typeof api.goToPageByBookPercentage !== 'function'
  ) return null
  try {
    return exactPageTargetFromRange(
      api.getCurrentReadingRange.call(api),
      direction
    )
  } catch {
    return null
  }
}

export function koboSemanticTransportReady(
  direction: 'next' | 'prev' = 'next'
): boolean {
  const transport = koboSemanticTransport
  if (!transport) return false
  if (transport.kind === 'ur-engine') {
    const api = currentKoboURAPI(transport)
    if (!api) return false
    if (exactPageTargetFromAPI(api, direction)) return true
    const rtl = koboURReaderIsRTL(api)
    const turn = direction === 'next'
      ? (rtl ? api.turnLeft : api.turnRight)
      : (rtl ? api.turnRight : api.turnLeft)
    return typeof turn === 'function'
  }
  if (direction !== 'next') return false
  try {
    return transport.bus.hasSubscribers
      ? transport.bus.hasSubscribers(
          transport.readerChannel,
          'rx.navigate.page.next'
        )
      : true
  } catch {
    return false
  }
}

function koboSemanticTransportStatus(): string {
  if (koboSemanticTransport) {
    return `ready:${koboSemanticTransport.kind}:` +
      koboSemanticTransport.moduleLabel
  }
  if (koboSemanticTransportPromise) return 'loading'
  return koboSemanticTransportFailure
}

type KoboSemanticTurnInvocation = {
  accepted: boolean
  completion?: Promise<void>
  details?: Record<string, unknown>
}

function invokeKoboSemanticPageTurn(
  direction: 'next' | 'prev'
): KoboSemanticTurnInvocation {
  const transport = koboSemanticTransport
  if (!transport || !koboSemanticTransportReady(direction)) {
    return { accepted: false }
  }
  try {
    let result: unknown | Promise<unknown>
    if (transport.kind === 'ur-engine') {
      const api = currentKoboURAPI(transport)
      if (!api) return { accepted: false }
      const exactTarget = exactPageTargetFromAPI(api, direction)
      if (
        exactTarget &&
        typeof api.goToPageByBookPercentage === 'function'
      ) {
        result = api.goToPageByBookPercentage.call(
          api,
          exactTarget.targetPercentage
        )
        return {
          accepted: true,
          completion: Promise.resolve(result).then(() => undefined),
          details: {
            transport: 'ur-progress',
            currentPage: exactTarget.currentPage + 1,
            targetPage: exactTarget.targetPage + 1,
            pagesOfBook: exactTarget.pagesOfBook,
            currentPercentage: exactTarget.currentPercentage,
            targetPercentage: exactTarget.targetPercentage,
          },
        }
      } else {
        const rtl = koboURReaderIsRTL(api)
        const turn = direction === 'next'
          ? (rtl ? api.turnLeft : api.turnRight)
          : (rtl ? api.turnRight : api.turnLeft)
        if (typeof turn !== 'function') return { accepted: false }
        result = turn.call(api)
      }
    } else {
      if (direction !== 'next') return { accepted: false }
      result = transport.bus.publish(
        transport.readerChannel,
        'rx.navigate.page.next',
        undefined
      )
    }
    return {
      accepted: true,
      completion: Promise.resolve(result).then(() => undefined),
      details: {
        transport: transport.kind === 'ur-engine'
          ? 'ur-directional'
          : 'legacy-message-bus',
      },
    }
  } catch {
    koboSemanticTransportFailure = 'semantic-call-failed'
    return { accepted: false }
  }
}

declare const __CASTREADER_XCTEST_FIXTURES__: boolean

type KoboSessionWindow = Window & {
  __castreaderKoboFrameSessionID?: string
}

function intersect(a: Rect, b: Rect): Rect | null {
  const left = Math.max(a.left, b.left)
  const top = Math.max(a.top, b.top)
  const right = Math.min(a.right, b.right)
  const bottom = Math.min(a.bottom, b.bottom)
  if (right <= left || bottom <= top) return null
  return { left, top, right, bottom }
}

function rectArea(rect: Rect): number {
  return Math.max(0, rect.right - rect.left) *
    Math.max(0, rect.bottom - rect.top)
}

function topViewport(): Rect {
  const visual = window.visualViewport
  if (visual && visual.width > 1 && visual.height > 1) {
    const bottom = visual.offsetTop + visual.height
    const occlusion = Math.min(
      Math.max(0, koboNativeBottomOcclusion),
      Math.max(0, visual.height - 1)
    )
    return {
      left: visual.offsetLeft,
      top: visual.offsetTop,
      right: visual.offsetLeft + visual.width,
      bottom: bottom - occlusion,
    }
  }
  const height = Math.max(1, window.innerHeight)
  const occlusion = Math.min(
    Math.max(0, koboNativeBottomOcclusion),
    Math.max(0, height - 1)
  )
  return {
    left: 0,
    top: 0,
    right: Math.max(1, window.innerWidth),
    bottom: height - occlusion,
  }
}

function viewportSizeKey(): string {
  const visual = window.visualViewport
  return [
    rounded(window.innerWidth),
    rounded(window.innerHeight),
    rounded(visual?.width || 0),
    rounded(visual?.height || 0),
    rounded(visual?.offsetLeft || 0),
    rounded(visual?.offsetTop || 0),
    rounded(koboNativeBottomOcclusion),
  ].join('x')
}

function normalizeIdentityText(text: string): string {
  const value = text.replace(/\s+/g, ' ').trim()
  return `${value.length}:${value.slice(0, 96)}:${value.slice(-96)}`
}

function stableHash32(value: string): number {
  let hash = 0x811C9DC5
  for (let index = 0; index < value.length; index++) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  return hash >>> 0
}

function logicalAttributes(element: HTMLElement): string {
  const values: string[] = []
  for (const attribute of Array.from(element.attributes)) {
    const name = attribute.name.toLowerCase()
    if (name.indexOf('data-cr-') === 0 || name === 'style') continue
    const logicalData = name.indexOf('data-') === 0 &&
      /(id|key|index|chapter|spine|para|content|page)/.test(name)
    if (
      name === 'id' ||
      name === 'class' ||
      name === 'role' ||
      name === 'epub:type' ||
      logicalData
    ) {
      values.push(`${name}=${attribute.value}`)
    }
  }
  return values.sort().join('&')
}

function isHTMLElementNode(node: Element): node is HTMLElement {
  // Elements from a same-origin iframe belong to that iframe's JavaScript
  // realm, so `node instanceof HTMLElement` in the shell is false.
  return node.nodeType === 1 &&
    typeof (node as HTMLElement).getBoundingClientRect === 'function'
}

function paragraphNodes(doc: Document): HTMLElement[] {
  const nodes = Array.from(doc.querySelectorAll(PARAGRAPH_SELECTOR))
    .filter(isHTMLElementNode)
  const out: HTMLElement[] = []
  const seen = new Set<HTMLElement>()
  for (const node of nodes) {
    if (seen.has(node)) continue
    if (node.tagName.toLowerCase() === 'p' && node.querySelector('p')) continue
    seen.add(node)
    out.push(node)
  }
  return out
}

function documentHasReadableContent(doc: Document): boolean {
  if (!doc.body) return false
  if ((doc.body.textContent || '').trim().length < MIN_FRAME_TEXT_CHARS) return false
  return paragraphNodes(doc).some(
    (element) => (element.textContent || '').trim().length >= MIN_PARA_CHARS
  )
}

/**
 * Kobo occasionally restores a signed-in browser profile before its
 * short-lived reader service session has been recreated. The page remains on
 * a valid readnow.kobo.com URL but renders an in-page MissingSession dialog, so
 * neither navigation status nor cookies can identify it.
 */
export function koboReaderFailureCode(): 'missing-session' | null {
  const text = (
    document.body?.innerText ||
    document.body?.textContent ||
    ''
  ).slice(0, 24_000)
  if (
    /user has no active session/i.test(text) ||
    /["']?MissingSession["']?/i.test(text) ||
    /service\/session-service/i.test(text)
  ) {
    return 'missing-session'
  }
  return null
}

/**
 * Keep WebKit from text-boosting narrow EPUB columns on iPhone. This changes
 * typography inside Kobo's chapter document only; unlike WKWebView.pageZoom it
 * does not shrink the shell, iframe, columns, cover, or highlight coordinates.
 *
 * Returns true when a newly loaded/preloaded chapter was styled. Callers skip
 * signature comparison for that polling pass so our own reflow cannot be
 * mistaken for a manual page turn.
 */
export function ensureKoboChapterTypography(): boolean {
  let changed = false
  const frames = Array.from(document.querySelectorAll('iframe'))
    .filter((node): node is HTMLIFrameElement =>
      node.tagName.toLowerCase() === 'iframe'
    )
  for (const iframe of frames) {
    try {
      const doc = iframe.contentDocument
      if (!doc?.documentElement || doc.getElementById(TYPOGRAPHY_STYLE_ID)) {
        continue
      }
      const style = doc.createElement('style')
      style.id = TYPOGRAPHY_STYLE_ID
      style.textContent = `
        html, body {
          -webkit-text-size-adjust: 100% !important;
          text-size-adjust: 100% !important;
        }
      `
      ;(doc.head || doc.documentElement).appendChild(style)
      changed = true
    } catch {
      // Cross-origin utility frames are outside the book and intentionally
      // remain untouched.
    }
  }
  return changed
}

function ownerStyle(element: HTMLElement): CSSStyleDeclaration | null {
  try {
    return element.ownerDocument.defaultView?.getComputedStyle(element) || null
  } catch {
    return null
  }
}

function writingModeFor(element: HTMLElement): string {
  const style = ownerStyle(element) as (CSSStyleDeclaration & {
    webkitWritingMode?: string
  }) | null
  return style?.writingMode || style?.webkitWritingMode || 'horizontal-tb'
}

function isVerticalWritingMode(mode: string): boolean {
  return /^(vertical|sideways)/i.test(mode)
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
  return full > 0 &&
    visible > 0 &&
    visible + COMPLETE_BLOCK_FRAGMENT_TOLERANCE >=
      full * COMPLETE_BLOCK_FRAGMENT_RATIO
}

function frameClip(
  iframe: HTMLIFrameElement,
  doc: Document,
  frameIndex: number
): KoboFrame | null {
  let style: CSSStyleDeclaration
  try {
    style = getComputedStyle(iframe)
  } catch {
    return null
  }
  if (
    style.display === 'none' ||
    style.visibility === 'hidden' ||
    Number(style.opacity || '1') <= 0.01
  ) return null

  const rect = iframe.getBoundingClientRect()
  if (rect.width <= 1 || rect.height <= 1) return null
  const hit = intersect(
    {
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom,
    },
    topViewport()
  )
  if (!hit) return null

  const layoutWidth = Math.max(1, iframe.offsetWidth || rect.width)
  const layoutHeight = Math.max(1, iframe.offsetHeight || rect.height)
  const scaleX = rect.width / layoutWidth
  const scaleY = rect.height / layoutHeight
  const contentLeft = rect.left + iframe.clientLeft * scaleX
  const contentTop = rect.top + iframe.clientTop * scaleY
  const innerWidth = Math.max(
    1,
    iframe.contentWindow?.innerWidth || iframe.clientWidth || layoutWidth
  )
  const innerHeight = Math.max(
    1,
    iframe.contentWindow?.innerHeight || iframe.clientHeight || layoutHeight
  )
  const mapped: Rect = {
    left: Math.max(0, (hit.left - contentLeft) / scaleX),
    top: Math.max(0, (hit.top - contentTop) / scaleY),
    right: Math.min(innerWidth, (hit.right - contentLeft) / scaleX),
    bottom: Math.min(innerHeight, (hit.bottom - contentTop) / scaleY),
  }
  if (mapped.right <= mapped.left || mapped.bottom <= mapped.top) return null
  return {
    iframe,
    doc,
    frameIndex,
    outerRect: rect,
    clip: mapped,
    scaleX,
    scaleY,
    visibleArea: rectArea(hit),
  }
}

/**
 * Every accessible frame, including Kobo's off-screen prefetch frames.
 * This is used only to walk source order for a one-sentence preview.
 */
function allAccessibleFrames(): Array<{
  iframe: HTMLIFrameElement
  doc: Document
  frameIndex: number
}> {
  const result: Array<{
    iframe: HTMLIFrameElement
    doc: Document
    frameIndex: number
  }> = []
  const frames = Array.from(document.querySelectorAll('iframe'))
    .filter((node): node is HTMLIFrameElement => node instanceof HTMLIFrameElement)
  frames.forEach((iframe, frameIndex) => {
    try {
      const doc = iframe.contentDocument
      if (!doc || !documentHasReadableContent(doc)) return
      result.push({ iframe, doc, frameIndex })
    } catch {
      // Kobo chapters are same-origin. A cross-origin utility frame is not book
      // content and must never become part of the reading snapshot.
    }
  })
  return result
}

/**
 * Visible chapter frames only.  Kobo can show a two-page spread, so retain
 * every frame with meaningful visible area, but reject the off-screen chapter
 * buffer even though its DOM is fully populated.
 */
export function currentKoboFrameClips(): KoboFrame[] {
  const candidates = allAccessibleFrames()
    .map(({ iframe, doc, frameIndex }) => frameClip(iframe, doc, frameIndex))
    .filter((value): value is KoboFrame => value !== null)
  if (candidates.length === 0) return []

  const maxArea = Math.max(...candidates.map((value) => value.visibleArea))
  const viewportArea = rectArea(topViewport())
  const meaningful = candidates.filter((value) =>
    value.visibleArea >= Math.max(900, viewportArea * 0.0125) &&
    value.visibleArea >= maxArea * 0.18
  )
  const selected = meaningful.length > 0
    ? meaningful
    : [candidates.reduce(
        (best, value) => value.visibleArea > best.visibleArea ? value : best
      )]

  const direction = (() => {
    try {
      return getComputedStyle(document.documentElement).direction ||
        getComputedStyle(document.body).direction ||
        'ltr'
    } catch {
      return 'ltr'
    }
  })()
  selected.sort((left, right) => {
    if (Math.abs(left.outerRect.top - right.outerRect.top) > 40) {
      return left.outerRect.top - right.outerRect.top
    }
    return direction === 'rtl'
      ? right.outerRect.left - left.outerRect.left
      : left.outerRect.left - right.outerRect.left
  })
  return selected
}

function rounded(value: number): number {
  return Math.round(Number.isFinite(value) ? value : 0)
}

/**
 * Settlement identity for a rendered Kobo page. Source ranges alone are not
 * enough during rotation: WebKit updates its viewport first and Kobo updates
 * iframe/column geometry later. Both snapshots can keep the same text
 * signature for several polling passes.
 */
function koboGeometryKey(): string {
  const frames = currentKoboFrameClips()
  const frameKeys = frames.map((frame) => {
    const bodyStyle = frame.doc.body ? ownerStyle(frame.doc.body) : null
    const rootStyle = ownerStyle(frame.doc.documentElement)
    const innerWidth =
      frame.iframe.contentWindow?.innerWidth || frame.iframe.clientWidth || 0
    const innerHeight =
      frame.iframe.contentWindow?.innerHeight || frame.iframe.clientHeight || 0
    return [
      frame.frameIndex,
      rounded(frame.outerRect.left),
      rounded(frame.outerRect.top),
      rounded(frame.outerRect.width),
      rounded(frame.outerRect.height),
      rounded(frame.clip.left),
      rounded(frame.clip.top),
      rounded(frame.clip.right),
      rounded(frame.clip.bottom),
      rounded(innerWidth),
      rounded(innerHeight),
      bodyStyle?.columnWidth || '-',
      bodyStyle?.columnGap || '-',
      rootStyle?.writingMode || '-',
    ].join(',')
  })
  return `${viewportSizeKey()}|${frameKeys.join(';')}`
}

/** Metadata-only one-shot geometry trace for real-device layout calibration. */
function koboLayoutDiagnostic(): string {
  const viewport = topViewport()
  const visual = window.visualViewport
  const frames = currentKoboFrameClips()
  const frame = frames[0]
  const anchor = frame ? paragraphNodes(frame.doc)[0] : null
  const style = anchor ? ownerStyle(anchor) : null
  const bodyStyle = frame?.doc.body ? ownerStyle(frame.doc.body) : null
  const rootStyle = frame ? ownerStyle(frame.doc.documentElement) : null
  let bottomOccluder = 0
  const shellNodes = Array.from(document.querySelectorAll('body *')).slice(0, 1200)
  for (const node of shellNodes) {
    const element = node as HTMLElement
    let computed: CSSStyleDeclaration
    try { computed = getComputedStyle(element) } catch { continue }
    if (computed.position !== 'fixed' && computed.position !== 'sticky') continue
    const rect = element.getBoundingClientRect()
    const viewportWidth = viewport.right - viewport.left
    if (
      rect.width < viewportWidth * 0.35 ||
      rect.height < 8 ||
      rect.bottom < viewport.bottom - 2 ||
      rect.top >= viewport.bottom
    ) continue
    bottomOccluder = Math.max(
      bottomOccluder,
      viewport.bottom - Math.max(viewport.top, rect.top)
    )
  }
  return [
    `layout=${rounded(window.innerWidth)}x${rounded(window.innerHeight)}`,
    `visual=${rounded(visual?.width || 0)}x${rounded(visual?.height || 0)}` +
      `@${rounded(visual?.offsetLeft || 0)},${rounded(visual?.offsetTop || 0)}`,
    frame
      ? `iframe=${rounded(frame.outerRect.left)},${rounded(frame.outerRect.top)},` +
        `${rounded(frame.outerRect.width)}x${rounded(frame.outerRect.height)}`
      : 'iframe=none',
    frame
      ? `clip=${rounded(frame.clip.left)},${rounded(frame.clip.top)}-` +
        `${rounded(frame.clip.right)},${rounded(frame.clip.bottom)}`
      : 'clip=none',
    `font=${style?.fontSize || '-'} line=${style?.lineHeight || '-'}`,
    `column=${bodyStyle?.columnWidth || '-'} gap=${bodyStyle?.columnGap || '-'}`,
    `textAdjust=${
      (rootStyle as (CSSStyleDeclaration & {
        webkitTextSizeAdjust?: string
      }) | null)?.webkitTextSizeAdjust ||
      rootStyle?.getPropertyValue('-webkit-text-size-adjust') ||
      '-'
    }`,
    `bottomFixed=${rounded(bottomOccluder)}`,
    `nativeBottom=${rounded(koboNativeBottomOcclusion)}`,
  ].join(' ')
}

function chapterIdentity(element: HTMLElement): string {
  const scope = (
    element.closest(
      'section[role="doc-chapter"],section[role="doc-part"],' +
      'section[epub\\:type],article'
    ) as HTMLElement | null
  ) || element.ownerDocument.body || element
  const spans = Array.from(scope.querySelectorAll('.koboSpan[id]'))
    .filter(isHTMLElementNode)
  const firstSpan = spans[0]?.id || ''
  const lastSpan = spans[spans.length - 1]?.id || ''
  const heading = scope.querySelector(
    'h1.element-title,h2.element-title,h3.element-title,h1,h2,h3'
  ) as HTMLElement | null
  return [
    logicalAttributes(scope),
    `span=${firstSpan}..${lastSpan}`,
    `heading=${normalizeIdentityText(heading?.textContent || '')}`,
  ].join('|')
}

function paragraphSourceID(
  element: HTMLElement,
  paragraphOrdinal: number
): number {
  const spans = Array.from(element.querySelectorAll('.koboSpan[id]'))
    .filter(isHTMLElementNode)
  const firstSpan = spans[0]?.id || ''
  const lastSpan = spans[spans.length - 1]?.id || ''
  const identity = [
    'kobo',
    chapterIdentity(element),
    `ordinal=${paragraphOrdinal}`,
    `spans=${firstSpan}..${lastSpan}`,
    logicalAttributes(element),
    normalizeIdentityText(element.textContent || ''),
  ].join('\u241F')
  return stableHash32(identity) || 1
}

const SENTENCE_TRAILING = '”"\'’」』）)】》〉]'

function trimVisibleRange(
  full: string,
  start: number,
  end: number
): { text: string; start: number; end: number } | null {
  const raw = full.slice(start, end)
  const withoutLeading = raw.trimStart()
  const leadingUTF16 = raw.length - withoutLeading.length
  const text = withoutLeading.trimEnd()
  if (text.length < MIN_PARA_CHARS) return null
  const trimmedStart = start + leadingUTF16
  return {
    text,
    start: trimmedStart,
    end: trimmedStart + text.length,
  }
}

export function koboParagraphSnapshotQuality(
  paragraphs: KoboPara[]
): { ok: boolean; reason: string } {
  let consecutiveShortPartials = 0
  let shortPartialCount = 0
  for (const paragraph of paragraphs) {
    const sourceLength = paragraph.element.textContent?.length ??
      paragraph.sourceEnd
    const isPartial =
      paragraph.sourceStart > 0 || paragraph.sourceEnd < sourceLength
    const isShort =
      paragraph.text.trim().length <= MAX_TRANSIENT_PARTIAL_CHARS
    if (isPartial && isShort) {
      consecutiveShortPartials++
      shortPartialCount++
      if (
        consecutiveShortPartials > MAX_CONSECUTIVE_SHORT_PARTIALS
      ) {
        return {
          ok: false,
          reason: 'consecutive-short-partial-slices',
        }
      }
    } else {
      consecutiveShortPartials = 0
    }
  }

  // A settled page can have one clipped tail at either boundary. Several
  // short partials spread through one snapshot, however, are Kobo's animated
  // neighbouring column—not meaningful prose. Fail closed and let the reflow
  // settlement loop sample again instead of sending word-sized TTS requests.
  if (
    paragraphs.length >= 6 &&
    shortPartialCount >= 4 &&
    shortPartialCount * 2 >= paragraphs.length
  ) {
    return { ok: false, reason: 'short-partial-slice-ratio' }
  }
  return { ok: true, reason: 'ok' }
}

function extractKoboParagraphsFromClips(clips: KoboFrame[]): KoboPara[] {
  const output: KoboPara[] = []
  const seen = new Set<string>()
  for (const frame of clips) {
    const nodes = paragraphNodes(frame.doc)
    nodes.forEach((element, paragraphOrdinal) => {
      const full = element.textContent || ''
      if (full.trim().length < MIN_PARA_CHARS) return
      const id = paragraphSourceID(element, paragraphOrdinal)
      // Rotation can briefly expose non-adjacent CSS columns from the same
      // source paragraph. Keep their source slices separate: bounding the
      // first and last visible character would make TTS speak the invisible
      // column between them.
      visibleCharRanges(element, frame.clip).forEach((range) => {
        const trimmed = trimVisibleRange(full, range.start, range.end)
        if (!trimmed) return
        const key = `${id}:${trimmed.start}:${trimmed.end}`
        if (seen.has(key)) return
        seen.add(key)
        output.push({
          text: trimmed.text,
          element,
          exactText: true,
          charOffset: trimmed.start,
          sourceParagraphIndex: id,
          sourceStart: trimmed.start,
          sourceEnd: trimmed.end,
          frameIndex: frame.frameIndex,
          paragraphOrdinal,
        })
      })
    })
  }

  // Kobo must speak the exact visible slice. Extending this final paragraph
  // to a sentence boundary can pull up to hundreds of characters from a
  // future CSS column into the current page: audio then reads invisible text,
  // TTS takes much longer, and the physical page turn is delayed. The
  // dedicated next-page speech preview owns that continuation instead.
  return koboParagraphSnapshotQuality(output).ok ? output : []
}

/** Exact visible-page extraction. Never includes an off-screen preloaded frame. */
export function extractKoboParagraphs(): KoboPara[] {
  return extractKoboParagraphsFromClips(currentKoboFrameClips())
}

export function acceptKoboHighlightRect(
  element: HTMLElement,
  rect: DOMRect
): boolean {
  const clip = currentKoboFrameClips().find(
    (value) => value.doc === element.ownerDocument
  )
  return !!clip && rectHasCompleteBlockCoverage(
    rect,
    clip.clip,
    writingModeFor(element)
  )
}

function contentFingerprint(paragraphs: KoboPara[]): string {
  if (paragraphs.length === 0) return ''
  const source = paragraphs.map((paragraph) => [
    paragraph.sourceParagraphIndex,
    paragraph.sourceStart,
    paragraph.sourceEnd,
    paragraph.text,
  ].join(':')).join('\u241E')
  return `kcf-${stableHash32(source).toString(36)}-${source.length.toString(36)}`
}

/**
 * Visual page identity.  It intentionally contains no pixel coordinates:
 * transforms animate continuously, while exact source slices identify only the
 * stable page the user can read.
 */
export function koboSignature(): string {
  const paragraphs = extractKoboParagraphs()
  if (paragraphs.length === 0) return ''
  const source = paragraphs.map((paragraph) => [
    paragraph.sourceParagraphIndex,
    paragraph.sourceStart,
    paragraph.sourceEnd,
  ].join(':')).join('|')
  return `kpg-${stableHash32(source).toString(36)}-${paragraphs.length}`
}

function shiftedClip(frame: KoboFrame, dx: number, dy: number): KoboFrame {
  return {
    ...frame,
    clip: {
      left: frame.clip.left + dx,
      right: frame.clip.right + dx,
      top: frame.clip.top + dy,
      bottom: frame.clip.bottom + dy,
    },
  }
}

function isForwardPreview(current: KoboPara[], candidate: KoboPara[]): boolean {
  const tail = current[current.length - 1]
  const head = candidate[0]
  if (!tail || !head) return false
  if (tail.sourceParagraphIndex === head.sourceParagraphIndex) {
    return head.sourceStart >= tail.sourceEnd - 2
  }
  if (
    typeof tail.frameIndex === 'number' &&
    typeof head.frameIndex === 'number' &&
    tail.frameIndex !== head.frameIndex
  ) {
    return head.frameIndex > tail.frameIndex
  }
  return (head.paragraphOrdinal ?? -1) > (tail.paragraphOrdinal ?? -1)
}

function pageAdvanceVectors(frame: KoboFrame, anchor: HTMLElement): Array<{
  dx: number
  dy: number
}> {
  const mode = writingModeFor(anchor)
  const style = ownerStyle(frame.doc.body)
  const direction = style?.direction || 'ltr'
  const width = Math.max(1, frame.clip.right - frame.clip.left)
  const height = Math.max(1, frame.clip.bottom - frame.clip.top)
  const columnGap = (() => {
    const value = Number.parseFloat(style?.columnGap || '')
    return Number.isFinite(value) ? value : 0
  })()
  if (isVerticalWritingMode(mode)) {
    const forward = /-rl$/i.test(mode) ? -1 : 1
    return [
      { dx: forward * (width + columnGap), dy: 0 },
      { dx: -forward * (width + columnGap), dy: 0 },
    ]
  }
  const forward = direction === 'rtl' ? -1 : 1
  return [
    { dx: forward * (width + columnGap), dy: 0 },
    { dx: 0, dy: height },
    { dx: -forward * (width + columnGap), dy: 0 },
  ]
}

/**
 * Read-only adjacent-page preview. It never clicks or changes Kobo's scroll /
 * transform. Failure is expected; the one-sentence source preview is the safe
 * fallback used for continuous audio.
 */
export function extractKoboNextPagePreview(): KoboPagePreview | null {
  const frames = currentKoboFrameClips()
  const current = extractKoboParagraphsFromClips(frames)
  const anchor = current[0]?.element
  if (frames.length === 0 || current.length === 0 || !anchor) return null
  for (const vector of pageAdvanceVectors(frames[0], anchor)) {
    const candidate = extractKoboParagraphsFromClips(
      frames.map((frame) => shiftedClip(frame, vector.dx, vector.dy))
    )
    if (!isForwardPreview(current, candidate)) continue
    const fingerprint = contentFingerprint(candidate)
    if (fingerprint) return { paragraphs: candidate, contentFingerprint: fingerprint }
  }
  return null
}

function firstSentenceAfter(
  element: HTMLElement,
  sourceParagraphIndex: number,
  start: number
): KoboSpeechPreview | null {
  const full = element.textContent || ''
  let sourceStart = Math.max(0, Math.min(start, full.length))
  while (sourceStart < full.length && /\s/.test(full[sourceStart])) sourceStart++
  if (sourceStart >= full.length) return null
  let sourceEnd = extendToSentenceEnd(full, Math.min(full.length, sourceStart + 1))
  if (sourceEnd <= sourceStart + 1) {
    sourceEnd = Math.min(full.length, sourceStart + 260)
  }
  while (sourceEnd < full.length && SENTENCE_TRAILING.indexOf(full[sourceEnd]) >= 0) {
    sourceEnd++
  }
  const raw = full.slice(sourceStart, sourceEnd)
  const text = raw.trimEnd()
  sourceEnd = sourceStart + text.length
  if (text.length < MIN_PARA_CHARS) return null
  const fingerprintSource =
    `${sourceParagraphIndex}:${sourceStart}:${sourceEnd}:${text}`
  return {
    text,
    exactText: true,
    sourceParagraphIndex,
    sourceStart,
    sourceEnd,
    contentFingerprint:
      `ksf-${stableHash32(fingerprintSource).toString(36)}-${text.length}`,
  }
}

/**
 * Source-order preload of exactly one not-yet-spoken sentence. Off-screen
 * frames may be inspected here, but their remaining chapter text is never
 * returned as part of the current page.
 */
export function extractKoboNextSpeechPreview(): KoboSpeechPreview | null {
  const current = extractKoboParagraphs()
  const tail = current[current.length - 1]
  if (!tail) return null
  const spokenTailEnd = tail.sourceEnd
  const sameParagraph = firstSentenceAfter(
    tail.element,
    tail.sourceParagraphIndex,
    spokenTailEnd
  )
  if (sameParagraph) return sameParagraph

  const frames = allAccessibleFrames()
  const currentFramePosition = frames.findIndex(
    (frame) => frame.doc === tail.element.ownerDocument
  )
  if (currentFramePosition < 0) return null
  const tailOrdinal = tail.paragraphOrdinal ??
    paragraphNodes(frames[currentFramePosition].doc).indexOf(tail.element)

  // Current chapter remainder, then at most the next preloaded chapter. This
  // bounds work and prevents a malformed empty chapter from scanning the book.
  for (
    let framePosition = currentFramePosition;
    framePosition <= Math.min(frames.length - 1, currentFramePosition + 1);
    framePosition++
  ) {
    const nodes = paragraphNodes(frames[framePosition].doc)
    const startOrdinal = framePosition === currentFramePosition
      ? tailOrdinal + 1
      : 0
    for (let ordinal = startOrdinal; ordinal < nodes.length; ordinal++) {
      const element = nodes[ordinal]
      const sourceParagraphIndex = paragraphSourceID(element, ordinal)
      const preview = firstSentenceAfter(element, sourceParagraphIndex, 0)
      if (preview) return preview
    }
  }
  return null
}

export function isKoboReaderMainFrame(): boolean {
  return window === window.top && location.hostname.toLowerCase() === KOBO_HOST
}

export function isKoboReaderDescendantFrame(): boolean {
  if (window === window.top) return false
  try {
    return window.top?.location.hostname.toLowerCase() === KOBO_HOST
  } catch {
    try {
      return new URL(document.referrer).hostname.toLowerCase() === KOBO_HOST
    } catch {
      return false
    }
  }
}

export function koboFrameSessionID(): string {
  const target = window as KoboSessionWindow
  if (target[FRAME_SESSION_PROPERTY]) return target[FRAME_SESSION_PROPERTY] as string
  let token = ''
  try {
    if (typeof crypto?.randomUUID === 'function') {
      token = crypto.randomUUID()
    } else if (crypto?.getRandomValues) {
      const words = new Uint32Array(4)
      crypto.getRandomValues(words)
      token = Array.from(words, (word) => word.toString(36)).join('-')
    }
  } catch { /* Math.random fallback */ }
  if (!token) {
    token = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
  }
  const id = `kbf-${token}`
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

function elementIsEnabled(element: HTMLElement): boolean {
  const disabled =
    element.getAttribute('aria-disabled') === 'true' ||
    element.hasAttribute('disabled')
  return !disabled
}

function elementIsVisiblyPresented(element: HTMLElement): boolean {
  const style = ownerStyle(element)
  if (
    style?.display === 'none' ||
    style?.visibility === 'hidden' ||
    Number(style?.opacity || '1') <= 0.01
  ) return false
  const rect = element.getBoundingClientRect()
  return rect.width >= 4 && rect.height >= 4
}

const NEXT_PAGE_LABEL =
  /(next[\s_-]*page|page[\s_-]*next|next\b(?![\s_-]*chapter)|nächste seite|seite weiter|page suivante|página siguiente|siguiente página|pagina successiva|prossima pagina|próxima página|página seguinte|volgende pagina|następna strona|次のページ|下一页|下一頁|다음 페이지)/i
const PREVIOUS_PAGE_LABEL =
  /(prev(?:ious)?[\s_-]*page|page[\s_-]*prev|previous\b(?![\s_-]*chapter)|vorherige seite|seite zurück|page précédente|página anterior|pagina precedente|página anterior|vorige pagina|poprzednia strona|前のページ|上一页|上一頁|이전 페이지)/i
const CHAPTER_LABEL =
  /(next|prev|previous|下一|上一|次の|前の).{0,12}(chapter|chapitre|kapitel|capítulo|capitolo|章)/i

function controlLabel(element: HTMLElement): string {
  return [
    element.getAttribute('aria-label') || '',
    element.getAttribute('title') || '',
    element.getAttribute('data-testid') || '',
    element.getAttribute('data-qa') || '',
    element.id || '',
    element.className || '',
    element.textContent || '',
  ].join(' ').replace(/\s+/g, ' ').trim()
}

type KoboPageControl = {
  element: HTMLElement
  rootLabel: string
  label: string
  visible: boolean
  rootCount: number
  candidateCount: number
}

function koboControlRoots(): Array<{
  root: Document | ShadowRoot
  label: string
}> {
  const roots: Array<{ root: Document | ShadowRoot; label: string }> = []
  const seen = new Set<Document | ShadowRoot>()
  const visit = (root: Document | ShadowRoot, label: string): void => {
    if (seen.has(root) || roots.length >= 64) return
    seen.add(root)
    roots.push({ root, label })

    let iframes: Element[] = []
    try { iframes = Array.from(root.querySelectorAll('iframe')).slice(0, 32) }
    catch { /* detached root */ }
    iframes.forEach((node, index) => {
      try {
        const doc = (node as HTMLIFrameElement).contentDocument
        if (doc) visit(doc, `${label}/frame:${index}`)
      } catch { /* cross-origin utility frame */ }
    })

    // Kobo may mount icon-only reader chrome in an open web-component root.
    let elements: Element[] = []
    try { elements = Array.from(root.querySelectorAll('*')).slice(0, 2500) }
    catch { /* detached root */ }
    elements.forEach((element) => {
      if (element.shadowRoot) {
        visit(
          element.shadowRoot,
          `${label}/shadow:${element.tagName.toLowerCase()}`
        )
      }
    })
  }
  visit(document, 'main')
  return roots
}

function findKoboPageControl(
  direction: 'next' | 'prev'
): KoboPageControl | null {
  const matcher = direction === 'next' ? NEXT_PAGE_LABEL : PREVIOUS_PAGE_LABEL
  const roots = koboControlRoots()
  const matches: Array<{
    element: HTMLElement
    rootLabel: string
    label: string
    visible: boolean
    score: number
  }> = []
  let candidateCount = 0
  for (const entry of roots) {
    let candidates: Element[] = []
    try {
      candidates = Array.from(entry.root.querySelectorAll(
        'button,[role="button"],[aria-label],[title],[data-testid],[data-qa]'
      ))
    } catch {
      continue
    }
    candidateCount += candidates.length
    for (const node of candidates) {
      if (!isHTMLElementNode(node)) continue
      const element = node
      const label = controlLabel(element)
      if (!label || CHAPTER_LABEL.test(label) || !matcher.test(label)) continue
      if (!elementIsEnabled(element)) continue
      const visible = elementIsVisiblyPresented(element)
      const aria = element.getAttribute('aria-label') || ''
      const explicitPageLabel =
        /(next|prev(?:ious)?)[\s_-]*page/i.test(aria)
      const score =
        (visible ? 1_000 : 0) +
        (explicitPageLabel ? 500 : 0) +
        (element.tagName.toLowerCase() === 'button' ? 120 : 0) +
        (element.getAttribute('role') === 'button' ? 60 : 0)
      matches.push({
        element,
        rootLabel: entry.label,
        label,
        visible,
        score,
      })
    }
  }
  matches.sort((left, right) => right.score - left.score)
  const best = matches[0]
  return best ? {
    ...best,
    rootCount: roots.length,
    candidateCount,
  } : null
}

/** Find a page control only; chapter controls are intentionally excluded. */
export function clickableKoboPageButton(
  direction: 'next' | 'prev'
): HTMLElement | null {
  return findKoboPageControl(direction)?.element || null
}

const KOBO_FOOTER_SLIDER_SELECTOR = [
  '[data-test-id="reader-footerBar-slider"]',
  '[data-testid="reader-footerBar-slider"]',
].join(',')
const KOBO_FOOTER_SLIDER_BAR_SELECTOR = [
  '[data-test-id="reader-footerBar-slider-bar"]',
  '[data-testid="reader-footerBar-slider-bar"]',
].join(',')
const KOBO_FOOTER_PAGE_NUMBER_SELECTOR = [
  '[data-test-id="reader-footerBar-pageNumber"]',
  '[data-testid="reader-footerBar-pageNumber"]',
].join(',')

type KoboProgressSliderTarget = KoboExactPageTarget & {
  root: HTMLElement
  bar: HTMLElement
  ownerWindow: Window
  rootLabel: string
  clientX: number
  clientY: number
  barWidth: number
  rtl: boolean
  targetSource: 'ur-range' | 'page-label'
}

function exactPageTargetFromFooterLabel(
  root: Document | ShadowRoot,
  direction: 'next' | 'prev'
): KoboExactPageTarget | null {
  let label: Element | null = null
  try { label = root.querySelector(KOBO_FOOTER_PAGE_NUMBER_SELECTOR) }
  catch { return null }
  const values = (label?.textContent || '').match(/\d[\d,]*/g)
    ?.map((value) => Number(value.replace(/,/g, ''))) || []
  // "7 of 15" is a single mobile page. "7–8 of 15" is a spread and is
  // deliberately rejected so an automatic action never skips a leaf.
  if (values.length !== 2) return null
  const [pageNumber, pages] = values
  if (
    !Number.isInteger(pageNumber) ||
    !Number.isInteger(pages) ||
    pages <= 1 ||
    pageNumber < 1 ||
    pageNumber > pages
  ) return null
  const currentPage = pageNumber - 1
  const targetPage = currentPage + (direction === 'next' ? 1 : -1)
  if (targetPage < 0 || targetPage >= pages) return null
  return {
    currentPage,
    targetPage,
    pagesOfBook: pages,
    currentPercentage: pageNumber / pages,
    targetPercentage: (targetPage + 1) / pages,
  }
}

function currentURPageTarget(
  direction: 'next' | 'prev'
): {
  api: KoboURReaderAPI
  target: KoboExactPageTarget
} | null {
  const transport = koboSemanticTransport
  if (!transport || transport.kind !== 'ur-engine') return null
  const api = currentKoboURAPI(transport)
  if (!api) return null
  const target = exactPageTargetFromAPI(api, direction)
  return target ? { api, target } : null
}

function findKoboProgressSliderTarget(
  direction: 'next' | 'prev'
): KoboProgressSliderTarget | null {
  const urTarget = currentURPageTarget(direction)
  const candidates: KoboProgressSliderTarget[] = []
  for (const entry of koboControlRoots()) {
    let sliders: Element[] = []
    try {
      sliders = Array.from(
        entry.root.querySelectorAll(KOBO_FOOTER_SLIDER_SELECTOR)
      )
    } catch {
      continue
    }
    for (const node of sliders) {
      if (!isHTMLElementNode(node) || !elementIsEnabled(node)) continue
      const barNode = node.querySelector(KOBO_FOOTER_SLIDER_BAR_SELECTOR)
      if (!isHTMLElementNode(barNode)) continue
      const rect = barNode.getBoundingClientRect()
      if (
        !Number.isFinite(rect.left) ||
        !Number.isFinite(rect.width) ||
        rect.width <= 1
      ) continue
      const ownerWindow = node.ownerDocument.defaultView
      if (!ownerWindow) continue
      const pageTarget =
        urTarget?.target ||
        exactPageTargetFromFooterLabel(entry.root, direction)
      if (!pageTarget) continue
      const rtl = urTarget
        ? koboURReaderIsRTL(urTarget.api)
        : documentDirection(node.ownerDocument) === 'rtl'
      const progressX = rect.width * pageTarget.targetPercentage
      const clientX = rtl
        ? rect.right - progressX
        : rect.left + progressX
      const clientY = rect.top + Math.max(0, rect.height / 2)
      candidates.push({
        ...pageTarget,
        root: node,
        bar: barNode,
        ownerWindow,
        rootLabel: entry.label,
        clientX,
        clientY,
        barWidth: rect.width,
        rtl,
        targetSource: urTarget ? 'ur-range' : 'page-label',
      })
    }
  }
  candidates.sort((left, right) => right.barWidth - left.barWidth)
  return candidates[0] || null
}

export function koboProgressSliderReady(
  direction: 'next' | 'prev' = 'next'
): boolean {
  return findKoboProgressSliderTarget(direction) !== null
}

type KoboProgressSliderInvocation = {
  accepted: boolean
  details?: Record<string, unknown>
}

export function invokeKoboProgressSliderTurn(
  direction: 'next' | 'prev'
): KoboProgressSliderInvocation {
  const target = findKoboProgressSliderTarget(direction)
  if (!target) return { accepted: false }
  try {
    target.root.dispatchEvent(new target.ownerWindow.MouseEvent('click', {
      bubbles: true,
      cancelable: true,
      clientX: target.clientX,
      clientY: target.clientY,
      view: target.ownerWindow,
    }))
    return {
      accepted: true,
      details: {
        transport: 'footer-progress',
        root: target.rootLabel,
        currentPage: target.currentPage + 1,
        targetPage: target.targetPage + 1,
        pagesOfBook: target.pagesOfBook,
        currentPercentage: target.currentPercentage,
        targetPercentage: target.targetPercentage,
        targetSource: target.targetSource,
        clientX: Math.round(target.clientX * 10) / 10,
        barWidth: Math.round(target.barWidth * 10) / 10,
        rtl: target.rtl,
      },
    }
  } catch {
    return { accepted: false }
  }
}

function documentDirection(doc: Document = document): 'ltr' | 'rtl' {
  const explicit =
    doc.documentElement.getAttribute('dir') ||
    doc.body?.getAttribute('dir') ||
    ''
  if (explicit.toLowerCase() === 'rtl') return 'rtl'
  try {
    const style = doc.defaultView?.getComputedStyle(doc.documentElement)
    return style?.direction === 'rtl' ? 'rtl' : 'ltr'
  } catch {
    return 'ltr'
  }
}

function keyForDirection(direction: 'next' | 'prev'): {
  key: string
  code: number
} {
  const rtl = documentDirection() === 'rtl'
  const forwardRight = direction === 'next' ? !rtl : rtl
  return forwardRight
    ? { key: 'ArrowRight', code: 39 }
    : { key: 'ArrowLeft', code: 37 }
}

function hotspotPoint(direction: 'next' | 'prev'): { x: number; y: number } {
  const rtl = documentDirection() === 'rtl'
  const forwardRight = direction === 'next' ? !rtl : rtl
  return {
    x: window.innerWidth * (forwardRight ? 0.90 : 0.10),
    y: window.innerHeight * 0.5,
  }
}

/**
 * One semantic request performs exactly one physical method. The caller waits
 * for a new page signature before it ever considers another request.
 */
export function turnKoboPage(
  direction: 'next' | 'prev',
  method: KoboTurnMethod
): KoboTurnMethod {
  if (method === 'slider') {
    return invokeKoboProgressSliderTurn(direction).accepted
      ? 'slider'
      : 'none'
  }
  if (method === 'button') {
    const control = findKoboPageControl(direction)
    if (!control) return 'none'
    control.element.click()
    return 'button'
  }
  if (method === 'key') {
    const { key, code } = keyForDirection(direction)
    const options = {
      key,
      code: key,
      keyCode: code,
      which: code,
      bubbles: true,
      cancelable: true,
    }
    try {
      // Kobo binds its pagination listener on document. Dispatching to the
      // focused element/body works in desktop fixtures but is ignored by the
      // production reader on iOS.
      document.dispatchEvent(
        new KeyboardEvent('keydown', options as KeyboardEventInit)
      )
      document.dispatchEvent(
        new KeyboardEvent('keyup', options as KeyboardEventInit)
      )
      return 'key'
    } catch {
      return 'none'
    }
  }
  if (method === 'hotspot') {
    const { x, y } = hotspotPoint(direction)
    const target = document.elementFromPoint(x, y) as HTMLElement | null
    if (!target) return 'none'
    const options = {
      bubbles: true,
      cancelable: true,
      clientX: x,
      clientY: y,
      view: window,
    }
    try {
      target.dispatchEvent(new MouseEvent('mousedown', options))
      target.dispatchEvent(new MouseEvent('mouseup', options))
      target.dispatchEvent(new MouseEvent('click', options))
      return 'hotspot'
    } catch {
      return 'none'
    }
  }
  return 'none'
}

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
  return typeof value === 'string' && value.trim().length > 0
    ? value.trim()
    : null
}

function nonemptyOpaqueString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

function layoutFailureCode(): string {
  const frames = Array.from(document.querySelectorAll('iframe'))
    .filter((node): node is HTMLIFrameElement => node instanceof HTMLIFrameElement)
  let hasVisualBookSurface = false
  for (const frame of frames) {
    try {
      const doc = frame.contentDocument
      if (!doc?.body) continue
      if (doc.querySelector('canvas,svg,img,object,embed')) {
        hasVisualBookSurface = true
      }
    } catch { /* cross-origin utility frame */ }
  }
  return hasVisualBookSurface
    ? 'fixed-layout-unsupported'
    : 'reader-content-unavailable'
}

/**
 * Installs the Kobo pagination adapter into the top frame. Event names stay
 * `googleBooks*` during this migration so native reuses its mature queue /
 * explain / preloading coordinator; every payload is tagged source=kobo.
 */
export function installKoboReader(
  post: Poster,
  requestExtract: (
    reason: string,
    metadata?: Record<string, unknown>
  ) => void,
  frameSessionID: string = koboFrameSessionID()
): void {
  const postForFrame = (
    type: string,
    payload: Record<string, unknown> = {}
  ): void => {
    post(type, { source: 'kobo', ...payload, frameSessionID })
  }
  const STABILITY_POLL_MS = 180
  const MIN_STABLE_MS = 420
  const TURN_CONFIRMATION_MS = 5200
  postForFrame('log', {
    message: `adapter version=${KOBO_ADAPTER_VERSION}`,
  })
  let committedSignature = koboSignature()
  let observedSignature = committedSignature
  let pendingAuto = false
  let pendingAutoMetadata: AutomaticTurnMetadata | null = null
  let pendingTurnMethod: KoboTurnMethod | null = null
  let pendingTurnBaseline = ''
  let lateAutoTurn: LateAutomaticTurn | null = null
  let preferredMethod: KoboTurnMethod | null = null
  let turnConfirmationTimer: ReturnType<typeof setTimeout> | null = null
  let settleTimer: ReturnType<typeof setTimeout> | null = null
  let changeReasonInFlight: 'auto' | 'manual' | 'refresh' | null = null
  let changeBaseline = ''
  let changeMetadata: TurnMetadata | null = null
  let settleCandidate = ''
  let settleGeometryCandidate = ''
  let settleCandidateSince = 0
  let settleStableSamples = 0
  let pendingManualIntent = false
  let manualIntentExpiresAt = 0
  let manualIntentBaseline = ''
  let manualIntentMetadata: ManualTurnMetadata | null = null
  let manualIntentKind = ''
  let manualSwipeActive = false
  let lastManualIntentAt = 0
  let previewTimer: ReturnType<typeof setTimeout> | null = null
  let lastPreviewToken = ''
  let lastGeometryPreviewMissToken = ''
  let lastSpeechPreviewToken = ''
  let layoutRefreshActive = false
  let layoutRefreshQuietUntil = 0
  let lastViewportSizeKey = viewportSizeKey()
  let hasPublishedInitialPage = false
  let bootCandidate = ''
  let bootGeometryCandidate = ''
  let bootCandidateSince = 0
  const installedListenerDocuments = new WeakSet<Document>()
  let semanticTransportLoggedStatus = ''
  let reportedReaderFailureCode = ''

  const reportReaderFailureIfPresent = (): boolean => {
    const code = koboReaderFailureCode()
    if (!code) return false
    if (reportedReaderFailureCode !== code) {
      reportedReaderFailureCode = code
      postForFrame('log', {
        message: `reader failure detected code=${code}`,
      })
      postForFrame('error', {
        stage: 'kobo-reader-session',
        code,
        message: 'Kobo reader session is temporarily unavailable.',
      })
    }
    return true
  }

  const warmSemanticTransport = (): void => {
    void prepareKoboSemanticTransport().then((ready) => {
      if (!ready) return
      const status = koboSemanticTransportStatus()
      if (status === semanticTransportLoggedStatus) return
      semanticTransportLoggedStatus = status
      postForFrame('log', {
        message: `semantic page transport ${status}`,
      })
    })
  }
  warmSemanticTransport()
  setTimeout(warmSemanticTransport, 800)
  setTimeout(warmSemanticTransport, 2400)
  setTimeout(warmSemanticTransport, 5000)
  setTimeout(warmSemanticTransport, 9000)
  setTimeout(warmSemanticTransport, 14_000)

  const clearPageVisuals = (): void => {
    const bridge = (window as unknown as {
      CR?: Record<string, (arg?: unknown) => unknown>
    }).CR
    try { bridge?.clearHighlight?.({}) } catch { /* replaced frame */ }
    try { bridge?.clearMarks?.({}) } catch { /* replaced frame */ }
  }

  const payloadFor = (
    metadata: TurnMetadata | null
  ): Record<string, unknown> => metadata ? { ...metadata } : {}

  const liveLateAutoTurn = (): LateAutomaticTurn | null => {
    if (lateAutoTurn && Date.now() <= lateAutoTurn.expiresAt) return lateAutoTurn
    lateAutoTurn = null
    return null
  }

  const clearAutoTurn = (): void => {
    pendingAuto = false
    pendingAutoMetadata = null
    pendingTurnMethod = null
    pendingTurnBaseline = ''
    if (turnConfirmationTimer) clearTimeout(turnConfirmationTimer)
    turnConfirmationTimer = null
  }

  const clearManualIntent = (): void => {
    pendingManualIntent = false
    manualIntentExpiresAt = 0
    manualIntentBaseline = ''
    manualIntentMetadata = null
    manualIntentKind = ''
    manualSwipeActive = false
  }

  const clearSettledChange = (
    reason: 'auto' | 'manual' | 'refresh'
  ): void => {
    if (changeReasonInFlight === reason) changeReasonInFlight = null
    changeBaseline = ''
    changeMetadata = null
    settleCandidate = ''
    settleGeometryCandidate = ''
    settleCandidateSince = 0
    settleStableSamples = 0
  }

  const automaticMetadata = (
    arg: unknown,
    fallbackBaseline: string
  ): AutomaticTurnMetadata => {
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
  ): ManualTurnMetadata | null => {
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

  const scheduleNextPagePreview = (attempt = 0): void => {
    if (previewTimer) clearTimeout(previewTimer)
    previewTimer = setTimeout(() => {
      previewTimer = null
      if (
        pendingAuto ||
        pendingManualIntent ||
        manualSwipeActive ||
        changeReasonInFlight !== null
      ) {
        scheduleNextPagePreview(Math.min(attempt + 1, 8))
        return
      }
      const sourceSignature = committedSignature || koboSignature()
      if (!sourceSignature) {
        scheduleNextPagePreview(Math.min(attempt + 1, 8))
        return
      }

      const preview = extractKoboNextPagePreview()
      if (preview?.paragraphs.length) {
        const token = `${sourceSignature}|${preview.contentFingerprint}`
        if (token !== lastPreviewToken) {
          lastPreviewToken = token
          const paragraphs = preview.paragraphs.map(
            (paragraph, paragraphIndex) => {
              const row: Record<string, unknown> = {
                paragraphIndex,
                text: paragraph.text,
                type: 'paragraph',
                sourceParagraphIndex: paragraph.sourceParagraphIndex,
                sourceUTF16Start: paragraph.sourceStart,
                sourceUTF16End: paragraph.sourceEnd,
              }
              if (
                paragraph.speechText &&
                paragraph.speechText !== paragraph.text
              ) {
                row.boundaryUTF16Offset = paragraph.text.length
                row.extendedUTF16Length = paragraph.speechText.length
                row.speechText = paragraph.speechText
              }
              return row
            }
          )
          postForFrame('googleBooksPagePreview', {
            sourceSignature,
            contentFingerprint: preview.contentFingerprint,
            paragraphs,
          })
        }
      } else {
        if (sourceSignature !== lastGeometryPreviewMissToken) {
          lastGeometryPreviewMissToken = sourceSignature
          postForFrame('googleBooksPreviewDiagnostic', {
            event: 'geometry-miss',
            sourceSignature,
            attempt,
          })
        }
        const speech = extractKoboNextSpeechPreview()
        if (speech) {
          const token = `${sourceSignature}|${speech.contentFingerprint}`
          if (token !== lastSpeechPreviewToken) {
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
            postForFrame('googleBooksPreviewDiagnostic', {
              event: 'source-preview',
              sourceSignature,
              sourceParagraphIndex: speech.sourceParagraphIndex,
              sourceUTF16Start: speech.sourceStart,
              sourceUTF16End: speech.sourceEnd,
              contentFingerprint: speech.contentFingerprint,
            })
          }
        }
      }
      // Read-only observation can stay alive for the spoken page; Kobo often
      // creates the adjacent column only after fonts and images settle.
      scheduleNextPagePreview(attempt < 6 ? attempt + 1 : 7)
    }, attempt === 0 ? 120 : attempt <= 6 ? 360 : 1100)
  }

  const beginSettlement = (
    reason: 'auto' | 'manual' | 'refresh',
    attempt = 0,
    forceExtract = false
  ): void => {
    if (settleTimer) clearTimeout(settleTimer)
    settleCandidate = koboSignature()
    settleGeometryCandidate = koboGeometryKey()
    settleCandidateSince = Date.now()
    settleStableSamples = 1

    const verify = (): void => {
      settleTimer = setTimeout(() => {
        settleTimer = null
        const current = koboSignature()
        const currentGeometry = koboGeometryKey()
        if (
          current !== settleCandidate ||
          currentGeometry !== settleGeometryCandidate
        ) {
          if (current) observedSignature = current
          settleCandidate = current
          settleGeometryCandidate = currentGeometry
          settleCandidateSince = Date.now()
          settleStableSamples = 1
          verify()
          return
        }
        settleStableSamples++
        const isLayoutRefresh = layoutRefreshActive
        const requiredSamples = isLayoutRefresh
          ? REFLOW_MIN_STABLE_SAMPLES
          : 2
        const requiredStableMS = isLayoutRefresh
          ? REFLOW_MIN_STABLE_MS
          : MIN_STABLE_MS
        if (
          settleStableSamples < requiredSamples ||
          Date.now() - settleCandidateSince < requiredStableMS ||
          (isLayoutRefresh && Date.now() < layoutRefreshQuietUntil) ||
          (reason === 'manual' && manualSwipeActive)
        ) {
          verify()
          return
        }

        const paragraphs = extractKoboParagraphs()
        if (paragraphs.length === 0 && attempt < 8) {
          beginSettlement(reason, attempt + 1, forceExtract)
          return
        }
        if (paragraphs.length === 0) {
          const metadata =
            changeMetadata ||
            (reason === 'auto' ? pendingAutoMetadata : manualIntentMetadata)
          if (reason === 'auto') {
            const method = pendingTurnMethod || 'none'
            clearAutoTurn()
            postForFrame('googleBooksTurnFailed', {
              method,
              reason: 'stable-page-empty',
              lateEligible: false,
              ...payloadFor(metadata),
            })
          } else if (reason === 'manual') {
            postForFrame('googleBooksPageChanging', {
              reason: 'manual',
              phase: 'cancelled',
              signature: current,
              baselineSignature: changeBaseline,
              ...payloadFor(metadata),
            })
            clearManualIntent()
          }
          postForFrame('error', {
            stage: 'kobo-page-extract',
            code: layoutFailureCode(),
            message: 'Kobo changed page but no readable reflowable text was available.',
          })
          clearSettledChange(reason)
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
            const method = pendingTurnMethod || 'none'
            const metadata =
              changeMetadata as AutomaticTurnMetadata | null ||
              pendingAutoMetadata
            clearAutoTurn()
            postForFrame('googleBooksTurnFailed', {
              method,
              reason: 'returned-to-baseline',
              lateEligible: false,
              ...payloadFor(metadata),
            })
          }
          if (finalSignature) observedSignature = finalSignature
          clearSettledChange(reason)
          return
        }

        const committedMetadata =
          changeMetadata ||
          (reason === 'auto' ? pendingAutoMetadata : null) ||
          (reason === 'manual' ? manualIntentMetadata : null)
        if (reason === 'auto') {
          if (pendingTurnMethod) preferredMethod = pendingTurnMethod
          clearAutoTurn()
        } else if (reason === 'manual') {
          clearManualIntent()
        }
        if (finalSignature) {
          committedSignature = finalSignature
          observedSignature = finalSignature
        }
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
        layoutRefreshActive = false
        clearSettledChange(reason)
        scheduleNextPagePreview()
      }, STABILITY_POLL_MS)
    }
    verify()
  }

  const beginLayoutRefresh = (source: string): void => {
    const now = Date.now()
    layoutRefreshActive = true
    layoutRefreshQuietUntil = Math.max(
      layoutRefreshQuietUntil,
      now + REFLOW_MIN_STABLE_MS
    )
    lastViewportSizeKey = viewportSizeKey()

    // Before boot, only hold the initial extractor behind the reflow gate.
    // Publishing a refresh first would race the adapter's canonical initial
    // page and let native start TTS twice.
    if (!hasPublishedInitialPage) return

    // A real touch/native/automatic turn keeps its ownership. Geometry is
    // still part of its settlement key and therefore receives the longer
    // reflow stability window above.
    if (
      pendingAuto ||
      manualSwipeActive ||
      (pendingManualIntent && manualIntentKind !== 'detected')
    ) return

    // Polling can observe the first resize-created signature a few
    // milliseconds before WebKit dispatches resize. Retract only that
    // synthetic "detected" intent; genuine swipe/click intents are untouched.
    if (pendingManualIntent && manualIntentKind === 'detected') {
      const metadata = manualIntentMetadata
      postForFrame('googleBooksPageChanging', {
        reason: 'manual',
        phase: 'cancelled',
        signature: koboSignature(),
        baselineSignature: manualIntentBaseline,
        ...payloadFor(metadata),
      })
      clearManualIntent()
    }
    if (settleTimer) clearTimeout(settleTimer)
    settleTimer = null
    if (changeReasonInFlight && changeReasonInFlight !== 'refresh') {
      clearSettledChange(changeReasonInFlight)
    }
    changeReasonInFlight = 'refresh'
    changeBaseline = committedSignature
    changeMetadata = null
    clearPageVisuals()
    postForFrame('log', {
      message:
        `layout refresh source=${source} viewport=${viewportSizeKey()} ` +
        `geometry=${koboGeometryKey().slice(0, 180)}`,
    })
    beginSettlement('refresh', 0, true)
  }

  const methodAvailable = (
    method: KoboTurnMethod,
    direction: 'next' | 'prev'
  ): boolean => {
    if (method === 'semantic') {
      return koboSemanticTransportReady(direction)
    }
    if (method === 'slider') {
      return koboProgressSliderReady(direction)
    }
    if (method === 'button') return clickableKoboPageButton(direction) !== null
    // Synthetic KeyboardEvents in WKWebView are untrusted. Dispatching one
    // without throwing only proves JavaScript ran, not that Kobo paginated.
    if (method === 'key') return false
    if (method === 'hotspot') {
      const point = hotspotPoint(direction)
      return document.elementFromPoint(point.x, point.y) !== null
    }
    return false
  }

  const attemptTurn = (
    direction: 'next' | 'prev',
    arg?: unknown
  ): boolean => {
    if (pendingAuto) return false
    const visualBaseline = koboSignature() || committedSignature
    const metadata = automaticMetadata(arg, visualBaseline)
    const remembered = preferredMethod ? [preferredMethod] : []
    const candidates: KoboTurnMethod[] = [
      'semantic',
      'slider',
      ...remembered,
      'button',
    ]
    const method = candidates.find(
      (candidate, index) =>
        candidates.indexOf(candidate) === index &&
        methodAvailable(candidate, direction)
    ) || 'none'
    if (method === 'none') {
      postForFrame('log', {
        message:
          `turn control missing direction=${direction} ` +
          `semantic=${koboSemanticTransportStatus()} ` +
          `slider=${koboProgressSliderReady(direction) ? 'ready' : 'missing'} ` +
          `roots=${koboControlRoots().length}`,
      })
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
    // Keep the final spoken-word highlight on the still-visible page. Native
    // requests the physical turn only after audio completion, and the
    // signature-departure branch below clears visuals as soon as Kobo really
    // starts showing another page. Clearing here causes a conspicuous blank
    // interval while a slow turn animation has not even begun.
    pendingTurnMethod = method

    const armTurnConfirmation = (): void => {
      if (turnConfirmationTimer) clearTimeout(turnConfirmationTimer)
      turnConfirmationTimer = setTimeout(() => {
        turnConfirmationTimer = null
        if (!pendingAuto || koboSignature() !== pendingTurnBaseline) return
        const failedMethod = pendingTurnMethod || method
        const failedMetadata = pendingAutoMetadata
        const failedBaseline = pendingTurnBaseline
        if (failedMetadata) {
          lateAutoTurn = {
            metadata: failedMetadata,
            detectionBaselineSignature: failedBaseline,
            expiresAt: Date.now() + AUTO_TURN_TOMBSTONE_TTL_MS,
          }
        }
        clearAutoTurn()
        postForFrame('googleBooksTurnFailed', {
          method: failedMethod,
          lateEligible: true,
          ...payloadFor(failedMetadata),
        })
      }, TURN_CONFIRMATION_MS)
    }

    if (method === 'slider') {
      const invocation = invokeKoboProgressSliderTurn(direction)
      if (!invocation.accepted) {
        clearAutoTurn()
        postForFrame('log', {
          message: `progress slider rejected direction=${direction}`,
        })
        postForFrame('googleBooksTurnFailed', {
          method,
          lateEligible: false,
          ...metadata,
        })
        return false
      }
      postForFrame('googleBooksTurnRequested', {
        method,
        attempt: 1,
        ...(invocation.details || {}),
        ...metadata,
      })
      armTurnConfirmation()
      return true
    }

    if (method === 'semantic') {
      const invocation = invokeKoboSemanticPageTurn(direction)
      if (!invocation.accepted) {
        clearAutoTurn()
        postForFrame('log', {
          message:
            `semantic turn rejected direction=${direction} ` +
            `status=${koboSemanticTransportStatus()}`,
        })
        postForFrame('googleBooksTurnFailed', {
          method,
          lateEligible: false,
          ...metadata,
        })
        return false
      }
      postForFrame('googleBooksTurnRequested', {
        method,
        attempt: 1,
        transport: koboSemanticTransportStatus(),
        ...(invocation.details || {}),
        ...metadata,
      })
      armTurnConfirmation()
      void invocation.completion?.catch(() => {
        if (
          !pendingAuto ||
          pendingAutoMetadata?.turnID !== metadata.turnID ||
          koboSignature() !== pendingTurnBaseline
        ) return
        clearAutoTurn()
        koboSemanticTransportFailure = 'semantic-promise-rejected'
        koboSemanticTransport = null
        warmSemanticTransport()
        postForFrame('log', {
          message:
            `semantic turn promise rejected direction=${direction} ` +
            `status=${koboSemanticTransportStatus()}`,
        })
        postForFrame('googleBooksTurnFailed', {
          method,
          lateEligible: false,
          ...metadata,
        })
      })
      return true
    }

    pendingTurnMethod = turnKoboPage(direction, method)
    if (pendingTurnMethod === 'none') {
      clearAutoTurn()
      postForFrame('googleBooksTurnFailed', {
        method,
        lateEligible: false,
        ...metadata,
      })
      return false
    }
    const clickedControl = findKoboPageControl(direction)
    if (clickedControl) {
      postForFrame('log', {
        message:
          `turn click root=${clickedControl.rootLabel} ` +
          `visible=${clickedControl.visible ? 'Y' : 'N'} ` +
          `roots=${clickedControl.rootCount} ` +
          `candidates=${clickedControl.candidateCount} ` +
          `label=${clickedControl.label.slice(0, 120)}`,
      })
    }
    postForFrame('googleBooksTurnRequested', {
      method: pendingTurnMethod,
      attempt: 1,
      ...metadata,
    })
    armTurnConfirmation()
    return true
  }

  const attemptManualTurn = (
    direction: 'next' | 'prev'
  ): boolean => {
    if (pendingAuto || pendingManualIntent) return false
    const remembered = preferredMethod ? [preferredMethod] : []
    const candidates: KoboTurnMethod[] = [
      'semantic',
      'slider',
      ...remembered,
      'button',
    ]
    const method = candidates.find(
      (candidate, index) =>
        candidates.indexOf(candidate) === index &&
        methodAvailable(candidate, direction)
    ) || 'none'
    if (method === 'none') return false
    if (!postManualIntent('native-control', direction)) return false

    changeReasonInFlight = 'manual'
    changeBaseline = manualIntentBaseline || committedSignature
    changeMetadata = manualIntentMetadata
    const intentID = manualIntentMetadata?.manualIntentID

    if (method === 'slider') {
      const invocation = invokeKoboProgressSliderTurn(direction)
      if (!invocation.accepted) {
        beginSettlement('manual')
        return false
      }
      return true
    }
    if (method === 'semantic') {
      const invocation = invokeKoboSemanticPageTurn(direction)
      if (!invocation.accepted) {
        beginSettlement('manual')
        return false
      }
      void invocation.completion?.catch(() => {
        if (
          pendingManualIntent &&
          manualIntentMetadata?.manualIntentID === intentID
        ) {
          beginSettlement('manual')
        }
      })
      return true
    }

    const performed = turnKoboPage(direction, method)
    if (performed === 'none') {
      beginSettlement('manual')
      return false
    }
    return true
  }

  function postManualIntent(
    intent:
      | 'swipe'
      | 'edge-click'
      | 'page-key'
      | 'detected'
      | 'native-control',
    direction: 'next' | 'prev',
    allowDebounce = true
  ): boolean {
    const now = Date.now()
    if (allowDebounce && now - lastManualIntentAt < 350) {
      return pendingManualIntent
    }
    lastManualIntentAt = now
    if (pendingAuto) clearAutoTurn()
    if (changeReasonInFlight && changeReasonInFlight !== 'manual') {
      if (settleTimer) clearTimeout(settleTimer)
      settleTimer = null
      clearSettledChange(changeReasonInFlight)
      observedSignature = koboSignature() || observedSignature
    }
    pendingManualIntent = true
    manualIntentExpiresAt = now + 2600
    manualIntentBaseline = committedSignature || observedSignature || koboSignature()
    manualIntentMetadata = {
      manualIntentID: protocolID('manual'),
      baselineSignature: manualIntentBaseline,
      originFrameSessionID: frameSessionID,
    }
    manualIntentKind = intent
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
    beginSettlement('manual')
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
      const fallbackBaseline = committedSignature || koboSignature()
      const automatic = nonemptyString(recordArg(arg).turnID)
        ? automaticMetadata(arg, fallbackBaseline)
        : null
      const manual = manualMetadata(arg, fallbackBaseline)
      if (automatic) {
        changeReasonInFlight = 'auto'
        changeBaseline =
          liveLateAutoTurn()?.detectionBaselineSignature || fallbackBaseline
        changeMetadata = automatic
        beginSettlement('auto', 0, true)
      } else if (manual) {
        changeReasonInFlight = 'manual'
        changeBaseline = manual.baselineSignature
        changeMetadata = manual
        beginSettlement('manual', 0, true)
      } else {
        changeReasonInFlight = 'refresh'
        changeBaseline = fallbackBaseline
        changeMetadata = null
        beginSettlement('refresh', 0, true)
      }
    },
    relayout(arg?: unknown): boolean {
      const value = recordArg(arg)
      const bottomOcclusion = Number(value.bottomOcclusion)
      if (Number.isFinite(bottomOcclusion)) {
        koboNativeBottomOcclusion = Math.max(0, bottomOcclusion)
      }
      beginLayoutRefresh(
        nonemptyString(value.reason) || 'native-surface'
      )
      return true
    },
    retargetTurnBaseline(arg?: unknown): void {
      const value = recordArg(arg)
      const turnID = nonemptyString(value.turnID)
      const baseline = nonemptyOpaqueString(value.detectionBaselineSignature)
      if (!turnID || !baseline) return
      if (pendingAutoMetadata?.turnID === turnID) {
        pendingTurnBaseline = baseline
        if (
          changeReasonInFlight === 'auto' &&
          (changeMetadata as AutomaticTurnMetadata | null)?.turnID === turnID
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
      if (turnID && lateAutoTurn?.metadata.turnID === turnID) {
        lateAutoTurn = null
      }
    },
  }

  CASTREADER_XCTEST_ONLY: if (__CASTREADER_XCTEST_FIXTURES__) {
    Object.assign(api, {
      __fixtureManualIntent(direction: 'next' | 'prev'): boolean {
        if (
          document.documentElement.getAttribute('data-cr-test-fixture') !== '1'
        ) return false
        return postManualIntent('swipe', direction)
      },
      __fixtureBeginManualSwipe(direction: 'next' | 'prev'): boolean {
        if (
          document.documentElement.getAttribute('data-cr-test-fixture') !== '1'
        ) return false
        beginManualSwipe(direction)
        return manualSwipeActive
      },
      __fixtureEndManualSwipe(): boolean {
        if (
          document.documentElement.getAttribute('data-cr-test-fixture') !== '1'
        ) return false
        const wasActive = manualSwipeActive
        finishManualSwipe()
        return wasActive
      },
    })
  }

  ;(window as unknown as {
    CastReaderGoogleBooks?: typeof api
    CastReaderKobo?: typeof api
  }).CastReaderGoogleBooks = api
  ;(window as unknown as {
    CastReaderKobo?: typeof api
  }).CastReaderKobo = api

  const bridge = (window as unknown as {
    CR?: Record<string, unknown>
  }).CR
  if (bridge) {
    Object.assign(bridge, {
      gbNextPage: api.nextPage,
      gbPrevPage: api.prevPage,
      gbManualPage: api.userPage,
      gbRefresh: api.refresh,
      gbRelayout: api.relayout,
      gbRetargetTurnBaseline: api.retargetTurnBaseline,
      gbCompleteTurn: api.completeTurn,
    })
  }

  type TouchOrigin = {
    x: number
    y: number
    intentPosted: boolean
    doc: Document
  }
  let touchOrigin: TouchOrigin | null = null

  const physicalSwipeDirection = (
    dx: number,
    doc: Document
  ): 'next' | 'prev' => {
    const movingTowardLeft = dx < 0
    const physicalNext = documentDirection(doc) === 'rtl'
      ? !movingTowardLeft
      : movingTowardLeft
    return physicalNext ? 'next' : 'prev'
  }

  const installManualListeners = (doc: Document): void => {
    if (installedListenerDocuments.has(doc)) return
    installedListenerDocuments.add(doc)
    const view = doc.defaultView
    if (!view) return

    doc.addEventListener('touchstart', (rawEvent: Event) => {
      const event = rawEvent as TouchEvent
      if (!event.isTrusted || event.touches.length !== 1) {
        touchOrigin = null
        return
      }
      const touch = event.touches[0]
      touchOrigin = {
        x: touch.clientX,
        y: touch.clientY,
        intentPosted: false,
        doc,
      }
    }, { capture: true, passive: true })

    const detectSwipe = (touch: Touch): void => {
      const origin = touchOrigin
      if (!origin || origin.doc !== doc || origin.intentPosted) return
      const dx = touch.clientX - origin.x
      const dy = touch.clientY - origin.y
      const threshold = Math.max(44, (view.innerWidth || window.innerWidth) * 0.11)
      if (
        Math.abs(dx) < threshold ||
        Math.abs(dx) < Math.abs(dy) * 1.25
      ) return
      beginManualSwipe(physicalSwipeDirection(dx, doc))
      origin.intentPosted = manualSwipeActive
    }

    doc.addEventListener('touchmove', (rawEvent: Event) => {
      const event = rawEvent as TouchEvent
      if (!event.isTrusted || event.touches.length !== 1) return
      detectSwipe(event.touches[0])
    }, { capture: true, passive: true })
    doc.addEventListener('touchend', (rawEvent: Event) => {
      const event = rawEvent as TouchEvent
      if (
        event.isTrusted &&
        touchOrigin?.doc === doc &&
        event.changedTouches.length === 1
      ) {
        detectSwipe(event.changedTouches[0])
      }
      touchOrigin = null
      finishManualSwipe()
    }, { capture: true, passive: true })
    doc.addEventListener('touchcancel', () => {
      touchOrigin = null
      finishManualSwipe()
    }, { capture: true, passive: true })

    doc.addEventListener('click', (rawEvent: Event) => {
      const event = rawEvent as MouseEvent
      if (!event.isTrusted) return
      const width = view.innerWidth || window.innerWidth
      const edge = Math.min(72, Math.max(42, width * 0.16))
      const target = event.target as Element | null
      const interactive = target?.closest(
        'a,button,input,textarea,select,[role="button"],[contenteditable="true"]'
      ) as HTMLElement | null
      const label = interactive ? controlLabel(interactive) : ''
      const nextControl = NEXT_PAGE_LABEL.test(label) && !CHAPTER_LABEL.test(label)
      const previousControl =
        PREVIOUS_PAGE_LABEL.test(label) && !CHAPTER_LABEL.test(label)
      if (
        !nextControl &&
        !previousControl &&
        event.clientX > edge &&
        event.clientX < width - edge
      ) return
      if (interactive && !nextControl && !previousControl) return
      const rtl = documentDirection(doc) === 'rtl'
      const physicalLeft = event.clientX < edge
      const direction = previousControl
        ? 'prev'
        : nextControl
          ? 'next'
          : physicalLeft === rtl
            ? 'next'
            : 'prev'
      postManualIntent('edge-click', direction)
    }, true)

    doc.addEventListener('keydown', (rawEvent: Event) => {
      const event = rawEvent as KeyboardEvent
      if (!event.isTrusted || event.repeat) return
      const target = event.target as HTMLElement | null
      if (
        target?.isContentEditable ||
        target?.tagName === 'INPUT' ||
        target?.tagName === 'TEXTAREA'
      ) return
      const rtl = documentDirection(doc) === 'rtl'
      const directions: Record<string, 'next' | 'prev'> = {
        ArrowRight: rtl ? 'prev' : 'next',
        PageDown: 'next',
        ArrowLeft: rtl ? 'next' : 'prev',
        PageUp: 'prev',
      }
      const direction = directions[event.key]
      if (direction) postManualIntent('page-key', direction)
    }, true)
  }

  const refreshFrameListeners = (): void => {
    installManualListeners(document)
    for (const frame of allAccessibleFrames()) {
      installManualListeners(frame.doc)
    }
  }
  refreshFrameListeners()

  const observeViewportChange = (source: string): void => {
    const key = viewportSizeKey()
    if (key === lastViewportSizeKey && source === 'poll') return
    lastViewportSizeKey = key
    beginLayoutRefresh(source)
  }
  window.addEventListener(
    'resize',
    () => observeViewportChange('window-resize'),
    { passive: true }
  )
  window.addEventListener(
    'orientationchange',
    () => observeViewportChange('orientationchange'),
    { passive: true }
  )
  window.visualViewport?.addEventListener(
    'resize',
    () => observeViewportChange('visual-viewport-resize'),
    { passive: true }
  )

  setInterval(() => {
    observeViewportChange('poll')
    if (reportReaderFailureIfPresent()) return
    if (ensureKoboChapterTypography()) return
    refreshFrameListeners()
    const signature = koboSignature()
    if (!signature || signature === observedSignature) return
    observedSignature = signature
    const firstGeometryChange = changeReasonInFlight === null
    const freshManualIntent =
      pendingManualIntent && Date.now() <= manualIntentExpiresAt
    const late = liveLateAutoTurn()
    const lateAutomaticDeparture =
      !!late && signature !== late.detectionBaselineSignature

    if (
      firstGeometryChange &&
      !pendingAuto &&
      !freshManualIntent &&
      !lateAutomaticDeparture &&
      !layoutRefreshActive
    ) {
      // Touch events inside an iframe may be consumed by Kobo before they reach
      // our listener. A non-automatic visual departure is still a manual turn;
      // emit a late intent so native stops/restarts on the newly visible page.
      postManualIntent('detected', 'next', false)
    }

    const reason = changeReasonInFlight ||
      (
        pendingAuto
          ? 'auto'
          : layoutRefreshActive
            ? 'refresh'
          : pendingManualIntent
            ? 'manual'
            : lateAutomaticDeparture
              ? 'auto'
              : 'refresh'
      )
    changeReasonInFlight = reason
    if (firstGeometryChange) {
      clearPageVisuals()
      changeBaseline = reason === 'auto'
        ? (
            pendingTurnBaseline ||
            late?.detectionBaselineSignature ||
            committedSignature
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
    beginSettlement(reason)
  }, 250)

  let waited = 0
  const boot = setInterval(() => {
    waited += 200
    if (reportReaderFailureIfPresent()) {
      clearInterval(boot)
      return
    }
    if (ensureKoboChapterTypography()) return
    refreshFrameListeners()
    const paragraphs = extractKoboParagraphs()
    if (paragraphs.length > 0) {
      const signature = koboSignature()
      const geometry = koboGeometryKey()
      if (
        signature !== bootCandidate ||
        geometry !== bootGeometryCandidate
      ) {
        bootCandidate = signature
        bootGeometryCandidate = geometry
        bootCandidateSince = Date.now()
        return
      }
      if (
        Date.now() - bootCandidateSince < INITIAL_LAYOUT_MIN_STABLE_MS ||
        Date.now() < layoutRefreshQuietUntil
      ) return

      clearInterval(boot)
      committedSignature = signature
      observedSignature = signature
      hasPublishedInitialPage = true
      layoutRefreshActive = false
      postForFrame('log', { message: koboLayoutDiagnostic() })
      requestExtract('initial')
      scheduleNextPagePreview()
      return
    }
    if (waited < 15_000) return

    clearInterval(boot)
    hasPublishedInitialPage = true
    layoutRefreshActive = false
    postForFrame('log', { message: koboLayoutDiagnostic() })
    requestExtract('initial')
    const code = layoutFailureCode()
    postForFrame('error', {
      stage: 'kobo-reader-layout',
      code,
      message: code === 'fixed-layout-unsupported'
        ? 'This fixed-layout Kobo book is not supported yet.'
        : 'Kobo reader content did not become available.',
    })
  }, 200)
}
