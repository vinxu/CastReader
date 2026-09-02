//
//  OnDeviceSpeechService.swift
//  CastReader
//
//  Network-free speech generation for small offline book packages. The
//  durable package owns rendered pages + OCR; this actor produces only the
//  current sentence and a short read-ahead window. Kokoro can plug into the
//  same protocol, while the system voice is the compatibility fallback.
//

import AVFoundation
import Foundation

enum OnDeviceSpeechEngine: String, Equatable, Sendable {
    case system
    case kokoro
}

struct OnDeviceSpeechCapability: Equatable, Sendable {
    let engine: OnDeviceSpeechEngine
    let voiceID: String
    let displayName: String
    let language: String
}

enum OnDeviceSpeechError: Error, Equatable, LocalizedError {
    case noInstalledVoice(String)
    case synthesisFailed
    case emptyAudio
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noInstalledVoice:
            return AppLocalized("本机没有可用的对应语言语音，请联网下载离线语音后重试。")
        case .synthesisFailed, .emptyAudio:
            return AppLocalized("本机语音生成失败，请重试。")
        case .cancelled:
            return nil
        }
    }
}

protocol OnDeviceSpeechGenerating: AnyObject {
    func capability(language: String) async -> OnDeviceSpeechCapability?
    func generateParagraph(
        paragraphIndex: Int,
        text: String,
        language: String,
        speaker: String?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws
}

/// A deterministic policy boundary that is independently unit-testable and
/// shared by the system/Kokoro adapters.
enum OnDeviceSpeechTimestampPolicy {
    static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var latinRun = ""
        func flushLatinRun() {
            if !latinRun.isEmpty {
                tokens.append(latinRun)
                latinRun = ""
            }
        }

        for character in text {
            if character.isWhitespace {
                flushLatinRun()
            } else if character.isASCII && (character.isLetter || character.isNumber) {
                latinRun.append(character)
            } else if character.isPunctuation {
                flushLatinRun()
            } else {
                flushLatinRun()
                tokens.append(String(character))
            }
        }
        flushLatinRun()
        return tokens
    }

    static func proportional(text: String, duration: Double) -> [TTSTimestamp] {
        guard duration.isFinite, duration > 0 else { return [] }
        let tokens = tokens(in: text)
        guard !tokens.isEmpty else { return [] }

        let weights = tokens.map { token in
            max(1, token.unicodeScalars.reduce(0) { partial, scalar in
                partial + (scalar.properties.isAlphabetic || scalar.properties.numericType != nil ? 1 : 0)
            })
        }
        let totalWeight = max(1, weights.reduce(0, +))
        var elapsed = 0.0
        return zip(tokens, weights).map { token, weight in
            let start = elapsed
            elapsed += duration * Double(weight) / Double(totalWeight)
            return TTSTimestamp(
                word: token,
                startTime: start,
                endTime: min(duration, elapsed)
            )
        }
    }

    /// `AVSpeechSynthesizerDelegate` callbacks are not guaranteed to advance in
    /// lockstep with the PCM write callback. On some voices every range arrives
    /// before the first audio buffer, producing a list of zero-length marks at
    /// time zero. Treat that as unavailable timing data instead of freezing the
    /// word highlight on the first token for the whole sentence.
    static func usable(
        _ timestamps: [TTSTimestamp],
        duration: Double
    ) -> [TTSTimestamp] {
        guard duration.isFinite, duration > 0, !timestamps.isEmpty else { return [] }
        var previousStart = -Double.infinity
        for timestamp in timestamps {
            guard !timestamp.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  timestamp.startTime.isFinite,
                  timestamp.endTime.isFinite,
                  timestamp.startTime >= 0,
                  timestamp.startTime >= previousStart,
                  timestamp.endTime > timestamp.startTime,
                  timestamp.endTime <= duration + 0.05 else {
                return []
            }
            previousStart = timestamp.startTime
        }
        return timestamps
    }
}

/// Local rendering always works in sentence-sized units, even for languages
/// whose cloud provider can return word timings for a whole paragraph. This is
/// what makes the first offline audio arrive quickly on a long OCR paragraph.
enum OnDeviceSpeechChunkingPolicy {
    static func requestUnits(_ text: String, language: String) -> [String] {
        let normalized = ReadingSentenceContract.normalizeWhitespace(
            text,
            language: language
        )
        guard !normalized.isEmpty else { return [] }
        let sentences = ReadingSentenceContract.segments(normalized)
        return sentences.isEmpty ? [normalized] : sentences
    }
}

actor OnDeviceSpeechService: OnDeviceSpeechGenerating {
    static let shared = OnDeviceSpeechService()

    private init() {}

    func capability(language: String) async -> OnDeviceSpeechCapability? {
        await SystemSpeechRenderSession.capability(language: language)
    }

    func generateParagraph(
        paragraphIndex: Int,
        text: String,
        language: String,
        speaker: String?,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        let sanitized = SpeechTextSanitizer.sanitizedForTTS(text)
        guard SpeechTextSanitizer.containsSpeakableContent(sanitized) else { return }
        guard let capability = await capability(language: language) else {
            throw OnDeviceSpeechError.noInstalledVoice(language)
        }

        let units = OnDeviceSpeechChunkingPolicy.requestUnits(
            sanitized,
            language: language
        )
        for (segmentIndex, unit) in units.enumerated() {
            do {
                try Task.checkCancellation()
                let rendered = try await SystemSpeechRenderSession.render(
                    text: unit,
                    voiceIdentifier: capability.voiceID
                )
                try Task.checkCancellation()
                guard !rendered.audioData.isEmpty, rendered.duration > 0 else {
                    throw OnDeviceSpeechError.emptyAudio
                }
                let renderedTimestamps = OnDeviceSpeechTimestampPolicy.usable(
                    rendered.timestamps,
                    duration: rendered.duration
                )
                let timestamps = renderedTimestamps.isEmpty
                    ? OnDeviceSpeechTimestampPolicy.proportional(
                        text: unit,
                        duration: rendered.duration
                    )
                    : renderedTimestamps
                let remaining = units.dropFirst(segmentIndex + 1).joined(separator: " ")
                await onSegmentReady(AudioSegment(
                    paragraphIndex: paragraphIndex,
                    segmentIndex: segmentIndex,
                    audioData: rendered.audioData,
                    timestamps: timestamps,
                    duration: rendered.duration,
                    text: unit,
                    isWavFormat: true,
                    unprocessedText: remaining,
                    speaker: speaker
                ))
            } catch is CancellationError {
                throw OnDeviceSpeechError.cancelled
            } catch let error as OnDeviceSpeechError {
                throw error
            } catch {
                throw OnDeviceSpeechError.synthesisFailed
            }
        }
    }
}

private struct SystemSpeechRenderResult {
    let audioData: Data
    let duration: Double
    let timestamps: [TTSTimestamp]
}

/// `AVSpeechSynthesizer.write` renders into PCM buffers without playing them.
/// The callback buffer is consumed synchronously and written into a private WAV
/// file; only the resulting Data crosses back into the player pipeline.
private final class SystemSpeechRenderSession: NSObject,
    AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private struct RangeMark {
        let range: NSRange
        let frame: AVAudioFramePosition
    }

    private let lock = NSLock()
    private let synthesizer = AVSpeechSynthesizer()
    private let text: String
    private let voiceIdentifier: String
    private let outputURL: URL

    private var continuation: CheckedContinuation<SystemSpeechRenderResult, Error>?
    private var audioFile: AVAudioFile?
    private var sampleRate = 0.0
    private var frameCount: AVAudioFramePosition = 0
    private var rangeMarks: [RangeMark] = []
    private var terminal = false

    private init(text: String, voiceIdentifier: String) {
        self.text = text
        self.voiceIdentifier = voiceIdentifier
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastReaderOfflineSpeech", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).wav")
        super.init()
        synthesizer.delegate = self
    }

    @MainActor
    static func capability(language: String) -> OnDeviceSpeechCapability? {
        let normalized = language
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let candidate = voice.language.lowercased()
            return candidate == normalized || candidate.hasPrefix("\(primary)-")
        }
        guard let voice = candidates.sorted(by: preferredVoiceOrder).first
            ?? AVSpeechSynthesisVoice(language: language) else { return nil }
        return OnDeviceSpeechCapability(
            engine: .system,
            voiceID: voice.identifier,
            displayName: voice.name,
            language: voice.language
        )
    }

    @MainActor
    private static func preferredVoiceOrder(
        _ lhs: AVSpeechSynthesisVoice,
        _ rhs: AVSpeechSynthesisVoice
    ) -> Bool {
        if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
        return lhs.identifier < rhs.identifier
    }

    static func render(
        text: String,
        voiceIdentifier: String
    ) async throws -> SystemSpeechRenderResult {
        try Task.checkCancellation()
        let session = SystemSpeechRenderSession(
            text: text,
            voiceIdentifier: voiceIdentifier
        )
        return try await withTaskCancellationHandler {
            try await session.start()
        } onCancel: {
            Task { @MainActor in session.cancel() }
        }
    }

    private func start() async throws -> SystemSpeechRenderResult {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let alreadyCancelled = terminal
            if !alreadyCancelled {
                self.continuation = continuation
            }
            lock.unlock()
            if alreadyCancelled {
                continuation.resume(throwing: OnDeviceSpeechError.cancelled)
                return
            }
            Task { @MainActor [self] in
                guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
                    finish(.failure(OnDeviceSpeechError.noInstalledVoice("")))
                    return
                }
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = voice
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                utterance.preUtteranceDelay = 0
                utterance.postUtteranceDelay = 0
                synthesizer.write(utterance) { [weak self] buffer in
                    self?.consume(buffer)
                }
            }
        }
    }

    @MainActor
    private func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        finish(.failure(OnDeviceSpeechError.cancelled))
    }

    private func consume(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            finish(.failure(OnDeviceSpeechError.synthesisFailed))
            return
        }
        if pcm.frameLength == 0 {
            completeAudio()
            return
        }

        do {
            lock.lock()
            defer { lock.unlock() }
            guard !terminal else { return }
            if audioFile == nil {
                sampleRate = pcm.format.sampleRate
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
            }
            try audioFile?.write(from: pcm)
            frameCount += AVAudioFramePosition(pcm.frameLength)
        } catch {
            finish(.failure(OnDeviceSpeechError.synthesisFailed))
        }
    }

    private func completeAudio() {
        let result: Result<SystemSpeechRenderResult, Error>
        lock.lock()
        if terminal {
            lock.unlock()
            return
        }
        let frames = frameCount
        let rate = sampleRate
        let marks = rangeMarks
        audioFile = nil
        lock.unlock()

        do {
            let data = try Data(contentsOf: outputURL, options: .mappedIfSafe)
            let duration = rate > 0 ? Double(frames) / rate : 0
            guard !data.isEmpty, duration > 0 else {
                throw OnDeviceSpeechError.emptyAudio
            }
            result = .success(SystemSpeechRenderResult(
                audioData: data,
                duration: duration,
                timestamps: timestamps(from: marks, frameCount: frames, sampleRate: rate)
            ))
        } catch let error as OnDeviceSpeechError {
            result = .failure(error)
        } catch {
            result = .failure(OnDeviceSpeechError.synthesisFailed)
        }
        finish(result)
    }

    private func timestamps(
        from marks: [RangeMark],
        frameCount: AVAudioFramePosition,
        sampleRate: Double
    ) -> [TTSTimestamp] {
        guard sampleRate > 0, frameCount > 0, !marks.isEmpty else { return [] }
        let nsText = text as NSString
        let valid = marks.filter {
            $0.range.location >= 0 && $0.range.length > 0
                && NSMaxRange($0.range) <= nsText.length
        }.sorted { lhs, rhs in
            if lhs.frame == rhs.frame { return lhs.range.location < rhs.range.location }
            return lhs.frame < rhs.frame
        }
        guard !valid.isEmpty else { return [] }
        return valid.enumerated().compactMap { index, mark in
            let token = nsText.substring(with: mark.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            let nextFrame = index + 1 < valid.count ? valid[index + 1].frame : frameCount
            let start = max(0, min(frameCount, mark.frame))
            let end = max(start, min(frameCount, nextFrame))
            return TTSTimestamp(
                word: token,
                startTime: Double(start) / sampleRate,
                endTime: Double(end) / sampleRate
            )
        }
    }

    private func finish(_ result: Result<SystemSpeechRenderResult, Error>) {
        let continuation: CheckedContinuation<SystemSpeechRenderResult, Error>?
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        terminal = true
        audioFile = nil
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: outputURL)
        continuation?.resume(with: result)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        lock.lock()
        if !terminal {
            rangeMarks.append(RangeMark(range: characterRange, frame: frameCount))
        }
        lock.unlock()
    }
}
