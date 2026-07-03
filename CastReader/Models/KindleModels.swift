//
//  KindleModels.swift
//  CastReader
//
//  Native Kindle shelf metadata. Kindle content still comes from the user's
//  authenticated read.amazon.com WebView session; CastReader persists only
//  book metadata and local reading position.
//

import Foundation
import SwiftUI

struct KindleBook: Identifiable, Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case id, asin, title, author, coverURL, readerURL, progressLabel
        case lastOpenedAt, lastSyncedAt, lastReadPageKey, lastReadURL
    }

    let id: String
    var asin: String?
    var title: String
    var author: String
    var coverURL: String?
    var readerURL: String
    var progressLabel: String
    var lastOpenedAt: Date?
    var lastSyncedAt: Date
    var lastReadPageKey: String?
    var lastReadURL: String?

    var displayAuthor: String {
        author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "未知作者")
            : author
    }

    var displayProgress: String {
        progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "尚未开始")
            : progressLabel
    }

    var effectiveReaderURL: String {
        lastReadURL?.isEmpty == false ? (lastReadURL ?? readerURL) : readerURL
    }

    var isLikelyLibraryBook: Bool {
        KindleBookValidator.isLikelyLibraryBook(self)
    }
}

enum KindleBookValidator {
    private static let blockedTitlePhrases = [
        "download", "app store", "kindle app", "learn more", "read on any device",
        "help", "support", "settings", "notebook", "privacy", "terms",
        "下载", "应用商店", "了解更多", "任何设备", "帮助", "支持", "设置", "笔记"
    ]

    private static let blockedURLPhrases = [
        "kindle-library", "landing", "help", "support", "settings", "notebook",
        "appstore", "app-store", "download", "privacy", "terms"
    ]

    static func isLikelyLibraryBook(_ book: KindleBook) -> Bool {
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2 else { return false }

        let lowerTitle = title.lowercased()
        if blockedTitlePhrases.contains(where: { lowerTitle.contains($0) }) {
            return false
        }

        let rawURL = book.readerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return false }

        let lowerURL = rawURL.lowercased()
        let hasASIN = containsASIN(book.asin) || containsASIN(book.id) || containsASIN(rawURL)
        let isReaderPath = isKindleReaderPath(rawURL)

        guard hasASIN || isReaderPath else { return false }

        if !hasASIN && blockedURLPhrases.contains(where: { lowerURL.contains($0) }) {
            return false
        }
        return true
    }

    static func containsASIN(_ raw: String?) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        return raw.range(of: #"(?i)(^|[?&=/:\s-])([A-Z0-9]{10})(?=$|[&#/\s-])"#, options: .regularExpression) != nil
            || raw.range(of: #"(?i)[?&]asin=([A-Z0-9]{10})(?=$|[&#])"#, options: .regularExpression) != nil
    }

    static func isKindleReaderPath(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        let host = url.host?.lowercased() ?? ""
        guard host.contains("read.amazon.") else { return false }
        return url.path.lowercased().contains("/reader/")
    }
}

enum KindleLibrarySort: String, CaseIterable, Identifiable {
    case recent
    case title
    case author

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .recent: return "最近"
        case .title: return "书名"
        case .author: return "作者"
        }
    }
}
