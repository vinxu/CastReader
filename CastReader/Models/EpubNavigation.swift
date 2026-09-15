import Foundation
import SwiftSoup

/// A preorder list preserves publisher order, nesting and non-link headings.
/// Targets refer to the *rendered* paragraph array, never a title search.
struct EpubNavigation: Codable, Equatable {
    enum Source: String, Codable { case nav, ncx, guide, headings, spine }
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let depth: Int
        let href: String?
        let fragment: String?
        var paragraphIndex: Int?
        let isGroup: Bool
    }
    let source: Source
    var entries: [Entry]
    var repairedFrom: Source? = nil

    func currentEntry(at paragraph: Int) -> String? {
        entries.filter { ($0.paragraphIndex ?? Int.max) <= paragraph }
            .max { lhs, rhs in
                if lhs.paragraphIndex == rhs.paragraphIndex { return lhs.depth < rhs.depth }
                return (lhs.paragraphIndex ?? -1) < (rhs.paragraphIndex ?? -1)
            }?.id
    }

    func isValid(paragraphCount: Int) -> Bool {
        entries.count <= EpubNavigationParser.maximumEntries
            && Set(entries.map(\.id)).count == entries.count
            && entries.allSatisfy {
                (0...EpubNavigationParser.maximumDepth).contains($0.depth)
                    && ($0.paragraphIndex.map { (0..<paragraphCount).contains($0) } ?? true)
            }
    }
}

enum EpubNavigationSelection {
    /// A converter may shift every NCX file number while retaining a correct
    /// in-book TOC. Prefer that independently corroborated source, never guess
    /// individual links from similar titles. Ambiguous/repeated headings do not
    /// vote, and one unusual chapter label cannot trigger a source replacement.
    static func select(_ candidates: [EpubNavigation], paragraphs: [ReadingParagraph]) -> EpubNavigation? {
        let usable = candidates.filter { $0.entries.contains { $0.paragraphIndex != nil } }
        guard let first = usable.first else { return nil }
        func key(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }.lowercased()
        }
        var headings: [String: [Int]] = [:]
        for paragraph in paragraphs {
            if case .heading = paragraph.type { headings[key(paragraph.text), default: []].append(paragraph.id) }
        }
        func score(_ navigation: EpubNavigation) -> (matches: Int, conflicts: Int) {
            var matches = 0, conflicts = 0
            for entry in navigation.entries where !entry.isGroup {
                guard let indexes = headings[key(entry.title)], indexes.count == 1,
                      let expected = indexes.first, let actual = entry.paragraphIndex else { continue }
                if actual == expected || (actual < expected && paragraphs[actual..<expected].allSatisfy { $0.text.isEmpty }) { matches += 1 }
                else { conflicts += 1 }
            }
            return (matches, conflicts)
        }
        let original = score(first)
        guard original.conflicts >= 3, original.conflicts > original.matches else { return first }
        for alternative in usable.dropFirst() {
            let quality = score(alternative)
            guard quality.matches >= 3, quality.matches > original.matches,
                  quality.matches >= 4 * max(quality.conflicts, 1) else { continue }
            var repaired = alternative
            repaired.repairedFrom = first.source
            // Preserve the publisher's hierarchy only when both entire label
            // sequences agree; otherwise keep the alternative's own structure.
            if first.entries.map({ key($0.title) }) == alternative.entries.map({ key($0.title) }) {
                repaired.entries = zip(alternative.entries, first.entries).map { entry, original in
                    .init(id: entry.id, title: entry.title, depth: original.depth, href: entry.href,
                          fragment: entry.fragment, paragraphIndex: entry.paragraphIndex, isGroup: entry.isGroup)
                }
            }
            return repaired
        }
        return first
    }
}

/// All resource URLs use the containing file as base and one URL decode.
/// Case and literal '+' are significant; queries do not identify ZIP entries.
enum EpubResourceURL {
    struct Target: Equatable { let path: String; let fragment: String? }
    static func resolve(_ href: String, relativeTo file: String) -> Target? {
        let value = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.hasPrefix("//"), !value.contains("\\"),
              let base = URL(string: "https://epub.invalid/")?.appendingPathComponent(file),
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host == "epub.invalid",
              url.port == nil, url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let path = components.percentEncodedPath.removingPercentEncoding,
              !path.contains("\0") else { return nil }
        // Encoded '/' is not a filename separator in OCF. Reject ambiguous paths.
        guard !components.percentEncodedPath.lowercased().contains("%2f"),
              !components.percentEncodedPath.lowercased().contains("%5c") else { return nil }
        let fragment = components.percentEncodedFragment?.removingPercentEncoding
        return Target(path: String(path.drop(while: { $0 == "/" })),
                      fragment: fragment.flatMap { $0.isEmpty ? nil : $0 })
    }
}

enum EpubXML {
    static func name(_ element: Element) -> String {
        element.tagName().split(separator: ":").last.map(String.init)?.lowercased() ?? ""
    }
    static func children(_ element: Element, _ tag: String) -> [Element] {
        element.children().array().filter { name($0) == tag }
    }
    static func descendants(_ element: Element, _ tag: String) -> [Element] {
        ((try? element.getAllElements().array()) ?? []).filter { name($0) == tag }
    }
    static func attr(_ element: Element, _ key: String) -> String { (try? element.attr(key)) ?? "" }
    static func tokens(_ value: String) -> Set<String> { Set(value.split(whereSeparator: \.isWhitespace).map(String.init)) }
    static func text(_ element: Element) -> String {
        ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func semantics(_ element: Element) -> Set<String> {
        var result = tokens(attr(element, "epub:type"))
        for attribute in element.getAttributes()?.asList() ?? [] {
            let key = attribute.getKey()
            guard key.hasSuffix(":type"), let prefix = key.split(separator: ":").first else { continue }
            var ancestor: Element? = element
            while let node = ancestor {
                if attr(node, "xmlns:\(prefix)") == "http://www.idpf.org/2007/ops" {
                    result.formUnion(tokens(attribute.getValue())); break
                }
                ancestor = node.parent()
            }
        }
        return result
    }
}

enum EpubNavigationParser {
    static let maximumEntries = 10_000
    static let maximumDepth = 64

    static func parse(_ markup: String, path: String, source: EpubNavigation.Source) -> EpubNavigation? {
        guard let doc = try? SwiftSoup.parse(markup, "", Parser.xmlParser()) else { return nil }
        var entries: [EpubNavigation.Entry] = []
        func baseFor(_ element: Element) -> String? {
            var base = path
            if source != .ncx, let htmlBase = EpubXML.descendants(doc, "base").first, htmlBase.hasAttr("href") {
                guard let target = EpubResourceURL.resolve(EpubXML.attr(htmlBase, "href"), relativeTo: base) else { return nil }
                base = target.path
            }
            var chain: [Element] = [], cursor: Element? = element
            while let node = cursor { chain.append(node); cursor = node.parent() }
            for node in chain.reversed() where node.hasAttr("xml:base") {
                guard let target = EpubResourceURL.resolve(EpubXML.attr(node, "xml:base"), relativeTo: base) else { return nil }
                base = target.path
            }
            return base
        }
        func append(title: String, href: String?, depth: Int, element: Element) {
            guard entries.count < maximumEntries, !title.isEmpty else { return }
            let target = href.flatMap { link in baseFor(element).flatMap { EpubResourceURL.resolve(link, relativeTo: $0) } }
            entries.append(.init(id: "\(source.rawValue)-\(entries.count)", title: title,
                                 depth: depth, href: target?.path, fragment: target?.fragment,
                                 paragraphIndex: nil, isGroup: href == nil))
        }
        func navList(_ list: Element, depth: Int) {
            guard depth <= maximumDepth, entries.count < maximumEntries else { return }
            for li in EpubXML.children(list, "li") {
                let children = li.children().array()
                if let label = children.first(where: { ["a", "span"].contains(EpubXML.name($0)) }) {
                    let href = EpubXML.name(label) == "a" && label.hasAttr("href") ? EpubXML.attr(label, "href") : nil
                    append(title: EpubXML.text(label), href: href, depth: depth, element: label)
                }
                for nested in children where ["ol", "ul"].contains(EpubXML.name(nested)) {
                    navList(nested, depth: depth + 1)
                }
            }
        }
        func ncxList(_ parent: Element, depth: Int) {
            guard depth <= maximumDepth, entries.count < maximumEntries else { return }
            for point in EpubXML.children(parent, "navpoint") {
                let label = EpubXML.children(point, "navlabel").first.map(EpubXML.text) ?? ""
                let link = EpubXML.children(point, "content").first
                append(title: label, href: link.map { EpubXML.attr($0, "src") }, depth: depth, element: link ?? point)
                ncxList(point, depth: depth + 1)
            }
        }
        switch source {
        case .ncx:
            guard let root = EpubXML.descendants(doc, "navmap").first else { return nil }
            ncxList(root, depth: 0)
        case .nav:
            let navs = EpubXML.descendants(doc, "nav")
            guard let root = navs.first(where: { EpubXML.semantics($0).contains("toc") })
                    ?? navs.first(where: { EpubXML.tokens(EpubXML.attr($0, "role")).contains("doc-toc") }) else { return nil }
            for list in root.children().array() where ["ol", "ul"].contains(EpubXML.name(list)) {
                navList(list, depth: 0)
            }
        case .guide:
            let root = EpubXML.descendants(doc, "body").first ?? doc
            let lists = root.children().array().filter { ["ol", "ul"].contains(EpubXML.name($0)) }
            if !lists.isEmpty { lists.forEach { navList($0, depth: 0) } }
            else {
                for link in EpubXML.descendants(root, "a") where link.hasAttr("href") {
                    append(title: EpubXML.text(link), href: EpubXML.attr(link, "href"), depth: 0, element: link)
                }
            }
        default: return nil
        }
        return entries.isEmpty ? nil : EpubNavigation(source: source, entries: entries)
    }
}
