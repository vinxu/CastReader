//
//  MarkdownParser.swift
//  CastReader
//

import Foundation

/// Markdown parser for extracting paragraphs and TOC
/// Matches the web markdown-parser.ts functionality
class MarkdownParser {

    /// Parse Markdown content into paragraphs and TOC
    static func parse(_ markdown: String) -> ParsedMarkdown {
        var paragraphs: [MarkdownParagraph] = []
        var toc: [MarkdownTocItem] = []
        var index = 0

        let lines = markdown.components(separatedBy: "\n")
        var currentParagraph = ""
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check for code block (```)
            if trimmed.hasPrefix("```") {
                // Flush current paragraph
                if !currentParagraph.isEmpty {
                    paragraphs.append(createParagraph(text: currentParagraph, index: &index))
                    currentParagraph = ""
                }

                // Find end of code block
                var codeContent = ""
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    if !codeContent.isEmpty {
                        codeContent += "\n"
                    }
                    codeContent += lines[i]
                    i += 1
                }

                // Add code block paragraph (empty text for TTS)
                let escapedCode = escapeHtml(codeContent)
                let html = "<pre><code class=\"language-\(language)\">\(escapedCode)</code></pre>"
                paragraphs.append(MarkdownParagraph(
                    id: UUID().uuidString,
                    index: index,
                    type: .code,
                    level: nil,
                    text: "", // Code blocks are not read aloud
                    html: html,
                    anchorId: nil
                ))
                index += 1
                i += 1
                continue
            }

            // Check for heading: # ## ### etc.
            if let headingMatch = parseHeading(trimmed) {
                // Flush current paragraph
                if !currentParagraph.isEmpty {
                    paragraphs.append(createParagraph(text: currentParagraph, index: &index))
                    currentParagraph = ""
                }

                let (level, text, anchorId) = headingMatch
                paragraphs.append(MarkdownParagraph(
                    id: UUID().uuidString,
                    index: index,
                    type: .heading,
                    level: level,
                    text: text,
                    html: "<h\(level) id=\"\(anchorId)\">\(escapeHtml(text))</h\(level)>",
                    anchorId: anchorId
                ))
                toc.append(MarkdownTocItem(id: anchorId, text: text, level: level))
                index += 1
                i += 1
                continue
            }

            // Check for blockquote: > text
            if trimmed.hasPrefix(">") {
                // Flush current paragraph
                if !currentParagraph.isEmpty {
                    paragraphs.append(createParagraph(text: currentParagraph, index: &index))
                    currentParagraph = ""
                }

                // Collect blockquote lines
                var quoteContent = ""
                while i < lines.count {
                    let quoteLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if quoteLine.hasPrefix(">") {
                        let content = String(quoteLine.dropFirst()).trimmingCharacters(in: .whitespaces)
                        if !quoteContent.isEmpty {
                            quoteContent += "\n"
                        }
                        quoteContent += content
                        i += 1
                    } else if quoteLine.isEmpty && i + 1 < lines.count && lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                        // Continue blockquote across empty line if next line is also blockquote
                        i += 1
                    } else {
                        break
                    }
                }

                paragraphs.append(MarkdownParagraph(
                    id: UUID().uuidString,
                    index: index,
                    type: .blockquote,
                    level: nil,
                    text: quoteContent,
                    html: "<blockquote>\(escapeHtml(quoteContent).replacingOccurrences(of: "\n", with: "<br>"))</blockquote>",
                    anchorId: nil
                ))
                index += 1
                continue
            }

            // Check for list item: - or * or 1.
            if isListItem(trimmed) {
                // Flush current paragraph
                if !currentParagraph.isEmpty {
                    paragraphs.append(createParagraph(text: currentParagraph, index: &index))
                    currentParagraph = ""
                }

                // Collect list items
                var listItems: [String] = []
                let isOrdered = trimmed.first?.isNumber ?? false

                while i < lines.count {
                    let listLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if isListItem(listLine) {
                        let content = extractListItemContent(listLine)
                        listItems.append(content)
                        i += 1
                    } else if listLine.isEmpty {
                        // Check if next non-empty line is still a list item
                        var nextIndex = i + 1
                        while nextIndex < lines.count && lines[nextIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                            nextIndex += 1
                        }
                        if nextIndex < lines.count && isListItem(lines[nextIndex].trimmingCharacters(in: .whitespaces)) {
                            i += 1
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }

                let text = listItems.joined(separator: "\n")
                let tag = isOrdered ? "ol" : "ul"
                let html = "<\(tag)>" + listItems.map { "<li>\(escapeHtml($0))</li>" }.joined() + "</\(tag)>"

                paragraphs.append(MarkdownParagraph(
                    id: UUID().uuidString,
                    index: index,
                    type: .list,
                    level: nil,
                    text: text,
                    html: html,
                    anchorId: nil
                ))
                index += 1
                continue
            }

            // Empty line - end current paragraph
            if trimmed.isEmpty {
                if !currentParagraph.isEmpty {
                    paragraphs.append(createParagraph(text: currentParagraph, index: &index))
                    currentParagraph = ""
                }
                i += 1
                continue
            }

            // Regular text - accumulate into paragraph
            if !currentParagraph.isEmpty {
                currentParagraph += "\n"
            }
            currentParagraph += trimmed
            i += 1
        }

        // Handle last paragraph
        if !currentParagraph.isEmpty {
            paragraphs.append(createParagraph(text: currentParagraph, index: &index))
        }

        let plainText = paragraphs
            .filter { $0.type != .code && !$0.text.isEmpty }
            .map { $0.text }
            .joined(separator: "\n\n")

        return ParsedMarkdown(paragraphs: paragraphs, toc: toc, plainText: plainText)
    }

    // MARK: - Private Helpers

    /// Parse heading line: # Title -> (level, text, anchorId)
    private static func parseHeading(_ line: String) -> (Int, String, String)? {
        guard line.hasPrefix("#") else { return nil }

        var level = 0
        for char in line {
            if char == "#" {
                level += 1
            } else {
                break
            }
        }

        guard level >= 1 && level <= 6 else { return nil }

        let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let anchorId = generateAnchorId(text)
        return (level, text, anchorId)
    }

    /// Generate anchor ID from heading text
    private static func generateAnchorId(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\u4e00-\\u9fff]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Check if line is a list item
    private static func isListItem(_ line: String) -> Bool {
        // Unordered: - item or * item
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return true
        }
        // Ordered: 1. item, 2. item, etc.
        if let dotIndex = line.firstIndex(of: ".") {
            let prefix = String(line[..<dotIndex])
            if prefix.allSatisfy({ $0.isNumber }) && line.index(after: dotIndex) < line.endIndex {
                return true
            }
        }
        return false
    }

    /// Extract content from list item
    private static func extractListItemContent(_ line: String) -> String {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }
        if let dotIndex = line.firstIndex(of: ".") {
            let afterDot = line.index(after: dotIndex)
            if afterDot < line.endIndex {
                return String(line[afterDot...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return line
    }

    /// Create a paragraph from accumulated text
    private static func createParagraph(text: String, index: inout Int) -> MarkdownParagraph {
        let para = MarkdownParagraph(
            id: UUID().uuidString,
            index: index,
            type: .paragraph,
            level: nil,
            text: text,
            html: "<p>\(escapeHtml(text).replacingOccurrences(of: "\n", with: "<br>"))</p>",
            anchorId: nil
        )
        index += 1
        return para
    }

    /// Escape HTML special characters
    private static func escapeHtml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#039;")
    }
}
