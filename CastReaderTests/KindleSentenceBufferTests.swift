import XCTest
import CoreGraphics
@testable import CastReader

final class KindleSentenceBufferTests: XCTestCase {
    private let scope = KindleSentenceBuffer.Scope(bookID: "fixture", layoutRevision: 1, navigationGeneration: 7)
    private func page(_ key: String, _ text: String) -> KindleSentenceBuffer.Page {
        .init(key: key, scope: scope, paragraphs: [.init(id: 0, text: text)])
    }
    private func edge(_ previous: String, _ next: String) -> KindleSentenceBuffer.ConfirmedEdge {
        .init(previousPageKey: previous, nextPageKey: next, scope: scope)
    }

    func testRealReportedWasNotBoundaryIsOneUtteranceWithTwoSourcePages() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        let first = try buffer.accept(page("A", "The journey continued. Was"))
        XCTAssertEqual(first.map(\.text), ["The journey continued."])
        let next = try buffer.accept(page("B", "not the raft progressing rapidly? What came next?"), after: edge("A", "B"))
        XCTAssertEqual(next.map(\.text), ["Was not the raft progressing rapidly?", "What came next?"])
        XCTAssertEqual(next[0].sources.map(\.pageKey), ["A", "B"])
        XCTAssertEqual(next[0].sources[0].sourceRange, NSRange(location: 23, length: 3))
        XCTAssertEqual(next[0].sources[1].speechRange.location, 4)
        XCTAssertNil(buffer.pending)
    }

    func testPredictedOrWrongAdjacentPageCannotConsumeTail() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        _ = try buffer.accept(page("A", "The unfinished"))
        XCTAssertThrowsError(try buffer.accept(page("B", "sentence.")))
        XCTAssertThrowsError(try buffer.accept(page("B", "sentence."), after: edge("X", "B")))
        XCTAssertEqual(buffer.pending?.text, "The unfinished")
        XCTAssertEqual(buffer.currentPageKey, "A")
        XCTAssertEqual(try buffer.accept(page("B", "sentence."), after: edge("A", "B")).map(\.text), ["The unfinished sentence."])
    }

    func testDuplicatePageObservationDoesNotReplayAnyPrefix() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        _ = try buffer.accept(page("A", "We"))
        let units = try buffer.accept(page("B", "we said, would go."), after: edge("A", "B"))
        XCTAssertEqual(units.map(\.text), ["We we said, would go."])
        XCTAssertEqual(try buffer.accept(page("B", "we said, would go."), after: edge("A", "B")), [])
    }

    func testFullSentenceAndChapterHeadingAreNotMerged() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        XCTAssertEqual(try buffer.accept(page("A", "A complete sentence." )).map(\.text), ["A complete sentence."])
        _ = try buffer.accept(page("B", "An unfinished ending"), after: edge("A", "B"))
        let chapter = KindleSentenceBuffer.Page(key: "C", scope: scope, paragraphs: [
            .init(id: 0, text: "CHAPTER TWO", isHeading: true), .init(id: 1, text: "A new journey.")
        ])
        XCTAssertEqual(try buffer.accept(chapter, after: edge("B", "C")).map(\.text),
                       ["An unfinished ending", "CHAPTER TWO", "A new journey."])
    }

    func testThreePagesRetainExactSourceRangesWithoutFuzzyPrefixRemoval() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        XCTAssertTrue(try buffer.accept(page("A", "A 👩🏽‍🔬" )).isEmpty)
        XCTAssertTrue(try buffer.accept(page("B", "carefully continues"), after: edge("A", "B")).isEmpty)
        let units = try buffer.accept(page("C", "the experiment."), after: edge("B", "C"))
        let unit = try XCTUnwrap(units.first)
        XCTAssertEqual(unit.text, "A 👩🏽‍🔬 carefully continues the experiment.")
        XCTAssertEqual(unit.sources.map(\.pageKey), ["A", "B", "C"])
        let spoken = unit.text as NSString
        XCTAssertEqual(unit.sources.map { spoken.substring(with: $0.speechRange) },
                       ["A 👩🏽‍🔬", "carefully continues", "the experiment."])
    }

    func testReflowAndCancelledNavigationRejectLateResults() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        _ = try buffer.accept(page("A", "The old tail"))
        let reflowed = KindleSentenceBuffer.Page(key: "B", scope: .init(bookID: "fixture", layoutRevision: 2, navigationGeneration: 7),
                                                paragraphs: [.init(id: 0, text: "must not join.")])
        XCTAssertThrowsError(try buffer.accept(reflowed, after: edge("A", "B")))
        buffer.cancel()
        XCTAssertNil(buffer.pending)
        XCTAssertThrowsError(try buffer.accept(page("B", "must not join."), after: edge("A", "B")))
        XCTAssertEqual(buffer.finish(), [])
    }

    func testSpeechBatchesGroupCompleteSentencesWithoutConsumingUnfinishedTail() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        let ready = try buffer.accept(page("A", "One sentence. Another sentence. Was"))
        let batches = KindleSentenceBuffer.playbackUnits(from: ready)
        XCTAssertEqual(batches.map(\.text), ["One sentence. Another sentence."])
        XCTAssertEqual(buffer.pending?.text, "Was")
        XCTAssertEqual(batches[0].sources.map(\.sourceRange), [NSRange(location: 0, length: 13), NSRange(location: 14, length: 17)])
        XCTAssertEqual(batches[0].sources.map(\.speechRange), batches[0].sources.map(\.sourceRange))
    }

    func testShortParagraphsShareRequestButRetainParagraphBreakAndHeadingBoundary() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        let ready = try buffer.accept(.init(key: "A", scope: scope, paragraphs: [
            .init(id: 0, text: "First short paragraph."), .init(id: 1, text: "Second short paragraph."),
            .init(id: 2, text: "CHAPTER TWO", isHeading: true), .init(id: 3, text: "New section.")]))
        let batches = KindleSentenceBuffer.playbackUnits(from: ready, isHeading: { $0.paragraphID == 2 })
        XCTAssertEqual(batches.map(\.text), ["First short paragraph.\n\nSecond short paragraph.", "CHAPTER TWO", "New section."])
        XCTAssertEqual(batches[0].sources.map(\.paragraphID), [0, 1])
        XCTAssertEqual(batches[0].sources[1].speechRange.location, "First short paragraph.\n\n".utf16.count)
    }

    func testLongSpeechBatchPreservesEverySourceCharacterAtClauseBoundaries() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        let text = String(repeating: "a careful observation, ", count: 60) + "ends here."
        let ready = try buffer.accept(page("A", text))
        let batches = KindleSentenceBuffer.playbackUnits(from: ready)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { $0.text.count <= 600 })
        for batch in batches {
            for source in batch.sources {
                XCTAssertEqual((text as NSString).substring(with: source.sourceRange),
                               (batch.text as NSString).substring(with: source.speechRange))
            }
        }
        XCTAssertEqual(batches.map(\.text).joined(separator: " "), text)
    }

    func testConfirmedEndFlushesOnceAndPreservesDashes() throws {
        var buffer = KindleSentenceBuffer(scope: scope)
        _ = try buffer.accept(page("A", "He said—"))
        let units = try buffer.accept(page("B", "continue."), after: edge("A", "B"))
        XCTAssertEqual(units.map(\.text), ["He said— continue."])
        _ = try buffer.accept(page("C", "Final fragment"), after: edge("B", "C"))
        XCTAssertEqual(buffer.finish().map(\.text), ["Final fragment"])
        XCTAssertEqual(buffer.finish(), [])
    }
}

final class KindleSpeechProjectionTests: XCTestCase {
    private func paragraph(_ text: String) -> ReadingParagraph {
        let words = text.split(separator: " ").enumerated().map {
            OCRWord(id: $0.offset, text: String($0.element),
                    bboxNorm: CGRect(x: Double($0.offset) * 0.1, y: 0.5, width: 0.08, height: 0.05))
        }
        return ReadingParagraph(id: 0, text: text, words: words)
    }

    func testJoinedAudioWordsRouteToOriginalPagesAndPositions() throws {
        let first = paragraph("The journey continued. Was")
        let next = paragraph("not the raft progressing rapidly?")
        let scope = KindleSentenceBuffer.Scope(bookID: "test", layoutRevision: 1, navigationGeneration: 1)
        var buffer = KindleSentenceBuffer(scope: scope)
        _ = try buffer.accept(.init(key: "A", scope: scope, paragraphs: [.init(id: 0, text: first.text)]))
        let units = try buffer.accept(.init(key: "B", scope: scope, paragraphs: [.init(id: 0, text: next.text)]),
                                      after: .init(previousPageKey: "A", nextPageKey: "B", scope: scope))
        let projected = try KindleSpeechProjection.project(XCTUnwrap(units.first), paragraphID: 7, pages: [
            "A": .init(key: "A", paragraphs: [first]), "B": .init(key: "B", paragraphs: [next])
        ])
        XCTAssertEqual(projected.paragraph.text, "Was not the raft progressing rapidly?")
        XCTAssertEqual(projected.paragraph.words.map(\.text), ["Was", "not", "the", "raft", "progressing", "rapidly?"])
        XCTAssertEqual(projected.anchors.map(\.pageKey), ["A", "B", "B", "B", "B", "B"])
        XCTAssertEqual(projected.anchors.map(\.wordIndex), [3, 0, 1, 2, 3, 4])
        XCTAssertEqual(projected.paragraph.words[0].bboxNorm, first.words[3].bboxNorm)
        XCTAssertEqual(projected.paragraph.words[1].bboxNorm, next.words[0].bboxNorm)
    }

    func testMissingOrChangedSourceIsRejected() throws {
        let unit = KindleSentenceBuffer.Unit(text: "Was", sources: [
            .init(pageKey: "A", paragraphID: 0, sourceRange: NSRange(location: 0, length: 3), speechRange: NSRange(location: 0, length: 3))
        ])
        XCTAssertThrowsError(try KindleSpeechProjection.project(unit, paragraphID: 0, pages: [:]))
        XCTAssertThrowsError(try KindleSpeechProjection.project(unit, paragraphID: 0, pages: ["A": .init(key: "A", paragraphs: [paragraph("Now")])]))
    }

    func testSourceWordPartIsClippedWithoutDeletingRestOfOriginalWord() throws {
        let original = paragraph("part.Next")
        let unit = KindleSentenceBuffer.Unit(text: "Next", sources: [
            .init(pageKey: "A", paragraphID: 0, sourceRange: NSRange(location: 5, length: 4), speechRange: NSRange(location: 0, length: 4))
        ])
        let projected = try KindleSpeechProjection.project(unit, paragraphID: 0, pages: ["A": .init(key: "A", paragraphs: [original])])
        XCTAssertEqual(projected.paragraph.words.map(\.text), ["Next"])
        XCTAssertEqual(projected.anchors.first?.characterRange, NSRange(location: 5, length: 4))
        XCTAssertEqual(original.text, "part.Next")
    }
}

@MainActor
final class KindleContinuousInputTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        useRegularVoiceForTest(language: "en")
    }

    private func player() throws -> AudioPlayerService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AudioPlayerService(testTemporaryRoot: root)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate())
    }

    func testLateConfirmedPageExtendsSamePlayerWithoutFinishingOrReplaying() async throws {
        let first = "The current page continues."
        let next = "Was not the raft progressing rapidly?"
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 0.35))
        }
        defer { fixture.close() }
        let audio = try player()
        let document = ReadingDocument(title: "Continuous Kindle fixture", sourceKind: .kindle, language: "en",
                                       paragraphs: [.init(id: 0, text: first)])
        let vm = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        defer { vm.deactivate(); audio.stop() }
        var demands: [(UUID, Int)] = []
        let token = try XCTUnwrap(vm.configureKindleContinuousInput { demands.append(($0, $1)) })
        var played: [Int] = []
        audio.onSegmentComplete = { if let id = audio.currentSegment?.paragraphIndex { played.append(id) } }
        vm.dbgGenerate(0)
        try await waitUntil { demands.count == 1 && played == [0] }
        XCTAssertFalse(vm.isFinished, "A visual page boundary must not end the reading session")
        XCTAssertEqual(demands[0].0, token)
        XCTAssertEqual(demands[0].1, 1)
        XCTAssertTrue(vm.appendKindleSpeech([.init(id: 1, text: next)], token: token, afterCount: 1, endOfContent: true))
        XCTAssertFalse(vm.appendKindleSpeech([.init(id: 1, text: next)], token: token, afterCount: 1))
        try await waitUntil { vm.isFinished }
        XCTAssertEqual(played, [0, 1])
        XCTAssertEqual(fixture.requests, [first, next])
        XCTAssertEqual(vm.document.id, document.id)
    }

    func testPauseAtPageBoundaryAcceptsSourceWithoutAutoplayAndResumesExactlyOnce() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 0.35))
        }
        defer { fixture.close() }
        let audio = try player()
        let vm = ReadAloudViewModel(document: .init(title: "Pause fixture", sourceKind: .kindle, language: "en",
            paragraphs: [.init(id: 0, text: "First complete sentence.")]), audioService: audio, ttsService: fixture.service())
        defer { vm.deactivate(); audio.stop() }
        var demands = 0
        let token = try XCTUnwrap(vm.configureKindleContinuousInput { _, _ in demands += 1 })
        var played: [Int] = []
        audio.onSegmentComplete = { if let id = audio.currentSegment?.paragraphIndex { played.append(id) } }
        vm.dbgGenerate(0)
        try await waitUntil { demands == 1 && played == [0] }
        vm.pausePlayback()
        XCTAssertTrue(vm.appendKindleSpeech([.init(id: 1, text: "Next complete sentence.")], token: token, afterCount: 1, endOfContent: true))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(played, [0])
        XCTAssertEqual(vm.document.paragraphs.count, 2)
        vm.togglePlayPause()
        try await waitUntil { vm.isFinished }
        XCTAssertEqual(played, [0, 1])
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testSourceFailureRetriesSourceWithoutRegeneratingCompletedSpeech() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 0.35))
        }
        defer { fixture.close() }
        let audio = try player()
        let vm = ReadAloudViewModel(document: .init(title: "Retry fixture", sourceKind: .kindle, language: "en",
            paragraphs: [.init(id: 0, text: "First sentence.")]), audioService: audio, ttsService: fixture.service())
        defer { vm.deactivate(); audio.stop() }
        var demands = 0
        let token = try XCTUnwrap(vm.configureKindleContinuousInput { _, _ in demands += 1 })
        var completed = 0
        audio.onSegmentComplete = { completed += 1 }
        vm.dbgGenerate(0)
        try await waitUntil { demands == 1 && completed == 1 }
        vm.failKindleSource(token: token, message: "Fixture source unavailable")
        XCTAssertFalse(audio.isPlaying)
        vm.togglePlayPause()
        try await waitUntil { demands == 2 }
        XCTAssertEqual(fixture.requests, ["First sentence."])
        XCTAssertTrue(vm.appendKindleSpeech([.init(id: 1, text: "Next sentence.")], token: token, afterCount: 1, endOfContent: true))
        try await waitUntil { vm.isFinished }
        XCTAssertEqual(completed, 2)
        XCTAssertEqual(fixture.requests, ["First sentence.", "Next sentence."])
    }

    func testRetiringSourcePrefixKeepsAbsoluteCursorAndFutureAudio() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 0.35))
        }
        defer { fixture.close() }
        let audio = try player()
        let paragraphs = (0..<5).map { ReadingParagraph(id: $0, text: "Sentence number \($0).") }
        let vm = ReadAloudViewModel(document: .init(title: "Memory fixture", sourceKind: .kindle, language: "en",
            paragraphs: paragraphs), audioService: audio, ttsService: fixture.service())
        defer { vm.deactivate(); audio.stop() }
        let token = try XCTUnwrap(vm.configureKindleContinuousInput { _, _ in })
        var played: [Int] = []
        audio.onSegmentComplete = { if let id = audio.currentSegment?.paragraphIndex { played.append(id) } }
        vm.dbgGenerate(0)
        try await waitUntil { vm.currentParagraphIndex == 3 }
        XCTAssertFalse(vm.retireKindleSpeech(before: 4, token: token))
        XCTAssertTrue(vm.retireKindleSpeech(before: 2, token: token))
        XCTAssertEqual(vm.document.paragraphs.count, 5)
        XCTAssertEqual(vm.document.paragraphs[0].text, "")
        XCTAssertEqual(vm.document.paragraphs[1].words, [])
        XCTAssertEqual(vm.document.paragraphs[3].id, 3)
        XCTAssertTrue(vm.appendKindleSpeech([], token: token, afterCount: 5, endOfContent: true))
        try await waitUntil { vm.isFinished }
        XCTAssertEqual(played, [0, 1, 2, 3, 4])
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testNavigationOwnerCannotReceiveLateOrWrongCursorPage() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 1))
        }
        defer { fixture.close() }
        let audio = try player()
        let document = ReadingDocument(title: "Retired Kindle fixture", sourceKind: .kindle, language: "en",
                                       paragraphs: [.init(id: 0, text: "The current page.")])
        let vm = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        defer { vm.deactivate(); audio.stop() }
        var demandCount = 0
        let token = try XCTUnwrap(vm.configureKindleContinuousInput { _, _ in demandCount += 1 })
        vm.dbgGenerate(0)
        try await waitUntil { demandCount == 1 }
        let appended = ReadingParagraph(id: 1, text: "The next page.")
        XCTAssertFalse(vm.appendKindleSpeech([appended], token: UUID(), afterCount: 1))
        XCTAssertFalse(vm.appendKindleSpeech([appended], token: token, afterCount: 0))
        vm.deactivate()
        XCTAssertFalse(vm.appendKindleSpeech([appended], token: token, afterCount: 1))
        XCTAssertFalse(fixture.requests.contains(appended.text))
    }
}
