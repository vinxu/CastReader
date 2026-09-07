import XCTest
@testable import CastReader

@MainActor
final class KindlePrefetchHorizonTests: XCTestCase {
    private func candidates(_ count: Int, chars: Int = 12, duration: Double? = nil) -> [KindleParagraphPrefetchHorizon.Candidate] {
        (1...count).map { .init(index: $0, utf16Count: chars, readyDuration: duration) }
    }
    func testKeepsTwoFutureParagraphsEvenWhenTheyExceedTimeTarget() {
        let result = KindleParagraphPrefetchHorizon.select(candidates(10, duration: 20), speed: 1)
        XCTAssertEqual(result.indices, [1, 2])
        XCTAssertEqual(result.additionalCharacters, 0)
    }
    func testShortParagraphsHaveEightParagraphHardLimit() {
        let result = KindleParagraphPrefetchHorizon.select(candidates(30, duration: 0.2), speed: 1)
        XCTAssertEqual(result.indices, Array(1...8))
        XCTAssertEqual(result.estimatedSeconds, 1.6, accuracy: 0.001)
    }
    func testAdditionalCharacterCapIncludesAlreadyReadyParagraphs() {
        let values = [
            KindleParagraphPrefetchHorizon.Candidate(index: 1, utf16Count: 2_000, readyDuration: 0.1),
            .init(index: 2, utf16Count: 2_000, readyDuration: 0.1),
            .init(index: 3, utf16Count: 900, readyDuration: 0.1),
            .init(index: 4, utf16Count: 701, readyDuration: 0.1),
        ]
        let result = KindleParagraphPrefetchHorizon.select(values, speed: 1)
        XCTAssertEqual(result.indices, [1, 2, 3])
        XCTAssertEqual(result.additionalCharacters, 900)
    }
    func testExactly1600AdditionalCharactersAreAllowed() {
        let result = KindleParagraphPrefetchHorizon.select(candidates(12, chars: 400, duration: 0.1), speed: 1)
        XCTAssertEqual(result.indices, Array(1...6))
        XCTAssertEqual(result.additionalCharacters, 1_600)
    }
    func testSpeedChangesLeadTimeButNotHardBounds() {
        let values = candidates(12, duration: 3)
        XCTAssertEqual(KindleParagraphPrefetchHorizon.select(values, speed: 1).indices, Array(1...4))
        XCTAssertEqual(KindleParagraphPrefetchHorizon.select(values, speed: 2).indices, Array(1...8))
        XCTAssertEqual(KindleParagraphPrefetchHorizon.select(values, speed: .nan).indices, Array(1...4))
    }
    func testUnknownDurationIsOnlyAnEstimateAndReadyCanExpandWindow() {
        let unknown = KindleParagraphPrefetchHorizon.select(candidates(12, chars: 240), speed: 1)
        XCTAssertEqual(unknown.indices, [1, 2])
        let ready = KindleParagraphPrefetchHorizon.select(candidates(12, chars: 240, duration: 0.2), speed: 1)
        XCTAssertEqual(ready.indices, Array(1...8))
    }
    func testInvalidReadyDurationUsesTextEstimate() {
        let result = KindleParagraphPrefetchHorizon.select(candidates(12, chars: 240, duration: .infinity), speed: 1)
        XCTAssertEqual(result.indices, [1, 2])
        XCTAssertEqual(result.estimatedSeconds, 20, accuracy: 0.001)
    }
    func testEmptyAndPageEndNeverInventSuccessor() {
        XCTAssertEqual(KindleParagraphPrefetchHorizon.select([], speed: 1).indices, [])
        XCTAssertEqual(KindleParagraphPrefetchHorizon.select(candidates(1), speed: 1).indices, [1])
    }

    private func waitUntil(timeout: Double = 8, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), "Bounded production prefetch/player did not reach expected state")
    }
    private func player() throws -> AudioPlayerService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AudioPlayerService(testTemporaryRoot: root)
    }
    private func document(_ texts: [String], source: ReadingSourceKind = .kindle) -> ReadingDocument {
        ReadingDocument(title: "Bounded horizon fixture", sourceKind: source, language: "en",
                        paragraphs: texts.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) })
    }
    func testProductionHorizonStartsDelayedSixthParagraphEarlyOnceAndPlaysInOrder() async throws {
        let texts = (0..<9).map { "Paragraph \($0)." }
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 0.6), delay: input == texts[6] ? 1.0 : 0)
        }
        defer { fixture.close() }
        let audio = try player()
        let vm = ReadAloudViewModel(document: document(texts), audioService: audio, ttsService: fixture.service())
        defer { vm.deactivate(); audio.stop() }
        var completed: [Int] = []
        audio.onSegmentComplete = { if let index = audio.currentSegment?.paragraphIndex { completed.append(index) } }
        vm.dbgGenerate(0)
        try await waitUntil { fixture.requests.contains(texts[6]) }
        XCTAssertLessThanOrEqual(vm.currentParagraphIndex, 1,
                                 "A depth-one strategy cannot request paragraph six this early")
        try await waitUntil { vm.dbgKindleReadyIndices.contains(6) }
        XCTAssertLessThanOrEqual(vm.currentParagraphIndex, 4,
                                 "Delayed target must be ready at least two predecessors before its boundary")
        try await waitUntil(timeout: 15) { vm.isFinished }
        XCTAssertEqual(completed, Array(0..<9))
        for text in texts { XCTAssertEqual(fixture.requests.filter { $0 == text }.count, 1) }
        XCTAssertFalse(audio.hasTerminalPlaybackFailure)
    }
    func testOutOfOrderReadyReplansFromCurrentAnchorWithoutRecursiveWholePagePrefetch() async throws {
        let texts = (0..<12).map { "Paragraph \($0) " + Array(repeating: "word", count: 45).joined(separator: " ") }
        let fixture = ReadAloudHTTPFixture { input, _ in
            let index = texts.firstIndex(of: input) ?? 0
            return .response(ReadAloudHTTPFixture.body(input, duration: index == 0 ? 2 : 0.2),
                             delay: index == 1 ? 0.4 : 0.02)
        }
        defer { fixture.close() }
        let audio = try player()
        let vm = ReadAloudViewModel(document: document(texts), audioService: audio, ttsService: fixture.service())
        defer { vm.deactivate(); audio.stop() }
        vm.dbgGenerate(0)
        try await waitUntil { vm.dbgKindleReadyIndices.count == 8 }
        XCTAssertEqual(vm.currentParagraphIndex, 0)
        XCTAssertEqual(vm.dbgKindlePrefetchIndices, Array(1...8))
        XCTAssertFalse(fixture.requests.contains(texts[9]))
        XCTAssertEqual(fixture.requests.count, 9)
    }
    func testOtherReaderSourcesRetainSingleParagraphPrefetch() async throws {
        let texts = (0..<10).map { "Paragraph \($0)." }
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 2))
        }
        defer { fixture.close() }
        let audio = try player()
        let vm = ReadAloudViewModel(document: document(texts, source: .text),
                                   audioService: audio, ttsService: fixture.service())
        defer { vm.deactivate(); audio.stop() }
        vm.dbgGenerate(0)
        try await waitUntil { vm.dbgPrefetchedIndex == 1 }
        XCTAssertEqual(vm.currentParagraphIndex, 0)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertTrue(vm.dbgKindlePrefetchIndices.isEmpty)
    }
}
