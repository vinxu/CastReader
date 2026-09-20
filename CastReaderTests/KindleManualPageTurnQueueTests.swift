import XCTest
@testable import CastReader

@MainActor
final class KindleManualPageTurnQueueTests: XCTestCase {
    func testRapidNextNextNextPreviousPreviousNeverOverlapAndKeepOrder() async {
        let queue = KindleManualPageTurnQueue()
        var active = 0, peak = 0, page = 10
        var positions: [Int] = []
        let tasks = [1, 1, 1, -1, -1].map { delta in Task { @MainActor in
            await queue.perform {
                active += 1; peak = max(peak, active)
                let old = page
                try? await Task.sleep(nanoseconds: 30_000_000)
                page = old + delta
                positions.append(page)
                active -= 1
            }
        } }
        for task in tasks { await task.value }
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(positions, [11, 12, 13, 12, 11])
    }

    func testStopCancelsQueuedTurnsAndResumeWaitsForDispatchedAction() async throws {
        let queue = KindleManualPageTurnQueue()
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let first = Task { await queue.perform {
            events.append("old-dispatch")
            await withCheckedContinuation { release = $0 }
            events.append("old-confirm")
        } }
        while release == nil { await Task.yield() }
        let queued = Task { await queue.perform { events.append("must-not-dispatch") } }
        await Task.yield()
        queue.cancel()
        let resumed = Task { await queue.perform { events.append("new-dispatch") } }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(events, ["old-dispatch"])
        release?.resume()
        await first.value; await queued.value; await resumed.value
        XCTAssertEqual(events, ["old-dispatch", "old-confirm", "new-dispatch"])
    }
}
