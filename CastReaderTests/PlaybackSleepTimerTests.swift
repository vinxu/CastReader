import XCTest
@testable import CastReader

@MainActor
final class PlaybackSleepTimerTests: XCTestCase {
    func testAutomaticReaderResumeCannotClearExpiredTimer() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        defer { audio.clearForAccountBoundary() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let doc = ReadingDocument(id: "sleep-resume-fixture", title: "Fixture", sourceKind: .text,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: "A local timer test.", type: .paragraph)])
        let vm = ReadAloudViewModel(document: doc, historyStore: HistoryStore(directory: directory),
                                   speechGenerator: SleepTimerFixtureSpeech())
        defer { vm.deactivate() }
        audio.sleepTimer.start(after: 0.01)
        try await Task.sleep(for: .milliseconds(30))
        audio.sleepTimer.checkDeadline()
        vm.start()
        vm.ensurePlaying()
        XCTAssertTrue(audio.sleepTimer.requiresExplicitResume)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.hasQueuedSegments)
    }

    func testDeadlineUsesElapsedWallTimeAndExpiresOnlyOnce() {
        var now = Date(timeIntervalSince1970: 1000)
        let timer = PlaybackSleepTimer(now: { now }, schedulesTicks: false)
        var expirations = 0
        timer.onExpiration = { expirations += 1 }
        timer.start(after: 60)
        now.addTimeInterval(35.2)
        timer.checkDeadline()
        XCTAssertEqual(timer.remainingSeconds, 25)
        now.addTimeInterval(50)
        XCTAssertFalse(timer.permitsAutomaticPlayback())
        timer.checkDeadline()
        XCTAssertEqual(expirations, 1)
        XCTAssertFalse(timer.isActive)
        XCTAssertTrue(timer.requiresExplicitResume)
    }

    func testCancelAndReplacementDoNotFireOldDeadline() {
        var now = Date(timeIntervalSince1970: 1000)
        let timer = PlaybackSleepTimer(now: { now }, schedulesTicks: false)
        var expirations = 0
        timer.onExpiration = { expirations += 1 }
        timer.start(after: 10)
        now.addTimeInterval(5)
        timer.start(after: 60)
        now.addTimeInterval(10)
        timer.checkDeadline()
        XCTAssertEqual(timer.remainingSeconds, 50)
        timer.cancel()
        now.addTimeInterval(100)
        timer.checkDeadline()
        XCTAssertEqual(expirations, 0)
        XCTAssertTrue(timer.permitsAutomaticPlayback())
    }

    func testNewTimerAndCancellationCannotResumeExpiredPlayback() {
        var now = Date(timeIntervalSince1970: 1000)
        let timer = PlaybackSleepTimer(now: { now }, schedulesTicks: false)
        timer.start(after: 1)
        now.addTimeInterval(2)
        timer.checkDeadline()
        timer.start(after: 60)
        timer.cancel()
        XCTAssertFalse(timer.permitsAutomaticPlayback())
        timer.resumeByUser()
        XCTAssertTrue(timer.permitsAutomaticPlayback())
    }

    func testCloseClearsTimerAndExpiryLatch() {
        var now = Date(timeIntervalSince1970: 1000)
        let timer = PlaybackSleepTimer(now: { now }, schedulesTicks: false)
        timer.start(after: 1)
        now.addTimeInterval(2)
        timer.checkDeadline()
        timer.endPlaybackSession()
        XCTAssertFalse(timer.isActive)
        XCTAssertFalse(timer.requiresExplicitResume)
    }

    func testClockTimeRollsToTomorrowAndDisplaysHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 23, minute: 45))!
        let selection = calendar.date(bySettingHour: 23, minute: 30, second: 0, of: now)!
        let next = PlaybackSleepTimer.nextStopTime(selection, now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: next), 12)
        XCTAssertEqual(calendar.component(.hour, from: next), 23)
        let timer = PlaybackSleepTimer(now: { now }, schedulesTicks: false)
        timer.start(after: 3661)
        XCTAssertEqual(timer.countdown, "1:01:01")
    }

    func testLateAudioCannotStartAcrossReadExplainOwnershipOrQueueReplacement() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        defer { audio.clearForAccountBoundary() }
        let read = audio.claimPlaybackSession(owner: .readAloud)
        audio.sleepTimer.start(after: 0.01)
        try await Task.sleep(nanoseconds: 100_000_000)
        audio.sleepTimer.checkDeadline()
        XCTAssertTrue(audio.loadSegment(Self.segment(), session: read))
        XCTAssertFalse(audio.isPlaying)
        XCTAssertNil(audio.currentSegment)
        let explain = audio.claimPlaybackSession(owner: .explain)
        XCTAssertTrue(audio.loadSegments([Self.segment()], session: explain))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.play(session: explain))
        XCTAssertTrue(audio.togglePlayPause(session: explain))
        for _ in 0..<30 {
            if audio.isPlaying { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(audio.isPlaying)
    }

    func testExpirationPausesRealPlayerAndPreservesPosition() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        defer { audio.clearForAccountBoundary() }
        let token = audio.claimPlaybackSession(owner: .readAloud)
        XCTAssertTrue(audio.loadSegment(Self.segment(), session: token))
        for _ in 0..<30 {
            if audio.currentTime > 0.2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(audio.isPlaying)
        audio.sleepTimer.start(after: 0.3)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(audio.sleepTimer.requiresExplicitResume)
        XCTAssertFalse(audio.isPlaying)
        let position = audio.playbackPosition
        XCTAssertGreaterThan(position, 0.2)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(audio.playbackPosition, position, accuracy: 0.05)
        XCTAssertNotNil(audio.currentSegment)
        XCTAssertTrue(audio.togglePlayPause(session: token))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(audio.playbackPosition, position)
    }

    private static func segment() -> AudioSegment {
        AudioSegment(paragraphIndex: 0, segmentIndex: 0,
                     audioData: ReadingResumeFixtureSpeech.wav(), timestamps: [],
                     duration: 16, text: "Sleep timer playback test", isWavFormat: true)
    }
}
