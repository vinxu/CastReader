//
//  KoboLibraryStore.swift
//  CastReader
//
//  Kobo 书架的本地元数据缓存。绑定、书架和阅读器复用同一个持久 Web
//  profile，从而让 Kobo 的 Google 登录入口复用用户已经完成的 Google
//  网页登录。解绑 Kobo 只清 CastReader 的 Kobo 本地状态，不清网页 Cookie。
//

import Foundation
import WebKit

@MainActor
enum KoboWebSession {
    /// Product requirement: commercial reading platforms that offer Google
    /// sign-in share the same browser profile. Cookie domain isolation remains
    /// enforced by WebKit.
    static var websiteDataStore: WKWebsiteDataStore {
        GoogleWebSession.websiteDataStore
    }
}

@MainActor
final class KoboLibraryStore: ObservableObject {
    static let shared = KoboLibraryStore(
        defaults: .standard,
        historyStore: .shared,
        websiteDataStore: KoboWebSession.websiteDataStore,
        usesLegacyStorageWhenUnscoped: false
    )

    @Published private(set) var books: [KoboBook] = []
    @Published private(set) var hasConnected = false
    @Published private(set) var accountLabel: String?
    private(set) var accountIdentity: String?
    @Published private(set) var anchors: [String: KoboReadingAnchor] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?

    private enum Storage {
        static let books = "kobo.library.books.v1"
        static let connected = "kobo.library.connected.v1"
        static let account = "kobo.library.account.v1"
        static let accountIdentity = "kobo.library.accountIdentity.v1"
        static let anchors = "kobo.library.anchors.v1"
    }

    private let defaults: UserDefaults
    private let historyStore: HistoryStore
    private let sharedWebsiteDataStore: WKWebsiteDataStore
    private let usesLegacyStorageWhenUnscoped: Bool
    private var accountScope: AccountContentScope?
    private var isLegacyTestingScopeActive = false

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            historyStore: .shared,
            websiteDataStore: KoboWebSession.websiteDataStore
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
        websiteDataStore: WKWebsiteDataStore,
        usesLegacyStorageWhenUnscoped: Bool = true
    ) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.sharedWebsiteDataStore = websiteDataStore
        self.usesLegacyStorageWhenUnscoped = usesLegacyStorageWhenUnscoped
        if usesLegacyStorageWhenUnscoped {
            load()
        } else {
            resetInMemory()
        }
    }

    func activateAccountScope(_ scope: AccountContentScope) {
        guard accountScope != scope || !hasActiveStorage else { return }
        resetInMemory()
        isLegacyTestingScopeActive = false
        accountScope = scope
        load()
    }

    func deactivateAccountScope() {
        resetInMemory()
        isLegacyTestingScopeActive = false
        accountScope = nil
    }

#if DEBUG
    func activateLegacyTestingScope() {
        resetInMemory()
        accountScope = nil
        isLegacyTestingScopeActive = true
        load()
    }
#endif

    var needsConnection: Bool { !hasConnected && books.isEmpty }

    var homeBooks: [KoboBook] {
        Array(sortedBooks(sort: .recent, query: "").prefix(8))
    }

    func sortedBooks(sort: KoboLibrarySort, query: String) -> [KoboBook] {
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
                $0.displayAuthor.localizedCaseInsensitiveCompare($1.displayAuthor)
                    == .orderedAscending
            }
        }
    }

    /// Partial snapshots may add/update books but never remove existing ones.
    /// Only a complete, same-account shelf snapshot can remove missing books.
    func mergeScrapedBooks(
        _ incoming: [KoboBook],
        account: KoboAccountInfo?
    ) {
        let valid = incoming
            .map(KoboBookMetadata.normalized)
            .filter(KoboBookValidator.isLikelyLibraryBook)
        let hasTrustedShelfEvidence =
            account?.hasAccountEvidence == true
                && account?.isShelfContext == true
        let incomingIdentity = account?.identity.flatMap {
            KoboAccountIdentity.isValidStoredIdentity($0) ? $0 : nil
        }

        // Kobo reader links can also occur on public/store pages. Never let
        // those pages enter or mutate the bound account shelf.
        guard hasTrustedShelfEvidence, let incomingIdentity else {
            lastError = AppLocalized("请先登录 Kobo 并进入你的书架。")
            return
        }

        let completeSnapshot =
            account?.isCompleteSnapshot == true
                && valid.count == incoming.count

        // A non-empty scrape that becomes empty after validation is not a
        // trustworthy empty shelf.
        guard !valid.isEmpty || incoming.isEmpty && completeSnapshot else {
            lastError = AppLocalized("当前页面没有找到 Kobo 书架中的书籍。")
            return
        }

        let accountChanged: Bool = {
            if let accountIdentity {
                return accountIdentity != incomingIdentity
            }
            // A legacy cache without identity cannot be inherited by the first
            // newly proven account.
            return hasConnected || !books.isEmpty || !anchors.isEmpty
        }()
        if accountChanged {
            historyStore.deleteAll(sourceKind: .kobo)
            books = []
            anchors = [:]
            accountLabel = nil
        }
        accountIdentity = incomingIdentity

        let existing = books.reduce(into: [String: KoboBook]()) {
            result, book in
            result[book.id] = KoboBookMetadata.merged(
                existing: result[book.id],
                incoming: book
            )
        }

        let now = Date()
        var merged = completeSnapshot ? [:] : existing
        for var candidate in valid {
            guard let canonical = KoboBookValidator.usableReaderURL(
                candidate.readerURL
            ),
            let bookUUID = KoboBookValidator.bookUUID(from: canonical) else {
                continue
            }
            candidate.readerURL = canonical
            candidate.bookUUID = bookUUID
            candidate.lastSyncedAt = now

            if let old = existing[candidate.id] {
                var combined = KoboBookMetadata.merged(
                    existing: old,
                    incoming: candidate
                )
                combined.readerURL = canonical
                combined.bookUUID = bookUUID
                combined.lastSyncedAt = now
                merged[candidate.id] = combined
            } else {
                merged[candidate.id] = candidate
            }
        }

        if completeSnapshot {
            let retainedIDs = Set(merged.keys)
            anchors = anchors.filter { retainedIDs.contains($0.key) }
        }

        let wasConnected = hasConnected
        books = merged.values.sorted {
            ($0.lastOpenedAt ?? $0.lastSyncedAt)
                > ($1.lastOpenedAt ?? $1.lastSyncedAt)
        }
        hasConnected = true
        if let label = KoboAccountIdentity.safeDisplayLabel(account?.label),
           !label.isEmpty {
            accountLabel = label
        }
        lastError = nil
        save()
        if !wasConnected {
            NotificationCenter.default.post(
                name: .castReaderLibraryConnectedForReview,
                object: nil
            )
        }
        ImageCache.shared.prefetch(books.compactMap(\.coverURL))
    }

    func markOpened(_ book: KoboBook) {
        clearError()
        update(book.id) { $0.lastOpenedAt = Date() }
    }

    func book(for id: String) -> KoboBook? {
        books.first { $0.id == id }
    }

    func updateProgress(
        bookID: String,
        readerURL: String,
        fingerprint: String,
        progressLabel: String?
    ) {
        guard let book = book(for: bookID),
              !fingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              let usable = KoboBookValidator.usableResumeURL(
                  readerURL,
                  expecting: book.bookUUID
              ) else {
            return
        }

        anchors[bookID] = KoboReadingAnchor(
            bookID: bookID,
            readerURL: usable,
            pageFingerprint: fingerprint,
            progressLabel: progressLabel,
            updatedAt: Date()
        )
        update(bookID) { entry in
            entry.lastOpenedAt = Date()
            entry.lastReaderURL = usable
            if let progressLabel, !progressLabel.isEmpty {
                entry.progressLabel = progressLabel
            }
        }
        historyStore.updateSourceURL(documentID: bookID, sourceURL: usable)
        save()
    }

    func anchor(for bookID: String) -> KoboReadingAnchor? {
        anchors[bookID]
    }

    func localRecoveryURL(bookID: String, failedURL: String?) -> String? {
        guard let book = book(for: bookID) else { return nil }
        let canonical = book.readerURL
        guard let failedURL,
              failedURL != canonical,
              KoboBookValidator.usableReaderURL(canonical) != nil else {
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
        historyStore.deleteAll(sourceKind: .kobo)
        books = []
        anchors = [:]
        hasConnected = false
        accountLabel = nil
        accountIdentity = nil
        lastError = nil
        save()

        // Do not call removeData/removeAllCookies here. This profile is shared
        // with Google Play Books and future Google-backed platform logins.
        _ = sharedWebsiteDataStore
    }

    private func update(
        _ id: String,
        _ mutate: (inout KoboBook) -> Void
    ) {
        guard let index = books.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&books[index])
        save()
    }

    private func load() {
        resetInMemory()
        guard hasActiveStorage else { return }
        hasConnected = defaults.bool(forKey: storageKey(Storage.connected))
        accountLabel = defaults.string(forKey: storageKey(Storage.account))
        let storedIdentity = defaults.string(forKey: storageKey(Storage.accountIdentity))
        accountIdentity =
            KoboAccountIdentity.isValidStoredIdentity(storedIdentity)
                ? storedIdentity
                : nil

        var decodedBooks: [KoboBook] = []
        if let data = defaults.data(forKey: storageKey(Storage.books)),
           let decoded = try? JSONDecoder().decode(
               [KoboBook].self,
               from: data
           ) {
            decodedBooks = decoded
        }

        var sanitizedByID: [String: KoboBook] = [:]
        for var book in decodedBooks {
            book = KoboBookMetadata.normalized(book)
            guard let canonical = KoboBookValidator.usableReaderURL(
                book.readerURL
            ),
            let bookUUID = KoboBookValidator.bookUUID(from: canonical) else {
                continue
            }
            book.readerURL = canonical
            book.bookUUID = bookUUID
            book.lastReaderURL = KoboBookValidator.usableResumeURL(
                book.lastReaderURL,
                expecting: bookUUID
            )
            guard KoboBookValidator.isLikelyLibraryBook(book) else {
                continue
            }
            sanitizedByID[book.id] = KoboBookMetadata.merged(
                existing: sanitizedByID[book.id],
                incoming: book
            )
        }

        var sanitizedAnchors: [String: KoboReadingAnchor] = [:]
        if let data = defaults.data(forKey: storageKey(Storage.anchors)),
           let decoded = try? JSONDecoder().decode(
               [String: KoboReadingAnchor].self,
               from: data
           ) {
            for (key, var anchor) in decoded {
                guard anchor.bookID == key,
                      var book = sanitizedByID[key],
                      !anchor.pageFingerprint
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty,
                      let usable = KoboBookValidator.usableResumeURL(
                          anchor.readerURL,
                          expecting: book.bookUUID
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
        guard hasActiveStorage else { return }
        defaults.set(hasConnected, forKey: storageKey(Storage.connected))
        defaults.set(accountLabel, forKey: storageKey(Storage.account))
        defaults.set(accountIdentity, forKey: storageKey(Storage.accountIdentity))
        if let data = try? JSONEncoder().encode(books) {
            defaults.set(data, forKey: storageKey(Storage.books))
        }
        if let data = try? JSONEncoder().encode(anchors) {
            defaults.set(data, forKey: storageKey(Storage.anchors))
        }
    }

    private var hasActiveStorage: Bool {
        accountScope != nil || usesLegacyStorageWhenUnscoped || isLegacyTestingScopeActive
    }

    private func storageKey(_ legacyKey: String) -> String {
        accountScope?.storageKey(legacyKey) ?? legacyKey
    }

    private func resetInMemory() {
        books = []
        hasConnected = false
        accountLabel = nil
        accountIdentity = nil
        anchors = [:]
        isRefreshing = false
        lastError = nil
    }
}
