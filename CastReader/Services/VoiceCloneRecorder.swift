import Foundation
import AVFoundation
import Combine

@MainActor
final class VoiceCloneRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate, @preconcurrency AVAudioPlayerDelegate {
    enum State: Equatable { case idle, recording, recorded, playing }

    @Published private(set) var state: State = .idle
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var fileSize: Int = 0
    @Published var errorMessage: String?

    let minimumDuration: TimeInterval = 3
    let maximumDuration: TimeInterval = 30
    let maximumBytes = 4 * 1024 * 1024

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private(set) var recordingURL: URL?

    var canSubmit: Bool {
        state == .recorded && duration >= minimumDuration && duration <= maximumDuration && fileSize <= maximumBytes
    }

    func startRecording() async {
        stopPlayback()
        errorMessage = nil
        guard await requestPermission() else {
            errorMessage = String(localized: "请在系统设置中允许麦克风权限")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-clone-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: maximumDuration) else {
                throw VoiceCloneError.invalidRecording(String(localized: "无法开始录音"))
            }
            self.recorder = recorder
            recordingURL = url
            duration = 0
            fileSize = 0
            state = .recording
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateRecordingProgress() }
            }
        } catch {
            errorMessage = error.localizedDescription
            resetAudioSession()
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        recorder?.stop()
        finishRecording()
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
        stopPlayback()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        duration = 0
        fileSize = 0
        state = .idle
        errorMessage = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        finishRecording()
        if !flag { errorMessage = String(localized: "录音未能完整保存，请重录") }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        state = recordingURL == nil ? .idle : .recorded
    }

    private func updateRecordingProgress() {
        guard let recorder, state == .recording else { return }
        duration = min(maximumDuration, recorder.currentTime)
        if duration >= maximumDuration { stopRecording() }
    }

    private func finishRecording() {
        timer?.invalidate()
        timer = nil
        duration = min(maximumDuration, recorder?.currentTime ?? duration)
        recorder = nil
        if let recordingURL {
            fileSize = (try? recordingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        state = .recorded
        if duration < minimumDuration {
            errorMessage = String(localized: "请至少录制 3 秒")
        } else if fileSize > maximumBytes {
            errorMessage = String(localized: "录音文件必须不超过 4 MB")
        }
        resetAudioSession()
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
