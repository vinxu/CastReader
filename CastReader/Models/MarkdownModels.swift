//
//  MarkdownModels.swift
//  CastReader
//

import Foundation

// MARK: - Paragraph Type
enum ParagraphType: String {
    case heading
    case paragraph
    case list
    case blockquote
    case code
}

// MARK: - Markdown Paragraph
struct MarkdownParagraph: Identifiable {
    let id: String           // UUID for SwiftUI
    let index: Int
    let type: ParagraphType
    let level: Int?          // Only for heading (1-6)
    let text: String         // For TTS
    let html: String         // For rendering
    let anchorId: String?    // For heading anchor
}

// MARK: - TOC Item
struct MarkdownTocItem: Identifiable {
    let id: String
    let text: String
    let level: Int
}

// MARK: - Parsed Markdown Result
struct ParsedMarkdown {
    let paragraphs: [MarkdownParagraph]
    let toc: [MarkdownTocItem]
    let plainText: String
}

// MARK: - Extension for PlayerView compatibility
extension ParsedMarkdown {
    /// Convert to PlayerView's expected format
    var asPlayerData: (paragraphs: [String], parsedParagraphs: [ParsedParagraph], indices: [BookIndex]) {
        // IMPORTANT: Filter BOTH arrays the same way to keep indices aligned
        // Filter out paragraphs with empty text (like code blocks)
        let nonEmptyParagraphs = paragraphs.filter { !$0.text.isEmpty }

        // TTS text array
        let texts = nonEmptyParagraphs.map { $0.text }

        // Convert to ParsedParagraph format - use new sequential indices
        let parsed = nonEmptyParagraphs.enumerated().map { idx, p in
            ParsedParagraph(id: p.anchorId, text: p.text, html: p.html, index: idx)
        }

        // Convert TOC to BookIndex format
        let indices = toc.map { BookIndex(href: $0.id, text: $0.text) }

        return (texts, parsed, indices)
    }
}
