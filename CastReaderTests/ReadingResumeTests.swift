import XCTest
import Combine
@testable import CastReader

private struct ResumeTestSpeech: ParagraphSpeechGenerating {
    let segments: [AudioSegment]
    var initialDelayNanoseconds: UInt64 = 0
    func generateTTSForParagraph(
        paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        if initialDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: initialDelayNanoseconds)
        }
        for segment in segments {
            try Task.checkCancellation()
            await onSegmentReady(segment)
            try await Task.sleep(nanoseconds: 80_000_000)
        }
    }
}

@MainActor
final class ReadingResumeTests: XCTestCase {
    private var directory: URL!
    private var wasPro = false

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        wasPro = ProManager.shared.debugForcePro
        ProManager.shared.debugForcePro = true
    }
    override func tearDown() async throws {
        ProManager.shared.debugForcePro = wasPro
        try? FileManager.default.removeItem(at: directory)
    }

    private func paragraphs(_ texts: [String]) -> [ReadingParagraph] {
        texts.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) }
    }
    private func document(_ source: ReadingSourceKind = .text, id: String = "resume-doc") -> ReadingDocument {
        ReadingDocument(id: id, title: "Resume test", sourceKind: source, language: "en",
                        paragraphs: paragraphs(["First paragraph.", "Alpha beta gamma delta."]))
    }
    private func segment(_ index: Int, text: String, paragraph: Int = 1,
                         duration: Double = 8, changedAudio: Bool = false) -> AudioSegment {
        let words = text.split(separator: " ")
        return AudioSegment(paragraphIndex: paragraph, segmentIndex: index,
                            audioData: wav(duration: duration, sample: changedAudio ? 7 : 0),
                            timestamps: words.enumerated().map {
                                TTSTimestamp(word: String($0.element), startTime: Double($0.offset) * 3,
                                             endTime: Double($0.offset) * 3 + 2)
                            }, duration: duration, text: text, isWavFormat: true)
    }
    private func wav(duration: Double, sample: Int16) -> Data {
        let count = Int(duration * 8000)
        var result = Data()
        func ascii(_ value: String) { result.append(Data(value.utf8)) }
        func u32(_ value: UInt32) { var x = value.littleEndian; withUnsafeBytes(of: &x) { result.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var x = value.littleEndian; withUnsafeBytes(of: &x) { result.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + count * 2)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16); ascii("data"); u32(UInt32(count * 2))
        for _ in 0..<count { u16(UInt16(bitPattern: sample)) }
        return result
    }
    private func save(_ store: HistoryStore, doc: ReadingDocument,
                      audio: ReadingResumeAudioCursor? = nil, index: Int = 1) throws {
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: doc.sourceKind, paragraphIndex: index, audio: audio))
        XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: store.progressBoundaryToken))
    }
    private func waitUntil(_ message: String, timeout: Double = 6, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertTrue(condition(), message)
    }

    func testFreshStoreAndVMLocateEverySharedReaderSourceBeforePlayback() throws {
        let sources: [ReadingSourceKind] = [.text, .epub, .pdf, .photo, .docx, .web,
                                           .kindle, .weread, .googleBooks, .kobo, .oreilly]
        for source in sources {
            let store = HistoryStore(directory: directory)
            let doc = document(source, id: source.rawValue)
            store.record(doc)
            try save(store, doc: doc)
            let fresh = HistoryStore(directory: directory)
            var incoming = doc
            if source.isWebRendered { incoming.paragraphs = [] }
            let vm = ReadAloudViewModel(document: incoming, historyStore: fresh)
            if source.isWebRendered { vm.loadWebParagraphs(doc.paragraphs, language: "en") }
            XCTAssertEqual(vm.currentParagraphIndex, 1, source.rawValue)
            XCTAssertFalse(vm.isPlaying, "Opening only must not auto-play: \(source.rawValue)")
            XCTAssertNil(vm.resumeNotice, source.rawValue)
            vm.stop()
        }
    }

    private func reflowFixture() throws -> (ReadingDocument, ReadingResumeCheckpoint, String) {
        let prefix = "The preceding sentences describe a long expedition through the mountains. "
        let target = "remembered"
        let suffix = " the precise location while the distant travelers continued their remarkable journey together."
        let text = prefix + target + suffix
        let doc = ReadingDocument(id: "kindle-reflow", title: "Reflow", sourceKind: .kindle,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: text)])
        let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(duration: 10, sample: 1),
            timestamps: [TTSTimestamp(word: target, startTime: 4, endTime: 6)], duration: 10,
            text: text, isWavFormat: true)
        let audio = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [segment], currentSegmentID: segment.id, time: 4.5))
        var checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .kindle, paragraphIndex: 0, audio: audio))
        checkpoint.visual = ReadingResumeContract.captureVisual(output: text, offset: prefix.utf16.count,
            length: target.utf16.count, source: text)
        checkpoint.reflow = try XCTUnwrap(ReadingResumeContract.captureReflow(source: text,
            visual: checkpoint.visual, audio: audio))
        return (doc, checkpoint, target + suffix)
    }

    func testKindleReflowMovesWordAcrossParagraphsAndRebuildsAudioCoordinates() throws {
        let (_, checkpoint, suffix) = try reflowFixture()
        let changed = [ReadingParagraph(id: 0, text: "A newly paginated preceding paragraph."),
                       ReadingParagraph(id: 1, text: suffix)]
        let restored = try XCTUnwrap(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint, paragraphs: changed))
        XCTAssertEqual(restored.paragraphIndex, 1)
        XCTAssertEqual(restored.visual?.utf16Offset, 0)
        let audio = AudioSegment(paragraphIndex: 1, segmentIndex: 0, audioData: wav(duration: 10, sample: 5),
            timestamps: [TTSTimestamp(word: "remembered", startTime: 0, endTime: 1.2)],
            duration: 10, text: suffix, isWavFormat: true)
        XCTAssertEqual(ReadingResumeContract.resolveAudio(try XCTUnwrap(restored.audio), segments: [audio], isComplete: true),
            .seek(segmentIndex: 0, seconds: 0.3))
        XCTAssertEqual(restored.updatedAt, checkpoint.updatedAt)
    }

    func testKindleReflowAcceptsOnlyVerifiedContextAtNewPageEdges() throws {
        let (doc, checkpoint, suffix) = try reflowFixture()
        // Both context sides survive in the full paragraph. At the new bottom
        // edge only the complete prefix is available; at the top only suffix.
        let end = (doc.paragraphs[0].text as NSString).range(of: "remembered").upperBound
        let bottom = String((doc.paragraphs[0].text as NSString).substring(to: end))
        XCTAssertNotNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint,
            paragraphs: [ReadingParagraph(id: 0, text: bottom)]))
        XCTAssertNotNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint,
            paragraphs: [ReadingParagraph(id: 0, text: suffix)]))
        XCTAssertNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint,
            paragraphs: [ReadingParagraph(id: 0, text: "remembered the precise location")]))
    }

    func testKindleReflowRejectsChangedOrAmbiguousAnchors() throws {
        let (doc, checkpoint, _) = try reflowFixture()
        XCTAssertNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint, paragraphs: [
            ReadingParagraph(id: 0, text: doc.paragraphs[0].text.replacingOccurrences(of: "precise", with: "incorrect"))]))
        XCTAssertNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint, paragraphs: [
            doc.paragraphs[0], ReadingParagraph(id: 1, text: doc.paragraphs[0].text)]))
        XCTAssertNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint, paragraphs: [
            ReadingParagraph(id: 0, text: doc.paragraphs[0].text.replacingOccurrences(of: "remembered", with: "forgotten"))]))
    }

    func testKindleReflowContextSurvivesSerializationWithoutBookText() throws {
        let (_, checkpoint, _) = try reflowFixture()
        let data = try JSONEncoder().encode(checkpoint)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("remembered"))
        XCTAssertEqual(try JSONDecoder().decode(ReadingResumeCheckpoint.self, from: data), checkpoint)
    }

    func testKindleReflowToleratesOneOCRLetterOnlyInSurroundingContext() throws {
        let (_, checkpoint, suffix) = try reflowFixture()
        for damaged in [suffix.replacingOccurrences(of: "precise", with: "recise"),
                        suffix.replacingOccurrences(of: "precise", with: "precisse"),
                        suffix.replacingOccurrences(of: "precise", with: "preclse")] {
            XCTAssertNotNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint,
                paragraphs: [ReadingParagraph(id: 0, text: damaged)]))
        }
        XCTAssertNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint,
            paragraphs: [ReadingParagraph(id: 0, text: suffix.replacingOccurrences(of: "precise", with: "recse"))]))
        XCTAssertNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint,
            paragraphs: [ReadingParagraph(id: 0, text: suffix.replacingOccurrences(of: "remembered", with: "remebered"))]))
    }

    func testKindleShortDialogueUsesAdjacentParagraphContextAfterReflow() throws {
        let before = "The traveler carefully explained the complete plan before asking for an answer."
        let after = "They immediately prepared their instruments and continued through the underground passage."
        let source = "Yes."
        let segment = AudioSegment(paragraphIndex: 1, segmentIndex: 0, audioData: wav(duration: 10, sample: 1),
            timestamps: [TTSTimestamp(word: "Yes", startTime: 0, endTime: 1)], duration: 10,
            text: source, isWavFormat: true)
        let audio = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [segment], currentSegmentID: segment.id, time: 0.4))
        let visual = ReadingResumeContract.captureVisual(output: source, offset: 0, length: 3, source: source)
        let context = try XCTUnwrap(ReadingResumeContract.captureReflow(source: source, visual: visual,
            audio: audio, precedingSource: before, followingSource: after))
        let original = paragraphs([before, source, after])
        var checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: original)
            .checkpoint(sourceKind: .kindle, paragraphIndex: 1, audio: audio))
        checkpoint.visual = visual; checkpoint.reflow = context
        let changed = paragraphs([before + "\n" + source, after])
        let restored = try XCTUnwrap(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint, paragraphs: changed))
        XCTAssertEqual(restored.paragraphIndex, 0)
        XCTAssertEqual(restored.visual?.utf16Offset, before.utf16.count + 1)
        XCTAssertNil(ReadingResumeContract.relocatedKindleCheckpoint(checkpoint, paragraphs: paragraphs([before, "No.", after])))
    }

    func testKindleReflowRestoresFreshVMWithoutOverwritingOldCheckpointBeforeAudio() async throws {
        let (doc, checkpoint, suffix) = try reflowFixture()
        let store = HistoryStore(directory: directory)
        store.record(doc)
        XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: store.progressBoundaryToken))
        let committedBeforeOpen = store.readingCheckpoint(for: doc.id)
        var changed = doc
        changed.paragraphs = [ReadingParagraph(id: 0, text: suffix)]
        let audio = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: wav(duration: 10, sample: 1),
            timestamps: [TTSTimestamp(word: "remembered", startTime: 0, endTime: 1.2)],
            duration: 10, text: suffix, isWavFormat: true)
        let vm = ReadAloudViewModel(document: changed, historyStore: store,
            speechGenerator: ResumeTestSpeech(segments: [audio]))
        defer { vm.stop() }
        XCTAssertNil(vm.resumeNotice)
        XCTAssertEqual(vm.currentParagraphIndex, 0)
        vm.flushReadingProgress()
        XCTAssertEqual(store.readingCheckpoint(for: doc.id), committedBeforeOpen)
        vm.ensurePlaying()
        try await waitUntil("Relocated word must become audible") { vm.isPlaying && AudioPlayerService.shared.hasAudibleProgress }
        vm.pausePlayback()
        XCTAssertEqual(AudioPlayerService.shared.playbackPosition, 0.3, accuracy: 0.35)
        XCTAssertNotEqual(store.readingCheckpoint(for: doc.id)?.paragraphFingerprint, checkpoint.paragraphFingerprint)
    }

    func testParagraphInsertionResolvesByContentAndAmbiguousDuplicatesDoNotGuess() throws {
        let before = ReadingResumeDocumentIndex(paragraphs: paragraphs(["One", "Target", "Three"]))
        let checkpoint = try XCTUnwrap(before.checkpoint(sourceKind: .text, paragraphIndex: 1, audio: nil))
        XCTAssertEqual(ReadingResumeDocumentIndex(paragraphs: paragraphs(["Inserted", "One", "Target", "Three"]))
            .resolve(checkpoint), 2)
        XCTAssertNil(ReadingResumeDocumentIndex(paragraphs: paragraphs(["One", "Target", "Three", "One", "Target", "Three"]))
            .resolve(checkpoint))
    }

    func testExactAudioAndRegeneratedSplitBothRecoverSavedWord() throws {
        let old = [segment(0, text: "Alpha beta "), segment(1, text: "gamma delta")]
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: old, currentSegmentID: "1-1", time: 4))
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: old, isComplete: true), .seek(segmentIndex: 1, seconds: 4))
        let new = [segment(0, text: "Alpha beta gamma ", changedAudio: true), segment(1, text: "delta", changedAudio: true)]
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [new[0]], isComplete: false), .waiting)
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: new, isComplete: true), .seek(segmentIndex: 1, seconds: 1))
        let changed = [segment(0, text: "Different wording", changedAudio: true)]
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: changed, isComplete: true), .unavailable)
    }

    func testWeReadColdPageRestoresTheVerifiedSuffixAfterContinuousHandoff() throws {
        let prior = paragraphs(["这里是已经开始的新句子，必须从保存的句内时间继续。", "后续段落用于确认正文。"])
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: prior).checkpoint(sourceKind: .weread, paragraphIndex: 0, audio: nil))
        let fresh = paragraphs(["上一页已经朗读完的跨页句子。" + prior[0].text, prior[1].text])
        let restored = try XCTUnwrap(ReadingResumeContract.restoreWeReadPage(fresh, checkpoint: checkpoint))
        XCTAssertEqual(restored.map(\.text), prior.map(\.text))
        XCTAssertEqual(ReadingResumeDocumentIndex(paragraphs: restored).resolve(checkpoint), 0)
        let changed = paragraphs(["上一页已经朗读完的跨页句子。这里是修改后的新句子。", prior[1].text])
        XCTAssertNil(ReadingResumeContract.restoreWeReadPage(changed, checkpoint: checkpoint))
    }

    func testWeReadColdConsumedPrefixPreservesNextPageBoundaryCoordinates() {
        let prefix = "上一页🙂。".utf16.count
        let original = WeReadPageSpeechBoundary(paragraphIndex: 0,
            visibleUTF16Offset: prefix + 12, speechUTF16Length: prefix + 24,
            sourceLayoutFingerprint: "layout", sourceParagraphIndex: 42, sourceSpeechEnd: 1200)
        let restored = original.removingPrefix(prefix, from: 0)
        XCTAssertEqual(restored.visibleUTF16Offset, 12)
        XCTAssertEqual(restored.speechUTF16Length, 24)
        XCTAssertTrue(restored.isCrossPage)
        XCTAssertEqual(restored.sourceSpeechEnd, 1200)
        XCTAssertEqual(restored.sourceParagraphIndex, 42)
        XCTAssertEqual(original.removingPrefix(prefix, from: 1), original)
        XCTAssertFalse(original.removingPrefix(1000, from: 0).isCrossPage)
    }

    func testSegmentTimedChineseResumesWithinVerifiedSentenceAfterRegeneration() throws {
        let old = AudioSegment(paragraphIndex: 1, segmentIndex: 0, audioData: Data([1]),
                               timestamps: [], duration: 8, text: "这是上次停下的同一句话。")
        let fresh = AudioSegment(paragraphIndex: 1, segmentIndex: 0, audioData: Data([2]),
                                 timestamps: [], duration: 10, text: old.text)
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [old], currentSegmentID: old.id, time: 4))
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [fresh], isComplete: true),
                       .seek(segmentIndex: 0, seconds: 5))
        var legacy = cursor
        legacy.segmentDuration = nil
        XCTAssertEqual(ReadingResumeContract.resolveAudio(legacy, segments: [fresh], isComplete: true),
                       .seek(segmentIndex: 0, seconds: 4))
        let changed = AudioSegment(paragraphIndex: 1, segmentIndex: 0, audioData: Data([2]),
                                   timestamps: [], duration: 10, text: "已经换成了别的句子。")
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [changed], isComplete: true), .unavailable)
    }

    func testSegmentTimedResumeRejectsDifferentPrecedingSentence() throws {
        let first = AudioSegment(paragraphIndex: 1, segmentIndex: 0, audioData: Data([1]),
                                 timestamps: [], duration: 3, text: "第一句。")
        let second = AudioSegment(paragraphIndex: 1, segmentIndex: 1, audioData: Data([2]),
                                  timestamps: [], duration: 8, text: "重复的第二句。")
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [first, second], currentSegmentID: second.id, time: 4))
        let wrongFirst = AudioSegment(paragraphIndex: 1, segmentIndex: 0, audioData: Data([3]),
                                      timestamps: [], duration: 3, text: "别的一句。")
        let freshSecond = AudioSegment(paragraphIndex: 1, segmentIndex: 1, audioData: Data([4]),
                                       timestamps: [], duration: 8, text: second.text)
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [wrongFirst, freshSecond], isComplete: true), .unavailable)
    }

    func testIdenticalAudioWithoutTimestampsStillResumesAtExactSecond() throws {
        let s = AudioSegment(paragraphIndex: 1, segmentIndex: 0, audioData: wav(duration: 8, sample: 0),
                             timestamps: [], duration: 8, text: "Untimed text", isWavFormat: true)
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [s], currentSegmentID: s.id, time: 5.7))
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [s], isComplete: true), .seek(segmentIndex: 0, seconds: 5.7))
    }

    func testColdStartRegeneratesAndSeeksBeforeFirstAudibleSegment() async throws {
        let doc = document()
        let store = HistoryStore(directory: directory)
        store.record(doc)
        let segments = [segment(0, text: "Alpha beta "), segment(1, text: "gamma delta")]
        let first = ReadAloudViewModel(document: doc, historyStore: store,
                                      speechGenerator: ResumeTestSpeech(segments: segments))
        first.startWithCachedSegments(segments, paragraphIndex: 1, segmentID: "1-1", progress: 0.5, isReplayEligible: false)
        defer { first.stop() }
        try await waitUntil("Initial audio must start at the later segment") { first.isPlaying && !AudioPlayerService.shared.isBuffering && AudioPlayerService.shared.hasAudibleProgress && AudioPlayerService.shared.currentSegment?.id == "1-1" }
        first.togglePlayPause()
        let stopped = try XCTUnwrap(store.readingCheckpoint(for: doc.id)?.audio)
        XCTAssertGreaterThanOrEqual(stopped.segmentTime, 4)
        first.stop()
        let fresh = HistoryStore(directory: directory)
        let resumed = ReadAloudViewModel(document: doc, historyStore: fresh,
                                        speechGenerator: ResumeTestSpeech(segments: segments))
        defer { resumed.stop() }
        XCTAssertEqual(resumed.currentParagraphIndex, 1)
        var audibleIDs: [String] = []
        let subscription = AudioPlayerService.shared.$isPlaying.sink { playing in
            if playing, let id = AudioPlayerService.shared.currentSegment?.id { audibleIDs.append(id) }
        }
        defer { subscription.cancel() }
        resumed.ensurePlaying()
        try await waitUntil("Cold resume must become audible") { resumed.isPlaying && !AudioPlayerService.shared.isBuffering && AudioPlayerService.shared.hasAudibleProgress }
        XCTAssertFalse(audibleIDs.isEmpty)
        XCTAssertTrue(audibleIDs.allSatisfy { $0 == "1-1" }, "Earlier audio must never briefly play")
        XCTAssertEqual(AudioPlayerService.shared.playbackPosition, stopped.segmentTime, accuracy: 0.35)
        resumed.togglePlayPause()
        let after = try XCTUnwrap(fresh.readingCheckpoint(for: doc.id)?.audio)
        XCTAssertGreaterThanOrEqual(after.segmentTime, stopped.segmentTime - 0.1)
    }

    func testPauseWhileWaitingKeepsLateAudioPausedUntilExplicitResume() async throws {
        let doc = document()
        let store = HistoryStore(directory: directory)
        store.record(doc)
        let speech = ResumeTestSpeech(
            segments: [segment(0, text: "First paragraph.", paragraph: 0)],
            initialDelayNanoseconds: 400_000_000
        )
        let vm = ReadAloudViewModel(document: doc, historyStore: store, speechGenerator: speech)
        defer { vm.stop() }
        vm.ensurePlaying()
        try await waitUntil("Generation should begin before audio is available") { vm.status.isLoading }
        vm.pausePlayback()
        XCTAssertTrue(vm.isPlaybackPausedByUser)
        XCTAssertFalse(vm.isWaitingForPlayableAudio)
        try await waitUntil("Late audio should remain available for resumption") {
            (AudioPlayerService.shared.currentSegment != nil || AudioPlayerService.shared.hasQueuedSegments)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertTrue(AudioPlayerService.shared.isExplicitlyPaused)
        vm.ensurePlaying()
        try await waitUntil("An explicit continue should release the paused audio") {
            vm.isPlaying && AudioPlayerService.shared.hasAudibleProgress
        }
        XCTAssertFalse(vm.isPlaybackPausedByUser)
    }

    func testLateAutomaticPageCommitCannotOverrideUserPause() throws {
        let doc = document(.kobo)
        let vm = ReadAloudViewModel(document: doc, historyStore: HistoryStore(directory: directory))
        defer { vm.stop() }
        vm.pausePlayback()
        vm.replaceLiveWebPage(paragraphs(["A later page arrived after pause."]), language: "en", autoplay: true)
        XCTAssertTrue(vm.isPlaybackPausedByUser)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertFalse(vm.isWaitingForPlayableAudio)
        XCTAssertFalse(vm.shouldResumeAfterManualLivePageTurn)
        XCTAssertEqual(vm.currentParagraphIndex, -1)
    }

    func testModeSwitchAndRepeatedContinueKeepSegmentAndTime() async throws {
        let doc = document()
        let store = HistoryStore(directory: directory)
        store.record(doc)
        let segments = [segment(0, text: "Alpha beta "), segment(1, text: "gamma delta")]
        let vm = ReadAloudViewModel(document: doc, historyStore: store,
                                   speechGenerator: ResumeTestSpeech(segments: segments))
        defer { vm.stop() }
        vm.startWithCachedSegments(segments, paragraphIndex: 1, segmentID: "1-1", progress: 0.5, isReplayEligible: false)
        try await waitUntil("Playing before mode switch") { vm.isPlaying && !AudioPlayerService.shared.isBuffering && AudioPlayerService.shared.hasAudibleProgress }
        vm.deactivate()
        let saved = try XCTUnwrap(store.readingCheckpoint(for: doc.id)?.audio)
        let visual = try XCTUnwrap(vm.initialResumeViewportRange,
            "Returning from Explain must reveal the stopped word before audio starts")
        XCTAssertEqual((doc.paragraphs[1].text as NSString).substring(with: visual), "delta")
        vm.activate()
        vm.ensurePlaying()
        try await waitUntil("Playing after mode switch") { vm.isPlaying && !AudioPlayerService.shared.isBuffering && AudioPlayerService.shared.hasAudibleProgress }
        vm.start()
        vm.ensurePlaying()
        XCTAssertEqual(AudioPlayerService.shared.currentSegment?.id, "1-1")
        XCTAssertEqual(AudioPlayerService.shared.playbackPosition, saved.segmentTime, accuracy: 0.4)
    }

    func testOpenWithoutPlayingDoesNotOverwriteCursorAndLegacyStillLocates() throws {
        let doc = document()
        let store = HistoryStore(directory: directory)
        store.record(doc)
        store.updateReadingPosition(documentID: doc.id, paragraphIndex: 1)
        XCTAssertEqual(ReadAloudViewModel(document: doc, historyStore: store).currentParagraphIndex, 1)
        let segments = [segment(0, text: "Alpha beta")]
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: segments, currentSegmentID: "1-0", time: 4))
        try save(store, doc: doc, audio: cursor)
        let vm = ReadAloudViewModel(document: doc, historyStore: store)
        vm.flushReadingProgress()
        vm.stop()
        XCTAssertEqual(store.readingCheckpoint(for: doc.id)?.audio, cursor)
    }

    func testChangedSourceShowsNoticeWithoutFallingBackToBeginning() throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        try save(store, doc: doc)
        var changed = doc
        changed.paragraphs = paragraphs(["Completely different content"])
        let coordinator = PlayerCoordinator(historyStore: store)
        coordinator.open(changed)
        defer { coordinator.close() }
        XCTAssertEqual(coordinator.session?.readVM.currentParagraphIndex, -1)
        XCTAssertNotNil(coordinator.session?.readVM.resumeNotice)
        coordinator.session?.readVM.ensurePlaying()
        XCTAssertFalse(coordinator.session?.readVM.isPlaying ?? true)
    }

    func testReimportedContentReusesIdentityButDifferentContentDoesNot() {
        let store = HistoryStore(directory: directory)
        let original = document()
        store.record(original)
        let duplicate = document(id: "new-import-uuid")
        XCTAssertEqual(store.canonicalDocument(duplicate).id, original.id)
        var different = duplicate
        different.paragraphs = paragraphs(["Different content"])
        XCTAssertEqual(store.canonicalDocument(different).id, duplicate.id)
    }

    func testHundredChapterEPUBReimportAndHistoryReparseKeepTheLastParagraph() async throws {
        let store = HistoryStore(directory: directory)
        let bytes = try ReadingResumeFixtureSpeech.epub()
        let doc = try XCTUnwrap(DocumentBuilder.fromEPUB(data: bytes, title: "100 chapters"))
        XCTAssertEqual(doc.paragraphs.count, 200)
        store.record(doc)
        try save(store, doc: doc, index: 199)
        let fresh = HistoryStore(directory: directory)
        let record = try XCTUnwrap(fresh.records.first)
        let reopenedValue = try await fresh.reopen(record)
        let reopened = try XCTUnwrap(reopenedValue)
        XCTAssertEqual(reopened.id, doc.id)
        XCTAssertEqual(ReadAloudViewModel(document: reopened, historyStore: fresh).currentParagraphIndex, 199)
        let reimport = try XCTUnwrap(DocumentBuilder.fromEPUB(data: bytes, title: "Renamed.epub"))
        let coordinator = PlayerCoordinator(historyStore: fresh)
        coordinator.open(reimport)
        defer { coordinator.close() }
        XCTAssertEqual(coordinator.session?.document.id, doc.id)
        XCTAssertEqual(coordinator.session?.readVM.currentParagraphIndex, 199)
    }

    func testLegacyImportFingerprintMigrationPreservesItsSavedPosition() throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        store.updateReadingPosition(documentID: doc.id, paragraphIndex: 1)
        let url = directory.appendingPathComponent("index.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        json[0].removeValue(forKey: "contentFingerprint")
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
        let old = HistoryStore(directory: directory)
        let imported = old.canonicalDocument(document(id: "new-uuid"))
        XCTAssertEqual(imported.id, doc.id)
        XCTAssertEqual(ReadAloudViewModel(document: imported, historyStore: old).currentParagraphIndex, 1)
    }

    func testDamagedCheckpointIsVisibleAndDeletionRemovesIt() throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        try save(store, doc: doc)
        let url = directory.appendingPathComponent(ReadingResumeContract.fingerprint(doc.id) + ".read.resume.json")
        try Data("broken".utf8).write(to: url)
        let vm = ReadAloudViewModel(document: doc, historyStore: store)
        XCTAssertNotNil(vm.resumeNotice)
        XCTAssertEqual(vm.currentParagraphIndex, -1)
        vm.ensurePlaying()
        XCTAssertFalse(vm.isPlaying)
        store.delete(doc.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.record(doc)
        XCTAssertNil(ReadAloudViewModel(document: doc, historyStore: store).resumeNotice)
    }

    func testLiveReaderWaitsForMatchingSavedPageInsteadOfStartingAnEarlierPage() throws {
        let store = HistoryStore(directory: directory)
        let doc = document(.kobo)
        store.record(doc)
        try save(store, doc: doc)
        var incoming = doc
        incoming.paragraphs = []
        let vm = ReadAloudViewModel(document: incoming, historyStore: store)
        vm.loadWebParagraphs(paragraphs(["Earlier provider page"]), language: "en")
        XCTAssertNotNil(vm.resumeNotice)
        vm.ensurePlaying()
        XCTAssertFalse(vm.isPlaying)
        vm.loadWebParagraphs(doc.paragraphs, language: "en")
        XCTAssertNil(vm.resumeNotice)
        XCTAssertEqual(vm.currentParagraphIndex, 1)
    }

    func testExplicitBackwardJumpReplacesProgressRatherThanKeepingMaximum() async throws {
        let doc = document()
        let store = HistoryStore(directory: directory)
        store.record(doc)
        try save(store, doc: doc)
        let segments = [segment(0, text: "First paragraph.", paragraph: 0)]
        let vm = ReadAloudViewModel(document: doc, historyStore: store,
                                   speechGenerator: ResumeTestSpeech(segments: segments))
        defer { vm.stop() }
        vm.jump(to: 0)
        try await waitUntil("Explicit backward jump must play") { vm.isPlaying && !AudioPlayerService.shared.isBuffering && AudioPlayerService.shared.hasAudibleProgress }
        vm.togglePlayPause()
        XCTAssertEqual(store.readingCheckpoint(for: doc.id)?.paragraphIndex, 0)
        let fresh = HistoryStore(directory: directory)
        XCTAssertEqual(ReadAloudViewModel(document: doc, historyStore: fresh).currentParagraphIndex, 0)
    }

    func testPreactivatedKindleColdResumeBindsStableBookBeforeSpeech() async throws {
        let store = HistoryStore(directory: directory)
        let saved = document(.kindle, id: "kindle-stable-book")
        store.record(saved)
        try save(store, doc: saved)
        var page = saved
        page.id = "fresh-page-uuid"
        let vm = ReadAloudViewModel(document: page, historyStore: store,
            speechGenerator: ResumeTestSpeech(segments: [segment(0, text: saved.paragraphs[1].text)],
                                             initialDelayNanoseconds: 150_000_000))
        vm.configurePlaybackMetadata(id: saved.id, title: saved.title, coverURL: nil)
        defer { vm.stop(); vm.deactivate() }
        XCTAssertTrue(vm.hasPendingReadingResume)
        // Kindle preactivates the VM before choosing the saved-position entry.
        // A previous content identity must never survive that new ownership.
        AudioPlayerService.shared.setBook(id: "previous-content", title: "Previous", chapterTitle: nil, coverUrl: nil)
        vm.activate()
        vm.ensurePlaying()
        XCTAssertEqual(AudioPlayerService.shared.currentBookId, saved.id,
                       "Bind identity while TTS is pending, before page gestures can arrive")
        try await waitUntil("Cold resume must play the remembered paragraph") {
            vm.status.isReady && vm.isPlaying && AudioPlayerService.shared.hasAudibleProgress
        }
        XCTAssertEqual(vm.currentParagraphIndex, 1)
        XCTAssertEqual(AudioPlayerService.shared.currentBookId, saved.id,
                       "A playing Kindle page must still be recognized after TTS leaves loading state")
        XCTAssertTrue(vm.shouldResumeAfterManualLivePageTurn)
    }

    func testPreactivatedKindleParagraphJumpBindsStableBook() async throws {
        let page = document(.kindle, id: "jump-page-uuid")
        let vm = ReadAloudViewModel(document: page, historyStore: HistoryStore(directory: directory),
            speechGenerator: ResumeTestSpeech(segments: [segment(0, text: page.paragraphs[1].text)]))
        vm.configurePlaybackMetadata(id: "kindle-jump-book", title: page.title, coverURL: nil)
        defer { vm.stop(); vm.deactivate() }
        AudioPlayerService.shared.setBook(id: "previous-content", title: "Previous", chapterTitle: nil, coverUrl: nil)
        vm.activate()
        vm.jump(to: 1)
        try await waitUntil("Preactivated jump must play") {
            vm.status.isReady && vm.isPlaying && AudioPlayerService.shared.hasAudibleProgress
        }
        XCTAssertEqual(AudioPlayerService.shared.currentBookId, "kindle-jump-book")
    }

    func testConfirmedKindlePageTurnDiscardsOldPageResumeBeforeWarmPlayback() async throws {
        let store = HistoryStore(directory: directory)
        let old = document(.kindle, id: "kindle-stable-book")
        store.record(old)
        try save(store, doc: old)
        var next = document(.kindle, id: "new-page-uuid")
        next.paragraphs = paragraphs(["The next page content"])
        let vm = ReadAloudViewModel(document: next, historyStore: store)
        vm.configurePlaybackMetadata(id: old.id, title: old.title, coverURL: nil)
        XCTAssertNotNil(vm.resumeNotice)
        vm.discardReadingResumeForConfirmedNavigation()
        XCTAssertNil(vm.resumeNotice)
        XCTAssertFalse(vm.hasPendingReadingResume)
        let segments = [segment(0, text: "The next page content", paragraph: 0)]
        vm.startWithPrefetchedSegments(segments, paragraphIndex: 0)
        defer { vm.stop() }
        try await waitUntil("Confirmed next page must play") { vm.isPlaying && !AudioPlayerService.shared.isBuffering && AudioPlayerService.shared.hasAudibleProgress }
        vm.togglePlayPause()
        vm.flushReadingProgress()
        let checkpoint = try XCTUnwrap(store.readingCheckpoint(for: old.id))
        XCTAssertEqual(ReadingResumeDocumentIndex(paragraphs: next.paragraphs).resolve(checkpoint), 0)
    }

    func testRepeatedPhotoImportStillReceivesItsDelayedOCRUpgrade() throws {
        let store = HistoryStore(directory: directory)
        var original = document(.photo)
        original.imageData = Data([1, 2, 3, 4])
        store.record(original)
        try save(store, doc: original)
        var placeholder = original
        placeholder.id = "fresh-photo-uuid"
        placeholder.contentSessionKey = placeholder.id
        placeholder.paragraphs = []
        let coordinator = PlayerCoordinator(historyStore: store)
        coordinator.open(placeholder)
        defer { coordinator.close() }
        XCTAssertEqual(coordinator.session?.document.id, original.id)
        var recognized = placeholder
        recognized.paragraphs = original.paragraphs
        coordinator.upgradeSessionContent(recognized)
        XCTAssertEqual(coordinator.session?.document.paragraphs, original.paragraphs)
        XCTAssertEqual(coordinator.session?.readVM.currentParagraphIndex, 1)
    }

    func testSameAccountCredentialRefreshKeepsExistingProgressWriterValid() throws {
        let store = HistoryStore(accountDataRoot: directory)
        XCTAssertTrue(store.activate(storageID: "account-a"))
        let token = store.progressBoundaryToken
        let doc = document()
        store.record(doc)
        XCTAssertTrue(store.activate(storageID: "account-a"))
        XCTAssertEqual(store.progressBoundaryToken, token)
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .text, paragraphIndex: 1, audio: nil))
        XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: token))
    }

    func testEditingContentUpdatesReimportIdentityInsteadOfMatchingOldBytes() {
        let store = HistoryStore(directory: directory)
        let original = document()
        store.record(original)
        var edited = original
        edited.paragraphs = paragraphs(["Edited content"])
        store.record(edited)
        XCTAssertEqual(store.canonicalDocument(document(id: "fresh-old-content")).id, "fresh-old-content")
        var freshEdited = edited
        freshEdited.id = "fresh-edited-content"
        freshEdited.contentSessionKey = freshEdited.id
        XCTAssertEqual(store.canonicalDocument(freshEdited).id, original.id)
    }

    func testRemoteReferenceRevisionKeepsAnchorWithoutPersistingPayload() throws {
        let store = HistoryStore(directory: directory)
        let origin = CloudDocumentOrigin(provider: .googleDrive, accountKey: "opaque-account",
                                         remoteItemID: "remote-item", revision: "rev1", originalName: "Remote.epub")
        let doc = ReadingDocument(id: origin.stableDocumentID, title: "Remote", sourceKind: .epub,
                                  language: "en", paragraphs: paragraphs(["First", "Saved target"]),
                                  fileData: Data("remote bytes must stay ephemeral".utf8), origin: origin,
                                  contentSessionKey: "session-rev1")
        store.record(doc)
        try save(store, doc: doc)
        let revised = ReadingDocument(id: doc.id, title: doc.title, sourceKind: .epub,
                                      language: "en", paragraphs: paragraphs(["New preface", "First", "Saved target"]),
                                      origin: origin.replacingRevision("rev2"), contentSessionKey: "session-rev2")
        let coordinator = PlayerCoordinator(historyStore: store)
        coordinator.open(revised)
        defer { coordinator.close() }
        XCTAssertEqual(coordinator.session?.readVM.currentParagraphIndex, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(doc.id + ".payload").path))
        let checkpointFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".resume.json") }
        XCTAssertEqual(checkpointFiles.count, 1)
        let json = try String(contentsOf: XCTUnwrap(checkpointFiles.first), encoding: .utf8)
        XCTAssertFalse(json.contains("Saved target"))
        XCTAssertFalse(json.contains("remote bytes"))
    }

    func testAccountBoundaryRejectsOldWriterEvenAfterSwitchingBack() throws {
        let store = HistoryStore(accountDataRoot: directory)
        XCTAssertTrue(store.activate(storageID: "account-a"))
        let doc = document()
        store.record(doc)
        let oldToken = store.progressBoundaryToken
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .text, paragraphIndex: 1, audio: nil))
        XCTAssertTrue(store.activate(storageID: "account-b"))
        XCTAssertNil(store.readingCheckpoint(for: doc.id))
        XCTAssertFalse(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: oldToken))
        XCTAssertTrue(store.activate(storageID: "account-a"))
        XCTAssertFalse(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: oldToken))
        XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: store.progressBoundaryToken))
    }
}

extension ReadingResumeTests {
    func testChineseVisualBookmarkUsesTimestampWordInsteadOfRemainingParagraph() throws {
        let source = String(repeating: "长篇正文", count: 300) + "记忆点" + String(repeating: "后续正文", count: 300)
        let offset = (source as NSString).range(of: "记忆点").location
        let audio = AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: Data([1]),
            timestamps: [TTSTimestamp(word: "记忆点", startTime: 3, endTime: 4)],
            duration: 8, text: source, isWavFormat: false)
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [audio], currentSegmentID: audio.id, time: 3.5))
        XCTAssertEqual(cursor.outputUTF16Offset, offset)
        XCTAssertEqual(cursor.outputUTF16Length, 3)
        let visual = try XCTUnwrap(ReadingResumeContract.captureVisual(output: source,
            offset: cursor.outputUTF16Offset, length: cursor.outputUTF16Length, source: source))
        XCTAssertEqual((source as NSString).substring(with: try XCTUnwrap(visual.range(in: source))), "记忆点")
        XCTAssertNil(ReadingResumeContract.captureVisual(output: source, offset: offset, length: Int.max, source: source))
    }

    func testVisualBookmarkNormalizesPunctuationWithoutChangingLiveOutputCoordinates() throws {
        let source = "Before, ‘remember’ — this exact position."
        let output = "Before remember this exact position."
        let offset = (output as NSString).range(of: "exact").location
        let cursor = try XCTUnwrap(ReadingResumeContract.captureVisual(output: output, offset: offset, source: source))
        let range = try XCTUnwrap(cursor.range(in: source))
        XCTAssertEqual((source as NSString).substring(with: range), "exact")
        XCTAssertNil(cursor.range(in: "Changed " + source))
    }

    func testVisualBookmarkUsesCorrectRepeatedWordAfterEmojiAndChinese() throws {
        let source = "📖 Start 记住这里 same same same destination same."
        let offset = (source as NSString).range(of: "same", options: .backwards).location
        let cursor = try XCTUnwrap(ReadingResumeContract.captureVisual(output: source, offset: offset, source: source))
        XCTAssertEqual(cursor.utf16Offset, offset)
        XCTAssertEqual(cursor.utf16Length, 4)
        let bytes = try JSONEncoder().encode(cursor)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("destination"))
        XCTAssertEqual(try JSONDecoder().decode(ReadingResumeVisualCursor.self, from: bytes), cursor)
    }

    func testVisualBookmarkRejectsAmbiguousContextAndInvalidOffsets() {
        let repeated = String(repeating: "same ", count: 30)
        let output = "changed " + repeated + "target"
        let source = "original " + repeated + "target " + repeated + "target"
        XCTAssertNil(ReadingResumeContract.captureVisual(output: output,
            offset: (output as NSString).range(of: "target").location, source: source))
        XCTAssertNil(ReadingResumeContract.captureVisual(output: "sample", offset: -1, source: "sample"))
        XCTAssertNil(ReadingResumeContract.captureVisual(output: "sample", offset: 6, source: "sample"))
        let invalid = ReadingResumeVisualCursor(sourceFingerprint: ReadingResumeContract.fingerprint("sample"),
            utf16Offset: Int.max, utf16Length: Int.max)
        XCTAssertNil(invalid.range(in: "sample"))
    }

    func testOldCheckpointWithoutVisualBookmarkRemainsDecodable() throws {
        let doc = document()
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .text, paragraphIndex: 1, audio: nil))
        let json = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(ReadingResumeCheckpoint.self, from: json)
        XCTAssertNil(decoded.visual)
        XCTAssertEqual(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs).resolve(decoded), 1)
    }
}

extension ReadingResumeTests {
    func testClearingHistoryRemovesEveryCaptionTrackCheckpoint() throws {
        let store = HistoryStore(directory: directory)
        let doc = document(.youtube)
        store.record(doc)
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .youtube, paragraphIndex: 1, audio: nil))
        for track in ["english", "chinese"] {
            XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id,
                boundary: store.progressBoundaryToken, variant: track))
        }
        store.clearAll()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasSuffix(".resume.json") })
    }

    func testYouTubeCaptionTrackCheckpointsAreIndependentAndDeleteTogether() throws {
        let store = HistoryStore(directory: directory)
        let doc = document(.youtube)
        store.record(doc)
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .youtube, paragraphIndex: 1, audio: nil))
        XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id,
            boundary: store.progressBoundaryToken, variant: "english-track"))
        XCTAssertNil(store.readingCheckpoint(for: doc.id, variant: "chinese-track"))
        var restored = try XCTUnwrap(store.readingCheckpoint(for: doc.id, variant: "english-track"))
        XCTAssertEqual(restored.activity?.revision, 1)
        restored.activity = nil
        XCTAssertEqual(restored, checkpoint)
        XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id,
            boundary: store.progressBoundaryToken, variant: "chinese-track"))
        store.delete(doc.id)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasSuffix(".resume.json") })
    }
}

extension ReadingResumeTests {
    func testRegeneratedSpeechNormalizesPunctuationAndChunkBoundariesWithoutLosingSavedWord() throws {
        let old = segment(0, text: "Alpha, beta gamma.")
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [old], currentSegmentID: old.id, time: 4))
        let fresh = [segment(0, text: "Alpha ", changedAudio: true),
                     segment(1, text: "beta — gamma", changedAudio: true)]
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: fresh, isComplete: true),
                       .seek(segmentIndex: 1, seconds: 1))
        let changed = [segment(0, text: "Different beta gamma.", changedAudio: true)]
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: changed, isComplete: true), .unavailable)
    }
}

extension ReadingResumeTests {
    func testNewViewModelGetsFreshRenderIdentityButMiniPlayerKeepsCurrentInstance() throws {
        let coordinator = PlayerCoordinator(historyStore: HistoryStore(directory: directory))
        let doc = document()
        coordinator.open(doc)
        let initial = try XCTUnwrap(coordinator.session)
        coordinator.minimize()
        coordinator.expand()
        coordinator.open(doc)
        XCTAssertEqual(coordinator.session?.instanceID, initial.instanceID)
        coordinator.close()
        coordinator.open(doc)
        defer { coordinator.close() }
        XCTAssertEqual(coordinator.session?.id, initial.id)
        XCTAssertNotEqual(coordinator.session?.instanceID, initial.instanceID)
        XCTAssertFalse(coordinator.session?.readVM === initial.readVM)
    }
}


extension ReadingResumeTests {
    func testUnifiedCatalogIncludesEveryListenedSourceButNotOpenedOnlyItems() throws {
        let store = HistoryStore(directory: directory)
        let sources: [ReadingSourceKind] = [.text, .photo, .pdf, .epub, .docx, .web,
            .kindle, .weread, .googleBooks, .kobo, .oreilly, .youtube]
        for source in sources {
            let doc = document(source, id: source.rawValue)
            store.record(doc)
            XCTAssertEqual(ContentCatalog(history: store).item(id: doc.id)?.state, .unstarted)
            try save(store, doc: doc)
        }
        store.record(document(.text, id: "opened-only"))
        let fresh = HistoryStore(directory: directory)
        XCTAssertEqual(Set(ContentCatalog(history: fresh).continuing.map(\.id)), Set(sources.map(\.rawValue)))
        XCTAssertNil(ContentCatalog(history: fresh).continuing.first { $0.id == "opened-only" })
        for item in ContentCatalog(history: fresh).continuing {
            XCTAssertEqual(item.checkpoint?.paragraphIndex, 1)
        }
    }

    func testAtomicActivityUsesActualListeningNotOpeningOrForcedFlushTime() throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .text, paragraphIndex: 1, audio: nil, now: old))
        XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: store.progressBoundaryToken))
        store.record(doc)
        try save(store, doc: doc)
        XCTAssertEqual(store.latestReadingCheckpoint(for: doc.id)?.activity?.lastListenedAt, old)
        XCTAssertEqual(store.latestReadingCheckpoint(for: doc.id)?.activity?.listenedSeconds, 0)
        for rejected in [Double.infinity, Double.nan, -1, 30] {
            store.recordListening(seconds: rejected, for: doc.id, boundary: store.progressBoundaryToken)
        }
        store.recordListening(seconds: 1.25, for: doc.id, boundary: UUID())
        store.recordListening(seconds: 1.25, for: doc.id, boundary: store.progressBoundaryToken)
        try save(store, doc: doc)
        let fresh = HistoryStore(directory: directory)
        XCTAssertEqual(fresh.latestReadingCheckpoint(for: doc.id)?.activity?.listenedSeconds, 1.25)
        XCTAssertGreaterThan(try XCTUnwrap(fresh.latestReadingCheckpoint(for: doc.id)?.activity?.lastListenedAt), old)
    }

    func testLegacyCheckpointAndParagraphRecordsRemainInUnifiedContinueWithoutInventedSeconds() throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        store.updateReadingPosition(documentID: doc.id, paragraphIndex: 1)
        XCTAssertEqual(ContentCatalog(history: store).continuing.first?.id, doc.id)
        XCTAssertNil(ContentCatalog(history: store).continuing.first?.lastListenedAt)
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .text, paragraphIndex: 1, audio: nil))
        let url = directory.appendingPathComponent(ReadingResumeContract.fingerprint(doc.id) + ".read.resume.json")
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
        let fresh = HistoryStore(directory: directory)
        XCTAssertEqual(fresh.readingCheckpoint(for: doc.id), checkpoint)
        XCTAssertEqual(ContentCatalog(history: fresh).continuing.first?.lastListenedAt, checkpoint.updatedAt)
        XCTAssertNil(fresh.readingCheckpoint(for: doc.id)?.activity)
    }

    func testCompletionArchiveAndDeletionUpdateCatalogWithoutLosingResumeLocator() throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        try save(store, doc: doc)
        let cursor = store.readingCheckpoint(for: doc.id)
        XCTAssertTrue(ContentProgressRepository(history: store).markCompleted(true, itemID: doc.id))
        XCTAssertEqual(ContentCatalog(history: store).item(id: doc.id)?.state, .completed)
        XCTAssertTrue(ContentCatalog(history: store).continuing.isEmpty)
        XCTAssertEqual(store.readingCheckpoint(for: doc.id)?.paragraphFingerprint, cursor?.paragraphFingerprint)
        XCTAssertTrue(store.setReadingCompleted(false, for: doc.id))
        store.setArchived(true, for: doc.id)
        store.record(doc) // Late callbacks/open metadata must not undo an archive.
        XCTAssertNil(ContentCatalog(history: store).item(id: doc.id))
        XCTAssertNotNil(store.readingCheckpoint(for: doc.id))
        let fresh = HistoryStore(directory: directory)
        fresh.setArchived(false, for: doc.id)
        XCTAssertEqual(ContentCatalog(history: fresh).continuing.first?.id, doc.id)
        fresh.delete(doc.id)
        XCTAssertNil(fresh.latestReadingCheckpoint(for: doc.id))
        XCTAssertTrue(ContentCatalog(history: fresh).continuing.isEmpty)
    }

    func testUnifiedResumeUsesExactIDLatestCheckpointAndRejectsStaleOrCompletedAction() async throws {
        let store = HistoryStore(directory: directory)
        var doc = document()
        doc.paragraphs = paragraphs(["First paragraph.", "Alpha beta gamma delta."])
        store.record(doc)
        try save(store, doc: doc)
        let coordinator = PlayerCoordinator(historyStore: store)
        defer { coordinator.close() }
        _ = try await coordinator.resume.open(itemID: doc.id, entryPoint: "catalog_test")
        XCTAssertEqual(coordinator.session?.readVM.currentParagraphIndex, 1)
        XCTAssertFalse(coordinator.session?.readVM.isPlaying ?? true)
        coordinator.close()
        try save(store, doc: doc, index: 0) // Same card ID, newer explicit backward stop.
        _ = try await coordinator.resume.open(itemID: doc.id, entryPoint: "catalog_test")
        XCTAssertEqual(coordinator.session?.readVM.currentParagraphIndex, 0)
        coordinator.close()
        do {
            _ = try await coordinator.resume.open(itemID: "removed", autoplay: true, entryPoint: "notification_test")
            XCTFail("An explicit stale ID must not open the most recent item")
        } catch ContentResumeError.unavailableItem {} catch { XCTFail("\(error)") }
        XCTAssertNil(coordinator.session)
        XCTAssertTrue(store.setReadingCompleted(true, for: doc.id))
        do {
            _ = try await coordinator.resume.open(itemID: doc.id, autoplay: true, entryPoint: "notification_test")
            XCTFail("A stale reminder must not autoplay completed content")
        } catch ContentResumeError.completedItem {} catch { XCTFail("\(error)") }
        XCTAssertNil(coordinator.session)
    }

    func testMissingFileKeepsCheckpointAndDoesNotOpenAnotherItem() async throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        try save(store, doc: doc)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(doc.id + ".payload"))
        XCTAssertEqual(ContentCatalog(history: store).item(id: doc.id)?.availability, .missingResource)
        let coordinator = PlayerCoordinator(historyStore: store)
        do {
            _ = try await coordinator.resume.open(itemID: doc.id, autoplay: true, entryPoint: "catalog_test")
            XCTFail("A missing payload must not begin playback")
        } catch {}
        XCTAssertNil(coordinator.session)
        XCTAssertEqual(store.readingCheckpoint(for: doc.id)?.paragraphIndex, 1)
    }

    func testInvalidOptionalActivityCannotDiscardVerifiedLocator() throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        var checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .text, paragraphIndex: 1, audio: nil))
        checkpoint.activity = ReadingProgressActivity(listenedSeconds: -20, lastListenedAt: Date(), revision: -1)
        let url = directory.appendingPathComponent(ReadingResumeContract.fingerprint(doc.id) + ".read.resume.json")
        try JSONEncoder().encode(checkpoint).write(to: url)
        let fresh = HistoryStore(directory: directory)
        XCTAssertEqual(fresh.readingCheckpoint(for: doc.id)?.paragraphIndex, 1)
        XCTAssertNil(fresh.readingCheckpoint(for: doc.id)?.activity)
    }

    func testNotificationRequiresExactItemAndOriginalAccountBoundary() {
        let valid = ResumeReminderDeepLink.userInfo(documentID: "book-42")
        XCTAssertEqual(ResumeReminderDeepLink.action(from: valid), .continueReading(itemID: "book-42", mode: .read))
        var wrongAccount = valid
        wrongAccount["accountBoundary"] = "old-account"
        XCTAssertNil(ResumeReminderDeepLink.action(from: wrongAccount))
        var missingID = valid
        missingID[ResumeReminderDeepLink.itemIDKey] = " "
        XCTAssertNil(ResumeReminderDeepLink.action(from: missingID))
        XCTAssertNil(ResumeReminderDeepLink.action(from: [ResumeReminderDeepLink.actionKey: ResumeReminderDeepLink.continueAction]))
    }
    func testOldWidgetEntityCannotActInAnotherAccount() throws {
        var snapshot = ContinueSnapshot(id: "book-42", title: "A book", sourceKind: "epub", updatedAt: Date())
        XCTAssertTrue(ReadingItemEntity(snapshot: snapshot).belongsToCurrentAccount)
        snapshot.accountBoundary = "another-account"
        let encoded = try JSONEncoder().encode(ReadingItemEntity(snapshot: snapshot))
        let restored = try JSONDecoder().decode(ReadingItemEntity.self, from: encoded)
        XCTAssertFalse(restored.belongsToCurrentAccount)
    }

    func testFailedAtomicWriteRetainsPendingListeningForRetry() throws {
        let store = HistoryStore(directory: directory)
        let doc = document()
        store.record(doc)
        try save(store, doc: doc)
        let url = directory.appendingPathComponent(ReadingResumeContract.fingerprint(doc.id) + ".read.resume.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        store.recordListening(seconds: 1.5, for: doc.id, boundary: store.progressBoundaryToken)
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: doc.paragraphs)
            .checkpoint(sourceKind: .text, paragraphIndex: 1, audio: nil))
        XCTAssertFalse(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: store.progressBoundaryToken))
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(store.saveReadingCheckpoint(checkpoint, for: doc.id, boundary: store.progressBoundaryToken))
        XCTAssertEqual(HistoryStore(directory: directory).readingCheckpoint(for: doc.id)?.activity?.listenedSeconds, 1.5)
    }

    func testExistingCatalogImmediatelyReflectsNewStopAcrossFilesystemAliases() throws {
        let real = directory.appendingPathComponent("real", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        // Match /var -> /private/var: the alias is an ancestor, while the
        // directory being enumerated is a real child directory.
        let historyDirectory = alias.appendingPathComponent("History", isDirectory: true)
        let first = HistoryStore(directory: historyDirectory)
        let doc = document()
        first.record(doc)
        try save(first, doc: doc)
        let reopened = HistoryStore(directory: historyDirectory)
        XCTAssertEqual(ContentCatalog(history: reopened).item(id: doc.id)?.checkpoint?.paragraphIndex, 1)
        reopened.recordListening(seconds: 1, for: doc.id, boundary: reopened.progressBoundaryToken)
        try save(reopened, doc: doc, index: 0)
        XCTAssertEqual(ContentCatalog(history: reopened).item(id: doc.id)?.checkpoint?.paragraphIndex, 0)
        XCTAssertEqual(ContentCatalog(history: reopened).item(id: doc.id)?.checkpoint?.activity?.listenedSeconds, 1)
    }

    func testDeletingAnotherItemDoesNotDiscardCurrentPendingListening() throws {
        let store = HistoryStore(directory: directory)
        let current = document(id: "current"), other = document(id: "other")
        store.record(current); store.record(other)
        store.recordListening(seconds: 1.5, for: current.id, boundary: store.progressBoundaryToken)
        store.delete(other.id)
        try save(store, doc: current)
        XCTAssertEqual(store.readingCheckpoint(for: current.id)?.activity?.listenedSeconds, 1.5)
    }

}

private actor VoiceRecordingSpeech: ParagraphSpeechGenerating {
    private(set) var voices: [String] = []
    private(set) var inputs: [String] = []
    var fails = false
    let segments: [AudioSegment]
    init(_ segments: [AudioSegment]) { self.segments = segments }
    func setFails(_ value: Bool) { fails = value }
    func generateTTSForParagraph(
        paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        voices.append(voice ?? "")
        inputs.append(text)
        if fails { throw URLError(.cannotConnectToHost) }
        for segment in segments { try Task.checkCancellation(); await onSegmentReady(segment) }
    }
}

extension ReadingResumeTests {
    func testInactiveReadAloudDiscardsOldVoiceAudioBeforeResume() async throws {
        let settings = AppSettings.shared
        let previous = settings.voice(for: "en")
        let old = segment(0, text: "Alpha beta gamma delta.", duration: 30)
        let replacement = segment(0, text: old.text, duration: 30, changedAudio: true)
        settings.clearActiveClonedVoice(for: "en")
        XCTAssertTrue(settings.setVoice("af_heart", for: "en"))
        let speech = VoiceRecordingSpeech([replacement])
        let vm = ReadAloudViewModel(document: document(), speechGenerator: speech)
        defer {
            vm.stop(); vm.deactivate()
            if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: "en") }
            else { settings.setVoice(previous, for: "en") }
        }
        vm.startWithCachedSegments([old], paragraphIndex: 1, segmentID: old.id, progress: 0,
                                   isReplayEligible: false, autoplay: false)
        vm.deactivate()
        XCTAssertTrue(settings.setVoice("vl_read_test", for: "en"))
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.activate()
        vm.ensurePlaying()
        try await waitUntil("Read must replace stale audio on resume") {
            AudioPlayerService.shared.currentSegment?.audioData == replacement.audioData
        }
        let voices = await speech.voices
        XCTAssertEqual(voices.first, "vl_read_test")
        XCTAssertFalse(voices.contains("af_heart"))
    }

    func testExplainCachedAudioRevoicesAndFailureNeverResumesOldNarrator() async throws {
        let settings = AppSettings.shared
        let previous = settings.voice(for: "en"), oldLanguage = settings.explainLanguage
        settings.explainLanguage = "en"
        settings.clearActiveClonedVoice(for: "en")
        settings.setVoice("af_heart", for: "en")
        let old = segment(0, text: "A cached explanation.", paragraph: 0, duration: 30)
        let replacement = segment(0, text: old.text, paragraph: 0, duration: 30, changedAudio: true)
        let speech = VoiceRecordingSpeech([replacement])
        let vm = ExplainViewModel(document: document(), speechGenerator: speech)
        defer {
            vm.stop(); vm.deactivate()
            settings.explainLanguage = oldLanguage
            if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: "en") }
            else { settings.setVoice(previous, for: "en") }
        }
        vm.debugSeedCachedNarration([old], voiceID: "af_heart")
        settings.setVoice("vl_explain_test", for: "en")
        try await Task.sleep(nanoseconds: 100_000_000)
        await speech.setFails(true)
        vm.activate()
        vm.ensurePlaying()
        try await waitUntil("A failed voice switch must be visible") {
            if case .error = vm.status { return true }; return false
        }
        XCTAssertNil(AudioPlayerService.shared.currentSegment)
        XCTAssertFalse(AudioPlayerService.shared.hasQueuedSegments)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
        await speech.setFails(false)
        vm.start()
        try await waitUntil("Retry must reuse narration and generate only the new voice") {
            AudioPlayerService.shared.currentSegment?.audioData == replacement.audioData
        }
        let voices = await speech.voices, inputs = await speech.inputs
        XCTAssertEqual(voices, ["vl_explain_test", "vl_explain_test"])
        XCTAssertEqual(inputs, [old.text, old.text])
        if case .error = vm.status { XCTFail("Successful retry must clear the error") }
        // Switching back from a clone to a regular voice also invalidates audio.
        settings.setVoice("af_bella", for: "en")
        try await Task.sleep(nanoseconds: 250_000_000)
        let finalVoices = await speech.voices
        XCTAssertEqual(finalVoices.last, "af_bella")
    }
}

extension ReadingResumeTests {
    func testSelectedPersonalVoiceIsUsedByReadAndCachedExplainReplay() async throws {
        let settings = AppSettings.shared
        let previous = settings.voice(for: "en"), oldLanguage = settings.explainLanguage
        settings.explainLanguage = "en"
        settings.setMultilingualClonedVoice("vc_personal_test", supportedLanguages: ["en"])
        let audio = segment(0, text: "One short paragraph.", paragraph: 0, duration: 30)
        let doc = ReadingDocument(id: "personal-voice", title: "Personal narrator", sourceKind: .text,
                                  language: "en", paragraphs: paragraphs([audio.text]))
        let speech = VoiceRecordingSpeech([audio])
        let read = ReadAloudViewModel(document: doc, speechGenerator: speech)
        let explain = ExplainViewModel(document: doc, speechGenerator: speech)
        defer {
            read.stop(); read.deactivate(); explain.stop(); explain.deactivate()
            settings.explainLanguage = oldLanguage
            if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: "en") }
            else { settings.setVoice(previous, for: "en") }
        }
        read.start()
        try await waitUntil("Personal voice must produce Read audio") {
            AudioPlayerService.shared.currentSegment?.audioData == audio.audioData
        }
        read.stop(); read.deactivate()
        explain.debugSeedCachedNarration([audio], voiceID: "af_heart")
        explain.replay()
        try await waitUntil("Replay must replace an old regular voice with the selected personal voice") {
            AudioPlayerService.shared.currentSegment?.audioData == audio.audioData
        }
        let voices = await speech.voices
        XCTAssertEqual(voices, ["vc_personal_test", "vc_personal_test"])
    }
}

extension ReadingResumeTests {
    private func retokenizedSegment(_ text: String = "We can't wait.",
                                    words: [String], changedAudio: Bool = true,
                                    index: Int = 0, paragraph: Int = 0) -> AudioSegment {
        AudioSegment(paragraphIndex: paragraph, segmentIndex: index,
                     audioData: wav(duration: 30, sample: changedAudio ? 7 : 0),
                     timestamps: words.enumerated().map {
                         TTSTimestamp(word: $0.element, startTime: Double($0.offset) * 3,
                                      endTime: Double($0.offset) * 3 + 2)
                     }, duration: 30, text: text, isWavFormat: true)
    }

    func testVoiceSwitchResolvesSplitAndMergedTimestampWords() throws {
        let whole = retokenizedSegment(words: ["We", "can't", "wait."], changedAudio: false)
        let split = retokenizedSegment(words: ["We", "can", "'t", "wait."])
        let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(
            segments: [whole], currentSegmentID: whole.id, time: 4))
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [split], isComplete: false),
                       .seek(segmentIndex: 0, seconds: 3))
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [split], isComplete: true),
                       .seek(segmentIndex: 0, seconds: 3))
        let reverse = try XCTUnwrap(ReadingResumeContract.captureAudio(
            segments: [split], currentSegmentID: split.id, time: 7))
        XCTAssertEqual(ReadingResumeContract.resolveAudio(reverse, segments: [whole], isComplete: true),
                       .seek(segmentIndex: 0, seconds: 3))
    }

    func testActiveCloneToRegularSwitchResumesRetokenizedAudioAndClearsProgress() async throws {
        try await exerciseRetokenizedVoiceSwitch(paused: false)
    }

    func testPausedCloneToRegularSwitchPreparesRetokenizedAudioWithoutPlaying() async throws {
        try await exerciseRetokenizedVoiceSwitch(paused: true)
    }

    private func exerciseRetokenizedVoiceSwitch(paused: Bool) async throws {
        let settings = AppSettings.shared, audio = AudioPlayerService.shared
        let previous = settings.voice(for: "en")
        settings.setVoice("vl_switch_test", for: "en")
        let old = retokenizedSegment(words: ["We", "can't", "wait."], changedAudio: false)
        let replacement = retokenizedSegment(words: ["We", "can", "'t", "wait."])
        let doc = ReadingDocument(id: UUID().uuidString, title: "Switch test", sourceKind: .text,
                                  language: "en", paragraphs: paragraphs([old.text]))
        let store = HistoryStore(directory: directory)
        store.record(doc)
        let speech = VoiceRecordingSpeech([replacement])
        let vm = ReadAloudViewModel(document: doc, historyStore: store, speechGenerator: speech)
        defer {
            vm.stop(); vm.deactivate()
            if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: "en") }
            else { settings.setVoice(previous, for: "en") }
        }
        vm.startWithCachedSegments([old], paragraphIndex: 0, segmentID: old.id, progress: 4 / 30,
                                   isReplayEligible: false)
        try await waitUntil("Initial clone must be audible") {
            vm.flushReadingProgress()
            return vm.isPlaying && audio.hasAudibleProgress && !audio.isBuffering
                && audio.playbackPosition >= 4 && store.readingCheckpoint(for: doc.id)?.audio != nil
        }
        if paused { vm.pausePlayback() }
        vm.flushReadingProgress()
        XCTAssertNotNil(store.readingCheckpoint(for: doc.id)?.audio)
        settings.setVoice("af_nicole", for: "en")
        try await waitUntil("Regular audio must resume and dismiss switching progress") {
            audio.currentSegment?.audioData == replacement.audioData && VoiceSwitchStatusCenter.shared.progress == nil
        }
        XCTAssertNil(vm.resumeNotice)
        if case .error = vm.status { XCTFail("Retokenization is not changed spoken content") }
        if paused {
            XCTAssertEqual(audio.playbackPosition, 3, accuracy: 0.1)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertTrue(audio.isExplicitlyPaused)
            vm.togglePlayPause()
        }
        try await waitUntil("The selected voice must be playable") {
            vm.isPlaying && audio.hasAudibleProgress && vm.debugResumeFirstPlaybackSeconds != nil
        }
        XCTAssertEqual(try XCTUnwrap(vm.debugResumeFirstPlaybackSeconds), 3, accuracy: 0.6)
        let voices = await speech.voices
        XCTAssertEqual(voices, ["af_nicole"])
    }
}

/// A producer whose completions can arrive even after cancellation, like a
/// response already dispatched by URLSession. Tests own every release point.
private actor ControlledVoiceSwitchSpeech: ParagraphSpeechGenerating {
    private var pending: [String: CheckedContinuation<[AudioSegment], Error>] = [:]
    private(set) var completed: Set<String> = []
    func isWaiting(_ voice: String) -> Bool { pending[voice] != nil }
    func release(_ voice: String, segments: [AudioSegment]) {
        pending.removeValue(forKey: voice)?.resume(returning: segments)
    }
    func fail(_ voice: String) { pending.removeValue(forKey: voice)?.resume(throwing: URLError(.timedOut)) }
    func cancelAll() {
        let work = pending.values
        pending.removeAll()
        for continuation in work { continuation.resume(throwing: CancellationError()) }
    }
    func generateTTSForParagraph(
        paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        let voice = voice ?? ""
        let segments = try await withCheckedThrowingContinuation { pending[voice] = $0 }
        for segment in segments { await onSegmentReady(segment) }
        completed.insert(voice)
    }
}

extension ReadingResumeTests {
    func testRetokenizedResumeVerifiesEntireWordAcrossStreamingSegmentsAndLegacyCheckpoint() throws {
        let old = retokenizedSegment(words: ["We", "can't", "wait."], changedAudio: false)
        var cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [old], currentSegmentID: old.id, time: 4))
        let first = retokenizedSegment("We can", words: ["We", "can"])
        let second = retokenizedSegment("'t wait.", words: ["'t", "wait."], index: 1)
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [first], isComplete: false), .waiting)
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [first], isComplete: true), .unavailable)
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [first, second], isComplete: true),
                       .seek(segmentIndex: 0, seconds: 3))
        cursor.semanticWordUTF16Length = nil
        let legacy = try JSONDecoder().decode(ReadingResumeAudioCursor.self, from: JSONEncoder().encode(cursor))
        XCTAssertEqual(ReadingResumeContract.resolveAudio(legacy, segments: [first, second], isComplete: true),
                       .seek(segmentIndex: 0, seconds: 3))
        let changed = retokenizedSegment("We can wait.", words: ["We", "can", "wait."])
        let missingTiming = retokenizedSegment(words: ["We", "can", "wait."])
        let missingPrefixTiming = retokenizedSegment(words: ["can", "'t", "wait."])
        let changedPrefix = retokenizedSegment("He can't wait.", words: ["He", "can", "'t", "wait."])
        for fresh in [changed, missingTiming, changedPrefix] {
            XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [fresh], isComplete: true), .unavailable)
        }
        // Prefix timestamps are unnecessary: text proves the prefix, while
        // timestamps must cover the complete saved word, without gaps.
        XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [missingPrefixTiming], isComplete: true),
                       .seek(segmentIndex: 0, seconds: 0))
    }

    func testRetokenizedResumeHandlesChineseAndUnicodeAfterPunctuationNormalization() throws {
        for (text, oldWords, freshText, newWords, time, expected) in [
            ("今天读书很好。", ["今天", "读书", "很好。"], "今天，读书很好。", ["今天", "读", "书", "很好。"], 4.0, 3.0),
            ("We can't wait.", ["We", "can", "'t", "wait."], "We can’t wait.", ["We", "can’t", "wait."], 7.0, 3.0),
            ("𐐀 can't wait.", ["𐐀", "can't", "wait."], "𐐀 can’t wait.", ["𐐀", "can", "’t", "wait."], 4.0, 3.0)
        ] {
            let old = retokenizedSegment(text, words: oldWords, changedAudio: false)
            let cursor = try XCTUnwrap(ReadingResumeContract.captureAudio(segments: [old], currentSegmentID: old.id, time: time))
            let fresh = retokenizedSegment(freshText, words: newWords)
            XCTAssertEqual(ReadingResumeContract.resolveAudio(cursor, segments: [fresh], isComplete: true),
                           .seek(segmentIndex: 0, seconds: expected))
        }
    }

    private func waitForRequest(_ speech: ControlledVoiceSwitchSpeech, voice: String) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if await speech.isWaiting(voice) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Expected a request for \(voice)")
    }

    func testRapidVoiceChangesIgnoreStaleAudioAndCompletionAndHonorPauseDuringRequest() async throws {
        let settings = AppSettings.shared, audio = AudioPlayerService.shared
        let previous = settings.voice(for: "en")
        settings.setVoice("vl_switch_test", for: "en")
        let old = retokenizedSegment(words: ["We", "can't", "wait."], changedAudio: false)
        let stale = retokenizedSegment("We can't wait. Stale", words: ["We", "can't", "wait."])
        let fresh = retokenizedSegment(words: ["We", "can", "'t", "wait."])
        let doc = ReadingDocument(id: UUID().uuidString, title: "Rapid switch", sourceKind: .text,
                                  language: "en", paragraphs: paragraphs([old.text]))
        let store = HistoryStore(directory: directory)
        store.record(doc)
        let speech = ControlledVoiceSwitchSpeech()
        let vm = ReadAloudViewModel(document: doc, historyStore: store, speechGenerator: speech)
        defer {
            vm.stop(); vm.deactivate()
            Task { await speech.cancelAll() }
            if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: "en") }
            else { settings.setVoice(previous, for: "en") }
        }
        vm.startWithCachedSegments([old], paragraphIndex: 0, segmentID: old.id, progress: 4 / 30, isReplayEligible: false)
        try await waitUntil("Clone playback must establish a cursor") {
            vm.flushReadingProgress()
            return vm.isPlaying && audio.hasAudibleProgress && !audio.isBuffering
                && audio.playbackPosition >= 4 && store.readingCheckpoint(for: doc.id)?.audio != nil
        }
        settings.setVoice("af_nicole", for: "en")
        try await waitForRequest(speech, voice: "af_nicole")
        XCTAssertNotNil(VoiceSwitchStatusCenter.shared.progress)
        settings.setVoice("am_puck", for: "en")
        try await waitForRequest(speech, voice: "am_puck")
        let newest = VoiceSwitchStatusCenter.shared.progress
        vm.pausePlayback()
        await speech.release("af_nicole", segments: [stale])
        // Let the stale task run through its callback, completion and defer.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(VoiceSwitchStatusCenter.shared.progress, newest)
        XCTAssertNil(audio.currentSegment)
        XCTAssertFalse(audio.hasQueuedSegments)
        await speech.release("am_puck", segments: [fresh])
        try await waitUntil("Newest request must finish, with the replacement audio queued") {
            VoiceSwitchStatusCenter.shared.progress == nil && audio.currentSegment?.text == fresh.text
        }
        XCTAssertFalse(audio.isPlaying)
        XCTAssertTrue(audio.isExplicitlyPaused)
        XCTAssertNil(vm.resumeNotice)
        vm.togglePlayPause()
        try await waitUntil("Resuming must play the latest voice") {
            vm.isPlaying && audio.hasAudibleProgress && vm.debugResumeFirstPlaybackSeconds != nil
        }
        XCTAssertEqual(try XCTUnwrap(vm.debugResumeFirstPlaybackSeconds), 3, accuracy: 0.6)
    }

    func testFailedVoiceSwitchClearsProgressAndRetryRecoversTheVerifiedCursor() async throws {
        let settings = AppSettings.shared, audio = AudioPlayerService.shared
        let previous = settings.voice(for: "en")
        settings.setVoice("vl_switch_test", for: "en")
        let old = retokenizedSegment(words: ["We", "can't", "wait."], changedAudio: false)
        let changed = retokenizedSegment("He can't wait.", words: ["He", "can", "'t", "wait."])
        let fresh = retokenizedSegment(words: ["We", "can", "'t", "wait."])
        let doc = ReadingDocument(id: UUID().uuidString, title: "Failure recovery", sourceKind: .text,
                                  language: "en", paragraphs: paragraphs([old.text]))
        let store = HistoryStore(directory: directory)
        store.record(doc)
        let speech = ControlledVoiceSwitchSpeech()
        let vm = ReadAloudViewModel(document: doc, historyStore: store, speechGenerator: speech)
        defer {
            vm.stop(); vm.deactivate()
            Task { await speech.cancelAll() }
            if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: "en") }
            else { settings.setVoice(previous, for: "en") }
        }
        vm.startWithCachedSegments([old], paragraphIndex: 0, segmentID: old.id, progress: 4 / 30, isReplayEligible: false)
        try await waitUntil("Clone playback must establish a cursor") {
            vm.flushReadingProgress()
            return vm.isPlaying && audio.hasAudibleProgress && !audio.isBuffering
                && audio.playbackPosition >= 4 && store.readingCheckpoint(for: doc.id)?.audio != nil
        }
        settings.setVoice("af_nicole", for: "en")
        try await waitForRequest(speech, voice: "af_nicole")
        await speech.release("af_nicole", segments: [changed])
        try await waitUntil("Changed content must fail visibly and end switching") {
            vm.resumeNotice != nil && VoiceSwitchStatusCenter.shared.progress == nil
        }
        XCTAssertNil(audio.currentSegment)
        XCTAssertFalse(audio.moreSegmentsExpected)
        // Selecting another voice after alignment failure must actually request
        // that voice instead of immediately returning behind resumeNotice.
        settings.setVoice("am_puck", for: "en")
        try await waitForRequest(speech, voice: "am_puck")
        await speech.fail("am_puck")
        try await waitUntil("A network error must also end switching") {
            if case .error = vm.status { return VoiceSwitchStatusCenter.shared.progress == nil }
            return false
        }
        XCTAssertFalse(audio.moreSegmentsExpected)
        XCTAssertNil(audio.currentSegment)
        vm.togglePlayPause()
        try await waitForRequest(speech, voice: "am_puck")
        await speech.release("am_puck", segments: [fresh])
        try await waitUntil("Retry must resume the verified position with the chosen voice") {
            vm.resumeNotice == nil && vm.isPlaying && audio.hasAudibleProgress && vm.debugResumeFirstPlaybackSeconds != nil
        }
        XCTAssertEqual(audio.currentSegment?.audioData, fresh.audioData)
        XCTAssertEqual(try XCTUnwrap(vm.debugResumeFirstPlaybackSeconds), 3, accuracy: 0.6)
    }
}

extension ReadingResumeTests {
    func testCommunityPersonalAndRegularVoicesRoundTripWhileReadingKindle() async throws {
        let settings = AppSettings.shared, audio = AudioPlayerService.shared
        let previous = settings.voice(for: "en")
        settings.setVoice("vl_switch_test", for: "en")
        let whole = retokenizedSegment(words: ["We", "can't", "wait."], changedAudio: false)
        let split = retokenizedSegment(words: ["We", "can", "'t", "wait."])
        let doc = ReadingDocument(id: UUID().uuidString, title: "Voice round trip", sourceKind: .kindle,
                                  language: "en", paragraphs: paragraphs([whole.text]))
        let store = HistoryStore(directory: directory)
        store.record(doc)
        let speech = ControlledVoiceSwitchSpeech()
        let vm = ReadAloudViewModel(document: doc, historyStore: store, speechGenerator: speech)
        defer {
            vm.stop(); vm.deactivate()
            Task { await speech.cancelAll() }
            if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: "en") }
            else { settings.setVoice(previous, for: "en") }
        }
        vm.startWithCachedSegments([whole], paragraphIndex: 0, segmentID: whole.id,
                                   progress: 4 / 30, isReplayEligible: false)
        try await waitUntil("Initial playback must persist its cursor") {
            vm.flushReadingProgress()
            return vm.isPlaying && audio.hasAudibleProgress && !audio.isBuffering
                && audio.playbackPosition >= 4 && store.readingCheckpoint(for: doc.id)?.audio != nil
        }
        for (voice, replacement) in [("af_nicole", split), ("vc_personal_switch_test", whole),
                                     ("af_heart", split), ("vl_switch_test", whole), ("am_puck", split)] {
            vm.flushReadingProgress()
            if voice.hasPrefix("vc_") { settings.setActiveClonedVoice(voice, for: "en") }
            else { settings.setVoice(voice, for: "en") }
            try await waitForRequest(speech, voice: voice)
            XCTAssertNil(audio.currentSegment, "Old audio must be removed at each handoff")
            await speech.release(voice, segments: [replacement])
            try await waitUntil("Each voice family must resume playback and finish its transaction") {
                vm.resumeNotice == nil && vm.isPlaying && audio.hasAudibleProgress
                    && VoiceSwitchStatusCenter.shared.progress == nil
                    && audio.currentSegment?.audioData == replacement.audioData
                    && vm.debugResumeFirstPlaybackSeconds != nil
            }
            XCTAssertEqual(settings.voice(for: "en"), voice)
            XCTAssertEqual(try XCTUnwrap(vm.debugResumeFirstPlaybackSeconds), 3, accuracy: 0.6)
            if case .error = vm.status { XCTFail("Voice round trip must remain playable") }
        }
    }
}

extension ReadingResumeTests {
    func testVoiceSwitchAfterRetiredPageGatePreservesPlaybackIntent() async throws {
        try await exerciseRetiredPageGateVoiceSwitch(paused: false)
    }

    func testVoiceSwitchAfterRetiredPageGateHonorsExplicitPause() async throws {
        try await exerciseRetiredPageGateVoiceSwitch(paused: true)
    }

    private func exerciseRetiredPageGateVoiceSwitch(paused: Bool) async throws {
        let settings = AppSettings.shared, audio = AudioPlayerService.shared
        let previous = settings.voice(for: "en")
        settings.setVoice("vl_switch_test", for: "en")
        let old = retokenizedSegment(words: ["We", "can't", "wait."], changedAudio: false)
        let fresh = retokenizedSegment(words: ["We", "can", "'t", "wait."])
        let future = retokenizedSegment("Next page.", words: ["Next", "page."], paragraph: 1)
        let doc = ReadingDocument(id: UUID().uuidString, title: "Page gate switch", sourceKind: .kindle,
                                  language: "en", paragraphs: paragraphs([old.text]))
        let store = HistoryStore(directory: directory)
        store.record(doc)
        let speech = VoiceRecordingSpeech([fresh])
        let vm = ReadAloudViewModel(document: doc, historyStore: store, speechGenerator: speech)
        defer {
            audio.canStartQueuedSegment = nil
            vm.stop(); vm.deactivate()
            if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: "en") }
            else { settings.setVoice(previous, for: "en") }
        }
        vm.startWithCachedSegments([old], paragraphIndex: 0, segmentID: old.id,
                                   progress: 29 / 30, isReplayEligible: false)
        let token = try XCTUnwrap(audio.activePlaybackSession)
        audio.canStartQueuedSegment = { $0.id != future.id }
        _ = audio.appendPreparedSegmentsForContinuousPlayback([future], session: token)
        try await waitUntil("Natural completion must hold the next page at the gate") { audio.isQueuedSegmentGated }
        vm.flushReadingProgress()
        XCTAssertNotNil(store.readingCheckpoint(for: doc.id)?.audio)
        XCTAssertTrue(audio.removePendingSegments(withIDs: [future.id]))
        audio.canStartQueuedSegment = nil
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.isBuffering)
        XCTAssertFalse(audio.isExplicitlyPaused)
        if paused { vm.pausePlayback() }
        settings.setVoice("af_maya", for: "en")
        try await waitUntil("The selected voice must replace the retired page gate") {
            audio.currentSegment?.audioData == fresh.audioData && VoiceSwitchStatusCenter.shared.progress == nil
        }
        XCTAssertNil(vm.resumeNotice)
        if paused {
            XCTAssertFalse(audio.isPlaying)
            XCTAssertTrue(audio.isExplicitlyPaused)
        } else {
            try await waitUntil("A transient page gate must not become a user Pause after switching") {
                vm.isPlaying && audio.hasAudibleProgress
            }
        }
        let voices = await speech.voices
        XCTAssertEqual(voices, ["af_maya"])
    }
}
