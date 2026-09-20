import Foundation
import SwiftSoup

/// Render and index in the same traversal. Referenced inline anchors split at
/// their exact text boundary, so native scrolling and TTS share one destination.
/// This EPUB-only parser leaves DOCX/website extraction unchanged.
enum EpubContentParser {
    struct Block {
        let type: ReadingParagraphType
        let text: String
        let imageHref: String?
        let anchors: [String]
    }

    static func parse(_ markup: String, referencedFragments: Set<String>) throws -> [Block] {
        let doc = try SwiftSoup.parse(markup)
        guard let body = doc.body() else { return [] }
        var blocks: [Block] = []
        var pendingAnchors: [String] = []
        var text = ""
        var kind: ReadingParagraphType = .paragraph
        var pendingSpace = false
        let containers: Set<String> = ["p", "div", "section", "article", "header", "footer", "aside", "main",
            "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "li", "ul", "ol", "dl", "dt", "dd",
            "table", "caption", "thead", "tbody", "tfoot", "tr", "figure", "figcaption", "address", "hr"]

        func flush() {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                blocks.append(.init(type: kind, text: clean, imageHref: nil, anchors: pendingAnchors))
                pendingAnchors.removeAll(keepingCapacity: true)
            }
            text = ""; pendingSpace = false
        }
        func appendText(_ value: String) {
            // Normalize HTML whitespace while preserving meaningful inline adjacency.
            for char in value {
                if char.isWhitespace { pendingSpace = !text.isEmpty }
                else {
                    if pendingSpace { text.append(" "); pendingSpace = false }
                    text.append(char)
                }
            }
        }
        func walk(_ node: Node, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 256 else { throw DocumentImportError.invalidEPUB(reason: "content_nesting_too_deep") }
            if let t = node as? TextNode { appendText(t.getWholeText()); return }
            guard let element = node as? Element else { return }
            let tag = EpubXML.name(element)
            let semantics = EpubXML.semantics(element)
            let classes = EpubXML.tokens(EpubXML.attr(element, "class"))
            let role = EpubXML.tokens(EpubXML.attr(element, "role"))
            // Do not use substring class matches: e.g. 'navy'/'stock' are content.
            if ["script", "style", "noscript", "iframe"].contains(tag)
                || (tag == "nav" && (semantics.contains("toc") || semantics.contains("page-list") || semantics.contains("landmarks") || role.contains("doc-toc")))
                || semantics.contains("pagebreak") || role.contains("doc-pagebreak")
                || !classes.isDisjoint(with: ["pageno", "x-ebookmaker-pageno", "linenum"])
                || element.hasAttr("hidden") || EpubXML.attr(element, "aria-hidden") == "true" { return }
            let isBlock = containers.contains(tag)
            if isBlock { flush() }
            let anchors = [EpubXML.attr(element, "id"), EpubXML.attr(element, "xml:id"),
                           tag == "a" ? EpubXML.attr(element, "name") : ""]
                .filter { !$0.isEmpty && referencedFragments.contains($0) }
            if !anchors.isEmpty { flush(); pendingAnchors.append(contentsOf: anchors) }
            let previousKind = kind
            if tag.count == 2, tag.first == "h", let level = Int(tag.dropFirst()), (1...6).contains(level) { kind = .heading(level) }
            else if tag == "blockquote" { kind = .blockquote }
            else if tag == "pre" { kind = .code }
            else if tag == "li" { kind = .list }
            else if tag == "figcaption" { kind = .caption }
            else if isBlock && !["blockquote", "pre", "li"].contains(tag) && previousKind == .paragraph { kind = .paragraph }
            if tag == "svg" {
                flush()
                let markup = try element.outerHtml()
                blocks.append(.init(type: .image, text: "",
                    imageHref: "data:image/svg+xml;base64," + Data(markup.utf8).base64EncodedString(),
                    anchors: pendingAnchors))
                pendingAnchors.removeAll(keepingCapacity: true)
            } else if tag == "img" || tag == "image" {
                flush()
                let src = tag == "img" ? EpubXML.attr(element, "src") :
                    (EpubXML.attr(element, "href").isEmpty ? EpubXML.attr(element, "xlink:href") : EpubXML.attr(element, "href"))
                if !src.isEmpty && !classes.contains("dropcap") {
                    blocks.append(.init(type: .image, text: "", imageHref: src, anchors: pendingAnchors))
                    pendingAnchors.removeAll(keepingCapacity: true)
                }
            } else if tag == "br" { pendingSpace = !text.isEmpty }
            else {
                if (tag == "td" || tag == "th"), !text.isEmpty { appendText(" | ") }
                for child in element.getChildNodes() { try walk(child, depth: depth + 1) }
            }
            if isBlock { flush() }
            kind = previousKind
        }
        try walk(body, depth: 0)
        flush()
        return blocks
    }
}
