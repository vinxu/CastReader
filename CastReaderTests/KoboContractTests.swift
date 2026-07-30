//
//  KoboContractTests.swift
//  CastReaderTests
//
//  Kobo 纯模型、URL 安全、书架快照、账号隔离和共享会话合同。
//

import WebKit
import XCTest
@testable import CastReader

final class KoboContractTests: XCTestCase {
    private let primaryUUID = "b849f0ce-d6b3-42f6-bcb6-e6774d00d132"
    private let secondUUID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    // MARK: - URL / identity

    func testReaderUUIDCanonicalizesTheProvidedKoboURL() {
        let raw =
            "https://readnow.kobo.com/B849F0CE-D6B3-42F6-BCB6-E6774D00D132" +
            "?backref_url=https%3A%2F%2Fwww.kobo.com%2Fsg%2Fen%2Flibrary%2Fbooks" +
            "&locale=en-US"
        XCTAssertEqual(
            KoboBookValidator.usableReaderURL(raw),
            "https://readnow.kobo.com/\(primaryUUID)"
        )
        XCTAssertEqual(
            KoboBookValidator.usableReaderURL("/\(primaryUUID)"),
            "https://readnow.kobo.com/\(primaryUUID)"
        )
        XCTAssertEqual(
            KoboBookValidator.usableReaderURL(
                "//readnow.kobo.com/\(primaryUUID)/"
            ),
            "https://readnow.kobo.com/\(primaryUUID)"
        )
    }

    func testReaderURLPolicyRejectsUnsafeAuthoritiesAndMalformedUUIDs() {
        let rejected = [
            "http://readnow.kobo.com/\(primaryUUID)",
            "https://user@readnow.kobo.com/\(primaryUUID)",
            "https://readnow.kobo.com:444/\(primaryUUID)",
            "https://readnow.kobo.com.evil.example/\(primaryUUID)",
            "https://evil.example/\(primaryUUID)",
            "https://readnow.kobo.com/",
            "https://readnow.kobo.com/not-a-uuid",
            "https://readnow.kobo.com/\(primaryUUID)/extra",
            "https://readnow.kobo.com/%7B\(primaryUUID)%7D",
            "https://readnow.kobo.com/%2F\(primaryUUID)",
        ]
        for raw in rejected {
            XCTAssertNil(
                KoboBookValidator.usableReaderURL(raw),
                "should reject \(raw)"
            )
            XCTAssertFalse(
                KoboWebAccessPolicy.allowsReaderNavigation(URL(string: raw)),
                "policy should reject \(raw)"
            )
        }

        XCTAssertTrue(
            KoboWebAccessPolicy.allowsReaderNavigation(
                URL(string: "https://readnow.kobo.com:443/\(primaryUUID)")
            )
        )
    }

    func testRegionalLibraryURLPolicyIsNarrow() {
        XCTAssertTrue(
            KoboWebAccessPolicy.allowsLibraryURL(
                URL(string: "https://www.kobo.com/sg/en/library/books")
            )
        )
        XCTAssertTrue(
            KoboWebAccessPolicy.allowsLibraryURL(
                URL(string: "https://kobo.com/library/books/")
            )
        )
        XCTAssertFalse(
            KoboWebAccessPolicy.allowsLibraryURL(
                URL(string: "https://readnow.kobo.com/\(primaryUUID)")
            )
        )
        XCTAssertFalse(
            KoboWebAccessPolicy.allowsLibraryURL(
                URL(string: "https://www.kobo.com/sg/en/store/books")
            )
        )
        XCTAssertFalse(
            KoboWebAccessPolicy.allowsLibraryURL(
                URL(string: "https://www.kobo.com/foo/bar/baz/library/books")
            )
        )
        XCTAssertFalse(
            KoboWebAccessPolicy.allowsLibraryURL(
                URL(string: "https://www.kobo.com.evil.example/sg/en/library/books")
            )
        )
    }

    func testStableIDAndResumeURLStayBoundToTheSameBook() {
        XCTAssertEqual(
            KoboBookValidator.stableID(bookUUID: primaryUUID),
            "kobo:\(primaryUUID)"
        )
        XCTAssertEqual(
            KoboBookValidator.usableResumeURL(
                "https://readnow.kobo.com/\(primaryUUID)?locale=en-US",
                expecting: primaryUUID
            ),
            "https://readnow.kobo.com/\(primaryUUID)"
        )
        XCTAssertNil(
            KoboBookValidator.usableResumeURL(
                "https://readnow.kobo.com/\(secondUUID)",
                expecting: primaryUUID
            )
        )
        XCTAssertNil(
            KoboBookValidator.usableResumeURL(
                "https://readnow.kobo.com/\(primaryUUID)",
                expecting: "invalid"
            )
        )
    }

    func testBookMetadataCannotClaimAnotherUUIDOrStableID() {
        let valid = makeBook(primaryUUID, title: "Valid")
        XCTAssertTrue(KoboBookValidator.isLikelyLibraryBook(valid))

        let wrongUUID = KoboBook(
            id: valid.id,
            title: valid.title,
            author: valid.author,
            coverURL: valid.coverURL,
            readerURL: valid.readerURL,
            progressLabel: valid.progressLabel,
            bookUUID: secondUUID,
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReaderURL: nil
        )
        XCTAssertFalse(KoboBookValidator.isLikelyLibraryBook(wrongUUID))

        let wrongStableID = KoboBook(
            id: "kobo:\(secondUUID)",
            title: valid.title,
            author: valid.author,
            coverURL: valid.coverURL,
            readerURL: valid.readerURL,
            progressLabel: valid.progressLabel,
            bookUUID: primaryUUID,
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReaderURL: nil
        )
        XCTAssertFalse(KoboBookValidator.isLikelyLibraryBook(wrongStableID))
    }

    // MARK: - Scan / shelf snapshot

    func testScanResultRequiresAccountAndShelfEvidence() {
        let result = KoboScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": true,
            "isShelfContext": true,
            "isCompleteSnapshot": true,
            "account": "Reader@Example.com",
            "accountIdentitySource": " Reader@Example.com ",
            "books": [
                [
                    "readerURL":
                        "https://readnow.kobo.com/\(primaryUUID)?locale=en-US",
                    "title": "The Test Book",
                    "author": "Ada Reader",
                    "coverURL": "//cdn.kobo.example/cover.jpg",
                    "progressLabel": "42%",
                ],
                [
                    "readerURL": "https://evil.example/\(secondUUID)",
                    "title": "Forged",
                ],
                [
                    "readerURL":
                        "https://readnow.kobo.com/\(secondUUID)",
                    "title": "  ",
                ],
            ],
        ])

        XCTAssertTrue(result.authenticated)
        XCTAssertEqual(
            result.account?.identity,
            KoboAccountIdentity.hash("reader@example.com")
        )
        XCTAssertFalse(
            result.account?.identity?.contains("reader@example.com") == true
        )
        XCTAssertEqual(result.account?.displayLabel, "Kobo · example.com")
        XCTAssertEqual(result.books.count, 1)
        XCTAssertEqual(result.books.first?.id, "kobo:\(primaryUUID)")
        XCTAssertEqual(
            result.books.first?.readerURL,
            "https://readnow.kobo.com/\(primaryUUID)"
        )
        XCTAssertEqual(
            result.books.first?.coverURL,
            "https://cdn.kobo.example/cover.jpg"
        )
    }

    func testScanBoundaryCleansActionTitlesAuthorsAndPlaceholderCovers() {
        let result = KoboScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": true,
            "isShelfContext": true,
            "isCompleteSnapshot": true,
            "account": "reader@example.com",
            "accountIdentitySource": "reader@example.com",
            "books": [[
                "readerURL": "https://readnow.kobo.com/\(primaryUUID)",
                "title": "Read Now: Two Tickets",
                "author": "By Casey Reader",
                "coverURL": "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP",
                "progressLabel": "",
            ]],
        ])

        XCTAssertEqual(result.books.first?.title, "Two Tickets")
        XCTAssertEqual(result.books.first?.author, "Casey Reader")
        XCTAssertNil(result.books.first?.coverURL)
    }

    func testPublicReaderLinksCannotMasqueradeAsAuthenticatedShelf() {
        let result = KoboScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": false,
            "isShelfContext": true,
            "isCompleteSnapshot": true,
            "books": [
                [
                    "readerURL":
                        "https://readnow.kobo.com/\(primaryUUID)",
                    "title": "Public Preview",
                ],
            ],
        ])
        XCTAssertFalse(result.authenticated)
        XCTAssertNil(result.account)
        XCTAssertEqual(result.books.count, 1)
    }

    func testEmptyShelfNeedsStableTrustedCompletion() {
        let account = makeAccount("empty@example.com", complete: true)
        XCTAssertFalse(
            KoboShelfSyncContract.canCommit(
                bookCount: 0,
                account: account,
                reachedEnd: true,
                stableEndPasses:
                    KoboShelfSyncContract.emptyShelfStablePasses - 1
            )
        )
        XCTAssertTrue(
            KoboShelfSyncContract.canCommit(
                bookCount: 0,
                account: account,
                reachedEnd: true,
                stableEndPasses:
                    KoboShelfSyncContract.emptyShelfStablePasses
            )
        )
        XCTAssertFalse(
            KoboShelfSyncContract.canCommit(
                bookCount: 0,
                account: KoboAccountInfo(
                    label: nil,
                    identity: nil,
                    hasAccountEvidence: true,
                    isShelfContext: true,
                    isCompleteSnapshot: true
                ),
                reachedEnd: true,
                stableEndPasses:
                    KoboShelfSyncContract.emptyShelfStablePasses
            ),
            "an unidentifiable account cannot own an isolated empty shelf"
        )
    }

    // MARK: - Store merge / anchor / account isolation

    @MainActor
    func testPartialSnapshotAddsButNeverDeletesAndCompleteSnapshotRemoves() {
        withIsolatedStore { store in
            let first = makeBook(primaryUUID, title: "First")
            let second = makeBook(secondUUID, title: "Second")
            let complete = makeAccount("reader@example.com", complete: true)
            store.mergeScrapedBooks([first, second], account: complete)
            store.updateProgress(
                bookID: second.id,
                readerURL: second.readerURL,
                fingerprint: "page-second",
                progressLabel: "20%"
            )

            store.mergeScrapedBooks(
                [makeBook(primaryUUID, title: "First Updated")],
                account: makeAccount("reader@example.com", complete: false)
            )
            XCTAssertEqual(Set(store.books.map(\.id)), [first.id, second.id])
            XCTAssertEqual(store.book(for: first.id)?.title, "First Updated")
            XCTAssertNotNil(store.anchor(for: second.id))

            store.mergeScrapedBooks(
                [makeBook(primaryUUID, title: "First Final")],
                account: complete
            )
            XCTAssertEqual(store.books.map(\.id), [first.id])
            XCTAssertNil(store.book(for: second.id))
            XCTAssertNil(store.anchor(for: second.id))
        }
    }

    @MainActor
    func testUntrustedOrInvalidSnapshotCannotMutateShelf() {
        withIsolatedStore { store in
            let original = makeBook(primaryUUID, title: "Original")
            store.mergeScrapedBooks(
                [original],
                account: makeAccount("reader@example.com", complete: true)
            )

            store.mergeScrapedBooks(
                [makeBook(secondUUID, title: "Public Card")],
                account: KoboAccountInfo(
                    label: nil,
                    identity: nil,
                    hasAccountEvidence: false,
                    isShelfContext: false,
                    isCompleteSnapshot: true
                )
            )
            XCTAssertEqual(store.books.map(\.id), [original.id])
            XCTAssertNotNil(store.lastError)

            var invalid = makeBook(secondUUID, title: "Invalid")
            invalid.readerURL = "https://evil.example/\(secondUUID)"
            store.mergeScrapedBooks(
                [invalid],
                account: makeAccount("reader@example.com", complete: true)
            )
            XCTAssertEqual(store.books.map(\.id), [original.id])
        }
    }

    @MainActor
    func testMetadataMergePreservesLocalAnchorAndOpenState() {
        withIsolatedStore { store in
            let original = makeBook(primaryUUID, title: "Old Title")
            store.mergeScrapedBooks(
                [original],
                account: makeAccount("reader@example.com", complete: true)
            )
            store.markOpened(original)
            store.updateProgress(
                bookID: original.id,
                readerURL: original.readerURL,
                fingerprint: "  opaque-page-token  ",
                progressLabel: "12%"
            )
            let openedAt = store.book(for: original.id)?.lastOpenedAt

            var refreshed = makeBook(primaryUUID, title: "New Title")
            refreshed.author = "New Author"
            refreshed.coverURL = "https://cdn.kobo.example/new.jpg"
            refreshed.progressLabel = "55%"
            store.mergeScrapedBooks(
                [refreshed],
                account: makeAccount("reader@example.com", complete: true)
            )

            let stored = store.book(for: original.id)
            XCTAssertEqual(stored?.title, "New Title")
            XCTAssertEqual(stored?.author, "New Author")
            XCTAssertEqual(stored?.progressLabel, "55%")
            XCTAssertEqual(stored?.lastOpenedAt, openedAt)
            XCTAssertEqual(
                stored?.lastReaderURL,
                "https://readnow.kobo.com/\(primaryUUID)"
            )
            XCTAssertEqual(
                store.anchor(for: original.id)?.pageFingerprint,
                "  opaque-page-token  ",
                "page identity is opaque and must not be trimmed"
            )
        }
    }

    @MainActor
    func testAnchorRejectsAnotherBookOrEmptyFingerprint() {
        withIsolatedStore { store in
            let book = makeBook(primaryUUID, title: "Book")
            store.mergeScrapedBooks(
                [book],
                account: makeAccount("reader@example.com", complete: true)
            )
            store.updateProgress(
                bookID: book.id,
                readerURL:
                    "https://readnow.kobo.com/\(secondUUID)",
                fingerprint: "wrong-book",
                progressLabel: nil
            )
            XCTAssertNil(store.anchor(for: book.id))

            store.updateProgress(
                bookID: book.id,
                readerURL: book.readerURL,
                fingerprint: "   ",
                progressLabel: nil
            )
            XCTAssertNil(store.anchor(for: book.id))
        }
    }

    @MainActor
    func testStableBookAndAnchorSurviveStoreReload() {
        let suite = "KoboContractTests.reload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KoboContractTests.reload-history.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)

        let book = makeBook(primaryUUID, title: "Persistent")
        let first = KoboLibraryStore(
            defaults: defaults,
            historyStore: history
        )
        first.mergeScrapedBooks(
            [book],
            account: makeAccount("reader@example.com", complete: true)
        )
        first.updateProgress(
            bookID: book.id,
            readerURL:
                "https://readnow.kobo.com/\(primaryUUID)?locale=en-US",
            fingerprint: "page-token-with-space ",
            progressLabel: "33%"
        )

        let reloaded = KoboLibraryStore(
            defaults: defaults,
            historyStore: history
        )
        XCTAssertTrue(reloaded.hasConnected)
        XCTAssertEqual(reloaded.books.map(\.id), [book.id])
        XCTAssertEqual(
            reloaded.book(for: book.id)?.lastReaderURL,
            "https://readnow.kobo.com/\(primaryUUID)"
        )
        XCTAssertEqual(
            reloaded.anchor(for: book.id)?.pageFingerprint,
            "page-token-with-space "
        )
        XCTAssertEqual(
            reloaded.accountIdentity,
            KoboAccountIdentity.hash("reader@example.com")
        )
    }

    @MainActor
    func testTrustedAccountChangeReplacesOnlyKoboState() {
        withIsolatedStoreAndHistory { store, history in
            let oldBook = makeBook(primaryUUID, title: "Old Account")
            store.mergeScrapedBooks(
                [oldBook],
                account: makeAccount("old@example.com", complete: true)
            )
            store.updateProgress(
                bookID: oldBook.id,
                readerURL: oldBook.readerURL,
                fingerprint: "old-page",
                progressLabel: nil
            )
            history.record(
                ReadingDocument(
                    id: oldBook.id,
                    title: oldBook.title,
                    sourceKind: .kobo,
                    language: "en",
                    paragraphs: [],
                    sourceURL: oldBook.readerURL
                )
            )
            history.record(
                ReadingDocument(
                    id: "retained-text",
                    title: "Retained",
                    sourceKind: .text,
                    language: "en",
                    paragraphs: [
                        ReadingParagraph(id: 0, text: "Retained")
                    ]
                )
            )

            let newBook = makeBook(secondUUID, title: "New Account")
            store.mergeScrapedBooks(
                [newBook],
                account: makeAccount("new@example.com", complete: false)
            )

            XCTAssertEqual(store.books.map(\.id), [newBook.id])
            XCTAssertNil(store.anchor(for: oldBook.id))
            XCTAssertFalse(history.records.contains { $0.sourceKind == .kobo })
            XCTAssertTrue(history.records.contains { $0.id == "retained-text" })
            XCTAssertEqual(
                store.accountIdentity,
                KoboAccountIdentity.hash("new@example.com")
            )
        }
    }

    @MainActor
    func testDisconnectPreservesSharedWebCookiesAndOtherHistory() async throws {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        try await withIsolatedStoreAndHistoryAsync(
            websiteDataStore: websiteDataStore
        ) { store, history in
            let book = makeBook(primaryUUID, title: "Kobo")
            store.mergeScrapedBooks(
                [book],
                account: makeAccount("reader@example.com", complete: true)
            )
            history.record(
                ReadingDocument(
                    id: book.id,
                    title: book.title,
                    sourceKind: .kobo,
                    language: "en",
                    paragraphs: [],
                    sourceURL: book.readerURL
                )
            )
            history.record(
                ReadingDocument(
                    id: "retained-text",
                    title: "Retained",
                    sourceKind: .text,
                    language: "en",
                    paragraphs: [
                        ReadingParagraph(id: 0, text: "Retained")
                    ]
                )
            )

            let cookieName = "shared_google_session_\(UUID().uuidString)"
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .domain: ".accounts.google.com",
                .path: "/",
                .name: cookieName,
                .value: "opaque",
                .secure: "TRUE",
                .expires: Date(timeIntervalSinceNow: 300),
            ]))
            await setCookie(cookie, in: websiteDataStore.httpCookieStore)

            await store.disconnectAccount()

            XCTAssertFalse(store.hasConnected)
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertTrue(store.anchors.isEmpty)
            XCTAssertFalse(history.records.contains { $0.sourceKind == .kobo })
            XCTAssertTrue(history.records.contains { $0.id == "retained-text" })
            let cookies = await allCookies(
                in: websiteDataStore.httpCookieStore
            )
            XCTAssertTrue(cookies.contains {
                $0.name == cookieName
                    && $0.domain.contains("accounts.google.com")
            })
        }
    }

    @MainActor
    func testKoboUsesThePersistentSharedGoogleWebProfile() {
        let google = GoogleWebSession.websiteDataStore
        let kobo = KoboWebSession.websiteDataStore
        XCTAssertTrue(google.isPersistent)
        XCTAssertTrue(kobo.isPersistent)
        XCTAssertEqual(kobo.identifier, google.identifier)
        XCTAssertEqual(
            google.identifier,
            GoogleWebSession.websiteDataStoreIdentifier
        )
    }

    func testKoboKeepsTheFullViewportAndUsesItsDesktopReaderIdentity() {
        XCTAssertEqual(LiveWebPlatformID.googleBooks.pageZoom, 1)
        XCTAssertEqual(LiveWebPlatformID.kobo.pageZoom, 1)
        XCTAssertEqual(
            LiveWebPlatformID.kobo.userAgent,
            GoogleBooksWebScripts.desktopSafariUserAgent
        )
        XCTAssertNotEqual(
            LiveWebPlatformID.kobo.userAgent,
            LiveWebPlatformID.googleBooks.userAgent,
            "Kobo needs its semantic desktop page controls while retaining a mobile CSS viewport"
        )
    }

    @MainActor
    func testMetadataMergePreservesGoodFieldsAcrossPartialScans() {
        withIsolatedStore { store in
            let account = makeAccount("reader@example.com", complete: true)
            var complete = makeBook(primaryUUID, title: "Two Tickets")
            complete.author = "Casey Reader"
            complete.coverURL = "https://cdn.kobo.example/two-tickets.jpg"
            store.mergeScrapedBooks([complete], account: account)

            var partial = makeBook(
                primaryUUID,
                title: "Read Now: Two Tickets"
            )
            partial.author = "Unknown author"
            partial.coverURL = nil
            store.mergeScrapedBooks([partial], account: account)

            XCTAssertEqual(store.books.first?.title, "Two Tickets")
            XCTAssertEqual(store.books.first?.author, "Casey Reader")
            XCTAssertEqual(
                store.books.first?.coverURL,
                "https://cdn.kobo.example/two-tickets.jpg"
            )
        }
    }

    // MARK: - Helpers

    private func makeBook(_ uuid: String, title: String) -> KoboBook {
        let canonical = KoboBookValidator.canonicalReaderURL(bookUUID: uuid)
        return KoboBook(
            id: KoboBookValidator.stableID(bookUUID: uuid),
            title: title,
            author: "",
            coverURL: nil,
            readerURL: canonical,
            progressLabel: "",
            bookUUID: uuid.lowercased(),
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReaderURL: nil
        )
    }

    private func makeAccount(
        _ rawIdentity: String,
        complete: Bool
    ) -> KoboAccountInfo {
        KoboAccountInfo(
            label: "Kobo account",
            identity: KoboAccountIdentity.hash(rawIdentity),
            hasAccountEvidence: true,
            isShelfContext: true,
            isCompleteSnapshot: complete
        )
    }

    @MainActor
    private func withIsolatedStore(
        _ body: (KoboLibraryStore) throws -> Void
    ) rethrows {
        try withIsolatedStoreAndHistory { store, _ in
            try body(store)
        }
    }

    @MainActor
    private func withIsolatedStoreAndHistory(
        _ body: (KoboLibraryStore, HistoryStore) throws -> Void
    ) rethrows {
        let suite = "KoboContractTests.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KoboContractTests.history.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)
        try body(
            KoboLibraryStore(defaults: defaults, historyStore: history),
            history
        )
    }

    @MainActor
    private func withIsolatedStoreAndHistoryAsync(
        websiteDataStore: WKWebsiteDataStore,
        _ body: (KoboLibraryStore, HistoryStore) async throws -> Void
    ) async rethrows {
        let suite = "KoboContractTests.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KoboContractTests.history.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)
        try await body(
            KoboLibraryStore(
                defaults: defaults,
                historyStore: history,
                websiteDataStore: websiteDataStore
            ),
            history
        )
    }

    @MainActor
    private func setCookie(
        _ cookie: HTTPCookie,
        in store: WKHTTPCookieStore
    ) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    @MainActor
    private func allCookies(
        in store: WKHTTPCookieStore
    ) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

@MainActor
final class KoboLibraryScanWebTests: XCTestCase {
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Error>?

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            continuation?.resume()
            continuation = nil
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private var webView: WKWebView?
    private var navigationWaiter: NavigationWaiter?

    override func tearDown() async throws {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        navigationWaiter = nil
        try await super.tearDown()
    }

    func testReadNowActionNodeResolvesItsWholeMetadataCard() async throws {
        let uuid = "b849f0ce-d6b3-42f6-bcb6-e6774d00d132"
        let view = try await loadShelf(
            """
            <!doctype html><html><body>
              <header>
                <a href="/logout" data-email="reader@example.com">Account</a>
              </header>
              <main>
                <article role="listitem" data-testid="book-card">
                  <picture>
                    <source srcset="https://cdn.kobo.example/two-tickets@2x.jpg 2x">
                    <img alt="Two Tickets"
                         src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP"
                         data-src="https://cdn.kobo.example/two-tickets.jpg">
                  </picture>
                  <h3 data-testid="book-title">Two Tickets</h3>
                  <span data-testid="book-author">By Casey Reader</span>
                  <a data-testid="book-read-now"
                     aria-label="Read Now: Two Tickets"
                     href="https://readnow.kobo.com/\(uuid)">Read Now</a>
                </article>
              </main>
            </body></html>
            """
        )

        let value = try await view.evaluateJavaScript(
            KoboWebScripts.libraryScan
        )
        let raw = try XCTUnwrap(value as? [String: Any])
        let result = KoboScanResult(raw)
        let book = try XCTUnwrap(result.books.first)

        XCTAssertTrue(result.authenticated)
        XCTAssertEqual(result.books.count, 1)
        XCTAssertEqual(book.title, "Two Tickets")
        XCTAssertEqual(book.author, "Casey Reader")
        XCTAssertEqual(
            book.coverURL,
            "https://cdn.kobo.example/two-tickets@2x.jpg"
        )
    }

    private func loadShelf(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            configuration: configuration
        )
        let waiter = NavigationWaiter()
        view.navigationDelegate = waiter
        webView = view
        navigationWaiter = waiter

        try await withCheckedThrowingContinuation { continuation in
            waiter.continuation = continuation
            view.loadHTMLString(
                html,
                baseURL: KoboWebScripts.shelfURL
            )
        }
        return view
    }
}
