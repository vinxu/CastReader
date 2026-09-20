import Foundation
import SwiftSoup

/// Images stay self-contained: an EPUB illustration never fetches the network.
enum EpubImageResource {
    static func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(4096), encoding: .utf8) else { return false }
        return head.range(of: "<svg", options: .caseInsensitive) != nil
    }

    static func embeddedData(_ href: String) -> Data? {
        guard href.lowercased().hasPrefix("data:image/"), let comma = href.firstIndex(of: ",") else { return nil }
        let payload = String(href[href.index(after: comma)...])
        guard payload.utf8.count <= 16 * 1_024 * 1_024 else { return nil }
        if href[..<comma].lowercased().contains(";base64") { return Data(base64Encoded: payload) }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    static func svg(_ data: Data, resolve: (String) -> Data?) -> Data? {
        guard data.count <= 8 * 1_024 * 1_024, let source = String(data: data, encoding: .utf8),
              let document = try? SwiftSoup.parse(source, "", Parser.xmlParser()),
              let svg = try? document.select("svg").first() else { return nil }
        // Remove active content even though the view also disables JavaScript
        // and uses a CSP denying all external loads.
        try? svg.select("script, foreignObject, foreignobject, iframe, object, embed, audio, video, animate, set").remove()
        for element in (try? svg.getAllElements().array()) ?? [] {
            for attribute in element.getAttributes()?.asList() ?? [] {
                let key = attribute.getKey()
                if key.lowercased().hasPrefix("on") { try? element.removeAttr(key) }
            }
            if element.tagName().lowercased() == "image" {
                let href = (try? element.attr("href")) ?? ""
                let reference = href.isEmpty ? ((try? element.attr("xlink:href")) ?? "") : href
                try? element.removeAttr("xlink:href")
                if let image = embeddedData(reference) ?? resolve(reference), !isSVG(image) {
                    // WebKit sniffs the actual raster format for a data image.
                    try? element.attr("href", "data:image/png;base64," + image.base64EncodedString())
                } else { try? element.remove() }
            }
        }
        // SwiftSoup's HTML chapter parser lowercases SVG attributes. Restore
        // case-sensitive SVG spelling before WebKit receives standalone XML.
        let names = ["viewbox": "viewBox", "preserveaspectratio": "preserveAspectRatio",
                     "gradientunits": "gradientUnits", "gradienttransform": "gradientTransform",
                     "markerwidth": "markerWidth", "markerheight": "markerHeight",
                     "refx": "refX", "refy": "refY"]
        for element in (try? svg.getAllElements().array()) ?? [] {
            for (lower, canonical) in names where element.hasAttr(lower) {
                let value = (try? element.attr(lower)) ?? ""
                try? element.removeAttr(lower)
                try? element.attr(canonical, value)
            }
            let tags = ["lineargradient": "linearGradient", "radialgradient": "radialGradient", "clippath": "clipPath"]
            if let tag = tags[element.tagName()] { try? element.tagName(tag) }
        }
        try? svg.attr("xmlns", "http://www.w3.org/2000/svg")
        return (try? svg.outerHtml())?.data(using: .utf8)
    }

    static func svgAspectRatio(_ data: Data) -> CGFloat {
        guard let text = String(data: data, encoding: .utf8),
              let document = try? SwiftSoup.parse(text, "", Parser.xmlParser()),
              let svg = try? document.select("svg").first() else { return 1 }
        let values = ((try? svg.attr("viewBox")) ?? "").split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) }
        if values.count == 4, values[2] > 0, values[3] > 0 { return CGFloat(values[2] / values[3]) }
        let width = Double(((try? svg.attr("width")) ?? "").replacingOccurrences(of: "px", with: ""))
        let height = Double(((try? svg.attr("height")) ?? "").replacingOccurrences(of: "px", with: ""))
        if let width, let height, width > 0, height > 0 { return CGFloat(width / height) }
        return 1
    }
}
