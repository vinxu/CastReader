import XCTest
import Combine
@testable import CastReader

private struct ResumeTestSpeech: ParagraphSpeechGenerating {
    let segments: [AudioSegment]
    func generateTTSForParagraph(
        paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
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
        try await waitUntil("Initial audio must start at the later segment") { first.isPlaying && AudioPlayerService.shared.currentSegment?.id == "1-1" }
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
        try await waitUntil("Cold resume must become audible") { resumed.isPlaying }
        XCTAssertFalse(audibleIDs.isEmpty)
        XCTAssertTrue(audibleIDs.allSatisfy { $0 == "1-1" }, "Earlier audio must never briefly play")
        XCTAssertEqual(AudioPlayerService.shared.playbackPosition, stopped.segmentTime, accuracy: 0.35)
        resumed.togglePlayPause()
        let after = try XCTUnwrap(fresh.readingCheckpoint(for: doc.id)?.audio)
        XCTAssertGreaterThanOrEqual(after.segmentTime, stopped.segmentTime - 0.1)
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
        try await waitUntil("Playing before mode switch") { vm.isPlaying }
        vm.deactivate()
        let saved = try XCTUnwrap(store.readingCheckpoint(for: doc.id)?.audio)
        let visual = try XCTUnwrap(vm.initialResumeViewportRange,
            "Returning from Explain must reveal the stopped word before audio starts")
        XCTAssertEqual((doc.paragraphs[1].text as NSString).substring(with: visual), "delta")
        vm.activate()
        vm.ensurePlaying()
        try await waitUntil("Playing after mode switch") { vm.isPlaying }
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
        try await waitUntil("Explicit backward jump must play") { vm.isPlaying }
        vm.togglePlayPause()
        XCTAssertEqual(store.readingCheckpoint(for: doc.id)?.paragraphIndex, 0)
        let fresh = HistoryStore(directory: directory)
        XCTAssertEqual(ReadAloudViewModel(document: doc, historyStore: fresh).currentParagraphIndex, 0)
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
        try await waitUntil("Confirmed next page must play") { vm.isPlaying }
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
        XCTAssertEqual(store.readingCheckpoint(for: doc.id, variant: "english-track"), checkpoint)
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
