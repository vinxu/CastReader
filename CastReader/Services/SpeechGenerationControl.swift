import Foundation

/// Accounts for a completed HTTP result while it crosses actors into the
/// reader's cache/queue. Without this handoff reservation a second producer
/// can enter before onSegmentReady has published the first result's duration.
final class SpeechGenerationReceipt {
    let id = UUID()
    private weak var control: SpeechGenerationControl?
    init(control: SpeechGenerationControl) { self.control = control }
    deinit {
        let control = control, id = id
        Task { @MainActor in control?.releaseResponse(id) }
    }
}

enum SpeechInputWindow {
    static func split(_ text: String, maximumUTF16: Int) -> ClonedTTSRequestChunker.Chunk {
        guard text.utf16.count > maximumUTF16 else { return .init(input: text, remainder: "") }
        var used = 0
        var end = text.unicodeScalars.startIndex
        var natural: String.Index?
        while end < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[end]
            let count = scalar.value > 0xFFFF ? 2 : 1
            guard used + count <= maximumUTF16 else { break }
            used += count
            end = text.unicodeScalars.index(after: end)
            if used >= maximumUTF16 / 2,
               CharacterSet.whitespacesAndNewlines.contains(scalar) || ".!?。！？；;".unicodeScalars.contains(scalar) {
                natural = end
            }
        }
        let boundary = natural ?? end
        return .init(input: String(text[..<boundary]), remainder: String(text[boundary...]))
    }
}

/// Producer lifetime is independent of one cancelled HTTP attempt. A pause
/// retains its exact checkpoint; a seek cancels the producer and its attempt.
@MainActor
final class SpeechGenerationControl {
    struct PlaybackSnapshot {
        var pending: [AudioSegment] = []
        var queueIDs: Set<UUID> = []
        var currentID: UUID?
        var position: Double = 0
        var rate: Double = 1
    }
    private struct Attempt {
        let id: UUID
        let pauseRevision: UInt64
        let cancel: () -> Void
    }
    private var attempt: Attempt?
    private var pauseRevision: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pending: [UUID: PresetTTSRequestScheduler.Priority] = [:]
    private var providers: [UUID: () -> [AudioSegment]?] = [:]
    private var responses: [UUID: Double] = [:]
    private var atomicOwner: SpeechGenerationContext.AtomicUnit?
    var playbackSnapshot: () -> PlaybackSnapshot = { PlaybackSnapshot() }
    private(set) var isPaused = false
    private(set) var isWaitingForBudget = false

    func addBufferProvider(_ provider: @escaping () -> [AudioSegment]?) {
        providers[UUID()] = provider
    }

    func reserveResponse(duration: Double) -> SpeechGenerationReceipt {
        let receipt = SpeechGenerationReceipt(control: self)
        responses[receipt.id] = duration
        updateBudget()
        return receipt
    }

    fileprivate func releaseResponse(_ id: UUID) {
        responses.removeValue(forKey: id)
        notify()
    }

    var bufferedSeconds: Double {
        let snapshot = playbackSnapshot()
        let rate = max(0.25, snapshot.rate)
        var seen = Set<UUID>()
        var seconds = 0.0
        func include(_ segment: AudioSegment, queued: Bool) {
            guard seen.insert(segment.generationIdentity).inserted else { return }
            if !queued && snapshot.queueIDs.contains(segment.generationIdentity) { return }
            // Unknown duration reserves the whole window until real metadata
            // arrives. Playback speed/time must not shrink an unknown reserve.
            guard segment.duration.isFinite, segment.duration > 0 else {
                seconds += 30
                return
            }
            let position = segment.generationIdentity == snapshot.currentID ? snapshot.position : 0
            seconds += max(0, segment.duration - position) / rate
        }
        snapshot.pending.forEach { include($0, queued: true) }
        for (id, provider) in providers {
            guard let segments = provider() else { providers.removeValue(forKey: id); continue }
            segments.forEach { include($0, queued: false) }
        }
        for (id, duration) in responses where !seen.contains(id) && !snapshot.queueIDs.contains(id) {
            seconds += duration.isFinite && duration > 0 ? duration / rate : 30
        }
        return seconds
    }

    private var playableQueueSeconds: Double {
        let snapshot = playbackSnapshot()
        return snapshot.pending.reduce(0) { total, segment in
            guard segment.duration.isFinite, segment.duration > 0 else { return total + 30 }
            let position = segment.generationIdentity == snapshot.currentID ? snapshot.position : 0
            return total + max(0, segment.duration - position) / max(0.25, snapshot.rate)
        }
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            pauseRevision &+= 1
            attempt?.cancel()
        }
        notify()
    }

    func notify() {
        updateBudget()
        let waiting = waiters.values
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func updateBudget() {
        let seconds = bufferedSeconds
        if seconds >= 30 { isWaitingForBudget = true }
        else if seconds <= 10 { isWaitingForBudget = false }
    }

    fileprivate func finishAtomicUnit(_ unit: SpeechGenerationContext.AtomicUnit) {
        guard atomicOwner === unit else { return }
        atomicOwner = nil
        notify()
    }

    private func waitForChange() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func run<T>(requestID: String, priority: PresetTTSRequestScheduler.Priority,
                operation: @escaping () async throws -> T) async throws -> T {
        let owner = UUID()
        pending[owner] = priority
        defer { pending.removeValue(forKey: owner); notify() }
        let atomic = SpeechGenerationContext.atomicUnit
        while true {
            try Task.checkCancellation()
            updateBudget()
            let highestPriority = pending.values.map(\.rawValue).min() ?? priority.rawValue
            let ownsAtomicUnit = atomic != nil && atomicOwner === atomic
            // Future-page reservations remain counted, but cannot starve the
            // explicitly owned audible producer while its playable queue drains.
            let audibleDemand = SpeechGenerationContext.audibleDemand?() == true
                && playableQueueSeconds <= 10
            if isPaused || attempt != nil || (atomicOwner != nil && !ownsAtomicUnit)
                || (!ownsAtomicUnit && !audibleDemand && priority.rawValue > highestPriority)
                || (isWaitingForBudget && atomic?.started != true && !audibleDemand) {
                try await waitForChange()
                continue
            }
            let attemptID = UUID()
            let revision = pauseRevision
            let task = Task { try await operation() }
            attempt = Attempt(id: attemptID, pauseRevision: revision, cancel: { task.cancel() })
            if let atomic {
                atomicOwner = atomic
                atomic.control = self
            }
            atomic?.started = true
            let result = await withTaskCancellationHandler {
                await task.result
            } onCancel: { task.cancel() }
            // Keep the permit until the real transport exits. A cancelled
            // URLSession callback can never overlap a resumed request.
            if attempt?.id == attemptID { attempt = nil }
            notify()
            try Task.checkCancellation()
            if revision != pauseRevision { continue }
            return try result.get()
        }
    }
}

enum SpeechGenerationContext {
    @MainActor final class AtomicUnit {
        var started = false
        weak var control: SpeechGenerationControl?
        func finish() { control?.finishAtomicUnit(self) }
    }
    @TaskLocal static var current: SpeechGenerationControl?
    @TaskLocal static var atomicUnit: AtomicUnit?
    @TaskLocal static var isAttempt = false
    @TaskLocal static var audibleDemand: (@MainActor () -> Bool)?

    /// Server-composed marks sometimes require a complete small narration unit.
    /// This exception is finite and never bypasses pause or serial transport.
    @MainActor static func withAtomicUnit<T>(text: String, maximumCharacters: Int = 2400,
        audibleDemand: (@MainActor () -> Bool)? = nil,
        operation: () async throws -> T) async throws -> T {
        guard text.unicodeScalars.count <= maximumCharacters else {
            throw TTSError.generationFailed("response_invalid")
        }
        let unit = AtomicUnit()
        defer { unit.finish() }
        return try await $audibleDemand.withValue(audibleDemand ?? Self.audibleDemand) {
            try await $atomicUnit.withValue(unit, operation: operation)
        }
    }
}

extension ParagraphSpeechGenerating {
    func controlled(by control: SpeechGenerationControl) -> any ParagraphSpeechGenerating {
        ControlledParagraphSpeechGenerator(base: self, control: control)
    }
}

private struct ControlledParagraphSpeechGenerator: ParagraphSpeechGenerating {
    let base: any ParagraphSpeechGenerating
    let control: SpeechGenerationControl

    func generateBufferedSpeech(paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?,
        beforeRequest: @escaping (TTSContinuation) async throws -> PresetTTSRequestScheduler.Priority,
        onSegmentReady: @escaping (AudioSegment) async -> Void) async throws {
        try await SpeechGenerationContext.$current.withValue(control) {
            try await base.generateBufferedSpeech(paragraphIndex: paragraphIndex, text: text, voice: voice,
                speed: speed, language: language, includeVoiceCode: includeVoiceCode, speaker: speaker,
                cloneRequestID: cloneRequestID, continuation: continuation,
                beforeRequest: beforeRequest, onSegmentReady: onSegmentReady)
        }
    }

    func generateTTSForParagraph(paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void) async throws {
        try await SpeechGenerationContext.$current.withValue(control) {
            try await base.generateTTSForParagraph(paragraphIndex: paragraphIndex, text: text, voice: voice,
                speed: speed, language: language, includeVoiceCode: includeVoiceCode, speaker: speaker,
                cloneRequestID: cloneRequestID, continuation: continuation, onCheckpoint: onCheckpoint,
                onSegmentReady: onSegmentReady)
        }
    }

    func generateVoiceSwitchSegments(paragraphIndex: Int, text: String, voice: String, language: String) async throws -> [AudioSegment] {
        try await SpeechGenerationContext.$current.withValue(control) {
            try await base.generateVoiceSwitchSegments(paragraphIndex: paragraphIndex, text: text, voice: voice, language: language)
        }
    }

    func generatePrefetchSegments(paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        presetPriority: PresetTTSRequestScheduler.Priority,
        onSegmentReady: ((AudioSegment) async -> Void)?) async throws -> [AudioSegment] {
        try await SpeechGenerationContext.$current.withValue(control) {
            try await base.generatePrefetchSegments(paragraphIndex: paragraphIndex, text: text, voice: voice,
                speed: speed, language: language, includeVoiceCode: includeVoiceCode, speaker: speaker,
                cloneRequestID: cloneRequestID, presetPriority: presetPriority, onSegmentReady: onSegmentReady)
        }
    }
}
