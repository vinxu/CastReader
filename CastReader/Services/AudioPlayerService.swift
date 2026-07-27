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
import UIKit

class AudioPlayerService: NSObject, ObservableObject {
    static let shared = AudioPlayerService()

    // MARK: - Published Properties
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var currentSegment: AudioSegment?
    @Published var isBuffering = false
    /// True while a streaming producer has promised additional queue items.
    /// Published because a temporarily empty queue must still block transient
    /// UI such as the App Store review request.
    @Published var moreSegmentsExpected = false
    /// True after the current queue drains while its producer is still active.
    @Published private(set) var isWaitingForNextSegment = false

    // Book/Chapter info
    @Published var currentBookId: String?
    @Published var currentBookTitle: String?
    @Published var currentChapterTitle: String?
    @Published var currentCoverUrl: String?
    @Published var currentCaption: String?
    private var currentCoverImage: UIImage?   // 本地封面（Now Playing artwork）

    // MARK: - Private Properties
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var playerStateCancellable: AnyCancellable?
    private var wasInterrupted = false
    private var playbackSuspendedByInterruption = false

    // Segments queue
    private var segmentsQueue: [AudioSegment] = []
    private var currentSegmentIndex = 0
    private var gatedSegmentIndex: Int?

    // 临时文件管理
    private var currentTempFileURL: URL?

    // Callbacks
    var onSegmentComplete: (() -> Void)?
    var onPlaybackComplete: (() -> Void)?
    /// Optional queue-boundary gate. Kindle uses it to ensure the semantic page
    /// turn and visible-surface confirmation finish before prepared next-page
    /// audio is allowed to start. Other readers leave it nil.
    var canStartQueuedSegment: ((AudioSegment) -> Bool)?

    // MARK: - Computed Properties
    var hasActivePlayback: Bool {
        currentBookId != nil
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var isQuiescentForReviewPrompt: Bool {
        AppReviewPresentationGate.playbackIsQuiescent(
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            moreSegmentsExpected: moreSegmentsExpected,
            isWaitingForNextSegment: isWaitingForNextSegment
        )
    }

    /// Last item currently owned by the player queue. Kindle uses this as the
    /// boundary marker when it appends the already-generated first utterance of
    /// the next page. The marker lets the page turn begin shortly before the
    /// audio queue crosses that boundary without interrupting the current item.
    var queuedTailSegmentID: String? {
        segmentsQueue.last?.id
    }

    /// True when a prepared segment can be started even if no AVPlayer exists
    /// yet (for example, a paused voice switch that generated its first item).
    var hasQueuedSegments: Bool {
        !segmentsQueue.isEmpty
    }

    /// True only when `canStartQueuedSegment` has held a concrete queue item.
    /// This is narrower than `isBuffering`, which can also describe AVPlayer
    /// loading and therefore must not be used as a page-boundary ownership flag.
    var isQueuedSegmentGated: Bool {
        gatedSegmentIndex != nil
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

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.wasInterrupted = true
                self.playbackSuspendedByInterruption = true
                print("🔇 Audio interrupted - pausing")
                self.pause()
            }

        case .ended:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 被其他 App / 系统中断后不要自动续播。保持暂停状态，等用户明确点击播放。
                // 否则 AVAudioSession 给 shouldResume 时会把 UI 重新标成 playing，但实际声音可能已被别的 App 接管。
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    print("❌ Failed to reactivate audio session: \(error)")
                }
                self.wasInterrupted = false
                self.syncPlaybackStateFromPlayer(reason: "interruption-ended")
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
            DispatchQueue.main.async { [weak self] in
                print("🎧 Audio route changed (headphones removed) - pausing")
                self?.pause()
            }
        default:
            break
        }
    }

    @objc private func handleAppDidBecomeActive() {
        syncPlaybackStateFromPlayer(reason: "app-active")
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

        // Artist/Album - show the current spoken caption on the lock screen.
        // iOS renders this as the secondary line in the system Now Playing card.
        if let bookTitle = currentBookTitle {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = bookTitle
        }
        if let caption = currentCaption, !caption.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyArtist] = caption
        } else {
            nowPlayingInfo[MPMediaItemPropertyArtist] = "CastReader"
        }

        // Duration and elapsed time
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

        // 封面：优先本地封面文件（History/<id>.cover.jpg，与「继续看」卡片同源）；惰性加载一次后缓存。
        if currentCoverImage == nil, let id = currentBookId { currentCoverImage = Self.localCoverImage(forID: id) }
        if let image = currentCoverImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        } else if let coverUrlString = currentCoverUrl,
                  let encoded = coverUrlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let coverUrl = URL(string: encoded) {
            loadArtwork(from: coverUrl) { artwork in
                if let artwork = artwork { nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }

    /// 本地封面文件（路径确定，不依赖 @MainActor 的 HistoryStore，避免跨 actor）。
    static func localCoverImage(forID id: String) -> UIImage? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("History/\(id).cover.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
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
                self.currentCoverImage = image
                completion(artwork)
            }
        }.resume()
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Public Methods

    func setBook(id: String, title: String, chapterTitle: String?, coverUrl: String?) {
        if currentBookId != id {
            currentCaption = nil
        }
        currentBookId = id
        currentBookTitle = title
        currentChapterTitle = chapterTitle
        currentCoverUrl = coverUrl
        currentCoverImage = Self.localCoverImage(forID: id)   // 本地封面（锁屏/控制中心 artwork）
    }

    func setNowPlayingCaption(_ caption: String?) {
        let cleaned = Self.cleanCaption(caption)
        guard cleaned != currentCaption else { return }
        currentCaption = cleaned
        updateNowPlayingInfo()
    }

    func clearBook() {
        stop()
        currentBookId = nil
        currentBookTitle = nil
        currentChapterTitle = nil
        currentCoverUrl = nil
        currentCaption = nil
        currentCoverImage = nil
        segmentsQueue.removeAll()
        currentSegmentIndex = 0
        canStartQueuedSegment = nil
        clearNowPlayingInfo()
    }

    func clearQueue() {
        print("🔊 clearQueue: Stopping and clearing \(segmentsQueue.count) segments")
        stop()
        segmentsQueue.removeAll()
        currentSegmentIndex = 0
        gatedSegmentIndex = nil
        canStartQueuedSegment = nil
        moreSegmentsExpected = false
        isWaitingForNextSegment = false
    }

    private static func cleanCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let cleaned = caption
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let maxCount = 120
        if cleaned.count <= maxCount { return cleaned }
        return String(cleaned.prefix(maxCount)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    func loadSegment(_ segment: AudioSegment, autoPlay: Bool = true) {
        print("🔊 loadSegment: Adding segment \(segment.segmentIndex) for paragraph \(segment.paragraphIndex), queueCount will be \(segmentsQueue.count + 1), waiting=\(isWaitingForNextSegment)")
        segmentsQueue.append(segment)

        guard !playbackSuspendedByInterruption else {
            isWaitingForNextSegment = false
            print("🔊 loadSegment: Queued while interrupted; waiting for user resume")
            return
        }

        // If we were waiting for the next segment, play it now
        if isWaitingForNextSegment, autoPlay {
            print("🔊 loadSegment: Was waiting, now playing segment \(segmentsQueue.count - 1)")
            isWaitingForNextSegment = false
            playSegment(at: segmentsQueue.count - 1)
        }
        // If this is the first segment and we're not playing, start playback
        else if autoPlay && segmentsQueue.count == 1 && !isPlaying {
            print("🔊 loadSegment: First segment, starting playback")
            playSegment(at: 0)
        } else {
            if !autoPlay { isWaitingForNextSegment = false }
            print("🔊 loadSegment: Segment queued (autoPlay=\(autoPlay), isPlaying=\(isPlaying), queueCount=\(segmentsQueue.count))")
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

    /// Append fully prepared audio behind the current queue without stopping or
    /// replacing the playing AVPlayerItem. This is intentionally separate from
    /// `loadSegments`, whose replace-and-start semantics are correct for jumps
    /// but would create an audible page-boundary gap for Kindle.
    @discardableResult
    func appendPreparedSegmentsForContinuousPlayback(_ segments: [AudioSegment]) -> String? {
        guard !segments.isEmpty else { return segmentsQueue.last?.id }
        let predecessor = segmentsQueue.last?.id
        let firstAppendedIndex = segmentsQueue.count
        segmentsQueue.append(contentsOf: segments)
        print("🔊 appendPreparedSegments: Added \(segments.count) segments after \(predecessor ?? "none")")

        guard !playbackSuspendedByInterruption else {
            isWaitingForNextSegment = false
            return predecessor
        }
        if isWaitingForNextSegment {
            isWaitingForNextSegment = false
            playSegment(at: firstAppendedIndex)
        } else if currentSegment == nil, !isPlaying {
            playSegment(at: firstAppendedIndex)
        }
        return predecessor
    }

    /// Remove only not-yet-played handoff items. The current and historical
    /// queue prefix is preserved so cancellation cannot cut audible playback.
    /// Returns false when one of the requested ids is already the current item.
    @discardableResult
    func removePendingSegments(withIDs ids: Set<String>) -> Bool {
        guard !ids.isEmpty, !segmentsQueue.isEmpty else { return true }
        let currentID = currentSegment?.id
        let currentWasRequested = currentID.map(ids.contains) ?? false
        let gatedID = gatedSegmentIndex.flatMap { index in
            segmentsQueue.indices.contains(index) ? segmentsQueue[index].id : nil
        }
        let suffixStart = min(segmentsQueue.count, currentSegmentIndex + 1)
        if suffixStart < segmentsQueue.count {
            let retainedSuffix = segmentsQueue[suffixStart...].filter { !ids.contains($0.id) }
            segmentsQueue.replaceSubrange(suffixStart..<segmentsQueue.count, with: retainedSuffix)
        }
        gatedSegmentIndex = gatedID.flatMap { id in
            ids.contains(id) ? nil : segmentsQueue.firstIndex(where: { $0.id == id })
        }
        if let gatedID, ids.contains(gatedID) {
            isBuffering = false
        }
        print("🔊 removePendingSegments: Removed pending handoff segments, currentRequested=\(currentWasRequested)")
        return !currentWasRequested
    }

    /// Retry a queue item previously held by `canStartQueuedSegment`. If the
    /// gate is still closed this remains a no-op and keeps buffering state.
    func resumeGatedSegmentIfPossible() {
        guard let index = gatedSegmentIndex else { return }
        playSegment(at: index)
    }

    /// Start a specifically queued item from a stable fractional checkpoint.
    /// Web readers use this only after an unavoidable WebKit reload. Seeking is
    /// applied after AVPlayerItem becomes ready and before audio is allowed to
    /// resume, so recovery never emits a short burst from the sentence start.
    @discardableResult
    func startQueuedSegment(
        id: String,
        progress: Double,
        autoPlay: Bool
    ) -> Bool {
        guard let index = segmentsQueue.firstIndex(where: { $0.id == id }) else { return false }
        playSegment(
            at: index,
            initialProgress: min(0.98, max(0, progress)),
            autoPlayWhenReady: autoPlay
        )
        return true
    }

    func play() {
        guard let player else {
            guard !segmentsQueue.isEmpty else {
                isPlaying = false
                updateNowPlayingInfo()
                return
            }
            playbackSuspendedByInterruption = false
            let index = segmentsQueue.indices.contains(currentSegmentIndex) ? currentSegmentIndex : 0
            playSegment(at: index)
            return
        }
        playbackSuspendedByInterruption = false
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("❌ Failed to activate audio session before play: \(error)")
        }
        player.playImmediately(atRate: playbackRate)
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
        playerStateCancellable?.cancel()
        playerStateCancellable = nil
        playbackSuspendedByInterruption = false
        isPlaying = false
        currentTime = 0
        duration = 0
        currentSegment = nil
        gatedSegmentIndex = nil
        isBuffering = false
        isWaitingForNextSegment = false
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
            player?.playImmediately(atRate: rate)
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
        print("🔊 nextSegment: currentIndex=\(currentSegmentIndex), queueCount=\(segmentsQueue.count), moreExpected=\(moreSegmentsExpected)")
        if currentSegmentIndex < segmentsQueue.count - 1 {
            print("🔊 nextSegment: Playing next segment at index \(currentSegmentIndex + 1)")
            playSegment(at: currentSegmentIndex + 1)
        } else if moreSegmentsExpected {
            // TTS is still generating segments, wait for them
            print("🔊 nextSegment: No more segments in queue but TTS still loading, waiting...")
            isWaitingForNextSegment = true
        } else {
            print("🔊 nextSegment: No more segments and TTS complete, calling onPlaybackComplete")
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

    private func playSegment(
        at index: Int,
        initialProgress: Double? = nil,
        autoPlayWhenReady: Bool = true
    ) {
        guard index >= 0 && index < segmentsQueue.count else {
            print("🔴 playSegment: index \(index) out of range (queue size: \(segmentsQueue.count))")
            return
        }

        let segment = segmentsQueue[index]
        if let canStartQueuedSegment, !canStartQueuedSegment(segment) {
            gatedSegmentIndex = index
            isPlaying = false
            isBuffering = true
            updateNowPlayingInfo()
            print("🔊 playSegment[\(index)]: Held by queue-boundary gate")
            return
        }
        gatedSegmentIndex = nil
        isBuffering = false

        // 删除上一个临时文件（释放磁盘空间）
        if let oldURL = currentTempFileURL {
            try? FileManager.default.removeItem(at: oldURL)
        }

        currentSegmentIndex = index
        // `currentTime` still belongs to the AVPlayerItem that just finished.
        // Publish the new segment only after rebasing its clock, otherwise
        // page-handoff observers can adopt the new segment with the old item's
        // terminal time and permanently skip the first highlighted words.
        currentTime = 0
        duration = segment.duration
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
            playAudio(
                from: tempURL,
                initialProgress: initialProgress,
                autoPlayWhenReady: autoPlayWhenReady
            )
        } catch {
            print("🔴 playSegment[\(index)]: Failed to write audio data: \(error)")
        }
    }

    private func playAudio(
        from url: URL,
        initialProgress: Double? = nil,
        autoPlayWhenReady: Bool = true
    ) {
        removeTimeObserver()

        // Ensure audio session is active
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }

        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)
        playerItem?.audioTimePitchAlgorithm = .timeDomain

        // Create or update player
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        observePlayerPlaybackState()

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
                    guard !self.playbackSuspendedByInterruption else {
                        self.player?.pause()
                        self.isPlaying = false
                        self.updateNowPlayingInfo()
                        print("Audio ready but suspended by interruption; waiting for user resume")
                        return
                    }
                    if let initialProgress, seconds.isFinite, seconds > 0 {
                        let targetSeconds = seconds * min(0.98, max(0, initialProgress))
                        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
                        let expectedItem = self.playerItem
                        self.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak expectedItem] _ in
                            guard let self, expectedItem === self.playerItem else { return }
                            self.currentTime = targetSeconds
                            if autoPlayWhenReady {
                                self.player?.playImmediately(atRate: self.playbackRate)
                                self.isPlaying = true
                            } else {
                                self.player?.pause()
                                self.isPlaying = false
                            }
                            self.updateNowPlayingInfo()
                            print("Audio restored at \(targetSeconds)s / \(seconds)s")
                        }
                    } else if autoPlayWhenReady {
                        self.player?.playImmediately(atRate: self.playbackRate)
                        self.isPlaying = true
                        self.updateNowPlayingInfo()
                    } else {
                        self.player?.pause()
                        self.isPlaying = false
                        self.updateNowPlayingInfo()
                    }
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

    private func observePlayerPlaybackState() {
        playerStateCancellable?.cancel()
        playerStateCancellable = player?
            .publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncPlaybackStateFromPlayer(reason: "time-control")
            }
    }

    private func syncPlaybackStateFromPlayer(reason: String) {
        guard let player else {
            if isPlaying {
                isPlaying = false
                updateNowPlayingInfo()
            }
            return
        }
        let actuallyPlaying = player.timeControlStatus == .playing && player.rate > 0
        guard actuallyPlaying != isPlaying else {
            updateNowPlayingElapsedTime()
            return
        }
        #if DEBUG
        NSLog("CRDBG AUDIO syncPlayback reason=%@ actual=%@ uiWas=%@ rate=%.2f status=%ld interrupted=%@",
              reason,
              actuallyPlaying ? "playing" : "paused",
              isPlaying ? "playing" : "paused",
              Double(player.rate),
              player.timeControlStatus.rawValue,
              wasInterrupted ? "Y" : "N")
        #endif
        isPlaying = actuallyPlaying
        updateNowPlayingInfo()
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
    static let freeSpeedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static let proSpeedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0]

    var speedDisplayText: String {
        if playbackRate == 1.0 {
            return "1x"
        }
        return String(format: "%.2gx", playbackRate)
    }
}
