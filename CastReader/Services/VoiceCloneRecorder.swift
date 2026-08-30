import Foundation
import AVFoundation
import Combine
import OSLog

@MainActor
final class VoiceCloneRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate, @preconcurrency AVAudioPlayerDelegate {
    enum State: Equatable { case idle, recording, recorded, playing }

    @Published private(set) var state: State = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var fileSize: Int = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var waveformSamples: [Double] = []
    @Published var errorMessage: String?

    let minimumDuration: TimeInterval = 3
    let maximumDuration: TimeInterval = 30
    let maximumBytes = 4 * 1024 * 1024

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private(set) var recordingURL: URL?
    private let logger = Logger(subsystem: "com.same.castreader", category: "VoiceCloneRecorder")

    var canSubmit: Bool {
        state == .recorded
            && duration >= minimumDuration
            && duration <= maximumDuration
            && fileSize <= maximumBytes
            && errorMessage == nil
    }

    @discardableResult
    func preparePermission() async -> Bool {
        errorMessage = nil
        let granted = await requestPermission()
        if !granted {
            errorMessage = AppLocalized("请在系统设置中允许麦克风权限")
        }
        return granted
    }

    @discardableResult
    func startRecording() async -> Bool {
        stopPlayback()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        duration = 0
        fileSize = 0
        level = 0
        waveformSamples = []
        state = .idle
        errorMessage = nil
        guard await preparePermission() else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-clone-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: maximumDuration) else {
                throw VoiceCloneError.invalidRecording(AppLocalized("无法开始录音"))
            }
            self.recorder = recorder
            recordingURL = url
            duration = 0
            fileSize = 0
            state = .recording
            timer?.invalidate()
            let meterTimer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateRecordingProgress() }
            }
            meterTimer.tolerance = 0.004
            // A default-mode timer may stall while a DragGesture is held.
            // Common mode keeps metering live throughout press-and-hold.
            RunLoop.main.add(meterTimer, forMode: .common)
            timer = meterTimer
            logger.info("Recording started at \(url.lastPathComponent, privacy: .public)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            resetAudioSession()
            return false
        }
    }

    func stopRecording() {
        guard state == .recording, let recorder else { return }
        let measuredDuration = max(duration, recorder.currentTime)
        recorder.delegate = nil
        recorder.stop()
        finishRecording(measuredDuration: measuredDuration)
    }

    func togglePlayback() {
        if state == .playing {
            stopPlayback()
            return
        }
        guard let recordingURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: recordingURL)
            player.delegate = self
            self.player = player
            state = .playing
            player.play()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func replaceRecording() {
        if state == .recording {
            recorder?.delegate = nil
            recorder?.stop()
            recorder = nil
            timer?.invalidate()
            timer = nil
        }
        stopPlayback()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        duration = 0
        fileSize = 0
        level = 0
        waveformSamples = []
        state = .idle
        errorMessage = nil
        resetAudioSession()
    }

    func cancelRecording() {
        replaceRecording()
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        finishRecording(measuredDuration: max(duration, recorder.currentTime))
        if !flag { errorMessage = AppLocalized("录音未能完整保存，请重录") }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        state = recordingURL == nil ? .idle : .recorded
    }

    private func updateRecordingProgress() {
        guard let recorder, state == .recording else { return }
        recorder.updateMeters()
        let averagePower = Double(recorder.averagePower(forChannel: 0))
        let peakPower = Double(recorder.peakPower(forChannel: 0))
        let waveformSample = Self.meterEnergy(
            averagePower: averagePower,
            peakPower: peakPower
        )
        level = Self.visualLevel(
            previous: level,
            averagePower: averagePower,
            peakPower: peakPower
        )
        waveformSamples = Self.appendingWaveformSample(
            waveformSample,
            to: waveformSamples,
            limit: 120
        )
        duration = min(maximumDuration, recorder.currentTime)
        if duration >= maximumDuration { stopRecording() }
    }

    /// Converts AVAudioRecorder's logarithmic meter into a deliberately broad
    /// visual range. Speech at ordinary phone distance should visibly occupy
    /// most of the waveform, while the attack/release filter keeps it fluid.
    static func visualLevel(
        previous: Double,
        averagePower: Double,
        peakPower: Double
    ) -> Double {
        let target = meterEnergy(
            averagePower: averagePower,
            peakPower: peakPower
        )
        let safePrevious = min(1, max(0, previous))
        let response = target > safePrevious ? 0.56 : 0.17
        return min(1, max(0, safePrevious + (target - safePrevious) * response))
    }

    /// Maps one logarithmic recorder reading into the visual activity range.
    /// Spatial variation belongs to the indicator animation, not a time-axis
    /// sample history, so the recorder only publishes this current energy.
    static func meterEnergy(
        averagePower: Double,
        peakPower: Double
    ) -> Double {
        // Preserve headroom all the way to 0 dBFS. The previous -17/-7 dB
        // ceilings made normal speech saturate, producing a wall of equal-height
        // bars. Average power drives the shape; peak adds crisp consonant detail.
        let average = normalizedVisualPower(averagePower, floor: -55, ceiling: -3)
        let peak = normalizedVisualPower(peakPower, floor: -48, ceiling: -1)
        let combined = average * 0.82 + peak * 0.18
        // Suppress ordinary room noise, then use the remaining range linearly so
        // adjacent speech samples retain their real amplitude differences.
        let noiseGate = 0.16
        guard combined > noiseGate else { return 0 }
        let gated = (combined - noiseGate) / (1 - noiseGate)
        return min(1, max(0, gated))
    }

    static func normalizedVisualPower(
        _ decibels: Double,
        floor: Double,
        ceiling: Double
    ) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }

    /// Keeps a short rolling meter history for the Voice Memos-style waveform.
    /// The newest sample is always last, so the view can place it at the right
    /// edge while older samples advance toward the left.
    static func appendingWaveformSample(
        _ sample: Double,
        to samples: [Double],
        limit: Int
    ) -> [Double] {
        guard limit > 0 else { return [] }
        var result = samples
        result.append(min(1, max(0, sample)))
        if result.count > limit {
            result.removeFirst(result.count - limit)
        }
        return result
    }

    private func finishRecording(measuredDuration: TimeInterval) {
        guard state == .recording else { return }
        timer?.invalidate()
        timer = nil
        recorder = nil
        if let recordingURL {
            fileSize = (try? recordingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            duration = min(maximumDuration, fileDuration(at: recordingURL) ?? measuredDuration)
        } else {
            duration = min(maximumDuration, measuredDuration)
        }
        level = 0
        state = .recorded
        logger.info("Recording finished: duration=\(self.duration, format: .fixed(precision: 3))s bytes=\(self.fileSize)")
        if duration < minimumDuration {
            errorMessage = AppLocalized("请至少录制 3 秒")
        } else if fileSize > maximumBytes {
            errorMessage = AppLocalized("录音文件必须不超过 4 MB")
        } else if let recordingURL, let quality = localQuality(at: recordingURL) {
            if quality.activeSpeechDuration < 2.5 {
                errorMessage = AppLocalized("没有检测到足够清晰的人声，请连续清晰说话至少 3 秒")
            } else if quality.activeRMSDBFS < -42 {
                errorMessage = AppLocalized("声音太小，请靠近手机并重新录制")
            } else if quality.clippingRatio > 0.004 {
                errorMessage = AppLocalized("声音过大并出现失真，请稍微远离手机重新录制")
            }
        }
        resetAudioSession()
    }

    private struct LocalRecordingQuality {
        let activeSpeechDuration: TimeInterval
        let activeRMSDBFS: Double
        let clippingRatio: Double
    }

    /// A deliberately small local preflight. The server worker remains the
    /// authoritative VAD/noise/reverb/speaker gate, while this prevents an
    /// obviously silent, very quiet, or clipped file from being uploaded.
    private func localQuality(at url: URL) -> LocalRecordingQuality? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, format.channelCount > 0 else { return nil }
        let frameCapacity = AVAudioFrameCount(max(1, Int(sampleRate * 0.02)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        var activeFrames: Int64 = 0
        var activeSquares = 0.0
        var clippedSamples: Int64 = 0
        var totalSamples: Int64 = 0
        while true {
            do {
                try file.read(into: buffer, frameCount: frameCapacity)
            } catch {
                return nil
            }
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            guard let channels = buffer.floatChannelData else { return nil }
            var frameSquares = 0.0
            for sampleIndex in 0..<count {
                var mono = 0.0
                for channelIndex in 0..<Int(format.channelCount) {
                    mono += Double(channels[channelIndex][sampleIndex])
                }
                mono /= Double(format.channelCount)
                frameSquares += mono * mono
                if abs(mono) >= 0.985 { clippedSamples += 1 }
            }
            totalSamples += Int64(count)
            let frameRMS = sqrt(frameSquares / Double(count))
            if frameRMS >= pow(10, -42.0 / 20.0) {
                activeFrames += Int64(count)
                activeSquares += frameSquares
            }
        }
        guard totalSamples > 0 else { return nil }
        let activeRMS = activeFrames > 0
            ? sqrt(activeSquares / Double(activeFrames))
            : 0
        let activeDBFS = 20 * log10(max(activeRMS, 0.000_000_001))
        return LocalRecordingQuality(
            activeSpeechDuration: Double(activeFrames) / sampleRate,
            activeRMSDBFS: activeDBFS,
            clippingRatio: Double(clippedSamples) / Double(totalSamples)
        )
    }

    private func fileDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        if recordingURL != nil, state == .playing { state = .recorded }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func resetAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {}
    }
}
