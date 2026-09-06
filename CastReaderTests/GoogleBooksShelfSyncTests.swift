import WebKit
import XCTest
@testable import CastReader

final class GoogleBooksShelfSyncTests: XCTestCase {
    func testHundredBookVirtualShelfCanTraverseMoreThanTheOldTwentyFourPassLimit() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        for window in 0..<50 {
            let result = snapshot(
                ids: [window * 2 + 1, window * 2 + 2],
                position: Double(window * 80), extent: 3_920
            )
            XCTAssertEqual(scan.observe(result, now: Double(window)), .wait)
            XCTAssertNil(scan.account)
        }
        let bottom = snapshot(ids: [99, 100], position: 3_920, extent: 3_920)
        XCTAssertEqual(scan.observe(bottom, now: 50), .wait)
        XCTAssertEqual(scan.observe(bottom, now: 51), .wait)
        XCTAssertEqual(scan.observe(bottom, now: 52), .complete)
        XCTAssertEqual(scan.books.count, 100)
        XCTAssertTrue(scan.completeTraversal)
        XCTAssertTrue(scan.account?.isCompleteSnapshot == true)
    }

    func testPendingLazyCardsCannotCompleteAnOtherwiseStableBottom() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        for pass in 0..<8 {
            XCTAssertEqual(scan.observe(snapshot(ids: [1], pending: true), now: Double(pass)), .wait)
        }
        XCTAssertNil(scan.account)
        for pass in 8..<11 {
            XCTAssertEqual(scan.observe(snapshot(ids: [1, 2]), now: Double(pass)), .wait)
        }
        XCTAssertEqual(scan.observe(snapshot(ids: [1, 2]), now: 11), .complete)
        XCTAssertEqual(scan.books.count, 2)
    }

    func testMetadataHydrationRestartsStabilityWithoutLosingEarlierCoverAndAuthor() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(scan.observe(snapshot(ids: [1], author: "First Author"), now: 0), .wait)
        XCTAssertEqual(scan.observe(snapshot(ids: [1], author: "First Author"), now: 1), .wait)
        for pass in 2..<5 {
            XCTAssertEqual(scan.observe(snapshot(ids: [1], author: "Final Author"), now: Double(pass)), .wait)
        }
        XCTAssertEqual(scan.observe(snapshot(ids: [1], author: ""), now: 5), .complete)
        XCTAssertEqual(scan.books["googlebooks:GBFIX0001"]?.author, "Final Author")
    }

    func testEmptyShelfNeedsTenStablePassesAndARealAccountIdentity() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        for pass in 0..<9 {
            XCTAssertEqual(scan.observe(snapshot(ids: [], explicitEmpty: true), now: Double(pass)), .wait)
        }
        XCTAssertEqual(scan.observe(snapshot(ids: [], explicitEmpty: true), now: 9), .complete)
        XCTAssertEqual(scan.books.count, 0)
        XCTAssertNotNil(scan.account?.identity)

        var unidentified = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(unidentified.observe(snapshot(ids: [], identity: nil, explicitEmpty: true), now: 0), .failed("account_unverified"))
        XCTAssertNil(unidentified.account)
    }

    func testSilentUnrecognizedEmptyDOMTimesOutInsteadOfBecomingACompleteEmptyShelf() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        let unrecognized = snapshot(ids: [])
        XCTAssertFalse(unrecognized.hasExplicitEmptyShelf)
        XCTAssertFalse(unrecognized.isCompleteSnapshot)
        for pass in 0..<12 {
            XCTAssertEqual(scan.observe(unrecognized, now: Double(pass)), .wait)
        }
        XCTAssertEqual(scan.observe(unrecognized, now: 12), .failed("unrecognized_shelf_content"))
        XCTAssertFalse(scan.completeTraversal)
        XCTAssertNil(scan.account)
    }

    func testInitiallyEmptyHydratingDOMCanStillProduceBooksBeforeTheBoundedTimeout() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        for pass in 0..<5 {
            XCTAssertEqual(scan.observe(snapshot(ids: []), now: Double(pass)), .wait)
        }
        for pass in 5..<8 {
            XCTAssertEqual(scan.observe(snapshot(ids: [1, 2]), now: Double(pass)), .wait)
        }
        XCTAssertEqual(scan.observe(snapshot(ids: [1, 2]), now: 8), .complete)
        XCTAssertEqual(scan.books.count, 2)
    }

    func testUnrecognizedCardsBlockBothPopulatedAndExplicitEmptyCompletion() {
        for ids in [[1], []] {
            var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
            let result = snapshot(ids: ids, explicitEmpty: ids.isEmpty, unrecognizedCandidates: 1)
            XCTAssertFalse(result.isCompleteSnapshot)
            for pass in 0..<12 {
                XCTAssertEqual(scan.observe(result, now: Double(pass)), .wait)
            }
            XCTAssertEqual(scan.observe(result, now: 12), .failed("unrecognized_shelf_content"))
            XCTAssertNil(scan.account)
        }
    }

    func testUnknownCardThatFinishesHydratingCanCompleteWithAllRecognizedBooks() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(scan.observe(snapshot(ids: [1], unrecognizedCandidates: 1), now: 0), .wait)
        for pass in 1..<4 {
            XCTAssertEqual(scan.observe(snapshot(ids: [1, 2]), now: Double(pass)), .wait)
        }
        XCTAssertEqual(scan.observe(snapshot(ids: [1, 2]), now: 4), .complete)
        XCTAssertEqual(scan.books.count, 2)
    }

    func testUnknownMiddleViewportMustRecoverInPlaceBeforeTraversalContinues() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(scan.observe(snapshot(ids: [1], extent: 160, unrecognizedCandidates: 1), now: 0), .wait)
        XCTAssertEqual(scan.observe(snapshot(ids: [1], extent: 160, unrecognizedCandidates: 1), now: 1), .wait)
        XCTAssertEqual(scan.observe(snapshot(ids: [1, 2], extent: 160), now: 2), .wait)
        XCTAssertEqual(scan.observe(snapshot(ids: [3], position: 80, extent: 160), now: 3), .wait)
        for pass in 4..<7 {
            XCTAssertEqual(scan.observe(snapshot(ids: [4], position: 160, extent: 160), now: Double(pass)), .wait)
        }
        XCTAssertEqual(scan.observe(snapshot(ids: [4], position: 160, extent: 160), now: 7), .complete)
        XCTAssertEqual(scan.books.count, 4, "The card that initially failed extraction must be included")
    }

    func testPersistentUnknownMiddleViewportFailsWithoutWaitingForTheShelfEnd() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        let middle = snapshot(ids: [1], extent: 160, unrecognizedCandidates: 1)
        XCTAssertFalse(middle.atScrollEnd)
        for pass in 0..<12 {
            XCTAssertEqual(scan.observe(middle, now: Double(pass)), .wait)
        }
        XCTAssertEqual(scan.observe(middle, now: 12), .failed("unrecognized_shelf_content"))
        XCTAssertNil(scan.account)
    }

    func testScrollingPastAnUnknownCardCannotHideTheIncompleteViewport() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(scan.observe(snapshot(ids: [1], extent: 80, unrecognizedCandidates: 1), now: 0), .wait)
        XCTAssertEqual(scan.observe(snapshot(ids: [3], position: 80, extent: 80), now: 1), .failed("unrecognized_card_skipped"))
        XCTAssertFalse(scan.completeTraversal)
        XCTAssertNil(scan.account)
        XCTAssertEqual(scan.books.count, 1)
    }

    func testTemporaryBlankViewportDoesNotReleaseAnUnknownCardPosition() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        _ = scan.observe(snapshot(ids: [1], extent: 80, unrecognizedCandidates: 1), now: 0)
        XCTAssertEqual(scan.observe(snapshot(ids: [], extent: 80, pending: true), now: 1), .wait)
        XCTAssertEqual(scan.observe(snapshot(ids: [2], position: 80, extent: 80), now: 2), .failed("unrecognized_card_skipped"))
        XCTAssertNil(scan.account)
    }

    func testStartingBelowTheFirstViewportOrSkippingAViewportCannotCommit() {
        var startedBelowTop = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(startedBelowTop.observe(
            snapshot(ids: [50], position: 80, extent: 300), now: 0
        ), .failed("shelf_start_unverified"))

        var skipped = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(skipped.observe(snapshot(ids: [1], extent: 300), now: 0), .wait)
        XCTAssertEqual(skipped.observe(
            snapshot(ids: [99], position: 300, extent: 300), now: 1
        ), .failed("scroll_traversal_interrupted"))
        XCTAssertFalse(skipped.completeTraversal)
    }

    func testGoogleAccountSwitchAndSignOutAbortBeforeMergingLaterCards() {
        var switched = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(switched.observe(snapshot(ids: [1], extent: 80), now: 0), .wait)
        XCTAssertEqual(switched.observe(snapshot(
            ids: [2], position: 80, extent: 80, identity: "other@example.invalid"
        ), now: 1), .failed("account_changed"))
        XCTAssertEqual(Set(switched.books.keys), ["googlebooks:GBFIX0001"])
        XCTAssertNil(switched.account)

        var signedOut = GoogleBooksShelfScanPolicy(startedAt: 0)
        _ = signedOut.observe(snapshot(ids: [1], extent: 80), now: 0)
        var login = snapshot(ids: [2], position: 80, extent: 80)
        login.authRequired = true
        login.authenticated = false
        XCTAssertEqual(signedOut.observe(login, now: 1), .failed("account_unverified"))
        XCTAssertEqual(Set(signedOut.books.keys), ["googlebooks:GBFIX0001"])
    }

    func testUnsupportedPaginationAndGlobalTimeoutPreserveAnUncommittableScan() {
        var unsupported = GoogleBooksShelfScanPolicy(startedAt: 0)
        var page = snapshot(ids: [1])
        page.hasUnsupportedPagination = true
        XCTAssertEqual(unsupported.observe(page, now: 0), .failed("pagination_unverified"))
        var timedOut = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(timedOut.observe(snapshot(ids: [1]), now: 181), .failed("scan_timeout"))
        XCTAssertNil(timedOut.account)
    }

    func testActiveShelfFilterCannotCompleteOrConfirmAnEarlierFullScan() {
        var raw = rawSnapshot(ids: [1])
        raw["hasActiveShelfFilter"] = true
        let filtered = GoogleBooksScanResult(raw)
        XCTAssertTrue(filtered.hasActiveShelfFilter)
        XCTAssertFalse(filtered.isCompleteSnapshot)
        XCTAssertFalse(filtered.account?.isCompleteSnapshot == true)
        var partial = GoogleBooksShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(partial.observe(filtered, now: 0), .failed("active_shelf_filter"))
        XCTAssertNil(partial.account)

        var completed = GoogleBooksShelfScanPolicy(startedAt: 0)
        let fullShelf = snapshot(ids: [1])
        XCTAssertFalse(fullShelf.hasActiveShelfFilter, "Older raw payloads must decode without a filter flag")
        for pass in 0..<3 {
            XCTAssertEqual(completed.observe(fullShelf, now: Double(pass)), .wait)
        }
        XCTAssertEqual(completed.observe(fullShelf, now: 3), .complete)
        XCTAssertTrue(completed.matchesCurrentAccount(fullShelf))
        XCTAssertFalse(completed.matchesCurrentAccount(filtered), "A filter selected after scanning must invalidate Sync")
    }

    func testMalformedCardDowngradesDeclaredCompleteSnapshotInsteadOfErasingBooks() {
        var raw = rawSnapshot(ids: [1])
        var cards = raw["books"] as! [[String: Any]]
        cards.append(["title": "Still hydrating", "readerURL": "https://example.invalid/book"])
        raw["books"] = cards
        let result = GoogleBooksScanResult(raw)
        XCTAssertEqual(result.books.count, 1)
        XCTAssertTrue(result.hasInvalidBooks)
        XCTAssertFalse(result.isCompleteSnapshot)
        XCTAssertFalse(result.account?.isCompleteSnapshot == true)
        raw["books"] = [42]
        let malformedArray = GoogleBooksScanResult(raw)
        XCTAssertTrue(malformedArray.hasInvalidBooks)
        XCTAssertFalse(malformedArray.isCompleteSnapshot)
    }

    func testCommitConfirmationCannotReuseACompleteScanAfterGoogleAccountChanges() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        for pass in 0...3 { _ = scan.observe(snapshot(ids: [1]), now: Double(pass)) }
        XCTAssertTrue(scan.completeTraversal)
        XCTAssertTrue(scan.matchesCurrentAccount(snapshot(ids: [1])))
        XCTAssertFalse(scan.matchesCurrentAccount(snapshot(ids: [2], identity: "other@example.invalid")))
        XCTAssertFalse(scan.matchesCurrentAccount(snapshot(ids: [1], identity: nil)))
    }

    @MainActor
    func testUnscopedStoreCannotClaimSuccessfulPersistence() throws {
        try withStore(active: false) { store, defaults, _ in
            XCTAssertNil(store.captureStorageBoundary())
            XCTAssertFalse(store.mergeScrapedBooks([book(1)], account: account()))
            XCTAssertFalse(store.hasConnected)
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertNotNil(store.lastError)
            XCTAssertNil(defaults.data(forKey: "googlebooks.library.books.v1"))
        }
    }

    @MainActor
    func testCastReaderAccountSwitchBackDoesNotReviveDelayedShelfCommit() throws {
        try withStore(active: false) { store, _, _ in
            let a = try XCTUnwrap(AccountContentScope(account: UserAccount(id: "local-a", provider: "google")))
            let b = try XCTUnwrap(AccountContentScope(account: UserAccount(id: "local-b", provider: "google")))
            store.activateAccountScope(a)
            XCTAssertTrue(store.mergeScrapedBooks([book(1)], account: account()))
            let staleA = try XCTUnwrap(store.captureStorageBoundary())
            store.activateAccountScope(b)
            XCTAssertTrue(store.mergeScrapedBooks([book(2)], account: account()))
            XCTAssertFalse(store.mergeScrapedBooks([book(1)], account: account(), expectedStorageBoundary: staleA))
            XCTAssertEqual(store.books.map(\.id), [book(2).id])
            store.activateAccountScope(a)
            XCTAssertFalse(store.isCurrentStorageBoundary(staleA))
            XCTAssertFalse(store.mergeScrapedBooks([book(3)], account: account(), expectedStorageBoundary: staleA))
            XCTAssertEqual(store.books.map(\.id), [book(1).id])
        }
    }

    @MainActor
    func testGoogleAccountSwitchBackInvalidatesPreviouslyCapturedProviderCommit() throws {
        try withStore { store, _, _ in
            let initial = try XCTUnwrap(store.captureStorageBoundary())
            XCTAssertTrue(store.mergeScrapedBooks([book(1)], account: account(), expectedStorageBoundary: initial))
            XCTAssertFalse(store.isCurrentStorageBoundary(initial), "First binding also establishes a new identity boundary")
            let staleA = try XCTUnwrap(store.captureStorageBoundary())
            let other = account(identity: "other@example.invalid")
            XCTAssertTrue(store.mergeScrapedBooks([book(2)], account: other, expectedStorageBoundary: staleA))
            XCTAssertFalse(store.mergeScrapedBooks([book(1)], account: account(), expectedStorageBoundary: staleA))
            XCTAssertEqual(store.books.map(\.id), [book(2).id])
            let currentB = try XCTUnwrap(store.captureStorageBoundary())
            XCTAssertTrue(store.mergeScrapedBooks([book(3)], account: account(), expectedStorageBoundary: currentB))
            XCTAssertFalse(store.mergeScrapedBooks([book(1)], account: account(), expectedStorageBoundary: staleA))
            XCTAssertEqual(store.books.map(\.id), [book(3).id])
        }
    }

    @MainActor
    func testPartialRescanAndReloadRetainGoodMetadataAndReadingAnchor() throws {
        try withStore { store, defaults, history in
            var first = book(1)
            first.author = "Synthetic Author"
            first.coverURL = "https://example.invalid/cover.jpg"
            XCTAssertTrue(store.mergeScrapedBooks([first, book(2)], account: account()))
            store.updateProgress(
                bookID: first.id, readerURL: first.readerURL + "&pg=GBS.PT12",
                fingerprint: "page-12", progressLabel: "12%"
            )
            let anchor = try XCTUnwrap(store.anchor(for: first.id))
            XCTAssertTrue(store.mergeScrapedBooks([book(1)], account: account(complete: false)))
            XCTAssertEqual(store.books.count, 2)
            XCTAssertEqual(store.book(for: first.id)?.author, first.author)
            XCTAssertEqual(store.book(for: first.id)?.coverURL, first.coverURL)
            XCTAssertEqual(store.anchor(for: first.id), anchor)
            let reloaded = GoogleBooksLibraryStore(defaults: defaults, historyStore: history)
            XCTAssertEqual(reloaded.books.count, 2)
            XCTAssertEqual(reloaded.anchor(for: first.id), anchor)
            XCTAssertEqual(reloaded.book(for: first.id)?.lastReaderURL, anchor.readerURL)
        }
    }

    @MainActor
    func testUntrustedNonemptyScanAndForgedBookIdentityCannotMutateShelf() throws {
        try withStore { store, _, _ in
            XCTAssertTrue(store.mergeScrapedBooks([book(1)], account: account()))
            XCTAssertFalse(store.mergeScrapedBooks([book(2)], account: nil))
            var forged = book(2)
            forged.readerURL = book(3).readerURL
            XCTAssertFalse(store.mergeScrapedBooks([forged], account: account()))
            XCTAssertEqual(store.books.map(\.id), [book(1).id])
        }
    }

    @MainActor
    func testUnprovenEmptyOrUnknownCardsCannotClearPersistedBooksAndAnchors() throws {
        try withStore { store, defaults, history in
            XCTAssertTrue(store.mergeScrapedBooks([book(1), book(2)], account: account()))
            let first = book(1)
            store.updateProgress(
                bookID: first.id, readerURL: first.readerURL + "&pg=GBS.PT4",
                fingerprint: "retained-page", progressLabel: nil
            )
            let anchor = try XCTUnwrap(store.anchor(for: first.id))
            XCTAssertFalse(store.mergeScrapedBooks([], account: account()))
            XCTAssertFalse(store.mergeScrapedBooks([], account: account(explicitEmpty: true, unrecognizedCandidates: 1)))
            XCTAssertFalse(store.mergeScrapedBooks([first], account: account(unrecognizedCandidates: 1)))
            let reloaded = GoogleBooksLibraryStore(defaults: defaults, historyStore: history)
            XCTAssertEqual(reloaded.books.count, 2)
            XCTAssertEqual(reloaded.anchor(for: first.id), anchor)

            // Only an explicitly proven empty shelf may remove the same
            // account's prior books and their local reading positions.
            XCTAssertTrue(store.mergeScrapedBooks([], account: account(explicitEmpty: true)))
            let empty = GoogleBooksLibraryStore(defaults: defaults, historyStore: history)
            XCTAssertTrue(empty.books.isEmpty)
            XCTAssertTrue(empty.anchors.isEmpty)
            XCTAssertTrue(empty.hasConnected)
        }
    }

    func testOldCompleteAccountPayloadDoesNotInventExplicitEmptyEvidence() throws {
        let old: [String: Any] = [
            "label": "Google account", "identity": GoogleBooksAccountIdentity.hash("reader@example.invalid")!,
            "hasAccountEvidence": true, "isShelfContext": true, "isCompleteSnapshot": true,
        ]
        let decoded = try JSONDecoder().decode(
            GoogleBooksAccountInfo.self, from: JSONSerialization.data(withJSONObject: old)
        )
        XCTAssertFalse(decoded.hasExplicitEmptyShelf)
        XCTAssertFalse(GoogleBooksShelfSyncContract.canCommit(
            bookCount: 0, account: decoded, reachedEnd: true, stableEndPasses: 100
        ))
    }

    func testEmptyCommitConfirmationMustStillShowAnExplicitEmptyShelf() {
        var scan = GoogleBooksShelfScanPolicy(startedAt: 0)
        for pass in 0...9 {
            _ = scan.observe(snapshot(ids: [], explicitEmpty: true), now: Double(pass))
        }
        XCTAssertTrue(scan.completeTraversal)
        XCTAssertTrue(scan.matchesCurrentAccount(snapshot(ids: [], explicitEmpty: true)))
        XCTAssertFalse(scan.matchesCurrentAccount(snapshot(ids: [])))
        XCTAssertFalse(scan.matchesCurrentAccount(snapshot(ids: [1])))
        XCTAssertFalse(scan.matchesCurrentAccount(snapshot(ids: [], explicitEmpty: true, unrecognizedCandidates: 1)))
    }

    @MainActor
    func testDisconnectInvalidatesDelayedCommitWhilePreservingAnEmptyPersistedShelf() async throws {
        let suite = "GoogleBooksShelfSyncTests.disconnect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = HistoryStore(directory: directory)
        let store = GoogleBooksLibraryStore(defaults: defaults, historyStore: history)
        XCTAssertTrue(store.mergeScrapedBooks([book(1)], account: account()))
        let stale = try XCTUnwrap(store.captureStorageBoundary())
        await store.disconnectAccount()
        XCTAssertFalse(store.mergeScrapedBooks([book(1)], account: account(), expectedStorageBoundary: stale))
        XCTAssertFalse(store.hasConnected)
        XCTAssertTrue(store.books.isEmpty)
        let reloaded = GoogleBooksLibraryStore(defaults: defaults, historyStore: history)
        XCTAssertFalse(reloaded.hasConnected)
        XCTAssertTrue(reloaded.books.isEmpty)
    }

    private func book(_ number: Int) -> GoogleBooksBook {
        let id = String(format: "GBFIX%04d", number)
        return GoogleBooksBook(
            id: "googlebooks:" + id, title: "Synthetic Book \(number)", author: "",
            coverURL: nil, readerURL: GoogleBooksBookValidator.canonicalReaderURL(volumeID: id),
            progressLabel: "", volumeID: id, lastOpenedAt: nil, lastSyncedAt: Date(), lastReaderURL: nil
        )
    }

    private func account(
        identity: String = "reader@example.invalid", complete: Bool = true,
        explicitEmpty: Bool = false, unrecognizedCandidates: Int = 0
    ) -> GoogleBooksAccountInfo {
        GoogleBooksAccountInfo(
            label: "Google account", identity: GoogleBooksAccountIdentity.hash(identity),
            hasAccountEvidence: true, isShelfContext: true, isCompleteSnapshot: complete,
            hasExplicitEmptyShelf: explicitEmpty, unrecognizedBookCandidateCount: unrecognizedCandidates
        )
    }

    private func snapshot(
        ids: [Int], position: Double = 0, extent: Double = 0,
        pending: Bool = false, identity: String? = "reader@example.invalid", author: String = "",
        explicitEmpty: Bool = false, unrecognizedCandidates: Int = 0
    ) -> GoogleBooksScanResult {
        GoogleBooksScanResult(rawSnapshot(
            ids: ids, position: position, extent: extent, pending: pending, identity: identity, author: author,
            explicitEmpty: explicitEmpty, unrecognizedCandidates: unrecognizedCandidates
        ))
    }

    private func rawSnapshot(
        ids: [Int], position: Double = 0, extent: Double = 0,
        pending: Bool = false, identity: String? = "reader@example.invalid", author: String = "",
        explicitEmpty: Bool = false, unrecognizedCandidates: Int = 0
    ) -> [String: Any] {
        var raw: [String: Any] = [
            "authRequired": false, "authenticated": true, "hasAccountEvidence": true,
            "isShelfContext": true, "isCompleteSnapshot": position >= extent && !pending,
            "atScrollEnd": position >= extent, "hasPendingWork": pending,
            "hasUnsupportedPagination": false, "hasCredentialForm": false,
            "isDocumentReady": true, "hasShelfSurface": true,
            "hasExplicitEmptyShelf": explicitEmpty, "unrecognizedBookCandidateCount": unrecognizedCandidates,
            "scrollPosition": position, "scrollExtent": extent, "viewportHeight": 100,
            "pageFingerprint": ids.map { String(format: "GBFIX%04d", $0) }.sorted().joined(separator: "|"),
            "books": ids.map { number -> [String: Any] in
                let book = book(number)
                return ["title": book.title, "readerURL": book.readerURL, "author": author]
            },
        ]
        if let identity { raw["accountIdentitySource"] = identity }
        return raw
    }

    @MainActor
    private func withStore(
        active: Bool = true,
        _ body: (GoogleBooksLibraryStore, UserDefaults, HistoryStore) throws -> Void
    ) rethrows {
        let suite = "GoogleBooksShelfSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let history = HistoryStore(directory: directory)
        let store = GoogleBooksLibraryStore(
            defaults: defaults, historyStore: history, websiteDataStore: .nonPersistent(),
            usesLegacyStorageWhenUnscoped: active
        )
        try body(store, defaults, history)
    }
}
