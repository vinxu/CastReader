import XCTest
import SwiftUI
import UIKit
@testable import CastReader

@MainActor
final class KindleMarkAnimationClockTests: XCTestCase {
    private final class HeldPage: ObservableObject {
        @Published var visible = true
    }

    private struct HeldPageFixture: View {
        @ObservedObject var page: HeldPage
        let id: UUID
        let fence: KindleVisualHoldReleaseFence
        let appeared: () -> Void
        var body: some View {
            ZStack {
                Color.blue
                if page.visible {
                    Color.white
                        .background(KindleVisualHoldRemovalObserver(id: id, fence: fence))
                        .onAppear(perform: appeared)
                }
            }
        }
    }

    func testNativeRevealWaitsForMountedHoldRemovalAndDisplayFrame() async {
        let fence = KindleVisualHoldReleaseFence(), page = HeldPage(), id = UUID()
        let mounted = expectation(description: "Native hold mounted")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIHostingController(rootView: HeldPageFixture(
            page: page, id: id, fence: fence, appeared: { mounted.fulfill() }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await fulfillment(of: [mounted], timeout: 2)
        let start = CACurrentMediaTime()
        let ready = await fence.waitForRemoval(of: id, while: { true }, remove: { page.visible = false })
        XCTAssertTrue(ready, "Removing the actual SwiftUI hold must release the next-page start")
        XCTAssertGreaterThan(CACurrentMediaTime() - start, 0)
        XCTAssertLessThan(CACurrentMediaTime() - start, 0.5)
    }

    func testMissingOrStaleNativeRemovalNeverAuthorizesPlayback() async {
        let fence = KindleVisualHoldReleaseFence()
        for staleCallback in [false, true] {
            let ready = await fence.waitForRemoval(of: UUID(), timeoutSeconds: 0.08, while: { true }, remove: {
                if staleCallback { fence.didRemove(UUID()) }
            })
            XCTAssertFalse(ready)
        }
    }

    func testCancelledNativeRevealCannotReleaseAReplacementHold() async {
        let fence = KindleVisualHoldReleaseFence(), old = UUID(), replacement = UUID()
        let registered = expectation(description: "Old reveal registered")
        let pending = Task {
            await fence.waitForRemoval(of: old, while: { true }, remove: { registered.fulfill() })
        }
        await fulfillment(of: [registered], timeout: 1)
        pending.cancel()
        let cancelled = await pending.value
        XCTAssertFalse(cancelled)
        let result = await fence.waitForRemoval(of: replacement, timeoutSeconds: 0.08, while: { true }, remove: {
            fence.didRemove(old)
        })
        XCTAssertFalse(result, "An old removal cannot authorize a new page")
    }

    func testNavigationInvalidationWinsOverAlreadyRemovedNativeHold() async {
        let fence = KindleVisualHoldReleaseFence(), id = UUID()
        var owned = true
        let result = await fence.waitForRemoval(of: id, while: { owned }, remove: {
            fence.didRemove(id)
            owned = false
        })
        XCTAssertFalse(result)
    }

    func testKnownAudioDeadlineFitsWholeStrokeAndRetainsPhaseAcrossRenderers() {
        let clock = KindleMarkAnimationClock()
        let id = UUID()
        clock.begin(id, duration: 2.2, completeBy: 100.5, now: 100)
        let animation = clock.animations[id]!
        XCTAssertEqual(animation.duration, 0.38, accuracy: 0.001)
        XCTAssertEqual(animation.progress(at: 100.38), 1, accuracy: 0.001)
        XCTAssertEqual(clock.remaining(at: 100.5), 0, accuracy: 0.001)
        clock.begin(id, duration: 2.2, completeBy: 102, now: 100.2)
        XCTAssertEqual(clock.animations[id]?.startedAt, 100)
        XCTAssertEqual(clock.animations[id]?.duration, animation.duration)
    }

    func testLateOrUnknownAudioDeadlineKeepsDrawingBounded() {
        let clock = KindleMarkAnimationClock()
        let late = UUID(), unknown = UUID()
        clock.begin(late, duration: 2.2, completeBy: 99, now: 100)
        clock.begin(unknown, duration: 2.2, completeBy: .nan, now: 100)
        XCTAssertEqual(clock.animations[late]?.duration, 0.01)
        XCTAssertEqual(clock.animations[unknown]?.duration, 2.2)
    }

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
