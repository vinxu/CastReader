//
//  GoogleBooksLibraryStore.swift
//  CastReader
//
//  Google Play 图书书架的本地元数据缓存。与 Kindle / 微信读书同一契约：
//  只存书名/作者/封面/阅读地址/本地进度，凭据只留在 WKWebView 的 website data store。
//

import Foundation
import WebKit

@MainActor
final class GoogleBooksLibraryStore: ObservableObject {
    static let shared = GoogleBooksLibraryStore()

    @Published private(set) var books: [GoogleBooksBook] = []
    @Published private(set) var hasConnected = false
    @Published private(set) var accountLabel: String?
    /// Hashed account identity used only to keep local shelves isolated.
    /// It must never be rendered as account UI.
    private(set) var accountIdentity: String?
    @Published private(set) var anchors: [String: GoogleBooksReadingAnchor] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?

    private let booksKey = "googlebooks.library.books.v1"
    private let connectedKey = "googlebooks.library.connected.v1"
    private let accountKey = "googlebooks.library.account.v1"
    private let accountIdentityKey = "googlebooks.library.accountIdentity.v1"
    private let anchorsKey = "googlebooks.library.anchors.v1"
    private let defaults: UserDefaults
    private let historyStore: HistoryStore
    /// Kept as an explicit dependency so the disconnect contract can verify
    /// that this shared Google browser profile survives a library disconnect.
    /// Only an independently named "Sign out of Google web session" action may
    /// ever erase it.
    private let sharedGoogleWebSessionDataStore: WKWebsiteDataStore

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            historyStore: .shared,
            websiteDataStore: GoogleWebSession.websiteDataStore
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

    /// Tests inject a non-persistent store to prove that disconnecting the
    /// library does not erase the shared Google browser session.
    init(
        defaults: UserDefaults,
        historyStore: HistoryStore,
        websiteDataStore: WKWebsiteDataStore
    ) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.sharedGoogleWebSessionDataStore = websiteDataStore
        load()
    }

    var needsConnection: Bool { !hasConnected && books.isEmpty }
    var homeBooks: [GoogleBooksBook] { Array(sortedBooks(sort: .recent, query: "").prefix(8)) }

    func sortedBooks(sort: GoogleBooksLibrarySort, query: String) -> [GoogleBooksBook] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = books.filter {
            needle.isEmpty
                || $0.title.lowercased().contains(needle)
                || $0.author.lowercased().contains(needle)
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

    func mergeScrapedBooks(_ incoming: [GoogleBooksBook], account: GoogleBooksAccountInfo? = nil) {
        let valid = incoming.filter(GoogleBooksBookValidator.isLikelyLibraryBook)
        let hasTrustedShelfEvidence =
            account?.hasAccountEvidence == true
                && account?.isShelfContext == true
        let incomingIdentity = account?.identity.flatMap {
            GoogleBooksAccountIdentity.isValidStoredIdentity($0) ? $0 : nil
        }
        let completeSnapshot =
            hasTrustedShelfEvidence
                && account?.isCompleteSnapshot == true
                && valid.count == incoming.count

        // A non-empty scrape that collapsed to zero valid books is not a
        // trustworthy empty shelf; never let it erase the prior snapshot.
        guard !valid.isEmpty || incoming.isEmpty && completeSnapshot else {
            lastError = AppLocalized("当前页面没有找到 Google Play 图书的书籍。")
            return
        }

        let accountChanged: Bool = {
            guard hasTrustedShelfEvidence, let incomingIdentity else { return false }
            if let accountIdentity { return accountIdentity != incomingIdentity }
            // Legacy caches did not persist an identity. Starting from a clean
            // snapshot prevents a newly selected account inheriting those books.
            return hasConnected || !books.isEmpty || !anchors.isEmpty
        }()
        if accountChanged {
            historyStore.deleteAll(sourceKind: .googleBooks)
            books = []
            anchors = [:]
            accountLabel = nil
        }
        if hasTrustedShelfEvidence, let incomingIdentity {
            accountIdentity = incomingIdentity
        }

        let now = Date()
        let existing = books.reduce(into: [String: GoogleBooksBook]()) { result, book in
            if let prior = result[book.id] {
                let priorDate = prior.lastOpenedAt ?? prior.lastSyncedAt
                let bookDate = book.lastOpenedAt ?? book.lastSyncedAt
                if bookDate > priorDate { result[book.id] = book }
            } else {
                result[book.id] = book
            }
        }
        var merged = completeSnapshot ? [:] : existing
        for var book in valid {
            guard let canonical = GoogleBooksBookValidator.usableReaderURL(book.readerURL),
                  let volumeID = GoogleBooksBookValidator.volumeID(from: canonical) else { continue }
            book.readerURL = canonical
            book.volumeID = volumeID
            book.lastSyncedAt = now
            if var old = existing[book.id] {
                old.title = book.title.isEmpty ? old.title : book.title
                old.author = book.author.isEmpty ? old.author : book.author
                old.coverURL = book.coverURL ?? old.coverURL
                old.readerURL = book.readerURL
                old.volumeID = volumeID
                old.progressLabel = book.progressLabel.isEmpty ? old.progressLabel : book.progressLabel
                old.lastSyncedAt = book.lastSyncedAt
                merged[book.id] = old
            } else {
                merged[book.id] = book
            }
        }

        if completeSnapshot {
            let retainedIDs = Set(merged.keys)
            anchors = anchors.filter { retainedIDs.contains($0.key) }
        }
        let wasConnected = hasConnected
        books = merged.values.sorted { ($0.lastOpenedAt ?? $0.lastSyncedAt) > ($1.lastOpenedAt ?? $1.lastSyncedAt) }
        hasConnected = true
        if let label = account?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
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
        // 与 Kindle/微信读书书架一致：同步时就把封面拉下来，首页不出现空占位。
        ImageCache.shared.prefetch(books.compactMap(\.coverURL))
    }

    func markOpened(_ book: GoogleBooksBook) {
        // A previous reader redirect must not poison the next explicit open.
        // If the session is still invalid, WebReaderBridge will report it again
        // after the new navigation finishes.
        clearError()
        update(book.id) { $0.lastOpenedAt = Date() }
    }

    func book(for id: String) -> GoogleBooksBook? { books.first { $0.id == id } }

    /// 记录续读位置。Play 图书是 SPA，翻页只改 URL 的 pg 参数，所以地址本身就是进度锚。
    func updateProgress(bookID: String, readerURL: String, fingerprint: String, progressLabel: String?) {
        guard let book = book(for: bookID) else { return }
        let expectedVolumeID =
            book.volumeID ?? GoogleBooksBookValidator.volumeID(from: book.readerURL)
        guard let usable = GoogleBooksBookValidator.usableResumeURL(
            readerURL,
            expecting: expectedVolumeID
        )
        else { return }
        anchors[bookID] = GoogleBooksReadingAnchor(
            bookID: bookID,
            readerURL: usable,
            pageFingerprint: fingerprint,
            progressLabel: progressLabel,
            updatedAt: Date()
        )
        update(bookID) { entry in
            entry.lastOpenedAt = Date()
            entry.lastReaderURL = usable
            if let progressLabel, !progressLabel.isEmpty { entry.progressLabel = progressLabel }
        }
        // PlayerCoordinator records the same stable Google book id in History.
        // Keep that URL aligned with the SPA's latest `pg` anchor so opening
        // from Library cannot jump back to the page captured at first launch.
        historyStore.updateSourceURL(documentID: bookID, sourceURL: usable)
        save()
    }

    func anchor(for bookID: String) -> GoogleBooksReadingAnchor? { anchors[bookID] }

    /// 续读地址打不开时可尝试规范入口。这个查询必须完全非破坏：
    /// 登录过期和临时重定向不能在规范入口真正成功前抹掉用户的 pg 锚点。
    func localRecoveryURL(bookID: String, failedURL: String?) -> String? {
        guard let book = book(for: bookID) else { return nil }
        let canonical = book.readerURL
        guard let failedURL, failedURL != canonical,
              GoogleBooksBookValidator.usableReaderURL(canonical) != nil else { return nil }
        return canonical
    }

    func reportError(_ message: String) { lastError = message }

    func clearError() { lastError = nil }

    func disconnectAccount() async {
        historyStore.deleteAll(sourceKind: .googleBooks)
        books = []
        anchors = [:]
        hasConnected = false
        accountLabel = nil
        accountIdentity = nil
        lastError = nil
        save()
        // Intentionally preserve sharedGoogleWebSessionDataStore. Unbinding
        // Google Play Books removes CastReader's local shelf association only;
        // keeping Google's web cookies lets this and future Google-backed
        // reading services offer a fast account confirmation next time.
        _ = sharedGoogleWebSessionDataStore
    }

    private func update(_ id: String, _ mutate: (inout GoogleBooksBook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        mutate(&books[index])
        save()
    }

    private func load() {
        hasConnected = defaults.bool(forKey: connectedKey)
        accountLabel = defaults.string(forKey: accountKey)
        let storedIdentity = defaults.string(forKey: accountIdentityKey)
        accountIdentity = GoogleBooksAccountIdentity.isValidStoredIdentity(storedIdentity)
            ? storedIdentity
            : nil

        var decodedBooks: [GoogleBooksBook] = []
        if let data = defaults.data(forKey: booksKey),
           let decoded = try? JSONDecoder().decode([GoogleBooksBook].self, from: data) {
            decodedBooks = decoded
        }
        var sanitizedByID: [String: GoogleBooksBook] = [:]
        for var book in decodedBooks {
            guard let canonical = GoogleBooksBookValidator.usableReaderURL(book.readerURL),
                  let volumeID = GoogleBooksBookValidator.volumeID(from: canonical) else { continue }
            book.readerURL = canonical
            book.volumeID = volumeID
            book.lastReaderURL = GoogleBooksBookValidator.usableResumeURL(
                book.lastReaderURL,
                expecting: volumeID
            )
            guard GoogleBooksBookValidator.isLikelyLibraryBook(book) else { continue }
            if let old = sanitizedByID[book.id] {
                let oldDate = old.lastOpenedAt ?? old.lastSyncedAt
                let candidateDate = book.lastOpenedAt ?? book.lastSyncedAt
                if candidateDate > oldDate { sanitizedByID[book.id] = book }
            } else {
                sanitizedByID[book.id] = book
            }
        }

        var sanitizedAnchors: [String: GoogleBooksReadingAnchor] = [:]
        if let data = defaults.data(forKey: anchorsKey),
           let decoded = try? JSONDecoder().decode([String: GoogleBooksReadingAnchor].self, from: data) {
            for (key, var anchor) in decoded {
                guard anchor.bookID == key,
                      var book = sanitizedByID[key],
                      let usable = GoogleBooksBookValidator.usableResumeURL(
                          anchor.readerURL,
                          expecting: book.volumeID
                      ) else { continue }
                anchor.readerURL = usable
                sanitizedAnchors[key] = anchor
                if book.lastReaderURL == nil {
                    book.lastReaderURL = usable
                    sanitizedByID[key] = book
                }
            }
        }
        books = sanitizedByID.values.sorted {
            ($0.lastOpenedAt ?? $0.lastSyncedAt) > ($1.lastOpenedAt ?? $1.lastSyncedAt)
        }
        anchors = sanitizedAnchors
        // Persist the cleaned migration so an invalid legacy URL cannot return
        // on the next launch.
        save()
    }

    private func save() {
        defaults.set(hasConnected, forKey: connectedKey)
        defaults.set(accountLabel, forKey: accountKey)
        defaults.set(accountIdentity, forKey: accountIdentityKey)
        if let data = try? JSONEncoder().encode(books) { defaults.set(data, forKey: booksKey) }
        if let data = try? JSONEncoder().encode(anchors) { defaults.set(data, forKey: anchorsKey) }
    }
}
