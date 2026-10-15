import XCTest
@testable import CastReader

@MainActor
final class SpeechGenerationControlTests: XCTestCase {
    private enum Failure: Error { case timeout }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { XCTFail("State did not advance"); throw Failure.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func segment(_ index: Int, duration: Double) -> AudioSegment {
        .init(paragraphIndex: 0, segmentIndex: index, audioData: Data([UInt8(index)]),
              timestamps: [], duration: duration, text: "Part \(index)")
    }

    func testTwoPagePreparedAudioSharesBudgetAndQueuePromotionDoesNotDoubleCount() async throws {
        let control = SpeechGenerationControl()
        let current = segment(0, duration: 20), nextPage = segment(0, duration: 15)
        var position = 0.0
        var nextQueued = false
        control.playbackSnapshot = {
            .init(pending: nextQueued ? [current, nextPage] : [current],
                  queueIDs: nextQueued ? [current.generationIdentity, nextPage.generationIdentity] : [current.generationIdentity],
                  currentID: current.generationIdentity, position: position, rate: 1)
        }
        control.addBufferProvider { [nextPage] }
        XCTAssertEqual(control.bufferedSeconds, 35)
        nextQueued = true
        XCTAssertEqual(control.bufferedSeconds, 35, "Promotion shares audio identity, not paragraph IDs")
        var calls = 0
        let job = Task { try await control.run(requestID: "next", priority: .readAhead) { calls += 1 } }
        try await until { control.isWaitingForBudget }
        position = 12; control.notify()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, 0, "23 seconds is below high water but above resume water")
        control.playbackSnapshot = { .init(pending: [nextPage], queueIDs: [current.generationIdentity, nextPage.generationIdentity], currentID: nextPage.generationIdentity, position: 6, rate: 1) }
        control.notify()
        try await job.value
        XCTAssertEqual(calls, 1)
    }

    func testUnknownDurationReservesThirtyAudibleSecondsAtAnySpeedOrPosition() {
        let control = SpeechGenerationControl()
        let unknown = segment(0, duration: 0)
        control.playbackSnapshot = { .init(pending: [unknown], queueIDs: [unknown.generationIdentity], currentID: unknown.generationIdentity, position: 50, rate: 2) }
        XCTAssertEqual(control.bufferedSeconds, 30)
    }

    func testHighWaterIsRememberedEvenBeforeAnotherProducerRequestsAdmission() async throws {
        let control = SpeechGenerationControl()
        let audio = segment(0, duration: 35)
        var position = 0.0
        control.playbackSnapshot = { .init(pending: [audio], queueIDs: [audio.generationIdentity], currentID: audio.generationIdentity, position: position) }
        control.notify()
        XCTAssertTrue(control.isWaitingForBudget)
        position = 7; control.notify()
        var calls = 0
        let job = Task { try await control.run(requestID: "late-waiter", priority: .readAhead) { calls += 1 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(calls, 0, "A producer arriving after high water must still wait for the low watermark")
        position = 25; control.notify()
        try await job.value
        XCTAssertEqual(calls, 1)
    }

    func testHTTPResultReservesBudgetUntilConsumerPublishesAndPromotionDoesNotDoubleCount() async throws {
        let control = SpeechGenerationControl()
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 35))
        }
        defer { fixture.close() }
        let generator = fixture.service().controlled(by: control)
        var pending: AudioSegment?
        var published: [AudioSegment] = []
        var release: (() -> Void)?
        control.addBufferProvider { published }
        let producer = Task {
            try await generator.generateBufferedSpeech(paragraphIndex: 0, text: "First page.",
                voice: "af_heart", speed: 1, language: "en", includeVoiceCode: true,
                speaker: nil, cloneRequestID: "handoff", continuation: nil,
                beforeRequest: { _ in .interactive }, onSegmentReady: { segment in
                    pending = segment
                    await withCheckedContinuation { continuation in release = { continuation.resume() } }
                    published = [segment]
                })
        }
        try await until { release != nil }
        XCTAssertEqual(control.bufferedSeconds, 35)
        var followingStarted = false
        let following = Task {
            try await control.run(requestID: "next-page", priority: .readAhead) { followingStarted = true }
        }
        try await until { control.isWaitingForBudget }
        XCTAssertFalse(followingStarted, "Response crossing actors already owns its generated duration")
        published = [try XCTUnwrap(pending)]
        XCTAssertEqual(control.bufferedSeconds, 35, "Consumer publication must deduplicate the response reservation")
        release?()
        try await producer.value
        XCTAssertEqual(control.bufferedSeconds, 35)
        control.playbackSnapshot = { .init(queueIDs: Set(published.map(\.generationIdentity))) }
        control.notify()
        try await following.value
        XCTAssertTrue(followingStarted, "Consumed queue identities cannot be counted again through retained preparation")
    }

    func testDiscardedAdjacentPageReleasesItsBudgetEvenWhileItsSourceOwnerIsRetained() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = AudioPlayerService(testTemporaryRoot: root)
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 35))
        }
        defer { audio.stop(); fixture.close(); try? FileManager.default.removeItem(at: root) }
        let page = LivePagePreparedSpeech(paragraphIndex: 0, sourceText: "Adjacent page.", voice: "af_heart", language: "en")
        page.start(generator: fixture.service(), audio: audio, speechInput: "Adjacent page.",
                   isCurrent: { true }, fitsBudget: { true })
        try await until { page.stream.finished && !page.stream.segments.isEmpty }
        XCTAssertEqual(audio.speechGeneration.bufferedSeconds, 35)
        var started = false
        let waiter = Task {
            try await audio.speechGeneration.run(requestID: "new-page", priority: .interactive) { started = true }
        }
        try await until { audio.speechGeneration.isWaitingForBudget }
        page.discardIfSpeculative()
        try await waiter.value
        XCTAssertTrue(started)
        XCTAssertEqual(audio.speechGeneration.bufferedSeconds, 0)
    }

    func testAudibleDemandUnblocksUnfinishedCurrentPageWithoutDroppingFutureBudget() async throws {
        for futureDuration in [35.0, 0.0] {
            let control = SpeechGenerationControl()
            let consumed = segment(0, duration: 20), future = segment(1, duration: futureDuration)
            let refill = segment(2, duration: 15)
            var queue: [AudioSegment] = []
            var position = 0.0
            control.playbackSnapshot = {
                .init(pending: queue, queueIDs: [consumed.generationIdentity],
                      currentID: refill.generationIdentity, position: position)
            }
            control.addBufferProvider { [future] }
            control.notify()
            var futureCalls = 0, currentCalls = 0
            // Higher nominal priority cannot deadlock the actual audible owner.
            let speculative = Task {
                try await control.run(requestID: "future", priority: .interactive) { futureCalls += 1 }
            }
            control.setPaused(true)
            let current = Task {
                try await SpeechGenerationContext.$audibleDemand.withValue({ true }) {
                    try await control.run(requestID: "current-tail", priority: .readAhead) {
                        currentCalls += 1; queue = [refill]; control.notify()
                    }
                    try await control.run(requestID: "current-next", priority: .readAhead) { currentCalls += 1 }
                }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(currentCalls, 0, "Audible demand cannot override pause")
            control.setPaused(false)
            try await until { currentCalls == 1 }
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(currentCalls, 1, "A refilled playable queue must stop the exception")
            XCTAssertEqual(futureCalls, 0)
            XCTAssertEqual(control.bufferedSeconds, (futureDuration > 0 ? futureDuration : 30) + 15)
            position = 5; control.notify()
            try await current.value
            XCTAssertEqual(currentCalls, 2)
            XCTAssertEqual(futureCalls, 0, "Unadopted audio still consumes the full shared budget")
            speculative.cancel()
            do { try await speculative.value; XCTFail("Cancelled speculative waiter must exit") }
            catch is CancellationError {} catch { XCTFail("Unexpected error") }
        }
    }

    func testPauseCancelsRealHTTPAttemptAndResumeUsesSameLogicalRequest() async throws {
        let control = SpeechGenerationControl()
        var ids: [String] = []
        let fixture = ReadAloudHTTPFixture.forRequests { request, body in
            ids.append(request.value(forHTTPHeaderField: "X-Request-ID") ?? "missing")
            return .response(ReadAloudHTTPFixture.body(body["input"] as? String ?? ""), delay: ids.count == 1 ? 3 : 0)
        }
        defer { fixture.close() }
        let generator = fixture.service().controlled(by: control)
        var segments: [AudioSegment] = []
        let producer = Task {
            try await generator.generateBufferedSpeech(paragraphIndex: 0, text: "Preserve this exact input.",
                voice: "af_heart", speed: 1, language: "en", includeVoiceCode: true,
                speaker: nil, cloneRequestID: "stable-reading-owner", continuation: nil,
                beforeRequest: { _ in .interactive }, onSegmentReady: { segments.append($0) })
        }
        try await until { fixture.requests.count == 1 }
        control.setPaused(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertTrue(segments.isEmpty)
        control.setPaused(false)
        try await producer.value
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertNotEqual(ids[0], "missing")
        XCTAssertEqual(segments.count, 1, "Cancelled prefix must never publish or replay")
    }

    func testSeekCancelsPausedWaiterWithoutStartingReplacementOfOldInput() async throws {
        let control = SpeechGenerationControl()
        control.setPaused(true)
        var calls = 0
        for _ in 0..<50 {
            let task = Task { try await control.run(requestID: "retired", priority: .interactive) { calls += 1 } }
            await Task.yield()
            task.cancel()
            do { try await task.value; XCTFail("Cancellation must exit") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        }
        control.setPaused(false)
        try await control.run(requestID: "target", priority: .interactive) { calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    func testLateCancelledAttemptKeepsSerialPermitAndCannotPublishItsResult() async throws {
        let control = SpeechGenerationControl()
        var release: (() -> Void)?
        var attempts = 0
        var live = 0
        var peak = 0
        let producer = Task {
            try await control.run(requestID: "stable", priority: .interactive) {
                attempts += 1; live += 1; peak = max(peak, live)
                defer { live -= 1 }
                if attempts == 1 {
                    await withCheckedContinuation { continuation in release = { continuation.resume() } }
                    return "old result"
                }
                return "current result"
            }
        }
        try await until { release != nil }
        control.setPaused(true)
        control.setPaused(false)
        let following = Task {
            try await control.run(requestID: "following", priority: .readAhead) {
                live += 1; peak = max(peak, live); live -= 1
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(attempts, 1, "Resume must wait until old transport actually exits")
        release?()
        let value = try await producer.value
        try await following.value
        XCTAssertEqual(value, "current result")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(peak, 1)
    }

    func testAtomicUnitIsFiniteAndStillHonorsPause() async throws {
        let control = SpeechGenerationControl()
        var calls = 0
        do {
            try await SpeechGenerationContext.withAtomicUnit(text: String(repeating: "字", count: 2401)) { calls += 1 }
            XCTFail("Oversize whole narration must not be admitted")
        } catch {}
        control.setPaused(true)
        let task = Task {
            try await SpeechGenerationContext.withAtomicUnit(text: "Complete marked sentence.") {
                try await control.run(requestID: "atomic", priority: .interactive) { calls += 1 }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(calls, 0)
        control.setPaused(false)
        try await task.value
        XCTAssertEqual(calls, 1)
    }

    func testOnlyOneAtomicUnitCanCrossBudgetAndPriorityCannotDeadlockItsContinuation() async throws {
        let control = SpeechGenerationControl()
        var reserved: [AudioSegment] = []
        control.addBufferProvider { reserved }
        var order: [String] = []
        var continueFirst: (() -> Void)?
        let first = Task {
            try await SpeechGenerationContext.withAtomicUnit(text: "First complete marked unit") {
                try await control.run(requestID: "a0", priority: .readAhead) { order.append("a0") }
                reserved.append(self.segment(0, duration: 20))
                await withCheckedContinuation { continuation in continueFirst = { continuation.resume() } }
                try await control.run(requestID: "a1", priority: .readAhead) { order.append("a1") }
                reserved.append(self.segment(1, duration: 20))
            }
        }
        try await until { continueFirst != nil }
        let second = Task {
            try await SpeechGenerationContext.withAtomicUnit(text: "Second complete marked unit") {
                try await control.run(requestID: "b0", priority: .interactive) { order.append("b0") }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(order, ["a0"], "A second atomic unit cannot open its own budget exception")
        continueFirst?()
        try await first.value
        XCTAssertEqual(order, ["a0", "a1"], "Higher-priority waiting unit must not deadlock the current unit")
        try await until { control.isWaitingForBudget }
        reserved.removeAll(); control.notify()
        try await second.value
        XCTAssertEqual(order, ["a0", "a1", "b0"])
    }

    func testInputWindowsAreBoundedLosslessAndPreserveSurrogates() {
        for limit in [160, 560] {
            let original = String(repeating: "First 😀 sentence. 第二个句子没有空格。 ", count: 100)
            var remaining = original
            var pieces: [String] = []
            while !remaining.isEmpty {
                let part = SpeechInputWindow.split(remaining, maximumUTF16: limit)
                XCTAssertFalse(part.input.isEmpty)
                XCTAssertLessThanOrEqual(part.input.utf16.count, limit)
                pieces.append(part.input); remaining = part.remainder
            }
            XCTAssertEqual(pieces.joined(), original)
        }
    }

    func testPartlyTailAndLocalTailKeepSourceSeparator() {
        let response = TTSResponse(audio: "", audioFormat: "wav", timestamps: [], duration: 1,
            processedText: "First. ", unprocessedText: "Second")
        let combined = ClonedTTSRequestChunker.appendingLocalRemainder(to: response,
            submittedInput: "First. Second ", localRemainder: "third.")
        XCTAssertEqual(combined.unprocessedText, "Second third.")
    }
}
