//
//  DocumentBuilder.swift
//  CastReader
//
//  把不同来源转换为统一 ReadingDocument：Markdown 文档、纯文本输入。
//  （拍摄源见 OCRService。）
//

import Foundation
import CoreImage
import PDFKit
import UIKit
import ZIPFoundation

enum DocumentBuilder {

    /// DOCX 标题：docProps/core.xml 的 <dc:title> →（空则）document.xml 首段文本 → nil（调用方回退文件名）。
    static func docxTitle(data: Data) -> String? {
        guard let archive = try? Archive(data: data, accessMode: .read) else { return nil }
        func read(_ path: String) -> String? {
            guard let entry = archive[path] else { return nil }
            var d = Data()
            guard (try? archive.extract(entry) { d.append($0) }) != nil else { return nil }
            return String(data: d, encoding: .utf8)
        }
        if let core = read("docProps/core.xml"),
           let t = firstGroup(core, #"<dc:title>([\s\S]*?)</dc:title>"#), isMeaningfulTitle(t) {
            return String(decodeXmlEntities(t).prefix(120))
        }
        if let doc = read("word/document.xml"),
           let firstP = firstGroup(doc, #"(<w:p\b[\s\S]*?</w:p>)"#) {
            let runs = allGroups(firstP, #"<w:t[^>]*>([\s\S]*?)</w:t>"#).joined()
            let t = decodeXmlEntities(runs).trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 2 { return String(t.prefix(60)) }
        }
        return nil
    }

    private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func allGroups(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .compactMap { $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil }
    }

    private static func decodeXmlEntities(_ s: String) -> String {
        var r = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'"] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r
    }

    /// 本地 PDF 文本提取（PDFKit，即时可读，无需后端）。
    static func fromPDF(url: URL, title: String? = nil) -> ReadingDocument? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        var text = ""
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let s = page.string {
                text += s + "\n\n"
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return fromPlainText(text, title: title ?? url.deletingPathExtension().lastPathComponent)
    }

    /// PDF 本地原生渲染（PDFKit PDFView 保排版）：提取每页文本按句切段，记录每句的 page + 页内字符范围（characterBounds 高亮用）。
    static func fromPDFNative(url: URL, title: String? = nil) -> ReadingDocument? {
        guard let pdf = PDFDocument(url: url), let data = try? Data(contentsOf: url) else { return nil }
        return nativePDFDocument(
            pdf: pdf,
            data: data,
            title: title,
            fallbackTitle: url.deletingPathExtension().lastPathComponent
        )
    }

    private static func nativePDFDocument(
        pdf: PDFDocument,
        data: Data,
        title: String?,
        fallbackTitle: String
    ) -> ReadingDocument? {
        var paragraphs: [ReadingParagraph] = []
        var pid = 0
        for pageIdx in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIdx), let pageStr = page.string else { continue }
            let ns = pageStr as NSString
            for r in ReadingSentenceContract.nsRanges(in: pageStr) {
                // pdfRange(r) 保留 page.string 原始范围（高亮 needle 用精确子串）；text 去 PDF 硬换行供 TTS 朗读（否则在换行处停顿）。
                let text = stripPdfLineBreaks(ns.substring(with: r)).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count < 2 { continue }
                paragraphs.append(ReadingParagraph(id: pid, text: text, pdfPageIndex: pageIdx, pdfRange: r))
                pid += 1
            }
        }
        guard !paragraphs.isEmpty else { return nil }
        let lang = detectLanguage(paragraphs.prefix(30).map(\.text).joined(separator: " "))
        // 标题：优先 PDF 元数据标题（有意义时）→ 首句/首行 → 文件名（避免 arxiv-id 文件名等 demo 感）。
        let metaTitle = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        let resolved = title ?? derivePDFTitle(meta: metaTitle, firstText: paragraphs.first?.text,
                                               fallback: fallbackTitle)
        return ReadingDocument(title: resolved,
                               sourceKind: .pdf, language: lang, paragraphs: paragraphs, fileData: data)
    }

    /// Unified PDF import. Fully searchable PDFs keep their original layout and
    /// exact PDFKit ranges. If any content page lacks a usable text layer, the
    /// document becomes a single OCR/text-reflow track so native and scanned
    /// pages cannot diverge into two incompatible highlight systems.
    static func fromPDFWithOCR(
        data: Data,
        title: String? = nil,
        fallbackTitle: String = "PDF"
    ) async -> ReadingDocument? {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { return nil }
        let pageTexts: [String] = (0..<pdf.pageCount).map {
            pdf.page(at: $0)?.string ?? ""
        }
        let pagesRequiringOCR = (0..<pdf.pageCount).map { pageIndex in
            !hasUsablePDFTextLayer(pageTexts[pageIndex])
                && pdf.page(at: pageIndex).map(pdfPageHasVisibleInk) == true
        }
        let requiresOCRReflow = pagesRequiringOCR.contains(true)
        if !requiresOCRReflow {
            return nativePDFDocument(pdf: pdf, data: data, title: title, fallbackTitle: fallbackTitle)
        }

        var paragraphs: [ReadingParagraph] = []
        for pageIndex in 0..<pdf.pageCount {
            let pageText = pageTexts[pageIndex]
            if hasUsablePDFTextLayer(pageText) {
                let ns = pageText as NSString
                for range in ReadingSentenceContract.nsRanges(in: pageText) {
                    let value = stripPdfLineBreaks(ns.substring(with: range))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value.count >= 2 else { continue }
                    paragraphs.append(ReadingParagraph(
                        id: paragraphs.count,
                        text: value,
                        pdfPageIndex: pageIndex
                    ))
                }
                continue
            }

            guard pagesRequiringOCR[pageIndex],
                  let page = pdf.page(at: pageIndex),
                  let image = renderPDFPageForOCR(page) else { continue }
            do {
                let ocr = try await OCRService.shared.recognizeImportedImage(
                    image: image,
                    title: title ?? fallbackTitle
                )
                for paragraph in ocr.paragraphs where
                    paragraph.type.isReadable && SpeechTextSanitizer.containsSpeakableContent(paragraph.text) {
                    paragraphs.append(ReadingParagraph(
                        id: paragraphs.count,
                        text: paragraph.text,
                        type: paragraph.type,
                        pdfPageIndex: pageIndex
                    ))
                }
            } catch {
                #if DEBUG
                NSLog("CRDBG PDF OCR page=%d failed=%@", pageIndex, error.localizedDescription)
                #endif
            }
        }
        guard !paragraphs.isEmpty else { return nil }
        let language = detectLanguage(paragraphs.prefix(40).map(\.text).joined(separator: " "))
        let metaTitle = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let resolvedTitle = title ?? derivePDFTitle(
            meta: metaTitle,
            firstText: paragraphs.first?.text,
            fallback: fallbackTitle
        )
        return ReadingDocument(
            title: resolvedTitle,
            sourceKind: .pdf,
            language: language,
            paragraphs: paragraphs,
            fileData: data
        )
    }

    /// PDF 标题推导：元数据标题（剔除 "Microsoft Word - …"/untitled 等垃圾）→ 首段文本（截断）→ 文件名兜底。
    static func derivePDFTitle(meta: String?, firstText: String?, fallback: String) -> String {
        if let m = meta?.trimmingCharacters(in: .whitespacesAndNewlines), isMeaningfulTitle(m) {
            return String(m.prefix(120))
        }
        if let f = firstText?.trimmingCharacters(in: .whitespacesAndNewlines), f.count >= 4 {
            return String(f.prefix(60))
        }
        return fallback
    }

    /// 标题是否「像个真标题」：非空、长度合理、不是 Office 导出的占位垃圾。
    static func isMeaningfulTitle(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 200 else { return false }
        let low = t.lowercased()
        let junk = ["untitled", "microsoft word -", "microsoft powerpoint -", "powerpoint presentation",
                    "doc1", "document1", "slide 1", "无标题"]
        return !junk.contains { low == $0 || low.hasPrefix($0) }
    }

    private static func hasUsablePDFTextLayer(_ text: String) -> Bool {
        let evidence = LanguageDetector.evidence(for: text)
        return evidence.readableCharacterCount >= 12 && SpeechTextSanitizer.containsSpeakableContent(text)
    }

    /// Empty separator pages are common in otherwise searchable PDFs. A small
    /// rendered luminance probe prevents one truly blank page from forcing the
    /// entire document into OCR reflow, while scanned text/pages remain visible.
    private static func pdfPageHasVisibleInk(_ page: PDFPage) -> Bool {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return false }
        let scale = 180 / max(bounds.width, bounds.height)
        let thumbnail = page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox
        )
        guard let input = CIImage(image: thumbnail),
              let filter = CIFilter(name: "CIAreaAverage") else { return true }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return true }
        var pixel = [UInt8](repeating: 255, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        let luminance = (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
        return luminance < 0.997
    }

    /// Render before OCR at a bounded high resolution. This is deliberately
    /// independent of the JPEG used for history thumbnails: OCR receives clean
    /// lossless pixels and is never fed a compressed preview.
    private static func renderPDFPageForOCR(_ page: PDFPage) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let targetLongEdge = min(2800, max(bounds.width, bounds.height) * 3)
        let scale = targetLongEdge / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }

    /// 去掉 PDF 硬换行（视觉排版换行，非句子边界，否则 TTS 在此停顿）：CJK 字之间删除（连续）、其余替空格（保英文词边界）。
    private static func stripPdfLineBreaks(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        out.reserveCapacity(chars.count)
        for (i, c) in chars.enumerated() {
            if c == "\n" || c == "\r" {
                let prev = i > 0 ? chars[i - 1] : " "
                let next = (i + 1 < chars.count) ? chars[i + 1] : " "
                if ReadingSentenceContract.isCJKOrKana(prev) && ReadingSentenceContract.isCJKOrKana(next) {
                    continue   // CJK 之间的换行 → 删除（中文连续、不停顿）
                }
                out.append(" ")   // 英文等 → 空格（保词边界）
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// 本地 EPUB 原生解析（ZIPFoundation + SwiftSoup，含内嵌图片，不上传、不走 WebView）。
    static func fromEPUB(data: Data, title: String) -> ReadingDocument? {
        guard let parsed = EpubNativeEngine.parse(data: data, fallbackTitle: title), !parsed.paragraphs.isEmpty else { return nil }
        let sample = parsed.paragraphs.prefix(40).filter { $0.type.isReadable }.map(\.text).joined(separator: " ")
        let lang = detectLanguage(sample)
        return ReadingDocument(title: parsed.title ?? title, sourceKind: .epub, language: lang,
                               paragraphs: parsed.paragraphs, fileData: data)   // 保留原始字节供历史重开重新解析
    }

    /// 本地纯文本文件。
    static func fromTextFile(url: URL) -> ReadingDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url) else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return fromPlainText(text, title: url.deletingPathExtension().lastPathComponent)
    }

    /// 网址 → web 源文档（容错补全 https://）。供「输入网址」与剪贴板快捷入口共用。
    static func fromWebURL(_ raw: String) -> ReadingDocument? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        return ReadingDocument(title: host, sourceKind: .web, paragraphs: [], sourceURL: s)
    }

    /// Markdown（上传文件解析后的内容）→ ReadingDocument(.text)
    static func fromMarkdown(_ markdown: String, title: String, sourceURL: String?, language: String? = nil) -> ReadingDocument {
        let parsed = MarkdownParser.parse(markdown)
        var paragraphs: [ReadingParagraph] = []
        var idx = 0
        for p in parsed.paragraphs {
            let trimmed = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }   // 跳过空段/代码块（text 为空）
            let type = mapType(p.type)
            // 标题保持整体；正文/列表按行/句拆细，便于滚动与高亮逐行跟随
            let pieces: [String]
            if case .heading = type { pieces = [trimmed] } else { pieces = splitForReading(p.text) }
            for piece in pieces {
                paragraphs.append(ReadingParagraph(id: idx, text: piece, type: type))
                idx += 1
            }
        }
        let lang = language ?? detectLanguage(parsed.plainText)
        return ReadingDocument(title: title.isEmpty ? defaultTitle(paragraphs) : title,
                               sourceKind: .text, language: lang,
                               paragraphs: paragraphs, sourceURL: sourceURL)
    }

    /// 纯文本输入 → ReadingDocument(.text)
    static func fromPlainText(_ text: String, title: String, language: String? = nil) -> ReadingDocument {
        let chunks = splitForReading(text)
        let paragraphs = chunks.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) }
        let lang = language ?? detectLanguage(text)
        return ReadingDocument(title: title.isEmpty ? defaultTitle(paragraphs) : title,
                               sourceKind: .text, language: lang,
                               paragraphs: paragraphs, sourceURL: nil)
    }

    // MARK: - Helpers

    private static func mapType(_ t: ParagraphType) -> ReadingParagraphType {
        switch t {
        case .paragraph: return .paragraph
        case .heading(let l): return .heading(l)
        case .blockquote: return .blockquote
        case .code: return .code
        case .list: return .list
        case .image: return .caption
        }
    }

    /// 按行拆；过长的行再按句拆 → 细粒度阅读单元（让滚动/高亮逐行跟随，不会卡在超大段落里）。
    private static func splitForReading(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [String] = []
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.count > 160 { result.append(contentsOf: splitSentences(line)) }
            else { result.append(line) }
        }
        if result.isEmpty {
            let t = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [t]
        }
        return result
    }

    /// 按句末标点拆句（中英）。
    private static func splitSentences(_ text: String) -> [String] {
        let values = ReadingSentenceContract.segments(text)
        return values.isEmpty ? [text] : values
    }

    private static func detectLanguage(_ text: String) -> String {
        LanguageDetector.detect(text)
    }

    private static func defaultTitle(_ paragraphs: [ReadingParagraph]) -> String {
        String((paragraphs.first?.text ?? AppLocalized("Untitled")).prefix(40))
    }
}
