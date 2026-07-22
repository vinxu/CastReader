//
//  WeReadLibraryStore.swift
//  CastReader
//

import Foundation
import WebKit

@MainActor
final class WeReadLibraryStore: ObservableObject {
    static let shared = WeReadLibraryStore()

    @Published private(set) var books: [WeReadBook] = []
    @Published private(set) var hasConnected = false
    @Published private(set) var accountLabel: String?
    @Published private(set) var anchors: [String: WeReadReadingAnchor] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?

    private let booksKey = "weread.library.books.v1"
    private let connectedKey = "weread.library.connected.v1"
    private let accountKey = "weread.library.account.v1"
    private let anchorsKey = "weread.library.anchors.v1"

    private init() { load() }

    var needsConnection: Bool { !hasConnected && books.isEmpty }
    var homeBooks: [WeReadBook] { Array(sortedBooks(sort: .recent, query: "").prefix(8)) }

    func sortedBooks(sort: WeReadLibrarySort, query: String) -> [WeReadBook] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = books.filter {
            needle.isEmpty || $0.title.lowercased().contains(needle) || $0.author.lowercased().contains(needle)
        }
        switch sort {
        case .recent:
            return filtered.sorted { ($0.lastOpenedAt ?? $0.lastSyncedAt) > ($1.lastOpenedAt ?? $1.lastSyncedAt) }
        case .title:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:
            return filtered.sorted { $0.displayAuthor.localizedCaseInsensitiveCompare($1.displayAuthor) == .orderedAscending }
        }
    }

    func mergeScrapedBooks(_ incoming: [WeReadBook], account: WeReadAccountInfo? = nil) {
        let valid = incoming.filter(WeReadBookValidator.isLikelyLibraryBook)
        guard !valid.isEmpty else {
            lastError = AppLocalized("当前页面没有找到微信读书书籍。")
            return
        }
        var merged = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        for var book in valid {
            book.lastSyncedAt = Date()
            if var old = merged[book.id] {
                let oldCanonicalURL = old.readerURL
                let canonicalChanged = oldCanonicalURL != book.readerURL
                old.title = book.title.isEmpty ? old.title : book.title
                old.author = book.author.isEmpty ? old.author : book.author
                old.coverURL = book.coverURL ?? old.coverURL
                old.readerURL = book.readerURL
                old.progressLabel = book.progressLabel.isEmpty ? old.progressLabel : book.progressLabel
                old.lastSyncedAt = book.lastSyncedAt
                if canonicalChanged,
                   WeReadBookEntryRecoveryContract.shouldDiscardResumeURL(
                    oldCanonicalURL: oldCanonicalURL,
                    newCanonicalURL: book.readerURL,
                    resumeURL: old.lastReaderURL
                   ) {
                    old.lastReaderURL = nil
                    old.lastPageFingerprint = nil
                    anchors.removeValue(forKey: book.id)
                }
                merged[book.id] = old
            } else {
                merged[book.id] = book
            }
        }
        books = merged.values.sorted { ($0.lastOpenedAt ?? $0.lastSyncedAt) > ($1.lastOpenedAt ?? $1.lastSyncedAt) }
        hasConnected = true
        if let label = account?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { accountLabel = label }
        // Keep only server/user data in persistence. The view supplies the
        // localized fallback so changing CastReader language updates instantly.
        lastError = nil
        save()
    }

    func markOpened(_ book: WeReadBook) { update(book.id) { $0.lastOpenedAt = Date() } }

    func updateProgress(bookID: String, readerURL: String, fingerprint: String, progressLabel: String?) {
        guard WeReadBookValidator.usableReaderURL(readerURL) != nil else { return }
        anchors[bookID] = WeReadReadingAnchor(bookID: bookID, readerURL: readerURL, pageFingerprint: fingerprint, progressLabel: progressLabel, updatedAt: Date())
        update(bookID) { book in
            book.lastOpenedAt = Date()
            book.lastReaderURL = readerURL
            book.lastPageFingerprint = fingerprint
            if let progressLabel, !progressLabel.isEmpty { book.progressLabel = progressLabel }
        }
        save()
    }

    func anchor(for bookID: String) -> WeReadReadingAnchor? { anchors[bookID] }

    func book(for id: String) -> WeReadBook? {
        books.first { $0.id == id }
    }

    /// Clear a failed local resume URL and return the distinct canonical shelf
    /// entry for one cheap retry. Returning nil tells the reader to perform the
    /// one-shot authenticated shelf recovery instead.
    func localRecoveryURL(bookID: String, failedURL: String?) -> String? {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return nil }
        let book = books[index]
        guard let fallback = WeReadBookEntryRecoveryContract.localFallbackURL(
            failedURL: failedURL,
            canonicalURL: book.readerURL,
            resumeURL: book.lastReaderURL
        ) else { return nil }
        books[index].lastReaderURL = nil
        books[index].lastPageFingerprint = nil
        anchors.removeValue(forKey: bookID)
        save()
        return fallback
    }

    /// Install the server-authored entry found by a recovery shelf scan. Reader
    /// progress is cleared because the failed URL/fingerprint can no longer be
    /// trusted; WeRead's own account session remains the progress authority.
    func installRecoveredEntry(_ incoming: WeReadBook, for bookID: String) -> String? {
        guard let readerURL = WeReadBookValidator.usableReaderURL(incoming.readerURL),
              let index = books.firstIndex(where: { $0.id == bookID }) else { return nil }
        books[index].title = incoming.title.isEmpty ? books[index].title : incoming.title
        books[index].author = incoming.author.isEmpty ? books[index].author : incoming.author
        books[index].coverURL = incoming.coverURL ?? books[index].coverURL
        books[index].readerURL = readerURL
        books[index].progressLabel = incoming.progressLabel.isEmpty ? books[index].progressLabel : incoming.progressLabel
        books[index].lastSyncedAt = Date()
        books[index].lastReaderURL = nil
        books[index].lastPageFingerprint = nil
        anchors.removeValue(forKey: bookID)
        lastError = nil
        save()
        return readerURL
    }

    func reportRecoveryError(_ message: String) {
        lastError = message
    }

    func disconnectAccount() async {
        books = []; anchors = [:]; hasConnected = false; accountLabel = nil; lastError = nil; save()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { records in
                let targets = records.filter { $0.displayName.lowercased().contains("weread") || $0.displayName.lowercased().contains("qq.com") }
                guard !targets.isEmpty else { continuation.resume(); return }
                WKWebsiteDataStore.default().removeData(ofTypes: types, for: targets) { continuation.resume() }
            }
        }
    }

    private func update(_ id: String, _ mutate: (inout WeReadBook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        mutate(&books[index]); save()
    }

    private func load() {
        let d = UserDefaults.standard
        hasConnected = d.bool(forKey: connectedKey)
        accountLabel = d.string(forKey: accountKey)
        let legacyAccountFallbacks: Set<String> = [
            "WeRead account", "微信读书账号", "WeRead アカウント", "Cuenta de WeRead",
            "Compte WeRead", "Conta do WeRead", "Account WeRead", "WeRead खाता",
        ]
        if let accountLabel, legacyAccountFallbacks.contains(accountLabel) {
            self.accountLabel = nil
            d.removeObject(forKey: accountKey)
        }
        if let data = d.data(forKey: booksKey), let decoded = try? JSONDecoder().decode([WeReadBook].self, from: data) {
            books = decoded.filter(WeReadBookValidator.isLikelyLibraryBook)
        }
        if let data = d.data(forKey: anchorsKey), let decoded = try? JSONDecoder().decode([String: WeReadReadingAnchor].self, from: data) { anchors = decoded }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(hasConnected, forKey: connectedKey)
        d.set(accountLabel, forKey: accountKey)
        if let data = try? JSONEncoder().encode(books) { d.set(data, forKey: booksKey) }
        if let data = try? JSONEncoder().encode(anchors) { d.set(data, forKey: anchorsKey) }
    }
}
