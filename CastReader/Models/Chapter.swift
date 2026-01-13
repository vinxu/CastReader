//
//  Chapter.swift
//  CastReader
//

import Foundation

struct Chapter: Codable, Identifiable {
    let id: String
    let title: String
    let content: String
    let order: Int

    var paragraphs: [String] {
        content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Table of Contents
struct TOCItem: Identifiable {
    let id: String
    let title: String
    let level: Int
    let chapterIndex: Int
    var children: [TOCItem]
    var isExpanded: Bool = false
}
