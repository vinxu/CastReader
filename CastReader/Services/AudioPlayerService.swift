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

enum AudioPlaybackOwner: String, Equatable, Sendable {
    case readAloud
    case explain
    case kindleBackgroundProbe
}

struct AudioPlaybackSessionToken: Equatable, Hashable, Sendable {
    let owner: AudioPlaybackOwner
    let generation: UInt64
}

struct AudioPlaybackResumeHandle: Equatable, Sendable {
    fileprivate let session: AudioPlaybackSessionToken?
    fileprivate let segmentID: String
    fileprivate let bookID: String?
}

/// The player owns one narrowly scoped temporary directory. Cleaning it never
/// touches imports, previews or any other subsystem's files. Legacy root-level
/// names are removed only when they match the old exact prefix + extension.
enum AudioPlaybackTemporaryFiles {
    static let directoryName = "CastReaderPlaybackAudio"
    private static let legacyPrefixes = ["segment_", "prestage_"]
    private static let audioExtensions: Set<String> = ["mp3", "wav"]

    static func prepare(
        root: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> URL {
        let standardizedRoot = root.standardizedFileURL
        let directory = standardizedRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        if directory.deletingLastPathComponent() == standardizedRoot,
           directory.lastPathComponent == directoryName {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return directory }
        for candidate in children {
            let name = candidate.lastPathComponent
            guard legacyPrefixes.contains(where: { name.hasPrefix($0) }),
                  audioExtensions.contains(
                      candidate.pathExtension.lowercased()
                  ),
                  (try? candidate.resourceValues(
                      forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true else { continue }
            try? fileManager.removeItem(at: candidate)
        }
        return directory
    }

    static func removeOwnedContents(
        in directory: URL,
        preserving preservedURLs: Set<URL> = [],
        fileManager: FileManager = .default
    ) {
        let directory = directory.standardizedFileURL
        guard directory.lastPathComponent == directoryName,
              directory.path != "/" else { return }
        let preserved = Set(preservedURLs.map(\.standardizedFileURL))
        let children = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for child in children
            where !preserved.contains(child.standardizedFileURL) {
            try? fileManager.removeItem(at: child)
        }
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    static func fileURL(
        in directory: URL,
        prefix: String,
        segmentID: String,
        fileExtension: String
    ) -> URL {
        directory.appendingPathComponent(
            "\(prefix)\(segmentID)_\(UUID().uuidString).\(fileExtension)"
        )
    }
}

/// A streaming TTS producer can finish just after the last audio item has
/// already drained. In that ordering the player is waiting for an item that
/// will never arrive, so producer completion must resolve the paragraph exactly
/// once instead of leaving the UI silently paused.
enum StreamingQueueDrainContract {
    static func shouldCompletePlayback(
        producerFinishedSuccessfully: Bool,
        isWaitingForNextSegment: Bool,
        moreSegmentsExpected: Bool,
        currentSegmentIndex: Int,
        queueCount: Int
    ) -> Bool {
        producerFinishedSuccessfully
            && isWaitingForNextSegment
            && !moreSegmentsExpected
            && queueCount > 0
            && currentSegmentIndex >= queueCount - 1
    }
}

/// Pure ownership state used by the player and unit tests. A queue can only be
/// controlled when it belongs to the currently active mode session. Claiming a
/// new session deliberately leaves the old queue attached to its old token so a
/// remote command or a late AVPlayer callback cannot revive it.
struct AudioPlaybackOwnershipState: Equatable {
    private(set) var activeSession: AudioPlaybackSessionToken?
    private(set) var queueSession: AudioPlaybackSessionToken?
    private var nextGeneration: UInt64 = 0

    mutating func claim(_ owner: AudioPlaybackOwner) -> AudioPlaybackSessionToken {
        nextGeneration &+= 1
        let token = AudioPlaybackSessionToken(owner: owner, generation: nextGeneration)
        activeSession = token
        return token
    }

    mutating func release(_ token: AudioPlaybackSessionToken) {
        guard activeSession == token else { return }
        activeSession = nil
    }

    mutating func transferActiveQueue(
        to owner: AudioPlaybackOwner
    ) -> AudioPlaybackSessionToken? {
        guard activeSession != nil, activeSession == queueSession else { return nil }
        nextGeneration &+= 1
        let token = AudioPlaybackSessionToken(owner: owner, generation: nextGeneration)
        activeSession = token
        queueSession = token
        return token
    }

    func permitsQueueMutation(_ token: AudioPlaybackSessionToken?) -> Bool {
        activeSession == token
    }

    @discardableResult
    mutating func attachQueue(to token: AudioPlaybackSessionToken?) -> Bool {
        guard permitsQueueMutation(token) else { return false }
        queueSession = token
        return true
    }

    func permitsPlayback(requestedBy token: AudioPlaybackSessionToken?) -> Bool {
        activeSession == token && queueSession == token
    }

    /// Lock-screen commands are allowed to target the one active queue without
    /// knowing its private token. A released queue deliberately fails because
    /// `activeSession != queueSession`.
    var permitsRemotePlayback: Bool {
        activeSession == queueSession
    }

    /// AVFoundation callbacks carry the session that installed their item. They
    /// must match both sides of ownership, even after a newer queue has already
    /// been attached for the same mode.
    func permitsCallback(from token: AudioPlaybackSessionToken?) -> Bool {
        queueSession == token && permitsPlayback(requestedBy: token)
    }
}

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
    @Published private(set) var moreSegmentsExpected = false
    /// True after the current queue drains while its producer is still active.
    @Published private(set) var isWaitingForNextSegment = false

    // Book/Chapter info
    @Published var currentBookId: String?
    @Published var currentBookTitle: String?
    @Published var currentChapterTitle: String?
    @Published var currentCoverUrl: String?
    @Published var currentCaption: String?
    private var currentCoverImage: UIImage?   // 本地封面（Now Playing artwork）
    private var artworkLoadKey: String?
    private var artworkDataTask: URLSessionDataTask?
    private var artworkDecodeTask: Task<Void, Never>?
    private var artworkRequestGeneration: UInt64 = 0

    // MARK: - Private Properties
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    /// Session that installed the current AVPlayerItem. Unlike the queue token,
    /// this also identifies callbacks already enqueued by AVFoundation. A
    /// seamless page handoff transfers it explicitly; an ordinary mode claim
    /// leaves it unchanged so late callbacks remain fenced.
    private var playerItemSession: AudioPlaybackSessionToken?
    private var reportedPlaybackFailureItemID: ObjectIdentifier?
    private var timeObserver: Any?
    private var playerStateCancellable: AnyCancellable?
    private var playerItemStatusCancellable: AnyCancellable?
    private var playerItemReadinessWorkItem: DispatchWorkItem?
    private var wasInterrupted = false
    private var playbackSuspendedByInterruption = false

    // Segments queue
    private var segmentsQueue: [AudioSegment] = []
    private var currentSegmentIndex = 0
    private var gatedSegmentIndex: Int?
    private var playbackOwnership = AudioPlaybackOwnershipState()

    // 临时文件管理
    private let playbackTemporaryDirectory: URL
    private var currentTempFileURL: URL?

    // Callbacks
    var onSegmentComplete: (() -> Void)?
    var onPlaybackComplete: (() -> Void)?
    var onPlaybackError: ((String) -> Void)?
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

    /// Whether Play can make audible progress without waiting for a new TTS
    /// response. `currentSegment` deliberately survives item completion, so
    /// its mere presence does not mean the drained queue can resume.
    var hasPlayableAudio: Bool {
        guard !segmentsQueue.isEmpty else { return false }
        if currentSegment == nil { return true }
        if currentSegmentIndex < segmentsQueue.count - 1 { return true }
        guard playerItem != nil else { return true }
        if isBuffering { return false }
        guard duration > 0.01 else { return true }
        return currentTime + 0.15 < duration
    }

    /// True only when `canStartQueuedSegment` has held a concrete queue item.
    /// This is narrower than `isBuffering`, which can also describe AVPlayer
    /// loading and therefore must not be used as a page-boundary ownership flag.
    var isQueuedSegmentGated: Bool {
        gatedSegmentIndex != nil
    }

    var activePlaybackSession: AudioPlaybackSessionToken? {
        playbackOwnership.activeSession
    }

    /// Claiming always creates a fresh generation, even for the same owner. This
    /// fences callbacks from an older VM instance as well as Read/Explain mode
    /// switches.
    @discardableResult
    func claimPlaybackSession(owner: AudioPlaybackOwner) -> AudioPlaybackSessionToken {
        suspendQueueForOwnershipChange()
        let token = playbackOwnership.claim(owner)
        ReaderRunLog.write(
            "AUDIO session claimed owner=\(owner.rawValue) gen=\(token.generation)"
        )
        return token
    }

    func releasePlaybackSession(_ token: AudioPlaybackSessionToken) {
        guard playbackOwnership.activeSession == token else { return }
        suspendQueueForOwnershipChange()
        playbackOwnership.release(token)
        ReaderRunLog.write(
            "AUDIO session released owner=\(token.owner.rawValue) gen=\(token.generation)"
        )
    }

    /// Seamless Kindle page handoff is the one intentional cross-VM transfer:
    /// the already-playing queue stays audible, but receives a fresh session so
    /// callbacks held by the detached VM can no longer control it.
    func transferActiveQueueSession(
        to owner: AudioPlaybackOwner
    ) -> AudioPlaybackSessionToken? {
        guard let token = playbackOwnership.transferActiveQueue(to: owner) else {
            return nil
        }
        if playerItem != nil {
            playerItemSession = token
        }
        return token
    }

    func isPlaybackSessionActive(_ token: AudioPlaybackSessionToken) -> Bool {
        playbackOwnership.activeSession == token
    }

    func isQueueOwned(by token: AudioPlaybackSessionToken) -> Bool {
        playbackOwnership.queueSession == token
    }

    func canControlPlayback(session token: AudioPlaybackSessionToken) -> Bool {
        playbackOwnership.permitsPlayback(requestedBy: token)
    }

    /// Narrow escape hatch for a page coordinator that is part of a known
    /// reader mode but does not own the VM's private token. The owner check keeps
    /// a late Read callback from touching Explain (and vice versa).
    private func activeSessionForCoordinator(
        owner: AudioPlaybackOwner
    ) -> AudioPlaybackSessionToken? {
        guard let token = playbackOwnership.activeSession,
              token.owner == owner else {
            return nil
        }
        return token
    }

    private func activeCoordinatorSession(
        owner: AudioPlaybackOwner
    ) -> AudioPlaybackSessionToken? {
        guard let token = activeSessionForCoordinator(owner: owner),
              playbackOwnership.permitsPlayback(requestedBy: token) else {
            return nil
        }
        return token
    }

    @discardableResult
    func clearActiveQueueForCoordinator(owner: AudioPlaybackOwner) -> Bool {
        guard let token = activeSessionForCoordinator(owner: owner) else { return false }
        return clearQueue(session: token)
    }

    @discardableResult
    func pauseActivePlaybackForCoordinator(owner: AudioPlaybackOwner) -> Bool {
        guard let token = activeCoordinatorSession(owner: owner) else { return false }
        return pause(session: token)
    }

    @discardableResult
    func playActivePlaybackForCoordinator(owner: AudioPlaybackOwner) -> Bool {
        guard let token = activeCoordinatorSession(owner: owner) else { return false }
        return play(session: token)
    }

    /// Voice samples use a separate AVPlayer, so they temporarily suspend the
    /// active content item. The handle binds resumption to the exact ownership
    /// generation and segment; a mode switch invalidates it automatically.
    func suspendActivePlaybackForVoicePreview() -> AudioPlaybackResumeHandle? {
        let session = playbackOwnership.activeSession
        guard playbackOwnership.permitsPlayback(requestedBy: session),
              isPlaying,
              let segmentID = currentSegment?.id,
              pause(session: session) else {
            return nil
        }
        return AudioPlaybackResumeHandle(
            session: session,
            segmentID: segmentID,
            bookID: currentBookId
        )
    }

    @discardableResult
    func resumePlaybackAfterVoicePreview(
        _ handle: AudioPlaybackResumeHandle
    ) -> Bool {
        guard playbackOwnership.activeSession == handle.session,
              playbackOwnership.queueSession == handle.session,
              currentSegment?.id == handle.segmentID,
              currentBookId == handle.bookID,
              !isPlaying else {
            return false
        }
        return play(session: handle.session)
    }

    private func currentItemCanPublishPlaybackState() -> Bool {
        playbackOwnership.permitsCallback(from: playerItemSession)
    }

    @discardableResult
    func setMoreSegmentsExpected(
        _ expected: Bool,
        session token: AudioPlaybackSessionToken
    ) -> Bool {
        guard playbackOwnership.permitsQueueMutation(token) else { return false }
        if moreSegmentsExpected != expected {
            ReaderRunLog.write(
                "AUDIO producer expected=\(expected ? "Y" : "N") " +
                "owner=\(token.owner.rawValue) gen=\(token.generation) " +
                "segment=\(currentSegment?.id ?? "nil")"
            )
        }
        moreSegmentsExpected = expected
        if !expected, isWaitingForNextSegment {
            // Cancellation/error/queue replacement paths use this setter. They
            // intentionally do not advance playback, but their abandoned
            // producer must no longer leave a fake loading state behind.
            isWaitingForNextSegment = false
            isBuffering = false
        }
        return true
    }

    /// Close a successful streaming producer. If its final queued item already
    /// ended, resolve the terminal callback on the next main-loop turn. Keeping
    /// `isWaitingForNextSegment` set until then lets a last-moment segment win
    /// the race and start normally without a duplicate completion callback.
    @discardableResult
    func finishStreamingProducer(
        session token: AudioPlaybackSessionToken
    ) -> Bool {
        guard playbackOwnership.permitsQueueMutation(token) else { return false }
        moreSegmentsExpected = false
        guard StreamingQueueDrainContract.shouldCompletePlayback(
            producerFinishedSuccessfully: true,
            isWaitingForNextSegment: isWaitingForNextSegment,
            moreSegmentsExpected: moreSegmentsExpected,
            currentSegmentIndex: currentSegmentIndex,
            queueCount: segmentsQueue.count
        ) else { return true }

        let terminalSegmentID = currentSegment?.id
        ReaderRunLog.write(
            "AUDIO producer finished after queue drained segment=\(terminalSegmentID ?? "nil")"
        )
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.playbackOwnership.permitsCallback(from: token),
                  self.currentSegment?.id == terminalSegmentID,
                  StreamingQueueDrainContract.shouldCompletePlayback(
                      producerFinishedSuccessfully: true,
                      isWaitingForNextSegment:
                          self.isWaitingForNextSegment,
                      moreSegmentsExpected: self.moreSegmentsExpected,
                      currentSegmentIndex: self.currentSegmentIndex,
                      queueCount: self.segmentsQueue.count
                  ) else { return }
            self.isWaitingForNextSegment = false
            self.isBuffering = false
            ReaderRunLog.write(
                "AUDIO resolved drained streaming producer segment=\(terminalSegmentID ?? "nil")"
            )
            self.onPlaybackComplete?()
        }
        return true
    }

    // MARK: - Initialization
    private override init() {
        playbackTemporaryDirectory = AudioPlaybackTemporaryFiles.prepare()
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
                ReaderRunLog.write(
                    "AUDIO interruption began segment=\(self.currentSegment?.id ?? "nil")"
                )
                print("🔇 Audio interrupted - pausing")
                self.pauseRegardlessOfOwnership()
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
                ReaderRunLog.write(
                    "AUDIO interruption ended segment=\(self.currentSegment?.id ?? "nil")"
                )
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
                ReaderRunLog.write(
                    "AUDIO route removed segment=\(self?.currentSegment?.id ?? "nil")"
                )
                print("🎧 Audio route changed (headphones removed) - pausing")
                self?.pauseRegardlessOfOwnership()
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
            guard let self else { return .commandFailed }
            return self.play(session: self.playbackOwnership.activeSession)
                ? .success
                : .commandFailed
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.pause(session: self.playbackOwnership.activeSession)
                ? .success
                : .commandFailed
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.togglePlayPause(session: self.playbackOwnership.activeSession)
                ? .success
                : .commandFailed
        }

        // Skip forward
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.skipForward(
                seconds: 15,
                session: self.playbackOwnership.activeSession
            ) ? .success : .commandFailed
        }

        // Skip backward
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.skipBackward(
                seconds: 15,
                session: self.playbackOwnership.activeSession
            ) ? .success : .commandFailed
        }

        // Next track (next segment)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.nextSegment(session: self.playbackOwnership.activeSession)
                ? .success
                : .commandFailed
        }

        // Previous track (previous segment)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.previousSegment(session: self.playbackOwnership.activeSession)
                ? .success
                : .commandFailed
        }

        // Change playback position (scrubbing)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return self.seek(
                to: positionEvent.positionTime,
                session: self.playbackOwnership.activeSession
            )
                ? .success
                : .commandFailed
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
        } else if let coverUrlString = currentCoverUrl?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !coverUrlString.isEmpty {
            if let image = ImageCache.shared.get(coverUrlString) {
                currentCoverImage = image
                nowPlayingInfo[MPMediaItemPropertyArtwork] =
                    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            } else {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                let requestKey = "\(currentBookId ?? "")|\(coverUrlString)"
                if artworkLoadKey != requestKey,
                   let coverUrl = Self.makeArtworkURL(coverUrlString) {
                    loadArtwork(
                        from: coverUrl,
                        sourceURL: coverUrlString,
                        requestKey: requestKey
                    )
                }
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

    private static func makeArtworkURL(_ raw: String) -> URL? {
        URL(string: raw)
            ?? raw.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ).flatMap(URL.init(string:))
    }

    private func loadArtwork(
        from url: URL,
        sourceURL: String,
        requestKey: String
    ) {
        cancelArtworkLoad()
        artworkLoadKey = requestKey
        let expectedGeneration = artworkRequestGeneration
        let request = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data,
                  error == nil,
                  !data.isEmpty,
                  data.count <= 20 * 1_024 * 1_024,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.artworkRequestGeneration == expectedGeneration,
                          self.artworkLoadKey == requestKey else { return }
                    self.artworkDataTask = nil
                    self.artworkLoadKey = nil
                }
                return
            }

            // Confirm this is still the current video before starting image
            // decode. The detached task is tracked as well, so switching videos
            // or closing the reader cancels both network and decode work.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.artworkRequestGeneration == expectedGeneration,
                      self.artworkLoadKey == requestKey,
                      self.currentArtworkRequestKey == requestKey else { return }
                self.artworkDataTask = nil
                let decodeTask = Task.detached(priority: .utility) { [weak self] in
                    guard !Task.isCancelled else { return }
                    let image = UIImage(data: data)
                    guard !Task.isCancelled else { return }

                    guard let image else {
                        await MainActor.run { [weak self] in
                            guard let self,
                                  self.artworkRequestGeneration == expectedGeneration,
                                  self.artworkLoadKey == requestKey else { return }
                            self.artworkDecodeTask = nil
                            self.artworkLoadKey = nil
                        }
                        return
                    }

                    let remainsCurrent = await MainActor.run { [weak self] in
                        guard let self else { return false }
                        return self.artworkRequestGeneration == expectedGeneration
                            && self.artworkLoadKey == requestKey
                            && self.currentArtworkRequestKey == requestKey
                    }
                    guard remainsCurrent, !Task.isCancelled else { return }
                    ImageCache.shared.set(sourceURL, image: image, data: data)
                    guard !Task.isCancelled else { return }

                    await MainActor.run { [weak self] in
                        guard let self,
                              self.artworkRequestGeneration == expectedGeneration,
                              self.artworkLoadKey == requestKey,
                              self.currentArtworkRequestKey == requestKey else {
                            return
                        }
                        self.currentCoverImage = image
                        self.artworkDecodeTask = nil
                        self.artworkLoadKey = nil
                        self.updateNowPlayingInfo()
                    }
                }
                self.artworkDecodeTask = decodeTask
            }
        }
        artworkDataTask = request
        request.resume()
    }

    private var currentArtworkRequestKey: String {
        let coverURL = currentCoverUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(currentBookId ?? "")|\(coverURL)"
    }

    private func cancelArtworkLoad() {
        artworkRequestGeneration &+= 1
        artworkDataTask?.cancel()
        artworkDataTask = nil
        artworkDecodeTask?.cancel()
        artworkDecodeTask = nil
        artworkLoadKey = nil
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Public Methods

    func setBook(id: String, title: String, chapterTitle: String?, coverUrl: String?) {
        cancelArtworkLoad()
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

    @discardableResult
    func clearBook(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        let effectiveSession = token
        guard playbackOwnership.permitsQueueMutation(effectiveSession) else { return false }
        cancelArtworkLoad()
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
        _ = playbackOwnership.attachQueue(to: effectiveSession)
        clearNowPlayingInfo()
        return true
    }

    @discardableResult
    func clearQueue(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        let effectiveSession = token
        guard playbackOwnership.permitsQueueMutation(effectiveSession) else { return false }
        print("🔊 clearQueue: Stopping and clearing \(segmentsQueue.count) segments")
        stop()
        segmentsQueue.removeAll()
        currentSegmentIndex = 0
        gatedSegmentIndex = nil
        canStartQueuedSegment = nil
        moreSegmentsExpected = false
        isWaitingForNextSegment = false
        _ = playbackOwnership.attachQueue(to: effectiveSession)
        return true
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

    @discardableResult
    func loadSegment(
        _ segment: AudioSegment,
        autoPlay: Bool = true,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        let effectiveSession = token
        guard playbackOwnership.permitsQueueMutation(effectiveSession) else { return false }
        if segmentsQueue.isEmpty {
            guard playbackOwnership.attachQueue(to: effectiveSession) else { return false }
        } else {
            guard playbackOwnership.queueSession == effectiveSession else { return false }
        }
        print("🔊 loadSegment: Adding segment \(segment.segmentIndex) for paragraph \(segment.paragraphIndex), queueCount will be \(segmentsQueue.count + 1), waiting=\(isWaitingForNextSegment)")
        ReaderRunLog.write(
            "AUDIO enqueue segment=\(segment.id) queue=\(segmentsQueue.count + 1) " +
            "waiting=\(isWaitingForNextSegment ? "Y" : "N") " +
            "auto=\(autoPlay ? "Y" : "N")"
        )
        segmentsQueue.append(segment)

        guard !playbackSuspendedByInterruption else {
            isWaitingForNextSegment = false
            print("🔊 loadSegment: Queued while interrupted; waiting for user resume")
            return true
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
        return true
    }

    @discardableResult
    func loadSegments(
        _ segments: [AudioSegment],
        autoPlay: Bool = true,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        let effectiveSession = token
        guard playbackOwnership.permitsQueueMutation(effectiveSession) else { return false }
        print("🔊 loadSegments: Received \(segments.count) segments")

        // Clear existing queue and stop current playback, while retaining the
        // exact files pre-staged for this incoming paragraph.
        stop(preservingPrestagedIDs: Set(segments.map(\.id)))
        segmentsQueue.removeAll()
        currentSegmentIndex = 0
        _ = playbackOwnership.attachQueue(to: effectiveSession)

        // Add new segments
        segmentsQueue.append(contentsOf: segments)

        // Start playback from the first segment
        if !segmentsQueue.isEmpty, autoPlay {
            print("🔊 loadSegments: Starting playSegment(at: 0)")
            playSegment(at: 0)
        } else {
            print("🔴 loadSegments: No segments to play!")
        }
        return true
    }

    /// Append fully prepared audio behind the current queue without stopping or
    /// replacing the playing AVPlayerItem. This is intentionally separate from
    /// `loadSegments`, whose replace-and-start semantics are correct for jumps
    /// but would create an audible page-boundary gap for Kindle.
    @discardableResult
    func appendPreparedSegmentsForContinuousPlayback(
        _ segments: [AudioSegment],
        session token: AudioPlaybackSessionToken? = nil
    ) -> String? {
        let effectiveSession: AudioPlaybackSessionToken?
        if let token {
            effectiveSession = token
        } else if let coordinator = activeCoordinatorSession(owner: .readAloud) {
            // WebReaderBridge/KindleBookView are page coordinators for the
            // currently active Read VM. Nil is intentionally accepted only for
            // this narrow, owner-checked seamless-handoff operation.
            effectiveSession = coordinator
        } else {
            effectiveSession = nil
        }
        guard playbackOwnership.permitsQueueMutation(effectiveSession),
              playbackOwnership.queueSession == effectiveSession else { return nil }
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

    // MARK: Boundary pre-staging

    /// Files written ahead of playback, keyed by segment id.
    ///
    /// Measured on device, a paragraph boundary spends 50–72ms between staging
    /// a segment and the item reporting `readyToPlay` — the disk write plus the
    /// asset parse — and that shows up as a gap between paragraphs. Both can
    /// happen while the previous paragraph is still playing.
    private var stagedFiles: [String: URL] = [:]
    private var stagedWarmupTasks: [String: Task<Void, Never>] = [:]
    /// Bounded so a long prefetch chain cannot accumulate temp files.
    private static let maximumStagedFiles = 6

    /// Write these segments to disk and warm their assets now, so the boundary
    /// only has to hand an already-parsed URL to the player.
    ///
    /// Safe to call repeatedly: already-staged segments are skipped, and a
    /// failure simply leaves the ordinary in-line staging path to do the work.
    func prestageSegments(_ segments: [AudioSegment]) {
        guard !segments.isEmpty else { return }
        for segment in segments {
            guard stagedFiles[segment.id] == nil, !segment.audioData.isEmpty else { continue }
            if stagedFiles.count >= Self.maximumStagedFiles { break }
            let ext = segment.isWavFormat ? "wav" : "mp3"
            let url = AudioPlaybackTemporaryFiles.fileURL(
                in: playbackTemporaryDirectory,
                prefix: "prestage_",
                segmentID: segment.id,
                fileExtension: ext
            )
            do {
                try segment.audioData.write(to: url)
            } catch {
                continue
            }
            stagedFiles[segment.id] = url
            // Parsing the asset is the expensive half. Doing it here means the
            // item created at the boundary reaches `readyToPlay` almost at once.
            let asset = AVURLAsset(url: url)
            stagedWarmupTasks[segment.id]?.cancel()
            stagedWarmupTasks[segment.id] = Task.detached(priority: .utility) {
                _ = try? await asset.load(.duration, .tracks)
            }
        }
    }

    private func takeStagedFile(for segment: AudioSegment) -> URL? {
        guard let url = stagedFiles.removeValue(forKey: segment.id) else { return nil }
        // The warmup is normally already complete. Dropping our handle lets it
        // finish without making it part of the next playback session.
        stagedWarmupTasks.removeValue(forKey: segment.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Drop staged files that playback will never reach (jump, stop, new
    /// generation). Temp files are cheap but not free.
    func discardPrestagedSegments(
        preserving preservedIDs: Set<String> = []
    ) {
        let discardedIDs = Set(stagedFiles.keys).subtracting(preservedIDs)
        for id in discardedIDs {
            stagedWarmupTasks.removeValue(forKey: id)?.cancel()
            guard let url = stagedFiles.removeValue(forKey: id) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Remove only not-yet-played handoff items. The current and historical
    /// queue prefix is preserved so cancellation cannot cut audible playback.
    /// Returns false when one of the requested ids is already the current item.
    @discardableResult
    func removePendingSegments(withIDs ids: Set<String>) -> Bool {
        if let active = playbackOwnership.activeSession,
           active.owner != .readAloud {
            return false
        }
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
    func resumeGatedSegmentIfPossible(session token: AudioPlaybackSessionToken? = nil) {
        let effectiveSession: AudioPlaybackSessionToken?
        if let token {
            effectiveSession = token
        } else if playbackOwnership.activeSession != nil {
            guard let coordinator = activeCoordinatorSession(owner: .readAloud) else {
                return
            }
            effectiveSession = coordinator
        } else {
            effectiveSession = nil
        }
        guard playbackOwnership.permitsPlayback(
            requestedBy: effectiveSession
        ) else { return }
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
        autoPlay: Bool,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        let effectiveSession = token
        guard playbackOwnership.permitsPlayback(requestedBy: effectiveSession) else {
            return false
        }
        guard let index = segmentsQueue.firstIndex(where: { $0.id == id }) else { return false }
        playSegment(
            at: index,
            initialProgress: min(0.98, max(0, progress)),
            autoPlayWhenReady: autoPlay
        )
        return true
    }

    @discardableResult
    func play(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        guard playbackOwnership.permitsPlayback(requestedBy: token) else {
            return false
        }
        guard let player else {
            guard !segmentsQueue.isEmpty else {
                isPlaying = false
                updateNowPlayingInfo()
                return false
            }
            playbackSuspendedByInterruption = false
            let index = segmentsQueue.indices.contains(currentSegmentIndex) ? currentSegmentIndex : 0
            return playSegment(at: index)
        }
        guard currentItemCanPublishPlaybackState() else {
            return false
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
        return true
    }

    private func pauseRegardlessOfOwnership() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    /// Retain the queue for an explicit recovery/replay decision, but drop all
    /// producer-transient state owned by the outgoing session. Otherwise a
    /// cancelled stream can leave the next mode permanently "buffering".
    private func suspendQueueForOwnershipChange() {
        pauseRegardlessOfOwnership()
        moreSegmentsExpected = false
        isWaitingForNextSegment = false
        isBuffering = false
        gatedSegmentIndex = nil
    }

    @discardableResult
    func pause(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        guard playbackOwnership.permitsPlayback(requestedBy: token) else { return false }
        pauseRegardlessOfOwnership()
        return true
    }

    @discardableResult
    func togglePlayPause(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        guard playbackOwnership.permitsPlayback(requestedBy: token) else {
            return false
        }
        if isPlaying {
            return pause(session: token)
        } else {
            return play(session: token)
        }
    }

    func stop() {
        stop(preservingPrestagedIDs: [])
    }

    private func stop(preservingPrestagedIDs: Set<String>) {
        print("🔊 stop(): Stopping playback, player=\(player != nil ? "exists" : "nil")")
        removeTimeObserver()
        player?.pause()
        player = nil
        playerItem = nil
        playerItemSession = nil
        playerItemStatusCancellable?.cancel()
        playerItemStatusCancellable = nil
        playerStateCancellable?.cancel()
        playerStateCancellable = nil
        playerItemReadinessWorkItem?.cancel()
        playerItemReadinessWorkItem = nil
        playbackSuspendedByInterruption = false
        isPlaying = false
        currentTime = 0
        duration = 0
        currentSegment = nil
        gatedSegmentIndex = nil
        isBuffering = false
        isWaitingForNextSegment = false
        // 清理临时文件
        if let tempURL = currentTempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
            currentTempFileURL = nil
        }
        discardPrestagedSegments(preserving: preservingPrestagedIDs)
        AudioPlaybackTemporaryFiles.removeOwnedContents(
            in: playbackTemporaryDirectory,
            preserving: Set(stagedFiles.values)
        )
        print("🔊 stop(): Playback stopped, currentSegment is now nil")
    }

    @discardableResult
    func seek(
        to time: Double,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        guard playbackOwnership.permitsPlayback(requestedBy: token) else { return false }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime)
        currentTime = time
        updateNowPlayingElapsedTime()
        return true
    }

    @discardableResult
    func seekToProgress(
        _ progress: Double,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        let time = duration * progress
        return seek(to: time, session: token)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.playImmediately(atRate: rate)
        }
        updateNowPlayingInfo()
    }

    @discardableResult
    func skipForward(
        seconds: Double = 15,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        let newTime = min(currentTime + seconds, duration)
        return seek(to: newTime, session: token)
    }

    @discardableResult
    func skipBackward(
        seconds: Double = 15,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        let newTime = max(currentTime - seconds, 0)
        return seek(to: newTime, session: token)
    }

    @discardableResult
    func nextSegment(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        let effectiveSession: AudioPlaybackSessionToken?
        if let token {
            effectiveSession = token
        } else if playbackOwnership.activeSession != nil {
            guard let coordinator = activeCoordinatorSession(owner: .readAloud) else {
                return false
            }
            effectiveSession = coordinator
        } else {
            effectiveSession = nil
        }
        guard playbackOwnership.permitsPlayback(
            requestedBy: effectiveSession
        ) else { return false }
        print("🔊 nextSegment: currentIndex=\(currentSegmentIndex), queueCount=\(segmentsQueue.count), moreExpected=\(moreSegmentsExpected)")
        if currentSegmentIndex < segmentsQueue.count - 1 {
            print("🔊 nextSegment: Playing next segment at index \(currentSegmentIndex + 1)")
            ReaderRunLog.write(
                "AUDIO advance segment from=\(currentSegment?.id ?? "nil") " +
                "to=\(segmentsQueue[currentSegmentIndex + 1].id)"
            )
            return playSegment(at: currentSegmentIndex + 1)
        } else if moreSegmentsExpected {
            // TTS is still generating segments, wait for them
            print("🔊 nextSegment: No more segments in queue but TTS still loading, waiting...")
            isWaitingForNextSegment = true
            isBuffering = true
            ReaderRunLog.write(
                "AUDIO queue drained while producer active segment=\(currentSegment?.id ?? "nil")"
            )
        } else {
            print("🔊 nextSegment: No more segments and TTS complete, calling onPlaybackComplete")
            ReaderRunLog.write(
                "AUDIO queue complete segment=\(currentSegment?.id ?? "nil") " +
                "queue=\(segmentsQueue.count)"
            )
            onPlaybackComplete?()
        }
        return true
    }

    @discardableResult
    func previousSegment(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        guard playbackOwnership.permitsPlayback(requestedBy: token) else { return false }
        if currentSegmentIndex > 0 {
            return playSegment(at: currentSegmentIndex - 1)
        } else {
            return seek(to: 0, session: token)
        }
    }

    // MARK: - Private Methods

    @discardableResult
    private func playSegment(
        at index: Int,
        initialProgress: Double? = nil,
        autoPlayWhenReady: Bool = true
    ) -> Bool {
        let expectedSession = playbackOwnership.queueSession
        guard playbackOwnership.permitsPlayback(requestedBy: expectedSession) else {
            return false
        }
        guard index >= 0 && index < segmentsQueue.count else {
            print("🔴 playSegment: index \(index) out of range (queue size: \(segmentsQueue.count))")
            return false
        }

        let segment = segmentsQueue[index]
        if let canStartQueuedSegment, !canStartQueuedSegment(segment) {
            gatedSegmentIndex = index
            isPlaying = false
            isBuffering = true
            updateNowPlayingInfo()
            print("🔊 playSegment[\(index)]: Held by queue-boundary gate")
            return false
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
        ReaderRunLog.write(
            "AUDIO stage segment=\(segment.id) index=\(index)/\(segmentsQueue.count) " +
            "duration=\(String(format: "%.2f", segment.duration))"
        )

        print("🔊 playSegment[\(index)]: audioData size: \(segment.audioData.count), duration: \(segment.duration)")

        // A paragraph boundary is the one moment where this work is audible, so
        // reuse the file the prefetch already staged when there is one.
        if let staged = takeStagedFile(for: segment) {
            currentTempFileURL = staged
            ReaderRunLog.write("AUDIO stage reused segment=\(segment.id)")
            playAudio(
                from: staged,
                initialProgress: initialProgress,
                autoPlayWhenReady: autoPlayWhenReady,
                expectedSession: expectedSession
            )
            return true
        }

        // Create temporary file for audio data
        // Use .wav extension for local TTS (WAV format) or .mp3 for cloud TTS
        let fileExtension = segment.isWavFormat ? "wav" : "mp3"
        let tempURL = AudioPlaybackTemporaryFiles.fileURL(
            in: playbackTemporaryDirectory,
            prefix: "segment_",
            segmentID: segment.id,
            fileExtension: fileExtension
        )
        currentTempFileURL = tempURL

        do {
            try segment.audioData.write(to: tempURL)
            print("🔊 playSegment[\(index)]: Written to \(tempURL.lastPathComponent), calling playAudio")
            playAudio(
                from: tempURL,
                initialProgress: initialProgress,
                autoPlayWhenReady: autoPlayWhenReady,
                expectedSession: expectedSession
            )
            return true
        } catch {
            let message = error.localizedDescription
            ReaderRunLog.write(
                "AUDIO failed to stage segment=\(segment.id) error=\(message)"
            )
            print("🔴 playSegment[\(index)]: Failed to write audio data: \(error)")
            isBuffering = false
            isPlaying = false
            updateNowPlayingInfo()
            onPlaybackError?(message)
            return false
        }
    }

    private func playAudio(
        from url: URL,
        initialProgress: Double? = nil,
        autoPlayWhenReady: Bool = true,
        expectedSession: AudioPlaybackSessionToken?
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
        playerItemSession = expectedSession
        reportedPlaybackFailureItemID = nil
        playerItemReadinessWorkItem?.cancel()
        playerItemReadinessWorkItem = nil

        // Create or update player
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        observePlayerPlaybackState()

        isBuffering = true

        // Observe player item status
        guard let observedItem = playerItem else { return }
        playerItemStatusCancellable?.cancel()
        playerItemStatusCancellable = observedItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak observedItem] status in
                guard let self = self else { return }
                guard let observedItem,
                      observedItem === self.playerItem,
                      self.currentItemCanPublishPlaybackState() else {
                    return
                }
                switch status {
                case .readyToPlay:
                    self.playerItemReadinessWorkItem?.cancel()
                    self.playerItemReadinessWorkItem = nil
                    self.isBuffering = false
                    let seconds = observedItem.duration.seconds
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
                            guard let self,
                                  expectedItem === self.playerItem,
                                  self.currentItemCanPublishPlaybackState() else { return }
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
                    ReaderRunLog.write(
                        "AUDIO ready segment=\(self.currentSegment?.id ?? "nil") " +
                        "duration=\(String(format: "%.2f", seconds)) " +
                        "auto=\(autoPlayWhenReady ? "Y" : "N")"
                    )
                    print("Audio ready to play, duration: \(seconds)")
                case .failed:
                    self.playerItemReadinessWorkItem?.cancel()
                    self.playerItemReadinessWorkItem = nil
                    let message =
                        observedItem.error?.localizedDescription
                            ?? "Unknown audio error"
                    self.reportPlaybackFailure(
                        for: observedItem,
                        message: message
                    )
                default:
                    break
                }
            }

        let readinessItemID = ObjectIdentifier(observedItem)
        let readinessWorkItem = DispatchWorkItem { [weak self, weak observedItem] in
            guard let self,
                  let observedItem,
                  observedItem === self.playerItem,
                  ObjectIdentifier(observedItem) == readinessItemID,
                  observedItem.status == .unknown,
                  self.currentItemCanPublishPlaybackState() else { return }
            self.playerItemReadinessWorkItem = nil
            self.reportPlaybackFailure(
                for: observedItem,
                message: AppLocalized("音频准备超时，请重试")
            )
        }
        playerItemReadinessWorkItem = readinessWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 12,
            execute: readinessWorkItem
        )

        // Add time observer
        addTimeObserver()

        // Observe when playback ends
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerFailedToPlayToEnd),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem
        )
    }

    private var lastNowPlayingUpdateTime: Double = 0

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600) // 50ms updates for smooth highlighting
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  self.currentItemCanPublishPlaybackState() else { return }
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
        guard currentItemCanPublishPlaybackState() else {
            return
        }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if waiting {
            isBuffering = true
        } else if playerItem?.status == .readyToPlay
                    || playerItem?.status == .failed {
            isBuffering = false
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
        ReaderRunLog.write(
            "AUDIO state reason=\(reason) " +
            "actual=\(actuallyPlaying ? "playing" : "paused") " +
            "waiting=\(waiting ? "Y" : "N") " +
            "rate=\(String(format: "%.2f", player.rate)) " +
            "segment=\(currentSegment?.id ?? "nil")"
        )
        isPlaying = actuallyPlaying
        updateNowPlayingInfo()
    }

    private func removeTimeObserver() {
        playerItemReadinessWorkItem?.cancel()
        playerItemReadinessWorkItem = nil
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        NotificationCenter.default.removeObserver(
            self,
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem
        )
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        guard let finishedItem = notification.object as? AVPlayerItem else {
            return
        }
        let itemID = ObjectIdentifier(finishedItem)
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePlayerDidFinishPlaying(itemID: itemID)
            }
            return
        }
        handlePlayerDidFinishPlaying(itemID: itemID)
    }

    private func handlePlayerDidFinishPlaying(itemID: ObjectIdentifier) {
        guard let currentItem = playerItem,
              ObjectIdentifier(currentItem) == itemID,
              currentItemCanPublishPlaybackState() else {
            // A replaced item may publish its terminal notification after the
            // next segment has started. Stale callbacks have no authority to
            // pause or otherwise mutate the new current item.
            return
        }
        let finishedSession = playerItemSession
        print("🔊 playerDidFinishPlaying: Segment finished, currentIndex=\(currentSegmentIndex)")
        ReaderRunLog.write(
            "AUDIO item finished segment=\(currentSegment?.id ?? "nil") " +
            "index=\(currentSegmentIndex)/\(segmentsQueue.count)"
        )
        onSegmentComplete?()
        guard let currentItemAfterCallback = playerItem,
              ObjectIdentifier(currentItemAfterCallback) == itemID,
              playbackOwnership.permitsCallback(from: finishedSession) else {
            return
        }
        _ = nextSegment(session: finishedSession)
    }

    @objc private func playerFailedToPlayToEnd(_ notification: Notification) {
        guard let failedItem = notification.object as? AVPlayerItem else {
            return
        }
        let itemID = ObjectIdentifier(failedItem)
        let message =
            (notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? Error)?.localizedDescription
                ?? failedItem.error?.localizedDescription
                ?? "Unknown audio error"
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePlayerFailedToPlayToEnd(
                    itemID: itemID,
                    message: message
                )
            }
            return
        }
        handlePlayerFailedToPlayToEnd(
            itemID: itemID,
            message: message
        )
    }

    private func handlePlayerFailedToPlayToEnd(
        itemID: ObjectIdentifier,
        message: String
    ) {
        guard let currentItem = playerItem,
              ObjectIdentifier(currentItem) == itemID,
              currentItemCanPublishPlaybackState() else {
            return
        }
        reportPlaybackFailure(for: currentItem, message: message)
    }

    private func reportPlaybackFailure(
        for item: AVPlayerItem,
        message: String
    ) {
        let itemID = ObjectIdentifier(item)
        guard reportedPlaybackFailureItemID != itemID else { return }
        reportedPlaybackFailureItemID = itemID
        playerItemReadinessWorkItem?.cancel()
        playerItemReadinessWorkItem = nil
        player?.pause()
        isBuffering = false
        isPlaying = false
        ReaderRunLog.write(
            "AUDIO player item failed segment=\(currentSegment?.id ?? "nil") " +
            "error=\(message)"
        )
        print("Player item failed: \(message)")
        updateNowPlayingInfo()
        onPlaybackError?(message)
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
