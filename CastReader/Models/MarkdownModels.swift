//
//  MarkdownModels.swift
//  CastReader
//

import Foundation

// MARK: - Paragraph Type（原定义于已删除的 Book.swift，迁移至此长期保留）
enum ParagraphType: Equatable {
    case paragraph
    case heading(Int)
    case blockquote
    case code
    case list
    case image
}

// MARK: - Markdown Paragraph
struct MarkdownParagraph: Identifiable {
    let id: String           // UUID for SwiftUI
    let index: Int
    let type: ParagraphType
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

