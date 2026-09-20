import XCTest
@testable import CastReader

@MainActor
final class SpeechPipelineTests: XCTestCase {
    private var root: URL!
    private var oldPro = false
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        useRegularVoiceForTest(language: "en")
    }
    override func tearDown() async throws {
        ProManager.shared.debugForcePro = oldPro
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
    func testKindleBridgeWaitsForActualFinalMultilineMarkAfterAudioEnds() async throws {
        try await exerciseKindleFinalInk(stopDuringDrain: false)
    }

    func testStoppingKindleDuringFinalInkRevokesAutomaticTurn() async throws {
        try await exerciseKindleFinalInk(stopDuringDrain: true)
    }

    func testPlayDuringKindleInkDrainResumesExactlyOnePageWithoutReplayingAudio() async throws {
        try await exerciseKindleFinalInk(stopDuringDrain: false, resumeDuringDrain: true)
    }

    private func exerciseKindleFinalInk(stopDuringDrain: Bool, resumeDuringDrain: Bool = false) async throws {
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
        try await wait { vm.status == .completed }
        let audioEndedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(turnAt, "Audio completion alone must not advance the visible page")
        let mark = try XCTUnwrap(vm.activeMarks.last)
        let timing = try XCTUnwrap(model.markAnimationClock.animations[mark.id])
        XCTAssertEqual(timing.duration, 2.2, accuracy: 0.01)
        XCTAssertGreaterThan(model.markAnimationClock.remaining(), 0.5)
        let requestsAtCompletion = fixture.requests.count
        if resumeDuringDrain { vm.togglePlayPause() }
        if stopDuringDrain {
            model.stopAll()
            try await Task.sleep(nanoseconds: 2_400_000_000)
            XCTAssertNil(turnAt, "A stopped page cannot turn after the pen deadline")
            XCTAssertFalse(model.isContinuingExplainPage)
        } else {
            try await wait { turnAt != nil }
            let visibleAdvanceAt = try XCTUnwrap(turnAt)
            XCTAssertGreaterThanOrEqual(visibleAdvanceAt - timing.startedAt, 2.3)
            XCTAssertLessThan(visibleAdvanceAt - audioEndedAt, 2.5)
            XCTAssertEqual(turnCount, 1)
            XCTAssertEqual(fixture.requests.count, requestsAtCompletion)
            print("PARITY_FIXED inkStartToTurnMs=\((visibleAdvanceAt - timing.startedAt) * 1000) audioEndToTurnMs=\((visibleAdvanceAt - audioEndedAt) * 1000)")
        }
    }
}

private actor SpeechPipelineSessionProvider: MobileSessionProviding {
    func sessionToken() -> String? { "cms_fixture" }
    func refreshSession() -> String? { "cms_fixture" }
    func invalidateSession() {}
    func rejectSession(_ token: String?) {}
}
