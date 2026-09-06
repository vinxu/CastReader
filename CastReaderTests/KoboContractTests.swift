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

    // MARK: - Initial reader recovery

    func testInitialEmptyReaderReloadsOnceThenSurfacesRepeatedTimeout() {
        let url = URL(string: KoboBookValidator.canonicalReaderURL(bookUUID: primaryUUID))!
        let bookID = KoboBookValidator.stableID(bookUUID: primaryUUID)
        var recovery = KoboInitialReaderRecoveryPolicy()
        guard case .scheduleReload(let ticket) = recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
        ) else { return XCTFail("Initial empty-page timeout must schedule recovery") }

        // More empty payloads while WebKit's reload is delayed must not
        // postpone that action by continually issuing fresh tickets.
        for _ in 0..<4 {
            XCTAssertEqual(recovery.readinessTimedOut(
                readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: true
            ), .wait)
        }
        XCTAssertTrue(recovery.consumeReload(
            ticket,
            readerURL: URL(string: url.absoluteString + "?locale=en-US"),
            bookID: bookID,
            isActive: true
        ))
        XCTAssertFalse(recovery.consumeReload(
            ticket, readerURL: url, bookID: bookID, isActive: true
        ), "Duplicate delayed callbacks must not reload again")
        for _ in 0..<3 {
            XCTAssertEqual(recovery.readinessTimedOut(
                readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
            ), .showError, "A still-empty reader must expose recovery UI, never loop")
        }
    }

    func testInitialReaderCommitDuringReloadDelayCancelsTheReloadPermanently() {
        let url = URL(string: KoboBookValidator.canonicalReaderURL(bookUUID: primaryUUID))!
        let bookID = KoboBookValidator.stableID(bookUUID: primaryUUID)
        var recovery = KoboInitialReaderRecoveryPolicy()
        guard case .scheduleReload(let ticket) = recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
        ) else { return XCTFail("Expected a delayed initial recovery") }

        recovery.pageDidCommit()
        XCTAssertFalse(recovery.consumeReload(
            ticket, readerURL: url, bookID: bookID, isActive: true
        ), "Late initial recovery must not refresh newly readable content")
        XCTAssertEqual(recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
        ), .ignore, "A later manual page's empty DOM is not an initial-open failure")
    }

    func testInitialReaderRecoveryWaitsForExistingRecoveryWithoutSpendingItsBudget() {
        let url = URL(string: KoboBookValidator.canonicalReaderURL(bookUUID: primaryUUID))!
        let bookID = KoboBookValidator.stableID(bookUUID: primaryUUID)
        var recovery = KoboInitialReaderRecoveryPolicy()
        XCTAssertEqual(recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: true
        ), .wait)
        XCTAssertEqual(recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: false, recoveryInProgress: false
        ), .showError)

        guard case .scheduleReload(let ticket) = recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
        ) else { return XCTFail("Waiting must preserve the one automatic attempt") }
        XCTAssertTrue(recovery.consumeReload(
            ticket, readerURL: url, bookID: bookID, isActive: true
        ))
    }

    func testInitialReaderRecoveryCannotFollowLoginOrAnotherBookDuringTheDelay() {
        let url = URL(string: KoboBookValidator.canonicalReaderURL(bookUUID: primaryUUID))!
        let bookID = KoboBookValidator.stableID(bookUUID: primaryUUID)
        let rejected = [
            "https://www.kobo.com/sg/en/signin",
            "https://readnow.kobo.com.evil.example/\(primaryUUID)",
            KoboBookValidator.canonicalReaderURL(bookUUID: secondUUID),
        ]
        for changedURL in rejected {
            var recovery = KoboInitialReaderRecoveryPolicy()
            guard case .scheduleReload(let ticket) = recovery.readinessTimedOut(
                readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
            ) else { return XCTFail("Expected initial recovery before navigation changed") }
            XCTAssertFalse(recovery.consumeReload(
                ticket, readerURL: URL(string: changedURL), bookID: bookID, isActive: true
            ))
            XCTAssertFalse(recovery.consumeReload(
                ticket, readerURL: url, bookID: bookID, isActive: true
            ), "Returning to the original URL cannot revive a rejected ticket")
            XCTAssertEqual(recovery.readinessTimedOut(
                readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
            ), .showError)
        }
    }

    func testInitialReaderRecoveryTicketDoesNotSurviveReopeningTheSameBook() {
        let url = URL(string: KoboBookValidator.canonicalReaderURL(bookUUID: primaryUUID))!
        let bookID = KoboBookValidator.stableID(bookUUID: primaryUUID)
        var recovery = KoboInitialReaderRecoveryPolicy()
        guard case .scheduleReload(let oldTicket) = recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
        ) else { return XCTFail("Expected first reader's delayed recovery") }

        // The bridge replaces this policy on configure, including A -> B -> A.
        recovery = KoboInitialReaderRecoveryPolicy()
        guard case .scheduleReload(let currentTicket) = recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
        ) else { return XCTFail("A new reader owns its own recovery attempt") }
        XCTAssertFalse(recovery.consumeReload(
            oldTicket, readerURL: url, bookID: bookID, isActive: true
        ))
        XCTAssertTrue(recovery.consumeReload(
            currentTicket, readerURL: url, bookID: bookID, isActive: true
        ), "An old callback must not consume the current reader's ticket")
    }

    func testInitialReaderRecoveryDoesNotReloadAfterAppBecomesInactive() {
        let url = URL(string: KoboBookValidator.canonicalReaderURL(bookUUID: primaryUUID))!
        let bookID = KoboBookValidator.stableID(bookUUID: primaryUUID)
        var recovery = KoboInitialReaderRecoveryPolicy()
        guard case .scheduleReload(let ticket) = recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
        ) else { return XCTFail("Expected delayed recovery while active") }
        XCTAssertFalse(recovery.consumeReload(
            ticket, readerURL: url, bookID: bookID, isActive: false
        ))
        XCTAssertFalse(recovery.consumeReload(
            ticket, readerURL: url, bookID: bookID, isActive: true
        ), "Foregrounding must not revive a previously cancelled callback")
        XCTAssertEqual(recovery.readinessTimedOut(
            readerURL: url, bookID: bookID, isActive: true, recoveryInProgress: false
        ), .showError)
    }

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
                    KoboShelfSyncContract.emptyShelfStablePasses - 1,
                completeTraversal: true
            )
        )
        XCTAssertTrue(
            KoboShelfSyncContract.canCommit(
                bookCount: 0,
                account: account,
                reachedEnd: true,
                stableEndPasses:
                    KoboShelfSyncContract.emptyShelfStablePasses,
                completeTraversal: true
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
                    KoboShelfSyncContract.emptyShelfStablePasses,
                completeTraversal: true
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

    @MainActor
    func testUnscopedProductionStoreCannotReportAnUnsavedShelfAsConnected() {
        let suite = "KoboContractTests.unscoped.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let store = KoboLibraryStore(defaults: defaults, historyStore: history,
                                     websiteDataStore: .nonPersistent(), usesLegacyStorageWhenUnscoped: false)
        store.mergeScrapedBooks([makeBook(primaryUUID, title: "Unsaved")],
                                account: makeAccount("synthetic@example.com", complete: true))
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.hasConnected)
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertNil(defaults.data(forKey: "kobo.library.books.v1"))
    }

    @MainActor
    func testDelayedSyncCannotWriteAfterAccountSwitchOrSwitchBack() throws {
        try withIsolatedStore { store in
            let a = try XCTUnwrap(AccountContentScope(account: UserAccount(id: "local-a", provider: "google")))
            let b = try XCTUnwrap(AccountContentScope(account: UserAccount(id: "local-b", provider: "google")))
            let account = makeAccount("synthetic@example.com", complete: true)
            let first = makeBook(primaryUUID, title: "Account A")
            let second = makeBook(secondUUID, title: "Account B")
            store.activateAccountScope(a)
            let oldBoundary = try XCTUnwrap(store.captureStorageBoundary())
            store.mergeScrapedBooks([first], account: account, expectedStorageBoundary: oldBoundary)
            store.activateAccountScope(a)
            XCTAssertTrue(store.isCurrentStorageBoundary(oldBoundary), "Reusing the current scope preserves active work")

            store.activateAccountScope(b)
            let newBoundary = try XCTUnwrap(store.captureStorageBoundary())
            store.mergeScrapedBooks([second], account: account, expectedStorageBoundary: newBoundary)
            store.mergeScrapedBooks([first], account: account, expectedStorageBoundary: oldBoundary)
            XCTAssertNotNil(store.lastError)
            XCTAssertEqual(store.books.map(\.id), [second.id])

            store.activateAccountScope(a)
            XCTAssertFalse(store.isCurrentStorageBoundary(oldBoundary), "A → B → A must not revive old work")
            store.mergeScrapedBooks([second], account: account, expectedStorageBoundary: oldBoundary)
            XCTAssertNotNil(store.lastError)
            XCTAssertEqual(store.books.map(\.id), [first.id], "Persisted A must survive a delayed result")

            store.deactivateAccountScope()
            XCTAssertFalse(store.isCurrentStorageBoundary(oldBoundary))
            store.mergeScrapedBooks([first], account: account, expectedStorageBoundary: oldBoundary)
            XCTAssertFalse(store.hasConnected)
            XCTAssertTrue(store.books.isEmpty)
        }
    }

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
                    <source data-srcset="https://cdn.kobo.example/two-tickets@2x.jpg 2x">
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

    // These are synthetic compatibility fixtures, not captured Kobo HTML.
    // Every scan/action executes in WKWebView so DOM visibility, URL parsing,
    // accessibility attributes and click dispatch use the production engine.
    func testFourPageShelfCollectsEveryPageAndDeduplicatesRepeatedBooks() async throws {
        let view = try await loadShelf(paginatedShelfFixture())
        var booksByID: [String: KoboBook] = [:]
        var fingerprints = Set<String>()

        for page in 1...4 {
            let raw = try await scan(view)
            let pagination = try XCTUnwrap(raw["pagination"] as? [String: Any])
            XCTAssertEqual(pagination["currentPage"] as? Int, page)
            XCTAssertEqual(pagination["totalPages"] as? Int, 4)
            XCTAssertEqual(pagination["hasPagination"] as? Bool, true)
            XCTAssertEqual(pagination["isFirstPage"] as? Bool, page == 1)
            XCTAssertEqual(pagination["isLastPage"] as? Bool, page == 4)
            XCTAssertEqual(raw["atScrollEnd"] as? Bool, true)
            XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, page == 4)
            let fingerprint = try XCTUnwrap(raw["pageFingerprint"] as? String)
            XCTAssertFalse(fingerprint.isEmpty)
            XCTAssertTrue(fingerprints.insert(fingerprint).inserted)

            let result = KoboScanResult(raw)
            XCTAssertTrue(result.authenticated)
            XCTAssertEqual(result.books.count, 2)
            for book in result.books {
                booksByID[book.id] = book
            }

            // Repeated scans only inspect/scroll the current page. Advancing
            // before native code receives its books would lose that page.
            for _ in 0..<3 {
                let repeated = try await scan(view)
                XCTAssertEqual(repeated["pageFingerprint"] as? String, fingerprint)
                XCTAssertEqual(repeated["isCompleteSnapshot"] as? Bool, page == 4)
            }
            let beforeAction = try await view.evaluateJavaScript("window.__fixtureClicks")
            XCTAssertEqual(beforeAction as? Int, page - 1)

            let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
            XCTAssertEqual(advanced as? Bool, page < 4)
            let afterAction = try await view.evaluateJavaScript("window.__fixtureClicks")
            XCTAssertEqual(afterAction as? Int, min(page, 3))
        }

        XCTAssertEqual(booksByID.count, 7, "The first book on page two repeats page one's last book")
        XCTAssertEqual(Set(booksByID.values.map(\.title)), Set((1...7).map { "Synthetic Book \($0)" }))
    }

    func testMobileLibraryScanUsesServerAuthenticationWithHiddenGenericAccountMenu() async throws {
        let body = KoboMobileLibraryFixture.body(isLoggedIn: true)
        let view = try await loadShelf("<!doctype html><html><body>\(body)</body></html>")
        let raw = try await scan(view)
        let result = KoboScanResult(raw)
        XCTAssertTrue(result.authenticated)
        XCTAssertEqual(raw["authRequired"] as? Bool, false)
        XCTAssertEqual(raw["hasAccountEvidence"] as? Bool, true)
        XCTAssertEqual(result.books.count, 1)
        XCTAssertEqual(result.books.first?.bookUUID, KoboMobileLibraryFixture.bookUUID)
        XCTAssertEqual(result.books.first?.title, KoboMobileLibraryFixture.title)
        XCTAssertEqual(result.books.first?.author, KoboMobileLibraryFixture.author)
        let account = try XCTUnwrap(result.account)
        XCTAssertNil(account.identity, "Generic Sign out/My Account text cannot identify a provider account")

        _ = try await view.evaluateJavaScript("document.querySelector('.nav-user-account').style.display = 'block'")
        let expanded = KoboScanResult(try await scan(view))
        XCTAssertTrue(expanded.authenticated)
        XCTAssertEqual(expanded.books.map(\.id), result.books.map(\.id))
        XCTAssertNil(expanded.account?.identity)
    }

    func testMobileLibraryScanRejectsExplicitSignedOutStateWithResidualBooks() async throws {
        let body = KoboMobileLibraryFixture.body(isLoggedIn: false)
        let view = try await loadShelf("<!doctype html><html><body>\(body)</body></html>")
        for showStaleMenu in [false, true] {
            if showStaleMenu {
                _ = try await view.evaluateJavaScript(
                    """
                    document.querySelector('.nav-user-account').style.display = 'block';
                    document.querySelector('a[href*="signin"]').remove();
                    """
                )
            }
            let raw = try await scan(view)
            XCTAssertEqual(raw["authenticated"] as? Bool, false)
            XCTAssertEqual(raw["authRequired"] as? Bool, true)
            XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false)
            XCTAssertFalse(KoboScanResult(raw).authenticated)
        }
    }

    func testMobileLibraryScanDoesNotUseRecommendedCardsAsShelfEvidence() async throws {
        let body = KoboMobileLibraryFixture.body(isLoggedIn: true, includesLibraryRoot: false)
        let view = try await loadShelf("<!doctype html><html><body>\(body)</body></html>")
        let raw = try await scan(view)
        XCTAssertEqual(raw["authenticated"] as? Bool, false)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false)
    }

    func testMobileEmptyLibraryRetainsAuthenticationWithoutInventingAnAccountIdentity() async throws {
        let body = KoboMobileLibraryFixture.body(isLoggedIn: true, includesBook: false)
        let view = try await loadShelf("<!doctype html><html><body>\(body)</body></html>")
        let raw = try await scan(view)
        let result = KoboScanResult(raw)
        XCTAssertTrue(result.authenticated)
        XCTAssertTrue(result.books.isEmpty)
        XCTAssertNotNil(result.account)
        XCTAssertNil(result.account?.identity)
    }

    func testShelfStartingOnPageThreeCanResetToFirstPage() async throws {
        let view = try await loadShelf(paginatedShelfFixture(initialPage: 3))
        let before = try await scan(view)
        let pagination = try XCTUnwrap(before["pagination"] as? [String: Any])
        XCTAssertEqual(pagination["isFirstPage"] as? Bool, false)
        XCTAssertEqual(pagination["canGoToFirstPage"] as? Bool, true)
        XCTAssertEqual(before["isCompleteSnapshot"] as? Bool, false)

        let reset = try await view.evaluateJavaScript(KoboWebScripts.resetShelfToFirstPage)
        XCTAssertEqual(reset as? Bool, true)
        let after = try await scan(view)
        let afterPagination = try XCTUnwrap(after["pagination"] as? [String: Any])
        XCTAssertEqual(afterPagination["currentPage"] as? Int, 1)
        XCTAssertEqual(afterPagination["isFirstPage"] as? Bool, true)
        XCTAssertEqual(after["isCompleteSnapshot"] as? Bool, false)
        let clickCount = try await view.evaluateJavaScript("window.__fixtureClicks")
        XCTAssertEqual(clickCount as? Int, 1)

        let unnecessaryReset = try await view.evaluateJavaScript(KoboWebScripts.resetShelfToFirstPage)
        XCTAssertEqual(unnecessaryReset as? Bool, false)
    }

    func testCursorPaginationWithoutPageNumbersCanReachItsExplicitLastPage() async throws {
        let view = try await loadShelf(paginatedShelfFixture(numbered: false))
        var ids = Set<String>()
        var pageKeys = Set<String>()
        for page in 1...4 {
            let raw = try await scan(view)
            let pagination = try XCTUnwrap(raw["pagination"] as? [String: Any])
            XCTAssertEqual(pagination["hasPagination"] as? Bool, true)
            XCTAssertEqual(pagination["blocked"] as? Bool, false)
            XCTAssertEqual(pagination["isFirstPage"] as? Bool, page == 1)
            XCTAssertEqual(pagination["isLastPage"] as? Bool, page == 4)
            XCTAssertEqual(pagination["hasNextPage"] as? Bool, page < 4)
            XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, page == 4)
            let key = try XCTUnwrap(pagination["pageKey"] as? String)
            XCTAssertFalse(key.isEmpty)
            XCTAssertTrue(pageKeys.insert(key).inserted)
            let cursor = try await view.evaluateJavaScript("new URL(location.href).searchParams.get('cursor')")
            XCTAssertEqual(cursor as? String, String(page))
            ids.formUnion(KoboScanResult(raw).books.map(\.id))

            let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
            XCTAssertEqual(advanced as? Bool, page < 4)
            let repeatedAction = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
            XCTAssertEqual(repeatedAction as? Bool, false, "Each observation authorizes at most one click")
        }
        XCTAssertEqual(ids.count, 7)
        let clickCount = try await view.evaluateJavaScript("window.__fixtureClicks")
        XCTAssertEqual(clickCount as? Int, 3)
    }

    func testTemporarilyDisabledNextDoesNotMakeFirstPageComplete() async throws {
        for attribute in ["disabled", "aria-disabled=\"true\""] {
            let view = try await loadShelf(paginatedShelfFixture())
            _ = try await view.evaluateJavaScript(
                """
                document.querySelector('nav').innerHTML =
                  '<a href="?page=1" aria-current="page">1</a>' +
                  '<span>Page 1 of 4</span>' +
                  '<button rel="next" \(attribute)>Next</button>';
                """
            )
            let raw = try await scan(view)
            let pagination = try XCTUnwrap(raw["pagination"] as? [String: Any])
            XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false, attribute)
            XCTAssertEqual(pagination["isLastPage"] as? Bool, false, attribute)
            let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
            XCTAssertEqual(advanced as? Bool, false, attribute)
            let clickCount = try await view.evaluateJavaScript("window.__fixtureClicks")
            XCTAssertEqual(clickCount as? Int, 0, attribute)
        }
    }

    func testSlowLastPageWaitsForLoadingToSettle() async throws {
        let view = try await loadShelf(paginatedShelfFixture(initialPage: 3))
        _ = try await scan(view)
        _ = try await view.evaluateJavaScript("window.__fixtureDelayNext = true")
        let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
        XCTAssertEqual(advanced as? Bool, true)

        let waiting = try await scan(view)
        XCTAssertEqual(waiting["hasPendingWork"] as? Bool, true)
        XCTAssertEqual(waiting["isCompleteSnapshot"] as? Bool, false)
        let secondAdvance = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
        XCTAssertEqual(secondAdvance as? Bool, false)

        _ = try await view.evaluateJavaScript("window.__fixtureFinishLoading()")
        let settled = try await scan(view)
        let pagination = try XCTUnwrap(settled["pagination"] as? [String: Any])
        XCTAssertEqual(pagination["currentPage"] as? Int, 4)
        XCTAssertEqual(settled["hasPendingWork"] as? Bool, false)
        XCTAssertEqual(settled["isCompleteSnapshot"] as? Bool, true)
        XCTAssertEqual(KoboScanResult(settled).books.map(\.title), ["Synthetic Book 6", "Synthetic Book 7"])
        let clickCount = try await view.evaluateJavaScript("window.__fixtureClicks")
        XCTAssertEqual(clickCount as? Int, 1)
    }

    func testShelfPaginationDoesNotClickRecommendationNext() async throws {
        let view = try await loadShelf(paginatedShelfFixture())
        _ = try await view.evaluateJavaScript(
            """
            document.querySelector('nav').remove();
            document.querySelector('aside').innerHTML =
              '<h2>Recommended books</h2><button aria-label="Next">Next</button>';
            """
        )
        let raw = try await scan(view)
        let pagination = try XCTUnwrap(raw["pagination"] as? [String: Any])
        XCTAssertEqual(pagination["hasPagination"] as? Bool, false)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, true)
        let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
        XCTAssertEqual(advanced as? Bool, false)
        let recommendationClicks = try await view.evaluateJavaScript("window.__fixtureRecommendationClicks")
        XCTAssertEqual(recommendationClicks as? Int, 0)

        // A recommendation carousel can itself expose a semantic pagination
        // nav and rel=next. Neither form belongs to the user's library pages.
        _ = try await view.evaluateJavaScript(
            """
            document.querySelector('aside').innerHTML =
              '<h2>Recommended books</h2><nav aria-label="Pagination">' +
              '<a href="?page=1" aria-current="page">1</a> ' +
              '<a rel="next" href="?page=2">Next</a></nav>';
            """
        )
        let withRecommendationNav = try await scan(view)
        let recommendationPagination = try XCTUnwrap(withRecommendationNav["pagination"] as? [String: Any])
        XCTAssertEqual(recommendationPagination["hasPagination"] as? Bool, false)
        XCTAssertEqual(withRecommendationNav["isCompleteSnapshot"] as? Bool, true)
        let advancedRecommendation = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
        XCTAssertEqual(advancedRecommendation as? Bool, false)
        let finalRecommendationClicks = try await view.evaluateJavaScript("window.__fixtureRecommendationClicks")
        XCTAssertEqual(finalRecommendationClicks as? Int, 0)
    }

    func testUnsafePaginationDestinationsCannotBeClickedOrCompleteTheShelf() async throws {
        let destinations = [
            "https://evil.example/library/books?page=2",
            "https://www.kobo.com.evil.example/sg/en/library/books?page=2",
            "http://www.kobo.com/sg/en/library/books?page=2",
            "https://user@www.kobo.com/sg/en/library/books?page=2",
            "https://www.kobo.com:444/sg/en/library/books?page=2",
            "https://www.kobo.com/sg/en/store/books?page=2",
            "https://www.kobo.com/sg/en/library/books?page=2&filter=archived",
            "javascript:window.__fixtureUnsafeNavigation=true",
        ]
        for destination in destinations {
            let view = try await loadShelf(paginatedShelfFixture())
            _ = try await view.evaluateJavaScript(
                """
                document.querySelector('nav').innerHTML =
                  '<a href="?page=1" aria-current="page">1</a>' +
                  '<span>Page 1 of 4</span>' +
                  '<a rel="next" href="\(destination)">Next</a>';
                """
            )
            let raw = try await scan(view)
            XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false, destination)
            let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
            XCTAssertEqual(advanced as? Bool, false, destination)
            let clickCount = try await view.evaluateJavaScript("window.__fixtureClicks")
            XCTAssertEqual(clickCount as? Int, 0, destination)
        }
    }

    func testUnknownPaginationBlocksCompleteSnapshot() async throws {
        let view = try await loadShelf(paginatedShelfFixture())
        _ = try await view.evaluateJavaScript(
            """
            document.querySelector('nav').innerHTML = '<button>Browse more</button>';
            """
        )
        let raw = try await scan(view)
        let pagination = try XCTUnwrap(raw["pagination"] as? [String: Any])
        XCTAssertEqual(pagination["hasPagination"] as? Bool, true)
        XCTAssertEqual(pagination["blocked"] as? Bool, true)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, false)
        let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
        XCTAssertEqual(advanced as? Bool, false)
    }

    func testKoboShowPageSizeControlAloneIsNotShelfPagination() async throws {
        let html = paginatedShelfFixture().replacingOccurrences(of: "</body>", with: showPageSizeFixture + "</body>")
        let view = try await loadShelf(html)
        _ = try await view.evaluateJavaScript("document.querySelector('main > nav').remove()")
        let raw = try await scan(view)
        let pagination = try XCTUnwrap(raw["pagination"] as? [String: Any])
        XCTAssertEqual(pagination["hasPagination"] as? Bool, false)
        XCTAssertEqual(pagination["isFirstPage"] as? Bool, true)
        XCTAssertEqual(pagination["isLastPage"] as? Bool, true)
        XCTAssertEqual(pagination["blocked"] as? Bool, false)
        XCTAssertEqual(raw["isCompleteSnapshot"] as? Bool, true)
        let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
        XCTAssertEqual(advanced as? Bool, false)
        let showClicks = try await view.evaluateJavaScript("window.__fixtureShowClicks")
        XCTAssertEqual(showClicks as? Int, 0)
    }

    func testKoboShowPageSizeControlDoesNotInflateRealTwoPagePagination() async throws {
        let html = paginatedShelfFixture().replacingOccurrences(of: "</body>", with: showPageSizeFixture + "</body>")
        let view = try await loadShelf(html)
        _ = try await view.evaluateJavaScript(
            """
            document.querySelector('main > nav').className = 'pagination';
            document.querySelector('main > nav').innerHTML =
              '<a href="?page=1" aria-current="page">1</a> ' +
              '<a href="?page=2">2</a> <a rel="next" href="?page=2">Next</a>';
            """
        )
        let first = try await scan(view)
        let firstPagination = try XCTUnwrap(first["pagination"] as? [String: Any])
        XCTAssertEqual(firstPagination["currentPage"] as? Int, 1)
        XCTAssertEqual(firstPagination["totalPages"] as? Int, 2)
        XCTAssertEqual(firstPagination["hasNextPage"] as? Bool, true)
        XCTAssertEqual(firstPagination["blocked"] as? Bool, false)
        XCTAssertEqual(first["isCompleteSnapshot"] as? Bool, false)
        let advanced = try await view.evaluateJavaScript(KoboWebScripts.advanceShelfPage)
        XCTAssertEqual(advanced as? Bool, true)

        _ = try await view.evaluateJavaScript(
            """
            document.querySelector('main > nav').innerHTML =
              '<a href="?page=1">1</a> <a href="?page=2" aria-current="page">2</a> ' +
              '<button rel="next" disabled>Next</button>';
            """
        )
        let last = try await scan(view)
        let lastPagination = try XCTUnwrap(last["pagination"] as? [String: Any])
        XCTAssertEqual(lastPagination["currentPage"] as? Int, 2)
        XCTAssertEqual(lastPagination["totalPages"] as? Int, 2)
        XCTAssertEqual(lastPagination["isLastPage"] as? Bool, true)
        XCTAssertEqual(last["isCompleteSnapshot"] as? Bool, true)
        let showClicks = try await view.evaluateJavaScript("window.__fixtureShowClicks")
        XCTAssertEqual(showClicks as? Int, 0)
    }

    /// Observed Kobo mobile page-size structure, populated with synthetic UI.
    /// Its "pagination" class names and visible 24 are not page numbers.
    private var showPageSizeFixture: String {
        """
        <div class="pagination-filter-container">
          <div class="pagination-controls filter-chip"><span>Show:</span>
            <button class="filter-btn">24</button>
            <ul id="pagination-option" class="filter-list" style="display:none">
              <li><a class="filter-item" href="?pageSize=24" aria-label="Show: 24">24</a></li>
              <li><a class="filter-item" href="?pageSize=36" aria-label="Show: 36">36</a></li>
              <li><a class="filter-item" href="?pageSize=48" aria-label="Show: 48">48</a></li>
              <li><a class="filter-item" href="?pageSize=60" aria-label="Show: 60">60</a></li>
            </ul>
          </div>
        </div>
        <script>
          window.__fixtureShowClicks = 0;
          document.querySelector('.pagination-filter-container').addEventListener('click', function (event) {
            event.preventDefault();
            window.__fixtureShowClicks += 1;
          });
        </script>
        """
    }

    private func scan(_ view: WKWebView) async throws -> [String: Any] {
        let value = try await view.evaluateJavaScript(KoboWebScripts.libraryScan)
        return try XCTUnwrap(value as? [String: Any])
    }

    /// Standard pagination deliberately includes a repeated UUID across pages.
    /// Anchors keep real same-origin hrefs, but the fixture intercepts their
    /// clicks and renders locally so the regression suite makes no web request.
    private func paginatedShelfFixture(initialPage: Int = 1, numbered: Bool = true) -> String {
        """
        <!doctype html><html lang="en"><head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>body { margin: 8px; } article { margin: 8px 0; } h3 { margin: 4px 0; }</style>
        </head><body>
          <header><a href="/logout" data-email="reader@example.com">Account</a></header>
          <main aria-label="My books"><section id="shelf"></section><nav aria-label="Pagination"></nav></main>
          <aside></aside>
          <script>
            window.__fixtureClicks = 0;
            window.__fixtureRecommendationClicks = 0;
            window.__fixtureDelayNext = false;
            var fixturePages = [[1, 2], [2, 3], [4, 5], [6, 7]];
            window.__fixtureRender = function (page) {
              window.__fixturePage = page;
              if (!\(numbered ? "true" : "false")) {
                // Emulate cursor-based SPA navigation without network I/O.
                // Book hydration alone must never change native page identity.
                history.replaceState(null, '', '?cursor=' + page);
              }
              document.querySelector('#shelf').innerHTML = fixturePages[page - 1].map(function (number) {
                var uuid = 'f000000' + number + '-1111-4111-8111-00000000000' + number;
                return '<article role="listitem" data-testid="book-card">' +
                  '<h3 data-testid="book-title">Synthetic Book ' + number + '</h3>' +
                  '<span data-testid="book-author">Test Author</span> ' +
                  '<a href="https://readnow.kobo.com/' + uuid + '">Read Now</a></article>';
              }).join('');
              var links = [];
              if (\(numbered ? "true" : "false")) {
                for (var number = 1; number <= 4; number += 1) {
                  links.push('<a href="?page=' + number + '"' +
                    (number === page ? ' aria-current="page"' : '') + '>' + number + '</a>');
                }
                links.push(page < 4
                  ? '<a rel="next" href="?page=' + (page + 1) + '">Next</a>'
                  : '<button rel="next" disabled aria-disabled="true">Next</button>');
              } else {
                links.push(page === 1
                  ? '<button rel="prev" disabled>Previous</button>'
                  : '<a rel="prev" href="?cursor=' + (page - 1) + '">Previous</a>');
                links.push(page < 4
                  ? '<a rel="next" href="?cursor=' + (page + 1) + '">Next</a>'
                  : '<button rel="next" disabled aria-disabled="true">Next</button>');
              }
              document.querySelector('nav').innerHTML = links.join(' ');
            };
            document.addEventListener('click', function (event) {
              var control = event.target.closest('a, button');
              if (!control) return;
              if (control.closest('aside')) {
                event.preventDefault();
                window.__fixtureRecommendationClicks += 1;
              } else if (control.closest('nav')) {
                event.preventDefault();
                window.__fixtureClicks += 1;
                var params = new URL(control.href, document.baseURI).searchParams;
                var targetPage = Number(params.get('page') || params.get('cursor'));
                if (!(targetPage >= 1 && targetPage <= 4)) return;
                window.__fixtureRender(targetPage);
                if (window.__fixtureDelayNext) {
                  document.querySelector('main').setAttribute('aria-busy', 'true');
                  window.__fixtureFinishLoading = function () {
                    document.querySelector('main').removeAttribute('aria-busy');
                    window.__fixtureDelayNext = false;
                  };
                }
              }
            });
            window.__fixtureRender(\(initialPage));
          </script>
        </body></html>
        """
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
