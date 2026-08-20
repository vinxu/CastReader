import XCTest
@testable import CastReader

/// 模拟 Amazon `/kindle-library` 的分批懒加载书架。
///
/// 要点：`scrapeLibrary` 抓的是**整个 DOM**，所以首屏渲染的那一批一次就全被
/// 抓走了；此后必须一路滚到已渲染内容的底部，Amazon 才会去请求下一批，而那
/// 一批要经过一次网络往返才会出现在 DOM 里。
private struct FakeAmazonShelf {
    let totalBooks: Int
    let batchSize: Int
    let restockSeconds: TimeInterval
    let booksPerScreen: Int

    private(set) var rendered: Int
    private var scrollTop: Int = 0
    private var restockDueAt: TimeInterval?

    init(totalBooks: Int, batchSize: Int, restockSeconds: TimeInterval, booksPerScreen: Int) {
        self.totalBooks = totalBooks
        self.batchSize = batchSize
        self.restockSeconds = restockSeconds
        self.booksPerScreen = booksPerScreen
        self.rendered = min(batchSize, totalBooks)
    }

    private var scrollCeiling: Int { max(0, rendered - booksPerScreen) }
    var atScrollEnd: Bool { scrollTop >= scrollCeiling }
    var isLoading: Bool { restockDueAt != nil }

    /// 补货到期就把下一批灌进 DOM。
    mutating func advanceClock(to now: TimeInterval) {
        guard let due = restockDueAt, now >= due else { return }
        rendered = min(rendered + batchSize, totalBooks)
        restockDueAt = nil
    }

    /// 真实 JS 现在一次滚到已渲染内容的底部，模型跟着对齐。
    mutating func scrollForward(now: TimeInterval) {
        scrollTop = scrollCeiling
        if atScrollEnd, rendered < totalBooks, restockDueAt == nil {
            restockDueAt = now + restockSeconds
        }
    }
}

private struct ScanRun {
    var booksFound: Int
    var elapsed: TimeInterval
    var passes: Int
    var declaredComplete: Bool
}

/// 修复前的判据：连续两个 pass 没有新书就收工，pass 间固定等 650ms，
/// 并且根本不看是否滚到了 DOM 底部（Android 线上版本的原样）。
private func runLegacyScan(shelf: FakeAmazonShelf) -> ScanRun {
    var shelf = shelf
    var now: TimeInterval = 0
    var seen = 0
    var idlePasses = 0
    for pass in 0..<12 {
        shelf.advanceClock(to: now)
        let before = seen
        seen = max(seen, shelf.rendered)
        idlePasses = (seen == before) ? idlePasses + 1 : 0
        if seen > 0, pass >= 2, idlePasses >= 2 {
            return ScanRun(booksFound: seen, elapsed: now, passes: pass + 1, declaredComplete: true)
        }
        shelf.scrollForward(now: now)  // 旧实现逐屏滚，但它根本活不到滚出效果的那一刻
        now += 0.65
    }
    return ScanRun(booksFound: seen, elapsed: now, passes: 12, declaredComplete: false)
}

/// 修复后的判据：`KindleShelfScanPolicy` 驱动同一个书架。
private func runPolicyScan(shelf: FakeAmazonShelf) -> ScanRun {
    var shelf = shelf
    var now: TimeInterval = 0
    var seen = 0
    var idlePasses = 0
    var lastNewBookAt: TimeInterval = 0
    var lastReachedEndAt: TimeInterval = 0
    var wasAtEnd = false
    var observedRestock: TimeInterval = 0
    var stableSnapshotPasses = 0
    var previousSnapshot = ""

    for pass in 0..<KindleShelfScanPolicy.maxPasses {
        shelf.advanceClock(to: now)
        let before = seen
        seen = max(seen, shelf.rendered)
        if seen == before {
            idlePasses += 1
        } else {
            if wasAtEnd {
                let restock = now - lastReachedEndAt
                if restock > 0 { observedRestock = max(observedRestock, restock) }
            }
            idlePasses = 0
            lastNewBookAt = now
        }
        let snapshot = "\(shelf.rendered):\(shelf.atScrollEnd):\(shelf.isLoading)"
        stableSnapshotPasses = (snapshot == previousSnapshot) ? stableSnapshotPasses + 1 : 0
        previousSnapshot = snapshot

        if shelf.atScrollEnd, !wasAtEnd { lastReachedEndAt = now }
        wasAtEnd = shelf.atScrollEnd
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: pass,
                bookCount: seen,
                idlePasses: idlePasses,
                stableSnapshotPasses: stableSnapshotPasses,
                secondsSinceLastNewBook: now - lastNewBookAt,
                secondsSinceReachedEnd: now - lastReachedEndAt,
                observedRestock: observedRestock,
                atScrollEnd: shelf.atScrollEnd,
                shelfLoading: shelf.isLoading,
                pageReady: true,
                isExactBoundLibrary: true
            )
        )
        switch decision {
        case .scanComplete:
            return ScanRun(booksFound: seen, elapsed: now, passes: pass + 1, declaredComplete: true)
        case .exhausted:
            return ScanRun(booksFound: seen, elapsed: now, passes: pass + 1, declaredComplete: false)
        case .keepScrolling(let waitSeconds):
            shelf.scrollForward(now: now)
            now += waitSeconds
        }
    }
    return ScanRun(booksFound: seen, elapsed: now, passes: KindleShelfScanPolicy.maxPasses, declaredComplete: false)
}

final class KindleShelfScanPolicyTests: XCTestCase {

    /// Shondra 的书架：约 300 本，Amazon 每批约 50 本。
    private var shondrasShelf: FakeAmazonShelf {
        FakeAmazonShelf(totalBooks: 300, batchSize: 50, restockSeconds: 2.5, booksPerScreen: 6)
    }

    /// 重现线上故障：旧判据在约 1.5 秒后宣布同步成功，只拿到首批。
    /// 埋点里 sync_started → sync_completed 是 1481ms / 1475ms，与此吻合。
    func testLegacyScanStopsAtTheFirstBatchAndCallsItSuccess() {
        let run = runLegacyScan(shelf: shondrasShelf)
        XCTAssertEqual(run.booksFound, 50, "旧判据只拿到 Amazon 的首批")
        XCTAssertTrue(run.declaredComplete, "而且它把这次截断当成了成功")
        XCTAssertEqual(run.passes, 3, "三次抓取就收工")
        XCTAssertLessThan(run.elapsed, 2.0, "总耗时约 1.3–1.5 秒，与线上埋点一致")
    }

    /// 修好之后：同一个书架必须扫全。
    func testPolicyScanReachesTheWholeShelf() {
        let run = runPolicyScan(shelf: shondrasShelf)
        XCTAssertEqual(run.booksFound, 300, "补货窗让每一批都进得来")
        XCTAssertTrue(run.declaredComplete, "扫完了才算完成")
    }

    /// 慢网络下补货更久，也不能提前收工。
    func testPolicyScanSurvivesSlowRestock() {
        let slow = FakeAmazonShelf(
            totalBooks: 220, batchSize: 50, restockSeconds: 4.5, booksPerScreen: 6
        )
        let run = runPolicyScan(shelf: slow)
        XCTAssertEqual(run.booksFound, 220)
        XCTAssertTrue(run.declaredComplete)
    }

    /// 超过旧的 120 / 160 条截断线的书架也要完整。
    func testPolicyScanExceedsTheOldHardCap() {
        let big = FakeAmazonShelf(
            totalBooks: 640, batchSize: 50, restockSeconds: 2.0, booksPerScreen: 8
        )
        let run = runPolicyScan(shelf: big)
        XCTAssertEqual(run.booksFound, 640)
        XCTAssertGreaterThan(run.booksFound, 160, "旧实现在 JS 层就把书架截断了")
    }

    /// 小书架：一批就装下，仍要正常收工，不能空转到预算耗尽。
    func testPolicyScanCompletesSmallShelfWithoutBurningBudget() {
        let small = FakeAmazonShelf(
            totalBooks: 12, batchSize: 50, restockSeconds: 2.5, booksPerScreen: 6
        )
        let run = runPolicyScan(shelf: small)
        XCTAssertEqual(run.booksFound, 12)
        XCTAssertTrue(run.declaredComplete)
        XCTAssertLessThan(run.passes, 12, "小书架不该滚满全程")
    }

    // MARK: - 判据本身

    /// 到底了、也没有新书，但观察窗还没走完 —— 这正是旧实现收工的那一刻。
    func testDoesNotCompleteInsideTheRestockWindow() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 2, bookCount: 48, idlePasses: 3, stableSnapshotPasses: 2,
                secondsSinceLastNewBook: 1.4,
                secondsSinceReachedEnd: 1.4,
                atScrollEnd: true, shelfLoading: false, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        XCTAssertNotEqual(decision, .scanComplete)
    }

    /// 观察窗走完，才允许收工。
    func testCompletesAfterTheRestockWindow() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 6, bookCount: 300, idlePasses: 3, stableSnapshotPasses: 2,
                secondsSinceLastNewBook: 3.2,
                secondsSinceReachedEnd: 3.2,
                atScrollEnd: true, shelfLoading: false, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        XCTAssertEqual(decision, .scanComplete)
    }

    /// 还没滚到底就不算扫完，哪怕这一轮没有新书。
    func testNeverCompletesBeforeReachingTheBottom() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 4, bookCount: 48, idlePasses: 5, stableSnapshotPasses: 3,
                secondsSinceLastNewBook: 9.0,
                secondsSinceReachedEnd: 9.0,
                atScrollEnd: false, shelfLoading: false, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        XCTAssertNotEqual(decision, .scanComplete)
    }

    /// Amazon 正在补货时不算扫完。
    func testNeverCompletesWhileShelfIsLoading() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 4, bookCount: 48, idlePasses: 4, stableSnapshotPasses: 2,
                secondsSinceLastNewBook: 5.0,
                secondsSinceReachedEnd: 5.0,
                atScrollEnd: true, shelfLoading: true, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        XCTAssertNotEqual(decision, .scanComplete)
    }

    /// atScrollEnd 因 Amazon 改版永久失真时，扫描仍必须停下来，
    /// 并且标成 exhausted，好让 scan_timeout 埋点把问题暴露出来。
    func testHardStopsWhenScrollSignalIsUnreliable() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 20, bookCount: 48, idlePasses: 12, stableSnapshotPasses: 9,
                secondsSinceLastNewBook: KindleShelfScanPolicy.stallTimeout,
                secondsSinceReachedEnd: KindleShelfScanPolicy.stallTimeout,
                atScrollEnd: false, shelfLoading: false, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        XCTAssertEqual(decision, .exhausted)
    }

    /// 但滚过一整批的途中（十几个 pass 没有新书）绝不能被当成停滞——
    /// 这是第一版修复踩的坑。
    func testLongIdleStretchWhileStillScrollingIsNotAStall() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 9, bookCount: 50, idlePasses: 9, stableSnapshotPasses: 0,
                secondsSinceLastNewBook: 5.4,
                secondsSinceReachedEnd: 5.4,
                atScrollEnd: false, shelfLoading: false, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        guard case .keepScrolling = decision else {
            return XCTFail("还没滚到底，应该继续滚，实际是 \(decision)")
        }
    }

    /// 观察窗必须从「滚到底」起算，不能从「最后一次拿到新书」起算。
    /// 真机复现过的时序：拿到一批后又滚了一次才到底，Amazon 这时才去请求
    /// 下一批；窗口若从拿到书起算，会在补货落地前 153ms 到期。
    func testObservationWindowStartsAtReachedEndNotLastNewBook() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 7, bookCount: 122, idlePasses: 3, stableSnapshotPasses: 2,
                secondsSinceLastNewBook: 3.1,
                secondsSinceReachedEnd: 0.5,
                atScrollEnd: true, shelfLoading: false, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        XCTAssertNotEqual(decision, .scanComplete, "刚滚到底就收工会漏掉正在补的那一批")
    }

    /// 补货耗时逼近观察窗上限时，仍然要扫全。
    func testPolicyScanSurvivesRestockNearWindowLimit() {
        let run = runPolicyScan(shelf: FakeAmazonShelf(
            totalBooks: 260, batchSize: 50, restockSeconds: 2.8, booksPerScreen: 8
        ))
        XCTAssertEqual(run.booksFound, 260)
        XCTAssertTrue(run.declaredComplete)
    }

    /// 慢网络：补货 5 秒，远超 3 秒的基础观察窗。固定窗口必然截断，
    /// 自适应窗口应当按实测把窗口放大到足以兜住。
    func testPolicyScanSurvivesRestockFarBeyondBaseWindow() {
        let run = runPolicyScan(shelf: FakeAmazonShelf(
            totalBooks: 200, batchSize: 50, restockSeconds: 5.0, booksPerScreen: 8
        ))
        XCTAssertEqual(run.booksFound, 200)
        XCTAssertTrue(run.declaredComplete)
    }

    /// 还没观测到补货时用基础窗口——单批装下的小书架不该被额外拖慢。
    func testObservationWindowStaysAtBaseWhenNoRestockObserved() {
        XCTAssertEqual(
            KindleShelfScanPolicy.observationWindow(observedRestock: 0),
            KindleShelfScanPolicy.restockObservationWindow
        )
    }

    /// 观测到慢补货后按倍数放大，但不超过上限。
    func testObservationWindowAdaptsToObservedRestock() {
        XCTAssertGreaterThan(KindleShelfScanPolicy.observationWindow(observedRestock: 4), 4)
        XCTAssertEqual(
            KindleShelfScanPolicy.observationWindow(observedRestock: 60),
            KindleShelfScanPolicy.maxObservationWindow
        )
    }

    /// 慢网络：Amazon 还挂着加载指示器时，超过普通停滞阈值也不能放弃。
    func testLoadingShelfIsNotTreatedAsStalled() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 15, bookCount: 50, idlePasses: 10, stableSnapshotPasses: 8,
                secondsSinceLastNewBook: KindleShelfScanPolicy.stallTimeout + 1,
                secondsSinceReachedEnd: KindleShelfScanPolicy.stallTimeout + 1,
                atScrollEnd: true, shelfLoading: true, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        guard case .keepScrolling = decision else {
            return XCTFail("还在补货就不该放弃，实际是 \(decision)")
        }
    }

    /// 但加载指示器一直亮着也不能无限等。
    func testLoadingShelfStillGivesUpEventually() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: 30, bookCount: 50, idlePasses: 25, stableSnapshotPasses: 20,
                secondsSinceLastNewBook: KindleShelfScanPolicy.stallTimeout * 2,
                secondsSinceReachedEnd: KindleShelfScanPolicy.stallTimeout * 2,
                atScrollEnd: true, shelfLoading: true, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        XCTAssertEqual(decision, .exhausted)
    }

    /// 空书架不该滚满 60 次——它有自己的证据链，12 个 pass 就该放手。
    func testEmptyShelfGivesUpEarly() {
        let decision = KindleShelfScanPolicy.decide(
            KindleShelfScanPolicy.Input(
                pass: KindleShelfScanPolicy.emptyShelfMaxPasses - 1, bookCount: 0,
                idlePasses: 11, stableSnapshotPasses: 10, secondsSinceLastNewBook: 8,
                secondsSinceReachedEnd: 8,
                atScrollEnd: true, shelfLoading: false, pageReady: true,
                isExactBoundLibrary: true
            )
        )
        XCTAssertEqual(decision, .exhausted)
    }

    /// 还在出新书时不浪费时间干等。
    func testWaitsLessWhileNewBooksKeepArriving() {
        let busy = KindleShelfScanPolicy.Input(
            pass: 3, bookCount: 120, idlePasses: 0, stableSnapshotPasses: 0,
            secondsSinceLastNewBook: 0,
                secondsSinceReachedEnd: 0,
            atScrollEnd: false, shelfLoading: false, pageReady: true,
            isExactBoundLibrary: true
        )
        var waitingForRestock = busy
        waitingForRestock.idlePasses = 2
        waitingForRestock.atScrollEnd = true
        XCTAssertLessThan(
            KindleShelfScanPolicy.waitSeconds(after: busy),
            KindleShelfScanPolicy.waitSeconds(after: waitingForRestock)
        )
    }
}

// MARK: - 标题黑名单不再误杀真书

final class KindleBookValidatorBlocklistTests: XCTestCase {

    private func book(title: String, asin: String?) -> KindleBook {
        KindleBook(
            id: asin ?? "row-\(title)",
            asin: asin,
            title: title,
            author: "",
            coverURL: nil,
            readerURL: "https://read.amazon.com/?asin=\(asin ?? "B000000000")&ref_=cr_lib",
            progressLabel: "",
            storefrontID: "us",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
    }

    /// 黑名单按子串匹配，曾把这些真书当成「下载 App」之类的功能入口丢掉。
    func testRealBooksWhoseTitlesContainBlockedWordsSurvive() {
        for title in [
            "The Help",
            "Life Support",
            "Terms of Endearment",
            "The Privacy Project",
            "Download Your Brain",
            "Settings for Success",
        ] {
            XCTAssertTrue(
                KindleBookValidator.isLikelyLibraryBook(book(title: title, asin: "B00TESTASI")),
                "带 ASIN 的《\(title)》是真书，不该被标题黑名单否决"
            )
        }
    }

    /// 但没有 ASIN 的功能入口卡片仍然要被挡住。
    func testChromeCardsWithoutASINAreStillRejected() {
        let chrome = KindleBook(
            id: "chrome-download",
            asin: nil,
            title: "Download the Kindle app",
            author: "",
            coverURL: nil,
            readerURL: "https://read.amazon.com/reader/download",
            progressLabel: "",
            storefrontID: "us",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
        XCTAssertFalse(KindleBookValidator.isLikelyLibraryBook(chrome))
    }
}
