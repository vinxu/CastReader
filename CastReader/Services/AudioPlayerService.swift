//
//  AudioPlayerService.swift
//  CastReader
//
//  Uses AVPlayer with background task support for continuous playback.
//

import Foundation
import AVFoundation
import Combine
import MediaPlayer

class AudioPlayerService: NSObject, ObservableObject {
    static let shared = AudioPlayerService()

    // MARK: - Published Properties
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var currentSegment: AudioSegment?
    @Published var isBuffering = false

    // Book/Chapter info
    @Published var currentBookId: String?
    @Published var currentBookTitle: String?
    @Published var currentChapterTitle: String?
    @Published var currentCoverUrl: String?

    // MARK: - Private Properties
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    // Segments queue
    private var segmentsQueue: [AudioSegment] = []
    private var currentSegmentIndex = 0

    // 临时文件管理
    private var currentTempFileURL: URL?

    // Callbacks
    var onSegmentComplete: (() -> Void)?
    var onPlaybackComplete: (() -> Void)?

    // MARK: - Computed Properties
    var hasActivePlayback: Bool {
        currentBookId != nil
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    // MARK: - Initialization
    private override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommandCenter()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)

            // 监听音频中断（来电、其他 app 播放等）
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioInterruption),
                name: AVAudioSession.interruptionNotification,
                object: session
            )

            // 监听音频路由变化（拔掉耳机等）
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: session
            )

            print("✅ Audio session configured for background playback")
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // 音频被中断（如来电），暂停播放
            print("🔇 Audio interrupted - pausing")
            pause()

        case .ended:
            // 中断结束，检查是否应该恢复播放
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("🔊 Audio interruption ended - resuming")
                    // 重新激活 audio session
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        play()
                    } catch {
                        print("❌ Failed to reactivate audio session: \(error)")
                    }
                }
            }

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            // 耳机被拔掉，暂停播放
            print("🎧 Audio route changed (headphones removed) - pausing")
            pause()
        default:
            break
        }
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // Skip forward
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward(seconds: 15)
            return .success
        }

        // Skip backward
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward(seconds: 15)
            return .success
        }

        // Next track (next segment)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextSegment()
            return .success
        }

        // Previous track (previous segment)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousSegment()
            return .success
        }

        // Change playback position (scrubbing)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: positionEvent.positionTime)
            return .success
        }
    }

    func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()

        // Title - use chapter title if available, otherwise book title
        if let chapterTitle = currentChapterTitle, !chapterTitle.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyTitle] = chapterTitle
        } else if let bookTitle = currentBookTitle {
            nowPlayingInfo[MPMediaItemPropertyTitle] = bookTitle
        }

        // Artist/Album - use book title as album
        if let bookTitle = currentBookTitle {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = bookTitle
            nowPlayingInfo[MPMediaItemPropertyArtist] = "CastReader"
        }

        // Duration and elapsed time
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

        // Load cover image if available
        if let coverUrlString = currentCoverUrl,
           let encoded = coverUrlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let coverUrl = URL(string: encoded) {
            loadArtwork(from: coverUrl) { artwork in
                if let artwork = artwork {
                    nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }

    private func loadArtwork(from url: URL, completion: @escaping (MPMediaItemArtwork?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data = data, error == nil,
                  let image = UIImage(data: data) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            DispatchQueue.main.async {
                completion(artwork)
            }
        }.resume()
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Public Methods

    func setBook(id: String, title: String, chapterTitle: String?, coverUrl: String?) {
        currentBookId = id
        currentBookTitle = title
        currentChapterTitle = chapterTitle
        currentCoverUrl = coverUrl
    }

    func clearBook() {
        stop()
        currentBookId = nil
        currentBookTitle = nil
        currentChapterTitle = nil
        currentCoverUrl = nil
        segmentsQueue.removeAll()
        currentSegmentIndex = 0
        clearNowPlayingInfo()
    }

    func clearQueue() {
        print("🔊 clearQueue: Stopping and clearing \(segmentsQueue.count) segments")
        stop()
        segmentsQueue.removeAll()
        currentSegmentIndex = 0
    }

    func loadSegment(_ segment: AudioSegment) {
        print("🔊 loadSegment: Adding segment \(segment.segmentIndex) for paragraph \(segment.paragraphIndex), queueCount will be \(segmentsQueue.count + 1)")
        segmentsQueue.append(segment)

        // If this is the first segment and we're not playing, start playback
        if segmentsQueue.count == 1 && !isPlaying {
            print("🔊 loadSegment: First segment, starting playback")
            playSegment(at: 0)
        } else {
            print("🔊 loadSegment: Segment queued (isPlaying=\(isPlaying), queueCount=\(segmentsQueue.count))")
        }
    }

    func loadSegments(_ segments: [AudioSegment]) {
        print("🔊 loadSegments: Received \(segments.count) segments")

        // Clear existing queue and stop current playback
        stop()
        segmentsQueue.removeAll()
        currentSegmentIndex = 0

        // Add new segments
        segmentsQueue.append(contentsOf: segments)

        // Start playback from the first segment
        if !segmentsQueue.isEmpty {
            print("🔊 loadSegments: Starting playSegment(at: 0)")
            playSegment(at: 0)
        } else {
            print("🔴 loadSegments: No segments to play!")
        }
    }

    func play() {
        player?.play()
        player?.rate = playbackRate
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        print("🔊 stop(): Stopping playback, player=\(player != nil ? "exists" : "nil")")
        removeTimeObserver()
        player?.pause()
        player = nil
        playerItem = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentSegment = nil
        // Clear Combine subscriptions to prevent stale observers
        cancellables.removeAll()
        // 清理临时文件
        if let tempURL = currentTempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
            currentTempFileURL = nil
        }
        print("🔊 stop(): Playback stopped, currentSegment is now nil")
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime)
        currentTime = time
        updateNowPlayingElapsedTime()
    }

    func seekToProgress(_ progress: Double) {
        let time = duration * progress
        seek(to: time)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
        updateNowPlayingInfo()
    }

    func skipForward(seconds: Double = 15) {
        let newTime = min(currentTime + seconds, duration)
        seek(to: newTime)
    }

    func skipBackward(seconds: Double = 15) {
        let newTime = max(currentTime - seconds, 0)
        seek(to: newTime)
    }

    func nextSegment() {
        print("🔊 nextSegment: currentIndex=\(currentSegmentIndex), queueCount=\(segmentsQueue.count)")
        if currentSegmentIndex < segmentsQueue.count - 1 {
            print("🔊 nextSegment: Playing next segment at index \(currentSegmentIndex + 1)")
            playSegment(at: currentSegmentIndex + 1)
        } else {
            print("🔊 nextSegment: No more segments, calling onPlaybackComplete")
            onPlaybackComplete?()
        }
    }

    func previousSegment() {
        if currentSegmentIndex > 0 {
            playSegment(at: currentSegmentIndex - 1)
        } else {
            seek(to: 0)
        }
    }

    // MARK: - Private Methods

    private func playSegment(at index: Int) {
        guard index >= 0 && index < segmentsQueue.count else {
            print("🔴 playSegment: index \(index) out of range (queue size: \(segmentsQueue.count))")
            return
        }

        // 删除上一个临时文件（释放磁盘空间）
        if let oldURL = currentTempFileURL {
            try? FileManager.default.removeItem(at: oldURL)
        }

        currentSegmentIndex = index
        let segment = segmentsQueue[index]
        currentSegment = segment

        print("🔊 playSegment[\(index)]: audioData size: \(segment.audioData.count), duration: \(segment.duration)")

        // Create temporary file for audio data
        // Use .wav extension for local TTS (WAV format) or .mp3 for cloud TTS
        let fileExtension = segment.isWavFormat ? "wav" : "mp3"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("segment_\(segment.id)_\(UUID().uuidString).\(fileExtension)")
        currentTempFileURL = tempURL

        do {
            try segment.audioData.write(to: tempURL)
            print("🔊 playSegment[\(index)]: Written to \(tempURL.lastPathComponent), calling playAudio")
            playAudio(from: tempURL)
        } catch {
            print("🔴 playSegment[\(index)]: Failed to write audio data: \(error)")
        }
    }

    private func playAudio(from url: URL) {
        removeTimeObserver()

        // Ensure audio session is active
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }

        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)

        // Create or update player
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        isBuffering = true

        // Observe player item status
        playerItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .readyToPlay:
                    self.isBuffering = false
                    let seconds = self.playerItem?.duration.seconds ?? 0
                    // Check for valid duration (not NaN or infinite)
                    if seconds.isFinite && seconds > 0 {
                        self.duration = seconds
                    }
                    // Start playback
                    self.player?.play()
                    self.player?.rate = self.playbackRate
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                    print("Audio ready to play, duration: \(seconds)")
                case .failed:
                    self.isBuffering = false
                    print("Player item failed: \(self.playerItem?.error?.localizedDescription ?? "Unknown error")")
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Add time observer
        addTimeObserver()

        // Observe when playback ends
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
    }

    private var lastNowPlayingUpdateTime: Double = 0

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600) // 50ms updates for smooth highlighting
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds

            // Update Now Playing info every second for lock screen progress
            if abs(time.seconds - self.lastNowPlayingUpdateTime) >= 1.0 {
                self.lastNowPlayingUpdateTime = time.seconds
                self.updateNowPlayingElapsedTime()
            }
        }
    }

    private func updateNowPlayingElapsedTime() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
    }

    @objc private func playerDidFinishPlaying() {
        print("🔊 playerDidFinishPlaying: Segment finished, currentIndex=\(currentSegmentIndex)")
        onSegmentComplete?()
        nextSegment()
    }
}

// MARK: - Playback Speed Options
extension AudioPlayerService {
    static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var speedDisplayText: String {
        if playbackRate == 1.0 {
            return "1x"
        }
        return String(format: "%.2gx", playbackRate)
    }
}
