//
//  KindleLibraryStore.swift
//  CastReader
//
//  Local Kindle shelf cache and progress store. Authentication lives in
//  WKWebView's website data store; this store keeps product-facing metadata.
//

import Foundation
import SwiftUI
import WebKit

@MainActor
final class KindleLibraryStore: ObservableObject {
    static let shared = KindleLibraryStore()

    @Published private(set) var books: [KindleBook] = []
    @Published private(set) var hasConnected = false
    @Published private(set) var accountLabel: String?
    @Published private(set) var accountEmail: String?
    @Published private(set) var listeningAnchors: [String: KindleListeningAnchor] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?

    private let booksKey = "kindle.library.books.v1"
    private let connectedKey = "kindle.library.connected.v1"
    private let accountLabelKey = "kindle.library.account.label.v1"
    private let accountEmailKey = "kindle.library.account.email.v1"
    private let listeningAnchorsKey = "kindle.listening.anchors.v1"

    private init() {
        load()
    }

    var homeBooks: [KindleBook] {
        Array(sortedBooks(sort: .recent, query: "").prefix(8))
    }

    var needsConnection: Bool {
        !hasConnected && books.isEmpty
    }

    var boundAccountDisplayName: String {
        if let email = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            return email
        }
        if let label = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return AppLocalized("Amazon Kindle 账号")
    }

    func sortedBooks(sort: KindleLibrarySort, query: String) -> [KindleBook] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = books.filter { book in
            guard !needle.isEmpty else { return true }
            return book.title.lowercased().contains(needle)
                || book.author.lowercased().contains(needle)
                || (book.asin ?? "").lowercased().contains(needle)
        }
        switch sort {
        case .recent:
            return filtered.sorted {
                ($0.lastOpenedAt ?? $0.lastSyncedAt) > ($1.lastOpenedAt ?? $1.lastSyncedAt)
            }
        case .title:
            return filtered.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .author:
            return filtered.sorted {
                $0.displayAuthor.localizedCaseInsensitiveCompare($1.displayAuthor) == .orderedAscending
            }
        }
    }

    func mergeScrapedBooks(_ scraped: [KindleBook], account: KindleAccountInfo? = nil) {
        let validBooks = sanitized(scraped)
        guard !validBooks.isEmpty else {
            lastError = AppLocalized("当前页面没有找到 Kindle 书籍。")
            if books.isEmpty {
                hasConnected = false
                save()
            }
            return
        }
        var existingByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        for var incoming in validBooks {
            incoming.lastSyncedAt = Date()
            if var old = existingByID[incoming.id] {
                old.title = incoming.title.isEmpty ? old.title : incoming.title
                old.author = incoming.author.isEmpty ? old.author : incoming.author
                old.coverURL = incoming.coverURL ?? old.coverURL
                old.readerURL = incoming.readerURL.isEmpty ? old.readerURL : incoming.readerURL
                old.progressLabel = incoming.progressLabel.isEmpty ? old.progressLabel : incoming.progressLabel
                if incoming.language != nil {
                    old.language = incoming.language
                    old.languageSource = incoming.languageSource
                    old.kindleWritingMode = incoming.kindleWritingMode
                    old.kindleReadingDirection = incoming.kindleReadingDirection
                    old.kindlePageProgressionDirection = incoming.kindlePageProgressionDirection
                }
                old.lastSyncedAt = incoming.lastSyncedAt
                existingByID[incoming.id] = old
            } else {
                existingByID[incoming.id] = incoming
            }
        }
        books = Array(existingByID.values).sorted {
            ($0.lastOpenedAt ?? $0.lastSyncedAt) > ($1.lastOpenedAt ?? $1.lastSyncedAt)
        }
        hasConnected = true
        if let account {
            setAccount(account)
        } else if accountLabel == nil && accountEmail == nil {
            accountLabel = AppLocalized("Amazon Kindle 账号")
        }
        lastError = nil
        save()
        // Sync is the moment we know the whole shelf; pull the covers now rather
        // than letting Home fetch them one at a time behind empty placeholders.
        ImageCache.shared.prefetch(books.compactMap(\.coverURL))
    }

    func markOpened(_ book: KindleBook) {
        update(bookID: book.id) { $0.lastOpenedAt = Date() }
    }

    func updateLanguageProfile(
        bookID: String,
        language: String,
        source: String,
        writingMode: KindleWritingMode = .horizontal,
        readingDirection: KindleReadingDirection? = nil,
        pageProgressionDirection: KindleReadingDirection? = nil
    ) {
        update(bookID: bookID) {
            $0.language = KindleLanguageContract.normalize(language)
            $0.languageSource = source
            $0.kindleWritingMode = writingMode.rawValue
            $0.kindleReadingDirection = readingDirection?.rawValue
            $0.kindlePageProgressionDirection = pageProgressionDirection?.rawValue
        }
    }

    func listeningAnchor(for bookID: String) -> KindleListeningAnchor? {
        listeningAnchors[bookID]
    }

    func hasListeningAnchor(for bookID: String) -> Bool {
        listeningAnchors[bookID] != nil
    }

    func saveListeningAnchor(_ anchor: KindleListeningAnchor) {
        listeningAnchors[anchor.bookId] = anchor
        save()
    }

    func removeListeningAnchor(for bookID: String) {
        guard listeningAnchors.removeValue(forKey: bookID) != nil else { return }
        save()
    }

    func updateProgress(bookID: String, pageKey: String?, url: String?, progressLabel: String? = nil) {
        update(bookID: bookID) { book in
            book.lastOpenedAt = Date()
            if let pageKey, !pageKey.isEmpty { book.lastReadPageKey = pageKey }
            if let url, !url.isEmpty { book.lastReadURL = url }
            if let progressLabel, !progressLabel.isEmpty { book.progressLabel = progressLabel }
        }
    }

    func disconnectLocalCache() {
        books.removeAll()
        hasConnected = false
        accountLabel = nil
        accountEmail = nil
        listeningAnchors.removeAll()
        lastError = nil
        save()
    }

    func disconnectAccount() async {
        disconnectLocalCache()
        await clearAmazonWebsiteData()
    }

    /// Amazon rejected the session and automatic recovery could not restore it,
    /// so the account has to be bound again. Unlike a user-initiated disconnect
    /// this keeps `listeningAnchors`: the shelf is re-scraped after rebinding and
    /// the anchors are keyed by book id, so reading positions survive a failure
    /// the user did not ask for.
    func markSessionExpiredForRebind() async {
        books.removeAll()
        hasConnected = false
        accountLabel = nil
        accountEmail = nil
        lastError = nil
        save()
        await clearAmazonWebsiteData()
    }

    func load() {
        let defaults = UserDefaults.standard
        hasConnected = defaults.bool(forKey: connectedKey)
        accountLabel = defaults.string(forKey: accountLabelKey)
        accountEmail = defaults.string(forKey: accountEmailKey)
        if let anchorData = defaults.data(forKey: listeningAnchorsKey),
           let decodedAnchors = try? JSONDecoder.kindle.decode([String: KindleListeningAnchor].self, from: anchorData) {
            listeningAnchors = decodedAnchors
        } else {
            listeningAnchors = [:]
        }
        guard let data = defaults.data(forKey: booksKey),
              let decoded = try? JSONDecoder.kindle.decode([KindleBook].self, from: data) else {
            books = []
            return
        }
        books = sanitized(decoded)
        if books.count != decoded.count || books.isEmpty {
            hasConnected = !books.isEmpty
            save()
        }
    }

    private func update(bookID: String, mutate: (inout KindleBook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        mutate(&books[index])
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(hasConnected, forKey: connectedKey)
        defaults.set(accountLabel, forKey: accountLabelKey)
        defaults.set(accountEmail, forKey: accountEmailKey)
        if let anchorData = try? JSONEncoder.kindle.encode(listeningAnchors) {
            defaults.set(anchorData, forKey: listeningAnchorsKey)
        }
        if let data = try? JSONEncoder.kindle.encode(books) {
            defaults.set(data, forKey: booksKey)
        }
    }

    private func sanitized(_ input: [KindleBook]) -> [KindleBook] {
        input.compactMap { raw in
            var book = raw
            guard book.isLikelyLibraryBook else { return nil }
            if let repaired = KindleBookValidator.repairedReaderURL(for: book, preferLastRead: false) {
                book.readerURL = repaired
            }
            if let repairedLastRead = KindleBookValidator.usableReaderURL(book.lastReadURL, fallbackASIN: book.asin ?? book.id) {
                book.lastReadURL = repairedLastRead
            } else {
                book.lastReadURL = nil
            }
            return book
        }
    }

    private func setAccount(_ account: KindleAccountInfo) {
        let label = account.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty {
            accountEmail = email
        }
        if let label, !label.isEmpty {
            accountLabel = label
        } else if accountLabel == nil {
            accountLabel = AppLocalized("Amazon Kindle 账号")
        }
    }

    private func clearAmazonWebsiteData() async {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: types) { records in
                let targets = records.filter { record in
                    let name = record.displayName.lowercased()
                    return name.contains("amazon") || name.contains("read.amazon")
                }
                guard !targets.isEmpty else {
                    continuation.resume()
                    return
                }
                dataStore.removeData(ofTypes: types, for: targets) {
                    continuation.resume()
                }
            }
        }
    }
}

struct KindleAccountInfo: Codable, Equatable {
    var label: String?
    var email: String?
}

private extension JSONEncoder {
    static var kindle: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var kindle: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
