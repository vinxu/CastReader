import AVFoundation
import Combine
import Foundation

/// Source ranges are retained before any speech is queued. The system speaks
/// these exact substrings, so UTF-16 callbacks never need estimated timestamps.
struct SystemSpeechUnit: Equatable {
    let paragraphID: Int
    let sourceRange: NSRange
    let text: String
}

enum SystemSpeechTextPlan {
    static func units(paragraphID: Int, text: String, maximumLength: Int = 500) -> [SystemSpeechUnit] {
        guard maximumLength > 0 else { return [] }
        var sentences: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) {
            _, range, _, _ in sentences.append(range)
        }
        if sentences.isEmpty, !text.isEmpty { sentences = [text.startIndex..<text.endIndex] }
        var result: [SystemSpeechUnit] = []
        for sentence in sentences {
            var start = sentence.lowerBound
            while start < sentence.upperBound {
                let end = text.index(start, offsetBy: maximumLength, limitedBy: sentence.upperBound) ?? sentence.upperBound
                var trimmedStart = start
                var trimmedEnd = end
                while trimmedStart < trimmedEnd, text[trimmedStart].isWhitespace {
                    trimmedStart = text.index(after: trimmedStart)
                }
                while trimmedEnd > trimmedStart, text[text.index(before: trimmedEnd)].isWhitespace {
                    trimmedEnd = text.index(before: trimmedEnd)
                }
                if trimmedStart < trimmedEnd {
                    let range = trimmedStart..<trimmedEnd
                    result.append(SystemSpeechUnit(paragraphID: paragraphID,
                        sourceRange: NSRange(range, in: text), text: String(text[range])))
                }
                start = end
            }
        }
        return result
    }

    static func sourceRange(_ spokenRange: NSRange, in unit: SystemSpeechUnit) -> NSRange? {
        guard spokenRange.location != NSNotFound, spokenRange.location >= 0,
              spokenRange.length > 0, spokenRange.location <= unit.text.utf16.count,
              spokenRange.length <= unit.text.utf16.count - spokenRange.location else { return nil }
        return NSRange(location: unit.sourceRange.location + spokenRange.location, length: spokenRange.length)
    }
}

struct SystemSpeechVoice: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
}

struct SystemSpeechRequest {
    let id: UUID
    let text: String
    let voiceID: String
    let rate: Float
}

enum SystemSpeechDriverEvent {
    case started(UUID)
    case range(UUID, NSRange)
    case finished(UUID)
    case cancelled(UUID)
}

@MainActor
protocol SystemSpeechDriving: AnyObject {
    var onEvent: ((SystemSpeechDriverEvent) -> Void)? { get set }
    func prepare() throws
    func speak(_ request: SystemSpeechRequest) throws
    func pause() -> Bool
    func resume() -> Bool
    func stop()
}

@MainActor
final class SystemSpeechPlaybackService: ObservableObject {
    enum State: String { case idle, preparing, speaking, paused, finished, failed }

    @Published private(set) var state: State = .idle {
        didSet {
            if let audio, let audioToken {
                audio.publishSystemSpeech(token: audioToken, speaking: state == .speaking, preparing: state == .preparing)
            }
        }
    }
    @Published private(set) var currentUnitIndex = 0
    @Published private(set) var highlightRange: NSRange?
    @Published private(set) var highlightedParagraphID: Int?
    @Published private(set) var callbackCount = 0
    @Published private(set) var firstSpeechMilliseconds: Int?
    @Published private(set) var errorCode: String?
    private(set) var units: [SystemSpeechUnit] = []
    private(set) var generation = UUID()
    var onCheckpoint: ((SystemSpeechUnit, NSRange?) -> Void)?
    var onPlayRequested: (() -> Void)?
    var onPlaybackInterrupted: (() -> Void)?

    private let driver: any SystemSpeechDriving
    private let now: () -> TimeInterval
    private var queued: [UUID: Int] = [:]
    private var nextIndex = 0
    private var voiceID = ""
    private var rate = AVSpeechUtteranceDefaultSpeechRate
    private var requestedAt: TimeInterval = 0
    private var requiresRequeue = false
    private var startWatchdog: Task<Void, Never>?
    private var audio: AudioPlayerService?
    private var audioToken: AudioPlaybackSessionToken?
    private var playbackTitle = ""

    init(driver: any SystemSpeechDriving, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver
        self.now = now
        driver.onEvent = { [weak self] event in self?.receive(event) }
    }

    convenience init() { self.init(driver: AppleSystemSpeechDriver()) }

    func connectPlayback(title: String, audio: AudioPlayerService = .shared) {
        self.audio = audio
        playbackTitle = title
        claimPlaybackIfNeeded()
    }

    func closePlayback() {
        stop()
        if let audio, let audioToken { audio.releasePlaybackSession(audioToken) }
        audioToken = nil
        audio = nil
    }

    private func claimPlaybackIfNeeded() {
        guard let audio else { return }
        if let audioToken, audio.isPlaybackSessionActive(audioToken) { return }
        audioToken = audio.attachSystemSpeech(.init(title: playbackTitle,
            play: Self.onMain { [weak self] in
                guard let self else { return }
                if let action = self.onPlayRequested { action() } else { self.play() }
            }, pause: Self.onMain { [weak self] in self?.onPlaybackInterrupted?(); self?.pause() },
            stop: Self.onMain { [weak self] in self?.onPlaybackInterrupted?(); self?.stop() },
            next: Self.onMain { [weak self] in guard let self else { return }; self.seek(to: self.currentUnitIndex + 1, autoplay: true) },
            previous: Self.onMain { [weak self] in guard let self else { return }; self.seek(to: max(0, self.currentUnitIndex - 1), autoplay: true) }))
    }

    private static func onMain(_ action: @escaping @MainActor () -> Void) -> () -> Void {
        { if Thread.isMainThread { MainActor.assumeIsolated { action() } }
          else { DispatchQueue.main.async { action() } } }
    }

    var canContinueAutomatically: Bool {
        guard let audio else { return true }
        guard let audioToken, audio.isPlaybackSessionActive(audioToken) else { return false }
        return audio.sleepTimer.permitsAutomaticPlayback()
    }

    static func voices(language: String) -> [SystemSpeechVoice] {
        let requested = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let primary = requested.split(separator: "-").first.map(String.init) ?? requested
        let preferredID = AVSpeechSynthesisVoice(language: language.replacingOccurrences(of: "_", with: "-"))?.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().split(separator: "-").first.map(String.init) == primary }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted {
                let lhsExact = $0.language.lowercased() == requested
                let rhsExact = $1.language.lowercased() == requested
                if lhsExact != rhsExact { return lhsExact }
                if ($0.identifier == preferredID) != ($1.identifier == preferredID) { return $0.identifier == preferredID }
                if $0.quality != $1.quality { return $0.quality.rawValue < $1.quality.rawValue }
                return $0.identifier < $1.identifier
            }
            .map { SystemSpeechVoice(id: $0.identifier, name: $0.name, language: $0.language) }
    }

    func load(_ units: [SystemSpeechUnit], voiceID: String) {
        stop()
        self.units = units
        self.voiceID = voiceID
        currentUnitIndex = 0
        highlightRange = nil
        highlightedParagraphID = nil
        state = .idle
    }

    func play() {
        guard !units.isEmpty, !voiceID.isEmpty else { fail("missing_text_or_voice"); return }
        claimPlaybackIfNeeded()
        audio?.sleepTimer.resumeByUser()
        guard state != .speaking, state != .preparing else { return }
        if state == .paused, !requiresRequeue, driver.resume() {
            state = .speaking
            return
        }
        begin(at: state == .finished ? 0 : currentUnitIndex)
    }

    func prepareForUserPlayback() {
        claimPlaybackIfNeeded()
        audio?.sleepTimer.resumeByUser()
        if units.isEmpty { state = .preparing }
    }

    /// Page continuation is never a user gesture: it must not reclaim an
    /// output taken by another reader or clear an expired sleep timer.
    func playAutomatically() {
        guard canContinueAutomatically, !units.isEmpty, !voiceID.isEmpty,
              state != .speaking, state != .preparing else { return }
        begin(at: currentUnitIndex)
    }

    func pause() {
        guard state == .speaking || state == .preparing else { return }
        startWatchdog?.cancel()
        // If the first utterance has not started, cancel instead of accepting
        // a pause which some voices report before their queued start callback.
        let wasPreparing = state == .preparing
        state = .paused
        if wasPreparing || !driver.pause() {
            invalidateQueue()
            requiresRequeue = true
        }
        checkpoint()
    }

    func stop() {
        checkpoint()
        invalidateQueue()
        state = .idle
        requiresRequeue = true
    }

    func seek(to index: Int, autoplay: Bool) {
        guard units.indices.contains(index) else { return }
        invalidateQueue()
        currentUnitIndex = index
        highlightRange = nil
        highlightedParagraphID = units[index].paragraphID
        state = .paused
        requiresRequeue = true
        checkpoint()
        if autoplay { begin(at: index) }
    }

    func setRate(_ newRate: Float) {
        guard newRate.isFinite else { return }
        let wasPlaying = state == .speaking || state == .preparing
        rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, newRate))
        if !units.isEmpty { seek(to: currentUnitIndex, autoplay: wasPlaying) }
    }

    func setVoice(_ identifier: String) {
        guard !identifier.isEmpty else { return }
        let wasPlaying = state == .speaking || state == .preparing
        voiceID = identifier
        if !units.isEmpty { seek(to: currentUnitIndex, autoplay: wasPlaying) }
    }

    private func begin(at index: Int) {
        guard units.indices.contains(index) else { return }
        guard canContinueAutomatically else { pause(); return }
        invalidateQueue()
        currentUnitIndex = index
        highlightRange = nil
        highlightedParagraphID = units[index].paragraphID
        nextIndex = index
        callbackCount = 0
        firstSpeechMilliseconds = nil
        errorCode = nil
        requestedAt = now()
        state = .preparing
        requiresRequeue = false
        do { try driver.prepare() }
        catch {
            ReaderRunLog.write("SYSTEM_SPEECH session setup failed code=\((error as NSError).code) domain=\((error as NSError).domain)")
            fail("system_speech_audio_session_\((error as NSError).code)")
            return
        }
        do { try fillQueue() }
        catch { fail("system_speech_voice_unavailable"); return }
        let run = generation
        startWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.generation == run,
                  self.state == .preparing else { return }
            self.fail("system_speech_start_timeout")
        }
    }

    private func invalidateQueue() {
        generation = UUID()
        startWatchdog?.cancel()
        startWatchdog = nil
        queued.removeAll()
        driver.stop()
    }

    private func fillQueue() throws {
        guard canContinueAutomatically else { return }
        while queued.count < 3, nextIndex < units.count {
            let index = nextIndex
            let id = UUID()
            queued[id] = index
            nextIndex += 1
            try driver.speak(SystemSpeechRequest(id: id, text: units[index].text, voiceID: voiceID, rate: rate))
        }
    }

    private func receive(_ event: SystemSpeechDriverEvent) {
        switch event {
        case .started(let id):
            if queued[id] != nil, !canContinueAutomatically { pause(); return }
            if queued[id] != nil, state == .paused {
                invalidateQueue()
                requiresRequeue = true
                return
            }
            guard let index = queued[id], state == .preparing || state == .speaking else { return }
            currentUnitIndex = index
            highlightedParagraphID = units[index].paragraphID
            highlightRange = nil
            state = .speaking
            if firstSpeechMilliseconds == nil { firstSpeechMilliseconds = Int((now() - requestedAt) * 1000) }
            startWatchdog?.cancel()
            checkpoint()
        case .range(let id, let range):
            guard let index = queued[id], state == .speaking, index == currentUnitIndex,
                  let source = SystemSpeechTextPlan.sourceRange(range, in: units[index]) else { return }
            highlightRange = source
            highlightedParagraphID = units[index].paragraphID
            callbackCount += 1
            checkpoint()
        case .finished(let id):
            if queued[id] != nil, state == .paused {
                // A completion can already be in flight when pause succeeds.
                // Cancel the tail and repeat the current sentence on resume.
                // Never enqueue more speech or silently skip ahead while paused.
                invalidateQueue()
                requiresRequeue = true
                checkpoint()
                return
            }
            guard let index = queued.removeValue(forKey: id), state == .speaking || state == .preparing else { return }
            if index + 1 == units.count {
                state = .finished
                checkpoint()
            } else {
                do { try fillQueue() } catch { fail("system_speech_queue_failed") }
            }
        case .cancelled(let id):
            guard queued[id] != nil else { return }
            fail("system_speech_cancelled")
        }
    }

    private func checkpoint() {
        guard units.indices.contains(currentUnitIndex) else { return }
        onCheckpoint?(units[currentUnitIndex], highlightRange)
    }

    private func fail(_ code: String) {
        invalidateQueue()
        errorCode = code
        state = .failed
        checkpoint()
    }
}

@MainActor
private final class AppleSystemSpeechDriver: NSObject, SystemSpeechDriving, AVSpeechSynthesizerDelegate {
    var onEvent: ((SystemSpeechDriverEvent) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var requests: [ObjectIdentifier: UUID] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
    }

    func prepare() throws {
        let session = AVAudioSession.sharedInstance()
        // Playback already enables AirPlay/A2DP. Explicit allowAirPlay is
        // supported only by playAndRecord and can fail on physical devices.
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
    }

    func speak(_ request: SystemSpeechRequest) throws {
        guard let voice = AVSpeechSynthesisVoice(identifier: request.voiceID) else {
            throw NSError(domain: "SystemSpeech", code: 1)
        }
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = voice
        utterance.rate = request.rate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        requests[ObjectIdentifier(utterance)] = request.id
        synthesizer.speak(utterance)
    }

    func pause() -> Bool { synthesizer.pauseSpeaking(at: .immediate) }
    func resume() -> Bool { synthesizer.continueSpeaking() }
    func stop() {
        requests.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            let key = ObjectIdentifier(utterance)
            guard let self, let id = self.requests[key] else { return }
            self.onEvent?(.started(id))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            let key = ObjectIdentifier(utterance)
            guard let self, let id = self.requests[key] else { return }
            self.onEvent?(.range(id, characterRange))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            let key = ObjectIdentifier(utterance)
            guard let self, let id = self.requests.removeValue(forKey: key) else { return }
            self.onEvent?(.finished(id))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            let key = ObjectIdentifier(utterance)
            guard let self, let id = self.requests.removeValue(forKey: key) else { return }
            self.onEvent?(.cancelled(id))
        }
    }
}
