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
    @Published private(set) var boundStorefrontID = KindleStorefront.us.id
    @Published private(set) var listeningAnchors: [String: KindleListeningAnchor] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?

    private enum Storage {
        static let books = "kindle.library.books.v1"
        static let connected = "kindle.library.connected.v1"
        static let accountLabel = "kindle.library.account.label.v1"
        static let accountEmail = "kindle.library.account.email.v1"
        static let listeningAnchors = "kindle.listening.anchors.v1"
        static let boundStorefront = "kindle.library.bound-storefront.v1"
        static let authoritativeStorefront = "kindle.library.bound-storefront-authoritative.v1"
    }

    private let defaults: UserDefaults
    /// The production singleton must remain empty until AuthService selects an
    /// account. Injected instances keep the legacy keys for contract tests and
    /// migration tooling that deliberately construct a device-global store.
    private let usesLegacyStorageWhenUnscoped: Bool
    private var accountScope: AccountContentScope?
    private var isLegacyTestingScopeActive = false
    private var hasAuthoritativeStorefrontBinding = false

    private init() {
        defaults = .standard
        usesLegacyStorageWhenUnscoped = false
        resetInMemory()
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        usesLegacyStorageWhenUnscoped = true
        load()
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
    /// UI tests intentionally seed the pre-account UserDefaults keys. Production
    /// code has no way to activate this compatibility path.
    func activateLegacyTestingScope() {
        resetInMemory()
        accountScope = nil
        isLegacyTestingScopeActive = true
        load()
    }
#endif

    var homeBooks: [KindleBook] {
        Array(sortedBooks(sort: .recent, query: "").prefix(8))
    }

    /// P0/P1 has exactly one active marketplace. Keep every product-facing
    /// count and state on this projection so legacy mixed caches cannot make an
    /// empty current site look populated.
    var boundBooks: [KindleBook] {
        books.filter { $0.storefrontID == boundStorefrontID }
    }

    var boundStorefront: KindleStorefront {
        KindleStorefront.entry(id: boundStorefrontID) ?? .us
    }

    var orderedStorefrontCandidates: [KindleStorefront] {
        let selected = AppLanguageManager.shared.selectedLanguage
        let language = selected == .system
            ? Locale.autoupdatingCurrent.language.languageCode?.identifier
            : selected.rawValue
        let context = KindleStorefrontRecommendationContext(
            locale: .autoupdatingCurrent,
            preferredLanguages: Locale.preferredLanguages,
            appLanguageCode: language,
            timeZone: .autoupdatingCurrent
        )
        return KindleStorefrontRecommender.recommend(
            context: context,
            authoritativeBoundStorefrontID: hasAuthoritativeStorefrontBinding
                || hasConnected
                || !boundBooks.isEmpty
                ? boundStorefrontID
                : nil
        ).candidates
    }

    var needsConnection: Bool {
        !hasConnected && boundBooks.isEmpty
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
            guard book.storefrontID == boundStorefrontID else { return false }
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
        // The observed reader host is the ingress authority. Check it before
        // `sanitized` repairs stale URLs, otherwise an incorrectly declared ES
        // book carrying a US URL could be rewritten to ES and admitted.
        let attributed = scraped.compactMap { raw -> KindleBook? in
            var book = raw
            guard Self.isScrapedBook(
                book,
                compatibleWith: boundStorefrontID
            ) else { return nil }
            book.storefrontID = boundStorefrontID
            return book
        }
        let validBooks = sanitized(attributed).filter {
            $0.storefrontID == boundStorefrontID
        }
        guard !validBooks.isEmpty else {
            lastError = AppLocalized("当前页面没有找到 Kindle 书籍。")
            save()
            return
        }
        var existingByID = Dictionary(uniqueKeysWithValues: boundBooks.map { ($0.id, $0) })
        for var incoming in validBooks {
            incoming.lastSyncedAt = Date()
            if var old = existingByID[incoming.id] {
                old.title = incoming.title.isEmpty ? old.title : incoming.title
                old.author = incoming.author.isEmpty ? old.author : incoming.author
                old.coverURL = incoming.coverURL ?? old.coverURL
                old.readerURL = incoming.readerURL.isEmpty ? old.readerURL : incoming.readerURL
                old.progressLabel = incoming.progressLabel.isEmpty ? old.progressLabel : incoming.progressLabel
                old.storefrontID = incoming.storefrontID ?? old.storefrontID
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
        let wasConnected = hasConnected
        books = Array(existingByID.values).sorted {
            ($0.lastOpenedAt ?? $0.lastSyncedAt) > ($1.lastOpenedAt ?? $1.lastSyncedAt)
        }
        hasConnected = true
        hasAuthoritativeStorefrontBinding = true
        if let account {
            setAccount(account)
        } else if accountLabel == nil && accountEmail == nil {
            accountLabel = AppLocalized("Amazon Kindle 账号")
        }
        lastError = nil
        save()
        if !wasConnected {
            NotificationCenter.default.post(
                name: .castReaderLibraryConnectedForReview,
                object: nil
            )
        }
        // Sync is the moment we know the whole shelf; pull the covers now rather
        // than letting Home fetch them one at a time behind empty placeholders.
        ImageCache.shared.prefetch(books.compactMap(\.coverURL))
    }

    nonisolated static func isScrapedBook(
        _ book: KindleBook,
        compatibleWith boundStorefrontID: String
    ) -> Bool {
        let observedStorefrontID = KindleStorefront.entry(
            url: URL(string: book.readerURL)
        )?.id
        let declaredStorefrontID = KindleStorefront.entry(
            id: book.storefrontID
        )?.id
        return (observedStorefrontID
            ?? declaredStorefrontID
            ?? boundStorefrontID) == boundStorefrontID
    }

    /// A zero-book shelf is still a successfully connected Amazon account.
    /// Keeping this state distinct from "not signed in" lets Home surface the
    /// storefront recovery path instead of sending the user through login again.
    func markConnectedWithEmptyShelf(account: KindleAccountInfo? = nil) {
        let wasConnected = hasConnected
        books.removeAll()
        hasConnected = true
        hasAuthoritativeStorefrontBinding = true
        if let account {
            setAccount(account)
        } else if accountLabel == nil && accountEmail == nil {
            accountLabel = AppLocalized("Amazon Kindle 账号")
        }
        lastError = nil
        save()
        if !wasConnected {
            NotificationCenter.default.post(
                name: .castReaderLibraryConnectedForReview,
                object: nil
            )
        }
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

    /// Selecting another marketplace starts a fresh shelf binding but preserves
    /// cookies for every marketplace and keeps listening anchors. Amazon
    /// sessions are domain-isolated and may legitimately coexist.
    func switchStorefront(to storefrontID: String, resetShelf: Bool = true) {
        guard let storefront = KindleStorefront.storefront(id: storefrontID),
              storefront.isSelectable else { return }
        hasAuthoritativeStorefrontBinding = true
        guard storefront.id != boundStorefrontID else {
            save()
            return
        }
        boundStorefrontID = storefront.id
        if resetShelf {
            books.removeAll()
            hasConnected = false
            accountLabel = nil
            accountEmail = nil
            lastError = nil
        }
        save()
        KindleRunLog.write("KINDLE storefront selected id=\(storefront.id) rebind=\(resetShelf ? "Y" : "N")")
    }

    func disconnectLocalCache() {
        books.removeAll()
        hasConnected = false
        hasAuthoritativeStorefrontBinding = false
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
        let expiredStorefront = boundStorefront
        books.removeAll()
        hasConnected = false
        accountLabel = nil
        accountEmail = nil
        lastError = nil
        save()
        await clearAmazonWebsiteData(for: expiredStorefront)
    }

    func load() {
        resetInMemory()
        guard hasActiveStorage else { return }
        let hasPersistedConnectionState = defaults.object(
            forKey: storageKey(Storage.connected)
        ) != nil
        hasConnected = defaults.bool(forKey: storageKey(Storage.connected))
        accountLabel = defaults.string(forKey: storageKey(Storage.accountLabel))
        accountEmail = defaults.string(forKey: storageKey(Storage.accountEmail))
        if let anchorData = defaults.data(forKey: storageKey(Storage.listeningAnchors)),
           let decodedAnchors = try? JSONDecoder.kindle.decode([String: KindleListeningAnchor].self, from: anchorData) {
            listeningAnchors = decodedAnchors
        }
        let decoded: [KindleBook]
        if let data = defaults.data(forKey: storageKey(Storage.books)),
           let restored = try? JSONDecoder.kindle.decode([KindleBook].self, from: data) {
            decoded = restored
        } else {
            decoded = []
        }

        let persisted = defaults.string(forKey: storageKey(Storage.boundStorefront))
            .flatMap { KindleStorefront.storefront(id: $0) }
            .flatMap { $0.isSelectable ? $0 : nil }
        let persistedIsAuthoritative = defaults.bool(
            forKey: storageKey(Storage.authoritativeStorefront)
        )
            || hasConnected
            || !decoded.isEmpty
        let inferredID = KindleStorefront.inferredID(from: decoded)
        let inferred = KindleStorefront.storefront(id: inferredID)
            .flatMap { $0.isSelectable ? $0 : nil }
        let selectedLanguage = AppLanguageManager.shared.selectedLanguage
        let language = selectedLanguage == .system
            ? Locale.autoupdatingCurrent.language.languageCode?.identifier
            : selectedLanguage.rawValue
        let recommendationContext = KindleStorefrontRecommendationContext(
            locale: .autoupdatingCurrent,
            preferredLanguages: Locale.preferredLanguages,
            appLanguageCode: language,
            timeZone: .autoupdatingCurrent
        )
        let suggested = KindleStorefrontRecommender.recommend(
            context: recommendationContext
        ).recommended
        let resolved = (persistedIsAuthoritative ? persisted : nil)
            ?? inferred
            ?? suggested
        boundStorefrontID = resolved.id
        hasAuthoritativeStorefrontBinding = persistedIsAuthoritative
            && persisted != nil
            || inferred != nil

        var migrated = decoded
        for index in migrated.indices where migrated[index].storefrontID == nil {
            migrated[index].storefrontID = KindleStorefrontMigration
                .resolvedStorefront(for: migrated[index])
                .flatMap { $0.isSelectable ? $0.id : nil }
                ?? resolved.id
        }
        books = sanitized(migrated).filter { $0.storefrontID == boundStorefrontID }
        if persisted == nil || !persistedIsAuthoritative {
            KindleRunLog.write(
                "KINDLE storefront migration id=\(resolved.id) source=\(inferred == nil ? "suggested" : "books")"
            )
        }
        if !hasPersistedConnectionState {
            hasConnected = !books.isEmpty
        }
        save()
    }

    private func update(bookID: String, mutate: (inout KindleBook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        mutate(&books[index])
        save()
    }

    private func save() {
        guard hasActiveStorage else { return }
        defaults.set(hasConnected, forKey: storageKey(Storage.connected))
        defaults.set(accountLabel, forKey: storageKey(Storage.accountLabel))
        defaults.set(accountEmail, forKey: storageKey(Storage.accountEmail))
        defaults.set(boundStorefrontID, forKey: storageKey(Storage.boundStorefront))
        defaults.set(
            hasAuthoritativeStorefrontBinding,
            forKey: storageKey(Storage.authoritativeStorefront)
        )
        if let anchorData = try? JSONEncoder.kindle.encode(listeningAnchors) {
            defaults.set(anchorData, forKey: storageKey(Storage.listeningAnchors))
        }
        if let data = try? JSONEncoder.kindle.encode(books) {
            defaults.set(data, forKey: storageKey(Storage.books))
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
        accountEmail = nil
        boundStorefrontID = KindleStorefront.us.id
        listeningAnchors = [:]
        isRefreshing = false
        lastError = nil
        hasAuthoritativeStorefrontBinding = false
    }

    private func sanitized(_ input: [KindleBook]) -> [KindleBook] {
        input.compactMap { raw in
            var book = raw
            if KindleStorefront.entry(id: book.storefrontID) == nil {
                book.storefrontID = KindleStorefront.entry(url: URL(string: book.readerURL))?.id
                    ?? boundStorefrontID
            }
            guard book.isLikelyLibraryBook else { return nil }
            if let repaired = KindleBookValidator.repairedReaderURL(for: book, preferLastRead: false) {
                book.readerURL = repaired
            }
            if let repairedLastRead = KindleBookValidator.usableReaderURL(
                book.lastReadURL,
                fallbackASIN: book.asin ?? book.id,
                storefront: KindleStorefront.entry(id: book.storefrontID) ?? boundStorefront
            ) {
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

    private func clearAmazonWebsiteData(
        for storefront: KindleStorefront? = nil
    ) async {
        let dataStore = CommercialWebSession.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: types) { records in
                let targets = records.filter { record in
                    if let storefront {
                        return KindleStorefront.isAmazonWebsiteDataDomain(
                            record.displayName,
                            for: storefront
                        )
                    }
                    return KindleStorefront.isAmazonWebsiteDataDomain(
                        record.displayName
                    )
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
