//
//  EpubNativeEngine.swift
//  CastReader
//
//  纯本地 EPUB 解析（不触网；独立 SVG 插图用禁用脚本的 WebKit 绘制）：
//  ZIPFoundation 解 EPUB → 读 META-INF/container.xml 找 OPF → 解析 manifest+spine →
//  按 spine 顺序逐章 XHTML 经 HtmlParser 抽段落（含图片）→ 合并、重排 index、内嵌图片字节回填。
//  产出 [ReadingParagraph]（图片段带 imageData），交 TextReaderView 原生渲染，
//  朗读/解读/MarkAnchoring 管线与 PDF/text 源完全复用。回译自 Android EpubNativeEngine。
//

import Foundation
import ZIPFoundation
import SwiftSoup
import ImageIO

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
        let navigation: EpubNavigation
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

        // Container URLs are relative to the ZIP root, not META-INF.
        guard let containerData = try entryData("META-INF/container.xml", maximumBytes: maximumContainerMarkupBytes),
              let containerXML = decodeXml(containerData),
              let container = try? SwiftSoup.parse(containerXML, "", Parser.xmlParser()) else { return nil }
        let roots = EpubXML.descendants(container, "rootfile")
        guard let root = roots.first(where: { EpubXML.attr($0, "media-type") == "application/oebps-package+xml" }) ?? roots.first,
              let opf = EpubResourceURL.resolve(EpubXML.attr(root, "full-path"), relativeTo: "")?.path,
              let opfData = try entryData(opf, maximumBytes: maximumPackageMarkupBytes),
              let opfXML = decodeXml(opfData),
              let opfDoc = try? SwiftSoup.parse(opfXML, "", Parser.xmlParser()) else { return nil }
        struct Item {
            let id: String
            let path: String
            let type: String
            let properties: Set<String>
        }
        var items: [Item] = []
        if let manifest = EpubXML.descendants(opfDoc, "manifest").first {
            for element in EpubXML.children(manifest, "item") {
                try Task.checkCancellation()
                let id = EpubXML.attr(element, "id")
                guard !id.isEmpty, let target = EpubResourceURL.resolve(EpubXML.attr(element, "href"), relativeTo: opf) else { continue }
                items.append(Item(id: id, path: target.path, type: EpubXML.attr(element, "media-type").lowercased(),
                                  properties: EpubXML.tokens(EpubXML.attr(element, "properties"))))
            }
        }
        var manifest: [String: Item] = [:]
        for item in items where manifest[item.id] == nil { manifest[item.id] = item }
        guard let spine = EpubXML.descendants(opfDoc, "spine").first else { return nil }
        var chapters = EpubXML.children(spine, "itemref").compactMap { manifest[EpubXML.attr($0, "idref")] }
        guard !chapters.isEmpty else { return nil }

        // Read both published sources. A valid NAV takes precedence over NCX;
        // an unusable NAV may fall back to the NCX without combining duplicates.
        var candidates: [EpubNavigation] = []
        var navPaths = Set<String>()
        func readNavigation(_ item: Item, source: EpubNavigation.Source) throws {
            try Task.checkCancellation()
            guard let data = try entryData(item.path, maximumBytes: maximumChapterMarkupBytes),
                  let markup = decodeXml(data),
                  let navigation = EpubNavigationParser.parse(markup, path: item.path, source: source) else { return }
            candidates.append(navigation)
        }
        for item in items where item.properties.contains("nav") {
            navPaths.insert(item.path)
            try readNavigation(item, source: .nav)
        }
        let declaredNCX = manifest[EpubXML.attr(spine, "toc")]
        let ncx = declaredNCX ?? items.first(where: { $0.type == "application/x-dtbncx+xml" })
        if let ncx { try readNavigation(ncx, source: .ncx) }
        if let guide = EpubXML.descendants(opfDoc, "guide").first,
           let reference = EpubXML.children(guide, "reference").first(where: { EpubXML.tokens(EpubXML.attr($0, "type")).contains("toc") }),
           let path = EpubResourceURL.resolve(EpubXML.attr(reference, "href"), relativeTo: opf)?.path,
           let item = items.first(where: { $0.path == path }) {
            try readNavigation(item, source: .guide)
        }
        var requested: [String: Set<String>] = [:]
        for entry in candidates.flatMap(\.entries) {
            guard let path = entry.href else { continue }
            if let fragment = entry.fragment { requested[path, default: []].insert(fragment) }
            // Tolerate published TOC destinations omitted from spine, but only
            // if declared in this publication's manifest.
            if !chapters.contains(where: { $0.path == path }),
               let item = items.first(where: { $0.path == path }) { chapters.append(item) }
        }
        var images: [String: Data] = [:]
        for item in items where item.type.hasPrefix("image/") {
            if let data = try entryData(item.path) { images[item.path] = data }
        }
        func illustration(_ href: String, relativeTo base: String) throws -> Data? {
            let path = EpubResourceURL.resolve(href, relativeTo: base)?.path
            let data: Data?
            if let embedded = EpubImageResource.embeddedData(href) { data = embedded }
            else if let path, let cached = images[path] { data = cached }
            else if let path { data = try entryData(path) }
            else { data = nil }
            guard let data else { return nil }
            if EpubImageResource.isSVG(data) {
                let svgBase = href.lowercased().hasPrefix("data:") ? base : (path ?? base)
                return EpubImageResource.svg(data) { nested in
                    guard let target = EpubResourceURL.resolve(nested, relativeTo: svgBase)?.path else { return nil }
                    return images[target]
                }
            }
            return CGImageSourceCreateWithData(data as CFData, nil) != nil ? data : nil
        }
        var paragraphs: [ReadingParagraph] = []
        var starts: [String: Int] = [:]
        var anchors: [String: [String: Int]] = [:]
        var generated: [EpubNavigation.Entry] = []
        var spineEntries: [EpubNavigation.Entry] = []
        var visited = Set<String>()
        for item in chapters {
            try Task.checkCancellation()
            guard visited.insert(item.path).inserted,
                  item.type.contains("html") || item.type.contains("xml"),
                  item.type != "application/x-dtbncx+xml",
                  let chapterData = try entryData(item.path, maximumBytes: maximumChapterMarkupBytes),
                  let markup = decodeXml(chapterData) else { continue }
            let blocks = try EpubContentParser.parse(markup, referencedFragments: requested[item.path] ?? [])
            let chapterStart = paragraphs.count
            for block in blocks {
                try Task.checkCancellation()
                var imageData: Data?
                if block.type == .image {
                    guard let href = block.imageHref,
                          let data = try illustration(href, relativeTo: item.path) else { continue }
                    imageData = data
                }
                let index = paragraphs.count
                for anchor in block.anchors where anchors[item.path]?[anchor] == nil {
                    anchors[item.path, default: [:]][anchor] = index
                }
                paragraphs.append(ReadingParagraph(id: index, text: block.text, type: block.type, imageData: imageData))
                if case .heading(let level) = block.type, !navPaths.contains(item.path) {
                    generated.append(.init(id: "heading-\(index)", title: block.text, depth: level - 1,
                                           href: item.path, fragment: nil, paragraphIndex: index, isGroup: false))
                }
            }
            if paragraphs.count > chapterStart {
                starts[item.path] = chapterStart
                let title = paragraphs[chapterStart...].first(where: { !$0.text.isEmpty })?.text
                    ?? (item.path as NSString).lastPathComponent
                spineEntries.append(.init(id: "spine-\(chapterStart)", title: title, depth: 0,
                                          href: item.path, fragment: nil, paragraphIndex: chapterStart, isGroup: false))
            }
        }
        guard !paragraphs.isEmpty else { return nil }
        for index in candidates.indices {
            for row in candidates[index].entries.indices {
                let entry = candidates[index].entries[row]
                guard let path = entry.href else { continue }
                // A missing fragment never silently degrades to chapter start.
                candidates[index].entries[row].paragraphIndex = entry.fragment.map { anchors[path]?[$0] } ?? starts[path]
            }
        }
        let fallback = EpubNavigation(source: generated.isEmpty ? .spine : .headings,
                                      entries: Array((generated.isEmpty ? spineEntries : generated).prefix(EpubNavigationParser.maximumEntries)))
        let navigation = EpubNavigationSelection.select(candidates, paragraphs: paragraphs) ?? fallback
        let title = try extractTitleCancellable(opfDoc) ?? fallbackTitle
        try Task.checkCancellation()
        return ParsedEpub(title: title, paragraphs: paragraphs, navigation: navigation)
    }

    // MARK: - Helpers

    private enum ExtractionLimitError: Error {
        case exceeded
    }

    /// 从 OPF metadata 取 dc:title（按 tagName 含 "title" 匹配，避开命名空间选择器兼容性问题）。
    /// 注意 SwiftSoup.Document 显式限定——CastReader 另有 Models/Document.swift 同名类型。
    private static func extractTitleCancellable(_ opfDoc: SwiftSoup.Document) throws -> String? {
        try Task.checkCancellation()
        guard let meta = EpubXML.descendants(opfDoc, "metadata").first else { return nil }
        for el in (try? meta.getAllElements().array()) ?? [] {
            try Task.checkCancellation()
            if EpubXML.name(el) == "title", let t = try? el.text() {
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
