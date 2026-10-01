import XCTest
import AVFoundation
import WebKit
import Combine
@testable import CastReader

@MainActor
final class PaginationContinuityTests: XCTestCase {
    private func segment(_ text: String, _ cues: [(String, Double, Double)], index: Int = 0) -> AudioSegment {
        AudioSegment(paragraphIndex: 0, segmentIndex: index, audioData: Data(),
            timestamps: cues.map { TTSTimestamp(word: $0.0, startTime: $0.1, endTime: $0.2) },
            duration: 10, text: text)
    }

    func testBoundaryUsesActualCueNotUniformCharacterRate() {
        let part = segment("Slow rapidly.", [("Slow", 0, 4.2), ("rapidly", 4.4, 5)])
        guard case let .cue(index, time) = WeReadCrossPageSpeechContract.audioBoundary(
            source: "Slow rapidly.", boundaryUTF16Offset: 5, segments: [part]) else {
            return XCTFail("Expected the real cue boundary")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(time, 4.2)
        XCTAssertEqual(WeReadCrossPageSpeechContract.continuationTime(source: part.text,
            boundaryUTF16Offset: 5, segments: [part]), 4.4)
    }

    func testUntimedOpeningUsesOnlyACompleteSingleSourceSentence() throws {
        let source = "“Who said I don’t?”"
        let short = segment(source, [])
        XCTAssertNil(WeReadCrossPageSpeechContract.sourceRange(source: source,
            segments: [short], segmentID: short.id, time: 0))
        let range = try XCTUnwrap(WeReadCrossPageSpeechContract.openingSourceRange(source: source, segment: short))
        XCTAssertEqual((source as NSString).substring(with: range), source)
        XCTAssertEqual(WeReadCrossPageSpeechContract.openingSourceRange(source: source,
            segment: segment(source, [], index: 900_010_000)), range,
            "A queued handoff rebases item IDs without changing the complete source")
        for unsafe in [segment("Different source.", []), segment("“Who said", []),
                       segment(source, [("wrong", 0, 1)])] {
            XCTAssertNil(WeReadCrossPageSpeechContract.openingSourceRange(source: source, segment: unsafe))
        }
        let multiple = segment("First sentence. Second sentence.", [])
        XCTAssertNil(WeReadCrossPageSpeechContract.openingSourceRange(source: multiple.text, segment: multiple))
    }

    func testPresentationWindowNeverInventsSilenceAcrossMediaItems() {
        let first = segment("First", [("First", 0, 1)])
        let second = segment("second", [("second", 0.2, 1)], index: 1)
        XCTAssertNil(WeReadCrossPageSpeechContract.continuationTime(source: "First second",
            boundaryUTF16Offset: 6, segments: [first, second]))
        let coarse = segment("First second", [("First second", 0, 2)])
        XCTAssertNil(WeReadCrossPageSpeechContract.continuationTime(source: coarse.text,
            boundaryUTF16Offset: 6, segments: [coarse]))
    }

    func testOneChineseAudioPartHighlightsOneSourceSentenceAtATime() throws {
        let source = "我十分乐意效劳。”\n“抱歉，实在抱歉，”他说。"
        let part = segment(source, [("我十分乐意效劳", 0, 1), ("抱歉实在抱歉他说", 1.2, 3)])
        let first = WeReadCrossPageSpeechContract.sentenceSourceRange(source: source,
            segments: [part], segmentID: part.id, time: 0.6)
        let second = WeReadCrossPageSpeechContract.sentenceSourceRange(source: source,
            segments: [part], segmentID: part.id, time: 1.7)
        XCTAssertEqual(first.map { (source as NSString).substring(with: $0) }, "我十分乐意效劳。”")
        XCTAssertEqual(second.map { (source as NSString).substring(with: $0) }, "“抱歉，实在抱歉，”他说。")
        XCTAssertEqual(NSIntersectionRange(try XCTUnwrap(first), try XCTUnwrap(second)).length, 0)
        let coarse = segment(source, [("我十分乐意效劳抱歉实在抱歉他说", 0, 3)])
        XCTAssertNil(WeReadCrossPageSpeechContract.sentenceSourceRange(source: source,
            segments: [coarse], segmentID: coarse.id, time: 1), "A coarse cue cannot invent the sentence change time")
    }

    func testChineseHighlightAdvancesInsideOneUninterruptedAudioPart() async throws {
        let oldPro = ProManager.shared.debugForcePro, oldSpeed = AppSettings.shared.speed
        ProManager.shared.debugForcePro = true
        AppSettings.shared.speed = 1
        defer { ProManager.shared.debugForcePro = oldPro; AppSettings.shared.speed = oldSpeed }
        useRegularVoiceForTest(language: "zh")
        let source = "我十分乐意效劳。”\n“抱歉，实在抱歉，”他说。"
        for coarse in [false, true] {
            let fixture = ReadAloudHTTPFixture { text, _ in
                var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 4)) as! [String: Any]
                if !coarse {
                    body["timestamps"] = [["word":"我十分乐意效劳","start_time":0.0,"end_time":1.3],
                        ["word":"抱歉实在抱歉他说","start_time":1.3,"end_time":3.8]]
                }
                return .response(try! JSONSerialization.data(withJSONObject: body))
            }
            defer { fixture.close() }
            let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let read = ReadAloudViewModel(document: .init(id: UUID().uuidString, title: "Sentence highlight",
                sourceKind: .weread, language: "zh", paragraphs: []), audioService: audio, ttsService: fixture.service())
            defer { read.stop(); read.deactivate(); audio.stop() }
            read.loadWebParagraphs([ReadingParagraph(id: 0, text: source)], language: "zh")
            // Live-page prefetch preserves one complete source unit. A cold
            // Chinese start may split natural sentences before the HTTP call,
            // which does not reproduce the reported multi-sentence audio part.
            let parts = try await fixture.service().generatePagePrefetchSegments(
                paragraphIndex: 0, text: source, voice: AppSettings.shared.voice(for: "zh"), language: "zh")
            XCTAssertEqual(parts.count, 1)
            read.startWithPrefetchedSegments(parts, paragraphIndex: 0)
            for _ in 0..<300 where audio.playbackPosition < 0.3 { try await Task.sleep(nanoseconds: 10_000_000) }
            let player = try XCTUnwrap(audio.activePlayerForTesting)
            let first = try XCTUnwrap(read.webHighlight)
            XCTAssertEqual(first.charStart, 0)
            XCTAssertEqual(first.charEnd, coarse ? 0 : "我十分乐意效劳。”".utf16.count)
            XCTAssertTrue(first.segmentTexts?.isEmpty == true, "JS must not expand the sentence to the transport part")
            for _ in 0..<300 where audio.playbackPosition < 1.6 { try await Task.sleep(nanoseconds: 10_000_000) }
            let second = try XCTUnwrap(read.webHighlight)
            XCTAssertEqual(second.charStart, coarse ? 0 : "我十分乐意效劳。”\n".utf16.count)
            XCTAssertEqual(second.charEnd, coarse ? 0 : source.utf16.count)
            XCTAssertTrue(audio.activePlayerForTesting === player)
            XCTAssertTrue(audio.isPlaying)
            XCTAssertEqual(fixture.requests.count, 1, "A highlight transition cannot split the speech request")
        }
    }

    func testColdContinueAppliesSelectedRateBeforeFirstAudibleFrame() async throws {
        let oldPro = ProManager.shared.debugForcePro, oldSpeed = AppSettings.shared.speed
        ProManager.shared.debugForcePro = true
        AppSettings.shared.speed = 1.5
        defer { ProManager.shared.debugForcePro = oldPro; AppSettings.shared.speed = oldSpeed }
        useRegularVoiceForTest(language: "en")
        for source in [ReadingSourceKind.weread, .kindle, .googleBooks, .kobo] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = HistoryStore(directory: root)
            let document = ReadingDocument(id: UUID().uuidString, title: "Continue speed", sourceKind: source,
                language: "en", paragraphs: [ReadingParagraph(id: 0, text: "Already read."),
                    ReadingParagraph(id: 1, text: "Continue from this saved sentence.")])
            store.record(document)
            let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: document.paragraphs)
                .checkpoint(sourceKind: source, paragraphIndex: 1, audio: nil))
            XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: document.id, boundary: store.progressBoundaryToken))
            let fixture = ReadAloudHTTPFixture { text, _ in .response(ReadAloudHTTPFixture.body(text, duration: 4)) }
            defer { fixture.close() }
            let audio = AudioPlayerService(testTemporaryRoot: root.appendingPathComponent("audio"))
            let read = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service(), historyStore: store)
            defer { read.stop(); read.deactivate(); audio.stop(); try? FileManager.default.removeItem(at: root) }
            if source != .kindle { read.loadWebParagraphs(document.paragraphs, language: "en") }
            // Deliver initial settings notifications while this reader is
            // inactive, as happens while a real online page finishes loading.
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(audio.playbackRate, 1)
            XCTAssertTrue(read.hasPendingReadingResume)
            read.activate()
            read.ensurePlaying()
            XCTAssertEqual(audio.playbackRate, 1.5, "\(source): apply rate before generation/readiness")
            for _ in 0..<400 where !audio.hasAudibleProgress { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(audio.hasAudibleProgress)
            XCTAssertEqual(try XCTUnwrap(audio.activePlayerForTesting).rate, 1.5, "\(source): verify AVPlayer rate")
            XCTAssertEqual(read.currentParagraphIndex, 1)
        }
    }

    func testConfirmedPageUsesMeasuredSilenceWithoutPausingMediaClock() async throws {
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { audio.stop() }
        let session = audio.claimPlaybackSession(owner: .readAloud)
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(), timestamps: [],
            duration: 2, text: "Two pages in one decoder", isWavFormat: true)
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false, session: session))
        var request: UUID?
        XCTAssertTrue(audio.armPagePresentationBoundary(segmentID: part.id, time: 0.2,
            session: session, continuationTime: 0.7) { request = $0 })
        XCTAssertTrue(audio.play(session: session))
        for _ in 0..<250 where request == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let id = try XCTUnwrap(request)
        let player = audio.activePlayerForTesting
        let start = audio.playbackPosition
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThan(audio.playbackPosition, start + 0.08, "The page's rendering must not stop the existing audio clock")
        XCTAssertTrue(audio.finishPagePresentation(id))
        XCTAssertTrue(audio.activePlayerForTesting === player)
        XCTAssertFalse(player?.currentItem?.forwardPlaybackEndTime.isValid ?? true)
        for _ in 0..<150 where audio.playbackPosition <= 0.8 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThan(audio.playbackPosition, 0.8, "Confirmation must remove the future media limit")
    }

    func testLatePageStopsAtNextAudibleCueRatherThanAtPreviousWordEnd() async throws {
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { audio.stop() }
        let session = audio.claimPlaybackSession(owner: .readAloud)
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(), timestamps: [],
            duration: 2, text: "Deadline fixture", isWavFormat: true)
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false, session: session))
        var request: UUID?
        XCTAssertTrue(audio.armPagePresentationBoundary(segmentID: part.id, time: 0.2,
            session: session, continuationTime: 0.5) { request = $0 })
        XCTAssertTrue(audio.play(session: session))
        for _ in 0..<250 where request == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        usleep(450_000)
        XCTAssertEqual(audio.playbackPosition, 0.5, accuracy: 0.002)
        audio.timeSampleForTesting?(CMTime(seconds: 0.1, preferredTimescale: 600))
        XCTAssertEqual(audio.currentTime, 0.5, accuracy: 0.002,
                       "A late pre-boundary time callback cannot move the source cursor back to the previous page")
        try await Task.sleep(nanoseconds: 80_000_000)
        audio.pause(session: session)
        XCTAssertTrue(audio.finishPagePresentation(try XCTUnwrap(request)))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.playbackPosition, 0.5, accuracy: 0.002, "User pause still wins over late confirmation")
    }

    func testChineseRequestHintsEveryKnownNativePageWithinOneSentence() {
        let source = "前半句中间句后半句。"
        let boundary = WeReadPageSpeechBoundary(paragraphIndex: 0, visibleUTF16Offset: 3,
            speechUTF16Length: source.utf16.count, followingPageUTF16Offsets: [6])
        XCTAssertEqual(WeReadCrossPageSpeechContract.speechInput(source, boundary: boundary,
            paragraphIndex: 0, language: "zh"), "前半句 中间句 后半句。")
        let coarse = segment(source, [("前半句", 0, 0.3), ("中间句后半句", 0.3, 2)])
        XCTAssertEqual(WeReadCrossPageSpeechContract.boundaryRejection(source: source, boundary: boundary,
            segments: [coarse]), "cross_page_coarse_cue", "A good first edge cannot conceal a later coarse page edge")
    }

    func testMalformedCueAfterValidBoundaryRejectsWholePart() {
        let part = segment("First second third.", [("First", 0, 1), ("second", 1, 2), ("WRONG", 2, 3)])
        guard case .rejected("invalid_source_cue") = WeReadCrossPageSpeechContract.audioBoundary(
            source: part.text, boundaryUTF16Offset: 6, segments: [part]) else {
            return XCTFail("Finding the boundary cannot bypass validation of later cues")
        }
    }

    func testAutomaticPageCommitRetainsDelayedPartlyProducer() async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let fixture = ReadAloudHTTPFixture { text, _ in
            if text == "Slow rapidly onward." {
                var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body("Slow rapidly ", tail: "onward.", duration: 1.2)) as! [String: Any]
                body["timestamps"] = [["word": "Slow", "start_time": 0.0, "end_time": 0.2], ["word": "rapidly", "start_time": 0.2, "end_time": 1.1]]
                return .response(try! JSONSerialization.data(withJSONObject: body))
            }
            return .response(ReadAloudHTTPFixture.body(text, duration: 0.8), delay: 0.7)
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let document = ReadingDocument(id: UUID().uuidString, title: "Partly turn", sourceKind: .weread,
            language: "en", paragraphs: [], sourceURL: "https://weread.qq.com/web/reader/fixture")
        let read = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        defer { read.stop(); audio.stop() }
        read.loadWebParagraphs([ReadingParagraph(id: 0, text: "Slow rapidly onward.", type: .paragraph)], language: "en",
            weReadBoundary: WeReadPageSpeechBoundary(paragraphIndex: 0, visibleUTF16Offset: 5, speechUTF16Length: 20,
                sourceLayoutFingerprint: "native-partly", sourceParagraphIndex: 1, sourceSpeechEnd: 20))
        var committed = false
        read.onPageBoundaryApproaching = {
            guard let current = audio.currentSegment, let hold = audio.pagePresentationHoldID else { return }
            XCTAssertTrue(audio.moreSegmentsExpected, "Visual cue must not wait for the final partly request")
            committed = read.commitLiveWebPageDuringActiveCarry([ReadingParagraph(id: 0, text: "After.", type: .paragraph)],
                language: "en", carrySegmentID: current.id)
            XCTAssertTrue(audio.finishPagePresentation(hold))
        }
        read.start()
        for _ in 0..<250 where !committed { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(committed)
        XCTAssertTrue(audio.moreSegmentsExpected)
        var heardTail = false
        for _ in 0..<250 {
            if audio.currentSegment?.text == "onward." { heardTail = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(heardTail, "The delayed response must enter the same queue after a visual turn")
        XCTAssertEqual(fixture.requests.filter { $0 == "Slow rapidly onward." }.count, 1)
        XCTAssertEqual(fixture.requests.filter { $0 == "onward." }.count, 1)
    }

    func testCarryPauseTapAndResumeKeepTheSameSourceAudio() async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let fixture = ReadAloudHTTPFixture { text, _ in
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 2)) as! [String: Any]
            if text == "Slow rapidly." {
                body["timestamps"] = [["word":"Slow","start_time":0.0,"end_time":0.3],
                                      ["word":"rapidly","start_time":0.3,"end_time":1.9]]
            }
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let read = ReadAloudViewModel(document: ReadingDocument(id: UUID().uuidString, title: "Carry control",
            sourceKind: .weread, language: "en", paragraphs: []), audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop() }
        read.loadWebParagraphs([ReadingParagraph(id: 0, text: "Slow rapidly.")], language: "en",
            weReadBoundary: WeReadPageSpeechBoundary(paragraphIndex: 0, visibleUTF16Offset: 5, speechUTF16Length: 13,
                sourceLayoutFingerprint: "native", sourceParagraphIndex: 0, sourceSpeechEnd: 13))
        var pausedAt: Double?
        read.onPageBoundaryApproaching = {
            guard let part = audio.currentSegment, let hold = audio.pagePresentationHoldID else { return }
            XCTAssertTrue(read.commitLiveWebPageDuringActiveCarry([ReadingParagraph(id: 0, text: "After.")],
                language: "en", carrySegmentID: part.id))
            read.togglePlayPause()
            pausedAt = audio.playbackPosition
            XCTAssertTrue(audio.isExplicitlyPaused)
            XCTAssertTrue(audio.finishPagePresentation(hold))
        }
        read.start()
        for _ in 0..<250 where pausedAt == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let position = try XCTUnwrap(pausedAt)
        let player = audio.activePlayerForTesting
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.playbackPosition, position, accuracy: 0.01)
        read.togglePlayPause()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(audio.activePlayerForTesting === player)
        XCTAssertGreaterThan(audio.playbackPosition, position + 0.1)
        XCTAssertEqual(fixture.requests.filter { $0 == "Slow rapidly." }.count, 1)
    }

    func testCarriedSentenceAdoptsMatchingPreparedSuccessorWithoutRegenerating() async throws {
        try await exercisePreparedCarrySuccessor(matchingVoice: true)
    }

    func testCarriedSentenceRejectsPreparedSuccessorFromDifferentVoice() async throws {
        try await exercisePreparedCarrySuccessor(matchingVoice: false)
    }

    private func exercisePreparedCarrySuccessor(matchingVoice: Bool) async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let voice = AppSettings.shared.voice(for: "en")
        let fixture = ReadAloudHTTPFixture { text, _ in
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 2)) as! [String: Any]
            if text == "Slow rapidly." {
                body["timestamps"] = [["word":"Slow","start_time":0.0,"end_time":0.3],
                                      ["word":"rapidly","start_time":0.3,"end_time":1.9]]
            }
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        defer { fixture.close() }
        let prepared = try await fixture.service().generatePagePrefetchSegments(
            paragraphIndex: 0, text: "After.", voice: voice, language: "en")
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let read = ReadAloudViewModel(document: ReadingDocument(id: UUID().uuidString, title: "Prepared carry",
            sourceKind: .weread, language: "en", paragraphs: []), audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop() }
        read.loadWebParagraphs([ReadingParagraph(id: 0, text: "Slow rapidly.")], language: "en",
            weReadBoundary: WeReadPageSpeechBoundary(paragraphIndex: 0, visibleUTF16Offset: 5, speechUTF16Length: 13,
                sourceLayoutFingerprint: "native", sourceParagraphIndex: 0, sourceSpeechEnd: 13))
        var committed = false
        read.onPageBoundaryApproaching = {
            guard let part = audio.currentSegment, let hold = audio.pagePresentationHoldID else { return }
            committed = read.commitLiveWebPageDuringActiveCarry([ReadingParagraph(id: 0, text: "After.")],
                language: "en", carrySegmentID: part.id,
                prepared: .init(paragraphIndex: 0, sourceText: "After.",
                    voiceID: matchingVoice ? voice : "another-voice", language: "en", segments: prepared))
            XCTAssertEqual(audio.currentSegment?.text, "Slow rapidly.", "Adoption must not cut off the carried sentence")
            XCTAssertTrue(audio.finishPagePresentation(hold))
        }
        read.start()
        for _ in 0..<400 where audio.currentSegment?.text != "After." || !audio.hasAudibleProgress {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(committed)
        XCTAssertEqual(audio.currentSegment?.text, "After.")
        XCTAssertTrue(audio.hasAudibleProgress)
        XCTAssertEqual(fixture.requests.filter { $0 == "After." }.count, matchingVoice ? 1 : 2,
                       "A matching prepared successor must survive the visual page commit")
    }

    func testCoarseCrossPageCueIsRejectedBeforeQueueCommit() {
        let part = segment("这是一句跨页的完整中文。", [("这是一句跨页的完整中文。", 0, 8)])
        guard case .rejected("cross_page_coarse_cue") = WeReadCrossPageSpeechContract.audioBoundary(
            source: part.text, boundaryUTF16Offset: 6, segments: [part]) else {
            return XCTFail("A sentence cue cannot be divided by character ratio")
        }
    }

    func testLaterParagraphReusingTransportIDDoesNotInheritPreviousCarryCoordinates() async throws {
        let oldPro = ProManager.shared.debugForcePro, oldSpeed = AppSettings.shared.speed
        ProManager.shared.debugForcePro = true; AppSettings.shared.speed = 1
        defer { ProManager.shared.debugForcePro = oldPro; AppSettings.shared.speed = oldSpeed }
        useRegularVoiceForTest(language: "en")
        let fixture = ReadAloudHTTPFixture { text, _ in
            guard text == "Slow rapidly." || text == "Later onward." else {
                return .response(ReadAloudHTTPFixture.body(text, duration: 0.3))
            }
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 1.5)) as! [String: Any]
            body["timestamps"] = text == "Slow rapidly."
                ? [["word":"Slow","start_time":0.0,"end_time":0.3], ["word":"rapidly","start_time":0.3,"end_time":1.4]]
                : [["word":"Later","start_time":0.0,"end_time":0.3], ["word":"onward","start_time":0.3,"end_time":1.4]]
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let read = ReadAloudViewModel(document: .init(id: UUID().uuidString, title: "Successive source units",
            sourceKind: .kobo, language: "en", paragraphs: []), audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop() }
        read.loadWebParagraphs([.init(id: 0, text: "Intro."), .init(id: 1, text: "Slow rapidly.")], language: "en",
            weReadBoundary: .init(paragraphIndex: 1, visibleUTF16Offset: 5, speechUTF16Length: 13,
                sourceParagraphIndex: 0, sourceSpeechEnd: 13))
        var firstID: String?, secondRange: NSRange?
        read.onPageBoundaryApproaching = {
            guard let part = audio.currentSegment, let hold = audio.pagePresentationHoldID else { return }
            if firstID == nil {
                firstID = part.id
                XCTAssertTrue(read.commitLiveWebPageDuringActiveCarry(
                    [.init(id: 0, text: "Middle."), .init(id: 1, text: "Later onward.")],
                    language: "en", carrySegmentID: part.id,
                    weReadBoundary: .init(paragraphIndex: 1, visibleUTF16Offset: 6, speechUTF16Length: 13,
                        sourceParagraphIndex: 1, sourceSpeechEnd: 205)))
            } else {
                XCTAssertEqual(part.id, firstID, "The transport id is deliberately reused on another page")
                secondRange = read.liveWebSourceRange(segmentID: part.id, time: 0.8)
            }
            XCTAssertTrue(audio.finishPagePresentation(hold))
        }
        read.start()
        for _ in 0..<400 where secondRange == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(secondRange, NSRange(location: 198, length: 6),
                       "A new source unit must use its own absolute origin, even when paragraph and segment numbers repeat")
    }

    func testLatinWordSplitAcrossPagesUsesRealWordEndAndFollowingCue() {
        for word in ["illustrations", "illustra\u{00ad}tions", "mother-in-law", "café"] {
            let source = "The \(word) continue."
            let spoken = word.replacingOccurrences(of: "\u{00ad}", with: "")
            let part = segment(source, [("The", 0, 0.2), (spoken, 0.3, 1.4), ("continue.", 1.6, 2)])
            guard case let .cue(index, time) = WeReadCrossPageSpeechContract.audioBoundary(
                source: source, boundaryUTF16Offset: 6, segments: [part]) else {
                return XCTFail("A single Latin word may occupy both visible pages: \(word)")
            }
            XCTAssertEqual(index, 0)
            XCTAssertEqual(time, 1.4, "Use the measured word end, never a subword estimate")
            XCTAssertEqual(WeReadCrossPageSpeechContract.continuationTime(source: source,
                boundaryUTF16Offset: 6, segments: [part]), 1.6)
        }
        let source = "Two separate words."
        let coarse = segment(source, [(source, 0, 2)])
        guard case .rejected("cross_page_coarse_cue") = WeReadCrossPageSpeechContract.audioBoundary(
            source: source, boundaryUTF16Offset: 5, segments: [coarse]) else {
            return XCTFail("A phrase cue must still be rejected")
        }
        // A producer cannot disguise a multiword phrase by removing spaces.
        let joined = segment(source, [("Twoseparatewords", 0, 2)])
        guard case .rejected("cross_page_coarse_cue") = WeReadCrossPageSpeechContract.audioBoundary(
            source: source, boundaryUTF16Offset: 5, segments: [joined]) else {
            return XCTFail("Source geometry must also identify exactly one word")
        }
        let threePages = segment("The illustrations continue.", [("The", 0, 0.2),
            ("illustrations", 0.3, 1.4), ("continue", 1.6, 2)])
        XCTAssertEqual(WeReadCrossPageSpeechContract.boundaryRejection(source: threePages.text,
            boundary: .init(paragraphIndex: 0, visibleUTF16Offset: 6,
                            speechUTF16Length: threePages.text.utf16.count, followingPageUTF16Offsets: [8]),
            segments: [threePages]), "cross_page_coarse_cue", "One word cannot authorize skipping an intermediate page")
    }

    func testLatinWordAcrossPageTurnsAfterWholeWordWithoutStoppingItsAudio() async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let source = "The illustrations continue."
        let fixture = ReadAloudHTTPFixture { text, _ in
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 3)) as! [String: Any]
            if text == source {
                body["timestamps"] = [["word":"The","start_time":0.0,"end_time":0.2],
                    ["word":"illustrations","start_time":0.3,"end_time":1.4],
                    ["word":"continue.","start_time":1.6,"end_time":2.9]]
            }
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let read = ReadAloudViewModel(document: .init(id: UUID().uuidString, title: "Word continuation",
            sourceKind: .kobo, language: "en", paragraphs: []), audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop() }
        read.loadWebParagraphs([ReadingParagraph(id: 0, text: source)], language: "en",
            weReadBoundary: .init(paragraphIndex: 0, visibleUTF16Offset: 10,
                speechUTF16Length: source.utf16.count, sourceLayoutFingerprint: "native-word",
                sourceParagraphIndex: 0, sourceSpeechEnd: source.utf16.count))
        var turned = false
        var carriedPlayer: AVPlayer?
        read.onPageBoundaryApproaching = {
            guard let part = audio.currentSegment, let hold = audio.pagePresentationHoldID else { return }
            XCTAssertEqual(read.currentWeReadBoundaryCue?.boundaryTime, 1.4)
            XCTAssertGreaterThanOrEqual(audio.playbackPosition, 1.39)
            carriedPlayer = audio.activePlayerForTesting
            turned = read.commitLiveWebPageDuringActiveCarry([ReadingParagraph(id: 0, text: "After.")],
                language: "en", carrySegmentID: part.id)
            XCTAssertTrue(audio.finishPagePresentation(hold))
        }
        read.start()
        for _ in 0..<300 where !turned { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(turned)
        XCTAssertTrue(audio.activePlayerForTesting === carriedPlayer)
        XCTAssertEqual(audio.currentSegment?.text, source)
        for _ in 0..<400 where audio.currentSegment?.text != "After." || !audio.hasAudibleProgress {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(audio.currentSegment?.text, "After.")
        XCTAssertTrue(audio.hasAudibleProgress)
        XCTAssertEqual(fixture.requests.filter { $0 == source }.count, 1)
    }

    func testExplicitRetryReclaimsSessionAfterRejectedSourceTiming() async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        var attempt = 0
        let fixture = ReadAloudHTTPFixture { text, _ in
            attempt += 1
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 3)) as! [String: Any]
            body["timestamps"] = attempt == 1
                ? [["word":"First second.","start_time":0.0,"end_time":2.9]]
                : [["word":"First","start_time":0.0,"end_time":1.4],
                   ["word":"second.","start_time":1.6,"end_time":2.9]]
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let read = ReadAloudViewModel(document: .init(id: UUID().uuidString, title: "Retry source timing",
            sourceKind: .kobo, language: "en", paragraphs: []), audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop() }
        read.loadWebParagraphs([ReadingParagraph(id: 0, text: "First second.")], language: "en",
            weReadBoundary: .init(paragraphIndex: 0, visibleUTF16Offset: 6, speechUTF16Length: 13))
        read.start()
        for _ in 0..<300 {
            if case .error = read.status { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .error = read.status else { return XCTFail("The first coarse response must be rejected") }
        XCTAssertFalse(read.isActive)
        XCTAssertFalse(audio.hasAudibleProgress)
        read.togglePlayPause()
        for _ in 0..<300 where !audio.hasAudibleProgress { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(read.isActive)
        XCTAssertTrue(audio.hasAudibleProgress)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(audio.currentSegment?.text, "First second.")
    }

    func testDuplicateTextRemainsOrderedAndMissingPartCannotSkipSource() {
        let first = segment("Same. ", [("Same", 0, 1)])
        let second = segment("Same. End.", [("Same", 0, 2), ("End", 2.3, 3)], index: 1)
        guard case let .cue(sequence, time) = WeReadCrossPageSpeechContract.audioBoundary(
            source: "Same. Same. End.", boundaryUTF16Offset: 12, segments: [first, second]) else {
            return XCTFail("Both identical source occurrences must be retained")
        }
        XCTAssertEqual(sequence, 1); XCTAssertEqual(time, 2)
        guard case .rejected("speech_source_mismatch") = WeReadCrossPageSpeechContract.audioBoundary(
            source: "Before. Same. End.", boundaryUTF16Offset: 12, segments: [second]) else {
            return XCTFail("A later matching substring is not source coverage")
        }
    }

    func testBoundaryBeforeFuturePartWaitsWithoutInventingTiming() {
        guard case .pending = WeReadCrossPageSpeechContract.audioBoundary(
            source: "First. Second. Third.", boundaryUTF16Offset: 14,
            segments: [segment("First. ", [("First", 0, 1)])]) else { return XCTFail("Pending generation") }
    }

    func testPartlyCoverageRejectsFalseRemainderBeforePublication() throws {
        XCTAssertThrowsError(try TTSPartlySourceCoverage.validate(input: "First. Second.", processed: "First. Second.", remaining: "Second."))
        XCTAssertThrowsError(try TTSPartlySourceCoverage.validate(input: "First. Second.", processed: "First.", remaining: "Third."))
        let expanded = try TTSPartlySourceCoverage.validate(input: "12 apples.", processed: "Twelve apples.", remaining: nil)
        XCTAssertEqual(expanded.processedText, "Twelve apples.")
        XCTAssertThrowsError(try TTSPartlySourceCoverage.validate(input: "First.", processed: nil, remaining: "First."))
        let final = try TTSPartlySourceCoverage.validate(input: "Final part.", processed: nil, remaining: nil)
        XCTAssertEqual(final.processedText, "Final part.")
        let first = try TTSPartlySourceCoverage.validate(input: "First. Second.", processed: nil, remaining: "Second.")
        XCTAssertEqual(first.processedText, "First. ")
        XCTAssertEqual(first.remainingText, "Second.")
    }

    func testLivePagePunctuationIsIdempotentAndPartlySuffixIsExact() async throws {
        let raw = "They were a-b-c--friends -- always—together. Afterward they left."
        let normalized = SpeechTextSanitizer.livePageRequest(raw)
        XCTAssertEqual(normalized, "They were a b c friends always together. Afterward they left.")
        XCTAssertEqual(SpeechTextSanitizer.livePageRequest(normalized), normalized)
        XCTAssertEqual(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) },
                       normalized.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let fixture = ReadAloudHTTPFixture { text, _ in
            if text == normalized {
                return .response(ReadAloudHTTPFixture.body("They were a b c friends always together. ", tail: "Afterward they left."))
            }
            return .response(ReadAloudHTTPFixture.body(text))
        }
        defer { fixture.close() }
        var received: [AudioSegment] = []
        try await fixture.service().generateBufferedSpeech(paragraphIndex: 0, text: raw, voice: "af_heart",
            speed: 1, language: "en", includeVoiceCode: true, speaker: nil, cloneRequestID: nil,
            continuation: TTSContinuation(requestUnits: [raw], nextSegmentIndex: 0, requiresSourceTiming: true),
            beforeRequest: { _ in .interactive }, onSegmentReady: { received.append($0) })
        XCTAssertEqual(fixture.requests, [normalized, "Afterward they left."])
        XCTAssertEqual(received.map(\.text).joined(), normalized)
    }

    func testShortOpeningWaitsForOneDecodedBodyPartWithoutRepeatingPrefix() async throws {
        try await verifyShortOpening(pauseWhilePreparing: false)
    }

    func testPausedReflowCanReachLaterPartWithoutResumingOrGeneratingPastCursor() async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let source = "Opening words. Restored sentence. Later suffix."
        let fixture = ReadAloudHTTPFixture { text, _ in
            if text == source { return .response(ReadAloudHTTPFixture.body("Opening words. ", tail: "Restored sentence. Later suffix.", duration: 4)) }
            if text == "Restored sentence. Later suffix." { return .response(ReadAloudHTTPFixture.body("Restored sentence. ", tail: "Later suffix.", duration: 4)) }
            return .response(ReadAloudHTTPFixture.body(text, duration: 4))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let read = ReadAloudViewModel(document: .init(id: UUID().uuidString, title: "Paused reflow",
            sourceKind: .googleBooks, language: "en", paragraphs: []), audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop() }
        let page = [ReadingParagraph(id: 0, text: source)]
        read.loadWebParagraphs(page, language: "en")
        read.activate(); read.pausePlayback()
        read.replaceLiveWebPage(page, language: "en", autoplay: false,
            resumeAnchor: .init(segmentText: "Restored sentence. ", sourceParagraphText: source,
                segmentProgress: 0.5, wasPlaying: false))
        for _ in 0..<300 where audio.currentSegment?.text != "Restored sentence. " || abs(audio.playbackPosition - 2) > 0.2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(audio.currentSegment?.text, "Restored sentence. ")
        XCTAssertFalse(audio.isPlaying)
        XCTAssertTrue(read.isPlaybackPausedByUser)
        XCTAssertEqual(audio.playbackPosition, 2, accuracy: 0.2)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(fixture.requests.contains("Later suffix."), "The restore exemption ends at the paused cursor")
        XCTAssertNotNil(read.webHighlight)
    }

    func testPauseWinsOverLateShortOpeningPreparation() async throws {
        try await verifyShortOpening(pauseWhilePreparing: true)
    }

    private func verifyShortOpening(pauseWhilePreparing: Bool) async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let fixture = ReadAloudHTTPFixture { text, _ in
            if text == "I" { return .response(ReadAloudHTTPFixture.body(text, duration: 0.3)) }
            if text == "Body tail." {
                return .response(ReadAloudHTTPFixture.body("Body ", tail: "tail.", duration: 2), delay: 0.5)
            }
            return .response(ReadAloudHTTPFixture.body(text, duration: 2))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let document = ReadingDocument(id: UUID().uuidString, title: "Short opening", sourceKind: .kobo,
            language: "en", paragraphs: [], sourceURL: "https://www.kobo.com/reader/fixture")
        let read = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        defer { read.stop(); audio.stop() }
        read.loadWebParagraphs([ReadingParagraph(id: 0, text: "I", type: .paragraph),
            ReadingParagraph(id: 1, text: "Body tail.", type: .paragraph)], language: "en")
        read.start()
        for _ in 0..<200 where fixture.requests.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fixture.requests, ["I", "Body tail."])
        XCTAssertNil(audio.currentSegment, "The title cannot outrun the cold first body response")
        if pauseWhilePreparing { read.pausePlayback() }
        for _ in 0..<200 where !audio.hasQueuedSegments { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(audio.hasQueuedSegments, "A paused title remains queued for explicit resume")
        if pauseWhilePreparing {
            try await Task.sleep(nanoseconds: 650_000_000)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertTrue(read.isPlaybackPausedByUser)
            XCTAssertEqual(read.currentParagraphIndex, 0)
            XCTAssertFalse(fixture.requests.contains("tail."))
            read.togglePlayPause()
            for _ in 0..<300 where read.currentParagraphIndex != 1 { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(read.currentParagraphIndex, 1)
            XCTAssertEqual(fixture.requests.filter { $0 == "I" }.count, 1)
            XCTAssertEqual(fixture.requests.filter { $0 == "Body tail." }.count, 1)
        } else {
            for _ in 0..<300 where read.currentParagraphIndex != 1 { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(read.currentParagraphIndex, 1)
            XCTAssertEqual(fixture.requests.filter { $0 == "Body tail." }.count, 1)
            XCTAssertEqual(fixture.requests.filter { $0 == "tail." }.count, 1)
        }
    }

    func testPromotedChineseSentenceTurnsAtVisiblePageEnd() async throws {
        try await verifyPromotedChineseBoundary(coarse: false)
    }

    func testCoarsePrefetchedCueNeverSpeaksInvisibleNextPage() async throws {
        try await verifyPromotedChineseBoundary(coarse: true)
    }

    private func verifyPromotedChineseBoundary(coarse: Bool) async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "zh")
        let fixture = ReadAloudHTTPFixture { text, _ in
            if text == "开始。" { return .response(ReadAloudHTTPFixture.body(text, duration: 1.2)) }
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 2)) as! [String: Any]
            if !coarse {
                body["timestamps"] = [["word":"前半句","start_time":0.0,"end_time":0.35],
                                      ["word":"后半句","start_time":0.35,"end_time":1.9]]
            }
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let document = ReadingDocument(id: UUID().uuidString, title: "中文跨页预取", sourceKind: .weread,
            language: "zh", paragraphs: [], sourceURL: "https://weread.qq.com/web/reader/fixture")
        let read = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        defer { read.stop(); audio.stop() }
        read.loadWebParagraphs([ReadingParagraph(id: 0, text: "开始。", type: .paragraph),
            ReadingParagraph(id: 1, text: "前半句后半句。", type: .paragraph)], language: "zh",
            weReadBoundary: WeReadPageSpeechBoundary(paragraphIndex: 1, visibleUTF16Offset: 3, speechUTF16Length: 7,
                sourceLayoutFingerprint: "page", sourceParagraphIndex: 3, sourceSpeechEnd: 7))
        var turnTime: Double?, heardInvisible = false
        read.onPageBoundaryApproaching = { turnTime = audio.playbackPosition }
        read.start()
        for _ in 0..<350 {
            if audio.currentSegment?.paragraphIndex == 1, audio.playbackPosition > 0.4 { heardInvisible = true }
            if case .error = read.status { break }
            if turnTime != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(heardInvisible)
        XCTAssertEqual(fixture.requests.filter { $0.contains("前半句") }.count, 1)
        if coarse {
            guard case .error = read.status else { return XCTFail("An unmappable source cue must stop before it speaks") }
            XCTAssertNil(turnTime)
        } else {
            XCTAssertEqual(try XCTUnwrap(turnTime), 0.35, accuracy: 0.04)
            XCTAssertNotNil(audio.pagePresentationHoldID)
        }
    }

    func testPresentationAtItemEndDeliversCompletionOnceAfterAcknowledgement() async throws {
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = audio.claimPlaybackSession(owner: .readAloud)
        defer { audio.stop() }
        let first = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 0.25), timestamps: [], duration: 0.25, text: "End", isWavFormat: true)
        let second = AudioSegment(paragraphIndex: 0, segmentIndex: 1,
            audioData: wav(), timestamps: [], duration: 2, text: "Next", isWavFormat: true)
        var hold: UUID?, completions = 0
        audio.onSegmentComplete = { completions += 1 }
        XCTAssertTrue(audio.loadSegments([first, second], autoPlay: false, session: session))
        XCTAssertTrue(audio.armPagePresentationBoundary(segmentID: first.id, time: 0.25, session: session) { hold = $0 })
        XCTAssertTrue(audio.play(session: session))
        for _ in 0..<200 where hold == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let id = try XCTUnwrap(hold)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(audio.currentSegment?.id, first.id)
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(audio.finishPagePresentation(id))
        for _ in 0..<200 where audio.currentSegment?.id != second.id { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(audio.currentSegment?.id, second.id)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(audio.finishPagePresentation(id))
        XCTAssertEqual(completions, 1)
    }

    func testChineseDisplayPolicyDoesNotDiscardNavigationTiming() {
        let cues = [TTSTimestamp(word: "前半句", startTime: 0, endTime: 2),
                    TTSTimestamp(word: "后半句", startTime: 2.2, endTime: 4)]
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: Data(),
            timestamps: TTSHighlightPolicy.displayTimestamps(cues, language: "zh"), duration: 4,
            text: "前半句后半句", timingTimestamps: cues)
        XCTAssertTrue(part.timestamps.isEmpty)
        guard case let .cue(_, time) = WeReadCrossPageSpeechContract.audioBoundary(
            source: part.text, boundaryUTF16Offset: 3, segments: [part]) else { return XCTFail("Raw cues must survive display policy") }
        XCTAssertEqual(time, 2)
    }

    func testCrossPageChineseRequestsActualTimingInsideOneSentence() throws {
        let source = "前半句后半句。"
        let boundary = WeReadPageSpeechBoundary(paragraphIndex: 0, visibleUTF16Offset: 3, speechUTF16Length: source.utf16.count)
        let hinted = WeReadCrossPageSpeechContract.speechInput(source, boundary: boundary, paragraphIndex: 0, language: "zh-CN")
        XCTAssertEqual(hinted, "前半句 后半句。")
        XCTAssertEqual(hinted.filter { !$0.isWhitespace }, source)
        let request = TTSRequest(input: hinted, language: "zh", requiresSourceTiming: true)
        XCTAssertTrue(request.returnTimestamps)
        XCTAssertFalse(TTSHighlightPolicy.usesWordTimestamps(language: "zh"))
    }

    func testLivePageTimingUsesLoadedWebSourceWhenDocumentParagraphsAreEmpty() async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let fixture = ReadAloudHTTPFixture { text, _ in
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 2)) as! [String: Any]
            body["timestamps"] = [["word": "Slow", "start_time": 0.0, "end_time": 0.5], ["word": "rapidly", "start_time": 0.5, "end_time": 1.8]]
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let document = ReadingDocument(id: UUID().uuidString, title: "Live source fixture", sourceKind: .weread,
            language: "en", paragraphs: [], sourceURL: "https://weread.qq.com/web/reader/source-fixture")
        let read = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        defer { read.stop(); audio.stop() }
        read.loadWebParagraphs([ReadingParagraph(id: 0, text: "Slow rapidly.", type: .paragraph)], language: "en",
            weReadBoundary: WeReadPageSpeechBoundary(paragraphIndex: 0, visibleUTF16Offset: 5, speechUTF16Length: 13,
                sourceLayoutFingerprint: "native-fixture", sourceParagraphIndex: 4, sourceSpeechEnd: 13))
        read.start()
        for _ in 0..<250 where read.currentWeReadBoundaryCue == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let cue = try XCTUnwrap(read.currentWeReadBoundaryCue)
        XCTAssertEqual(cue.boundaryTime, 0.5)
        XCTAssertEqual(cue.consumedCursor?.sourceLayoutFingerprint, "native-fixture")
    }

    private func presentationFixture() async throws -> (AudioPlayerService, AudioPlaybackSessionToken, UUID) {
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = audio.claimPlaybackSession(owner: .readAloud)
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(), timestamps: [],
            duration: 2, text: "Same media across two pages", isWavFormat: true)
        var hold: UUID?
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false, session: session))
        XCTAssertTrue(audio.armPagePresentationBoundary(segmentID: part.id, time: 0.2, session: session) { hold = $0 })
        XCTAssertTrue(audio.play(session: session))
        for _ in 0..<250 where hold == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        return (audio, session, try XCTUnwrap(hold))
    }

    func testPresentationHoldFreezesMediaAndResumesSamePlayer() async throws {
        let (audio, _, hold) = try await presentationFixture()
        defer { audio.stop() }
        let player = audio.activePlayerForTesting
        let position = audio.playbackPosition
        XCTAssertTrue(audio.hasPlaybackRequest)
        XCTAssertFalse(audio.isExplicitlyPaused)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(audio.playbackPosition, position, accuracy: 0.01)
        XCTAssertFalse(audio.finishPagePresentation(UUID()), "Wrong page operation cannot release media")
        XCTAssertTrue(audio.finishPagePresentation(hold))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(audio.activePlayerForTesting === player)
        XCTAssertGreaterThan(audio.playbackPosition, position + 0.1)
        XCTAssertFalse(audio.finishPagePresentation(hold), "A completion is consumed once")
    }

    func testMediaStopsAtVisibleEdgeWhileMainExecutorIsBusy() async throws {
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { audio.stop() }
        let session = audio.claimPlaybackSession(owner: .readAloud)
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(), timestamps: [],
            duration: 2, text: "Engine-owned page edge", isWavFormat: true)
        var hold: UUID?
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false, session: session))
        XCTAssertTrue(audio.armPagePresentationBoundary(segmentID: part.id, time: 0.3, session: session) { hold = $0 })
        XCTAssertTrue(audio.play(session: session))
        for _ in 0..<250 where audio.playbackPosition < 0.05 { try await Task.sleep(nanoseconds: 10_000_000) }
        // Deliberate fault injection: WebKit/layout can block this executor,
        // but the media engine must not speak the hidden continuation.
        usleep(400_000)
        XCTAssertLessThanOrEqual(audio.playbackPosition, 0.301)
        for _ in 0..<100 where hold == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(audio.finishPagePresentation(try XCTUnwrap(hold)))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertGreaterThan(audio.playbackPosition, 0.4)
    }

    func testRealCompletionAfterVisualHoldIgnoresEstimatedDurationPadding() async throws {
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { audio.stop() }
        let session = audio.claimPlaybackSession(owner: .readAloud)
        // The data lasts 2 seconds, but server metadata includes padding.
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(), timestamps: [],
            duration: 2.2, text: "Full immutable sentence", isWavFormat: true)
        var completed = 0
        audio.onPlaybackComplete = { completed += 1 }
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false, session: session))
        XCTAssertTrue(audio.armPagePresentationBoundary(segmentID: part.id, time: 0.3, session: session) { hold in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertTrue(audio.finishPagePresentation(hold))
            }
        })
        XCTAssertTrue(audio.play(session: session))
        for _ in 0..<350 where completed == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(completed, 1, "Real media end must complete once, even when metadata overstates duration")
    }

    func testWholePageUsesContainerEndInsteadOfServerDurationEstimate() async throws {
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { audio.stop() }
        let session = audio.claimPlaybackSession(owner: .readAloud)
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(), timestamps: [],
            duration: 1.4, text: "Underestimated full page", isWavFormat: true)
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false, session: session))
        var heldAt: Double?
        XCTAssertTrue(audio.armQueuedTailPresentationBoundary { _ in heldAt = audio.playbackPosition })
        XCTAssertTrue(audio.play(session: session))
        for _ in 0..<350 where heldAt == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(try XCTUnwrap(heldAt), 2, accuracy: 0.025,
                       "Whole-page turn is owned by the actual item end, even before duration metadata is ready")
        XCTAssertTrue(audio.finishPagePresentation(try XCTUnwrap(audio.pagePresentationHoldID)))
    }

    func testPauseAndNewOwnerWinOverLatePresentation() async throws {
        let (audio, session, hold) = try await presentationFixture()
        defer { audio.stop() }
        XCTAssertTrue(audio.pause(session: session))
        let position = audio.playbackPosition
        XCTAssertTrue(audio.finishPagePresentation(hold))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(audio.playbackPosition, position, accuracy: 0.01)
        XCTAssertFalse(audio.isPlaying)
        _ = audio.claimPlaybackSession(owner: .explain)
        XCTAssertFalse(audio.finishPagePresentation(hold))
        XCTAssertFalse(audio.play(session: session))
    }

    func testNativeWeReadPaintAndExactNeighborUseProductionAdapter() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: WeReadWebScripts.nativePageBridge,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: web.frame)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(web); window.isHidden = false
        defer { web.stopLoading(); window.isHidden = true }
        web.loadHTMLString(#"""
        <html><meta name="viewport" content="width=device-width,initial-scale=1"><body>
        <div id="host" style="width:350px;height:600px"><div class="wr_canvasContainer"><canvas width="350" height="600" style="width:350px;height:600px"></canvas></div></div>
        <button class="renderTarget_pager_button_right" onclick="reader.leftRenderPageIdx++;turns++">下一页</button>
        <script>
        window.turns=0;
        window.pages=['前半句','后半句。','下一句。'].map((text,index)=>({pageIdx:index,chapterUid:7,contents:Array.from(text).map((text,j)=>({type:1,text,_offset:index*3+j,canvasX:20+j*22,rect:{y:20,w:20,h:20}}))}));
        window.reader={_isVue:true,$options:{name:'HorizontalReader',methods:{getCurrentChapterPages(){return pages.filter(p=>p.chapterUid===this.currentChapterUid)}}},$el:document.querySelector('#host'),bookInfo:{bookId:'fixture-book'},pageWidth:350,pageHeight:600,fontSizeLevel:2,fontFamily:'serif',displayColumnCount:1,isSinglePage:true,leftRenderPageIdx:0,extraRenderPagesInfo:pages,isLastPage:false,paintPageFinish(){},setPreloadChapterRenderContents(){}};
        (function(){}).apply(reader,[]);
        window.paint=()=>reader.paintPageFinish(document.querySelector('canvas').getContext('2d'));
        window.snapshot=()=>window.__castReaderWeReadNative.snapshot(document.querySelector('#host'));
        </script></body></html>
        """#, baseURL: URL(string: "https://weread.qq.com/web/reader/native-fixture"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("typeof snapshot === 'function' && !!document.documentElement.getAttribute('data-castreader-wr-native')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let initiallyReady = try await web.evaluateJavaScript("snapshot().ready") as? Bool
        XCTAssertEqual(initiallyReady, false, "Layout data alone is not painted")
        _ = try await web.callAsyncJavaScript("paint(); await new Promise(requestAnimationFrame);", arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("snapshot().ready")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let initial = try await web.evaluateJavaScript("snapshot()") as? [String: Any]
        XCTAssertEqual(initial?["ready"] as? Bool, true)
        let items = try XCTUnwrap(initial?["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["text"] as? String, "前半句")
        XCTAssertEqual(items.first?["sourceParagraphText"] as? String, "前半句后半句。")
        let accepted = try await web.evaluateJavaScript("window.__castReaderWeReadNative.turn('next')") as? Bool
        XCTAssertEqual(accepted, true)
        _ = try await web.callAsyncJavaScript("await new Promise(requestAnimationFrame);", arguments: [:], in: nil, contentWorld: .page)
        let beforePaint = try await web.evaluateJavaScript("snapshot().ready") as? Bool
        XCTAssertEqual(beforePaint, false)
        let duplicate = try await web.evaluateJavaScript("window.__castReaderWeReadNative.turn('next')") as? Bool
        XCTAssertEqual(duplicate, false)
        _ = try await web.callAsyncJavaScript("paint(); await new Promise(requestAnimationFrame);", arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("snapshot().ready")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let after = try await web.evaluateJavaScript("snapshot()") as? [String: Any]
        XCTAssertEqual(after?["ready"] as? Bool, true)
        XCTAssertNotEqual(initial?["pageIdentity"] as? String, after?["pageIdentity"] as? String)
        let turns = try await web.evaluateJavaScript("turns") as? Int
        XCTAssertEqual(turns, 1)
        // Renderer mutates an existing page object: cached identity must change.
        _ = try await web.callAsyncJavaScript("pages[1].contents[0].text='新';reader.setPreloadChapterRenderContents();await new Promise(requestAnimationFrame);", arguments: [:], in: nil, contentWorld: .page)
        let mutated = try await web.evaluateJavaScript("snapshot().ready") as? Bool
        XCTAssertEqual(mutated, false, "Changed glyph revision needs another paint")
        _ = try await web.callAsyncJavaScript(#"""
            pages[1].contents[pages[1].contents.length-1].text='。\u200b';
            reader.setPreloadChapterRenderContents();paint();await new Promise(requestAnimationFrame);
            """#, arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("snapshot().ready")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let formatted = try await web.evaluateJavaScript("snapshot().items[0].sourceParagraphText") as? String
        XCTAssertEqual(formatted, "前半句新半句。\u{200b}", "A zero-width glyph suffix must not merge the next sentence into this source unit")
        // An auto-next accepted by the renderer can land on an access wall
        // without painting its target. A later catalog jump owns a new target.
        let pendingTurn = try await web.evaluateJavaScript("window.__castReaderWeReadNative.turn('next')") as? Bool
        XCTAssertEqual(pendingTurn, true)
        _ = try await web.evaluateJavaScript("window.__castReaderWeReadNative.prepareNavigation()")
        let retiredReady = try await web.evaluateJavaScript("snapshot().ready") as? Bool
        XCTAssertEqual(retiredReady, false, "Manual intent must not reuse the old painted page")
        _ = try await web.callAsyncJavaScript("""
            pages=[{pageIdx:0,chapterUid:8,contents:Array.from('新的章节。').map((text,j)=>({type:1,text,_offset:j,canvasX:20+j*22,rect:{y:20,w:20,h:20}}))}];
            reader.extraRenderPagesInfo=pages;reader.leftRenderPageIdx=0;
            reader.setPreloadChapterRenderContents();paint();await new Promise(requestAnimationFrame);
            """, arguments: [:], in: nil, contentWorld: .page)
        let recovered = try await web.evaluateJavaScript("snapshot()") as? [String: Any]
        XCTAssertEqual(recovered?["ready"] as? Bool, true, "An abandoned automatic target cannot block a newly painted chapter")
        XCTAssertEqual((recovered?["items"] as? [[String: Any]])?.first?["text"] as? String, "新的章节。")
    }

    func testWeReadChinesePageEndPaintAndResumeThroughProductionBridge() async throws {
        try await verifyWeReadSourceCarry(pageCount: 2)
    }

    func testWeReadThreePagesTurnAtEachSourceCueWithoutNewProducer() async throws {
        try await verifyWeReadSourceCarry(pageCount: 3)
    }

    private func verifyWeReadSourceCarry(pageCount: Int) async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "zh")
        let fixture = ReadAloudHTTPFixture { text, _ in
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: 2)) as! [String: Any]
            if text.contains("前半句") {
                body["timestamps"] = pageCount == 2
                    ? [["word":"前半句","start_time":0.0,"end_time":0.35],
                       ["word":"后半句","start_time":0.35,"end_time":1.9]]
                    : [["word":"前半句","start_time":0.0,"end_time":0.35],
                       ["word":"中间句","start_time":0.35,"end_time":0.9],
                       ["word":"后半句","start_time":0.9,"end_time":1.9]]
            }
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService.shared
        audio.stop()
        let document = ReadingDocument(id: UUID().uuidString, title: "WeRead cue fixture", sourceKind: .weread,
            language: "zh", paragraphs: [], sourceURL: "https://weread.qq.com/web/reader/cue-fixture")
        let read = ReadAloudViewModel(document: document, ttsService: fixture.service())
        let explain = ExplainViewModel(document: document)
        let bridge = WebReaderBridge()
        bridge.pageSpeechGenerator = fixture.service()
        bridge.configure(expectsDynamicWebContent: true, isWeRead: true, bookID: document.id, readerURL: document.sourceURL)
        bridge.attach(readVM: read, explainVM: explain)
        let inbox = ForwardingInbox(bridge)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(inbox, contentWorld: .page, name: WebReaderBridge.handlerName)
        for script in [WeReadWebScripts.nativePageBridge, WeReadWebScripts.canvasIntercept, WeReadWebScripts.readerBridge] {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        bridge.webView = web
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: web.frame)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(web); window.isHidden = false
        defer { read.stop(); explain.stop(); audio.stop(); web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: WebReaderBridge.handlerName, contentWorld: .page); window.isHidden = true }
        let pageJSON = pageCount == 2 ? "['开始。前半句','后半句。下一句。']" : "['开始。前半句','中间句','后半句。下一句。']"
        web.loadHTMLString(#"""
        <html><meta name="viewport" content="width=device-width,initial-scale=1"><body style="margin:0">
        <div class="wr_canvasContainer" style="width:350px;height:600px"><canvas width="350" height="600" style="width:350px;height:600px"></canvas></div>
        <button class="renderTarget_pager_button_right" onclick="reader.leftRenderPageIdx++;turns++;setTimeout(paint,25)">下一页</button>
        <script>
        window.turns=0;let offset=0;
        window.pages=\#(pageJSON).map((text,index)=>({pageIdx:index,chapterUid:7,contents:Array.from(text).map((text,j)=>({type:1,text,_offset:offset++,canvasX:20+j*22,rect:{y:20,w:20,h:20}}))}));
        window.reader={_isVue:true,$options:{name:'HorizontalReader',methods:{getCurrentChapterPages(){return pages}}},$el:document.querySelector('.wr_canvasContainer'),bookInfo:{bookId:'cue-fixture'},pageWidth:350,pageHeight:600,fontSizeLevel:2,fontFamily:'serif',displayColumnCount:1,isSinglePage:true,leftRenderPageIdx:0,extraRenderPagesInfo:pages,isLastPage:false,paintPageFinish(){},setPreloadChapterRenderContents(){}};
        (function(){}).apply(reader,[]);
        window.paint=()=>reader.paintPageFinish(document.querySelector('canvas').getContext('2d'));
        setTimeout(paint,50);
        </script></body></html>
        """#, baseURL: URL(string: document.sourceURL!))
        for _ in 0..<300 where !read.hasReadableWebContent { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(read.hasReadableWebContent)
        read.start()
        var resumed = false
        for _ in 0..<400 {
            if inbox.turnPositions.count == pageCount - 1, audio.currentSegment?.text.contains("前半句") == true,
               audio.playbackPosition > (pageCount == 2 ? 0.6 : 1.1), audio.pagePresentationHoldID == nil { resumed = true; break }
            if case .error = read.status { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(try XCTUnwrap(inbox.turnPositions.first), 0.35, accuracy: 0.04)
        if pageCount == 3 {
            XCTAssertTrue(fixture.requests.contains("前半句 中间句 后半句。"), "One whole sentence contains both native page hints")
            XCTAssertEqual(inbox.turnPositions.count, 2)
            if inbox.turnPositions.count == 2 { XCTAssertEqual(inbox.turnPositions[1], 0.9, accuracy: 0.04) }
        }
        XCTAssertTrue(resumed, "Native painted continuation must resume the same source audio")
        XCTAssertEqual(inbox.weReadPaintedReceipts.count, pageCount - 1,
                       "Canvas and exact next cue should arrive in one painted receipt, without a second JS handshake")
        XCTAssertEqual(fixture.requests.filter { $0.contains("前半句") }.count, 1)
    }

    private final class PageMessages: NSObject, WKScriptMessageHandler {
        var values: [[String: Any]] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let value = message.body as? [String: Any] { values.append(value) }
        }
    }

    private func withGoogleFixture(_ body: String, url: String = "https://books.googleusercontent.com/books/reader/frame", messages: PageMessages? = nil, check: (WKWebView) async throws -> Void) async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if let messages { config.userContentController.add(messages, name: WebReaderBridge.handlerName) }
        config.userContentController.addUserScript(WKUserScript(source: GoogleBooksWebScripts.nativeLayoutBridge,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        config.userContentController.addUserScript(WKUserScript(source: try XCTUnwrap(WebReaderView.loadBundleJS()),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: web.frame)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(web); window.isHidden = false
        defer { web.stopLoading(); window.isHidden = true }
        web.loadHTMLString("<html><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0}reader-horizontal-view,reader-page,reader-rendered-page{display:block}reader-page{position:absolute;width:350px;height:560px;left:0;top:0}p{font:20px serif;line-height:30px;margin:20px}</style><body>" + body + "</body></html>",
            baseURL: URL(string: url))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("typeof CR?.extract === 'function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await check(web)
    }

    private final class ForwardingInbox: NSObject, WKScriptMessageHandler {
        let bridge: WebReaderBridge
        var presentations: [[String: Any]] = []
        var turnPositions: [Double] = []
        var onTurn: (() -> Void)?
        var weReadPaintedReceipts: [String] = []
        init(_ bridge: WebReaderBridge) { self.bridge = bridge }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], body["type"] as? String == "wereadPage",
               let payload = body["payload"] as? [String: Any],
               let id = payload["presentedOperationID"] as? String {
                weReadPaintedReceipts.append(id)
            }
            if let body = message.body as? [String: Any], body["type"] as? String == "pagePresentationReady",
               let payload = body["payload"] as? [String: Any] { presentations.append(payload) }
            if let body = message.body as? [String: Any], body["type"] as? String == "rendered",
               let payload = body["payload"] as? [String: Any],
               let id = payload["presentedOperationID"] as? String {
                XCTAssertEqual(id, AudioPlayerService.shared.pagePresentationHoldID?.uuidString,
                               "A paint receipt must still belong to the held media operation")
                presentations.append(["holdID": id, "ready": true, "nativePagePaint": true])
            }
            if let body = message.body as? [String: Any], ["googleBooksTurnRequested", "wereadTurnRequested"].contains(body["type"] as? String ?? "") {
                turnPositions.append(AudioPlayerService.shared.playbackPosition)
                onTurn?()
            }
            bridge.userContentController(controller, didReceive: message)
        }
    }

    func testKoboRealCueTurnsAndAcknowledgesLivePageBeforeResuming() async throws {
        try await verifyKoboCuePages(pageCount: 2)
    }

    func testKoboThreePagesUseTwoRealCuesAndOneSourceProducer() async throws {
        try await verifyKoboCuePages(pageCount: 3)
    }

    func testWholePageWaitsForMediaEndAndPaintBeforePreparedSuccessor() async throws {
        try await verifyKoboCuePages(pageCount: 2, wholePage: true)
    }

    func testTransientMissingAnchorRetainsHeldMediaUntilExactPaintIsReady() async throws {
        try await verifyKoboCuePages(pageCount: 2, deferFirstAnchor: true)
    }

    func testKoboPreparedSuccessorSurvivesCarriedSentenceThroughProductionBridge() async throws {
        try await verifyKoboCuePages(pageCount: 2, preparedCarry: true)
    }

    func testKoboNativePageAndExactCuePaintTogetherWithoutHostConfirmationRoundTrip() async throws {
        try await verifyKoboCuePages(pageCount: 2, expectsNativePaint: true)
    }

    func testWholePageSuccessorPaintsItsExactFirstCueWithNativePage() async throws {
        try await verifyKoboCuePages(pageCount: 2, wholePage: true, expectsNativePaint: true)
    }

    func testUntimedSingleSentenceSuccessorPaintsAndContinuesWithoutWordCue() async throws {
        try await verifyKoboCuePages(pageCount: 2, wholePage: true, expectsNativePaint: true,
                                    untimedOpening: true)
    }

    func testWholePageSuccessorRejectsMismatchedFirstCue() async throws {
        try await verifyKoboCuePages(pageCount: 2, wholePage: true, expectsNativePaint: false)
    }

    func testKoboMismatchedSourceCueRequiresHostAnchorConfirmation() async throws {
        try await verifyKoboCuePages(pageCount: 2, expectsNativePaint: false)
    }

    func testKoboConfirmedBookEndDrainsPageHoldWithoutExtraNextOrTimeout() async throws {
        try await verifyKoboCuePages(pageCount: 2, wholePage: true, bookEnd: true)
    }

    func testNextPageProducerSurvivesCurrentPagePartTransitions() async throws {
        try await verifyKoboCuePages(pageCount: 2, wholePage: true, multipartPreload: true)
    }

    private func verifyKoboCuePages(pageCount: Int, wholePage: Bool = false, deferFirstAnchor: Bool = false,
                                  preparedCarry: Bool = false, expectsNativePaint: Bool? = nil,
                                  bookEnd: Bool = false, multipartPreload: Bool = false, untimedOpening: Bool = false) async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let fixture = ReadAloudHTTPFixture { text, _ in
            if multipartPreload {
                if text == "Slow first." {
                    return .response(ReadAloudHTTPFixture.body("Slow ", tail: "first.", duration: 1.2))
                }
                if text == "first." { return .response(ReadAloudHTTPFixture.body(text, duration: 4)) }
                return .response(ReadAloudHTTPFixture.body(text, duration: 3), delay: 2)
            }
            if wholePage {
                var body = try! JSONSerialization.jsonObject(with:
                    ReadAloudHTTPFixture.body(text, duration: text == "Slow." ? 1.8 : 3)) as! [String: Any]
                if untimedOpening && text == "Rapidly onward." { body["timestamps"] = [] }
                return .response(try! JSONSerialization.data(withJSONObject: body))
            }
            if text == "The prepared successor." { return .response(ReadAloudHTTPFixture.body(text, duration: 3)) }
            var body = try! JSONSerialization.jsonObject(with: ReadAloudHTTPFixture.body(text, duration: preparedCarry ? 6 : 3)) as! [String: Any]
            body["timestamps"] = [["word":"Slow","start_time":0.0,"end_time":preparedCarry ? 3.0 : 0.4],
                                  ["word":"rapidly","start_time":preparedCarry ? 3.0 : 0.4,"end_time":preparedCarry ? 4.0 : 1.3],
                                  ["word":"onward","start_time":preparedCarry ? 4.0 : 1.3,"end_time":preparedCarry ? 5.8 : 2.8]]
            return .response(try! JSONSerialization.data(withJSONObject: body))
        }
        defer { fixture.close() }
        let audio = AudioPlayerService.shared
        audio.stop()
        let document = ReadingDocument(id: UUID().uuidString, title: "Kobo cue fixture", sourceKind: .kobo,
            language: "en", paragraphs: [], sourceURL: "https://readnow.kobo.com/f0000001-1111-4111-8111-000000000001")
        let read = ReadAloudViewModel(document: document, ttsService: fixture.service())
        let explain = ExplainViewModel(document: document)
        let bridge = WebReaderBridge()
        bridge.pageSpeechGenerator = fixture.service()
        bridge.configure(expectsDynamicWebContent: true, livePlatform: .kobo, bookID: document.id, readerURL: document.sourceURL)
        bridge.attach(readVM: read, explainVM: explain)
        // SwiftUI republishes setActive while AVPlayer transitions between
        // parts. Exercise that real host entry point, not only page messages.
        let hostUpdates = multipartPreload ? read.objectWillChange
            .receive(on: RunLoop.main).sink { bridge.setActive(readMode: true) } : nil
        defer { hostUpdates?.cancel() }
        let inbox = ForwardingInbox(bridge)
        if preparedCarry {
            inbox.onTurn = {
                XCTAssertEqual(fixture.requests.filter { $0 == "The prepared successor." }.count, 1,
                               "The successor must be generated before visual navigation")
            }
        }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(inbox, name: WebReaderBridge.handlerName)
        config.userContentController.addUserScript(WKUserScript(source: try XCTUnwrap(WebReaderView.loadBundleJS()), injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .page))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        bridge.webView = web
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: web.frame)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(web); window.isHidden = false
        defer { read.stop(); explain.stop(); audio.stop(); web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: WebReaderBridge.handlerName); window.isHidden = true }
        let html = #"""
        <html><meta name="viewport" content="width=device-width,initial-scale=1"><body style="margin:0">
        <div id="BookView" style="position:absolute;left:20px;top:20px;width:240px;height:280px;overflow:hidden">
          <div class="ReadingOrderView"><div class="ReadingItem"><iframe data-chapterurl="chapter-1.xhtml" style="position:relative;width:720px;height:280px;border:0" srcdoc="<style>html,body{margin:0}p{margin:0;position:relative;width:720px;height:280px;font:24px/32px Georgia}span{position:absolute;top:20px}</style><p><span style='left:12px'>Slow </span><span style='left:252px'>rapidly onward.</span></p>"></iframe></div></div>
        </div><button aria-label="Next page" style="position:absolute;top:340px" onclick="turns++;document.querySelector('iframe').style.left='-240px';this.disabled=true">Next page</button>
        <script>window.turns=0</script></body></html>
        """#
        let source = pageCount == 2 ? html : html
            .replacingOccurrences(of: "rapidly onward.</span>", with: "rapidly </span><span style='left:492px'>onward.</span>")
            .replacingOccurrences(of: "style.left='-240px';this.disabled=true", with: "style.left=(-240*turns)+'px';this.disabled=turns===2")
        let wholePageSource = html.replacingOccurrences(of:
            "<p><span style='left:12px'>Slow </span><span style='left:252px'>rapidly onward.</span></p>",
            with: "<p style='position:absolute;left:12px;top:20px;width:200px'>Slow.</p><p style='position:absolute;left:252px;top:20px;width:200px'>Rapidly onward.</p>")
        let preparedCarrySource = source.replacingOccurrences(of: "</p>\"></iframe>",
            with: "</p><p style='position:absolute;left:252px;top:80px;width:200px;height:80px'>The prepared successor.</p>\"></iframe>")
        let renderedSource = wholePage ? wholePageSource : preparedCarry ? preparedCarrySource : source
        web.loadHTMLString(multipartPreload ? renderedSource.replacingOccurrences(of: "Slow.", with: "Slow first.") : renderedSource, baseURL: URL(string: document.sourceURL!))
        for _ in 0..<300 where !read.hasReadableWebContent { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(read.hasReadableWebContent)
        _ = try await web.evaluateJavaScript("""
          (()=>{window.hostConfirmations=0;const confirm=CR.confirmPresentation;
            CR.confirmPresentation=(arg)=>{window.hostConfirmations++;confirm(arg)};})()
          """)
        if expectsNativePaint == false || deferFirstAnchor {
            _ = try await web.evaluateJavaScript("""
              (()=>{const next=CR.gbNextPage;CR.gbNextPage=(arg)=>{
                if(arg.sourcePresentation)arg.sourcePresentation.text='wrong source must not be painted';
                return next(arg)}})()
              """)
        }
        if deferFirstAnchor {
            _ = try await web.evaluateJavaScript("""
            (()=>{const confirm=CR.confirmPresentation;let first=true;
            CR.confirmPresentation=(arg)=>{if(first){first=false;CR.clearHighlight()}confirm(arg)}})()
            """)
        }
        if bookEnd {
            _ = try await web.evaluateJavaScript("""
              CR.gbNextPage=(arg)=>{window.webkit.messageHandlers.castreader.postMessage({
                type:'googleBooksTurnFailed',payload:{...arg,source:'kobo',
                  frameSessionID:arg.originFrameSessionID,method:'native-book-end',lateEligible:false,
                  nativeBookEnd:{pagesOfBook:100,firstPage:99,lastPage:99}}});return false};true
              """)
        }
        read.start()
        if bookEnd {
            for _ in 0..<250 where !read.isFinished || audio.pagePresentationHoldID != nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(read.isFinished, "Proven book end must finish the source session")
            XCTAssertNil(audio.pagePresentationHoldID, "Book end is not an unconfirmed next-page paint")
            XCTAssertFalse(audio.isBuffering)
            let turns = try await web.evaluateJavaScript("turns") as? Int
            XCTAssertEqual(turns, 0)
            return
        }
        var held = false
        var mediaAfterAcknowledgement = false
        for _ in 0..<600 {
            held = held || audio.pagePresentationHoldID != nil
            if inbox.presentations.filter({ $0["ready"] as? Bool == true }).count >= pageCount - 1,
               audio.playbackPosition > (pageCount == 2 ? 0.6 : 1.5),
               !preparedCarry || audio.currentSegment?.text == "The prepared successor.",
               !wholePage || audio.currentSegment?.text == "Rapidly onward." {
                mediaAfterAcknowledgement = true; break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if deferFirstAnchor {
            XCTAssertTrue(inbox.presentations.contains { $0["ready"] as? Bool == false })
            XCTAssertFalse({ if case .error = read.status { return true }; return false }(),
                           "A transient missing anchor must stay held, not destroy the active queue")
        }
        XCTAssertTrue(held, "The real AVPlayer cue must freeze transport during the native turn")
        XCTAssertTrue(mediaAfterAcknowledgement, "A painted live source anchor must release the same item")
        if let expectsNativePaint {
            XCTAssertEqual(inbox.presentations.contains { $0["nativePagePaint"] as? Bool == true }, expectsNativePaint)
            let confirmations = try await web.evaluateJavaScript("window.hostConfirmations") as? Int ?? -1
            if expectsNativePaint { XCTAssertEqual(confirmations, 0) }
            else { XCTAssertGreaterThan(confirmations, 0) }
        }
        XCTAssertEqual(fixture.requests.first, wholePage ? (multipartPreload ? "Slow first." : "Slow.") : "Slow rapidly onward.")
        if wholePage {
            XCTAssertGreaterThanOrEqual(inbox.turnPositions.first ?? 0, 1.79, "Preparation lead cannot authorize an early visual turn")
            XCTAssertEqual(fixture.requests.filter { $0 == "Rapidly onward." }.count, 1)
        }
        if preparedCarry {
            XCTAssertEqual(fixture.requests.filter { $0 == "The prepared successor." }.count, 1,
                           "Committing the carry must adopt, not discard and regenerate, the exact prepared source")
        }
        let turns = try await web.evaluateJavaScript("turns") as? Int
        XCTAssertEqual(turns, pageCount - 1)
        XCTAssertEqual(fixture.requests.filter { $0 == (wholePage ? (multipartPreload ? "Slow first." : "Slow.") : "Slow rapidly onward.") }.count, 1)
    }

    func testKoboNativeBookClipHiddenLabelsDropCapAndFade() async throws {
        try await withGoogleFixture(#"""
        <div id="BookView" style="position:absolute;left:20px;top:20px;width:240px;height:280px;overflow:visible">
        <div class="ReadingOrderView"><div class="ReadingItem"><iframe data-chapterurl="chapter-1.xhtml" style="width:720px;height:280px;border:0" srcdoc="<style>html,body{margin:0;height:280px;column-width:240px;column-gap:0;column-fill:auto}p{margin:0;height:280px;font:24px/32px Georgia}span.drop{position:relative;top:-3px}</style><p><span class='drop'>D</span>ropped caps stay visible.<span style='display:none'>HIDDEN SOCIAL LABEL</span></p><p>This next column must not be included.</p><p>Hidden third column.</p>"></iframe></div></div></div>
        """#, url: "https://readnow.kobo.com/f0000001-1111-4111-8111-000000000001") { web in
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("document.querySelector('iframe')?.contentDocument?.querySelectorAll('p').length === 3")) as? Bool == true { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let rows = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(rows?.count, 1)
            XCTAssertEqual(rows?.first?["text"] as? String, "Dropped caps stay visible.")
            let sourceID = rows?.first?["sourceParagraphIndex"] as? Int
            let paint = try await web.evaluateJavaScript("""
              CR.init({segments:[{paragraphIndex:0,text:'Dropped caps stay visible.'}]});
              CR.highlightRange({paragraphIndex:0,charStart:0,charEnd:1,segSeq:0,segmentTexts:[]});
              (()=>{const d=document.querySelector('iframe').contentDocument;const r=d.createRange();r.selectNodeContents(d.querySelector('.drop'));return {sourceTop:r.getBoundingClientRect().top, tops:[...d.querySelectorAll('.cr-hl-ov')].map(n=>n.getBoundingClientRect().top)}})()
              """) as? [String: Any]
            let tops = paint?["tops"] as? [Double] ?? []
            XCTAssertFalse(tops.isEmpty)
            XCTAssertTrue(tops.allSatisfy { $0 >= -0.01 }, "Paint must be clipped to the native page")
            let faded = try await web.evaluateJavaScript("document.querySelector('.ReadingOrderView').style.opacity='0.4';CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertTrue(faded?.isEmpty == true, "A partially faded target is not presented")
            let secondChapter = try await web.evaluateJavaScript("document.querySelector('.ReadingOrderView').style.opacity='1';document.querySelector('iframe').setAttribute('data-chapterurl','chapter-2.xhtml');CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertNotEqual(sourceID, secondChapter?.first?["sourceParagraphIndex"] as? Int,
                "Identical chapter text must retain distinct native source ownership")
        }
    }

    func testKoboNextPagePreviewDoesNotCountColumnGapTwice() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <div id="BookView" style="position:absolute;left:0;top:0;width:250px;height:280px;overflow:hidden">
        <div class="ReadingOrderView"><div class="ReadingItem"><iframe data-chapterurl="chapter-stride.xhtml" style="position:relative;width:1000px;height:280px;border:0" srcdoc="<style>html{margin:0}body{margin:0;width:200px;height:280px;column-width:200px;column-gap:50px;column-fill:auto}p{margin:0;height:280px;break-after:column;font:20px/28px Georgia}</style><p>The first visible column owns this opening paragraph.</p><p>The second column starts exactly at its native offset and ends here.</p><p>The third column must remain entirely outside the prepared second page.</p>"></iframe></div></div></div>
        <button id="next" aria-label="Next page" style="position:absolute;top:350px" onclick="document.querySelector('iframe').style.left='-250px';this.disabled=true">Next page</button>
        """#, url: "https://readnow.kobo.com/f0000001-1111-4111-8111-000000000001", messages: inbox) { web in
            for _ in 0..<300 where !inbox.values.contains(where: { $0["type"] as? String == "googleBooksPagePreview" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let payload = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "googleBooksPagePreview" }?["payload"] as? [String: Any])
            let predicted = try XCTUnwrap(payload["paragraphs"] as? [[String: Any]])
            XCTAssertEqual(predicted.map { $0["text"] as? String ?? "" },
                ["The second column starts exactly at its native offset and ends here."])
            _ = try await web.evaluateJavaScript("document.querySelector('#next').click()")
            try await Task.sleep(nanoseconds: 900_000_000)
            let rendered = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered")
            let actual = try XCTUnwrap(rendered as? [[String: Any]])
            XCTAssertEqual(actual.map { $0["text"] as? String ?? "" }, predicted.map { $0["text"] as? String ?? "" })
            for key in ["sourceParagraphIndex", "sourceUTF16Start", "sourceUTF16End"] {
                XCTAssertEqual(actual.map { $0[key] as? Int ?? -1 }, predicted.map { $0[key] as? Int ?? -1 }, key)
            }
        }
    }

    func testGoogleExplainMarkSurvivesReopenedFragmentAndTwoColumnReflow() async throws {
        try await withGoogleFixture(#"""
        <reader-app><reader-rendered-page style="position:absolute;left:0;top:0;width:350px;height:560px;overflow:hidden"><div class="gb-segment"><p>First retained sentence.</p><p>Second retained sentence.</p></div></reader-rendered-page></reader-app>
        """#) { web in
            _ = try await web.evaluateJavaScript("CR.extract('fixture')")
            let first = "First retained sentence."
            let second = "Second retained sentence."
            let split = first.utf16.count
            let original = LiveWebPageSourceSlice(visibleParagraphIndex: 0, sourceParagraphIndex: 42,
                sourceUTF16Start: 102, sourceUTF16End: 102 + split + second.utf16.count, text: first + second)
            let visible = [LiveWebPageSourceSlice(visibleParagraphIndex: 0, sourceParagraphIndex: 42,
                sourceUTF16Start: 102, sourceUTF16End: 102 + split, text: first),
                LiveWebPageSourceSlice(visibleParagraphIndex: 1, sourceParagraphIndex: 42,
                sourceUTF16Start: 102 + split, sourceUTF16End: original.sourceUTF16End, text: second)]
            let fragments = LiveWebSourceReflowContract.domFragments(for: original, in: visible, domOffsets: [0, 0])
            let segments: [[String: Any]] = [["paragraphIndex": 0, "text": original.text,
                "domParagraphIndex": 0, "domFragments": fragments.map(\.payload)]]
            let count = try await web.callAsyncJavaScript("""
                CR.init({segments}); CR.showMark({id:'kept',paragraphIndex:0,charStart:0,charEnd:end,action:'underline',seed:11});
                return document.querySelectorAll('svg[data-cr-marks] path').length;
                """, arguments: ["segments": segments, "end": original.text.utf16.count], in: nil, contentWorld: .page) as? Int
            XCTAssertGreaterThanOrEqual(count ?? 0, 2, "One immutable mark must paint both visible source fragments")
            let suffix = LiveWebSourceReflowContract.domFragments(for: original, in: [visible[1]], domOffsets: [0])
            let suffixSegments: [[String: Any]] = [["paragraphIndex": 0, "text": original.text,
                "domParagraphIndex": 1, "domFragments": suffix.map(\.payload)]]
            let painted = try await web.callAsyncJavaScript("""
                CR.clearMarks(); CR.init({segments});
                CR.showMark({id:'kept',paragraphIndex:0,charStart:start,charEnd:end,action:'underline',seed:11});
                const p=document.querySelectorAll('.gb-segment p')[1].getBoundingClientRect();
                const paths=[...document.querySelectorAll('svg[data-cr-marks] path')];
                return paths.length>0&&paths.every(path=>{const r=path.getBoundingClientRect();return r.top>=p.top&&r.bottom<=p.bottom+8});
                """, arguments: ["segments": suffixSegments, "start": split, "end": original.text.utf16.count], in: nil, contentWorld: .page) as? Bool
            XCTAssertEqual(painted, true, "A source offset of 102 must never be applied to a short reopened DOM fragment")
        }
    }

    func testGoogleNativeFragmentsKeepSourceIdentityButUseLocalDOMOffsets() async throws {
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage">
        <reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p ocean_stream_index="1" ocean-sliced-element>Hello </p></div></reader-rendered-page></reader-page>
        <reader-page id="page-0-1" class="-gb-loaded" style="left:1000px"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p ocean_stream_index="1" ocean-reopened-element>world. End.</p></div></reader-rendered-page></reader-page>
        <reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text stale-font" style="width:350px;height:560px"><div class="gb-segment"><p>Wrong hidden typography.</p></div></reader-rendered-page></reader-page>
        </li></ol></reader-horizontal-view><button><mat-icon>chevron_right</mat-icon></button>
        """#) { web in
            let first = try await web.evaluateJavaScript("CR.extract('fixture'); window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(first?.count, 1)
            XCTAssertEqual(first?.first?["text"] as? String, "Hello")
            XCTAssertEqual(first?.first?["speechText"] as? String, "Hello world.")
            let next = try await web.evaluateJavaScript("document.querySelectorAll('reader-page').forEach(p=>{p.classList.toggle('shown',p.id==='page-0-1');p.style.left=p.id==='page-0-1'?'0px':'1000px'});CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(next?.first?["text"] as? String, "world. End.")
            XCTAssertEqual(next?.first?["sourceParagraphIndex"] as? Int, first?.first?["sourceParagraphIndex"] as? Int)
            XCTAssertEqual(next?.first?["sourceUTF16Start"] as? Int, 6)
            XCTAssertEqual(next?.first?["domUTF16Start"] as? Int, 0)
            let rects = try await web.evaluateJavaScript("CR.init({segments:[{paragraphIndex:0,text:'world. End.',domCharOffset:0}]});CR.highlightRange({paragraphIndex:0,charStart:0,charEnd:5,segSeq:0,segmentTexts:[]});document.querySelectorAll('.cr-hl-ov').length") as? Int
            XCTAssertGreaterThan(rects ?? 0, 0)
        }
    }

    func testGoogleTransientMeasuringDOMIsCapturedAndTrimmedByNextNativeSlice() async throws {
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage"><reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p ocean_stream_index="1" ocean-sliced-element>Hello </p></div></reader-rendered-page></reader-page></li></ol></reader-horizontal-view>
        <button><mat-icon>chevron_right</mat-icon></button>
        """#) { web in
            _ = try await web.callAsyncJavaScript(#"""
            const frame=document.createElement('iframe'); frame.style.cssText='position:absolute;left:-9999px;width:350px;height:560px;border:0';document.body.append(frame);
            const doc=frame.contentDocument; doc.documentElement.style.cssText='height:100%;width:100%';doc.body.className='layout';doc.body.style.margin='0';
            const a=doc.createElement('div');a.className='gb-segment';a.setAttribute('ocean_stream_index','0');a.innerHTML='<p ocean_stream_index="1">Hello world.</p>';doc.body.append(a);a.remove();
            const b=doc.createElement('div');b.className='gb-segment';b.setAttribute('ocean_stream_index','0');b.setAttribute('ocean-reopened-element','');b.setAttribute('ocean_stream_close','');b.innerHTML='<p ocean_stream_index="1" ocean-reopened-element ocean_stream_close>world.</p>';doc.body.append(b);b.remove();
            await new Promise(resolve=>setTimeout(resolve,0));
            """#, arguments: [:], in: nil, contentWorld: .page)
            let count = try await web.evaluateJavaScript("JSON.parse(document.documentElement.getAttribute('data-castreader-pb-layouts')||'[]').length") as? Int
            XCTAssertEqual(count, 1)
            let actual = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(actual?.first?["text"] as? String, "Hello")
            XCTAssertEqual(actual?.first?["speechText"] as? String, "Hello world.")
            XCTAssertEqual(actual?.first?["sourceSpeechEnd"] as? Int, 12)
        }
    }

    func testGoogleCurrentNativePageReanchorsAfterUnknownEarlierCut() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage"><reader-page id="page-0-1" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><a id="GBS.PT1"></a><p ocean-reopened-element>old expanded.</p><p>Current exact source.</p></div></reader-rendered-page></reader-page></li></ol></reader-horizontal-view>
        <button><mat-icon>chevron_right</mat-icon></button>
        <script>document.documentElement.setAttribute('data-castreader-pb-layouts',JSON.stringify([{id:1,className:'layout',width:350,height:560,anchors:['GBS.PT1'],pages:[
          {blocks:[{raw:'An unresolved old',stream:'1',boundaries:[],reopened:false,closed:false}],closed:false},
          {blocks:[{raw:'old expanded.',stream:'1',boundaries:[],reopened:true,closed:true},{raw:'Current exact source.',stream:'2',boundaries:[],reopened:false,closed:true}],closed:true},
          {blocks:[{raw:'The confirmed immediate successor.',stream:'3',boundaries:[],reopened:false,closed:true}],closed:true}
        ]}]));</script>
        """#, messages: inbox) { web in
            for _ in 0..<250 where !inbox.values.contains(where: { $0["type"] as? String == "googleBooksPagePreview" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let preview = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "googleBooksPagePreview" }?["payload"] as? [String: Any])
            let paragraphs = try XCTUnwrap(preview["paragraphs"] as? [[String: Any]])
            XCTAssertEqual(paragraphs.compactMap { $0["text"] as? String }, ["The confirmed immediate successor."])
            let current = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(current?.compactMap { $0["text"] as? String }, ["old expanded.", "Current exact source."])
        }
    }

    func testGoogleVerifiedNextPageSurvivesUnknownLaterMeasuredCut() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage"><reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><a id="GBS.PT1"></a><p>A.</p></div></reader-rendered-page></reader-page></li></ol></reader-horizontal-view>
        <button><mat-icon>chevron_right</mat-icon></button>
        <script>document.documentElement.setAttribute('data-castreader-pb-layouts',JSON.stringify([{id:1,className:'layout',width:350,height:560,anchors:['GBS.PT1'],pages:[
          {blocks:[{raw:'A.',stream:'1',boundaries:[],reopened:false,closed:true}],closed:true},
          {blocks:[{raw:'The confirmed next page.',stream:'2',boundaries:[],reopened:false,closed:true}],closed:true},
          {blocks:[{raw:'C prefix',stream:'3',boundaries:[],reopened:false,closed:false}],closed:false},
          {blocks:[{raw:'prefix expanded.',stream:'3',boundaries:[],reopened:true,closed:true}],closed:true}
        ]}]));</script>
        """#, messages: inbox) { web in
            for _ in 0..<250 where !inbox.values.contains(where: { $0["type"] as? String == "googleBooksPagePreview" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let preview = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "googleBooksPagePreview" }?["payload"] as? [String: Any])
            let paragraphs = try XCTUnwrap(preview["paragraphs"] as? [[String: Any]])
            XCTAssertEqual(paragraphs.compactMap { $0["text"] as? String }, ["The confirmed next page."])
            let current = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(current?.compactMap { $0["text"] as? String }, ["A."], "Preparation must not move the visible page")
        }
    }

    func testGoogleNativeEndResolvesOwnedTurnWithoutAnotherClick() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <reader-page id="page-30-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>The last page finishes here.</p></div></reader-rendered-page></reader-page>
        <reader-end-of-book style="display:none;width:350px;height:560px">Book complete</reader-end-of-book>
        <button onclick="window.clicks=(window.clicks||0)+1;document.querySelector('reader-page').remove();const e=document.querySelector('reader-end-of-book');e.classList.add('shown');e.style.display='block';this.disabled=true"><mat-icon>chevron_right</mat-icon></button>
        """#, messages: inbox) { web in
            for _ in 0..<200 where !inbox.values.contains(where: { $0["type"] as? String == "rendered" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            _ = try await web.evaluateJavaScript("window.CastReaderGoogleBooks.nextPage({turnID:'end-owned'})")
            for _ in 0..<100 where !inbox.values.contains(where: { $0["type"] as? String == "googleBooksTurnFailed" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let end = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "googleBooksTurnFailed" }?["payload"] as? [String: Any])
            XCTAssertEqual(end["turnID"] as? String, "end-owned")
            XCTAssertEqual(end["reason"] as? String, "native-book-end")
            XCTAssertEqual(end["lateEligible"] as? Bool, false)
            XCTAssertTrue(GoogleBooksBookEndContract.isConfirmed(end["nativeBookEnd"]))
            let clicks = try await web.evaluateJavaScript("window.clicks") as? Int
            XCTAssertEqual(clicks, 1)
        }
    }

    func testGoogleHiddenCompletionPanelCannotEndLoadingChapter() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>The chapter is still loading.</p></div></reader-rendered-page></reader-page>
        <reader-end-of-book class="shown" style="display:none">Hidden cached book end</reader-end-of-book>
        <button disabled><mat-icon>chevron_right</mat-icon></button>
        """#, messages: inbox) { web in
            for _ in 0..<200 where !inbox.values.contains(where: { $0["type"] as? String == "rendered" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            _ = try await web.evaluateJavaScript("window.CastReaderGoogleBooks.nextPage({turnID:'loading-owned'})")
            try await Task.sleep(nanoseconds: 800_000_000)
            XCTAssertFalse(inbox.values.contains { value in
                let payload = value["payload"] as? [String: Any]
                return payload?["reason"] as? String == "native-book-end"
            })
        }
    }

    func testGoogleRotationRevealsUniqueOffscreenSourceWithoutVisibleNeighbors() async throws {
        let inbox = PageMessages()
        let source = "The exact speaking paragraph survives rotation into the following native spread."
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage">
        <reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>Earlier unrelated chapter text.</p></div></reader-rendered-page></reader-page>
        <reader-page id="page-0-1" class="-gb-loaded" style="left:1000px"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>The exact speaking paragraph survives rotation into the following native spread.</p></div></reader-rendered-page></reader-page>
        </li></ol></reader-horizontal-view>
        <button onclick="document.querySelectorAll('reader-page').forEach(p=>{p.classList.toggle('shown',p.id==='page-0-1');p.style.left=p.id==='page-0-1'?'0px':'1000px'})"><mat-icon>chevron_right</mat-icon></button>
        """#, messages: inbox) { web in
            for _ in 0..<200 where !inbox.values.contains(where: { $0["type"] as? String == "rendered" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let current = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "rendered" }?["payload"] as? [String: Any])
            let payload: [String: Any] = ["reflowSourceText": source,
                "reflowBaseline": try XCTUnwrap(current["signature"] as? String),
                "originFrameSessionID": try XCTUnwrap(current["frameSessionID"] as? String)]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let script = "(() => { try { window.CastReaderGoogleBooks.refresh(" + String(decoding: data, as: UTF8.self) + "); return 'ok'; } catch (e) { return String(e) + String(e.stack || ''); } })()"
            let refreshed: String = try await withCheckedThrowingContinuation { continuation in
                web.evaluateJavaScript(script) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "missing result") }
                }
            }
            XCTAssertEqual(refreshed, "ok")
            for _ in 0..<200 {
                if try await web.evaluateJavaScript("document.querySelector('reader-page.shown').id") as? String == "page-0-1" { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let shown = try await web.evaluateJavaScript("document.querySelector('reader-page.shown').id") as? String
            XCTAssertEqual(shown, "page-0-1")
        }
    }

    func testKoboContentsOpensLocalizedNativeFooterWithoutClickingChapterNavigation() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <div class="RXFooter_metaInfoTocButton"><div class="TextButton_touchAreaSize" aria-label="開啟目錄">
        <div class="TextButton_button TextButton_clickable" role="button" aria-label="開啟目錄"
          onclick="window.tocClicks=(window.tocClicks||0)+1;document.getElementById('contents').hidden=false">Chapter 9</div></div></div>
        <div role="button" aria-label="下一章" onclick="window.wrongChapter=true">Next chapter</div>
        <div id="contents" hidden>Contents</div>
        """#, url: "https://readnow.kobo.com/f0000001-1111-4111-8111-000000000001", messages: inbox) { web in
            let opened = try await web.evaluateJavaScript(ReaderWebAppearanceCenter.openKoboContentsScript) as? Bool
            XCTAssertEqual(opened, true)
            let visible = try await web.evaluateJavaScript("!document.getElementById('contents').hidden && window.tocClicks===1 && !window.wrongChapter") as? Bool
            XCTAssertEqual(visible, true)
        }
    }

    func testKoboRevisitedPageRepublishesPreviewAfterChapterWithoutGeometry() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <div id="BookView" style="position:absolute;left:0;top:0;width:240px;height:280px;overflow:hidden"><div class="ReadingOrderView">
        <div class="ReadingItem"><iframe id="returnPage" data-chapterurl="chapter-1.xhtml" style="position:absolute;left:0;top:0;width:720px;height:280px;border:0" srcdoc="<style>html,body{margin:0}p{position:absolute;width:200px;height:100px;font:20px/28px Georgia}</style><p style='left:12px'>The current opening page.</p><p style='left:252px'>The confirmed prepared successor.</p>"></iframe></div>
        <div class="ReadingItem"><iframe id="tailPage" data-chapterurl="chapter-2.xhtml" style="position:absolute;left:5000px;top:0;width:240px;height:280px;border:0" srcdoc="<style>html,body{margin:0}p{font:20px/28px Georgia}</style><p>The other chapter ends here.</p>"></iframe></div>
        </div></div>
        """#, url: "https://readnow.kobo.com/f0000001-1111-4111-8111-000000000001", messages: inbox) { web in
            func previews() -> [[String: Any]] {
                inbox.values.filter { $0["type"] as? String == "googleBooksPagePreview" }
                    .compactMap { $0["payload"] as? [String: Any] }
            }
            for _ in 0..<300 where previews().isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
            let first = try XCTUnwrap(previews().first)
            let signature = try XCTUnwrap(first["sourceSignature"] as? String)
            let initialCount = previews().filter { $0["sourceSignature"] as? String == signature }.count
            _ = try await web.evaluateJavaScript("document.getElementById('returnPage').style.left='5000px';document.getElementById('tailPage').style.left='0px';window.CastReaderKobo.refresh({});true")
            var committedOtherChapter = false
            for _ in 0..<300 {
                if inbox.values.contains(where: {
                    guard $0["type"] as? String == "rendered", let p = $0["payload"] as? [String: Any],
                          let rows = p["paragraphs"] as? [[String: Any]] else { return false }
                    return rows.first?["text"] as? String == "The other chapter ends here."
                }) { committedOtherChapter = true; break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(committedOtherChapter)
            _ = try await web.evaluateJavaScript("document.getElementById('tailPage').style.left='5000px';document.getElementById('returnPage').style.left='0px';window.CastReaderKobo.refresh({});true")
            for _ in 0..<300 where previews().filter({ $0["sourceSignature"] as? String == signature }).count <= initialCount {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let returned = previews().filter { $0["sourceSignature"] as? String == signature }
            XCTAssertGreaterThan(returned.count, initialCount, "Native invalidated the prior preview while the other chapter was visible")
            XCTAssertEqual(returned.last?["contentFingerprint"] as? String, first["contentFingerprint"] as? String)
        }
    }

    func testGoogleRefreshedPresentationRepublishesItsNativePreview() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage">
        <reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>Current exact source page.</p></div></reader-rendered-page></reader-page>
        <reader-page id="page-0-1" class="-gb-loaded" style="left:1000px"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>The confirmed next source page.</p></div></reader-rendered-page></reader-page>
        </li></ol></reader-horizontal-view>
        """#, messages: inbox) { web in
            func previews() -> [[String: Any]] {
                inbox.values.filter { $0["type"] as? String == "googleBooksPagePreview" }
                    .compactMap { $0["payload"] as? [String: Any] }
            }
            for _ in 0..<250 where previews().isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
            let first = try XCTUnwrap(previews().first), count = previews().count
            _ = try await web.evaluateJavaScript("window.CastReaderGoogleBooks.refresh({});true")
            for _ in 0..<250 where previews().count <= count { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertGreaterThan(previews().count, count)
            XCTAssertEqual(previews().last?["contentFingerprint"] as? String, first["contentFingerprint"] as? String)
        }
    }

    func testKoboLaidOutNextChapterPreviewsOnlyItsFirstPhysicalPage() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <div id="BookView" style="position:absolute;left:0;top:0;width:240px;height:280px;overflow:hidden"><div class="ReadingOrderView">
        <div class="ReadingItem"><iframe data-chapterurl="chapter-1.xhtml" style="position:absolute;left:0;top:0;width:720px;height:280px;border:0" srcdoc="<style>html,body{margin:0;height:280px;column-width:240px;column-gap:0;column-fill:auto}p{margin:0;height:280px;font:24px/32px Georgia}</style><p>Current chapter ends here.</p>"></iframe></div>
        <div class="ReadingItem"><iframe id="nextChapter" data-chapterurl="chapter-2.xhtml" style="position:absolute;left:5000px;top:0;width:720px;height:280px;border:0" srcdoc="<style>html,body{margin:0;height:280px;column-width:240px;column-gap:0;column-fill:auto}p{margin:0;height:280px;font:24px/32px Georgia}</style><p>Verified next chapter opening.</p><p>This belongs to its second page.</p>"></iframe></div>
        </div></div>
        """#, url: "https://readnow.kobo.com/f0000001-1111-4111-8111-000000000001", messages: inbox) { web in
            for _ in 0..<300 where !inbox.values.contains(where: { $0["type"] as? String == "googleBooksPagePreview" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let preview = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "googleBooksPagePreview" }?["payload"] as? [String: Any])
            let rows = try XCTUnwrap(preview["paragraphs"] as? [[String: Any]])
            XCTAssertEqual(rows.compactMap { $0["text"] as? String }, ["Verified next chapter opening."])
            let current = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(current?.compactMap { $0["text"] as? String }, ["Current chapter ends here."])
            let location = try await web.evaluateJavaScript("document.getElementById('nextChapter').style.left") as? String
            XCTAssertEqual(location, "5000px", "Preparation must not navigate or reveal the buffered chapter")
            _ = try await web.evaluateJavaScript("document.querySelector('iframe').style.left='5000px';document.getElementById('nextChapter').style.left='0px';CR.extract('fixture');true")
            let committed = try await web.evaluateJavaScript("window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(committed?.compactMap { $0["text"] as? String }, rows.compactMap { $0["text"] as? String }, "The real first page must confirm the predicted source")
        }
    }

    func testKoboNextChapterSpeechPreviewPassesSharedNativePreparationContract() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <div id="BookView" style="position:absolute;left:0;top:0;width:240px;height:280px;overflow:hidden"><div class="ReadingOrderView">
        <div class="ReadingItem"><iframe data-chapterurl="chapter-1.xhtml" style="position:absolute;left:0;top:0;width:240px;height:280px;border:0" srcdoc="<style>html,body{margin:0}p{font:20px/28px Georgia}</style><p>Current complete chapter.</p>"></iframe></div>
        <div class="ReadingItem"><iframe data-chapterurl="chapter-2.xhtml" style="position:absolute;left:5000px;top:0;width:240px;height:280px;border:0" srcdoc="<style>html,body{margin:0}p{font:20px/28px Georgia}</style><p>Next exact source sentence. The following sentence has its own prepared producer.</p>"></iframe></div>
        </div></div>
        """#, url: "https://readnow.kobo.com/f0000001-1111-4111-8111-000000000001", messages: inbox) { _ in
            for _ in 0..<300 where !inbox.values.contains(where: { $0["type"] as? String == "googleBooksSpeechPreview" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let current = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "rendered" }?["payload"] as? [String: Any])
            let payload = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "googleBooksSpeechPreview" }?["payload"] as? [String: Any])
            let candidate = GoogleBooksSpeechPreviewCandidate(
                sourceSignature: try XCTUnwrap(payload["sourceSignature"] as? String),
                originFrameSessionID: try XCTUnwrap(payload["originFrameSessionID"] as? String),
                contentFingerprint: try XCTUnwrap(payload["contentFingerprint"] as? String),
                sourceParagraphIndex: try XCTUnwrap(payload["sourceParagraphIndex"] as? Int),
                sourceUTF16Start: try XCTUnwrap(payload["sourceUTF16Start"] as? Int),
                sourceUTF16End: try XCTUnwrap(payload["sourceUTF16End"] as? Int),
                text: try XCTUnwrap(payload["text"] as? String))
            XCTAssertEqual(candidate.text, "Next exact source sentence.")
            let following = try XCTUnwrap(payload["following"] as? [String: Any])
            XCTAssertEqual(following["text"] as? String, "The following sentence has its own prepared producer.")
            XCTAssertEqual(following["sourceParagraphIndex"] as? Int, candidate.sourceParagraphIndex)
            XCTAssertEqual(following["sourceUTF16Start"] as? Int, candidate.sourceUTF16End + 1)
            XCTAssertTrue(GoogleBooksSpeechPreloadContract.canPrepare(candidate: candidate,
                exactText: payload["exactText"] as? Bool == true,
                currentSourceSignature: try XCTUnwrap(current["signature"] as? String),
                activeFrameSessionID: try XCTUnwrap(current["frameSessionID"] as? String)),
                "Use the actual adapter message, not an independently invented native fixture")
        }
    }

    func testGoogleUnconfirmedFutureContinuationKeepsVerifiedCurrentAndNextPage() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage">
        <reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>Current page.</p></div></reader-rendered-page></reader-page>
        <reader-page id="page-0-1" class="-gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>Verified next page.</p></div></reader-rendered-page></reader-page>
        <reader-page id="page-0-2" class="-gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p ocean-sliced-element>Unfinished later paragraph</p></div></reader-rendered-page></reader-page>
        <reader-page id="page-0-3" class="-gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>Unconfirmed later continuation.</p></div></reader-rendered-page></reader-page>
        </li></ol></reader-horizontal-view><button><mat-icon>chevron_right</mat-icon></button>
        """#, messages: inbox) { web in
            for _ in 0..<250 where !inbox.values.contains(where: { $0["type"] as? String == "googleBooksPagePreview" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let preview = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "googleBooksPagePreview" }?["payload"] as? [String: Any])
            let paragraphs = try XCTUnwrap(preview["paragraphs"] as? [[String: Any]])
            XCTAssertEqual(paragraphs.compactMap { $0["text"] as? String }, ["Verified next page."])
            let current = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertEqual(current?.compactMap { $0["text"] as? String }, ["Current page."])
        }
    }

    func testGooglePreviewRecoversOnlyAfterNativeContinuationEvidenceArrives() async throws {
        let inbox = PageMessages()
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage">
        <reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p ocean-sliced-element>Hello </p></div></reader-rendered-page></reader-page>
        <reader-page id="page-0-1" class="-gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p>world.</p></div></reader-rendered-page></reader-page>
        </li></ol></reader-horizontal-view><button><mat-icon>chevron_right</mat-icon></button>
        """#, messages: inbox) { web in
            try await Task.sleep(nanoseconds: 850_000_000)
            XCTAssertFalse(inbox.values.contains { $0["type"] as? String == "googleBooksPagePreview" })
            _ = try await web.evaluateJavaScript("document.querySelector('#page-0-1 p').setAttribute('ocean-reopened-element','')")
            for _ in 0..<250 where !inbox.values.contains(where: { $0["type"] as? String == "googleBooksPagePreview" }) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let preview = try XCTUnwrap(inbox.values.first { $0["type"] as? String == "googleBooksPagePreview" }?["payload"] as? [String: Any])
            let paragraphs = try XCTUnwrap(preview["paragraphs"] as? [[String: Any]])
            XCTAssertEqual(paragraphs.compactMap { $0["text"] as? String }, ["world."])
            XCTAssertEqual(paragraphs.first?["sourceUTF16Start"] as? Int, 6)
            let page = try await web.evaluateJavaScript("document.querySelector('reader-page.shown').id") as? String
            XCTAssertEqual(page, "page-0-0", "Preparing a successor must not navigate or alter the visible page")
        }
    }

    func testGoogleGrowingMeasurementKeepsLatestTextClosureAndNativeOffsets() async throws {
        try await withGoogleFixture("<main>Native layout updates</main>") { web in
            _ = try await web.callAsyncJavaScript(#"""
                const frame=document.createElement('iframe');document.body.append(frame);
                window.measureDoc=frame.contentDocument;
                window.growing=measureDoc.createElement('div');growing.className='gb-segment';growing.setAttribute('ocean_stream_index','0');
                growing.innerHTML='<p ocean_stream_index="1">Initially partial</p>';measureDoc.body.append(growing);
                await new Promise(r=>setTimeout(r,0));
                growing.firstChild.firstChild.data+=' source.';
                growing.firstChild.setAttribute('ocean_stream_close','3');growing.setAttribute('ocean_stream_close','4');
                const anchor=measureDoc.createElement('a');anchor.id='GBS.PT3';anchor.setAttribute('ocean_stream_index','2');growing.firstChild.append(anchor);
                await new Promise(r=>setTimeout(r,0));
                """#, arguments: [:], in: nil, contentWorld: .page)
            let captured = try await web.evaluateJavaScript("JSON.parse(document.documentElement.getAttribute('data-castreader-pb-layouts'))")
            let groups = try XCTUnwrap(captured as? [[String: Any]])
            XCTAssertEqual(groups.count, 1)
            let pages = try XCTUnwrap(groups.first?["pages"] as? [[String: Any]])
            XCTAssertEqual(pages.count, 1, "Native node identity is deduplicated, not its first incomplete text")
            XCTAssertEqual(pages.first?["closed"] as? Bool, true)
            let block = try XCTUnwrap((pages.first?["blocks"] as? [[String: Any]])?.first)
            XCTAssertEqual(block["raw"] as? String, "Initially partial source.")
            XCTAssertEqual(block["closed"] as? Bool, true)
            let marker = (block["boundaries"] as? [[String: Any]])?.first
            XCTAssertEqual(marker?["offset"] as? Int, "Initially partial source.".utf16.count)
            XCTAssertEqual(marker?["stream"] as? String, "2")
            _ = try await web.callAsyncJavaScript("growing.remove();await new Promise(r=>setTimeout(r,0));", arguments: [:], in: nil, contentWorld: .page)
            let count = try await web.evaluateJavaScript("JSON.parse(document.documentElement.getAttribute('data-castreader-pb-layouts'))[0].pages.length") as? Int
            XCTAssertEqual(count, 1)
        }
    }

    func testGoogleExtendedNextMeasurementRequiresNativeBoundaryEvidence() async throws {
        try await withGoogleFixture(#"""
        <reader-horizontal-view><ol><li class="onepage"><reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><a id="GBS.PT1"></a><p ocean_stream_index="1" ocean-sliced-element>Hello </p></div></reader-rendered-page></reader-page></li></ol></reader-horizontal-view>
        <button><mat-icon>chevron_right</mat-icon></button>
        """#) { web in
            for witnesses in [true, false] {
                _ = try await web.callAsyncJavaScript(#"""
                    window.measurement=[{id:1,className:'layout',width:350,height:560,anchors:['GBS.PT1'],pages:[
                      {blocks:[{raw:'Hello world.',stream:'1',reopened:false,closed:false,boundaries:witnesses?[{stream:'2',offset:6}]:[]}],closed:false},
                      {blocks:[{raw:'world. Next.',stream:'1',reopened:true,closed:true,boundaries:witnesses?[{stream:'2',offset:0}]:[]}],closed:true}]}];
                    document.documentElement.setAttribute('data-castreader-pb-layouts',JSON.stringify(measurement));
                    """#, arguments: ["witnesses": witnesses], in: nil, contentWorld: .page)
                let actual = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
                XCTAssertEqual(actual?.first?["speechText"] as? String, "Hello world.", "Native offsets or strongly bound live slice must cover growing source")
            }
            _ = try await web.callAsyncJavaScript(#"""
                measurement[0].pages[0].blocks[0].boundaries=[{stream:'2',offset:6}];
                measurement[0].pages[1].blocks[0].boundaries=[{stream:'2',offset:1}];
                document.documentElement.setAttribute('data-castreader-pb-layouts',JSON.stringify(measurement));
                """#, arguments: [:], in: nil, contentWorld: .page)
            let conflicting = try await web.evaluateJavaScript("CR.extract('fixture');window.__crLastRendered") as? [[String: Any]]
            XCTAssertNil(conflicting?.first?["speechText"], "A matching visible prefix must not overrule conflicting native source offsets")
        }
    }

    private func wav(sample: Int16 = 0) -> Data {
        func little<T: FixedWidthInteger>(_ value: T) -> Data {
            var copy = value.littleEndian
            return withUnsafeBytes(of: &copy) { Data($0) }
        }
        let size: UInt32 = 32_000
        var data = Data("RIFF".utf8) + little(36 + size) + Data("WAVEfmt ".utf8)
        data += little(UInt32(16)); data += little(UInt16(1)); data += little(UInt16(1))
        data += little(UInt32(8000)); data += little(UInt32(16000))
        data += little(UInt16(2)); data += little(UInt16(16))
        data += Data("data".utf8) + little(size)
        for _ in 0..<16_000 { data += little(sample) }
        return data
    }

    func testKindleFinishedSuccessorDuringPageBuildAdvancesAfterOwnerTransfer() async throws {
        try await verifyKindleTerminalAdoption(pauseBeforeAdoption: false, finishBeforeAdoption: true)
    }

    func testKindleFinishedSuccessorPreservesPauseUntilExplicitResume() async throws {
        try await verifyKindleTerminalAdoption(pauseBeforeAdoption: true, finishBeforeAdoption: true)
    }

    func testKindlePlayingSuccessorTransfersWithoutSkippingItsRemainder() async throws {
        try await verifyKindleTerminalAdoption(pauseBeforeAdoption: false, finishBeforeAdoption: false)
    }

    private func verifyKindleTerminalAdoption(pauseBeforeAdoption: Bool,
                                             finishBeforeAdoption: Bool) async throws {
        let oldPro = ProManager.shared.debugForcePro, oldSpeed = AppSettings.shared.speed
        ProManager.shared.debugForcePro = true
        AppSettings.shared.speed = 2
        defer { ProManager.shared.debugForcePro = oldPro; AppSettings.shared.speed = oldSpeed }
        useRegularVoiceForTest(language: "en")
        let texts = ["The short page opening.", "The paragraph after the opening."]
        let fixture = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: 0.8), delay: 0.15)
        }
        defer { fixture.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = AudioPlayerService(testTemporaryRoot: root)
        let oldSession = audio.claimPlaybackSession(owner: .readAloud)
        audio.setPlaybackRate(2)
        let opening = AudioSegment(paragraphIndex: 0, segmentIndex: 700002000,
            audioData: ReadAloudHTTPFixture.wav(duration: 1),
            timestamps: [TTSTimestamp(word: texts[0], startTime: 0, endTime: 1)],
            duration: 1, text: texts[0], isWavFormat: true)
        var oldCompletions = 0
        var completedTexts: [String] = []
        audio.onPlaybackComplete = { oldCompletions += 1 }
        audio.onSegmentComplete = { if let text = audio.currentSegment?.text { completedTexts.append(text) } }
        XCTAssertTrue(audio.loadSegments([opening], autoPlay: true, session: oldSession))
        for _ in 0..<300 where finishBeforeAdoption ? oldCompletions == 0 : !audio.hasAudibleProgress {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(oldCompletions, finishBeforeAdoption ? 1 : 0)
        if pauseBeforeAdoption { XCTAssertTrue(audio.pause(session: oldSession)) }
        let document = ReadingDocument(id: UUID().uuidString, title: "Delayed Kindle page owner",
            sourceKind: .kindle, language: "en",
            paragraphs: texts.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) })
        let read = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop(); try? FileManager.default.removeItem(at: root) }
        var documentCompletions = 0
        read.onDocumentFinished = { _ in documentCompletions += 1 }
        XCTAssertTrue(read.adoptContinuousPlayback([opening], paragraphIndex: 0))
        // A retired coordinator cannot publish or reset the transferred queue.
        audio.deliverTransferredQueueCompletion(session: oldSession)
        if pauseBeforeAdoption {
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(read.currentParagraphIndex, 0)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertTrue(fixture.requests.isEmpty)
            read.togglePlayPause()
        } else if !finishBeforeAdoption {
            XCTAssertEqual(read.currentParagraphIndex, 0, "An unfinished item must keep its remaining speech")
        }
        for _ in 0..<500 where documentCompletions == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(documentCompletions, 1)
        XCTAssertEqual(completedTexts, texts, "The consumed opening must never replay or skip its successor")
        XCTAssertEqual(fixture.requests, [texts[1]], "Only the unspoken next paragraph needs TTS")
        XCTAssertEqual(oldCompletions, finishBeforeAdoption ? 1 : 0)
    }

    func testShortDialogueStartupAccumulatesSeveralOrderedParagraphs() async throws {
        let oldPro = ProManager.shared.debugForcePro, oldSpeed = AppSettings.shared.speed
        ProManager.shared.debugForcePro = true
        AppSettings.shared.speed = 1.5
        defer { ProManager.shared.debugForcePro = oldPro; AppSettings.shared.speed = oldSpeed }
        useRegularVoiceForTest(language: "en")
        let texts = ["Yes.", "Really?", "Of course.", "This longer paragraph supplies the next several seconds of speech."]
        let fixture = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: text == texts.last ? 12 : 0.6), delay: 0.25)
        }
        defer { fixture.close() }
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let read = ReadAloudViewModel(document: .init(id: UUID().uuidString, title: "Cold short dialogue",
            sourceKind: .kobo, language: "en", paragraphs: []), audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop() }
        read.loadWebParagraphs(texts.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) }, language: "en")
        read.start()
        for _ in 0..<500 where !audio.hasAudibleProgress { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(audio.hasAudibleProgress)
        XCTAssertEqual(fixture.requests, texts, "First playback waits for a bounded duration, not one short body part")
        XCTAssertEqual(read.dbgKindleReadyIndices, [1, 2, 3])
        for _ in 0..<500 where read.currentParagraphIndex < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(read.currentParagraphIndex, 3)
        XCTAssertEqual(fixture.requests, texts, "Promotion uses each existing producer exactly once")
    }

    func testReadAheadDecoderSurvivesIntermediateParagraphPromotion() async throws {
        let oldPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
        defer { ProManager.shared.debugForcePro = oldPro }
        useRegularVoiceForTest(language: "en")
        let texts = ["Opening paragraph.", "Second paragraph.", "Third paragraph.", "Fourth paragraph."]
        let lengths = [4.0, 3.0, 3.5, 2.5]
        let fixture = ReadAloudHTTPFixture { text, _ in
            .response(ReadAloudHTTPFixture.body(text, duration: lengths[texts.firstIndex(of: text)!]))
        }
        defer { fixture.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = AudioPlayerService(testTemporaryRoot: root)
        let document = ReadingDocument(id: UUID().uuidString, title: "Decoder lifetime",
            sourceKind: .text, language: "en",
            paragraphs: texts.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) })
        let read = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        defer { read.stop(); read.deactivate(); audio.stop(); try? FileManager.default.removeItem(at: root) }
        // Distinct audio bytes prevent paragraph-local IDs or byte deduplication
        // from accidentally preserving a decoder for the wrong paragraph.
        func part(_ index: Int) -> AudioSegment {
            AudioSegment(paragraphIndex: index, segmentIndex: 0,
                audioData: ReadAloudHTTPFixture.wav(duration: lengths[index]), timestamps: [],
                duration: lengths[index], text: texts[index], isWavFormat: true)
        }
        read.start()
        let third = part(2), fourth = part(3)
        for _ in 0..<200 where !audio.isPreparedForPlayback(third) || !audio.isPreparedForPlayback(fourth) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let thirdPlayer = try XCTUnwrap(audio.preparedMediaForTesting(third)?.player)
        let fourthPlayer = try XCTUnwrap(audio.preparedMediaForTesting(fourth)?.player)
        XCTAssertTrue(audio.isPreparedForPlayback(third))
        XCTAssertEqual(read.currentParagraphIndex, 0)
        for _ in 0..<500 where read.currentParagraphIndex < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(read.currentParagraphIndex, 1)
        XCTAssertTrue(audio.preparedMediaForTesting(third)?.player === thirdPlayer,
            "Starting paragraph two must retain the already decoded paragraph three")
        XCTAssertTrue(audio.isPreparedForPlayback(third))
        for _ in 0..<500 where read.currentParagraphIndex < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(read.currentParagraphIndex, 2)
        XCTAssertTrue(audio.activePlayerForTesting === thirdPlayer,
            "Promote the same ready decoder, rather than creating one at the audible boundary")
        read.stop()
        for _ in 0..<100 where fourthPlayer.currentItem != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(fourthPlayer.currentItem, "Stopping releases untaken speculative media")
    }

    func testMeasurePreparedPresentationResumeAgainstNativeBufferPolicy() async throws {
        // Diagnostic experiment, not an acoustic or latency acceptance test.
        // Only the buffer policy differs; the production hold/release path,
        // actual AVPlayer decoder, rate and media clock remain in use.
        for waits in [true, false] {
            for sample in 0..<3 {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let audio = AudioPlayerService(testTemporaryRoot: root)
                defer { audio.stop(); try? FileManager.default.removeItem(at: root) }
                let session = audio.claimPlaybackSession(owner: .readAloud)
                audio.setPlaybackRate(1.5)
                let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
                    audioData: wav(), timestamps: [], duration: 2, text: "Clock experiment", isWavFormat: true)
                audio.prestageSegments([part])
                for _ in 0..<250 where !audio.isPreparedForPlayback(part) { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(audio.isPreparedForPlayback(part))
                XCTAssertTrue(audio.loadSegments([part], autoPlay: false, session: session))
                XCTAssertTrue(audio.startQueuedSegment(id: part.id, progress: 0, autoPlay: false, session: session))
                let player = try XCTUnwrap(audio.activePlayerForTesting)
                player.automaticallyWaitsToMinimizeStalling = waits
                var hold: UUID?
                XCTAssertTrue(audio.armPagePresentationBoundary(segmentID: part.id, time: 0.3, session: session) { hold = $0 })
                XCTAssertTrue(audio.play(session: session))
                for _ in 0..<500 where hold == nil { try await Task.sleep(for: .milliseconds(5)) }
                let id = try XCTUnwrap(hold)
                try await Task.sleep(for: .milliseconds(150))
                let position = audio.playbackPosition
                XCTAssertEqual(position, 0.3, accuracy: 0.002)
                let ready = player.currentItem?.isPlaybackBufferEmpty == false
                let began = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(audio.finishPagePresentation(id))
                var waitingReason = "none"
                for _ in 0..<500 where audio.playbackPosition < position + 0.005 {
                    if let reason = player.reasonForWaitingToPlay { waitingReason = reason.rawValue }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
                print("PAGINATION_NATIVE_RESUME waits=\(waits) sample=\(sample) bufferReady=\(ready) firstAdvanceMs=\(elapsed) position=\(audio.playbackPosition) reason=\(waitingReason)")
                XCTAssertGreaterThan(audio.playbackPosition, position + 0.004)
                XCTAssertEqual(player.rate, 1.5)
            }
        }
    }

    func testDecodedLeaseTransfersSamePlayerAndOldCleanupCannotReleaseIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = AudioPlayerService(testTemporaryRoot: root)
        defer { audio.stop(); try? FileManager.default.removeItem(at: root) }
        let token = audio.claimPlaybackSession(owner: .readAloud)
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(),
            timestamps: [], duration: 2, text: "Prepared fixture", isWavFormat: true)
        audio.prestageSegments([part])
        for _ in 0..<250 where audio.preparedMediaForTesting(part)?.decoded != true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let lease = try XCTUnwrap(audio.preparedMediaForTesting(part))
        XCTAssertTrue(lease.decoded, "Real AVPlayer preroll must finish on the device")
        XCTAssertEqual(lease.player.rate, 0)
        XCTAssertLessThan(lease.player.currentTime().seconds, 0.001)
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false, session: token))
        XCTAssertTrue(audio.startQueuedSegment(id: part.id, progress: 0, autoPlay: false, session: token))
        XCTAssertTrue(audio.activePlayerForTesting === lease.player)
        audio.discardPrestagedSegments()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(lease.player.currentItem)
        XCTAssertEqual(lease.player.rate, 0, "Ready must preserve explicit pause")
        XCTAssertNil(audio.preparedMediaForTesting(part), "Ownership transferred exactly once")
    }

    func testPreparedExplanationLeaseSurvivesPredecessorStopAndCannotStopTakenPlayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = AudioPlayerService(testTemporaryRoot: root)
        defer { audio.stop(); try? FileManager.default.removeItem(at: root) }
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(),
            timestamps: [], duration: 2, text: "Successor explanation", isWavFormat: true)
        var lease: AudioPlayerService.PreparedMediaLease? = audio.retainPreparedSegments([part])
        XCTAssertNotNil(lease)
        for _ in 0..<250 where !audio.isPreparedForPlayback(part) { try await Task.sleep(nanoseconds: 20_000_000) }
        let prepared = try XCTUnwrap(audio.preparedMediaForTesting(part))
        XCTAssertTrue(prepared.decoded)
        audio.stop()
        audio.clearQueue()
        XCTAssertTrue(audio.preparedMediaForTesting(part)?.player === prepared.player)
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false))
        XCTAssertTrue(audio.startQueuedSegment(id: part.id, progress: 0, autoPlay: false))
        XCTAssertTrue(audio.activePlayerForTesting === prepared.player)
        lease = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(prepared.player.currentItem, "Old payload cleanup must not release taken media")
        XCTAssertEqual(prepared.player.rate, 0, "Prepared media must respect explicit non-autoplay")
    }

    func testCancelledPreparedExplanationReleasesUntakenMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = AudioPlayerService(testTemporaryRoot: root)
        defer { audio.stop(); try? FileManager.default.removeItem(at: root) }
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(),
            timestamps: [], duration: 2, text: "Cancelled explanation", isWavFormat: true)
        var lease: AudioPlayerService.PreparedMediaLease? = audio.retainPreparedSegments([part])
        XCTAssertNotNil(lease)
        let player = try XCTUnwrap(audio.preparedMediaForTesting(part)?.player)
        lease = nil
        for _ in 0..<100 where audio.preparedMediaForTesting(part) != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(audio.preparedMediaForTesting(part))
        XCTAssertNil(player.currentItem)
    }

    func testTakenLeaseCannotReleaseNewPreparationWithIdenticalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = AudioPlayerService(testTemporaryRoot: root)
        defer { audio.stop(); try? FileManager.default.removeItem(at: root) }
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(),
            timestamps: [], duration: 2, text: "Repeated explanation", isWavFormat: true)
        var oldLease: AudioPlayerService.PreparedMediaLease? = audio.retainPreparedSegments([part])
        XCTAssertNotNil(oldLease)
        XCTAssertTrue(audio.loadSegments([part], autoPlay: false))
        XCTAssertTrue(audio.startQueuedSegment(id: part.id, progress: 0, autoPlay: false))
        let takenPlayer = try XCTUnwrap(audio.activePlayerForTesting)
        let nextLease = audio.retainPreparedSegments([part])
        let nextPlayer = try XCTUnwrap(audio.preparedMediaForTesting(part)?.player)
        XCTAssertFalse(takenPlayer === nextPlayer)
        oldLease = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(audio.preparedMediaForTesting(part)?.player === nextPlayer)
        XCTAssertNotNil(takenPlayer.currentItem)
        withExtendedLifetime(nextLease) {}
    }

    func testAccountBoundaryRevokesPinnedPreparedMedia() throws {
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let part = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(),
            timestamps: [], duration: 2, text: "Private explanation", isWavFormat: true)
        let lease = audio.retainPreparedSegments([part])
        let player = try XCTUnwrap(audio.preparedMediaForTesting(part)?.player)
        audio.clearForAccountBoundary()
        XCTAssertNil(audio.preparedMediaForTesting(part))
        XCTAssertNil(player.currentItem)
        withExtendedLifetime(lease) {}
    }

    func testSameSegmentIDWithDifferentVoiceBytesCannotReuseLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = AudioPlayerService(testTemporaryRoot: root)
        defer { audio.stop(); try? FileManager.default.removeItem(at: root) }
        func part(_ sample: Int16) -> AudioSegment {
            AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(sample: sample),
                timestamps: [], duration: 2, text: "Same id", isWavFormat: true)
        }
        let a = part(0), b = part(1)
        audio.prestageSegments([a, b])
        let playerA = try XCTUnwrap(audio.preparedMediaForTesting(a)?.player)
        let playerB = try XCTUnwrap(audio.preparedMediaForTesting(b)?.player)
        XCTAssertFalse(playerA === playerB)
        audio.discardPrestagedSegments()
        XCTAssertNil(playerA.currentItem); XCTAssertNil(playerB.currentItem)
    }
}
