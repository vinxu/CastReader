//
//  EpubNativeEngine.swift
//  CastReader
//
//  纯本地 EPUB 解析（对标 PDF 的 fromPDFNative，全程不触网、不走 WebView）：
//  ZIPFoundation 解 EPUB → 读 META-INF/container.xml 找 OPF → 解析 manifest+spine →
//  按 spine 顺序逐章 XHTML 经 HtmlParser 抽段落（含图片）→ 合并、重排 index、内嵌图片字节回填。
//  产出 [ReadingParagraph]（图片段带 imageData），交 TextReaderView 原生渲染，
//  朗读/解读/MarkAnchoring 管线与 PDF/text 源完全复用。回译自 Android EpubNativeEngine。
//

import Foundation
import ZIPFoundation
import SwiftSoup

enum EpubNativeEngine {

    /// Bound synchronous SwiftSoup/HtmlParser work between cancellation
    /// checkpoints. Images keep the archive-wide limit and are streamed in
    /// cancellable chunks; XML/XHTML larger than this is rejected as malformed.
    static let maximumContainerMarkupBytes: UInt64 = 1 * 1_024 * 1_024
    static let maximumPackageMarkupBytes: UInt64 = 8 * 1_024 * 1_024
    static let maximumChapterMarkupBytes: UInt64 = 8 * 1_024 * 1_024

    struct ParsedEpub {
        let title: String?
        let paragraphs: [ReadingParagraph]
    }

    /// 解析 EPUB 字节为顺序段落（图片段已回填字节）。失败返回 nil（调用方回退原上传流程）。
    static func parse(data: Data, fallbackTitle: String) -> ParsedEpub? {
        try? parseCancellable(data: data, fallbackTitle: fallbackTitle)
    }

    /// Cancellation-aware EPUB parser used by the device-only import path.
    /// Ordinary malformed input returns nil; cancellation and enforced resource
    /// limits remain observable so callers can report them without partial books.
    static func parseCancellable(data: Data, fallbackTitle: String) throws -> ParsedEpub? {
        try Task.checkCancellation()
        guard Int64(data.count) <= SupportedDocumentFormat.epub.maximumInputBytes else {
            return nil
        }
        let archive: Archive
        do {
            archive = try Archive(
                data: data,
                accessMode: .read,
                pathEncoding: nil
            )
        } catch {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        try DocumentArchiveValidator.validate(archive)

        var extractedBytes: UInt64 = 0

        func entryData(
            _ path: String,
            maximumBytes: UInt64 = DocumentResourceLimits.archive.maximumEntryUncompressedBytes
        ) throws -> Data? {
            try Task.checkCancellation()
            guard let entry = archive[path], entry.type == .file else { return nil }
            guard entry.uncompressedSize <= maximumBytes else {
                if maximumBytes == DocumentResourceLimits.archive.maximumEntryUncompressedBytes {
                    throw DocumentImportError.resourceLimitExceeded(.archiveEntryTooLarge)
                }
                throw DocumentImportError.invalidEPUB(reason: "markup_entry_too_large")
            }
            var d = Data()
            d.reserveCapacity(Int(entry.uncompressedSize))
            do {
                _ = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    let chunkBytes = UInt64(chunk.count)
                    guard UInt64(d.count) <= DocumentResourceLimits.archive.maximumEntryUncompressedBytes,
                          chunkBytes <= DocumentResourceLimits.archive.maximumEntryUncompressedBytes - UInt64(d.count) else {
                        throw DocumentImportError.resourceLimitExceeded(.archiveEntryTooLarge)
                    }
                    guard extractedBytes <= DocumentResourceLimits.archive.maximumTotalUncompressedBytes,
                          chunkBytes <= DocumentResourceLimits.archive.maximumTotalUncompressedBytes - extractedBytes else {
                        throw DocumentImportError.resourceLimitExceeded(.archiveExpandedSizeTooLarge)
                    }
                    guard UInt64(d.count) <= maximumBytes,
                          chunkBytes <= maximumBytes - UInt64(d.count) else {
                        throw ExtractionLimitError.exceeded
                    }
                    d.append(chunk)
                    extractedBytes += chunkBytes
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DocumentImportError {
                throw error
            } catch is ExtractionLimitError {
                throw DocumentImportError.invalidEPUB(reason: "markup_entry_too_large")
            } catch {
                try Task.checkCancellation()
                return nil
            }
            try Task.checkCancellation()
            return d
        }

        // 1. META-INF/container.xml → OPF 路径
        guard let containerData = try entryData(
            "META-INF/container.xml",
            maximumBytes: maximumContainerMarkupBytes
        ),
              let containerXml = decodeXml(containerData),
              let containerDoc = try? SwiftSoup.parse(containerXml, "", Parser.xmlParser()),
              let opf = (try? containerDoc.select("rootfile").first()?.attr("full-path")) ?? nil,
              !opf.isEmpty else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()

        // OPF 所在目录（相对 zip 根）—— manifest 内 href 相对此目录
        let opfPathNorm = normHref(opf)
        let opfDir: String = opfPathNorm.contains("/")
            ? String(opfPathNorm[..<opfPathNorm.lastIndex(of: "/")!]) : ""

        func zipPath(relOpf: String) -> String {
            normHref(opfDir.isEmpty ? relOpf : opfDir + "/" + relOpf)
        }

        // 2. OPF → manifest（id→href,type）+ spine（阅读顺序）
        let primaryOPFData = try entryData(opf, maximumBytes: maximumPackageMarkupBytes)
        let resolvedOPFData: Data?
        if let primaryOPFData {
            resolvedOPFData = primaryOPFData
        } else {
            resolvedOPFData = try entryData(
                opfPathNorm,
                maximumBytes: maximumPackageMarkupBytes
            )
        }
        guard let opfData = resolvedOPFData,
              let opfXml = decodeXml(opfData),
              let opfDoc = try? SwiftSoup.parse(opfXml, "", Parser.xmlParser()) else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()

        var manifest: [String: (href: String, type: String)] = [:]
        let manifestItems = (try? opfDoc.select("manifest item").array()) ?? []
        try Task.checkCancellation()
        for item in manifestItems {
            try Task.checkCancellation()
            let id = (try? item.attr("id")) ?? ""
            let href = (try? item.attr("href")) ?? ""
            let type = (try? item.attr("media-type")) ?? ""
            if !id.isEmpty, !href.isEmpty { manifest[id] = (href, type) }
        }
        var spine: [String] = []
        let spineItems = (try? opfDoc.select("spine itemref").array()) ?? []
        try Task.checkCancellation()
        for r in spineItems {
            try Task.checkCancellation()
            let idref = (try? r.attr("idref")) ?? ""
            if !idref.isEmpty { spine.append(idref) }
        }
        guard !spine.isEmpty else {
            try Task.checkCancellation()
            return nil
        }

        // 3. 内嵌图片资源：规范化 href（相对 OPF 目录）→ 字节
        var images: [String: Data] = [:]
        for item in manifest.values {
            try Task.checkCancellation()
            guard item.type.lowercased().hasPrefix("image/") else { continue }
            if let d = try entryData(zipPath(relOpf: item.href)) {
                images[normHref(item.href)] = d
            }
        }

        // 4. 按 spine 顺序逐章解析 → 合并段落、重排 id、回填图片字节
        var paragraphs: [ReadingParagraph] = []
        var idx = 0
        for idref in spine {
            try Task.checkCancellation()
            guard let item = manifest[idref] else { continue }
            let t = item.type.lowercased()
            guard t.contains("html") || t.contains("xml") else { continue }   // 仅 XHTML 章节
            guard let chData = try entryData(
                zipPath(relOpf: item.href),
                maximumBytes: maximumChapterMarkupBytes
            ),
                  let xhtml = decodeXml(chData) else { continue }
            try Task.checkCancellation()
            let blocks = HtmlParser.parse(xhtml)
            try Task.checkCancellation()
            for b in blocks {
                try Task.checkCancellation()
                var imageData: Data? = nil
                if b.type == .image {
                    guard let href = b.imageHref else { continue }
                    guard let d = images[resolveImageHref(href, chapterHref: item.href)] else { continue }   // 无字节 → 跳过图片段
                    imageData = d
                } else if b.text.isEmpty {
                    continue
                }
                // 图片段 text 置空：占 id 保 index 对齐，但不让 caption("Image") 污染解读 fullText / 后端段落
                paragraphs.append(ReadingParagraph(id: idx, text: b.type == .image ? "" : b.text, type: b.type, imageData: imageData))
                idx += 1
            }
        }

        try Task.checkCancellation()
        guard !paragraphs.isEmpty else {
            try Task.checkCancellation()
            return nil
        }
        let title = try extractTitleCancellable(opfDoc) ?? fallbackTitle
        try Task.checkCancellation()
        return ParsedEpub(title: title, paragraphs: paragraphs)
    }

    // MARK: - Helpers

    private enum ExtractionLimitError: Error {
        case exceeded
    }

    /// 从 OPF metadata 取 dc:title（按 tagName 含 "title" 匹配，避开命名空间选择器兼容性问题）。
    /// 注意 SwiftSoup.Document 显式限定——CastReader 另有 Models/Document.swift 同名类型。
    private static func extractTitleCancellable(_ opfDoc: SwiftSoup.Document) throws -> String? {
        try Task.checkCancellation()
        guard let meta = try? opfDoc.select("metadata").first() else { return nil }
        for el in (try? meta.getAllElements().array()) ?? [] {
            try Task.checkCancellation()
            if el.tagName().lowercased().contains("title"), let t = try? el.text() {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func decodeXml(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// <img src>（相对当前章节）→ 相对 OPF 目录的规范化 href，用于匹配 images map。
    private static func resolveImageHref(_ src: String, chapterHref: String) -> String {
        if src.isEmpty || src.hasPrefix("data:") || src.hasPrefix("http") { return src }
        let decoded = src.replacingOccurrences(of: "%20", with: " ")
        let baseDir = chapterHref.contains("/") ? String(chapterHref[..<chapterHref.lastIndex(of: "/")!]) : ""
        let combined: String
        if decoded.hasPrefix("/") {
            combined = String(decoded.drop(while: { $0 == "/" }))
        } else if baseDir.isEmpty {
            combined = decoded
        } else {
            combined = baseDir + "/" + decoded
        }
        return normHref(combined)
    }

    /// 规范化 href：解析 ./ 与 ../、去空段、decode %20。
    private static func normHref(_ href: String) -> String {
        let decoded = href.replacingOccurrences(of: "%20", with: " ")
        var parts: [String] = []
        for seg in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch seg {
            case ".": break
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(seg))
            }
        }
        return parts.joined(separator: "/")
    }
}
