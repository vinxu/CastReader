//
//  OReillyContractTests.swift
//  CastReaderTests
//

import WebKit
import XCTest
@testable import CastReader

final class OReillyContractTests: XCTestCase {
    private let firstID = "9781098176495"
    private let secondID = "9781098162665"
    private let proxyHost =
        "learning-oreilly-com.ezproxy.example.edu"

    func testInstitutionEntrySupportsPeninsulaEZproxyAndRejectsUnsafeLinks() {
        let peninsula =
            OReillyWebScripts.peninsulaLibrarySystemAccessURL
        XCTAssertEqual(
            peninsula.host?.lowercased(),
            "login.ezproxy.plsinfo.org"
        )
        XCTAssertTrue(
            OReillyWebScripts.allowsInstitutionEntryURL(peninsula)
        )
        XCTAssertEqual(
            OReillyWebScripts.institutionEntryURL(
                from: "  \(peninsula.absoluteString)\n"
            ),
            peninsula
        )
        XCTAssertTrue(
            OReillyWebScripts.allowsInstitutionEntryURL(
                OReillyWebScripts.institutionAccessURL
            )
        )
        let peninsulaReaderHost =
            "learning-oreilly-com.ezproxy.plsinfo.org"
        XCTAssertTrue(
            OReillyWebAccessPolicy.isAllowedReaderHost(
                peninsulaReaderHost
            )
        )
        XCTAssertEqual(
            OReillyWebScripts.historyURL(
                for: URL(
                    string: "https://\(peninsulaReaderHost)/home/"
                )
            )?.absoluteString,
            "https://\(peninsulaReaderHost)/history/"
        )

        let rejected = [
            "http://login.ezproxy.plsinfo.org/login?" +
                "qurl=https%3A%2F%2Fwww.oreilly.com%2Flibrary%2F",
            "https://user@login.ezproxy.plsinfo.org/login?" +
                "qurl=https%3A%2F%2Fwww.oreilly.com%2Flibrary%2F",
            "https://login.ezproxy.plsinfo.org:444/login?" +
                "qurl=https%3A%2F%2Fwww.oreilly.com%2Flibrary%2F",
            "https://evil.example/login?" +
                "qurl=https%3A%2F%2Fwww.oreilly.com%2Flibrary%2F",
            "https://login.ezproxy.plsinfo.org/login?" +
                "qurl=https%3A%2F%2Fevil.example%2Flibrary%2F",
            "https://ezproxy.attacker.com/login?" +
                "qurl=https%3A%2F%2Fwww.oreilly.com%2Flibrary%2F",
            "https://learning-oreilly-com.ezproxy.attacker.com/history/",
            "https://www.oreilly.com/account/login",
        ]
        for raw in rejected {
            XCTAssertNil(
                OReillyWebScripts.institutionEntryURL(from: raw),
                "should reject unsafe institution entry \(raw)"
            )
        }
    }

    func testTrustedEmptyHistoryRequiresSeedingOnlyForANewShelf() {
        let account = makeAccount("temporary-reader", complete: true)
        XCTAssertFalse(
            OReillyShelfSyncContract.canCommit(
                bookCount: 0,
                account: account,
                reachedEnd: true,
                stableEndPasses:
                    OReillyShelfSyncContract.emptyShelfStablePasses - 1
            )
        )
        XCTAssertTrue(
            OReillyShelfSyncContract.canCommit(
                bookCount: 0,
                account: account,
                reachedEnd: true,
                stableEndPasses:
                    OReillyShelfSyncContract.emptyShelfStablePasses
            )
        )
        XCTAssertFalse(
            OReillyShelfSyncContract.canCommit(
                bookCount: 0,
                account: makeAccount("temporary-reader", complete: false),
                reachedEnd: true,
                stableEndPasses:
                    OReillyShelfSyncContract.emptyShelfStablePasses
            ),
            "an ambiguous empty DOM must not become a destructive snapshot"
        )
        XCTAssertTrue(
            OReillyShelfSyncContract.requiresCatalogSeed(
                scannedBookCount: 0,
                existingBookCount: 0,
                isExistingAccount: false
            )
        )
        XCTAssertFalse(
            OReillyShelfSyncContract.requiresCatalogSeed(
                scannedBookCount: 0,
                existingBookCount: 2,
                isExistingAccount: true
            ),
            "an established shelf may accept a trusted empty snapshot"
        )
        XCTAssertTrue(
            OReillyShelfSyncContract.requiresCatalogSeed(
                scannedBookCount: 0,
                existingBookCount: 2,
                isExistingAccount: false
            ),
            "another account must not inherit the old account's shelf state"
        )
        XCTAssertFalse(
            OReillyShelfSyncContract.requiresCatalogSeed(
                scannedBookCount: 1,
                existingBookCount: 0,
                isExistingAccount: false
            )
        )
    }

    func testDirectAndInstitutionReaderURLsPreserveActualPathAndFragment() {
        let direct =
            "https://learning.oreilly.com/library/view/" +
            "building-applications-with/\(firstID)/preface01.html#heading"
        XCTAssertEqual(
            OReillyBookValidator.usableReaderURL(direct),
            direct
        )

        let proxied =
            "https://\(proxyHost)/library/view/-/\(firstID)/continue/"
        XCTAssertEqual(
            OReillyBookValidator.usableReaderURL(
                proxied,
                trustedHost: proxyHost
            ),
            proxied
        )
        XCTAssertEqual(
            OReillyBookValidator.stableID(contentID: firstID),
            "oreilly:\(firstID)"
        )
    }

    func testReaderPolicyRejectsLookalikesUnsafeAuthoritiesAndCrossHost() {
        let rejected = [
            "http://learning.oreilly.com/library/view/-/\(firstID)/",
            "https://user@learning.oreilly.com/library/view/-/\(firstID)/",
            "https://learning.oreilly.com:444/library/view/-/\(firstID)/",
            "https://learning.oreilly.com.evil.example/library/view/-/\(firstID)/",
            "https://learning-oreilly-com.evil.example/library/view/-/\(firstID)/",
            "https://evil.example/library/view/-/\(firstID)/",
            "https://learning.oreilly.com/library/view/-/short/",
            "https://learning.oreilly.com/library/view/-/\(firstID)/%2e%2e/",
            "https://learning.oreilly.com/library//view/-/\(firstID)/",
        ]
        for raw in rejected {
            XCTAssertNil(
                OReillyBookValidator.usableReaderURL(raw),
                "should reject \(raw)"
            )
        }

        let direct =
            "https://learning.oreilly.com/library/view/-/\(firstID)/"
        XCTAssertNil(
            OReillyBookValidator.usableReaderURL(
                direct,
                trustedHost: proxyHost
            ),
            "a proxy-bound shelf must not silently jump to another origin"
        )
    }

    func testResumeURLMustStayOnTheSameBookAndTrustedHost() {
        let chapter =
            "https://\(proxyHost)/library/view/title/\(firstID)/ch01.html#s1"
        XCTAssertEqual(
            OReillyBookValidator.usableResumeURL(
                chapter,
                expecting: firstID,
                trustedHost: proxyHost
            ),
            chapter
        )
        XCTAssertNil(
            OReillyBookValidator.usableResumeURL(
                "https://\(proxyHost)/library/view/title/\(secondID)/ch01.html",
                expecting: firstID,
                trustedHost: proxyHost
            )
        )
    }

    func testScanRequiresNativeTrustedShelfURLAndHashesIdentity() {
        let historyURL = URL(string: "https://\(proxyHost)/history/")!
        let reader =
            "/library/view/-/\(firstID)/continue/"
        let result = OReillyScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": true,
            "isShelfContext": true,
            "isCompleteSnapshot": true,
            "account": "Peninsula Library System Learner",
            "accountIdentitySource": "institution-user-123",
            "books": [[
                "contentKind": "book",
                "title": "Building Applications with AI Agents",
                "author": "By Michael Albada",
                "readerURL": reader,
                "coverURL": "/covers/urn:orm:book:\(firstID)/100w/",
                "progressLabel": "0% Progress",
            ]],
        ], pageURL: historyURL)

        XCTAssertTrue(result.authenticated)
        XCTAssertEqual(result.books.first?.id, "oreilly:\(firstID)")
        XCTAssertEqual(
            result.books.first?.readerURL,
            "https://\(proxyHost)\(reader)"
        )
        XCTAssertEqual(result.books.first?.author, "Michael Albada")
        XCTAssertEqual(
            result.account?.identity,
            OReillyAccountIdentity.hash("institution-user-123")
        )
        XCTAssertFalse(
            result.account?.identity?.contains("institution-user-123")
                == true
        )

        let discovery = OReillyScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": true,
            "isShelfContext": true,
            "isCompleteSnapshot": true,
            "accountIdentitySource": "institution-user-123",
            "books": [[
                "contentKind": "book",
                "title": "Recommendation",
                "readerURL": reader,
            ]],
        ], pageURL: URL(string: "https://\(proxyHost)/home/"))
        XCTAssertFalse(discovery.authenticated)
        XCTAssertNil(discovery.account)
        XCTAssertTrue(discovery.books.isEmpty)
    }

    func testHistoryScanRejectsNonBookContentKinds() {
        let historyURL = URL(string: "https://\(proxyHost)/history/")!
        let common: [String: Any] = [
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": true,
            "isShelfContext": true,
            "isCompleteSnapshot": true,
            "account": "Institution Learner",
            "accountIdentitySource": "learner:opaque-account-id",
        ]
        let nonBookKinds = ["course", "video", "event", "playlist", ""]

        for kind in nonBookKinds {
            var raw = common
            raw["books"] = [[
                "contentKind": kind,
                "title": "Not a book",
                "readerURL":
                    "/library/view/-/\(firstID)/continue/",
            ]]
            let result = OReillyScanResult(raw, pageURL: historyURL)
            XCTAssertTrue(
                result.books.isEmpty,
                "History item kind \(kind) must not become a shelf book"
            )
        }
    }

    func testLiveReaderPayloadMustMatchBoundPlatform() {
        XCTAssertTrue(
            LiveWebPlatformID.oreilly.acceptsPayloadSource("oreilly")
        )
        XCTAssertFalse(
            LiveWebPlatformID.oreilly.acceptsPayloadSource("kobo")
        )
        XCTAssertFalse(
            LiveWebPlatformID.oreilly.acceptsPayloadSource("google-books")
        )
        XCTAssertFalse(
            LiveWebPlatformID.oreilly.acceptsPayloadSource(nil)
        )
    }

    @MainActor
    func testOReillyReaderAcceptsAutomaticReviewSessionContinuation() {
        let document = ReadingDocument(
            title: "O'Reilly chapter",
            sourceKind: .oreilly,
            paragraphs: [
                ReadingParagraph(
                    id: 0,
                    text: "Visible chapter text.",
                    type: .paragraph
                )
            ]
        )
        let viewModel = ReadAloudViewModel(document: document)

        XCTAssertTrue(
            viewModel.inheritAppReviewReadSession(
                AppReviewReadSessionProgress(
                    sessionID: "oreilly-visual-page-session",
                    playbackSeconds: 240
                )
            )
        )
    }

    @MainActor
    func testPartialSnapshotNeverDeletesAndCompleteSameAccountMayDelete() {
        withIsolatedStore { store in
            let account = makeAccount("reader-one", complete: true)
            let first = makeBook(firstID, title: "First")
            let second = makeBook(secondID, title: "Second")
            store.mergeScrapedBooks([first, second], account: account)
            store.updateProgress(
                bookID: second.id,
                readerURL:
                    "https://\(proxyHost)/library/view/title/" +
                    "\(secondID)/ch01.html",
                fingerprint: "page-two",
                progressLabel: "20%"
            )

            store.mergeScrapedBooks(
                [makeBook(firstID, title: "First Updated")],
                account: makeAccount("reader-one", complete: false)
            )
            XCTAssertEqual(
                Set(store.books.map(\.id)),
                [first.id, second.id]
            )
            XCTAssertNotNil(store.anchor(for: second.id))

            store.mergeScrapedBooks(
                [makeBook(firstID, title: "First Final")],
                account: account
            )
            XCTAssertEqual(store.books.map(\.id), [first.id])
            XCTAssertNil(store.anchor(for: second.id))
        }
    }

    @MainActor
    func testStoredURLsRemainScrapedURLsInsteadOfSynthesizedISBNURLs() {
        withIsolatedStore { store in
            var book = makeBook(firstID, title: "Agents")
            book.readerURL =
                "https://\(proxyHost)/library/view/custom-slug/" +
                "\(firstID)/continue/?source=history#resume"
            store.mergeScrapedBooks(
                [book],
                account: makeAccount("reader-one", complete: true)
            )
            XCTAssertEqual(store.books.first?.readerURL, book.readerURL)

            let chapter =
                "https://\(proxyHost)/library/view/custom-slug/" +
                "\(firstID)/ch03.html#section-4"
            store.updateProgress(
                bookID: book.id,
                readerURL: chapter,
                fingerprint: "visual-page-3",
                progressLabel: "12%"
            )
            XCTAssertEqual(store.books.first?.lastReaderURL, chapter)
            XCTAssertEqual(store.anchor(for: book.id)?.readerURL, chapter)
        }
    }

    @MainActor
    func testShelfAndVisualAnchorSurviveStoreReload() {
        let suite = "OReillyContractTests.reload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OReillyContractTests.reload-history.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)

        let book = makeBook(firstID, title: "Persistent")
        let first = OReillyLibraryStore(
            defaults: defaults,
            historyStore: history
        )
        first.mergeScrapedBooks(
            [book],
            account: makeAccount("reader-one", complete: true)
        )
        let chapter =
            "https://\(proxyHost)/library/view/title/" +
            "\(firstID)/ch07.html#example"
        first.updateProgress(
            bookID: book.id,
            readerURL: chapter,
            fingerprint: " opaque-visual-page ",
            progressLabel: "40%",
            scrollOffset: 1_240,
            scrollMaximum: 8_000,
            scrollRatio: 0.155,
            sourceParagraphIndex: 17,
            sourceUTF16Start: 84,
            sourceUTF16End: 212
        )

        let reloaded = OReillyLibraryStore(
            defaults: defaults,
            historyStore: history
        )
        XCTAssertTrue(reloaded.hasConnected)
        XCTAssertEqual(reloaded.books.map(\.id), [book.id])
        XCTAssertEqual(reloaded.book(for: book.id)?.lastReaderURL, chapter)
        XCTAssertEqual(
            reloaded.anchor(for: book.id)?.pageFingerprint,
            " opaque-visual-page ",
            "fingerprints are opaque and must not be rewritten"
        )
        XCTAssertEqual(reloaded.anchor(for: book.id)?.scrollOffset, 1_240)
        XCTAssertEqual(reloaded.anchor(for: book.id)?.scrollMaximum, 8_000)
        XCTAssertEqual(reloaded.anchor(for: book.id)?.scrollRatio, 0.155)
        XCTAssertEqual(
            reloaded.anchor(for: book.id)?.sourceParagraphIndex,
            17
        )
        XCTAssertEqual(reloaded.anchor(for: book.id)?.sourceUTF16Start, 84)
        XCTAssertEqual(reloaded.anchor(for: book.id)?.sourceUTF16End, 212)
        XCTAssertEqual(
            reloaded.accountIdentity,
            OReillyAccountIdentity.hash("reader-one")
        )
    }

    @MainActor
    func testAccountChangeIsolatesOldOReillyShelf() {
        withIsolatedStore { store in
            let first = makeBook(firstID, title: "First Account")
            store.mergeScrapedBooks(
                [first],
                account: makeAccount("reader-one", complete: true)
            )
            let second = makeBook(secondID, title: "Second Account")
            store.mergeScrapedBooks(
                [second],
                account: makeAccount("reader-two", complete: false)
            )
            XCTAssertEqual(store.books.map(\.id), [second.id])
            XCTAssertEqual(
                store.accountIdentity,
                OReillyAccountIdentity.hash("reader-two")
            )
        }
    }

    @MainActor
    func testDisconnectClearsOnlyLocalOReillyStateAndPreservesCookies()
        async throws {
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        try await withIsolatedStoreAsync(
            websiteDataStore: websiteDataStore
        ) { store, history in
            let book = makeBook(firstID, title: "Agents")
            store.mergeScrapedBooks(
                [book],
                account: makeAccount("reader-one", complete: true)
            )
            history.record(
                ReadingDocument(
                    id: book.id,
                    title: book.title,
                    sourceKind: .oreilly,
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
            let cookieName = "oreilly_shared_\(UUID().uuidString)"
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .domain: ".oreilly.com",
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
            XCTAssertFalse(
                history.records.contains { $0.sourceKind == .oreilly }
            )
            XCTAssertTrue(
                history.records.contains { $0.id == "retained-text" }
            )
            let cookies = await allCookies(
                in: websiteDataStore.httpCookieStore
            )
            XCTAssertTrue(cookies.contains { $0.name == cookieName })
        }
    }

    @MainActor
    func testOReillyUsesPersistentCommercialWebProfile() {
        let shared = CommercialWebSession.websiteDataStore
        let oreilly = OReillyWebSession.websiteDataStore
        XCTAssertTrue(oreilly.isPersistent)
        XCTAssertEqual(shared.identifier, oreilly.identifier)
    }

    private func makeBook(
        _ contentID: String,
        title: String
    ) -> OReillyBook {
        let url =
            "https://\(proxyHost)/library/view/-/\(contentID)/continue/"
        return OReillyBook(
            id: OReillyBookValidator.stableID(contentID: contentID),
            title: title,
            author: "",
            coverURL: nil,
            readerURL: url,
            progressLabel: "",
            contentID: contentID,
            readerHost: proxyHost,
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReaderURL: nil
        )
    }

    private func makeAccount(
        _ identity: String,
        complete: Bool
    ) -> OReillyAccountInfo {
        OReillyAccountInfo(
            label: "Peninsula Library System Learner",
            identity: OReillyAccountIdentity.hash(identity),
            hasAccountEvidence: true,
            isShelfContext: true,
            isCompleteSnapshot: complete
        )
    }

    @MainActor
    private func withIsolatedStore(
        _ body: (OReillyLibraryStore) throws -> Void
    ) rethrows {
        let suite = "OReillyContractTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OReillyContractTests.history.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)
        try body(
            OReillyLibraryStore(
                defaults: defaults,
                historyStore: history
            )
        )
    }

    @MainActor
    private func withIsolatedStoreAsync(
        websiteDataStore: WKWebsiteDataStore,
        _ body: (
            OReillyLibraryStore,
            HistoryStore
        ) async throws -> Void
    ) async rethrows {
        let suite = "OReillyContractTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OReillyContractTests.history.\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)
        try await body(
            OReillyLibraryStore(
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
