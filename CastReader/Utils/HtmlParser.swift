//
//  HtmlParser.swift
//  CastReader
//
//  EPUB 章节 XHTML → 结构化段落块（文本/标题/引用/列表/代码/图片）。
//  SwiftSoup（Jsoup 的 Swift 移植）做内存高效的 DOM 遍历，忠实对齐 Android `HtmlParser`：
//  按文档顺序递归处理 body 子节点，跳过 script/style/nav/toc/pageno 等非正文；
//  图片段只记 src（相对章节路径），由 EpubNativeEngine 解析到内嵌资源字节。
//

import Foundation
import SwiftSoup

/// HTML 解析出的一个段落块（图片段只带 href，字节在 EpubNativeEngine 回填）。
struct EpubBlock {
    let type: ReadingParagraphType
    let text: String          // 正文 / 标题文字 / 图片 alt-caption
    let imageHref: String?    // Local resource href or an embedded SVG/data image
}

enum HtmlParser {

    /// 解析一章 XHTML 为顺序段落块。失败回退到纯文本切分。
    static func parse(_ html: String) -> [EpubBlock] {
        do {
            let doc = try SwiftSoup.parse(html)
            // 全局移除噪声元素（行号/页码/装饰首字母）—— 在解析副本上 remove，安全且省去 per-element clone。
            try? doc.select(".linenum, span.linenum, .pageno, .x-ebookmaker-pageno, img.dropcap").remove()
            guard let body = doc.body() else { return fallback(html) }

            var blocks: [EpubBlock] = []
            var processed = Set<ObjectIdentifier>()

            for child in body.children().array() {
                try processElement(child, into: &blocks, processed: &processed)
            }

            return blocks.isEmpty ? fallback(html) : blocks
        } catch {
            return fallback(html)
        }
    }

    // MARK: - 递归处理单元素（对齐 Android processElement）

    private static let skipTags: Set<String> = [
        "script", "style", "nav", "header", "footer",
        "noscript", "iframe"
    ]
    private static let skipClassFragments = [
        "toc", "table-of-contents", "navigation", "nav",
        "footer", "header", "pageno", "x-ebookmaker-pageno"
    ]

    private static func processElement(_ element: Element,
                                       into blocks: inout [EpubBlock],
                                       processed: inout Set<ObjectIdentifier>) throws {
        let oid = ObjectIdentifier(element)
        if processed.contains(oid) { return }

        let tag = element.tagName().lowercased()
        let classes: Set<String> = Set((try? element.classNames())?.map { $0 } ?? [])

        if skipTags.contains(tag) { return }
        // 跳过目录/导航/页码等容器
        if classes.contains(where: { cls in skipClassFragments.contains { cls.lowercased().contains($0) } }) {
            return
        }
        if tag == "span", classes.contains(where: { $0.lowercased().contains("pageno") }) { return }

        // Consume each DOM occurrence, not each filename: repeated figures are
        // meaningful content. Empty alt is accessibility metadata, not a dropcap.
        if tag == "img" {
            processed.insert(oid)
            let src = try element.attr("src")
            if !src.isEmpty {
                blocks.append(EpubBlock(type: .image,
                    text: nonEmpty(try? element.attr("alt")) ?? "Image", imageHref: src))
            }
            return
        }
        if tag == "svg" {
            processed.insert(oid)
            let markup = try element.outerHtml()
            blocks.append(EpubBlock(type: .image, text: "Image",
                imageHref: "data:image/svg+xml;base64," + Data(markup.utf8).base64EncodedString()))
            return
        }
        if isImageContainer(tag: tag, classes: classes) {
            try appendContent(element, type: .paragraph, into: &blocks)
            markSubtreeProcessed(element, into: &processed)
            return
        }
        if tag == "table" {
            // Preserve every cell and embedded image, with visible row/cell
            // boundaries. EPUB remains reflowed rather than discarding tables.
            func appendRows(_ container: Element) throws {
                for child in container.children().array() {
                    switch child.tagName().lowercased() {
                    case "caption": try appendContent(child, type: .paragraph, into: &blocks)
                    case "tr": try appendContent(child, type: .paragraph, into: &blocks, tableRow: true)
                    default: try appendRows(child)
                    }
                }
            }
            try appendRows(element)
            markSubtreeProcessed(element, into: &processed)
            return
        }

        // 诗歌容器（div.poem / div.stanza）→ 引用样式，保留换行
        if tag == "div", classes.contains("poem") || classes.contains("stanza") {
            markSubtreeProcessed(element, into: &processed)
            let text = try extractPoetryText(element)
            if !text.isEmpty { blocks.append(EpubBlock(type: .blockquote, text: text, imageHref: nil)) }
            return
        }

        // 标题 h1–h6
        if tag.count == 2, tag.hasPrefix("h"), let level = Int(String(tag.dropFirst())), (1...6).contains(level) {
            processed.insert(oid)
            try appendContent(element, type: .heading(level), into: &blocks)
            return
        }

        // 段落 / 引用 / 预格式 / 列表项
        switch tag {
        case "p":
            processed.insert(oid)
            try appendContent(element, type: .paragraph, into: &blocks)
            return
        case "blockquote":
            processed.insert(oid)
            try appendContent(element, type: .blockquote, into: &blocks)
            return
        case "pre":
            processed.insert(oid)
            let text = ((try? element.text(trimAndNormaliseWhitespace: false)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(EpubBlock(type: .code, text: text, imageHref: nil)) }
            return
        case "li":
            processed.insert(oid)
            try appendContent(element, type: .list, into: &blocks)
            return
        default:
            break
        }

        // 叶子 div（无块级子元素）且有足够文本 → 当段落
        if tag == "div", !hasBlockChildren(element) {
            let text = try extractText(element)
            if text.count > 10 {
                markSubtreeProcessed(element, into: &processed)
                try appendContent(element, type: .paragraph, into: &blocks)
                return
            }
        }

        // 容器元素：递归子节点
        for child in element.children().array() {
            try processElement(child, into: &blocks, processed: &processed)
        }
    }

    /// Walk mixed inline content in source order. Extracting only `.text()`
    /// from a paragraph silently loses images nested in p/a/span/blockquote/li.
    private static func appendContent(_ element: Element, type: ReadingParagraphType,
                                      into blocks: inout [EpubBlock], tableRow: Bool = false) throws {
        var text = ""
        func flush() {
            let value = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(EpubBlock(type: type, text: value, imageHref: nil)) }
            text = ""
        }
        func visit(_ node: Node) throws {
            if let value = node as? TextNode { text += value.getWholeText(); return }
            guard let child = node as? Element else { return }
            let tag = child.tagName().lowercased()
            if skipTags.contains(tag) { return }
            if tag == "img" {
                flush()
                let src = try child.attr("src")
                if !src.isEmpty {
                    blocks.append(EpubBlock(type: .image,
                        text: nonEmpty(try? child.attr("alt")) ?? "Image", imageHref: src))
                }
                return
            }
            if tag == "svg" {
                flush()
                let markup = try child.outerHtml()
                blocks.append(EpubBlock(type: .image, text: "Image",
                    imageHref: "data:image/svg+xml;base64," + Data(markup.utf8).base64EncodedString()))
                return
            }
            if tag == "br" { text += " "; return }
            let boundary = blockTags.contains(tag) || tag == "figcaption"
            if boundary { flush() }
            for node in child.getChildNodes() { try visit(node) }
            if boundary { flush() }
        }
        let children = element.getChildNodes()
        for (index, node) in children.enumerated() {
            if tableRow, let cell = node as? Element,
               ["td", "th"].contains(cell.tagName().lowercased()),
               index > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += " | " }
            try visit(node)
        }
        flush()
    }

    // MARK: - Helpers

    private static func isImageContainer(tag: String, classes: Set<String>) -> Bool {
        if tag == "figure" { return true }
        if tag == "div" {
            let imageClasses: Set<String> = ["figure", "figcenter", "figright", "figleft", "figfull", "illustration", "image"]
            if !classes.isDisjoint(with: imageClasses) { return true }
        }
        return false
    }

    private static let blockTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "div", "blockquote", "pre", "ul", "ol", "li"]

    private static func hasBlockChildren(_ element: Element) -> Bool {
        element.children().array().contains { blockTags.contains($0.tagName().lowercased()) }
    }

    private static func markSubtreeProcessed(_ element: Element, into processed: inout Set<ObjectIdentifier>) {
        processed.insert(ObjectIdentifier(element))
        if let all = try? element.getAllElements().array() {
            for e in all { processed.insert(ObjectIdentifier(e)) }
        }
    }

    /// 文本提取：<br>→空格，折叠空白。噪声元素（行号/页码/首字母图）已在 parse() 全局移除。
    private static func extractText(_ element: Element) throws -> String {
        try? element.select("br").after(" ")
        let text = try element.text()
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 诗歌：优先按缩进 span（class^=i）逐行，否则 <br> 切行。
    private static func extractPoetryText(_ element: Element) throws -> String {
        var lines: [String] = []
        if let spans = try? element.select("span[class^=i]"), !spans.isEmpty() {
            for span in spans.array() {
                let t = span.ownText()
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines.append(t) }
            }
        }
        if lines.isEmpty {
            try? element.select("br").after("\n")
            let raw = (try? element.text()) ?? ""
            lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return lines.joined(separator: "\n")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// 兜底：无结构段落时按空行/块边界切纯文本。
    private static func fallback(_ html: String) -> [EpubBlock] {
        guard let doc = try? SwiftSoup.parse(html), let bodyEl = doc.body(),
              let body = try? bodyEl.text() else { return [] }
        let parts = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
            .filter { $0.count > 5 }
        return parts.map { EpubBlock(type: .paragraph, text: $0, imageHref: nil) }
    }
}
