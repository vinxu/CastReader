import XCTest
@testable import CastReader

@MainActor
final class ReadAloudEntitlementPauseTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        useRegularVoiceForTest(language: "en")
    }

    @MainActor
    private final class ControlledRefresh {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        private(set) var returned = false

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
            returned = true
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func player() throws -> AudioPlayerService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AudioPlayerService(testTemporaryRoot: root)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(7)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out at the actual AVPlayer/refresh boundary")
    }

    func testFirstSessionClaimDoesNotTurnInitialAutoplayIntoUserPause() async throws {
        let audio = try player()
        defer { audio.stop(); audio.onPlaybackComplete = nil }
        let token = audio.claimPlaybackSession(owner: .readAloud)
        XCTAssertFalse(audio.isExplicitlyPaused)
        let segment = AudioSegment(
            paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 0.2),
            timestamps: [], duration: 0.2, text: "Alpha.", isWavFormat: true
        )
        var completed = 0
        audio.onPlaybackComplete = { completed += 1 }
        XCTAssertTrue(audio.loadSegment(segment, session: token))
        XCTAssertNotNil(audio.currentItemForTesting, "First claim must actually stage the WAV")
        try await waitUntil { completed == 1 }
        XCTAssertFalse(audio.hasTerminalPlaybackFailure)
        XCTAssertEqual(audio.currentSegment?.id, segment.id)
    }

    func testInternalRefreshAutomaticallyContinuesPreparedNonKindleSuccessor() async throws {
        try await verifyRefresh(pauseWhileWaiting: false)
    }

    func testUserPauseDuringRefreshWaitsForExplicitResumeBeforeSuccessor() async throws {
        try await verifyRefresh(pauseWhileWaiting: true)
    }

    private func verifyRefresh(pauseWhileWaiting: Bool) async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: input == "Alpha." ? 1.5 : 0.25))
        }
        defer { fixture.close() }
        let audio = try player()
        let document = ReadingDocument(
            title: "Local entitlement pause fixture", sourceKind: .text,
            language: "en", paragraphs: [
                ReadingParagraph(id: 0, text: "Alpha."),
                ReadingParagraph(id: 1, text: "Bravo.")
            ]
        )
        let vm = ReadAloudViewModel(document: document, audioService: audio, ttsService: fixture.service())
        let refresh = ControlledRefresh()
        defer {
            refresh.finish()
            vm.deactivate()
            audio.stop()
            audio.onPlaybackComplete = nil
            audio.onSegmentComplete = nil
        }
        var completed: [String] = []
        audio.onSegmentComplete = { if let text = audio.currentSegment?.text { completed.append(text) } }
        vm.dbgGenerate(0)
        let naturalCompletion = audio.onPlaybackComplete
        var refreshCount = 0
        // Inject only the async status refresh at a real natural audio boundary.
        // The VM's production refresh coordinator, ownership checks, advance,
        // cached successor promotion, and AVPlayer all remain in use. No Pro,
        // quota, account, or routing singleton is mutated by this fixture.
        audio.onPlaybackComplete = {
            if refreshCount == 0 {
                refreshCount += 1
                vm.dbgRefreshAccessThenRetryAdvance { await refresh.wait() }
            } else {
                naturalCompletion?()
            }
        }
        try await waitUntil { refresh.entered }
        try await waitUntil { vm.dbgPrefetchedIndex == 1 }
        XCTAssertEqual(completed, ["Alpha."])
        XCTAssertEqual(vm.currentParagraphIndex, 0)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.isExplicitlyPaused, "The internal gate pause is not a user Pause")
        XCTAssertTrue(vm.dbgIsAwaitingAccessRefresh)

        if pauseWhileWaiting {
            vm.togglePlayPause()
            XCTAssertTrue(audio.isExplicitlyPaused)
        }
        refresh.finish()
        try await waitUntil { refresh.returned && !vm.dbgIsAwaitingAccessRefresh }

        if pauseWhileWaiting {
            // Observe longer than Bravo's complete WAV duration, so an
            // accidental automatic start cannot hide behind a transient flag.
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(completed, ["Alpha."])
            XCTAssertEqual(vm.currentParagraphIndex, 0)
            XCTAssertFalse(audio.isPlaying)
            XCTAssertFalse(vm.isFinished)
            vm.togglePlayPause()
        }
        try await waitUntil { vm.isFinished }
        XCTAssertEqual(completed, ["Alpha.", "Bravo."])
        XCTAssertEqual(fixture.requests.filter { $0 == "Alpha." }.count, 1)
        XCTAssertEqual(fixture.requests.filter { $0 == "Bravo." }.count, 1)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(audio.hasTerminalPlaybackFailure)
    }
}
