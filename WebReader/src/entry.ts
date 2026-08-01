// CastReader WebReader bundle 入口。
// 注入 WKWebView：扩展站点专用 extractor + Visual Zone 正文提取 + 手写标注 + window.CR 桥。
// TTS 在 native，native 调 window.CR.* 驱动高亮（见 cr-bridge.ts）。

import { extractZones, readAllExtract, visibleTextBlockExtract } from '@/extractors/visible-text-block-extractor'
import { weixinExtractor } from '@/extractors/weixin'
import { initBridge } from './cr-bridge'
import {
  acceptPlayBooksHighlightRect,
  extractPlayBooksParagraphs,
  installPlayBooksReader,
  installPlayBooksRelay,
  installPlayBooksRelayReceiver,
  isPlayBooksReaderFrame,
  isPlayBooksRelayContainer,
  playBooksFrameSessionID,
  playBooksSignature,
} from './play-books'
import {
  acceptKoboHighlightRect,
  extractKoboParagraphs,
  installKoboReader,
  isKoboReaderDescendantFrame,
  isKoboReaderMainFrame,
  koboFrameSessionID,
  koboSignature,
} from './kobo'
import {
  acceptOReillyHighlightRect,
  extractOReillyParagraphs,
  installOReillyReader,
  isOReillyReaderMainFrame,
  oReillyFrameSessionID,
  oReillySignature,
} from './oreilly'

type Para = { text: string; element: HTMLElement }

/**
 * 扩展第 1 层——站点专用 extractor。微信公众号正文是 section/span 深度嵌套，Visual Zone 易掉段
 * （→ 朗读掉内容、解读喂后端正文不全只分到几块就"完成"）。weixin extractor 针对其 DOM 结构精确提取。
 * 零 chrome 依赖，按 hostname 匹配；命中且 >=3 段才采用，否则回退 Visual Zone。
 */
function siteExtract(): Para[] | null {
  const host = location.hostname
  if (host.includes('mp.weixin.qq.com')) {
    try {
      const paras = weixinExtractor.extractParagraphsWithElements?.() || []
      if (paras.length >= 3) return paras.map((p) => ({ text: p.text, element: p.element as HTMLElement }))
    } catch { /* ignore */ }
  }
  return null
}

/**
 * 扩展第 3 层——Visual Zone：纯空间分割（收集可见叶子文本块 → 左边缘直方图多列检测 → 列内 Y-gap
 * 切 section → 面积×文本量×居中度评分选最佳区，区内全读）。通用兜底，段落 element.textContent 与 text 对齐。
 */
function zoneExtract(): Para[] {
  const zr = extractZones()
  return (zr.paragraphs || []).map((p) => ({ text: p.text, element: p.element as HTMLElement }))
}

function extract(): Para[] {
  let r: Para[] | null = siteExtract()
  let method = 'site'
  if (!r || r.length < 3) { method = 'zone'; try { r = zoneExtract() } catch { /* ignore */ } }
  if (!r || r.length < 2) { method = 'read-all'; try { r = (readAllExtract() as Para[]) } catch { /* ignore */ } }
  if (!r || !r.length) { method = 'vtb'; try { r = (visibleTextBlockExtract() as Para[]) } catch { /* ignore */ } }
  try { (window as unknown as { __crExtractMethod?: string }).__crExtractMethod = method } catch { /* */ }
  return (r || []).map((p) => ({ text: p.text, element: p.element }))
}

/**
 * Google Play Books：正文在跨源 iframe 里，顶层壳没有任何可读内容。
 * - 顶层壳：只装 CR 转发（native 的 evaluateJavaScript 只到主帧），绝不提取，
 *   否则会把阅读器 UI 当正文读出来。
 * - 阅读帧：站点专用提取 + 翻页/手动翻页监听驱动 rendered。
 */
function bootPlayBooks(): boolean {
  if (isPlayBooksRelayContainer()) {
    installPlayBooksRelay()
    return true
  }
  if (!isPlayBooksReaderFrame()) return false

  const frameSessionID = playBooksFrameSessionID()
  installPlayBooksRelayReceiver(frameSessionID)
  let pendingReason = 'initial'
  let pendingPageMetadata: Record<string, unknown> = {}
  initBridge({
    extract: () => extractPlayBooksParagraphs() as unknown as Para[],
    acceptHighlightRect: acceptPlayBooksHighlightRect,
    autoExtract: false,
    pageMeta: () => ({
      source: 'google-books',
      reason: pendingReason,
      signature: playBooksSignature(),
      frameSessionID,
      ...pendingPageMetadata,
    }),
    onInstalled: ({ extract: doExtract }) => {
      const CR = (window as unknown as { CR?: { disableScroll?: boolean } }).CR
      if (CR) CR.disableScroll = true
      const post = (type: string, payload: Record<string, unknown> = {}): void => {
        try {
          ;(window as unknown as {
            webkit?: { messageHandlers?: Record<string, { postMessage: (m: unknown) => void }> }
          }).webkit?.messageHandlers?.castreader?.postMessage({ type, payload })
        } catch { /* */ }
      }
      installPlayBooksReader(post, (reason, metadata = {}) => {
        pendingReason = reason
        pendingPageMetadata = metadata
        doExtract(reason)
        pendingPageMetadata = {}
      }, frameSessionID)
    },
  })
  return true
}

/**
 * Kobo: the shell owns one bridge and reads the same-origin srcdoc chapter
 * frames directly.  Never install a competing bridge inside each preloaded
 * chapter frame: those frames are a future-content buffer, not independent
 * current pages.
 */
function bootKobo(): boolean {
  if (isKoboReaderDescendantFrame()) return true
  if (!isKoboReaderMainFrame()) return false

  const frameSessionID = koboFrameSessionID()
  let pendingReason = 'initial'
  let pendingPageMetadata: Record<string, unknown> = {}
  initBridge({
    extract: () => extractKoboParagraphs() as unknown as Para[],
    acceptHighlightRect: acceptKoboHighlightRect,
    autoExtract: false,
    pageMeta: () => ({
      source: 'kobo',
      reason: pendingReason,
      signature: koboSignature(),
      frameSessionID,
      ...pendingPageMetadata,
    }),
    onInstalled: ({ extract: doExtract }) => {
      const CR = (window as unknown as { CR?: { disableScroll?: boolean } }).CR
      if (CR) CR.disableScroll = true
      const post = (
        type: string,
        payload: Record<string, unknown> = {}
      ): void => {
        try {
          ;(window as unknown as {
            webkit?: {
              messageHandlers?: Record<
                string,
                { postMessage: (message: unknown) => void }
              >
            }
          }).webkit?.messageHandlers?.castreader?.postMessage({ type, payload })
        } catch { /* */ }
      }
      installKoboReader(post, (reason, metadata = {}) => {
        pendingReason = reason
        pendingPageMetadata = metadata
        doExtract(reason)
        pendingPageMetadata = {}
      }, frameSessionID)
    },
  })
  return true
}

/**
 * O'Reilly renders a semantic chapter directly in the top document and scrolls
 * it continuously. The adapter maps one unobscured viewport to the shared
 * page-turn protocol, so native Read/Explain remains single-sourced.
 */
function bootOReilly(): boolean {
  if (!isOReillyReaderMainFrame()) return false

  const frameSessionID = oReillyFrameSessionID()
  let pendingReason = 'initial'
  let pendingPageMetadata: Record<string, unknown> = {}
  initBridge({
    extract: () => extractOReillyParagraphs() as unknown as Para[],
    acceptHighlightRect: acceptOReillyHighlightRect,
    autoExtract: false,
    pageMeta: () => ({
      source: 'oreilly',
      reason: pendingReason,
      signature: oReillySignature(),
      frameSessionID,
      ...pendingPageMetadata,
    }),
    onInstalled: ({ extract: doExtract }) => {
      const CR = (window as unknown as {
        CR?: { disableScroll?: boolean }
      }).CR
      if (CR) CR.disableScroll = true
      const post = (
        type: string,
        payload: Record<string, unknown> = {}
      ): void => {
        try {
          ;(window as unknown as {
            webkit?: {
              messageHandlers?: Record<
                string,
                { postMessage: (message: unknown) => void }
              >
            }
          }).webkit?.messageHandlers?.castreader?.postMessage({ type, payload })
        } catch { /* */ }
      }
      installOReillyReader(post, (reason, metadata = {}) => {
        pendingReason = reason
        pendingPageMetadata = metadata
        doExtract(reason)
        pendingPageMetadata = {}
      }, frameSessionID)
    },
  })
  return true
}

if (!bootOReilly() && !bootKobo() && !bootPlayBooks()) {
  initBridge({ extract })
}
