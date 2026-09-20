import XCTest
@testable import CastReader

@MainActor
final class KindleMarkAnimationClockTests: XCTestCase {
    func testHandoffKeepsPhaseAndCompletionDeadline() {
        let clock = KindleMarkAnimationClock()
        let id = UUID()
        clock.begin(id, duration: 2.2, now: 100)
        let original = clock.animations[id]!
        clock.begin(id, duration: 0.45, now: 101)
        XCTAssertEqual(clock.animations[id]?.startedAt, 100)
        XCTAssertEqual(clock.animations[id]?.duration, 2.2)
        XCTAssertEqual(original.progress(at: 100), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(original.progress(at: 101), 0.4)
        XCTAssertLessThan(original.progress(at: 101), 1)
        XCTAssertEqual(original.progress(at: 103), 1, accuracy: 0.0001)
        XCTAssertEqual(clock.remaining(at: 101), 1.32, accuracy: 0.001)
        XCTAssertEqual(clock.remaining(at: 103), 0)
    }

    func testFinalStrokeDelaysContinuationOnlyForRemainingInk() async {
        let clock = KindleMarkAnimationClock()
        clock.begin(UUID(), duration: 0.45)
        let started = ProcessInfo.processInfo.systemUptime
        let allowed = await clock.drain { true }
        XCTAssertTrue(allowed)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThanOrEqual(elapsed, 0.56)
        XCTAssertLessThan(elapsed, 1)
    }

    func testManualNavigationAndPauseCancelPendingAdvancePromptly() async throws {
        for reset in [false, true] {
            let clock = KindleMarkAnimationClock()
            clock.begin(UUID(), duration: 2.2)
            let task = Task { await clock.drain { true } }
            try await Task.sleep(nanoseconds: 40_000_000)
            let started = ProcessInfo.processInfo.systemUptime
            if reset { clock.reset() } else { clock.cancelWaits() }
            let allowed = await task.value
            XCTAssertFalse(allowed)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.2)
        }
    }

    func testMissingRendererCannotBlockForeverAndStaleOwnerNeverTurns() async {
        let clock = KindleMarkAnimationClock()
        clock.begin(UUID(), duration: 1_000)
        XCTAssertLessThanOrEqual(clock.remaining(), 2.32)
        let denied = await clock.drain { false }
        XCTAssertFalse(denied)
        let started = ProcessInfo.processInfo.systemUptime
        let allowed = await clock.drain { true }
        XCTAssertTrue(allowed)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2.6)
    }

    func testTaskCancellationCannotBecomeSuccessfulTurn() async throws {
        let clock = KindleMarkAnimationClock()
        clock.begin(UUID(), duration: 2.2)
        let task = Task { await clock.drain { true } }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        let allowed = await task.value
        XCTAssertFalse(allowed)
    }
}
