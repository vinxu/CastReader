import XCTest
@testable import CastReader

final class PresetTTSRequestSchedulerTests: XCTestCase {
    private actor Recorder {
        var values: [String] = []
        func add(_ value: String) { values.append(value) }
    }
    private actor Barrier {
        private var continuation: CheckedContinuation<Void, Never>?
        var entered = false
        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered = true
            }
        }
        func open() { continuation?.resume(); continuation = nil }
    }
    private enum FixtureError: Error { case expected, timedOut }

    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Scheduler did not reach the expected state")
        throw FixtureError.timedOut
    }

    private func job(_ name: String, _ priority: PresetTTSRequestScheduler.Priority,
                     _ scheduler: PresetTTSRequestScheduler, _ recorder: Recorder) -> Task<Void, Error> {
        Task {
            try await scheduler.run(priority: priority, requestID: name) {
                await recorder.add(name)
            }
        }
    }

    func testPendingPlaybackAndNextSentenceOvertakeSpeculativePages() async throws {
        let scheduler = PresetTTSRequestScheduler()
        let recorder = Recorder()
        let a = try await scheduler.acquire(priority: .interactive, requestID: "occupied-a")
        let b = try await scheduler.acquire(priority: .interactive, requestID: "occupied-b")
        let page = job("page", .speculative, scheduler, recorder)
        try await until { await scheduler.debugCounts.waiting == 1 }
        let next = job("next", .readAhead, scheduler, recorder)
        try await until { await scheduler.debugCounts.waiting == 2 }
        let current = job("current", .interactive, scheduler, recorder)
        try await until { await scheduler.debugCounts.waiting == 3 }
        await scheduler.release(a)
        try await until { await recorder.values.count == 3 }
        let order = await recorder.values
        XCTAssertEqual(order, ["current", "next", "page"])
        try await page.value; try await next.value; try await current.value
        await scheduler.release(b)
        let counts = await scheduler.debugCounts
        XCTAssertEqual(counts.active, 0)
        XCTAssertEqual(counts.waiting, 0)
    }

    func testSpeculationCannotOccupyBothSlotsAndBlockNextSentence() async throws {
        let scheduler = PresetTTSRequestScheduler()
        let recorder = Recorder()
        let firstPage = try await scheduler.acquire(priority: .speculative, requestID: "first-page")
        let laterPage = job("later-page", .speculative, scheduler, recorder)
        try await until { await scheduler.debugCounts.waiting == 1 }
        let next = job("next", .readAhead, scheduler, recorder)
        try await until { await recorder.values == ["next"] }
        let counts = await scheduler.debugCounts
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.waiting, 1)
        await scheduler.release(firstPage)
        try await until { await recorder.values.count == 2 }
        try await next.value; try await laterPage.value
        let order = await recorder.values
        XCTAssertEqual(order, ["next", "later-page"])
    }

    func testCancelledQueuedRequestNeverStartsOrLeaksAdmission() async throws {
        let scheduler = PresetTTSRequestScheduler(maximumActive: 1)
        let recorder = Recorder()
        let blocker = try await scheduler.acquire(priority: .interactive, requestID: "occupied")
        let cancelled = job("cancelled", .readAhead, scheduler, recorder)
        try await until { await scheduler.debugCounts.waiting == 1 }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(type(of: error))") }
        let counts = await scheduler.debugCounts
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.waiting, 0)
        await scheduler.release(blocker)
        try await scheduler.run(priority: .interactive, requestID: "recovery") { await recorder.add("recovery") }
        let order = await recorder.values
        XCTAssertEqual(order, ["recovery"])
    }

    func testCancellationOfAdmittedOperationKeepsPermitUntilItActuallyExits() async throws {
        let scheduler = PresetTTSRequestScheduler(maximumActive: 1)
        let barrier = Barrier()
        let recorder = Recorder()
        let active = Task {
            try await scheduler.run(priority: .interactive, requestID: "active") {
                await barrier.wait() // Represents a transport still tearing down.
                try Task.checkCancellation()
            }
        }
        try await until { await barrier.entered }
        let next = job("next", .readAhead, scheduler, recorder)
        try await until { await scheduler.debugCounts.waiting == 1 }
        active.cancel()
        let counts = await scheduler.debugCounts
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.waiting, 1)
        let before = await recorder.values
        XCTAssertTrue(before.isEmpty)
        await barrier.open()
        do { try await active.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error") }
        try await until { await recorder.values == ["next"] }
        try await next.value
    }

    func testSharedAPITransportAdmitsNextSentenceWhileSecondPageWaits() async throws {
        let first = "First speculative page."
        let second = "Second speculative page."
        let next = "The next sentence."
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input), delay: input == first ? 0.8 : 0)
        }
        defer { fixture.close() }
        let scheduler = PresetTTSRequestScheduler()
        let service = TTSService(api: APIService(session: fixture.session, presetScheduler: scheduler))
        let a = Task { try await service.generatePrefetchSegments(paragraphIndex: 0, text: first, voice: "af_heart", language: "en", presetPriority: .speculative) }
        try await until { fixture.requests == [first] }
        let b = Task { try await service.generatePrefetchSegments(paragraphIndex: 0, text: second, voice: "af_heart", language: "en", presetPriority: .speculative) }
        try await until { await scheduler.debugCounts.waiting == 1 }
        let c = Task { try await service.generatePrefetchSegments(paragraphIndex: 1, text: next, voice: "af_heart", language: "en") }
        try await until { fixture.requests.count == 2 }
        XCTAssertEqual(fixture.requests, [first, next])
        let nextAudio = try await c.value
        XCTAssertFalse(nextAudio.isEmpty)
        _ = try await a.value
        _ = try await b.value
        XCTAssertEqual(fixture.requests, [first, next, second])
    }

    func testFailureAndCancellationBeforeEnqueueDoNotStrandPermits() async throws {
        let scheduler = PresetTTSRequestScheduler(maximumActive: 1)
        do {
            try await scheduler.run(priority: .interactive, requestID: "failure") { throw FixtureError.expected }
            XCTFail("Expected failure")
        } catch FixtureError.expected {}
        for _ in 0..<30 {
            let task = Task {
                try await scheduler.run(priority: .readAhead, requestID: "cancel-race") { try Task.checkCancellation() }
            }
            task.cancel()
            _ = try? await task.value
        }
        let counts = await scheduler.debugCounts
        XCTAssertEqual(counts.active, 0)
        XCTAssertEqual(counts.waiting, 0)
    }

    func testCloneBackgroundWaitsForFirstAudioAndUserActionCanOvertakeIt() async throws {
        let scheduler = PresetTTSRequestScheduler(protectInteractive: true)
        let recorder = Recorder()
        let foreground = try await scheduler.acquire(priority: .interactive, requestID: "first-audio")
        let background = job("background", .readAhead, scheduler, recorder)
        try await until { await scheduler.debugCounts.waiting == 1 }
        let before = await recorder.values
        XCTAssertTrue(before.isEmpty, "An unused transport slot must not start a competing clone preparation")
        await scheduler.release(foreground)
        try await background.value

        let activeBackground = try await scheduler.acquire(priority: .readAhead, requestID: "already-generating")
        let later = job("later", .speculative, scheduler, recorder)
        try await until { await scheduler.debugCounts.waiting == 1 }
        let userAction = job("user", .interactive, scheduler, recorder)
        try await userAction.value
        let during = await recorder.values
        XCTAssertEqual(during, ["background", "user"])
        await scheduler.release(activeBackground)
        try await later.value
        let counts = await scheduler.debugCounts
        XCTAssertEqual(counts.active, 0)
        XCTAssertEqual(counts.waiting, 0)
    }

    func testProtocolPrefetchDoesNotCancelForegroundSpeech() async throws {
        let foregroundText = "The current sentence must finish."
        let backgroundText = "The following paragraph can prepare independently."
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input), delay: input == foregroundText ? 0.4 : 0)
        }
        defer { fixture.close() }
        let service: any ParagraphSpeechGenerating = fixture.service()
        let recorder = Recorder()
        let foreground = Task {
            try await service.generateTTSForParagraph(
                paragraphIndex: 0, text: foregroundText, voice: "af_heart", speed: 1,
                language: "en", includeVoiceCode: true, speaker: nil, cloneRequestID: nil
            ) { segment in await recorder.add(segment.text) }
        }
        try await until { fixture.requests == [foregroundText] }
        let background = try await service.generatePrefetchSegments(
            paragraphIndex: 1, text: backgroundText, voice: "af_heart", language: "en"
        )
        XCTAssertEqual(background.map(\.text).joined(), backgroundText)
        try await foreground.value
        let played = await recorder.values
        XCTAssertEqual(played, [foregroundText])
    }
}
