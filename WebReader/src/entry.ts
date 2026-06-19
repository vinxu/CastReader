// CastReader WebReader bundle 入口。
// 注入 WKWebView：扩展站点专用 extractor + Visual Zone 正文提取 + 手写标注 + window.CR 桥。
// TTS 在 native，native 调 window.CR.* 驱动高亮（见 cr-bridge.ts）。

import { extractZones, readAllExtract, visibleTextBlockExtract } from '@/extractors/visible-text-block-extractor'
import { weixinExtractor } from '@/extractors/weixin'
import { initBridge } from './cr-bridge'

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

initBridge({ extract })
