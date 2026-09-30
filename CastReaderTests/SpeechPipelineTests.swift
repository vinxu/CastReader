import XCTest
import Combine
@testable import CastReader

@MainActor
final class SpeechPipelineTests: XCTestCase {
    private var root: URL!
    private var oldPro = false
    private var oldSpeed: Double = 1
    private var oldEnglishVoice = ""
    private var oldChineseVoice = ""

    func testReviewEligibilityIgnoresMediaTicksButTracksBufferedAndPlayingStates() async throws {
        let audio = AudioPlayerService.shared
        let token = audio.claimPlaybackSession(owner: .readAloud)
        defer { audio.releasePlaybackSession(token) }
        _ = audio.clearQueue(session: token)
        _ = audio.setMoreSegmentsExpected(false, session: token)
        audio.isPlaying = false
        audio.isBuffering = false
        var values: [Bool] = []
        let observation = audio.reviewQuiescencePublisher.sink { values.append($0) }
        defer { observation.cancel() }
        try await wait { values == [true] }
        for i in 0..<100 { audio.currentTime = Double(i) / 20 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(values, [true], "Audio progress must not invalidate root navigation")
        _ = audio.setMoreSegmentsExpected(true, session: token)
        try await wait { values.last == false }
        audio.isBuffering = true
        audio.isPlaying = true
        _ = audio.setMoreSegmentsExpected(false, session: token)
        audio.isBuffering = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(values, [true, false], "Buffered/playing transitions remain ineligible")
        audio.isPlaying = false
        try await wait { values == [true, false, true] }
        audio.currentTime = 0
    }
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        oldSpeed = Double(AppSettings.shared.speed)
        oldEnglishVoice = AppSettings.shared.voice(for: "en")
        oldChineseVoice = AppSettings.shared.voice(for: "zh")
        AppSettings.shared.speed = 1
        oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        useRegularVoiceForTest(language: "en")
    }
    override func tearDown() async throws {
        ProManager.shared.debugForcePro = oldPro
        AppSettings.shared.speed = oldSpeed
        AppSettings.shared.setVoice(oldEnglishVoice, for: "en")
        AppSettings.shared.setVoice(oldChineseVoice, for: "zh")
        try? FileManager.default.removeItem(at: root)
    }
    private func wait(_ condition: () -> Bool, timeout: Double = 6) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }
    private func makeVM(_ source: ReadingSourceKind, fixture: ReadAloudHTTPFixture,
                        texts: [String]) -> (ReadAloudViewModel, AudioPlayerService) {
        let player = AudioPlayerService(testTemporaryRoot: root)
        let paragraphs = texts.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) }
        let doc = ReadingDocument(id: UUID().uuidString, title: "Stream fixture", sourceKind: source,
                                  language: "en", paragraphs: source.isWebRendered ? [] : paragraphs)
        let vm = ReadAloudViewModel(document: doc, audioService: player,
                                   ttsService: fixture.service(), historyStore: HistoryStore(directory: root))
        if source.isWebRendered { vm.loadWebParagraphs(paragraphs, language: "en") }
        return (vm, player)
    }

    func testPrefetchedExplanationStartsBeforePlanDoneAndKeepsSameJob() async throws {
        try await verifyEarlyPrefetchedPlan(stopBeforeDone: false)
    }

    func testFullyConsumedCarryCanPrepareSuccessorBeforeAudioEndsButNotWhilePaused() async throws {
        let fixture = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 3))
        }
        defer { fixture.close() }
        let (vm, audio) = makeVM(.weread, fixture: fixture, texts: ["The carried sentence finishes on this page."])
        defer { vm.stop(); vm.deactivate(); audio.stop() }
        vm.start()
        try await wait { audio.isPlaying && !audio.moreSegmentsExpected }
        let current = try XCTUnwrap(audio.currentSegment)
        XCTAssertTrue(vm.commitLiveWebPageDuringActiveCarry(
            [ReadingParagraph(id: 0, text: "finishes on this page.", speechText: "")],
            language: "en", carrySegmentID: current.id))
        XCTAssertTrue(vm.isOnLastReadableParagraph)
        XCTAssertTrue(vm.currentTTSCompleteForPageHandoff)
        XCTAssertTrue(vm.canPrepareAdjacentLivePageAudio,
                      "A carry-only visual page still owns real playable source audio")
        vm.togglePlayPause()
        XCTAssertFalse(vm.canPrepareAdjacentLivePageAudio)
        let position = audio.playbackPosition
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(audio.playbackPosition, position, accuracy: 0.01)
        vm.togglePlayPause()
        try await wait { audio.isPlaying }
        XCTAssertTrue(vm.canPrepareAdjacentLivePageAudio)
    }

    func testConfirmedShortOpeningAdoptsPendingSuccessorExactlyOnce() async throws {
        try await verifyPendingAdjacentReserve(stopAfterAdoption: false)
    }

    func testStoppedPendingAdjacentReserveCannotRevivePlayback() async throws {
        try await verifyPendingAdjacentReserve(stopAfterAdoption: true)
    }

    func testPausedPendingAdjacentReserveWaitsForExplicitResume() async throws {
        try await verifyPendingAdjacentReserve(stopAfterAdoption: false, pauseAfterAdoption: true)
    }

    private func verifyPendingAdjacentReserve(stopAfterAdoption: Bool, pauseAfterAdoption: Bool = false) async throws {
        let head = "Short opening."
        let body = "The pending successor continues the confirmed source exactly once."
        let fixture = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: text == head ? 1.2 : 2),
                      delay: text == body ? 0.6 : 0)
        }
        defer { fixture.close() }
        let (vm, audio) = makeVM(.weread, fixture: fixture, texts: ["Original page."])
        defer { vm.stop(); vm.deactivate(); audio.stop() }
        let voice = AppSettings.shared.voice(for: "en")
        let generatedOpening = try await fixture.service().generatePagePrefetchSegments(
            paragraphIndex: 0, text: head, voice: voice, language: "en")
        // Production rebases the successor before queueing. Its page-local
        // 0-0 transport ID must not masquerade as the predecessor's boundary.
        let opening = generatedOpening.map { segment in
            AudioSegment(paragraphIndex: segment.paragraphIndex, segmentIndex: 800_000_000 + segment.segmentIndex,
                audioData: segment.audioData, timestamps: segment.timestamps, duration: segment.duration,
                text: segment.text, isWavFormat: segment.isWavFormat, unprocessedText: segment.unprocessedText,
                speaker: segment.speaker, timingTimestamps: segment.timingTimestamps)
        }
        let reserve = LivePagePreparedSpeech(paragraphIndex: 1, sourceText: body, voice: voice, language: "en")
        vm.start()
        try await wait { audio.isPlaying && !audio.moreSegmentsExpected }
        var adopted = false
        XCTAssertTrue(audio.armQueuedTailPresentationBoundary { hold in
            reserve.start(generator: fixture.service(), audio: audio, speechInput: body,
                          isCurrent: { !adopted }, fitsBudget: { true })
            adopted = vm.commitContinuousLiveWebPage(
                [ReadingParagraph(id: 0, text: head), ReadingParagraph(id: 1, text: body)],
                language: "en", preparedSegments: opening, following: [reserve])
            XCTAssertTrue(adopted)
            XCTAssertTrue(reserve.adopted)
            XCTAssertFalse(reserve.stream.finished)
            XCTAssertTrue(audio.finishPagePresentation(hold))
        })
        XCTAssertNotNil(audio.appendPreparedSegmentsForContinuousPlayback(opening))
        try await wait { adopted }
        if stopAfterAdoption {
            vm.stop()
            try await Task.sleep(for: .milliseconds(1100))
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(audio.currentSegment)
            XCTAssertLessThanOrEqual(fixture.requests.filter { $0 == body }.count, 1)
        } else {
            if pauseAfterAdoption {
                try await wait { audio.currentSegment?.text == head && audio.isPlaying }
                vm.togglePlayPause()
                let position = audio.playbackPosition
                try await Task.sleep(for: .milliseconds(1100))
                XCTAssertFalse(audio.isPlaying)
                XCTAssertEqual(audio.currentSegment?.text, head)
                XCTAssertEqual(audio.playbackPosition, position, accuracy: 0.02)
                vm.togglePlayPause()
            }
            try await wait { audio.currentSegment?.text == body && audio.isPlaying }
            XCTAssertEqual(fixture.requests.filter { $0 == body }.count, 1,
                           "Visible-page adoption must retain the in-flight producer")
        }
    }

    func testStoppedEarlyPrefetchedPlanCannotReviveAfterDone() async throws {
        try await verifyEarlyPrefetchedPlan(stopBeforeDone: true)
    }

    func testPagePrefetchPreparesOneSuccessorBeforeTakeAndNeverRegeneratesIt() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        let oldLanguage = AppSettings.shared.explainLanguage
        AppSettings.shared.explainLanguage = "en"
        let texts = ["The prepared opening introduces the idea.", "Its successor continues that same idea.", "Only playback demand prepares the final explanation."]
        func section(_ index: Int) -> [String: Any] {
            ["id": "block-\(index)", "text": texts[index], "style": "explain", "cinematic": ["events": []]]
        }
        let speech = ReadAloudHTTPFixture { text, _ in .response(ReadAloudHTTPFixture.body(text, duration: 0.9)) }
        let plan = ReadAloudHTTPFixture.forRequests { request, body in
            switch request.url?.path {
            case "/api/quickread/extract-plan":
                let first: [String: Any] = ["job_id": "bounded-page", "output_language": "en", "total_blocks": 3, "block_0": section(0)]
                let json = String(data: try! JSONSerialization.data(withJSONObject: first), encoding: .utf8)!
                return .response(Data("event: block0\ndata: \(json)\n\nevent: done\ndata: {\"job_id\":\"bounded-page\",\"total_blocks\":3}\n\n".utf8))
            case "/api/quickread/extract-block":
                return .response(try! JSONSerialization.data(withJSONObject: ["section": section(body["block_idx"] as? Int ?? 1)]))
            default: return .response(Data("{\"events\":[]}".utf8))
            }
        }
        let document = ReadingDocument(title: "Bounded producer", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "This page contains enough original source material to explain. Its prepared opening and following narration must keep their original production job across a page handover.")])
        let vm = ExplainViewModel(document: document, speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session, mobileSessionProvider: SpeechPipelineSessionProvider()))
        defer { vm.stop(); vm.deactivate(); audio.clearForAccountBoundary(); speech.close(); plan.close(); AppSettings.shared.explainLanguage = oldLanguage }
        let payload = try await vm.prefetchFirstBlock(for: document, previousSummary: "Previous page context", textFingerprint: "page-b")
        try await wait { speech.requests.contains(texts[1]) }
        XCTAssertFalse(audio.isPlaying, "Speculation must remain inaudible")
        XCTAssertFalse(speech.requests.contains(texts[2]), "Speculation is bounded to one successor")
        var completions = 0
        vm.onDocumentFinished = { completions += 1 }
        vm.startFromPrefetched(payload)
        try await wait({ completions == 1 }, timeout: 7)
        for text in texts { XCTAssertEqual(speech.requests.filter { $0 == text }.count, 1) }
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, 1)
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-block" && ($0.body["block_idx"] as? Int) == 1 }.count, 1)
    }

    func testNextPagePlanMayRunButItsSpeechWaitsForAudiblePageSuccessor() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        let oldLanguage = AppSettings.shared.explainLanguage
        AppSettings.shared.explainLanguage = "en"
        let opening = "The audible page introduces the idea."
        let successor = "Its immediate successor must be ready before speculative speech."
        let future = "The following page has its own explanation."
        func section(_ text: String) -> [String: Any] {
            ["id": "block", "text": text, "style": "explain", "cinematic": ["events": []]]
        }
        let speech = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 5), delay: text == successor ? 2 : 0)
        }
        let plan = ReadAloudHTTPFixture.forRequests { request, body in
            switch request.url?.path {
            case "/api/quickread/extract-plan":
                let isFuture = (body["text"] as? String)?.hasPrefix("Future source") == true
                let job = isFuture ? "future-job" : "audible-job"
                let count = isFuture ? 1 : 2
                let first: [String: Any] = ["job_id": job, "output_language": "en", "total_blocks": count,
                    "block_0": section(isFuture ? future : opening)]
                let json = String(data: try! JSONSerialization.data(withJSONObject: first), encoding: .utf8)!
                return .response(Data("event: block0\ndata: \(json)\n\nevent: done\ndata: {\"job_id\":\"\(job)\",\"total_blocks\":\(count)}\n\n".utf8))
            case "/api/quickread/extract-block":
                return .response(try! JSONSerialization.data(withJSONObject: ["section": section(successor)]))
            default:
                let text = body["job_id"] as? String == "future-job" ? future : ((body["block_idx"] as? Int) == 1 ? successor : opening)
                return .response(try! JSONSerialization.data(withJSONObject: ["section": section(text)]))
            }
        }
        func document(_ prefix: String) -> ReadingDocument {
            ReadingDocument(title: "Speech admission", sourceKind: .kindle, language: "en",
                paragraphs: [ReadingParagraph(id: 0, text: prefix + " contains enough meaningful original source text for a complete explanation with a prepared opening and a following section.")])
        }
        let current = document("Current source")
        let vm = ExplainViewModel(document: current, speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session, mobileSessionProvider: SpeechPipelineSessionProvider()))
        defer { vm.stop(); vm.deactivate(); audio.clearForAccountBoundary(); speech.close(); plan.close(); AppSettings.shared.explainLanguage = oldLanguage }
        let ready = try await vm.prefetchFirstBlock(for: current, previousSummary: nil, textFingerprint: "current")
        vm.startFromPrefetched(ready)
        try await wait { audio.isPlaying && speech.requests.contains(successor) }
        let work = Task { try await vm.prefetchFirstBlock(for: document("Future source"), previousSummary: nil, textFingerprint: "future") }
        defer { work.cancel() }
        try await wait { plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count == 2 }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(speech.requests.contains(future), "Future-page synthesis cannot jump ahead of the current successor")
        _ = try await work.value
        XCTAssertNotNil(vm.debugPreparedVoiceIDs[1], "The audible successor must finish first")
        XCTAssertEqual(vm.currentBlockIndex, 0)
        XCTAssertNotEqual(audio.currentSegment?.text, future, "Speculative audio remains inaudible")
        XCTAssertEqual(speech.requests.filter { $0 == successor }.count, 1, "Adoption must not deadlock or regenerate its own successor")
    }

    func testAdjacentPlanStartsBeforeOpeningAudioButSpeechKeepsCurrentReserve() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        let oldLanguage = AppSettings.shared.explainLanguage
        AppSettings.shared.explainLanguage = "en"
        let opening = "The opening must receive the first speech slot."
        let successor = "The current page also needs its complete successor."
        let future = "The adjacent page is planned while the opening is still loading."
        func section(_ text: String) -> [String: Any] {
            ["id": "section", "text": text, "cinematic": ["events": []]]
        }
        let speech = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 6),
                      delay: text == opening ? 2 : text == successor ? 3 : 0)
        }
        let plan = ReadAloudHTTPFixture.forRequests { request, body in
            let isFuture = (body["text"] as? String)?.hasPrefix("Future source") == true
            let job = isFuture ? "early-next" : "early-current"
            if request.url?.path == "/api/quickread/extract-plan" {
                let count = isFuture ? 1 : 2
                let first: [String: Any] = ["job_id": job, "output_language": "en", "total_blocks": count,
                                           "block_0": section(isFuture ? future : opening)]
                let done: [String: Any] = ["job_id": job, "total_blocks": count,
                                          "page_summary": "The current page introduces the original idea."]
                let a = String(data: try! JSONSerialization.data(withJSONObject: first), encoding: .utf8)!
                let b = String(data: try! JSONSerialization.data(withJSONObject: done), encoding: .utf8)!
                return .response(Data("event: block0\ndata: \(a)\n\nevent: done\ndata: \(b)\n\n".utf8))
            }
            if request.url?.path == "/api/quickread/extract-block" {
                return .response(try! JSONSerialization.data(withJSONObject: ["section": section(successor)]))
            }
            return .response(Data("{\"events\":[]}".utf8))
        }
        func document(_ prefix: String) -> ReadingDocument {
            ReadingDocument(title: "Early adjacent planning", sourceKind: .kindle, language: "en",
                paragraphs: [ReadingParagraph(id: 0, text: prefix + " contains sufficient original text for a page explanation. This is the exact page source used to prepare the narration.")])
        }
        let vm = ExplainViewModel(document: document("Current source"), speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session, mobileSessionProvider: SpeechPipelineSessionProvider()))
        defer { vm.stop(); vm.deactivate(); audio.clearForAccountBoundary(); speech.close(); plan.close(); AppSettings.shared.explainLanguage = oldLanguage }
        XCTAssertFalse(vm.canPlanAdjacentLivePage)
        vm.startByUser()
        try await wait({ vm.adjacentPlanRevision > 0 && vm.canPlanAdjacentLivePage }, timeout: 1.5)
        XCTAssertEqual(vm.currentBlockIndex, -1, "The bridge gets a planning event before opening media exists")
        XCTAssertEqual(vm.currentContinuitySummary(), "The current page introduces the original idea.")
        let next = Task { try await vm.prefetchFirstBlock(for: document("Future source"),
            previousSummary: vm.currentContinuitySummary(), textFingerprint: "early-next-source") }
        defer { next.cancel() }
        try await wait({ plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count == 2 }, timeout: 1)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(speech.requests.contains(future), "Early planning cannot steal the opening's speech capacity")
        XCTAssertFalse(audio.isPlaying)
        _ = try await next.value
        XCTAssertNotNil(vm.debugPreparedVoiceIDs[0])
        XCTAssertNotNil(vm.debugPreparedVoiceIDs[1])
        XCTAssertEqual(vm.currentBlockIndex, 0)
        XCTAssertNotEqual(audio.currentSegment?.text, future)
        vm.togglePlayPause()
        XCTAssertFalse(vm.canPlanAdjacentLivePage, "Pause must close early planning admission")
        vm.stop()
        XCTAssertFalse(vm.canPlanAdjacentLivePage)
    }

    func testPendingPageAdoptionKeepsSlowProducerPastFifteenSeconds() async throws {
        try await verifyPendingPageAdoption(stop: false)
    }

    func testExplanationVoiceSwitchRefillsSuccessorBeforeCurrentBlockEnds() async throws {
        try await verifyExplanationVoiceSwitchBuffer(paused: false)
    }

    func testPausedExplanationVoiceSwitchRefillsSuccessorOnResume() async throws {
        try await verifyExplanationVoiceSwitchBuffer(paused: true)
    }

    private func verifyExplanationVoiceSwitchBuffer(paused: Bool) async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        let oldLanguage = AppSettings.shared.explainLanguage
        let oldVoice = AppSettings.shared.voice(for: "en")
        AppSettings.shared.explainLanguage = "en"
        let texts = ["This opening is long enough to prepare its successor before it ends.",
                     "The same successor keeps its explanation and changes only its voice."]
        func section(_ index: Int) -> [String: Any] {
            ["id": "block-\(index)", "text": texts[index], "cinematic": ["events": []]]
        }
        let speech = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: text == texts[0] ? 5 : 1))
        }
        let plan = ReadAloudHTTPFixture.forRequests { request, body in
            if request.url?.path == "/api/quickread/extract-plan" {
                let first: [String: Any] = ["job_id": "revoice-buffer", "output_language": "en", "total_blocks": 2, "block_0": section(0)]
                let json = String(data: try! JSONSerialization.data(withJSONObject: first), encoding: .utf8)!
                return .response(Data("event: block0\ndata: \(json)\n\nevent: done\ndata: {\"job_id\":\"revoice-buffer\",\"total_blocks\":2}\n\n".utf8))
            }
            if request.url?.path == "/api/quickread/extract-block" {
                return .response(try! JSONSerialization.data(withJSONObject: ["section": section(1)]))
            }
            return .response(try! JSONSerialization.data(withJSONObject: ["section": section(body["block_idx"] as? Int ?? 0)]))
        }
        let document = ReadingDocument(title: "Revoice buffer", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: texts.joined(separator: " "))])
        let vm = ExplainViewModel(document: document, speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session, mobileSessionProvider: SpeechPipelineSessionProvider()))
        defer {
            vm.stop(); vm.deactivate(); audio.clearForAccountBoundary(); speech.close(); plan.close()
            AppSettings.shared.explainLanguage = oldLanguage; AppSettings.shared.setVoice(oldVoice, for: "en")
        }
        let payload = try await vm.prefetchFirstBlock(for: document, previousSummary: nil, textFingerprint: "revoice-page")
        vm.startFromPrefetched(payload)
        try await wait { audio.isPlaying && vm.debugPreparedVoiceIDs[1] == oldVoice }
        if paused { vm.togglePlayPause() }
        AppSettings.shared.setVoice("af_bella", for: "en")
        try await wait { vm.debugPreparedVoiceIDs[0] == "af_bella" && VoiceSwitchStatusCenter.shared.progress == nil }
        if paused {
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(vm.debugPreparedVoiceIDs[1], "Explicit pause must backpressure future synthesis")
            vm.ensurePlaying()
        }
        try await wait { vm.debugPreparedVoiceIDs[1] == "af_bella" }
        XCTAssertEqual(vm.currentBlockIndex, 0, "Rebuild the successor during the current block, not at its end")
        let successor = try XCTUnwrap(vm.debugPreparedSegments(block: 1).first)
        try await wait { audio.isPreparedForPlayback(successor) }
        let decoder = try XCTUnwrap(audio.preparedMediaForTesting(successor)?.player)
        XCTAssertEqual(vm.currentBlockIndex, 0, "Decode the immediate successor before the audible block ends")
        XCTAssertEqual(speech.requests.filter { $0 == texts[1] }.count, 2, "One synthesis per voice")
        try await wait({ vm.currentBlockIndex == 1 && audio.isPlaying }, timeout: 7)
        XCTAssertTrue(audio.activePlayerForTesting === decoder, "Block turnover must adopt the exact prepared decoder across clearQueue")
        XCTAssertEqual(speech.requests.filter { $0 == texts[1] }.count, 2, "The prepared successor must not regenerate at takeover")
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, 1)
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-block" }.count, 1)
    }

    func testStoppedPendingPageAdoptionCancelsWithoutLateAudio() async throws {
        try await verifyPendingPageAdoption(stop: true)
    }

    func testPendingPageAdoptionBeforeOpeningHasNoReserveDeadlock() async throws {
        try await verifyPendingPageAdoption(stop: false, beforePlan: true)
    }

    func testIdleActivatedModeCanPreparePageWithoutWaitingForPlayback() async throws {
        try await verifyPendingPageAdoption(stop: false, activateIdle: true)
    }

    private func verifyPendingPageAdoption(stop: Bool, beforePlan: Bool = false, activateIdle: Bool = false) async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        let oldLanguage = AppSettings.shared.explainLanguage
        AppSettings.shared.explainLanguage = "en"
        let narration = "The original pending producer reaches this exact page without a second request."
        let speech = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 0.6), delay: stop || beforePlan || activateIdle ? 1 : 16)
        }
        let plan = ReadAloudHTTPFixture.forRequests { request, _ in
            guard request.url?.path == "/api/quickread/extract-plan" else {
                return .response(Data("{\"events\":[]}".utf8))
            }
            let first: [String: Any] = ["job_id": "pending-page", "output_language": "en", "total_blocks": 1,
                "block_0": ["id": "block", "text": narration, "style": "explain", "cinematic": ["events": []]]]
            let json = String(data: try! JSONSerialization.data(withJSONObject: first), encoding: .utf8)!
            return .response(Data("event: block0\ndata: \(json)\n\nevent: done\ndata: {\"job_id\":\"pending-page\",\"total_blocks\":1}\n\n".utf8))
        }
        let document = ReadingDocument(title: "Pending page", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "This original text is long enough for a real explanation. The visible page takes an already running speculative job, including all pending audio and its cancellation ownership.")])
        let vm = ExplainViewModel(document: document, speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session, mobileSessionProvider: SpeechPipelineSessionProvider()))
        defer { vm.stop(); vm.deactivate(); audio.clearForAccountBoundary(); speech.close(); plan.close(); AppSettings.shared.explainLanguage = oldLanguage }
        if activateIdle { vm.activate() }
        let work = Task { try await vm.prefetchFirstBlock(for: document, previousSummary: nil, textFingerprint: "pending-target") }
        if !beforePlan { try await wait { speech.requests.contains(narration) } }
        vm.startFromPendingPagePrefetch(work)
        if stop {
            vm.stop(); vm.deactivate()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertTrue(work.isCancelled)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertNil(audio.currentSegment)
        } else {
            try await wait({ audio.hasAudibleProgress }, timeout: 22)
            XCTAssertFalse(work.isCancelled)
            XCTAssertEqual(audio.currentSegment?.text, narration)
        }
        XCTAssertEqual(speech.requests.filter { $0 == narration }.count, 1)
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, 1)
    }

    func testShortPageEligibilityUsesTargetLanguage() {
        let english = ReadingDocument(title: "Title", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "Chapter Two")])
        let chinese = ReadingDocument(title: "中文", sourceKind: .kindle, language: "zh",
            paragraphs: [ReadingParagraph(id: 0, text: "当前页包含足够的中文正文，可以开始准备连续讲解。")])
        XCTAssertFalse(ExplainViewModel.canPrefetchExplanation(english))
        XCTAssertTrue(ExplainViewModel.canPrefetchExplanation(chinese))
    }

    private func verifyEarlyPrefetchedPlan(stopBeforeDone: Bool) async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        let oldLanguage = AppSettings.shared.explainLanguage
        AppSettings.shared.explainLanguage = "en"
        let first = "A prepared opening is ready before the plan finishes."
        let second = "The same plan supplies the remaining explanation."
        func section(_ text: String) -> [String: Any] {
            ["id": "block", "text": text, "style": "explain", "cinematic": ["events": []]]
        }
        let speech = ReadAloudHTTPFixture { text, _ in .response(ReadAloudHTTPFixture.body(text, duration: 0.7)) }
        let plan = ReadAloudHTTPFixture.forRequests { request, body in
            switch request.url?.path {
            case "/api/quickread/extract-plan":
                let block: [String: Any] = ["job_id": "early-plan", "output_language": "en",
                    "total_blocks": 0, "block_0": section(first)]
                let json = String(data: try! JSONSerialization.data(withJSONObject: block), encoding: .utf8)!
                return .stream([Data("event: block0\ndata: \(json)\n\nevent: stage\ndata: {\"stage\":\"planning\"}\n\n".utf8),
                    Data("event: done\ndata: {\"job_id\":\"early-plan\",\"total_blocks\":2,\"page_summary\":\"The original idea is now established; continue with its consequence.\"}\n\n".utf8)], interval: 2.5)
            case "/api/quickread/extract-block":
                return .response(try! JSONSerialization.data(withJSONObject: ["section": section(second)]))
            default:
                return .response(try! JSONSerialization.data(withJSONObject: ["section": section((body["block_idx"] as? Int) == 1 ? second : first)]))
            }
        }
        let document = ReadingDocument(title: "Early page", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "This source page contains enough meaningful text for explanation. Its first idea and later idea must remain attached to one exact planning job during a page handover.")])
        let vm = ExplainViewModel(document: document, speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session, mobileSessionProvider: SpeechPipelineSessionProvider()))
        defer { vm.stop(); vm.deactivate(); audio.clearForAccountBoundary(); speech.close(); plan.close(); AppSettings.shared.explainLanguage = oldLanguage }
        var completions = 0
        vm.onDocumentFinished = { completions += 1 }
        let began = Date()
        let payload = try await vm.prefetchFirstBlock(for: document, previousSummary: nil, textFingerprint: "exact-target")
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "Ready first media cannot wait for done")
        vm.startFromPrefetched(payload)
        try await wait { audio.hasAudibleProgress }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2.5)
        XCTAssertEqual(completions, 0, "Placeholder total=0 cannot authorize early page completion")
        if stopBeforeDone {
            vm.stop(); vm.deactivate()
            try await Task.sleep(nanoseconds: 2_700_000_000)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertFalse(speech.requests.contains(second))
            XCTAssertEqual(completions, 0)
            XCTAssertNil(vm.currentContinuitySummary(), "A stopped producer cannot restore late page context")
        } else {
            try await wait({ completions == 1 }, timeout: 6)
            XCTAssertEqual(speech.requests.filter { $0 == first }.count, 1)
            XCTAssertEqual(speech.requests.filter { $0 == second }.count, 1)
            XCTAssertTrue(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-block" }
                .allSatisfy { $0.body["job_id"] as? String == "early-plan" })
            XCTAssertEqual(vm.currentContinuitySummary(), "The original idea is now established; continue with its consequence.")
            vm.loadWebParagraphs([ReadingParagraph(id: 0, text: "A different source revision.")])
            XCTAssertNil(vm.currentContinuitySummary(), "A summary cannot attach to replaced source text")
        }
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, 1)
    }

    func testRetainedReaderCannotStealNewDocumentOnVoiceChange() async throws {
        let fixture = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 4))
        }
        let player = AudioPlayerService(testTemporaryRoot: root)
        func reader(_ text: String) -> ReadAloudViewModel {
            ReadAloudViewModel(document: ReadingDocument(title: text, sourceKind: .text,
                language: "en", paragraphs: [ReadingParagraph(id: 0, text: text)]),
                audioService: player, ttsService: fixture.service(), historyStore: HistoryStore(directory: root))
        }
        let old = reader("Old document.")
        let current = reader("Current document.")
        defer { old.stop(); old.deactivate(); current.stop(); current.deactivate(); player.stop(); fixture.close() }
        old.dbgGenerate(0)
        await old.dbgWaitGeneration()
        old.pausePlayback()
        // A retained host has not received onDisappear/deactivate yet.
        current.dbgGenerate(0)
        await current.dbgWaitGeneration()
        AppSettings.shared.setVoice("af_bella", for: "en")
        try await wait { fixture.requests.filter { $0 == "Current document." }.count == 2 && player.hasAudibleProgress }
        XCTAssertEqual(fixture.requests.filter { $0 == "Old document." }.count, 1)
        XCTAssertEqual(player.currentSegment?.text, "Current document.")
        XCTAssertTrue(old.dbgSegments(for: 0).isEmpty, "A later explicit resume must regenerate with the new voice")
    }

    func testExplicitExplainStartReplacesInheritedReadPause() async throws {
        try await verifyExplainStartAfterReadPause(explicitStart: true, pauseDuringPlan: false)
    }

    func testExplainPrefetchRejectsExpiredAndFutureClockEntries() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(QuickReadPrefetchLifetime.isUsable(createdAt: created, now: created.addingTimeInterval(60)))
        XCTAssertFalse(QuickReadPrefetchLifetime.isUsable(createdAt: created, now: created.addingTimeInterval(110 * 60)))
        XCTAssertFalse(QuickReadPrefetchLifetime.isUsable(createdAt: created, now: created.addingTimeInterval(2 * 3600 + 9 * 60)))
        XCTAssertFalse(QuickReadPrefetchLifetime.isUsable(createdAt: created, now: created.addingTimeInterval(-1)))
    }

    func testExpiredExplainPrefetchReplansBeforePlayingCachedOpening() async throws {
        try await verifyUnavailableExplainJob(scenario: "stale-prefetch")
    }

    func testUnavailableExplainJobResumesMissingBlockWithoutReplayingOpening() async throws {
        try await verifyUnavailableExplainJob(scenario: "recover")
    }

    func testUnavailableExplainJobCannotReuseChangedPlanIndexes() async throws {
        try await verifyUnavailableExplainJob(scenario: "changed-prefix")
    }

    func testUnavailableExplainJobRecoveryIsBounded() async throws {
        try await verifyUnavailableExplainJob(scenario: "still-unavailable")
    }

    func testGenericExplain404DoesNotReplan() async throws {
        try await verifyUnavailableExplainJob(scenario: "generic-404")
    }

    func testPauseDuringExplainJobRecoveryRemainsPaused() async throws {
        try await verifyUnavailableExplainJob(scenario: "pause")
    }

    func testClosedExplainPageRejectsLateJobRecovery() async throws {
        try await verifyUnavailableExplainJob(scenario: "close")
    }

    private func verifyUnavailableExplainJob(scenario: String) async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        let previousLanguage = AppSettings.shared.explainLanguage
        AppSettings.shared.explainLanguage = "en"
        let opening = "This opening has already been explained."
        let replacement = "This is a freshly prepared opening."
        let remaining = "Only the remaining explanation should play next."
        var clock = Date()
        var plans = 0
        func section(_ index: Int, _ text: String) -> [String: Any] {
            ["id": "block-\(index)", "text": text, "style": "explain", "cinematic": ["events": []]]
        }
        let speech = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 0.7))
        }
        let plan = ReadAloudHTTPFixture.forRequests { request, body in
            if request.url?.path == "/api/quickread/extract-plan" {
                plans += 1
                let text = plans > 1 && ["stale-prefetch", "changed-prefix"].contains(scenario) ? replacement : opening
                let block: [String: Any] = ["job_id": "lease-\(plans)", "output_language": "en",
                    "total_blocks": 2, "block_0": section(0, text)]
                let blockJSON = String(data: try! JSONSerialization.data(withJSONObject: block), encoding: .utf8)!
                return .response(Data("event: block0\ndata: \(blockJSON)\n\nevent: done\ndata: {\"job_id\":\"lease-\(plans)\",\"total_blocks\":2}\n\n".utf8),
                    delay: plans > 1 ? 0.45 : 0)
            }
            let index = body["block_idx"] as? Int ?? 0
            if request.url?.path == "/api/quickread/extract-block",
               body["job_id"] as? String == "lease-1" || scenario == "still-unavailable" {
                let code = scenario == "generic-404" ? "ROUTE_NOT_FOUND" : "QUICKREAD_JOB_NOT_FOUND"
                return .response(Data("{\"code\":\"\(code)\"}".utf8), status: 404)
            }
            let text = index == 0 ? (scenario == "stale-prefetch" && plans > 1 ? replacement : opening) : remaining
            return .response(try! JSONSerialization.data(withJSONObject: ["section": section(index, text)]))
        }
        let document = ReadingDocument(title: "Expired Kindle task", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "This source page has an opening idea followed by a second idea that still needs to be explained to the listener.")])
        let vm = ExplainViewModel(document: document, speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session, mobileSessionProvider: SpeechPipelineSessionProvider()),
            now: { clock })
        var played: [String] = []
        audio.onSegmentComplete = { if let text = audio.currentSegment?.text { played.append(text) } }
        defer {
            vm.stop(); vm.deactivate(); audio.clearForAccountBoundary()
            speech.close(); plan.close(); AppSettings.shared.explainLanguage = previousLanguage
        }
        if scenario == "stale-prefetch" {
            let prefetched = try await vm.prefetchFirstBlock(for: document, previousSummary: nil, textFingerprint: "fixture")
            clock = clock.addingTimeInterval(2 * 3600 + 9 * 60)
            vm.startFromPrefetched(prefetched)
        } else {
            vm.startByUser()
        }
        if ["pause", "close"].contains(scenario) {
            try await wait { plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count == 2 }
            if scenario == "close" {
                vm.stop(); vm.deactivate()
                try await Task.sleep(nanoseconds: 700_000_000)
                XCTAssertFalse(audio.isPlaying)
                XCTAssertFalse(speech.requests.contains(remaining))
                return
            }
            let session = try XCTUnwrap(audio.activePlaybackSession)
            XCTAssertTrue(audio.pause(session: session))
            try await wait { vm.currentBlockIndex == 1 }
            XCTAssertFalse(audio.isPlaying)
            XCTAssertTrue(audio.isExplicitlyPaused)
            vm.togglePlayPause()
        }
        if ["changed-prefix", "still-unavailable", "generic-404"].contains(scenario) {
            try await wait { if case .error = vm.status { return true }; return false }
            XCTAssertEqual(played, [opening])
            XCTAssertFalse(speech.requests.contains(remaining))
        } else {
            try await wait { vm.status == .completed }
            XCTAssertEqual(played, [scenario == "stale-prefetch" ? replacement : opening, remaining])
        }
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count,
            scenario == "generic-404" ? 1 : 2)
        if scenario != "stale-prefetch" {
            XCTAssertEqual(speech.requests.filter { $0 == opening }.count, 1)
        }
    }

    func testPauseDuringExplicitExplainPreparationStillWins() async throws {
        try await verifyExplainStartAfterReadPause(explicitStart: true, pauseDuringPlan: true)
    }

    func testAutomaticExplainStartPreservesInheritedPause() async throws {
        try await verifyExplainStartAfterReadPause(explicitStart: false, pauseDuringPlan: false)
    }

    private func verifyExplainStartAfterReadPause(explicitStart: Bool, pauseDuringPlan: Bool) async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        let priorAutoPlay = AppSettings.shared.autoPlay
        AppSettings.shared.autoPlay = false
        let narration = "This is a new explanation rather than the old reading audio."
        let speech = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 3))
        }
        let plan = ReadAloudHTTPFixture.forRequests { request, _ in
            if request.url?.path == "/api/quickread/compose-block" {
                return .response(Data("{\"section\":{\"id\":\"block-0\",\"text\":\"\(narration)\",\"style\":\"explain\",\"cinematic\":{\"events\":[]}}}".utf8))
            }
            return .response(Data("""
            event: block0
            data: {"job_id":"pause-intent-plan","output_language":"en","total_blocks":1,"block_0":{"id":"block-0","text":"\(narration)","style":"explain","cinematic":{"events":[]}}}

            event: done
            data: {"job_id":"pause-intent-plan","total_blocks":1}

            """.utf8), delay: 0.35)
        }
        let document = ReadingDocument(title: "Explicit explanation start", sourceKind: .text,
            language: "en", paragraphs: [ReadingParagraph(id: 0,
                text: "Listening while reading helps connect spoken words with their written meaning. A short pause leaves time to reflect on the main idea.")])
        let vm = ExplainViewModel(document: document, speechGenerator: speech.service(),
            quickReadService: QuickReadService(session: plan.session,
                mobileSessionProvider: SpeechPipelineSessionProvider()))
        defer {
            vm.stop(); vm.deactivate(); audio.clearForAccountBoundary()
            speech.close(); plan.close(); AppSettings.shared.autoPlay = priorAutoPlay
        }
        let readSession = audio.claimPlaybackSession(owner: .readAloud)
        XCTAssertTrue(audio.loadSegments([AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 3), timestamps: [], duration: 3,
            text: "Old reading audio", isWavFormat: true)], autoPlay: false, session: readSession))
        XCTAssertTrue(audio.pause(session: readSession))
        vm.activateAfterModeSwitch(autoplay: false)
        XCTAssertTrue(audio.isExplicitlyPaused)
        if explicitStart { vm.startByUser() } else { vm.start() }
        try await wait { !plan.requests.isEmpty }
        if pauseDuringPlan {
            let session = try XCTUnwrap(audio.activePlaybackSession)
            XCTAssertTrue(audio.pause(session: session))
        }
        try await wait { audio.hasQueuedSegments && vm.currentBlockIndex == 0 }
        if explicitStart && !pauseDuringPlan {
            try await wait { audio.hasAudibleProgress }
        } else {
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertFalse(audio.isPlaying, "A later Pause or an automatic continuation must not be overridden")
            vm.togglePlayPause()
            try await wait { audio.hasAudibleProgress }
        }
        XCTAssertEqual(audio.currentSegment?.text, narration)
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, 1)
    }

    func testCompletedReaderPreparesNewVoiceWithoutReplayingOldAudio() async throws {
        let fixture = ReadAloudHTTPFixture { text, attempt in
            .response(ReadAloudHTTPFixture.body(text, duration: attempt == 1 ? 0.2 : 2))
        }
        let (vm, player) = makeVM(.text, fixture: fixture, texts: ["Read this again."])
        defer { vm.stop(); vm.deactivate(); player.stop(); fixture.close() }
        vm.dbgGenerate(0)
        try await wait { vm.isFinished }
        let oldAudio = try XCTUnwrap(player.currentSegment?.audioData)
        AppSettings.shared.setVoice("af_bella", for: "en")
        try await wait { fixture.requests.count == 2 && vm.status.isReady && VoiceSwitchStatusCenter.shared.progress == nil }
        XCTAssertFalse(player.isPlaying, "Selecting a voice after completion must not start playback")
        XCTAssertNotEqual(player.currentSegment?.audioData, oldAudio)
        vm.ensurePlaying()
        try await wait { player.hasAudibleProgress }
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(player.currentSegment?.text, "Read this again.")
    }

    func testRetainedExplanationCannotStealCurrentReadOnVoiceChange() async throws {
        let fixture = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 4))
        }
        let player = AudioPlayerService.shared
        let old = ExplainViewModel(document: ReadingDocument(title: "Previous", sourceKind: .text,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: "Previous explanation.")]),
            speechGenerator: fixture.service())
        let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 4), timestamps: [], duration: 4,
            text: "Previous explanation.", isWavFormat: true)
        old.debugSeedCachedNarration([segment], voiceID: AppSettings.shared.voice(for: "en"))
        old.activate()
        old.ensurePlaying()
        let current = ReadAloudViewModel(document: ReadingDocument(title: "Current", sourceKind: .text,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: "Current reading.")]),
            audioService: player, ttsService: fixture.service(), historyStore: HistoryStore(directory: root))
        defer { old.stop(); old.deactivate(); current.stop(); current.deactivate(); player.stop(); fixture.close() }
        current.dbgGenerate(0)
        await current.dbgWaitGeneration()
        AppSettings.shared.setVoice("af_bella", for: "en")
        try await wait { fixture.requests.filter { $0 == "Current reading." }.count == 2 && player.hasAudibleProgress }
        XCTAssertFalse(fixture.requests.contains("Previous explanation."))
        XCTAssertEqual(player.currentSegment?.text, "Current reading.")
    }

    func testReadAheadFirstAudioPlaysBeforeTailAcrossReaderSources() async throws {
        for source: ReadingSourceKind in [.text, .epub, .pdf, .weread, .kindle, .kobo, .googleBooks, .oreilly] {
            let fixture = ReadAloudHTTPFixture { input, _ in
                if input == "Second prefix. Tail." {
                    return .response(ReadAloudHTTPFixture.body("Second prefix. ", tail: "Tail.", duration: 1))
                }
                if input == "Tail." { return .response(ReadAloudHTTPFixture.body(input, duration: 0.2), delay: 1.7) }
                return .response(ReadAloudHTTPFixture.body(input, duration: 0.25))
            }
            let (vm, player) = makeVM(source, fixture: fixture, texts: ["First.", "Second prefix. Tail."])
            defer { vm.stop(); vm.deactivate(); player.stop(); fixture.close() }
            vm.dbgGenerate(0)
            try await wait { player.currentSegment?.text == "Second prefix. " && player.hasAudibleProgress }
            XCTAssertEqual(vm.dbgSegments(for: 1).count, 1, "Must start while Tail HTTP is pending: \(source)")
            XCTAssertTrue(player.moreSegmentsExpected)
            try await wait { vm.isFinished }
            XCTAssertEqual(fixture.requests.filter { $0 == "Second prefix. Tail." }.count, 1)
            XCTAssertEqual(fixture.requests.filter { $0 == "Tail." }.count, 1)
            vm.stop(); vm.deactivate(); fixture.close()
        }
    }

    func testPromotedReadAheadFailureRetriesOnlyMissingTail() async throws {
        let fixture = ReadAloudHTTPFixture { input, attempt in
            if input == "Second prefix. Tail." {
                return .response(ReadAloudHTTPFixture.body("Second prefix. ", tail: "Tail.", duration: 0.25))
            }
            if input == "Tail.", attempt == 1 { return .response(Data("{}".utf8), status: 500, delay: 0.8) }
            return .response(ReadAloudHTTPFixture.body(input, duration: 0.2))
        }
        let (vm, player) = makeVM(.text, fixture: fixture, texts: ["First.", "Second prefix. Tail.", "Last."])
        defer { vm.stop(); vm.deactivate(); player.stop(); fixture.close() }
        var completed: [String] = []
        player.onSegmentComplete = { if let text = player.currentSegment?.text { completed.append(text) } }
        vm.dbgGenerate(0)
        try await wait { if case .error = vm.status { return true }; return false }
        XCTAssertEqual(vm.currentParagraphIndex, 1)
        // An HTTP failure can arrive before AVPlayer finishes the buffered
        // prefix. Verify that it drains without a retry, regardless of device
        // handoff latency, before asking for the missing tail.
        try await wait { completed.count == 2 }
        XCTAssertEqual(completed, ["First.", "Second prefix. "])
        XCTAssertTrue(player.moreSegmentsExpected)
        vm.ensurePlaying()
        try await wait { vm.isFinished }
        XCTAssertEqual(completed, ["First.", "Second prefix. ", "Tail.", "Last."])
        XCTAssertEqual(fixture.requests.filter { $0 == "Second prefix. Tail." }.count, 1)
        XCTAssertEqual(fixture.requests.filter { $0 == "Tail." }.count, 2)
    }

    func testPausedReadAheadCannotAutoPromoteOrDispatchMoreWork() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            if input == "Second prefix. Tail." {
                return .response(ReadAloudHTTPFixture.body("Second prefix. ", tail: "Tail.", duration: 16))
            }
            return .response(ReadAloudHTTPFixture.body(input, duration: 1.5))
        }
        let (vm, player) = makeVM(.text, fixture: fixture, texts: ["First.", "Second prefix. Tail."])
        defer { vm.stop(); vm.deactivate(); player.stop(); fixture.close() }
        vm.dbgGenerate(0)
        try await wait { vm.dbgPrefetchedIndex == 1 }
        vm.pausePlayback()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.currentParagraphIndex, 0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(fixture.requests.contains("Tail."), "Full read-ahead buffer must stop new synthesis")
        vm.ensurePlaying()
        try await wait { player.currentSegment?.text == "Second prefix. " && player.hasAudibleProgress }
    }

    func testVoiceSwitchSendsOnlyVerifiedSuffixAndReusesCompletedVoice() async throws {
        try await assertVoiceSwitchSuffix(String(repeating: "已经听过的内容不应该重复生成。", count: 8))
    }

    func testVoiceSwitchSkipsEvenShortVerifiedPrefix() async throws {
        try await assertVoiceSwitchSuffix("基督教里浪子回头的绝妙寓言，")
    }

    private func assertVoiceSwitchSuffix(_ prefix: String) async throws {
        useRegularVoiceForTest(language: "zh")
        let suffix = "这里才是目前正在朗读的位置，后面还有新的内容。"
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 4), delay: 0.15)
        }
        defer { fixture.close() }
        let player = AudioPlayerService(testTemporaryRoot: root)
        let original = AppSettings.shared.voice(for: "zh")
        AppSettings.shared.setVoice("zf_046", for: "zh")
        let vm = ReadAloudViewModel(document: ReadingDocument(title: "Suffix fixture", sourceKind: .text,
            language: "zh", paragraphs: [ReadingParagraph(id: 0, text: prefix + suffix)]),
            audioService: player, ttsService: fixture.service(), historyStore: HistoryStore(directory: root))
        let old = [prefix, suffix].enumerated().map {
            AudioSegment(paragraphIndex: 0, segmentIndex: $0.offset,
                audioData: ReadAloudHTTPFixture.wav(duration: 4), timestamps: [], duration: 4,
                text: $0.element, isWavFormat: true)
        }
        defer { vm.stop(); vm.deactivate(); player.stop(); AppSettings.shared.setVoice(original, for: "zh") }
        vm.startWithCachedSegments(old, paragraphIndex: 0, segmentID: old[1].id, progress: 0.2, isReplayEligible: false)
        try await wait { player.hasAudibleProgress && player.currentSegment?.id == "0-1" }
        AppSettings.shared.setVoice("zf_001", for: "zh")
        try await wait { fixture.requests.count == 1 && vm.status.isReady && player.hasAudibleProgress }
        XCTAssertEqual(fixture.requests, [suffix])
        XCTAssertEqual(vm.dbgSegments(for: 0).first?.audioData.count, 0)
        XCTAssertEqual(vm.processedDisplayText, prefix + suffix)
        XCTAssertNil(vm.resumeNotice)
        AppSettings.shared.setVoice("zf_046", for: "zh")
        try await wait { fixture.requests.count == 2 && vm.status.isReady && player.hasAudibleProgress }
        vm.pausePlayback()
        AppSettings.shared.setVoice("zf_001", for: "zh")
        try await wait { VoiceSwitchStatusCenter.shared.progress == nil && vm.status.isReady }
        XCTAssertEqual(fixture.requests.count, 2, "Switch back should reuse verified audio without synthesis")
        XCTAssertTrue(player.isExplicitlyPaused)
        XCTAssertFalse(player.isPlaying)
    }

    func testSuffixRejectsChangedTextAndPreservesUnicodeBoundary() throws {
        let prefix = String(repeating: "Café résumé 中文。 ", count: 8)
        let suffix = "现在继续正确的内容。"
        let segments = [prefix, suffix].enumerated().map {
            AudioSegment(paragraphIndex: 0, segmentIndex: $0.offset, audioData: Data([1]),
                timestamps: [], duration: 5, text: $0.element)
        }
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: segments,
            currentSegmentID: "0-1", time: 2))
        let plan = try XCTUnwrap(ReadingResumeContract.speechSuffixPlan(source: prefix + suffix, segments: segments, cursor: cursor))
        XCTAssertEqual(plan.text, suffix)
        XCTAssertEqual(plan.nextSegmentIndex, 1)
        XCTAssertTrue(plan.prefix.allSatisfy { $0.audioData.isEmpty })
        XCTAssertNil(ReadingResumeContract.speechSuffixPlan(source: "changed" + prefix + suffix, segments: segments, cursor: cursor))
    }

    func testExplanationPublishesTimedMarksWithFirstShortUnitBeforeDelayedTail() async throws {
        let first = "The first important concept is attention, which lets us understand and remember what we read. "
        let second = "The second important concept is memory, which helps us apply these ideas throughout the day."
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 1), delay: input.contains("second") ? 1.8 : 0)
        }
        defer { fixture.close() }
        let marks = [QuickreadEvent(action: "highlight", text: "attention"), QuickreadEvent(action: "underline", text: "memory")]
        let section = QuickreadSection(id: "test", text: first + second, cinematic: QuickreadCinematic(events: marks))
        let vm = ExplainViewModel(document: ReadingDocument(title: "Explanation fixture", sourceKind: .text,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: "attention and memory")]), speechGenerator: fixture.service())
        let audio = AudioPlayerService.shared
        defer { vm.stop(); vm.deactivate(); audio.stop() }
        let task = Task { try await vm.debugPlayShortNarration(section) }
        defer { task.cancel() }
        try await wait { audio.hasAudibleProgress && audio.currentSegment?.text.contains("first") == true }
        let firstTimes = vm.debugPreparedMarkTimes
        XCTAssertEqual(firstTimes.count, 1)
        XCTAssertTrue(audio.moreSegmentsExpected)
        XCTAssertLessThan(vm.explanationText.count, first.count,
                          "Streaming a short unit must still display a single visual line")
        XCTAssertLessThanOrEqual((vm.explanationText as NSString).size(withAttributes:
            [.font: UIFont.systemFont(ofSize: 16, weight: .medium)]).width, 280)
        try await task.value
        XCTAssertEqual(vm.debugPreparedMarkTimes.count, 2)
        XCTAssertEqual(vm.debugPreparedMarkTimes.first, firstTimes.first, "Published marks must never move when later audio arrives")
        XCTAssertGreaterThanOrEqual(vm.debugPreparedMarkTimes.last ?? -1, 1)
        try await wait { if case .completed = vm.status { return true }; return false }
        XCTAssertEqual(vm.activeMarks.count, 2)
        let voice = AppSettings.shared.voice(for: vm.playbackLanguage)
        let expectedRequests = try XCTUnwrap(ExplanationSpeechPlan.units(text: section.text, marks: section.events))
            .flatMap { ClonedTTSStartup.requestUnits($0.text, language: vm.playbackLanguage, voice: voice) }
        XCTAssertEqual(fixture.requests, expectedRequests.map { SpeechTextSanitizer.sanitizedForTTS($0).trimmingCharacters(in: .whitespacesAndNewlines) },
                       "Each language/voice-specific unit must be synthesized exactly once")
    }

    func testExplainSubtitlesFollowPlayerClockAtSpeedPauseSeekAndReusedMediaID() async throws {
        let text = "First words. Second words. Last words."
        let starts = [0.0, 0.3, 2.0, 2.3, 6.0, 6.3]
        let words = ["First", "words", "Second", "words", "Last", "words"]
        let times = zip(words, starts).map { TTSTimestamp(word: $0, startTime: $1, endTime: $1 + 0.2) }
        let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 8), timestamps: times, duration: 8,
            text: text, isWavFormat: true)
        let vm = ExplainViewModel(document: ReadingDocument(title: "Subtitle fixture", sourceKind: .text,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: text)]))
        let audio = AudioPlayerService.shared
        defer { vm.stop(); vm.deactivate(); audio.stop() }
        AppSettings.shared.speed = 1.5
        vm.setSubtitleLayout(width: 280, font: UIFont.systemFont(ofSize: 16, weight: .medium))
        vm.debugSeedCachedNarration([segment], voiceID: AppSettings.shared.voice(for: "en"))
        vm.activate(); vm.ensurePlaying()
        try await wait { audio.hasAudibleProgress && vm.explanationText == "First words." }
        XCTAssertEqual(audio.playbackRate, 1.5)
        try await wait { vm.explanationText == "Second words." }
        XCTAssertGreaterThanOrEqual(audio.playbackPosition, 2)
        XCTAssertLessThan(audio.playbackPosition, 2.4)
        vm.togglePlayPause()
        let pausedCaption = vm.explanationText
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(vm.explanationText, pausedCaption)
        XCTAssertTrue(vm.debugSeekSubtitle(to: 6.2))
        try await wait { vm.explanationText == "Last words." }
        XCTAssertTrue(vm.debugSeekSubtitle(to: 0.4))
        try await wait { vm.explanationText == "First words." }
        XCTAssertFalse(audio.isPlaying)
        vm.stop(); vm.deactivate()
        let next = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 3), timestamps: [], duration: 3,
            text: "Different page.", isWavFormat: true)
        vm.debugSeedCachedNarration([next], voiceID: AppSettings.shared.voice(for: "en"))
        vm.activate(); vm.ensurePlaying()
        try await wait { audio.hasAudibleProgress && vm.explanationText == "Different page." }
    }

    func testQueuedOldPageTickCannotFlashNewPagesFinalSubtitle() async throws {
        let vm = ExplainViewModel(document: ReadingDocument(title: "Queued clock fixture", sourceKind: .text,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: "Original page.")]))
        let audio = AudioPlayerService.shared
        defer { vm.stop(); vm.deactivate(); audio.stop() }
        let first = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 8), timestamps: [], duration: 8,
            text: "Original page.", isWavFormat: true)
        let next = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 4), timestamps: [
                TTSTimestamp(word: "New", startTime: 0, endTime: 0.4),
                TTSTimestamp(word: "opening", startTime: 0.4, endTime: 0.8),
                TTSTimestamp(word: "Final", startTime: 3, endTime: 3.4),
                TTSTimestamp(word: "line", startTime: 3.4, endTime: 3.8)],
            duration: 4, text: "New opening. Final line.", isWavFormat: true)
        let voice = AppSettings.shared.voice(for: "en")
        vm.debugSeedCachedNarration([first], voiceID: voice)
        vm.activate(); vm.ensurePlaying()
        try await wait { audio.hasAudibleProgress }
        var captions: [String] = []
        let subscription = vm.$explanationText.sink { captions.append($0) }
        defer { subscription.cancel() }
        audio.currentTime = 7.8 // Already emitted; delivery is queued on RunLoop.main.
        vm.debugSeedCachedNarration([next], voiceID: voice, enqueueImmediately: true)
        try await wait { audio.hasAudibleProgress && audio.currentSegment?.text == next.text }
        XCTAssertEqual(vm.explanationText, "New opening.")
        XCTAssertFalse(captions.contains("Final line."), "An old item clock must never reach the new page, even for one frame")
    }

    func testChineseExplanationRequestsRawTimingForSingleLineCaptions() async throws {
        let oldLanguage = AppSettings.shared.explainLanguage
        AppSettings.shared.explainLanguage = "zh"
        useRegularVoiceForTest(language: "zh")
        defer { AppSettings.shared.explainLanguage = oldLanguage }
        let text = String(repeating: "第一部分的讲解文字需要真实时间", count: 5) + "。" +
            String(repeating: "后续部分也需要按真实音频时间切换", count: 5) + "。"
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 1))
        }
        let vm = ExplainViewModel(document: ReadingDocument(title: "Raw timing fixture", sourceKind: .text,
            language: "zh", paragraphs: [ReadingParagraph(id: 0, text: text)]), speechGenerator: fixture.service())
        defer { vm.stop(); vm.deactivate(); AudioPlayerService.shared.stop(); fixture.close() }
        try await vm.debugPlayShortNarration(QuickreadSection(id: "raw-timing", text: text,
            cinematic: QuickreadCinematic(events: [])))
        XCTAssertGreaterThanOrEqual(fixture.capturedRequests.count, 2)
        XCTAssertTrue(fixture.capturedRequests.allSatisfy { $0.body["return_timestamps"] as? Bool == true })
    }

    func testExplanationKeepsAmbiguousOrParaphrasedMarksOnComposePath() {
        let text = "The first paragraph explains our reading habits and how attention affects understanding. The second paragraph explains how to remember the important concepts after reading."
        XCTAssertNil(ExplanationSpeechPlan.units(text: text, marks: [QuickreadEvent(action: "highlight", text: "different original wording")]))
        XCTAssertNil(ExplanationSpeechPlan.units(text: text, marks: [QuickreadEvent(action: "highlight", text: "paragraph")]))
        let units = ExplanationSpeechPlan.units(text: text, marks: [QuickreadEvent(action: "highlight", text: "attention")])
        XCTAssertEqual(units?.count, 2)
        XCTAssertEqual(ExplanationSpeechPlan.normalized(units?.map(\.text).joined() ?? ""), ExplanationSpeechPlan.normalized(text))
    }

    func testForegroundReadAheadStopsAtTimeBudgetAndWhilePaused() async throws {
        let fragments = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliet", "Kilo", "Lima"]
            .map { "Section \($0). " }
        let text = fragments.joined()
        let fixture = ReadAloudHTTPFixture { input, _ in
            // Preserve the actual wire prefix and tail, including its trimmed ending.
            var boundary = input.firstIndex(of: ".").map { input.index(after: $0) } ?? input.endIndex
            while boundary < input.endIndex, input[boundary].isWhitespace {
                boundary = input.index(after: boundary)
            }
            return .response(ReadAloudHTTPFixture.body(String(input[..<boundary]),
                tail: String(input[boundary...]), duration: 5))
        }
        defer { fixture.close() }
        let (vm, player) = makeVM(.text, fixture: fixture, texts: [text])
        defer { vm.stop(); vm.deactivate(); player.stop() }
        vm.dbgGenerate(0)
        player.setPlaybackRate(1)
        try await wait { vm.dbgSegments(for: 0).count == 3 && player.hasAudibleProgress }
        vm.pausePlayback()
        let pausedCount = fixture.requests.count
        player.setPlaybackRate(2)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fixture.requests.count, pausedCount, "Pause must stop new requests even after a speed change")
        XCTAssertLessThan(pausedCount, fragments.count)
        vm.ensurePlaying()
        try await wait { fixture.requests.count >= 5 }
        XCTAssertLessThan(fixture.requests.count, fragments.count, "Higher speed expands the time window without synthesizing the whole paragraph")
    }

    func testBufferDemandAccountsForRateAndPause() {
        let buffer = SpeechStreamBuffer(paragraphIndex: 0, voice: "vl_test", language: "en", requestID: "id")
        let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: Data([1]),
                                   timestamps: [], duration: 12, text: "Buffered text")
        buffer.append(segment)
        XCTAssertFalse(buffer.canRequest(currentSegmentID: nil, position: 0, rate: 1, paused: false))
        XCTAssertTrue(buffer.canRequest(currentSegmentID: segment.id, position: 5, rate: 1, paused: false))
        XCTAssertTrue(buffer.canRequest(currentSegmentID: nil, position: 0, rate: 2, paused: false))
        XCTAssertFalse(buffer.canRequest(currentSegmentID: segment.id, position: 11, rate: 2, paused: true))
    }
}

extension SpeechPipelineTests {
    func testManualTurnDuringNaturalAudioGapPreservesResumeButExplicitPauseWins() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            if input == "Alpha. Bravo." {
                return .response(ReadAloudHTTPFixture.body("Alpha. ", tail: "Bravo.", duration: 0.2))
            }
            return .response(ReadAloudHTTPFixture.body(input, duration: 0.4), delay: 2)
        }
        let (vm, player) = makeVM(.weread, fixture: fixture, texts: ["Alpha. Bravo."])
        defer { vm.stop(); vm.deactivate(); player.stop(); fixture.close() }
        vm.dbgGenerate(0)
        try await wait { player.isWaitingForNextSegment }
        XCTAssertTrue(vm.isActive)
        XCTAssertFalse(vm.isPlaybackPausedByUser)
        XCTAssertTrue(player.moreSegmentsExpected)
        XCTAssertTrue(player.currentSegment != nil)
        XCTAssertTrue(vm.shouldResumeAfterManualLivePageTurn)
        vm.pausePlayback()
        XCTAssertFalse(vm.shouldResumeAfterManualLivePageTurn)
        vm.deactivate()
        XCTAssertFalse(vm.shouldResumeAfterManualLivePageTurn)
    }
}

extension SpeechPipelineTests {
    func testKindlePreparedAudioTailUsesDecoderClockDespiteDelayedUITick() async throws {
        let text = "The prepared explanation is already speaking on the current page. Its last annotation must finish with the decoder rather than a delayed interface timestamp."
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 4))
        }
        let document = ReadingDocument(title: "Decoder deadline", sourceKind: .kindle,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: text)])
        let vm = ExplainViewModel(document: document, speechGenerator: fixture.service())
        let audio = AudioPlayerService.shared
        defer { vm.stop(); vm.deactivate(); audio.stop(); fixture.close() }
        try await vm.debugPlayShortNarration(QuickreadSection(id: "decoder-deadline", text: text,
            cinematic: QuickreadCinematic(events: [])))
        try await wait { audio.playbackPosition > 0.4 && vm.preparedLivePageAudioTail != nil }
        let before = try XCTUnwrap(vm.preparedLivePageAudioTail)
        let uiTime = audio.currentTime
        audio.currentTime = 0 // Simulate a queued UI sample, without rewinding the decoder.
        let delayed = try XCTUnwrap(vm.preparedLivePageAudioTail)
        audio.currentTime = uiTime
        XCTAssertEqual(delayed.lastSegmentID, before.lastSegmentID)
        XCTAssertEqual(delayed.remainingAudioSeconds, before.remainingAudioSeconds, accuracy: 0.03,
                       "A stale UI timestamp must not add silence after the final ink")
    }

    func testKindleExplainManualNavigationPreservesExplicitPause() async throws {
        let text = "A paused explanation must stay paused when selecting a different page. An explicit resume can continue the same prepared narration without creating another request."
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 4))
        }
        let document = ReadingDocument(title: "Manual pause fixture", sourceKind: .kindle,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: text)])
        let vm = ExplainViewModel(document: document, speechGenerator: fixture.service())
        let book = KindleBook(id: UUID().uuidString, asin: nil, title: "Pause fixture", author: "", coverURL: nil,
            readerURL: "https://read.amazon.com/", progressLabel: "", storefrontID: "us", lastOpenedAt: nil,
            lastSyncedAt: Date(), lastReadPageKey: nil, lastReadURL: nil)
        let model = KindleBookViewModel(book: book, websiteDataStore: .nonPersistent())
        model.webView.navigationDelegate = nil
        model.mode = .explain
        model.explainVM = vm
        defer { model.destroy(); vm.stop(); vm.deactivate(); AudioPlayerService.shared.stop(); fixture.close() }
        XCTAssertNotNil(ExplanationSpeechPlan.units(text: text, marks: []),
                        "The short-narration fixture requires two playable speech units")
        try await vm.debugPlayShortNarration(QuickreadSection(id: "pause-navigation", text: text,
            cinematic: QuickreadCinematic(events: [])))
        try await wait { vm.isPlaying && AudioPlayerService.shared.hasAudibleProgress }
        XCTAssertTrue(model.shouldResumeAfterUserPageTurn)
        vm.togglePlayPause()
        XCTAssertFalse(model.shouldResumeAfterUserPageTurn,
                       "An owned but paused AVPlayer item does not authorize autoplay after Previous/Next")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(model.shouldResumeAfterUserPageTurn)
        vm.ensurePlaying()
        XCTAssertTrue(AudioPlayerService.shared.hasPlaybackRequest)
        XCTAssertTrue(model.shouldResumeAfterUserPageTurn,
                      "Resume intent must survive AVPlayer's transient waiting state")
        try await wait { AudioPlayerService.shared.isPlaying && !AudioPlayerService.shared.isBuffering }
        XCTAssertTrue(model.shouldResumeAfterUserPageTurn)
    }

    func testKindleFinalMarkDoesNotAddSilenceAfterKnownAudioTail() async throws {
        try await exerciseKindleFinalInk(stopDuringDrain: false, playbackRate: 3)
    }

    func testKindleBridgeWaitsForActualFinalMultilineMarkAfterAudioEnds() async throws {
        try await exerciseKindleFinalInk(stopDuringDrain: false)
    }

    func testStoppingKindleDuringFinalInkRevokesAutomaticTurn() async throws {
        try await exerciseKindleFinalInk(stopDuringDrain: true)
    }

    func testPlayDuringKindleInkDrainResumesExactlyOnePageWithoutReplayingAudio() async throws {
        try await exerciseKindleFinalInk(stopDuringDrain: false, resumeDuringDrain: true)
    }

    private func exerciseKindleFinalInk(stopDuringDrain: Bool, resumeDuringDrain: Bool = false,
                                       playbackRate: Double = 1) async throws {
        let previousSpeed = AppSettings.shared.speed
        AppSettings.shared.speed = playbackRate
        defer { AppSettings.shared.speed = previousSpeed }
        let text = "The first important concept is attention, which lets us understand and remember what we read. The second important concept is memory, which helps us apply these ideas throughout the day."
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 0.4))
        }
        defer { fixture.close() }
        let section = QuickreadSection(id: "final-ink", text: text, cinematic: QuickreadCinematic(events: [QuickreadEvent(action: "underline", text: "The second important concept is memory, which helps us apply these ideas throughout the day.")]))
        var words: [OCRWord] = []
        var x: CGFloat = 20; var y: CGFloat = 30
        for (i, token) in text.split(separator: " ").enumerated() {
            let width = CGFloat(token.count) * 7
            if x + width > 620 { x = 20; y += 32 }
            words.append(OCRWord(id: i, text: String(token), bboxNorm: CGRect(x: x / 650, y: 1 - (y + 22) / 320, width: width / 650, height: 22.0 / 320)))
            x += width + 7
        }
        let document = ReadingDocument(title: "Ink fixture", sourceKind: .kindle, language: "en", paragraphs: [ReadingParagraph(id: 0, text: text, words: words)], imagePixelSize: CGSize(width: 650, height: 320))
        let vm = ExplainViewModel(document: document, speechGenerator: fixture.service())
        let book = KindleBook(id: UUID().uuidString, asin: nil, title: "Local ink fixture", author: "", coverURL: nil,
            readerURL: "https://read.amazon.com/", progressLabel: "", storefrontID: "us", lastOpenedAt: nil,
            lastSyncedAt: Date(), lastReadPageKey: nil, lastReadURL: nil)
        let model = KindleBookViewModel(book: book, websiteDataStore: .nonPersistent())
        model.webView.navigationDelegate = nil
        model.mode = .explain
        model.readVM = ReadAloudViewModel(document: document)
        model.explainVM = vm
        model.bindLivePlaybackForTesting(document: document)
        defer { model.destroy(); vm.stop(); vm.deactivate(); AudioPlayerService.shared.stop() }
        var turnAt: Double?
        var turnCount = 0
        model.explainAdvanceReadyForTesting = { turnAt = ProcessInfo.processInfo.systemUptime; turnCount += 1 }
        try await vm.debugPlayShortNarration(section)
        var audioEndedAt: Double?
        AudioPlayerService.shared.onSegmentComplete = { audioEndedAt = ProcessInfo.processInfo.systemUptime }
        try await wait { !vm.activeMarks.isEmpty }
        let mark = try XCTUnwrap(vm.activeMarks.last)
        let timing = try XCTUnwrap(model.markAnimationClock.animations[mark.id])
        XCTAssertGreaterThan(timing.duration, 0)
        XCTAssertLessThanOrEqual(timing.duration, 2.2)
        let requestsAtCompletion = fixture.requests.count
        if resumeDuringDrain {
            vm.pauseOwnedPlayback()
            vm.togglePlayPause()
        }
        if stopDuringDrain {
            model.stopAll()
            try await Task.sleep(nanoseconds: 2_400_000_000)
            XCTAssertNil(turnAt, "A stopped page cannot turn after the pen deadline")
            XCTAssertFalse(model.isContinuingExplainPage)
        } else {
            try await wait { turnAt != nil }
            let visibleAdvanceAt = try XCTUnwrap(turnAt)
            let ended = try XCTUnwrap(audioEndedAt)
            XCTAssertGreaterThanOrEqual(visibleAdvanceAt - timing.startedAt, timing.duration,
                "The whole multiline path must finish before the page can advance")
            XCTAssertLessThan(visibleAdvanceAt - ended, 0.2,
                "The final pen stroke must fit the known audio tail, including fast playback")
            XCTAssertEqual(turnCount, 1)
            XCTAssertEqual(fixture.requests.count, requestsAtCompletion)
            print("PARITY_FIXED inkStartToTurnMs=\((visibleAdvanceAt - timing.startedAt) * 1000) audioEndToTurnMs=\((visibleAdvanceAt - ended) * 1000)")
        }
    }
}

private actor SpeechPipelineSessionProvider: MobileSessionProviding {
    func sessionToken() -> String? { "cms_fixture" }
    func refreshSession() -> String? { "cms_fixture" }
    func invalidateSession() {}
    func rejectSession(_ token: String?) {}
}
