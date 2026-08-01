//
//  OReillyLibraryStore.swift
//  CastReader
//
//  O'Reilly 书架元数据和视觉页锚点的本地缓存。网页凭据只存在
//  CommercialWebSession 的持久 WKWebsiteDataStore；解绑不会清 Cookie。
//

import Foundation
import WebKit

enum OReillyWebSession {
    static var websiteDataStore: WKWebsiteDataStore {
        CommercialWebSession.websiteDataStore
    }
}

@MainActor
final class OReillyLibraryStore: ObservableObject {
    static let shared = OReillyLibraryStore()

    @Published private(set) var books: [OReillyBook] = []
    @Published private(set) var hasConnected = false
    @Published private(set) var accountLabel: String?
    private(set) var accountIdentity: String?
    @Published private(set) var anchors: [String: OReillyReadingAnchor] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?

    private let booksKey = "oreilly.library.books.v1"
    private let connectedKey = "oreilly.library.connected.v1"
    private let accountKey = "oreilly.library.account.v1"
    private let accountIdentityKey = "oreilly.library.accountIdentity.v1"
    private let anchorsKey = "oreilly.library.anchors.v1"
    private let defaults: UserDefaults
    private let historyStore: HistoryStore
    private let sharedWebsiteDataStore: WKWebsiteDataStore

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            historyStore: .shared,
            websiteDataStore: OReillyWebSession.websiteDataStore
        )
    }

    convenience init(
        defaults: UserDefaults,
        historyStore: HistoryStore
    ) {
        self.init(
            defaults: defaults,
            historyStore: historyStore,
            websiteDataStore: .nonPersistent()
        )
    }

    init(
        defaults: UserDefaults,
        historyStore: HistoryStore,
        websiteDataStore: WKWebsiteDataStore
    ) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.sharedWebsiteDataStore = websiteDataStore
        load()
    }

    var needsConnection: Bool { !hasConnected && books.isEmpty }

    var homeBooks: [OReillyBook] {
        Array(sortedBooks(sort: .recent, query: "").prefix(8))
    }

    func sortedBooks(
        sort: OReillyLibrarySort,
        query: String
    ) -> [OReillyBook] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let filtered = books.filter {
            needle.isEmpty
                || $0.title.lowercased().contains(needle)
                || $0.author.lowercased().contains(needle)
        }
        switch sort {
        case .recent:
            return filtered.sorted {
                ($0.lastOpenedAt ?? $0.lastSyncedAt)
                    > ($1.lastOpenedAt ?? $1.lastSyncedAt)
            }
        case .title:
            return filtered.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            }
        case .author:
            return filtered.sorted {
                $0.displayAuthor.localizedCaseInsensitiveCompare(
                    $1.displayAuthor
                ) == .orderedAscending
            }
        }
    }

    /// Partial snapshots may add/update but never remove. Deletion is allowed
    /// only for a complete trusted snapshot of the already-bound account.
    func mergeScrapedBooks(
        _ incoming: [OReillyBook],
        account: OReillyAccountInfo?
    ) {
        let valid = incoming
            .map(OReillyBookMetadata.normalized)
            .filter(OReillyBookValidator.isLikelyLibraryBook)
        let hasTrustedShelfEvidence =
            account?.hasAccountEvidence == true
                && account?.isShelfContext == true
        let incomingIdentity = account?.identity.flatMap {
            OReillyAccountIdentity.isValidStoredIdentity($0) ? $0 : nil
        }

        guard hasTrustedShelfEvidence, let incomingIdentity else {
            lastError = AppLocalized(
                "请先登录 O’Reilly 并进入你的阅读历史。"
            )
            return
        }

        let completeSnapshot =
            account?.isCompleteSnapshot == true
                && valid.count == incoming.count
        guard !valid.isEmpty || incoming.isEmpty && completeSnapshot else {
            lastError = AppLocalized(
                "当前页面没有找到 O’Reilly 阅读历史中的书籍。"
            )
            return
        }

        let accountChanged: Bool = {
            if let accountIdentity {
                return accountIdentity != incomingIdentity
            }
            return hasConnected || !books.isEmpty || !anchors.isEmpty
        }()
        if accountChanged {
            historyStore.deleteAll(sourceKind: .oreilly)
            books = []
            anchors = [:]
            accountLabel = nil
        }
        accountIdentity = incomingIdentity

        let existing = books.reduce(into: [String: OReillyBook]()) {
            result, book in
            result[book.id] = OReillyBookMetadata.merged(
                existing: result[book.id],
                incoming: book
            )
        }

        // A complete snapshot can prune only when the account identity already
        // matched. An account transition is isolated above and starts fresh.
        var merged: [String: OReillyBook] =
            completeSnapshot && !accountChanged ? [:] : existing
        let now = Date()
        for var candidate in valid {
            guard let readerURL = OReillyBookValidator.usableReaderURL(
                candidate.readerURL,
                trustedHost: candidate.readerHost
            ),
            let contentID = OReillyBookValidator.contentID(from: readerURL),
            candidate.id
                == OReillyBookValidator.stableID(contentID: contentID) else {
                continue
            }
            candidate.readerURL = readerURL
            candidate.contentID = contentID
            candidate.readerHost =
                URL(string: readerURL)?.host?.lowercased()
                    ?? candidate.readerHost.lowercased()
            candidate.lastReaderURL =
                OReillyBookValidator.usableResumeURL(
                    candidate.lastReaderURL,
                    expecting: contentID,
                    trustedHost: candidate.readerHost
                )
            candidate.lastSyncedAt = now

            if let old = existing[candidate.id] {
                var combined = OReillyBookMetadata.merged(
                    existing: old,
                    incoming: candidate
                )
                combined.readerURL = readerURL
                combined.contentID = contentID
                combined.readerHost = candidate.readerHost
                combined.lastSyncedAt = now
                merged[candidate.id] = combined
            } else {
                merged[candidate.id] = candidate
            }
        }

        if completeSnapshot && !accountChanged {
            let retainedIDs = Set(merged.keys)
            anchors = anchors.filter { retainedIDs.contains($0.key) }
        }

        books = merged.values.sorted {
            ($0.lastOpenedAt ?? $0.lastSyncedAt)
                > ($1.lastOpenedAt ?? $1.lastSyncedAt)
        }
        hasConnected = true
        if let label = OReillyAccountIdentity.safeDisplayLabel(account?.label),
           !label.isEmpty {
            accountLabel = label
        }
        lastError = nil
        save()
        ImageCache.shared.prefetch(books.compactMap(\.coverURL))
    }

    func markOpened(_ book: OReillyBook) {
        clearError()
        update(book.id) { $0.lastOpenedAt = Date() }
    }

    func book(for id: String) -> OReillyBook? {
        books.first { $0.id == id }
    }

    func updateProgress(
        bookID: String,
        readerURL: String,
        fingerprint: String,
        progressLabel: String?,
        scrollOffset: Double? = nil,
        scrollMaximum: Double? = nil,
        scrollRatio: Double? = nil,
        sourceParagraphIndex: Int? = nil,
        sourceUTF16Start: Int? = nil,
        sourceUTF16End: Int? = nil
    ) {
        guard let book = book(for: bookID),
              !fingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              let usable = OReillyBookValidator.usableResumeURL(
                  readerURL,
                  expecting: book.contentID,
                  trustedHost: book.readerHost
              ) else {
            return
        }
        let safeSourceStart = sourceUTF16Start.flatMap {
            $0 >= 0 ? $0 : nil
        }
        let safeSourceEnd: Int? = sourceUTF16End.flatMap { value -> Int? in
            guard value >= 0, value >= (safeSourceStart ?? 0) else {
                return nil
            }
            return value
        }
        anchors[bookID] = OReillyReadingAnchor(
            bookID: bookID,
            readerURL: usable,
            pageFingerprint: fingerprint,
            progressLabel: progressLabel,
            scrollOffset: Self.nonnegativeFinite(scrollOffset),
            scrollMaximum: Self.nonnegativeFinite(scrollMaximum),
            scrollRatio: Self.unitFinite(scrollRatio),
            sourceParagraphIndex: sourceParagraphIndex.flatMap {
                $0 >= 0 ? $0 : nil
            },
            sourceUTF16Start: safeSourceStart,
            sourceUTF16End: safeSourceEnd,
            updatedAt: Date()
        )
        update(bookID) { entry in
            entry.lastOpenedAt = Date()
            entry.lastReaderURL = usable
            if let progressLabel,
               !progressLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
                entry.progressLabel = progressLabel
            }
        }
        historyStore.updateSourceURL(documentID: bookID, sourceURL: usable)
        save()
    }

    func anchor(for bookID: String) -> OReillyReadingAnchor? {
        anchors[bookID]
    }

    func localRecoveryURL(
        bookID: String,
        failedURL: String?
    ) -> String? {
        guard let book = book(for: bookID),
              let canonical = OReillyBookValidator.usableReaderURL(
                  book.readerURL,
                  trustedHost: book.readerHost
              ),
              failedURL != canonical else {
            return nil
        }
        return canonical
    }

    func canonicalReaderURL(for bookID: String) -> String? {
        book(for: bookID)?.readerURL
    }

    func reportError(_ message: String) {
        lastError = message
    }

    func clearError() {
        lastError = nil
    }

    func disconnectAccount() async {
        historyStore.deleteAll(sourceKind: .oreilly)
        books = []
        anchors = [:]
        hasConnected = false
        accountLabel = nil
        accountIdentity = nil
        lastError = nil
        save()

        // Never call removeData/removeAllCookies: all commercial integrations
        // deliberately share this persistent WebKit profile.
        _ = sharedWebsiteDataStore
    }

    private func update(
        _ id: String,
        _ mutate: (inout OReillyBook) -> Void
    ) {
        guard let index = books.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&books[index])
        save()
    }

    private func load() {
        hasConnected = defaults.bool(forKey: connectedKey)
        accountLabel = defaults.string(forKey: accountKey)
        let storedIdentity = defaults.string(forKey: accountIdentityKey)
        accountIdentity =
            OReillyAccountIdentity.isValidStoredIdentity(storedIdentity)
                ? storedIdentity
                : nil
        if accountIdentity == nil {
            // O'Reilly has no legacy local shelf format. Metadata without a
            // proven hashed owner must not reappear as another account's shelf.
            hasConnected = false
            accountLabel = nil
        }

        var decodedBooks: [OReillyBook] = []
        if accountIdentity != nil,
           let data = defaults.data(forKey: booksKey),
           let decoded = try? JSONDecoder().decode(
               [OReillyBook].self,
               from: data
           ) {
            decodedBooks = decoded
        }

        var sanitizedByID: [String: OReillyBook] = [:]
        for var book in decodedBooks {
            book = OReillyBookMetadata.normalized(book)
            guard let readerURL = OReillyBookValidator.usableReaderURL(
                book.readerURL,
                trustedHost: book.readerHost
            ),
            let contentID = OReillyBookValidator.contentID(from: readerURL)
            else {
                continue
            }
            book.readerURL = readerURL
            book.contentID = contentID
            book.readerHost =
                URL(string: readerURL)?.host?.lowercased() ?? ""
            book.lastReaderURL = OReillyBookValidator.usableResumeURL(
                book.lastReaderURL,
                expecting: contentID,
                trustedHost: book.readerHost
            )
            guard OReillyBookValidator.isLikelyLibraryBook(book) else {
                continue
            }
            sanitizedByID[book.id] = OReillyBookMetadata.merged(
                existing: sanitizedByID[book.id],
                incoming: book
            )
        }

        var sanitizedAnchors: [String: OReillyReadingAnchor] = [:]
        if let data = defaults.data(forKey: anchorsKey),
           let decoded = try? JSONDecoder().decode(
               [String: OReillyReadingAnchor].self,
               from: data
           ) {
            for (key, var anchor) in decoded {
                guard anchor.bookID == key,
                      var book = sanitizedByID[key],
                      !anchor.pageFingerprint
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty,
                      let usable = OReillyBookValidator.usableResumeURL(
                          anchor.readerURL,
                          expecting: book.contentID,
                          trustedHost: book.readerHost
                      ) else {
                    continue
                }
                anchor.readerURL = usable
                sanitizedAnchors[key] = anchor
                if book.lastReaderURL == nil {
                    book.lastReaderURL = usable
                    sanitizedByID[key] = book
                }
            }
        }

        books = sanitizedByID.values.sorted {
            ($0.lastOpenedAt ?? $0.lastSyncedAt)
                > ($1.lastOpenedAt ?? $1.lastSyncedAt)
        }
        anchors = sanitizedAnchors
        save()
    }

    private func save() {
        defaults.set(hasConnected, forKey: connectedKey)
        defaults.set(accountLabel, forKey: accountKey)
        defaults.set(accountIdentity, forKey: accountIdentityKey)
        if let data = try? JSONEncoder().encode(books) {
            defaults.set(data, forKey: booksKey)
        }
        if let data = try? JSONEncoder().encode(anchors) {
            defaults.set(data, forKey: anchorsKey)
        }
    }

    private nonisolated static func nonnegativeFinite(
        _ value: Double?
    ) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private nonisolated static func unitFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else {
            return nil
        }
        return value
    }
}
