//
//  ReadingDocument.swift
//  CastReader
//
//  统一阅读文档模型 —— 同时表示「拍摄照片 + Vision OCR」与「重排纯文本」两种源。
//  朗读高亮与解读 marks 的定位都基于此模型（见 ReadingAnchorResolver）。
//

import CoreGraphics
import Foundation

// MARK: - Source Kind

enum ReadingSourceKind: String, Equatable, Codable {
    case photo   // 拍摄/选图，带 Vision OCR 的词级 bbox
    case kindle  // Kindle Cloud Reader：多页渲染图 + Vision OCR 词级 bbox
    case weread  // 微信读书：实时 Canvas/DOM bridge（不 OCR、不保存章节正文）
    case googleBooks = "google_books"  // Google Play 图书：跨源阅读帧的实时 DOM bridge（不 OCR、不保存正文）
    case kobo    // Kobo Web Reader：同源章节 iframe + CSS columns 的实时 DOM bridge
    case oreilly // O’Reilly Learning：顶层语义 DOM 的长章节，以当前可见视口为视觉页
    case text    // 上传文件 / 文本输入，重排纯文本
    case web     // 网址：WKWebView 直接加载网页 DOM，高亮/标注经 JS bridge（保留原排版）
    case docx    // 本地 DOCX：WKWebView 内 mammoth.js 转 HTML 渲染（不上传后端），复用 web 的高亮/标注/提取链路
    case pdf     // 本地 PDF：PDFKit 原生 PDFView 渲染（保排版不重排），朗读高亮用 characterBounds overlay
    case epub    // 本地 EPUB：ZIPFoundation 解包 + SwiftSoup 抽段落（含内嵌图片字节），原生 TextReaderView 渲染（不上传、不走 WebView）
    case youtube // YouTube 公开字幕稿：原生字幕视图 + CastReader 自有 TTS（不播放/下载视频音频流）
}

extension ReadingSourceKind {
    /// WKWebView 渲染的源（网页 / 本地 DOCX）：正文提取在 DOM、高亮/标注经 WebReaderBridge 驱动。
    /// 注意：EPUB 已改为原生解析渲染（走 TextReaderView），不在此列。
    var isWebRendered: Bool {
        self == .web || self == .docx || self == .weread
            || self == .googleBooks || self == .kobo || self == .oreilly
    }

    /// 绑定书库里的「实时网页阅读器」：页面归第三方所有，CastReader 只在其 DOM 上
    /// 做高亮/标注，并按页驱动 TTS —— 一页读完再翻页，而不是一次拿整本。
    var isLiveWebLibrary: Bool {
        self == .weread || self == .googleBooks || self == .kobo
            || self == .oreilly
    }

    /// 原生文本渲染源（重排文本 / EPUB）：走 TextReaderView，朗读词/句高亮统一用 processedDisplayText 内字符范围。
    var isNativeTextRendered: Bool { self == .text || self == .epub || self == .youtube }

    /// OCR 图片几何源：用每个词的 Vision bbox 在原图上叠加高亮/mark。
    var isOCRImageRendered: Bool { self == .photo || self == .kindle }
}

// MARK: - OCR Word

/// 单个 OCR 词及其归一化包围盒（Vision 坐标：原点左下，0...1）
struct OCRWord: Identifiable, Equatable {
    let id: Int            // 文档内全局词索引
    let text: String
    let bboxNorm: CGRect   // Vision 归一化（原点左下），原样保存
}

/// One independently paintable region of a logical OCR paragraph. A Kindle
/// paragraph can continue from the bottom of one spread column at the top of
/// the next; keeping both fragments prevents a highlight union across the
/// center gutter.
struct OCRVisualFragment: Equatable {
    enum Column: String, Equatable {
        case single, left, right
    }

    var column: Column
    var bboxNorm: CGRect
    var wordIDs: [Int]
}

// MARK: - Paragraph

enum ReadingParagraphType: Equatable {
    case paragraph
    case heading(Int)
    case blockquote
    case code
    case list
    case caption
    case image   // EPUB 内嵌图片 / Kindle 页面图（不朗读），渲染走 imageData

    /// 是否参与朗读（代码块、图片段不读）
    var isReadable: Bool {
        self != .code && self != .image
    }
}

struct ReadingParagraph: Identifiable, Equatable {
    let id: Int                 // 连续 0-based 段落索引
    let text: String            // 重排纯文本（TTS 输入 + 文本命中）
    /// Optional source-specific narration text. YouTube keeps accessibility
    /// annotations in `text` for display while sending only `speechText` to
    /// TTS. `nil` preserves the existing contract for every other source.
    var speechText: String? = nil
    var speaker: String? = nil
    var type: ReadingParagraphType = .paragraph
    var words: [OCRWord] = []   // 仅 photo，按阅读顺序
    var bboxNorm: CGRect? = nil // 仅 photo，段落包络（用于滚动/居中）
    var visualFragments: [OCRVisualFragment] = [] // Kindle 跨栏段落的独立绘制区域
    var pdfPageIndex: Int? = nil // 仅 pdf：该句所在 PDF 页
    var pdfRange: NSRange? = nil // 仅 pdf：该句在该页 string 内的字符范围（PDFKit characterBounds 高亮用）
    var pageIndex: Int? = nil    // 仅 kindle：该 OCR 段落所属的 Kindle 渲染页
    var imageData: Data? = nil   // 仅 epub：内嵌图片字节（PNG/JPEG），type==.image 时直接渲染
    var startMs: Int? = nil      // 仅 youtube：字幕段在原视频中的跳转锚（不用于 TTS 同步）

    init(id: Int, text: String, speechText: String? = nil, speaker: String? = nil,
         type: ReadingParagraphType = .paragraph,
         words: [OCRWord] = [], bboxNorm: CGRect? = nil,
         visualFragments: [OCRVisualFragment] = [],
         pdfPageIndex: Int? = nil, pdfRange: NSRange? = nil, pageIndex: Int? = nil,
         imageData: Data? = nil, startMs: Int? = nil) {
        self.id = id
        self.text = text
        self.speechText = speechText
        self.speaker = speaker
        self.type = type
        self.words = words
        self.bboxNorm = bboxNorm
        self.visualFragments = visualFragments
        self.pdfPageIndex = pdfPageIndex
        self.pdfRange = pdfRange
        self.pageIndex = pageIndex
        self.imageData = imageData
        self.startMs = startMs
    }

    var resolvedSpeechText: String { speechText ?? text }
}

// MARK: - Document

struct ReadingDocument: Identifiable, Equatable {
    let id: String
    var title: String
    var sourceKind: ReadingSourceKind
    var language: String                 // "en"/"zh"… 决定 TTS 与 Vision 识别语言
    var paragraphs: [ReadingParagraph]
    var imageData: Data? = nil           // 仅 photo（JPEG）
    var imagePixelSize: CGSize? = nil    // 仅 photo，原图像素尺寸
    var sourceURL: String? = nil         // 上传得到的 COS URL；纯拍摄为 synthetic
    var coverURL: String? = nil          // 绑定书库封面；Mini Player / 锁屏共用
    var fileData: Data? = nil            // 仅 docx：原始文件字节，交 WebView 内 mammoth 本地渲染
    /// 云盘来源只保存可重新获取的远端引用，不包含 OAuth token 或文件字节。
    var origin: CloudDocumentOrigin? = nil
    /// 本地导入保持原有 payload 持久化；云盘导入只留远端引用。
    var persistencePolicy: DocumentPersistencePolicy = .localPayload
    /// 实际交给解析器的格式（Google 原生文档可与原始 MIME 不同）。
    var effectiveFormat: SupportedDocumentFormat? = nil
    var exportFormat: CloudExportFormat? = nil
    /// 下载完成时服务端返回的最终修订号。
    var contentRevision: String? = nil
    /// 内容会话身份：本地文档等于 id；云盘文档随 revision / 导出格式变化。
    var contentSessionKey: String
    var youtubeTranscript: YouTubeTranscriptDocument? = nil // 仅 youtube：字幕、元数据与画面锚
    var youtubeCacheHit: Bool = false     // 仅用于当前会话的离线/缓存徽标
    /// 仅 photo/kindle：版面分析判定的栏数。多栏说明这一页可能有不止一篇文章，
    /// 用来决定要不要问用户「只读其中一块」。
    var layoutColumnCount: Int? = nil
    var createdAt: Date = Date()

    init(id: String = UUID().uuidString,
         title: String,
         sourceKind: ReadingSourceKind,
         language: String = Constants.TTS.defaultLanguage,
         paragraphs: [ReadingParagraph],
         imageData: Data? = nil,
         imagePixelSize: CGSize? = nil,
         sourceURL: String? = nil,
         coverURL: String? = nil,
         fileData: Data? = nil,
         origin: CloudDocumentOrigin? = nil,
         persistencePolicy: DocumentPersistencePolicy? = nil,
         effectiveFormat: SupportedDocumentFormat? = nil,
         exportFormat: CloudExportFormat? = nil,
         contentRevision: String? = nil,
         contentSessionKey: String? = nil,
         youtubeTranscript: YouTubeTranscriptDocument? = nil,
         youtubeCacheHit: Bool = false,
         layoutColumnCount: Int? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.sourceKind = sourceKind
        self.language = language
        self.paragraphs = paragraphs
        self.imageData = imageData
        self.imagePixelSize = imagePixelSize
        self.sourceURL = sourceURL
        self.coverURL = coverURL
        self.fileData = fileData
        self.origin = origin
        // A provider origin is a hard privacy boundary: callers cannot
        // accidentally turn an ephemeral cloud download into History payload.
        self.persistencePolicy = origin == nil
            ? (persistencePolicy ?? .localPayload)
            : .remoteReference
        self.effectiveFormat = effectiveFormat
        self.exportFormat = exportFormat
        self.contentRevision = contentRevision
        self.contentSessionKey = contentSessionKey ?? id
        self.youtubeTranscript = youtubeTranscript
        self.youtubeCacheHit = youtubeCacheHit
        self.layoutColumnCount = layoutColumnCount
        self.createdAt = createdAt
    }

    /// 全文（段落用空行连接），用于解读请求与 TTS 兜底
    var fullText: String {
        paragraphs.map(\.text).joined(separator: "\n\n")
    }

    /// 参与朗读的段落（剔除代码块与空段）
    var readableParagraphs: [ReadingParagraph] {
        paragraphs.filter {
            $0.type.isReadable &&
                !$0.resolvedSpeechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isEmpty: Bool {
        readableParagraphs.isEmpty
    }

    /// Text-layer PDFs retain exact PDFKit ranges and render in PDFView. A
    /// scanned or hybrid PDF is OCR-reflowed and intentionally has no pdfRange,
    /// so it uses the same text/highlight pipeline as TXT and EPUB.
    var usesNativePDFRendering: Bool {
        sourceKind == .pdf && paragraphs.contains { $0.pdfRange != nil }
    }

    var usesNativeTextRendering: Bool {
        sourceKind.isNativeTextRendered || (sourceKind == .pdf && !usesNativePDFRendering)
    }
}

// MARK: - 坐标换算（拍摄叠加的关键）

/// Vision 归一化（原点左下）↔ SwiftUI 点（原点左上，图片 aspectFit 显示）换算。
enum ReadingGeometry {

    /// 图片在容器内 aspectFit 后的实际显示矩形（SwiftUI 点，原点左上）。
    static func fittedImageRect(container: CGSize, imagePixel: CGSize) -> CGRect {
        guard imagePixel.width > 0, imagePixel.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imagePixel.width, container.height / imagePixel.height)
        let w = imagePixel.width * scale
        let h = imagePixel.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }

    /// 把 Vision 归一化矩形（原点左下）映射到显示矩形内的 SwiftUI 点矩形（原点左上）。
    static func displayRect(forNorm n: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + n.minX * fitted.width,
               y: fitted.minY + (1 - n.maxY) * fitted.height,   // 翻转 Y
               width: n.width * fitted.width,
               height: n.height * fitted.height)
    }

    /// 一组归一化矩形按行合并为包络（用于跨多词高亮/标注）。
    static func unionNorm(_ rects: [CGRect]) -> CGRect? {
        guard var u = rects.first else { return nil }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }
}
