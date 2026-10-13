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
    let imageHref: String?    // 仅 .image：<img src>（相对当前章节）
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
            var processedImages = Set<String>()

            for child in body.children().array() {
                try processElement(child, into: &blocks, processed: &processed, processedImages: &processedImages)
            }

            return blocks.isEmpty ? fallback(html) : blocks
        } catch {
            return fallback(html)
        }
    }

    // MARK: - 递归处理单元素（对齐 Android processElement）

    private static let skipTags: Set<String> = [
        "script", "style", "nav", "header", "footer",
        "table", "tbody", "tr", "td", "th", "noscript", "iframe", "svg"
    ]
    private static let skipClassFragments = [
        "toc", "table-of-contents", "navigation", "nav",
        "footer", "header", "pageno", "x-ebookmaker-pageno"
    ]

    private static func processElement(_ element: Element,
                                       into blocks: inout [EpubBlock],
                                       processed: inout Set<ObjectIdentifier>,
                                       processedImages: inout Set<String>) throws {
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

        // 图片容器（figure / div.figcenter|figright|figleft|figure|illustration|image）
        if isImageContainer(tag: tag, classes: classes) {
            if let img = try element.select("img").first() {
                let src = try img.attr("src")
                if !src.isEmpty, !processedImages.contains(src) {
                    processedImages.insert(src)
                    markSubtreeProcessed(element, into: &processed)
                    let caption = firstText(element, ".caption")
                        ?? firstText(element, "figcaption")
                        ?? nonEmpty(try? img.attr("alt"))
                        ?? nonEmpty(try? img.attr("title"))
                        ?? "Image"
                    blocks.append(EpubBlock(type: .image, text: caption, imageHref: src))
                }
            }
            return
        }

        // 独立 <img>
        if tag == "img" {
            let src = try element.attr("src")
            let alt = try element.attr("alt")
            let isDropcap = classes.contains("dropcap") || alt.count <= 1
            if !src.isEmpty, !processedImages.contains(src), !isDropcap {
                processedImages.insert(src)
                processed.insert(oid)
                let caption = nonEmpty(alt) ?? nonEmpty(try? element.attr("title")) ?? "Image"
                blocks.append(EpubBlock(type: .image, text: caption, imageHref: src))
            }
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
            let text = try extractText(element)
            if !text.isEmpty { blocks.append(EpubBlock(type: .heading(level), text: text, imageHref: nil)) }
            return
        }

        // 段落 / 引用 / 预格式 / 列表项
        switch tag {
        case "p":
            processed.insert(oid)
            let text = try extractText(element)
            if !text.isEmpty { blocks.append(EpubBlock(type: .paragraph, text: text, imageHref: nil)) }
            return
        case "blockquote":
            processed.insert(oid)
            let text = try extractText(element)
            if !text.isEmpty { blocks.append(EpubBlock(type: .blockquote, text: text, imageHref: nil)) }
            return
        case "pre":
            processed.insert(oid)
            let text = ((try? element.text(trimAndNormaliseWhitespace: false)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(EpubBlock(type: .code, text: text, imageHref: nil)) }
            return
        case "li":
            processed.insert(oid)
            let text = try extractText(element)
            if !text.isEmpty { blocks.append(EpubBlock(type: .list, text: text, imageHref: nil)) }
            return
        default:
            break
        }

        // 叶子 div（无块级子元素）且有足够文本 → 当段落
        if tag == "div", !hasBlockChildren(element) {
            let text = try extractText(element)
            if text.count > 10 {
                markSubtreeProcessed(element, into: &processed)
                blocks.append(EpubBlock(type: .paragraph, text: text, imageHref: nil))
                return
            }
        }

        // 容器元素：递归子节点
        for child in element.children().array() {
            try processElement(child, into: &blocks, processed: &processed, processedImages: &processedImages)
        }
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

    /// 取某 CSS 选择器命中的首个元素文本（非空）。
    private static func firstText(_ element: Element, _ css: String) -> String? {
        guard let el = try? element.select(css).first(), let t = try? el.text() else { return nil }
        return nonEmpty(t)
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
