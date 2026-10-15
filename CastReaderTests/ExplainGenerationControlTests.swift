import XCTest
@testable import CastReader

private actor ExplainControlSessionProvider: MobileSessionProviding {
    func sessionToken() -> String? { "cms_fixture" }
    func refreshSession() -> String? { "cms_fixture" }
    func invalidateSession() {}
    func rejectSession(_ token: String?) {}
}

private final class ExplainRequestLedger {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        values.append(request.value(forHTTPHeaderField: "X-Request-ID") ?? "")
    }
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Isolated HTTP/TTSService/AVPlayer tests, not live provider or quota evidence.
@MainActor
final class ExplainGenerationControlTests: XCTestCase {
    private var oldLanguage = ""
    private var oldPro = false
    override func setUp() async throws {
        _ = AuthService.shared
        AudioPlayerService.shared.clearForAccountBoundary()
        oldLanguage = AppSettings.shared.explainLanguage
        AppSettings.shared.explainLanguage = "en"
        oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        useRegularVoiceForTest(language: "en")
    }
    override func tearDown() async throws {
        AudioPlayerService.shared.clearForAccountBoundary()
        AppSettings.shared.explainLanguage = oldLanguage
        ProManager.shared.debugForcePro = oldPro
    }
    private func wait(_ message: String, timeout: Double = 8, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), message)
    }
    private func document() -> ReadingDocument {
        ReadingDocument(title: "Controlled explanation", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "A source page has enough meaningful text for a complete explanation. The source and its spoken commentary must remain synchronized across page boundaries.")])
    }
    private func plan(_ texts: [String], marks: [[String: Any]] = []) -> ReadAloudHTTPFixture {
        func section(_ index: Int) -> [String: Any] {
            ["id": "block-\(index)", "text": texts[min(index, texts.count - 1)],
             "style": "explain", "cinematic": ["events": marks]]
        }
        return ReadAloudHTTPFixture.forRequests { request, body in
            if request.url?.path == "/api/quickread/extract-plan" {
                let block: [String: Any] = ["job_id": "controlled-plan", "output_language": "en",
                    "total_blocks": texts.count, "block_0": section(0)]
                let json = String(data: try! JSONSerialization.data(withJSONObject: block), encoding: .utf8)!
                return .response(Data("event: block0\ndata: \(json)\n\nevent: done\ndata: {\"job_id\":\"controlled-plan\",\"total_blocks\":\(texts.count)}\n\n".utf8))
            }
            return .response(try! JSONSerialization.data(withJSONObject: ["section": section(body["block_idx"] as? Int ?? 0)]))
        }
    }
    private func viewModel(speech: ReadAloudHTTPFixture, plan: ReadAloudHTTPFixture) -> ExplainViewModel {
        ExplainViewModel(document: document(), speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session, mobileSessionProvider: ExplainControlSessionProvider()))
    }

    func testPauseBeforeFirstMediaAbortsAndResumesSameRequestWithoutReplanning() async throws {
        let audio = AudioPlayerService.shared
        let gate = ReadAloudHTTPFixture.ResponseGate()
        let ledger = ExplainRequestLedger()
        let text = "This narration must wait for the listener to resume."
        let speech = ReadAloudHTTPFixture.forRequests { request, body in
            ledger.append(request)
            return .gatedResponse(ReadAloudHTTPFixture.body(body["input"] as? String ?? "", duration: 2), gate)
        }
        let planning = plan([text])
        let vm = viewModel(speech: speech, plan: planning)
        defer { vm.stop(); vm.deactivate(); gate.release(); speech.close(); planning.close() }
        vm.startByUser()
        try await wait("First TTS attempt must start") { speech.requests.count == 1 }
        vm.togglePlayPause()
        XCTAssertTrue(audio.isExplicitlyPaused)
        gate.release() // An old transport callback cannot publish into a paused queue.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(speech.requests.count, 1)
        XCTAssertNil(audio.currentSegment)
        XCTAssertTrue(vm.debugPreparedSegments(block: 0).isEmpty)
        vm.togglePlayPause()
        try await wait("The existing producer must resume") { audio.hasAudibleProgress }
        XCTAssertEqual(speech.requests.count, 2)
        XCTAssertEqual(Set(ledger.ids).count, 1)
        XCTAssertFalse(ledger.ids.first?.isEmpty ?? true)
        XCTAssertEqual(planning.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, 1)
        XCTAssertEqual(audio.currentSegment?.text, text)
    }

    func testPausedVoiceSwitchRemainsActionableWithoutGeneratingUntilResume() async throws {
        try await verifyPausedVoiceSwitch(pauseDuringPreparation: false)
    }

    func testPauseDuringVoiceReplacementHidesWaitingAndResumesTheSameProducer() async throws {
        try await verifyPausedVoiceSwitch(pauseDuringPreparation: true)
    }

    private func verifyPausedVoiceSwitch(pauseDuringPreparation: Bool) async throws {
        let audio = AudioPlayerService.shared
        let gate = ReadAloudHTTPFixture.ResponseGate()
        let text = "The explanation must retain its source marks while a new narrator waits for the listener."
        let initialVoice = AppSettings.shared.voice(for: "en")
        let replacement = initialVoice == "af_bella" ? "af_nicole" : "af_bella"
        let speech = ReadAloudHTTPFixture.forRequests { _, body in
            let response = ReadAloudHTTPFixture.body(body["input"] as? String ?? "", duration: 40)
            return pauseDuringPreparation && body["voice"] as? String == replacement
                ? .gatedResponse(response, gate) : .response(response)
        }
        let planning = plan([text])
        let vm = viewModel(speech: speech, plan: planning)
        defer { vm.stop(); vm.deactivate(); gate.release(); speech.close(); planning.close() }
        vm.startByUser()
        try await wait("Original narrator must play") { audio.hasAudibleProgress }
        if !pauseDuringPreparation { vm.togglePlayPause() }
        XCTAssertTrue(AppSettings.shared.setVoice(replacement, for: "en"))
        try await wait("Voice preference must reach Explain") { vm.acceptanceVoiceID == replacement }
        if pauseDuringPreparation {
            try await wait("Replacement must start before Pause") { speech.requests.count == 2 }
            vm.togglePlayPause()
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(audio.isExplicitlyPaused)
        XCTAssertFalse(vm.isPreparingNext, "A dormant producer must leave the Play control actionable")
        try await wait("Paused voice status must settle after its minimum display duration", timeout: 2) {
            VoiceSwitchStatusCenter.shared.progress == nil
        }
        XCTAssertNil(VoiceSwitchStatusCenter.shared.progress, "Paused generation must not show an endless voice spinner")
        let pausedRequestCount = speech.requests.count
        XCTAssertEqual(pausedRequestCount, pauseDuringPreparation ? 2 : 1)
        gate.release()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(speech.requests.count, pausedRequestCount)
        XCTAssertNil(audio.currentSegment, "Old or late audio must not enter the paused replacement queue")
        vm.togglePlayPause()
        try await wait("Explicit Play must resume the retained replacement producer") {
            vm.debugPreparedVoiceIDs[0] == replacement && audio.hasAudibleProgress
        }
        XCTAssertEqual(speech.requests.count, pausedRequestCount + 1)
        XCTAssertFalse(vm.isPreparingNext)
        XCTAssertNil(VoiceSwitchStatusCenter.shared.progress)
        XCTAssertEqual(planning.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, 1)
    }

    func testAtomicComposeCountsPendingAudioAndDoesNotGenerateSecondPageBlockBeforeAdoption() async throws {
        let audio = AudioPlayerService.shared
        let first = String(repeating: "The first bounded narration explains a related concept without losing its original annotations ", count: 12)
        let second = "Only an adopted page may generate its next explanation block."
        let speech = ReadAloudHTTPFixture { text, _ in .response(ReadAloudHTTPFixture.body(text, duration: 20)) }
        let planning = plan([first, second], marks: [["action": "underline", "text": "source anchor", "at": 2]])
        let vm = viewModel(speech: speech, plan: planning)
        defer { vm.stop(); vm.deactivate(); speech.close(); planning.close() }
        var payload: ExplainViewModel.PrefetchedFirstBlock? = try await vm.prefetchFirstBlock(
            for: document(), previousSummary: nil, textFingerprint: "target")
        XCTAssertGreaterThan(speech.requests.count, 1, "The finite atomic section must complete all bounded parts despite crossing the watermark")
        XCTAssertGreaterThanOrEqual(audio.speechGeneration.bufferedSeconds, 40, "Unqueued prepared audio occupies the shared buffer")
        XCTAssertFalse(audio.hasQueuedSegments)
        let count = speech.requests.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(speech.requests.count, count, "Source planning cannot synthesize a second speculative block")
        XCTAssertFalse(speech.requests.contains(second))
        vm.startFromPrefetched(try XCTUnwrap(payload))
        try await wait("Adoption must play the complete marked opening") { audio.hasAudibleProgress }
        XCTAssertEqual(vm.debugPreparedMarkTimes, [2])
        XCTAssertFalse(speech.requests.contains(second), "The shared audible budget remains full after adoption")
        vm.stop(); vm.deactivate()
        payload = nil
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(speech.requests.count, count, "Retired background producers cannot dispatch after stop")
    }

    func testPreparedFutureExplanationCannotStarveCurrentAudibleBlock() async throws {
        let audio = AudioPlayerService.shared
        let futureText = "This future page remains prepared but is not adopted."
        let first = "The current explanation must still become audible."
        let second = "Speculative successor must wait once current audio is sufficient."
        let speech = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: input == futureText ? 35 : 15))
        }
        let futurePlan = plan([futureText]), currentPlan = plan([first, second])
        let futureVM = viewModel(speech: speech, plan: futurePlan)
        let currentVM = viewModel(speech: speech, plan: currentPlan)
        defer {
            currentVM.stop(); currentVM.deactivate(); futureVM.stop(); futureVM.deactivate()
            speech.close(); futurePlan.close(); currentPlan.close()
        }
        let future = try await futureVM.prefetchFirstBlock(for: document(), previousSummary: nil,
                                                           textFingerprint: "future-budget-owner")
        XCTAssertEqual(audio.speechGeneration.bufferedSeconds, 35)
        currentVM.startByUser()
        try await wait("Current audible block must not wait forever for an unadopted page") { audio.hasAudibleProgress }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(speech.requests, [futureText, first])
        XCTAssertEqual(audio.currentSegment?.text, first)
        XCTAssertGreaterThan(audio.speechGeneration.bufferedSeconds, 45)
        XCTAssertTrue(currentVM.debugSeekSubtitle(to: 14.95))
        try await wait("A waiting successor must gain audible ownership when the current block drains") {
            audio.currentSegment?.text == second && audio.hasAudibleProgress
        }
        XCTAssertEqual(speech.requests, [futureText, first, second])
        XCTAssertGreaterThan(audio.speechGeneration.bufferedSeconds, 45, "The future page is still retained")
        withExtendedLifetime(future) {}
    }

    func testPathologicalAtomicSectionRejectsBeforeAnyPaidRequest() async throws {
        let speech = ReadAloudHTTPFixture { text, _ in .response(ReadAloudHTTPFixture.body(text)) }
        let planning = plan([String(repeating: "x", count: 2401)])
        let vm = viewModel(speech: speech, plan: planning)
        defer { vm.stop(); vm.deactivate(); speech.close(); planning.close() }
        do {
            _ = try await vm.prefetchFirstBlock(for: document(), previousSummary: nil, textFingerprint: "oversized")
            XCTFail("Oversized composed narration cannot bypass a finite atomic bound")
        } catch {
            XCTAssertTrue(speech.requests.isEmpty)
        }
    }

    func testRollingPreparationWaitsForGlobalBudgetAndStopCancelsTheWaitingProducer() async throws {
        let audio = AudioPlayerService.shared
        let first = "The current explanation is one complete audible block."
        let second = "A future block must wait behind the current audible budget."
        let speech = ReadAloudHTTPFixture { text, _ in .response(ReadAloudHTTPFixture.body(text, duration: 40)) }
        let planning = plan([first, second, "A third block cannot overtake the second."])
        let vm = viewModel(speech: speech, plan: planning)
        defer { vm.stop(); vm.deactivate(); speech.close(); planning.close() }
        vm.startByUser()
        try await wait("First block must play") { audio.hasAudibleProgress }
        try await wait("Shared budget must block successor") { audio.speechGeneration.isWaitingForBudget }
        let position = audio.playbackPosition
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(audio.playbackPosition, position, "Producer backpressure must not pause AVPlayer")
        XCTAssertEqual(speech.requests, [first])
        vm.stop(); vm.deactivate()
        audio.speechGeneration.notify()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(speech.requests, [first], "Owned waiting tasks must be cancelled rather than revived by empty budget")
        XCTAssertFalse(audio.isPlaying)
    }
}
