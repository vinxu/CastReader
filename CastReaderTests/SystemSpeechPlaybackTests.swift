import XCTest
import AVFoundation
@testable import CastReader

@MainActor
final class SystemSpeechPlaybackTests: XCTestCase {
    func testAvailableReadingVoicesExcludeEffectsAndPreferSystemDefault() async throws {
        let voices = await SystemSpeechPlaybackService.availableVoices(language: "en-US")
        guard !voices.isEmpty else { throw XCTSkip("No English system voice installed in this test runtime") }
        for value in voices {
            let voice = try XCTUnwrap(AVSpeechSynthesisVoice(identifier: value.id))
            XCTAssertFalse(voice.voiceTraits.contains(.isNoveltyVoice), value.name)
            XCTAssertFalse(voice.voiceTraits.contains(.isPersonalVoice), value.name)
        }
        if let preferred = AVSpeechSynthesisVoice(language: "en-US"), voices.contains(where: { $0.id == preferred.identifier }) {
            XCTAssertEqual(voices.first?.id, preferred.identifier)
        }
    }

    private final class Driver: SystemSpeechDriving {
        var onEvent: ((SystemSpeechDriverEvent) -> Void)?
        var requests: [SystemSpeechRequest] = []
        var pauseWorks = true
        var preparationError: Error?
        var resumed = 0
        func prepare() throws { if let preparationError { throw preparationError } }
        func speak(_ request: SystemSpeechRequest) throws { requests.append(request) }
        func pause() -> Bool { pauseWorks }
        func resume() -> Bool { resumed += 1; return true }
        func stop() {}
        func emit(_ event: SystemSpeechDriverEvent) { onEvent?(event) }
    }

    func testSourceOffsetsSurviveEmojiCJKAndLeadingWhitespace() {
        let source = "  Hello 👨‍👩‍👧‍👦.  第二句测试。 下一句。"
        let units = SystemSpeechTextPlan.units(paragraphID: 7, text: source)
        XCTAssertFalse(units.isEmpty)
        for unit in units {
            XCTAssertEqual((source as NSString).substring(with: unit.sourceRange), unit.text)
            XCTAssertEqual(unit.paragraphID, 7)
            let full = NSRange(location: 0, length: unit.text.utf16.count)
            XCTAssertEqual(SystemSpeechTextPlan.sourceRange(full, in: unit), unit.sourceRange)
        }
        let first = units[0]
        XCTAssertNil(SystemSpeechTextPlan.sourceRange(NSRange(location: NSNotFound, length: 1), in: first))
        XCTAssertNil(SystemSpeechTextPlan.sourceRange(NSRange(location: 0, length: first.text.utf16.count + 1), in: first))
    }

    func testAudioSessionFailureCanRetryWithoutLeavingQueuedSpeech() {
        let driver = Driver()
        let speech = SystemSpeechPlaybackService(driver: driver)
        driver.preparationError = NSError(domain: NSOSStatusErrorDomain, code: -50)
        speech.load(SystemSpeechTextPlan.units(paragraphID: 0, text: "Retry safely."), voiceID: "test")
        speech.play()
        XCTAssertEqual(speech.errorCode, "system_speech_audio_session_-50")
        XCTAssertTrue(driver.requests.isEmpty)
        driver.preparationError = nil
        speech.play()
        XCTAssertEqual(speech.state, .preparing)
        XCTAssertNil(speech.errorCode)
        XCTAssertEqual(driver.requests.count, 1)
    }

    func testLongSentenceBoundKeepsEveryNonWhitespaceCharacter() {
        let source = String(repeating: "你好🙂", count: 80)
        let units = SystemSpeechTextPlan.units(paragraphID: 0, text: source, maximumLength: 31)
        XCTAssertTrue(units.allSatisfy { $0.text.count <= 31 })
        XCTAssertEqual(units.map(\.text).joined(), source)
    }

    func testQueueRemainsBoundedAndRefillsOnCompletion() {
        let driver = Driver()
        let service = SystemSpeechPlaybackService(driver: driver)
        let units = (0..<10).map { SystemSpeechUnit(paragraphID: $0, sourceRange: NSRange(location: 0, length: 5), text: "Hello") }
        service.load(units, voiceID: "local-test")
        service.play()
        XCTAssertEqual(driver.requests.count, 3)
        driver.emit(.started(driver.requests[0].id))
        driver.emit(.finished(driver.requests[0].id))
        XCTAssertEqual(driver.requests.count, 4)
    }

    func testStopAndSeekRejectAllOldCallbacks() {
        let driver = Driver()
        let service = SystemSpeechPlaybackService(driver: driver)
        service.load(SystemSpeechTextPlan.units(paragraphID: 0, text: "First sentence. Second sentence."), voiceID: "local-test")
        service.play()
        let old = driver.requests[0].id
        driver.emit(.started(old))
        driver.emit(.range(old, NSRange(location: 0, length: 5)))
        service.seek(to: 1, autoplay: false)
        driver.emit(.range(old, NSRange(location: 6, length: 8)))
        driver.emit(.finished(old))
        driver.emit(.cancelled(old))
        XCTAssertEqual(service.state, .paused)
        XCTAssertEqual(service.currentUnitIndex, 1)
        XCTAssertNil(service.highlightRange)
        service.stop()
        driver.emit(.started(old))
        XCTAssertEqual(service.state, .idle)
    }

    func testPauseBeforeFirstCallbackCannotAutostart() {
        let driver = Driver()
        let service = SystemSpeechPlaybackService(driver: driver)
        service.load(SystemSpeechTextPlan.units(paragraphID: 0, text: "A delayed voice."), voiceID: "local-test")
        service.play()
        let old = driver.requests[0].id
        service.pause()
        driver.emit(.started(old))
        XCTAssertEqual(service.state, .paused)
        service.play()
        XCTAssertNotEqual(driver.requests.last?.id, old)
        XCTAssertEqual(service.state, .preparing)
    }

    func testCompletionInFlightAfterPauseCannotSkipOrRefill() {
        let driver = Driver()
        let service = SystemSpeechPlaybackService(driver: driver)
        let units = (0..<6).map { SystemSpeechUnit(paragraphID: $0, sourceRange: NSRange(location: 0, length: 5), text: "Hello") }
        service.load(units, voiceID: "local-test")
        service.play()
        let old = driver.requests[0].id
        driver.emit(.started(old))
        service.pause()
        driver.emit(.finished(old))
        driver.emit(.started(driver.requests[1].id))
        XCTAssertEqual(service.state, .paused)
        XCTAssertEqual(service.currentUnitIndex, 0)
        XCTAssertEqual(driver.requests.count, 3)
        service.play()
        XCTAssertEqual(driver.resumed, 0)
        XCTAssertEqual(driver.requests[3].text, units[0].text)
        XCTAssertEqual(service.state, .preparing)
    }

    func testNewPlaybackOwnerAndAccountBoundaryStopSystemSpeech() {
        let driver = Driver()
        let speech = SystemSpeechPlaybackService(driver: driver)
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        speech.load(SystemSpeechTextPlan.units(paragraphID: 1, text: "A sentence."), voiceID: "test-local")
        speech.connectPlayback(title: "Saved page", audio: audio)
        speech.play()
        let old = driver.requests[0].id
        driver.emit(.started(old))
        XCTAssertTrue(audio.isPlaying)
        _ = audio.claimPlaybackSession(owner: .explain)
        XCTAssertEqual(speech.state, .idle)
        driver.emit(.range(old, NSRange(location: 0, length: 1)))
        XCTAssertNil(speech.highlightRange)
        speech.play()
        driver.emit(.started(driver.requests.last!.id))
        audio.clearForAccountBoundary()
        XCTAssertEqual(speech.state, .idle)
        XCTAssertFalse(audio.isPlaying)
        speech.closePlayback()
    }

    func testSharedSleepTimerPausesSystemSpeechAndRequiresExplicitPlay() async throws {
        let driver = Driver()
        let service = SystemSpeechPlaybackService(driver: driver)
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        service.load(SystemSpeechTextPlan.units(paragraphID: 1, text: "First sentence. Second sentence."), voiceID: "test-local")
        service.connectPlayback(title: "Saved page", audio: audio)
        service.play()
        driver.emit(.started(driver.requests[0].id))
        audio.sleepTimer.start(after: 0.01)
        try await Task.sleep(for: .milliseconds(25))
        audio.sleepTimer.checkDeadline()
        XCTAssertEqual(service.state, .paused)
        XCTAssertTrue(audio.sleepTimer.requiresExplicitResume)
        let count = driver.requests.count
        service.seek(to: 1, autoplay: true)
        XCTAssertEqual(driver.requests.count, count)
        XCTAssertEqual(service.state, .paused)
        service.play()
        XCTAssertFalse(audio.sleepTimer.requiresExplicitResume)
        XCTAssertEqual(service.state, .preparing)
        service.closePlayback()
    }

    func testActualRangesOnlyAndRateChangeRequeuesCurrentWord() {
        let driver = Driver()
        var time = 10.0
        let service = SystemSpeechPlaybackService(driver: driver, now: { time })
        service.load(SystemSpeechTextPlan.units(paragraphID: 4, text: "  First sentence. Second sentence."), voiceID: "local-test")
        service.play()
        let old = driver.requests[0].id
        time = 10.25
        driver.emit(.started(old))
        XCTAssertEqual(service.firstSpeechMilliseconds, 250)
        XCTAssertNil(service.highlightRange)
        driver.emit(.range(old, NSRange(location: 0, length: 5)))
        XCTAssertEqual(service.highlightRange, NSRange(location: 2, length: 5))
        service.setRate(0.6)
        XCTAssertEqual(service.currentUnitIndex, 0)
        XCTAssertEqual(service.state, .preparing)
        driver.emit(.cancelled(old))
        XCTAssertNil(service.errorCode)
        XCTAssertEqual(driver.requests.last?.rate, 0.6)
    }

    func testRateChangesRetainCurrentWordAcrossEmojiRapidChangesAndPause() {
        let driver = Driver()
        let speech = SystemSpeechPlaybackService(driver: driver)
        let text = "Hello 👋 world again."
        let word = (text as NSString).range(of: "world")
        speech.load([SystemSpeechUnit(paragraphID: 9, sourceRange: NSRange(location: 11, length: text.utf16.count), text: text)], voiceID: "local")
        speech.play()
        let old = driver.requests[0].id
        driver.emit(.started(old)); driver.emit(.range(old, word))
        speech.setRate(0.65)
        let superseded = driver.requests.last!.id
        speech.setRate(0.4)
        let current = driver.requests.last!
        XCTAssertEqual(current.text, "world again.")
        XCTAssertEqual(current.rate, 0.4)
        driver.emit(.finished(old)); driver.emit(.cancelled(superseded))
        driver.emit(.started(current.id)); driver.emit(.range(current.id, NSRange(location: 0, length: 5)))
        XCTAssertEqual(speech.highlightRange, NSRange(location: 11 + word.location, length: 5))
        XCTAssertEqual(speech.activeRate, 0.4)
        speech.pause(); speech.setRate(0.6)
        XCTAssertEqual(speech.state, .paused)
        speech.play()
        XCTAssertEqual(driver.requests.last?.text, "world again.")
        XCTAssertEqual(driver.resumed, 0)
        XCTAssertNil(speech.errorCode)
    }

    func testNativeSpeechRateChangesActualDurationAndActiveUtterance() async throws {
        let available = await SystemSpeechPlaybackService.availableVoices(language: "en-US")
        let voice = try XCTUnwrap(available.first)
        let speech = SystemSpeechPlaybackService()
        defer { speech.stop() }
        let text = "One small step changes the reading speed. Every word stays in its original order."
        let unit = SystemSpeechUnit(paragraphID: 0, sourceRange: NSRange(location: 0, length: text.utf16.count), text: text)
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(condition(), "Native speech stalled: \(speech.state), \(speech.errorCode ?? "none")")
        }
        func duration(rate: Float) async throws -> Double {
            speech.load([unit], voiceID: voice.id); speech.setRate(rate); speech.play()
            try await waitUntil { speech.state == .speaking }
            XCTAssertEqual(speech.activeRate, rate)
            let began = ProcessInfo.processInfo.systemUptime
            try await waitUntil { speech.state == .finished }
            return ProcessInfo.processInfo.systemUptime - began
        }
        let slow = try await duration(rate: 0.35)
        let fast = try await duration(rate: 0.65)
        XCTAssertGreaterThan(slow, fast * 1.25, "Changing native rate must change real speaking duration")
        print("OFFLINE_NATIVE_RATE slowMs=\(Int(slow * 1000)) fastMs=\(Int(fast * 1000))")
        speech.load([unit], voiceID: voice.id); speech.setRate(0.35); speech.play()
        try await waitUntil { speech.callbackCount >= 3 }
        let location = try XCTUnwrap(speech.highlightRange).location
        speech.setRate(0.65)
        try await waitUntil { speech.activeRate == 0.65 && speech.state == .speaking && speech.highlightRange != nil }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(speech.highlightRange).location, location)
        XCTAssertEqual(speech.currentUnitIndex, 0)
    }

    func testAutomaticNextPageCannotClearSleepDeadlineOrReclaimAnotherReader() async throws {
        let driver = Driver()
        let speech = SystemSpeechPlaybackService(driver: driver)
        let audio = AudioPlayerService(testTemporaryRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let first = SystemSpeechTextPlan.units(paragraphID: 1, text: "The first saved page.")
        let second = SystemSpeechTextPlan.units(paragraphID: 2, text: "The next saved page.")
        speech.load(first, voiceID: "local")
        speech.connectPlayback(title: "Offline book", audio: audio)
        speech.play()
        driver.emit(.started(driver.requests[0].id))
        driver.emit(.finished(driver.requests[0].id))
        audio.sleepTimer.start(after: 0.01)
        try await Task.sleep(for: .milliseconds(25))
        audio.sleepTimer.checkDeadline()
        speech.load(second, voiceID: "local")
        let count = driver.requests.count
        speech.playAutomatically()
        XCTAssertEqual(driver.requests.count, count)
        XCTAssertTrue(audio.sleepTimer.requiresExplicitResume)
        speech.play()
        XCTAssertGreaterThan(driver.requests.count, count)
        _ = audio.claimPlaybackSession(owner: .explain)
        speech.load(first, voiceID: "local")
        let afterTransfer = driver.requests.count
        speech.playAutomatically()
        XCTAssertEqual(driver.requests.count, afterTransfer)
        speech.closePlayback()
    }
}
