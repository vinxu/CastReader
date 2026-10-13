import XCTest
@testable import CastReader

final class KoboShelfScanPolicyTests: XCTestCase {
    func testFourPagesAreAccumulatedAndDuplicateUUIDsMergeOnlyAfterLastPage() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        for page in 1...4 {
            let first = 1 + (page - 1) * 19
            let snapshot = makeSnapshot(page: page, total: 4, ids: Array(first..<(first + 20)))
            let decision = settle(&scan, snapshot, now: &now)
            XCTAssertEqual(decision, page == 4 ? .complete : .advancePage)
            XCTAssertEqual(scan.completeTraversal, page == 4)
            if page < 4 { XCTAssertNil(scan.account) }
        }
        XCTAssertEqual(scan.completedPageCount, 4)
        XCTAssertEqual(scan.books.count, 77)
        XCTAssertEqual(scan.books[bookID(20)]?.title, "Page 2 book 20")
        XCTAssertTrue(scan.account?.isCompleteSnapshot == true)
        XCTAssertTrue(KoboShelfSyncContract.canCommit(
            bookCount: scan.books.count,
            account: scan.account,
            reachedEnd: true,
            stableEndPasses: scan.stableEndPasses,
            completeTraversal: scan.completeTraversal
        ))
    }

    func testHundredBooksAcrossFourPagesCommitOnlyAfterTheFourthStablePage() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        for page in 1...4 {
            let snapshot = makeSnapshot(page: page, total: 4, ids: hundredBookPage(page))
            XCTAssertEqual(settle(&scan, snapshot, now: &now), page == 4 ? .complete : .advancePage)
            XCTAssertEqual(scan.completedPageCount, page)
            XCTAssertEqual(scan.books.count, page * 25)
            XCTAssertEqual(scan.completeTraversal, page == 4)
            if page < 4 {
                XCTAssertNil(scan.account)
                // A slow page action may leave the previous 25 cards visible
                // for several polls; it must neither click twice nor count it.
                for _ in 0..<3 {
                    now += 0.35
                    XCTAssertEqual(scan.observe(snapshot, now: now), .wait)
                    XCTAssertEqual(scan.completedPageCount, page)
                    XCTAssertEqual(scan.books.count, page * 25)
                }
            }
        }
        XCTAssertEqual(Set(scan.books.keys), Set((1...100).map(bookID)))
        XCTAssertTrue(KoboShelfSyncContract.canCommit(
            bookCount: scan.books.count,
            account: scan.account,
            reachedEnd: true,
            stableEndPasses: scan.stableEndPasses,
            completeTraversal: scan.completeTraversal
        ))
    }

    func testHundredBookTraversalDeduplicatesOverlappingPageBoundaries() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        for page in 1...4 {
            var ids = hundredBookPage(page)
            if page > 1 { ids.insert(ids[0] - 1, at: 0) }
            let snapshot = makeSnapshot(page: page, total: 4, ids: ids)
            XCTAssertEqual(settle(&scan, snapshot, now: &now), page == 4 ? .complete : .advancePage)
            XCTAssertEqual(scan.books.count, page * 25)
        }
        XCTAssertEqual(scan.books.count, 100, "103 encountered cards contain 100 distinct UUIDs")
        XCTAssertEqual(scan.completedPageCount, 4)
        XCTAssertEqual(scan.books[bookID(25)]?.title, "Page 2 book 25")
        XCTAssertEqual(scan.books[bookID(50)]?.title, "Page 3 book 50")
        XCTAssertEqual(scan.books[bookID(75)]?.title, "Page 4 book 75")
        XCTAssertTrue(scan.completeTraversal)
    }

    func testHundredBookFourthPageRepeatingAnEarlierPageCannotCommit() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        for page in 1...3 {
            XCTAssertEqual(settle(&scan, makeSnapshot(page: page, total: 4, ids: hundredBookPage(page)), now: &now), .advancePage)
        }
        let loop = makeSnapshot(page: 4, total: 4, ids: hundredBookPage(2))
        XCTAssertEqual(scan.observe(loop, now: now + 0.35), .failed("pagination_loop"))
        XCTAssertEqual(scan.books.count, 75)
        XCTAssertEqual(scan.completedPageCount, 3)
        XCTAssertFalse(scan.completeTraversal)
        XCTAssertNil(scan.account)
        XCTAssertFalse(KoboShelfSyncContract.canCommit(
            bookCount: scan.books.count,
            account: loop.account.map(KoboAccountInfo.init(label:)),
            reachedEnd: true,
            stableEndPasses: 10,
            completeTraversal: scan.completeTraversal
        ), "A last-page flag cannot authorize replacing the saved library after a pagination loop")
    }

    @MainActor
    func testInterruptedHundredBookRescanPreservesTheExistingLibraryAndProgress() {
        let suite = "KoboShelfScanPolicyTests.hundred.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KoboLibraryStore(defaults: defaults, historyStore: HistoryStore(directory: directory))
        let saved = makeSnapshot(page: 1, total: 1, ids: Array(1...100))
        store.mergeScrapedBooks(saved.books, account: saved.account.map(KoboAccountInfo.init(label:)))
        let lastBook = saved.books[99]
        store.updateProgress(
            bookID: lastBook.id,
            readerURL: lastBook.readerURL,
            fingerprint: "retained-page-anchor",
            progressLabel: "73%"
        )

        // The newly scraped pages contain a different 100-book catalog. If a
        // partial scan were committed, the saved catalog and anchor would go.
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        for page in 1...3 {
            let ids = hundredBookPage(page).map { $0 + 100 }
            XCTAssertEqual(settle(&scan, makeSnapshot(page: page, total: 4, ids: ids), now: &now), .advancePage)
        }
        let waiting = makeSnapshot(page: 4, total: 4, ids: Array(176...200), pending: true)
        XCTAssertEqual(scan.observe(waiting, now: now + 0.35), .wait)
        let timeout = now + KoboShelfScanPolicy.transitionTimeout + 0.1
        XCTAssertEqual(scan.observe(waiting, now: timeout), .failed("page_transition_timeout"))
        let latePage = makeSnapshot(page: 4, total: 4, ids: Array(176...200))
        XCTAssertEqual(scan.observe(latePage, now: timeout + 1), .failed("page_transition_timeout"))

        let canCommit = KoboShelfSyncContract.canCommit(
            bookCount: scan.books.count,
            account: scan.account,
            reachedEnd: true,
            stableEndPasses: scan.stableEndPasses,
            completeTraversal: scan.completeTraversal
        )
        XCTAssertFalse(canCommit)
        XCTAssertNil(scan.account)
        XCTAssertFalse(scan.completeTraversal)
        if canCommit {
            store.mergeScrapedBooks(Array(scan.books.values), account: scan.account)
        }
        XCTAssertEqual(Set(store.books.map(\.id)), Set(saved.books.map(\.id)))
        XCTAssertEqual(store.books.count, 100)
        XCTAssertEqual(store.anchor(for: lastBook.id)?.pageFingerprint, "retained-page-anchor")
        XCTAssertEqual(store.anchor(for: lastBook.id)?.progressLabel, "73%")
    }

    func testHydratingNextPageMustReplaceOldBooksBeforeItIsAccepted() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 1, total: 2, ids: [1, 2]), now: &now), .advancePage)
        for _ in 0..<8 {
            now += 0.35
            // Kobo updates pagination/URL first; the old cards remain visible.
            XCTAssertEqual(scan.observe(makeSnapshot(page: 2, total: 2, ids: [1, 2]), now: now), .wait)
        }
        XCTAssertTrue(scan.isAwaitingPageChange)
        XCTAssertEqual(scan.completedPageCount, 1)
        XCTAssertFalse(scan.completeTraversal)
        XCTAssertEqual(scan.observe(nil, now: now + 0.1), .wait)
        XCTAssertEqual(scan.observe(makeSnapshot(page: 2, total: 2, ids: [3], pending: true), now: now + 0.2), .wait)
        XCTAssertEqual(scan.observe(makeSnapshot(page: 2, total: 2, ids: [3], blocked: true), now: now + 0.3), .wait)
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 2, total: 2, ids: [3]), now: &now), .complete)
        XCTAssertEqual(scan.books.count, 3)
    }

    func testOneClickThenWaitsAndTimesOutWithoutReclickingOrCommitting() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        let first = makeSnapshot(page: 1, total: 4, ids: [1])
        XCTAssertEqual(settle(&scan, first, now: &now), .advancePage)
        for _ in 0..<20 {
            now += 0.35
            XCTAssertEqual(scan.observe(first, now: now), .wait)
        }
        XCTAssertEqual(scan.observe(first, now: 25), .failed("page_transition_timeout"))
        XCTAssertNil(scan.account)
        XCTAssertFalse(scan.completeTraversal)
    }

    func testStartingOnFourthPageReturnsToFirstBeforeCollectingAnyBooks() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        let fourth = makeSnapshot(page: 4, total: 4, ids: [76, 77])
        XCTAssertEqual(scan.observe(fourth, now: now), .resetToFirstPage)
        XCTAssertEqual(scan.collectedBookCount, 0)
        XCTAssertEqual(scan.observe(fourth, now: 1), .wait)
        now = 1
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 1, total: 4, ids: [1, 2]), now: &now), .advancePage)
        XCTAssertEqual(scan.books.count, 2)
        XCTAssertNil(scan.books[bookID(77)])
    }

    func testUnknownStartWithoutAFirstPageControlIsRejected() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        let unknown = makeSnapshot(page: nil, total: 4, ids: [42], canGoFirst: false)
        XCTAssertEqual(scan.observe(unknown, now: 0), .failed("first_page_unverified"))
        XCTAssertEqual(scan.collectedBookCount, 0)
    }

    func testUnknownStartCanResetAndProveFirstPage() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 1
        XCTAssertEqual(scan.observe(makeSnapshot(page: nil, total: 2, ids: [42]), now: 0), .resetToFirstPage)
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 1, total: 2, ids: [1]), now: &now), .advancePage)
        XCTAssertNil(scan.books[bookID(42)])
    }

    func testChangedAccountAbortsBeforeMergingNextPage() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 1, total: 2, ids: [1]), now: &now), .advancePage)
        let changed = makeSnapshot(page: 2, total: 2, ids: [2], identity: "other@example.com")
        XCTAssertEqual(scan.observe(changed, now: now), .failed("account_changed"))
        XCTAssertNil(scan.books[bookID(2)])
        XCTAssertNil(scan.account)
        XCTAssertFalse(scan.completeTraversal)
    }

    func testTemporaryMissingAuthenticationDuringNavigationIsRetried() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 1, total: 2, ids: [1]), now: &now), .advancePage)
        let hydrating = KoboScanResult(["authRequired": true, "authenticated": false])
        XCTAssertEqual(scan.observe(hydrating, now: now + 1), .wait)
        now += 2
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 2, total: 2, ids: [2]), now: &now), .complete)
    }

    func testRepeatedEarlierPageContentCannotCompleteTheTraversal() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        var now: TimeInterval = 0
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 1, total: 3, ids: [1]), now: &now), .advancePage)
        XCTAssertEqual(settle(&scan, makeSnapshot(page: 2, total: 3, ids: [2]), now: &now), .advancePage)
        XCTAssertEqual(scan.observe(makeSnapshot(page: 3, total: 3, ids: [1]), now: now), .failed("pagination_loop"))
        XCTAssertFalse(scan.completeTraversal)
    }

    func testSinglePageSnapshotDoesNotSatisfyCommitWithoutWholeScanEvidence() {
        let snapshot = makeSnapshot(page: 4, total: 4, ids: [77])
        let account = snapshot.account.map(KoboAccountInfo.init(label:))
        XCTAssertFalse(KoboShelfSyncContract.canCommit(
            bookCount: 1, account: account, reachedEnd: true, stableEndPasses: 10
        ))
    }

    func testEmptyUnpaginatedShelfNeedsTenStablePassesAndTrustedIdentity() {
        var scan = KoboShelfScanPolicy(startedAt: 0)
        let empty = makeSnapshot(page: 1, total: 1, ids: [])
        for pass in 1..<10 {
            XCTAssertEqual(scan.observe(empty, now: Double(pass) * 0.35), .wait)
        }
        XCTAssertEqual(scan.observe(empty, now: 3.5), .complete)
        XCTAssertTrue(scan.completeTraversal)
        XCTAssertTrue(scan.books.isEmpty)
    }

    func testUnknownPaginationAndGlobalTimeoutNeverReturnACommittableAccount() {
        var blockedScan = KoboShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(blockedScan.observe(makeSnapshot(page: 1, total: 4, ids: [1], blocked: true), now: 0), .failed("pagination_unrecognized"))
        var timedOutScan = KoboShelfScanPolicy(startedAt: 0)
        XCTAssertEqual(timedOutScan.observe(nil, now: 181), .failed("scan_timeout"))
        XCTAssertNil(blockedScan.account)
        XCTAssertNil(timedOutScan.account)
    }

    private func settle(
        _ scan: inout KoboShelfScanPolicy,
        _ snapshot: KoboScanResult,
        now: inout TimeInterval
    ) -> KoboShelfScanPolicy.Decision {
        var last: KoboShelfScanPolicy.Decision = .wait
        for _ in 0..<KoboShelfSyncContract.requiredStablePasses(bookCount: snapshot.books.count) {
            now += 0.35
            last = scan.observe(snapshot, now: now)
        }
        return last
    }

    private func makeSnapshot(
        page: Int?,
        total: Int,
        ids: [Int],
        identity: String = "fixture@example.com",
        pending: Bool = false,
        canGoFirst: Bool = true,
        blocked: Bool = false
    ) -> KoboScanResult {
        var pagination: [String: Any] = [
            "hasPagination": total > 1,
            "totalPages": total,
            "isFirstPage": page == 1,
            "isLastPage": page == total,
            "hasNextPage": page.map { $0 < total } ?? true,
            "canGoToFirstPage": canGoFirst,
            "blocked": blocked,
            "pageKey": page.map { "page:\($0)" } ?? "unknown",
        ]
        if let page { pagination["currentPage"] = page }
        return KoboScanResult([
            "authRequired": false,
            "authenticated": true,
            "hasAccountEvidence": true,
            "isShelfContext": true,
            "account": "Fixture reader",
            "accountIdentitySource": identity,
            "isCompleteSnapshot": page == total && !pending,
            "atScrollEnd": true,
            "hasPendingWork": pending,
            "pageFingerprint": ids.map(uuid).sorted().joined(separator: "|"),
            "pagination": pagination,
            "books": ids.map { id -> [String: Any] in
                [
                    "title": "Page \(page ?? 0) book \(id)",
                    "author": "Fixture author",
                    "readerURL": "https://readnow.kobo.com/\(uuid(id))",
                ]
            },
        ])
    }

    private func uuid(_ value: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", value)
    }

    private func bookID(_ value: Int) -> String {
        KoboBookValidator.stableID(bookUUID: uuid(value))
    }

    private func hundredBookPage(_ page: Int) -> [Int] {
        Array(((page - 1) * 25 + 1)...(page * 25))
    }
}
