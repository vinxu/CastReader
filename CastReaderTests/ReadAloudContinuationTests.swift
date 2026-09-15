import XCTest
import AVFoundation
@testable import CastReader

extension XCTestCase {
    /// Keep preset transport fixtures independent from saved clone selections.
    @MainActor
    func useRegularVoiceForTest(language: String) {
        let settings = AppSettings.shared
        let previous = settings.voice(for: language)
        XCTAssertTrue(settings.setVoice(VoiceCatalog.resolvedVoice(preferred: "", for: language), for: language))
        addTeardownBlock {
            await MainActor.run {
                if previous.hasPrefix("vc_") {
                    settings.setActiveClonedVoice(previous, for: language)
                } else {
                    settings.setVoice(previous, for: language)
                }
            }
        }
    }
}

/// Each fixture has its own URLSession and registry key. These are controlled
/// HTTP responses through URLProtocol, not a claim about an online TTS service.
final class ReadAloudHTTPFixture {
    enum Reply {
        case response(Data, status: Int = 200, delay: Double = 0)
        case failure(URLError.Code, delay: Double = 0)
    }
    private let lock = NSLock()
    private var inputs: [String] = []
    private let responder: (String, Int) -> Reply
    let id = UUID().uuidString
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReadAloudFixtureURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Reader-Fixture": id]
        return URLSession(configuration: config)
    }()
    init(_ responder: @escaping (String, Int) -> Reply) {
        self.responder = responder
        ReadAloudFixtureURLProtocol.register(self)
    }
    func close() {
        session.invalidateAndCancel()
        ReadAloudFixtureURLProtocol.unregister(id)
    }
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return inputs
    }
    fileprivate func reply(_ input: String) -> Reply {
        lock.lock(); defer { lock.unlock() }
        inputs.append(input)
        return responder(input, inputs.filter { $0 == input }.count)
    }
    func service() -> TTSService { TTSService(api: APIService(session: session)) }

    static func wav(duration: Double) -> Data {
        func little<T: FixedWidthInteger>(_ value: T) -> Data {
            var copy = value.littleEndian
            return withUnsafeBytes(of: &copy) { Data($0) }
        }
        let samples = Int(duration * 8_000)
        let count = UInt32(samples * 2)
        var data = Data("RIFF".utf8)
        data += little(36 + count); data += Data("WAVEfmt ".utf8)
        data += little(UInt32(16)); data += little(UInt16(1)); data += little(UInt16(1))
        data += little(UInt32(8_000)); data += little(UInt32(16_000))
        data += little(UInt16(2)); data += little(UInt16(16))
        data += Data("data".utf8); data += little(count)
        for i in 0..<samples {
            data += little(Int16(sin(Double(i) * 2 * .pi * 330 / 8_000) * 200))
        }
        return data
    }
    static func body(_ text: String, tail: String = "", duration: Double = 0.3) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "audio": wav(duration: duration).base64EncodedString(),
            "audio_format": "wav", "processed_text": text,
            "unprocessed_text": tail, "duration": duration,
            "timestamps": [["word": text, "start_time": 0, "end_time": duration]],
        ])
    }
}

private final class ReadAloudFixtureURLProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var fixtures: [String: ReadAloudHTTPFixture] = [:]
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false
    static func register(_ fixture: ReadAloudHTTPFixture) {
        registryLock.lock(); defer { registryLock.unlock() }
        fixtures[fixture.id] = fixture
    }
    static func unregister(_ id: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        fixtures.removeValue(forKey: id)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.registryLock.lock()
        let fixture = Self.fixtures[request.value(forHTTPHeaderField: "X-Reader-Fixture") ?? ""]
        Self.registryLock.unlock()
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reply = fixture.reply(object?["input"] as? String ?? "MISSING_INPUT")
        let delay: Double
        switch reply {
        case .response(_, _, let value), .failure(_, let value): delay = value
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.deliveryLock.lock(); defer { self.deliveryLock.unlock() }
            guard !self.stopped else { return }
            switch reply {
            case .response(let data, let status, _):
                let response = HTTPURLResponse(url: self.request.url!, statusCode: status,
                                               httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            case .failure(let code, _):
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        }
    }
    override func stopLoading() {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        stopped = true
    }
}

@MainActor
final class ReadAloudContinuationTests: XCTestCase {
    private func audio() throws -> AudioPlayerService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AudioPlayerService(testTemporaryRoot: root)
    }
    private func document(_ texts: [String], language: String = "en") -> ReadingDocument {
        // The simulator may retain a community voice from UI testing. These
        // offline transport fixtures require the anonymous preset endpoint.
        let settings = AppSettings.shared
        let previous = settings.voice(for: language)
        if language == "en" {
            settings.clearActiveClonedVoice(for: language)
            settings.setVoice("af_heart", for: language)
            addTeardownBlock {
                await MainActor.run {
                    if previous.hasPrefix("vc_") { settings.setActiveClonedVoice(previous, for: language) }
                    else { settings.setVoice(previous, for: language) }
                }
            }
        }
        return ReadingDocument(title: "Offline continuation fixture", sourceKind: .kindle,
                        language: language,
                        paragraphs: texts.enumerated().map { ReadingParagraph(id: $0.offset, text: $0.element) })
    }
    private func waitUntil(timeout: Double = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate(), "Timed out waiting for the real player/HTTP boundary")
    }
    private func verifyTailRetry(timeoutFailure: Bool, failureAfterDrain: Bool) async throws {
        let prefixDuration = failureAfterDrain ? 0.15 : 1.0
        let fixture = ReadAloudHTTPFixture { input, attempt in
            if input == "Alpha. Bravo." {
                return .response(ReadAloudHTTPFixture.body("Alpha. ", tail: "Bravo.", duration: prefixDuration))
            }
            if input == "Bravo.", attempt == 1 {
                if timeoutFailure { return .failure(.timedOut, delay: failureAfterDrain ? 0.3 : 0) }
                return .response(Data("{}".utf8), status: 500, delay: failureAfterDrain ? 0.3 : 0)
            }
            return .response(ReadAloudHTTPFixture.body(input))
        }
        defer { fixture.close() }
        let player = try audio()
        let vm = ReadAloudViewModel(document: document(["Alpha. Bravo.", "Charlie."]),
                                   audioService: player, ttsService: fixture.service())
        defer { vm.deactivate(); player.stop() }
        var completed: [String] = []
        player.onSegmentComplete = { if let text = player.currentSegment?.text { completed.append(text) } }
        var finished = 0
        vm.onDocumentFinished = { _ in finished += 1 }
        vm.dbgGenerate(0)
        try await waitUntil { if case .error = vm.status { return true }; return false }
        try await waitUntil { completed.contains("Alpha. ") }
        XCTAssertEqual(vm.currentParagraphIndex, 0)
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(completed, ["Alpha. "])
        XCTAssertTrue(player.moreSegmentsExpected)
        vm.togglePlayPause()
        try await waitUntil { finished == 1 }
        XCTAssertEqual(fixture.requests.filter { $0 == "Alpha. Bravo." }.count, 1)
        XCTAssertEqual(fixture.requests.filter { $0 == "Bravo." }.count, 2,
                       "One failed dispatch, then one explicit tail retry without automatic replay")
        XCTAssertEqual(completed, ["Alpha. ", "Bravo.", "Charlie."])
        XCTAssertFalse(player.hasTerminalPlaybackFailure)
    }
    func testHTTP500BeforePrefixEndsCannotSkipTailAndRetryDoesNotReplayPrefix() async throws {
        try await verifyTailRetry(timeoutFailure: false, failureAfterDrain: false)
    }
    func testTimeoutAfterPrefixDrainsRetriesOnlyMissingTail() async throws {
        try await verifyTailRetry(timeoutFailure: true, failureAfterDrain: true)
    }
    func testPauseWhileFailedTailPrefixIsStillPlayingDoesNotTriggerRetry() async throws {
        let fixture = ReadAloudHTTPFixture { input, attempt in
            if input == "Alpha. Bravo." {
                return .response(ReadAloudHTTPFixture.body("Alpha. ", tail: "Bravo.", duration: 2))
            }
            if input == "Bravo.", attempt == 1 { return .response(Data("{}".utf8), status: 500) }
            return .response(ReadAloudHTTPFixture.body(input))
        }
        defer { fixture.close() }
        let player = try audio()
        let vm = ReadAloudViewModel(document: document(["Alpha. Bravo."]),
                                   audioService: player, ttsService: fixture.service())
        defer { vm.deactivate(); player.stop() }
        vm.dbgGenerate(0)
        try await waitUntil { if case .error = vm.status { return player.isPlaying && player.currentTime > 0 }; return false }
        vm.togglePlayPause()
        XCTAssertFalse(player.isPlaying)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fixture.requests.filter { $0 == "Bravo." }.count, 1)
        let pausedAt = player.currentTime
        vm.ensurePlaying()
        try await waitUntil { vm.isFinished }
        XCTAssertGreaterThan(pausedAt, 0)
        XCTAssertEqual(fixture.requests.filter { $0 == "Alpha. Bravo." }.count, 1)
        XCTAssertEqual(fixture.requests.filter { $0 == "Bravo." }.count, 2)
    }
    func testLocalSentenceCheckpointRetainsLaterUnstartedUnits() async throws {
        let text = "第一句。第二句。第三句。"
        let fixture = ReadAloudHTTPFixture { input, attempt in
            if input == "第二句。", attempt == 1 { return .response(Data("{}".utf8), status: 500) }
            return .response(ReadAloudHTTPFixture.body(input, duration: 0.15))
        }
        defer { fixture.close() }
        let tts = fixture.service()
        var checkpoint: TTSContinuation?
        var segments: [AudioSegment] = []
        do {
            try await tts.generateTTSForParagraph(paragraphIndex: 0, text: text, language: "zh",
                onCheckpoint: { checkpoint = $0 }, onSegmentReady: { segments.append($0) })
            XCTFail("The second local sentence should fail")
        } catch { XCTAssertEqual(segments.map(\.text), ["第一句。"]) }
        let saved = try XCTUnwrap(checkpoint)
        XCTAssertEqual(saved.requestUnits, ["第二句。", "第三句。"])
        XCTAssertEqual(saved.nextSegmentIndex, 1)
        try await tts.generateTTSForParagraph(paragraphIndex: 0, text: text, language: "zh",
            continuation: saved, onSegmentReady: { segments.append($0) })
        XCTAssertEqual(segments.map(\.text), ["第一句。", "第二句。", "第三句。"])
        XCTAssertEqual(segments.map(\.segmentIndex), [0, 1, 2])
        XCTAssertEqual(fixture.requests.filter { $0 == "第一句。" }.count, 1)
    }
    func testPauseWhilePrefetchIsInFlightWaitsForExplicitResumeWithoutDuplicateRequest() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 0.2), delay: input == "Bravo." ? 1.1 : 0)
        }
        defer { fixture.close() }
        let player = try audio()
        let vm = ReadAloudViewModel(document: document(["Alpha.", "Bravo."]),
                                   audioService: player, ttsService: fixture.service())
        defer { vm.deactivate(); player.stop() }
        vm.dbgGenerate(0)
        try await waitUntil { vm.status.isLoading && player.currentSegment != nil && !player.isPlaying }
        vm.togglePlayPause()
        try await waitUntil { vm.dbgPrefetchedIndex == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(vm.currentParagraphIndex, 0)
        vm.ensurePlaying()
        try await waitUntil { vm.isFinished }
        XCTAssertEqual(fixture.requests.filter { $0 == "Bravo." }.count, 1)
    }
    func testPauseAndResumeFirstRequestPreservesItsProducer() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            .response(ReadAloudHTTPFixture.body(input, duration: 0.3), delay: 0.6)
        }
        defer { fixture.close() }
        let player = try audio()
        let vm = ReadAloudViewModel(document: document(["Alpha."]),
                                   audioService: player, ttsService: fixture.service())
        defer { vm.deactivate(); player.stop() }
        vm.dbgGenerate(0)
        try await waitUntil { fixture.requests.count == 1 }
        vm.togglePlayPause()
        try await waitUntil { vm.status == .ready }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(fixture.requests.count, 1)
        vm.ensurePlaying()
        try await waitUntil { vm.isFinished }
        XCTAssertEqual(fixture.requests.count, 1)
    }
    func testDeactivateRejectsLateTailAndOldSessionCannotResume() async throws {
        let fixture = ReadAloudHTTPFixture { input, _ in
            if input == "Alpha. Bravo." {
                return .response(ReadAloudHTTPFixture.body("Alpha. ", tail: "Bravo.", duration: 0.3))
            }
            return .response(ReadAloudHTTPFixture.body(input), delay: 0.6)
        }
        defer { fixture.close() }
        let player = try audio()
        let vm = ReadAloudViewModel(document: document(["Alpha. Bravo."]),
                                   audioService: player, ttsService: fixture.service())
        defer { vm.deactivate(); player.stop() }
        vm.dbgGenerate(0)
        try await waitUntil { fixture.requests.contains("Bravo.") }
        let oldSession = try XCTUnwrap(player.activePlaybackSession)
        vm.deactivate()
        let newSession = player.claimPlaybackSession(owner: .explain)
        XCTAssertTrue(player.clearQueue(session: newSession))
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasQueuedSegments)
        XCTAssertFalse(player.play(session: oldSession))
        XCTAssertEqual(player.activePlaybackSession, newSession)
    }
}

@MainActor
final class AudioStreamingPauseIntentTests: XCTestCase {
    func testSeekingBackAfterCompletedQueueReplaysCurrentItemAndCompletesAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        var completions = 0
        player.onPlaybackComplete = { completions += 1 }
        XCTAssertTrue(player.loadSegments([AudioSegment(
            paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 0.4),
            timestamps: [], duration: 0.4, text: "Replay this sentence", isWavFormat: true
        )], session: token))
        for _ in 0..<150 where completions == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(player.pause(session: token))
        XCTAssertTrue(player.seek(to: 0.1, session: token))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(player.isPlaying, "Seeking must preserve an explicit Pause")
        XCTAssertTrue(player.play(session: token))
        for _ in 0..<150 where completions < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completions, 2, "A completed sentence must be replayable after seeking back")
        XCTAssertTrue(player.play(session: token))
        XCTAssertEqual(completions, 2, "The replay must deliver its completion only once")
    }

    func testSeekingBackAtStreamingBoundaryReplaysPrefixBeforeQueuedTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        XCTAssertTrue(player.clearQueue(session: token))
        XCTAssertTrue(player.setMoreSegmentsExpected(true, session: token))
        func segment(_ index: Int) -> AudioSegment {
            AudioSegment(paragraphIndex: 0, segmentIndex: index,
                         audioData: ReadAloudHTTPFixture.wav(duration: 0.4),
                         timestamps: [], duration: 0.4, text: "Part \(index)", isWavFormat: true)
        }
        var completed: [Int] = []
        player.onSegmentComplete = { completed.append(player.currentSegment!.segmentIndex) }
        XCTAssertTrue(player.loadSegment(segment(0), session: token))
        for _ in 0..<150 where !player.isWaitingForNextSegment { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(player.isWaitingForNextSegment)
        XCTAssertTrue(player.pause(session: token))
        XCTAssertTrue(player.skipBackward(seconds: 15, session: token))
        XCTAssertFalse(player.isWaitingForNextSegment, "The user now owns a replay of the current item")
        XCTAssertTrue(player.loadSegment(segment(1), session: token))
        XCTAssertTrue(player.finishStreamingProducer(session: token))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(completed, [0])
        XCTAssertTrue(player.play(session: token))
        for _ in 0..<150 where completed.count < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completed, [0, 0, 1], "Back must replay the prefix before consuming the late tail")
    }

    func testImmediatePlayAfterRewindWaitsForTheRequestedPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        var completions = 0
        player.onPlaybackComplete = { completions += 1 }
        XCTAssertTrue(player.loadSegments([AudioSegment(
            paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 1),
            timestamps: [], duration: 1, text: "Resume near the end", isWavFormat: true
        )], session: token))
        for _ in 0..<150 where completions == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(player.pause(session: token))
        var playbackStarts: [Double] = []
        let observation = player.$isPlaying.filter { $0 }.sink { _ in playbackStarts.append(player.currentTime) }
        defer { observation.cancel() }
        XCTAssertTrue(player.seek(to: 0.75, session: token))
        XCTAssertTrue(player.play(session: token))
        for _ in 0..<150 where completions < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completions, 2)
        XCTAssertFalse(playbackStarts.isEmpty)
        XCTAssertTrue(playbackStarts.allSatisfy { $0 >= 0.70 }, "Play must not emit the sentence start before restoration: \(playbackStarts)")
        XCTAssertTrue(player.seek(to: 0.1, session: token))
        XCTAssertTrue(player.clearQueue(session: token))
        XCTAssertFalse(player.play(session: token), "Cancelling restoration must not leave an empty queue waiting for a seek")
    }

    func testLateStreamingTailHonorsPauseAndResumeStartsTailOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        XCTAssertTrue(player.clearQueue(session: token))
        XCTAssertTrue(player.setMoreSegmentsExpected(true, session: token))
        func segment(_ index: Int) -> AudioSegment {
            AudioSegment(paragraphIndex: 0, segmentIndex: index,
                         audioData: ReadAloudHTTPFixture.wav(duration: 0.2),
                         timestamps: [], duration: 0.2, text: "Part \(index)", isWavFormat: true)
        }
        var completed: [Int] = []
        player.onSegmentComplete = { if let index = player.currentSegment?.segmentIndex { completed.append(index) } }
        XCTAssertTrue(player.loadSegment(segment(0), session: token))
        for _ in 0..<100 where !player.isWaitingForNextSegment { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(player.isWaitingForNextSegment)
        XCTAssertTrue(player.pause(session: token))
        XCTAssertTrue(player.loadSegment(segment(1), session: token))
        XCTAssertTrue(player.finishStreamingProducer(session: token))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(completed, [0])
        XCTAssertTrue(player.play(session: token))
        for _ in 0..<100 where completed.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completed, [0, 1])
    }
    func testPauseInsideNaturalEndCallbackDoesNotStartAlreadyQueuedTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        let segments = (0...1).map { index in
            AudioSegment(paragraphIndex: 0, segmentIndex: index,
                         audioData: ReadAloudHTTPFixture.wav(duration: 0.15),
                         timestamps: [], duration: 0.15, text: "Part \(index)", isWavFormat: true)
        }
        var completed: [Int] = []
        player.onSegmentComplete = {
            completed.append(player.currentSegment!.segmentIndex)
            if completed.count == 1 { _ = player.pause(session: token) }
        }
        XCTAssertTrue(player.loadSegments(segments, session: token))
        for _ in 0..<100 where completed.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(completed, [0])
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.play(session: token))
        for _ in 0..<100 where completed.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completed, [0, 1])
    }

    func testPauseBeforeDeferredSuccessfulDrainDefersCompletionUntilResumeExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        XCTAssertTrue(player.clearQueue(session: token))
        XCTAssertTrue(player.setMoreSegmentsExpected(true, session: token))
        var completions = 0
        player.onPlaybackComplete = { completions += 1 }
        XCTAssertTrue(player.loadSegment(AudioSegment(
            paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 0.15),
            timestamps: [], duration: 0.15, text: "Alpha", isWavFormat: true
        ), session: token))
        for _ in 0..<100 where !player.isWaitingForNextSegment { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(player.isWaitingForNextSegment)
        XCTAssertTrue(player.finishStreamingProducer(session: token))
        XCTAssertTrue(player.pause(session: token))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(player.play(session: token))
        XCTAssertTrue(player.play(session: token))
        XCTAssertEqual(completions, 1)
    }

    func testPausedCrossPageGateDoesNotReleaseUntilExplicitPlay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        let segments = (0...1).map { index in
            AudioSegment(paragraphIndex: index, segmentIndex: 0,
                         audioData: ReadAloudHTTPFixture.wav(duration: 0.15),
                         timestamps: [], duration: 0.15, text: "Page \(index)", isWavFormat: true)
        }
        var gateOpen = false
        var completed: [Int] = []
        player.canStartQueuedSegment = { $0.paragraphIndex == 0 || gateOpen }
        player.onSegmentComplete = {
            XCTAssertFalse(player.isPlaying, "Natural completion must publish its terminal state before callbacks")
            completed.append(player.currentSegment!.paragraphIndex)
        }
        XCTAssertTrue(player.loadSegments(segments, session: token))
        for _ in 0..<100 where !player.isQueuedSegmentGated { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(player.isQueuedSegmentGated)
        XCTAssertTrue(player.pause(session: token))
        gateOpen = true
        player.resumeGatedSegmentIfPossible(session: token)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(completed, [0])
        XCTAssertTrue(player.play(session: token))
        for _ in 0..<100 where completed.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completed, [0, 1])
    }

    func testAppendingPreparedPageWhilePausedRetainsItWithoutAutoplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        XCTAssertTrue(player.clearQueue(session: token))
        XCTAssertTrue(player.setMoreSegmentsExpected(true, session: token))
        func segment(_ index: Int) -> AudioSegment {
            AudioSegment(paragraphIndex: index, segmentIndex: 0,
                         audioData: ReadAloudHTTPFixture.wav(duration: 0.15),
                         timestamps: [], duration: 0.15, text: "Page \(index)", isWavFormat: true)
        }
        var completed: [Int] = []
        player.onSegmentComplete = { completed.append(player.currentSegment!.paragraphIndex) }
        XCTAssertTrue(player.loadSegment(segment(0), session: token))
        for _ in 0..<100 where !player.isWaitingForNextSegment { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(player.isWaitingForNextSegment)
        XCTAssertTrue(player.pause(session: token))
        XCTAssertEqual(player.appendPreparedSegmentsForContinuousPlayback([segment(1)], session: token), "0-0")
        XCTAssertTrue(player.finishStreamingProducer(session: token))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(completed, [0])
        XCTAssertTrue(player.play(session: token))
        for _ in 0..<100 where completed.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completed, [0, 1])
    }

    func testExplicitNextAtPausedFinalItemStillAdvancesParagraphBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let player = AudioPlayerService(testTemporaryRoot: root)
        defer { player.stop(); try? FileManager.default.removeItem(at: root) }
        let token = player.claimPlaybackSession(owner: .readAloud)
        var completions = 0
        player.onPlaybackComplete = { completions += 1 }
        XCTAssertTrue(player.loadSegments([AudioSegment(
            paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 1),
            timestamps: [], duration: 1, text: "Alpha", isWavFormat: true
        )], session: token))
        XCTAssertTrue(player.pause(session: token))
        XCTAssertTrue(player.nextSegment(session: token))
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(player.isExplicitlyPaused)
    }

}
