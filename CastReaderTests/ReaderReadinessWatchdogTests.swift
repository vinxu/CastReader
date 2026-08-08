//
//  ReaderReadinessWatchdogTests.swift
//  CastReaderTests
//
//  从 Android 的 ReaderReadinessWatchdogTest.kt 移植（commit fe24532）。
//  截止期不可延长、刷新节流、身份替换与取消语义都固定在这里。
//

import XCTest
@testable import CastReader

final class ReaderReadinessWatchdogTests: XCTestCase {

    private func watchdog() -> ReaderReadinessWatchdog {
        ReaderReadinessWatchdog(timeoutMs: 60_000, refreshIntervalMs: 4_000)
    }

    private func identity(
        documentEpoch: UInt64 = 4,
        bookID: String = "b_40EQAAQBAJ",
        commandSessionEpoch: UInt64 = 9
    ) -> ReaderReadinessWatchdog.Identity {
        ReaderReadinessWatchdog.Identity(
            readerDocumentEpoch: documentEpoch,
            bookID: bookID,
            commandSessionEpoch: commandSessionEpoch
        )
    }

    func testRepeatedMainDocumentCallbacksCannotExtendTheDeadline() {
        var watchdog = watchdog()
        let first = watchdog.arm(identity(), nowElapsedMs: 1_000)
        let pageFinished = watchdog.arm(identity(), nowElapsedMs: 8_000)

        XCTAssertEqual(first, pageFinished)
        XCTAssertEqual(pageFinished.deadlineElapsedMs, 61_000)
        XCTAssertEqual(
            watchdog.action(pageFinished, nowElapsedMs: 61_000, hasReadyFrame: true),
            .timeout
        )
    }

    func testDeferredColdStartExtractionCannotExtendTheTerminalDeadline() {
        var watchdog = watchdog()
        let documentStart = watchdog.arm(identity(), nowElapsedMs: 1_000)
        let transientBridgeError = watchdog.arm(identity(), nowElapsedMs: 13_000)

        XCTAssertEqual(documentStart, transientBridgeError)
        XCTAssertEqual(transientBridgeError.deadlineElapsedMs, 61_000)
        XCTAssertEqual(
            watchdog.action(transientBridgeError, nowElapsedMs: 61_000, hasReadyFrame: true),
            .timeout
        )
    }

    func testWaitingWithoutAReadyFrameDoesNotConsumeRefreshEligibility() {
        var watchdog = watchdog()
        let ticket = watchdog.arm(identity(), nowElapsedMs: 0)

        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 7_000, hasReadyFrame: false),
            .wait
        )
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 32_000, hasReadyFrame: false),
            .wait
        )
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 32_001, hasReadyFrame: true),
            .refresh
        )
        XCTAssertEqual(ticket.deadlineElapsedMs, 60_000)
    }

    func testReadyFrameCanBeRefreshedRepeatedlyButNeverFasterThanEveryFourSeconds() {
        var watchdog = watchdog()
        let ticket = watchdog.arm(identity(), nowElapsedMs: 10_000)

        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 18_250, hasReadyFrame: true),
            .refresh
        )
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 22_249, hasReadyFrame: true),
            .wait
        )
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 22_250, hasReadyFrame: true),
            .refresh
        )
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 24_000, hasReadyFrame: false),
            .wait
        )
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 26_250, hasReadyFrame: true),
            .refresh
        )
    }

    func testTotalDeadlineIsSixtySecondsEvenWhenNoFrameEverBecomesReady() {
        var watchdog = watchdog()
        let ticket = watchdog.arm(identity(), nowElapsedMs: 5_000)

        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 64_999, hasReadyFrame: false),
            .wait
        )
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 65_000, hasReadyFrame: false),
            .timeout
        )
    }

    func testBookDocumentOrCommandAuthorityChangeMakesOldDelayedActionStale() {
        let identityMutations = [
            identity(documentEpoch: 5),
            identity(bookID: "another-volume"),
            identity(commandSessionEpoch: 10)
        ]

        for replacementIdentity in identityMutations {
            var watchdog = watchdog()
            let old = watchdog.arm(identity(), nowElapsedMs: 0)
            let replacement = watchdog.arm(replacementIdentity, nowElapsedMs: 2_000)

            XCTAssertFalse(watchdog.isActive(old))
            XCTAssertTrue(watchdog.isActive(replacement))
            XCTAssertEqual(
                watchdog.action(old, nowElapsedMs: 60_000, hasReadyFrame: true),
                .stale
            )
        }
    }

    func testCommitOrTeardownCancellationInvalidatesBothRefreshAndTimeout() {
        var watchdog = watchdog()
        let ticket = watchdog.arm(identity(), nowElapsedMs: 0)

        watchdog.cancel(ticket)

        XCTAssertFalse(watchdog.isActive(ticket))
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 7_000, hasReadyFrame: false),
            .stale
        )
        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 60_000, hasReadyFrame: true),
            .stale
        )
    }

    func testTimeoutRemainsActiveUntilTheOwnerConsumesAndCancelsIt() {
        var watchdog = watchdog()
        let ticket = watchdog.arm(identity(), nowElapsedMs: 0)

        XCTAssertEqual(
            watchdog.action(ticket, nowElapsedMs: 60_000, hasReadyFrame: true),
            .timeout
        )
        XCTAssertTrue(watchdog.isActive(ticket))

        watchdog.cancel(ticket)
        XCTAssertFalse(watchdog.isActive(ticket))
    }
}
