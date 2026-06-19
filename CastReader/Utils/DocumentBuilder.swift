//
//  DocumentBuilder.swift
//  CastReader
//
//  把不同来源转换为统一 ReadingDocument：Markdown 文档、纯文本输入。
//  （拍摄源见 OCRService。）
//

import Foundation
import PDFKit

enum DocumentBuilder {

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
        var paragraphs: [ReadingParagraph] = []
        var pid = 0
        for pageIdx in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIdx), let pageStr = page.string else { continue }
            let ns = pageStr as NSString
            for r in sentenceRangesInPage(ns) {
                // pdfRange(r) 保留 page.string 原始范围（高亮 needle 用精确子串）；text 去 PDF 硬换行供 TTS 朗读（否则在换行处停顿）。
                let text = stripPdfLineBreaks(ns.substring(with: r)).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count < 2 { continue }
                paragraphs.append(ReadingParagraph(id: pid, text: text, pdfPageIndex: pageIdx, pdfRange: r))
                pid += 1
            }
        }
        guard !paragraphs.isEmpty else { return nil }
        let lang = detectLanguage(paragraphs.prefix(30).map(\.text).joined(separator: " "))
        return ReadingDocument(title: title ?? url.deletingPathExtension().lastPathComponent,
                               sourceKind: .pdf, language: lang, paragraphs: paragraphs, fileData: data)
    }

    /// page string 内按句末标点切句（中文 。！？；+ 英文 .!?; 后接空白/结尾），换行不切句（PDF 硬换行常在句中）。
    private static func sentenceRangesInPage(_ ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        let len = ns.length
        var i = 0
        while i < len {
            let cu = ns.character(at: i)
            var isEnd = (cu == 0x3002 || cu == 0xFF01 || cu == 0xFF1F || cu == 0xFF1B   // 。！？；
                         || cu == 0x21 || cu == 0x3F || cu == 0x3B)                      // ! ? ;
            if cu == 0x2E {   // '.'：英文句点仅当后接空白/结尾才切（避免小数/缩写）
                let nextBreak = (i + 1 >= len) || {
                    let n = ns.character(at: i + 1); return n == 0x20 || n == 0x0A || n == 0x0D
                }()
                if nextBreak { isEnd = true }
            }
            if isEnd {
                ranges.append(NSRange(location: start, length: i + 1 - start))
                start = i + 1
            }
            i += 1
        }
        if start < len { ranges.append(NSRange(location: start, length: len - start)) }
        return ranges
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
                if isCJKChar(prev) && isCJKChar(next) {
                    continue   // CJK 之间的换行 → 删除（中文连续、不停顿）
                }
                out.append(" ")   // 英文等 → 空格（保词边界）
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func isCJKChar(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x3000...0x303F).contains(v)   // CJK 标点
            || (0xFF00...0xFFEF).contains(v)   // 全角字符/标点
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
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if "。！？!?".contains(ch) {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [text] : out
    }

    private static func detectLanguage(_ text: String) -> String {
        LanguageDetector.detect(text)
    }

    private static func defaultTitle(_ paragraphs: [ReadingParagraph]) -> String {
        String((paragraphs.first?.text ?? String(localized: "Untitled")).prefix(40))
    }
}
