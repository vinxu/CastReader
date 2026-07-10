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
        KindleBookValidator.repairedReaderURL(for: self, preferLastRead: true) ?? readerURL
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

        let rawURL = repairedReaderURL(for: book, preferLastRead: false) ?? book.readerURL.trimmingCharacters(in: .whitespacesAndNewlines)
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
        asinValue(in: raw) != nil
    }

    static func asinValue(in raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let patterns = [
            #"(?i)[?&]asin=([A-Z0-9]{10})(?=$|[&#])"#,
            #"(?i)(^|[?&=/:\s-])([A-Z0-9]{10})(?=$|[&#/\s-])"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, range: range) else { continue }
            let group = match.numberOfRanges > 2 ? 2 : 1
            guard let swiftRange = Range(match.range(at: group), in: raw) else { continue }
            return String(raw[swiftRange]).uppercased()
        }
        return nil
    }

    static func isKindleReaderPath(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        let host = url.host?.lowercased() ?? ""
        guard host.contains("read.amazon.") else { return false }
        return url.path.lowercased().contains("/reader/")
    }

    static func repairedReaderURL(for book: KindleBook, preferLastRead: Bool) -> String? {
        let candidates = preferLastRead ? [book.lastReadURL, Optional(book.readerURL)] : [Optional(book.readerURL), book.lastReadURL]
        for candidate in candidates {
            if let usable = usableReaderURL(candidate, fallbackASIN: book.asin ?? book.id) {
                return usable
            }
        }
        if let asin = asinValue(in: book.asin) ?? asinValue(in: book.id) {
            return canonicalReaderURL(asin: asin)
        }
        return nil
    }

    static func usableReaderURL(_ raw: String?, fallbackASIN: String? = nil) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isBareKindleRoot(trimmed), let asin = asinValue(in: fallbackASIN) {
            return canonicalReaderURL(asin: asin)
        }

        if let asin = asinValue(in: trimmed) {
            return canonicalReaderURL(asin: asin)
        }

        if isKindleReaderPath(trimmed) {
            return trimmed
        }

        return nil
    }

    static func canonicalReaderURL(asin: String) -> String {
        "https://read.amazon.com/?asin=\(asin.uppercased())&ref_=kwl_kr_iv_rec_1"
    }

    private static func isBareKindleRoot(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        let host = url.host?.lowercased() ?? ""
        guard host.contains("read.amazon.") else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty && (url.query?.isEmpty ?? true)
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
