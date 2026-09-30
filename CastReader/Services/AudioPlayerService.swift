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
import CryptoKit

enum AudioPlaybackOwner: String, Equatable, Sendable {
    case readAloud
    case explain
    case kindleBackgroundProbe
    case systemSpeech
}

struct AudioExternalPlaybackControls {
    let title: String
    let play: () -> Void
    let pause: () -> Void
    let stop: () -> Void
    let next: () -> Void
    let previous: () -> Void
}

struct AudioPlaybackSessionToken: Equatable, Hashable, Sendable {
    let owner: AudioPlaybackOwner
    let generation: UInt64
}

struct AudioPlaybackResumeHandle: Equatable, Sendable {
    fileprivate let session: AudioPlaybackSessionToken?
    fileprivate let segmentID: String
    fileprivate let bookID: String?
    fileprivate let intentRevision: UInt64
}

/// One local rebuild per selected item. A failed retry remains terminal until
/// the caller explicitly selects/regenerates audio; readiness alone cannot
/// replenish the budget for a corrupt item that repeatedly fails at playback.
struct AudioPlaybackRecoveryBudget {
    private(set) var attempts = 0
    private(set) var isTerminal = false

    mutating func claimRetry() -> Bool {
        guard attempts < 1, !isTerminal else {
            isTerminal = true
            return false
        }
        attempts += 1
        return true
    }
}

struct AudioPlaybackProgressEvidence {
    private var previousPosition: Double?
    private var previousWasPlaying = false
    private(set) var hasAdvanced = false

    mutating func observe(position: Double, actuallyPlaying: Bool) {
        guard position.isFinite, position >= 0 else { return }
        defer {
            previousPosition = position
            previousWasPlaying = actuallyPlaying
        }
        guard actuallyPlaying, previousWasPlaying, let previousPosition,
              position > previousPosition + 0.005 else { return }
        hasAdvanced = true
    }
}

enum AudioPlaybackFailureStage: String, Codable {
    case staging = "file_write_failed"
    case itemStatus = "player_status_failed"
    case itemEnd = "player_end_failed"
    case readiness = "player_ready_timeout"
    case resume = "player_resume_failed"
}

/// Only bounded machine values leave the error boundary. NSError descriptions,
/// userInfo, paths, URLs, document text and account identifiers are never stored.
struct AudioPlaybackFailureDiagnostic: Codable {
    let timestamp: Double
    let stage: AudioPlaybackFailureStage
    let errors: [String]
    let byteCount: Int
    let mediaKind: String
    let fileExists: Bool
    let fileBytes: Int?
    let itemStatus: Int?
    let playerStatus: Int?
    let timeControlStatus: Int?
    let position: Double
    let recoveryAttempt: Int

    var analyticsCode: String {
        var code = stage.rawValue
        for error in errors.prefix(2) where code.count + error.count + 1 <= 64 {
            code += "_" + error
        }
        return code
    }

    static func errorCodes(_ error: Error?) -> [String] {
        var codes: [String] = []
        var current = error as NSError?
        while let value = current, codes.count < 3 {
            let domain: String
            switch value.domain {
            case AVFoundationErrorDomain: domain = "av"
            case NSOSStatusErrorDomain: domain = "os"
            case NSPOSIXErrorDomain: domain = "posix"
            case NSCocoaErrorDomain: domain = "cocoa"
            case NSURLErrorDomain: domain = "url"
            default: domain = "other"
            }
            let decimal = String(value.code)
            let number = decimal.hasPrefix("-") ? "n" + decimal.dropFirst() : "p" + decimal
            codes.append("\(domain)_\(number)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return codes
    }

    static func mediaKind(_ data: Data) -> String {
        let bytes = Array(data.prefix(12))
        if bytes.isEmpty { return "empty" }
        if bytes.starts(with: [0x49, 0x44, 0x33]) { return "mp3_id3" }
        if bytes.count >= 2, bytes[0] == 0xff, bytes[1] & 0xe0 == 0xe0 { return "mpeg_audio" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes.suffix(4) == [0x57, 0x41, 0x56, 0x45] { return "wav" }
        if bytes.starts(with: [0x4f, 0x67, 0x67, 0x53]) { return "ogg" }
        if bytes.count >= 8, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return "mp4" }
        return "unknown"
    }
}

enum AudioPlaybackDiagnostics {
    private static let queue = DispatchQueue(label: "com.same.castreader.audio-diagnostics")

    static func record(_ diagnostic: AudioPlaybackFailureDiagnostic) {
        queue.async {
            guard let data = try? JSONEncoder().encode(diagnostic),
                  let line = String(data: data, encoding: .utf8) else { return }
            NSLog("CRAudio %@", line)
            guard let directory = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("audio-playback-diagnostics.jsonl")
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let retained = old.split(separator: "\n").suffix(47).map(String.init)
            let output = (retained + [line]).joined(separator: "\n") + "\n"
            try? Data(output.utf8).write(to: url, options: .atomic)
        }
    }
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

    mutating func invalidateAll() {
        activeSession = nil
        queueSession = nil
        // Never reuse a token after sign-out: detached callbacks may still exist.
        nextGeneration &+= 1
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
    let sleepTimer = PlaybackSleepTimer()
    private var externalPlayback: (token: AudioPlaybackSessionToken, controls: AudioExternalPlaybackControls)?
    private var ownershipRevoked: (() -> Void)?
    private var playbackIntentRevision: UInt64 = 0

    /// Shares ownership, interruption, sleep and remote controls with system
    /// speech while keeping AVPlayer's segment/timestamp pipeline intact.
    func attachSystemSpeech(_ controls: AudioExternalPlaybackControls) -> AudioPlaybackSessionToken {
        let token = claimPlaybackSession(owner: .systemSpeech)
        _ = clearQueue(session: token)
        externalPlayback = (token, controls)
        cancelArtworkLoad()
        currentBookId = nil
        currentBookTitle = nil
        currentChapterTitle = nil
        currentCaption = nil
        currentCoverUrl = nil
        currentCoverImage = nil
        setExternalSeekCommands(enabled: false)
        updateNowPlayingInfo()
        return token
    }

    func publishSystemSpeech(token: AudioPlaybackSessionToken, speaking: Bool, preparing: Bool) {
        guard externalPlayback?.token == token, isPlaybackSessionActive(token) else { return }
        isPlaying = speaking
        isBuffering = preparing
        updateNowPlayingInfo()
    }

    private func detachExternalPlayback() {
        guard let previous = externalPlayback else { return }
        externalPlayback = nil
        previous.controls.stop()
        setExternalSeekCommands(enabled: true)
    }

    func stopSystemSpeechForLibraryBoundary() {
        guard externalPlayback != nil else { return }
        stop()
        clearNowPlayingInfo()
    }

    private func setExternalSeekCommands(enabled: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipForwardCommand.isEnabled = enabled
        commands.skipBackwardCommand.isEnabled = enabled
        commands.changePlaybackPositionCommand.isEnabled = enabled
    }
    private var readerAppearanceHold: (id: UUID, session: AudioPlaybackSessionToken?, resume: AudioPlaybackResumeHandle?)?

    /// Layout changes must not race a late TTS item or an automatic page turn.
    /// Bind the hold to its owner so changing books cannot suspend another reader.
    func beginReaderAppearance() -> UUID {
        if let hold = readerAppearanceHold, hold.session == playbackOwnership.activeSession { return hold.id }
        let resume = suspendActivePlaybackForVoicePreview()
        let id = UUID()
        readerAppearanceHold = (id, playbackOwnership.activeSession, resume)
        return id
    }

    func endReaderAppearance(_ id: UUID, resumePlayback: Bool = true) {
        guard let hold = readerAppearanceHold, hold.id == id else { return }
        readerAppearanceHold = nil
        if resumePlayback, let resume = hold.resume {
            _ = resumePlaybackAfterVoicePreview(resume)
        }
    }

    private struct PresentationBoundary {
        let id: UUID
        let session: AudioPlaybackSessionToken
        let segmentID: String
        let time: Double
        let continuationTime: Double
        let atItemEnd: Bool
        let reached: (UUID) -> Void
    }
    private var presentationBoundary: PresentationBoundary?
    private var presentationObserver: (player: AVPlayer, token: Any)?
    private var presentationDeadlineObserver: (player: AVPlayer, token: Any)?
    private var presentationHold: PresentationBoundary?
    private var presentationSuspended = false
    private var presentationMediaLimit: (itemID: ObjectIdentifier, time: Double)?
    var pagePresentationHoldID: UUID? { presentationHold?.id }

    /// The actual media clock owns this edge. A UI poll and a character ratio
    /// cannot authorize playback into an unpainted page.
    @discardableResult
    func armPagePresentationBoundary(segmentID: String, time: Double,
        session: AudioPlaybackSessionToken, atItemEnd: Bool = false,
        continuationTime: Double? = nil, reached: @escaping (UUID) -> Void) -> Bool {
        guard playbackOwnership.permitsPlayback(requestedBy: session),
              time.isFinite, time >= 0, presentationHold == nil else { return false }
        let deadline = continuationTime.flatMap { $0.isFinite && $0 >= time ? $0 : nil } ?? time
        if let edge = presentationBoundary, edge.session == session,
           edge.segmentID == segmentID, edge.time == time, edge.atItemEnd == atItemEnd,
           edge.continuationTime == deadline { return true }
        removePresentationObserver()
        if playerItem?.forwardPlaybackEndTime.isValid == true { playerItem?.forwardPlaybackEndTime = .invalid }
        presentationBoundary = PresentationBoundary(id: UUID(), session: session,
            segmentID: segmentID, time: time, continuationTime: deadline, atItemEnd: atItemEnd, reached: reached)
        ReaderRunLog.write("PAGINATION boundary_armed segment=\(segmentID) cue=\(time) deadline=\(deadline) generation=\(session.generation)")
        installPresentationObserver()
        return true
    }

    private func removePresentationObserver() {
        if let observer = presentationObserver { observer.player.removeTimeObserver(observer.token) }
        if let observer = presentationDeadlineObserver { observer.player.removeTimeObserver(observer.token) }
        presentationObserver = nil
        presentationDeadlineObserver = nil
    }

    private func installPresentationObserver() {
        guard presentationObserver == nil, let edge = presentationBoundary,
              edge.segmentID == currentSegment?.id,
              playbackOwnership.permitsPlayback(requestedBy: edge.session), let player else { return }
        if edge.atItemEnd {
            // Container duration and server estimates may include MP3 padding.
            // Only the real item-end notification can authorize this turn.
            if currentItemDrained { reachPresentationBoundary(edge, player: player) }
            return
        }
        if let item = playerItem, edge.continuationTime > playbackPosition,
           edge.continuationTime < (currentSegment?.duration ?? 0) - 0.001 {
            // AVPlayer itself stops at the source edge, even when the main
            // executor is busy painting and delivers its observer late.
            item.forwardPlaybackEndTime = CMTime(seconds: edge.continuationTime, preferredTimescale: 1_000_000)
            presentationMediaLimit = (ObjectIdentifier(item), edge.continuationTime)
        }
        if edge.continuationTime > edge.time {
            let token = player.addBoundaryTimeObserver(forTimes: [NSValue(time:
                CMTime(seconds: edge.continuationTime, preferredTimescale: 1_000_000))], queue: .main) { [weak self, weak player] in
                guard let self, let player else { return }
                self.reachPresentationBoundary(edge, player: player)
                self.suspendForPresentationIfNeeded(edge, player: player)
            }
            presentationDeadlineObserver = (player, token)
        }
        let reached = { [weak self, weak player] in
            guard let self, let player else { return }
            self.reachPresentationBoundary(edge, player: player)
        }
        if playbackPosition >= edge.time && hasPlaybackRequest {
            // A late producer must hold immediately, never seek backwards and
            // replay already audible content. Diagnostics retain the overshoot.
            reached()
        } else {
            let token = player.addBoundaryTimeObserver(forTimes: [NSValue(time:
                CMTime(seconds: edge.time, preferredTimescale: 1_000_000))], queue: .main, using: reached)
            presentationObserver = (player, token)
        }
    }

    private func reachPresentationBoundary(_ edge: PresentationBoundary, player: AVPlayer) {
        guard player === self.player, presentationBoundary?.id == edge.id,
              playbackOwnership.permitsPlayback(requestedBy: edge.session),
              currentSegment?.id == edge.segmentID, hasPlaybackRequest else { return }
        if let observer = presentationObserver { observer.player.removeTimeObserver(observer.token) }
        presentationObserver = nil
        presentationBoundary = nil
        presentationHold = edge
        presentationSuspended = false
        currentTime = playbackPosition
        ReaderRunLog.write("PAGINATION visual_requested id=\(edge.id) time=\(currentTime) cue=\(edge.time) deadline=\(edge.continuationTime) mono=\(ProcessInfo.processInfo.systemUptime)")
        if currentItemDrained || playbackPosition + 0.001 >= edge.continuationTime {
            suspendForPresentationIfNeeded(edge, player: player)
        }
        edge.reached(edge.id)
    }

    private func suspendForPresentationIfNeeded(_ edge: PresentationBoundary, player: AVPlayer) {
        guard player === self.player, presentationHold?.id == edge.id,
              !presentationSuspended, playbackOwnership.permitsPlayback(requestedBy: edge.session),
              currentSegment?.id == edge.segmentID else { return }
        presentationSuspended = true
        player.pause()
        currentTime = playbackPosition
        isPlaying = false
        isBuffering = true
        updateNowPlayingInfo()
        ReaderRunLog.write("PAGINATION visual_hold id=\(edge.id) generation=\(edge.session.generation) time=\(currentTime) cue=\(edge.time) mono=\(ProcessInfo.processInfo.systemUptime)")
        if !currentItemDrained, player.status == .readyToPlay {
            // The native endpoint protected the page even while the UI was
            // busy. Now paused, re-prime the same decoder DURING rendering,
            // rather than waiting for the visual acknowledgement to warm it.
            if playerItem?.forwardPlaybackEndTime.isValid == true { playerItem?.forwardPlaybackEndTime = .invalid }
            player.preroll(atRate: playbackRate) { [weak self, weak player] ready in
                DispatchQueue.main.async {
                    guard let self, player === self.player,
                          self.presentationHold?.id == edge.id else { return }
                    ReaderRunLog.write("PAGINATION resume_prepared id=\(edge.id) ready=\(ready) mono=\(ProcessInfo.processInfo.systemUptime)")
                }
            }
        }
    }

    /// Called only after exact target identity and current anchor acknowledgement.
    /// Explicit Pause/Stop and a new owner always win over a late acknowledgement.
    @discardableResult
    func finishPagePresentation(_ id: UUID) -> Bool {
        guard let hold = presentationHold, hold.id == id,
              playbackOwnership.permitsPlayback(requestedBy: hold.session),
              currentSegment?.id == hold.segmentID else { return false }
        let wasSuspended = presentationSuspended
        removePresentationObserver()
        presentationHold = nil
        presentationSuspended = false
        if playerItem?.forwardPlaybackEndTime.isValid == true { playerItem?.forwardPlaybackEndTime = .invalid }
        isBuffering = false
        ReaderRunLog.write("PAGINATION visual_release id=\(id) time=\(playbackPosition) suspended=\(wasSuspended) intent=\(hasPlaybackRequest) mono=\(ProcessInfo.processInfo.systemUptime)")
        if currentItemDrained, let item = playerItem {
            // End notification can precede the page acknowledgement. Deliver
            // its completion once, then advance under the retained play intent.
            handlePlayerDidFinishPlaying(itemID: ObjectIdentifier(item))
        } else if wasSuspended && hasPlaybackRequest && !playbackSuspendedByInterruption {
            guard !hasTerminalPlaybackFailure else { return true }
            if playerItem?.status == .failed || player?.status == .failed {
                _ = recoverPlaybackFailure(stage: .resume, error: playerItem?.error ?? player?.error)
                return true
            }
            // This active session only paused for a page. Re-activating the
            // shared audio session here serializes OS work after page paint.
            player?.playImmediately(atRate: playbackRate)
            isPlaying = player?.timeControlStatus == .playing
            updateNowPlayingInfo()
        }
        return true
    }

    /// Exact native book-end evidence resolves a drained page, not a missing
    /// paint. Never use it to skip an unfinished cross-page source cue.
    @discardableResult
    func finishDrainedPageAtBookEnd() -> Bool {
        guard currentItemDrained, let hold = presentationHold, hold.atItemEnd else { return false }
        return finishPagePresentation(hold.id)
    }

    private func revokePagePresentation() {
        removePresentationObserver()
        if playerItem?.forwardPlaybackEndTime.isValid == true { playerItem?.forwardPlaybackEndTime = .invalid }
        presentationMediaLimit = nil
        presentationBoundary = nil
        presentationHold = nil
        presentationSuspended = false
    }

    private func permitsAutomaticPlayback() -> Bool {
        guard sleepTimer.permitsAutomaticPlayback(), presentationHold == nil else { return false }
        guard let hold = readerAppearanceHold else { return true }
        return hold.session != playbackOwnership.activeSession
    }

    // MARK: - Published Properties
    @Published var isPlaying = false
    /// Query the player at lifecycle boundaries instead of the last 100 ms UI tick.
    var playbackPosition: Double {
        let value = player?.currentTime().seconds ?? currentTime
        return value.isFinite && value >= 0 ? value : currentTime
    }

    @Published var currentTime: Double = 0
    /// Transport IDs (e.g. 0-0) repeat across pages. Async UI observers must
    /// bind each queued clock event to the actual media instance as well.
    var currentMediaIdentity: ObjectIdentifier? { playerItem.map(ObjectIdentifier.init) }
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
    @Published private(set) var hasAudibleProgress = false
    private(set) var recoveryBudget = AudioPlaybackRecoveryBudget()
    private(set) var lastPlaybackFailureCode: String?
    var hasTerminalPlaybackFailure: Bool { recoveryBudget.isTerminal }

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
    private var playbackRequested = false
    /// A held/retired next-page gate can be silent without becoming a user
    /// Pause. Keep the requested transport intent across that transient state.
    var hasPlaybackRequest: Bool {
        playbackRequested && !isExplicitlyPaused && !playbackSuspendedByInterruption
            && !hasTerminalPlaybackFailure
    }
    /// A user pause outlives a network wait and is distinct from natural item
    /// completion (where isPlaying is also false).
    private(set) var isExplicitlyPaused = false
    private var currentItemDrained = false
    private var currentItemCompletionDelivered = false
    private var queueCompletionDelivered = false
    private var progressEvidence = AudioPlaybackProgressEvidence()
    private var isSeekingInitialPosition = false

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

    /// Root navigation only needs this transition for review eligibility.
    /// Observing the entire player redraws every root tab on every audio tick.
    var reviewQuiescencePublisher: AnyPublisher<Bool, Never> {
        Publishers.CombineLatest4($isPlaying, $isBuffering, $moreSegmentsExpected, $isWaitingForNextSegment)
            .map { playing, buffering, expected, waiting in
                AppReviewPresentationGate.playbackIsQuiescent(
                    isPlaying: playing, isBuffering: buffering,
                    moreSegmentsExpected: expected, isWaitingForNextSegment: waiting)
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    /// Last item currently owned by the player queue. Kindle uses this as the
    /// boundary marker when it appends the already-generated first utterance of
    /// the next page. The marker lets the page turn begin shortly before the
    /// audio queue crosses that boundary without interrupting the current item.
    var queuedTailSegmentID: String? {
        segmentsQueue.last?.id
    }

    /// Capture before appending a next-page queue; its real media end owns the
    /// visual edge when a sentence finishes exactly at the current page end.
    func armQueuedTailPresentationBoundary(reached: @escaping (UUID) -> Void) -> Bool {
        guard let tail = segmentsQueue.last, let session = playbackOwnership.queueSession else { return false }
        let end = tail.id == currentSegment?.id && duration > 0 ? duration : tail.duration
        guard end.isFinite, end > 0 else { return false }
        return armPagePresentationBoundary(segmentID: tail.id, time: end, session: session, atItemEnd: true, reached: reached)
    }

    func cancelPendingPresentationBoundary(segmentID: String) {
        guard let edge = presentationBoundary, edge.segmentID == segmentID,
              playbackOwnership.permitsPlayback(requestedBy: edge.session) else { return }
        removePresentationObserver()
        if currentSegment?.id == segmentID {
            if playerItem?.forwardPlaybackEndTime.isValid == true { playerItem?.forwardPlaybackEndTime = .invalid }
        }
        presentationBoundary = nil
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
    func claimPlaybackSession(owner: AudioPlaybackOwner, onRevoked: (() -> Void)? = nil) -> AudioPlaybackSessionToken {
        // Checkpoint and cancel the outgoing producer before replacing its
        // queue. A late generation callback must never reclaim another window.
        let outgoing = ownershipRevoked
        ownershipRevoked = nil
        outgoing?()
        detachExternalPlayback()
        suspendQueueForOwnershipChange()
        let token = playbackOwnership.claim(owner)
        ownershipRevoked = onRevoked
        ReaderRunLog.write(
            "AUDIO session claimed owner=\(owner.rawValue) gen=\(token.generation)"
        )
        return token
    }

    func releasePlaybackSession(_ token: AudioPlaybackSessionToken) {
        guard playbackOwnership.activeSession == token else { return }
        ownershipRevoked = nil
        detachExternalPlayback()
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
        guard externalPlayback == nil else { return nil }
        guard let token = playbackOwnership.transferActiveQueue(to: owner) else {
            return nil
        }
        ownershipRevoked = nil
        if playerItem != nil {
            playerItemSession = token
        }
        return token
    }

    func setOwnershipRevocationHandler(for token: AudioPlaybackSessionToken, _ handler: @escaping () -> Void) {
        guard playbackOwnership.activeSession == token else { return }
        ownershipRevoked = handler
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
            bookID: currentBookId,
            intentRevision: playbackIntentRevision
        )
    }

    @discardableResult
    func resumePlaybackAfterVoicePreview(
        _ handle: AudioPlaybackResumeHandle
    ) -> Bool {
        guard playbackOwnership.activeSession == handle.session,
              playbackIntentRevision == handle.intentRevision,
              playbackOwnership.queueSession == handle.session,
              currentSegment?.id == handle.segmentID,
              currentBookId == handle.bookID,
              !isPlaying else {
            return false
        }
        return play(session: handle.session)
    }

    private func currentItemCanPublishPlaybackState() -> Bool {
        !hasTerminalPlaybackFailure && playbackOwnership.permitsCallback(from: playerItemSession)
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
        guard playbackOwnership.permitsQueueMutation(token), !hasTerminalPlaybackFailure else { return false }
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
                  self.permitsAutomaticPlayback(),
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
            self.publishDrainedQueueCompletion()
        }
        return true
    }

    // MARK: - Initialization
    private override init() {
        playbackTemporaryDirectory = AudioPlaybackTemporaryFiles.prepare()
        super.init()
        configureSleepTimer()
        setupAudioSession()
        setupRemoteCommandCenter()
    }

    private func configureSleepTimer() {
        sleepTimer.onExpiration = { [weak self] in
            guard let self else { return }
            self.pauseRegardlessOfOwnership()
            self.isBuffering = false
            ReaderRunLog.write("AUDIO sleep timer expired; explicit play required")
        }
    }

    #if DEBUG
    var currentItemForTesting: AVPlayerItem? { playerItem }
    private(set) var timeSampleForTesting: ((CMTime) -> Void)?
    /// Isolated player for offline failure/recovery tests; never claims remote
    /// commands or removes the application's playback directory.
    init(testTemporaryRoot: URL) {
        playbackTemporaryDirectory = AudioPlaybackTemporaryFiles.prepare(root: testTemporaryRoot)
        super.init()
        configureSleepTimer()
    }
    #endif

    private var audioSessionIsActive = false

    private func activateAudioSessionIfNeeded() throws {
        guard !audioSessionIsActive else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        audioSessionIsActive = true
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        ReaderRunLog.write("AUDIO route ports=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")) outputLatencyMs=\(session.outputLatency * 1_000) ioBufferMs=\(session.ioBufferDuration * 1_000) sampleRate=\(session.sampleRate)")
        #endif
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Playback provides AirPlay/A2DP output implicitly. The explicit
            // allowAirPlay option is valid only for playAndRecord.
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try activateAudioSessionIfNeeded()

            // 监听音频中断（来电、其他 app 播放等）
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioInterruption),
                name: AVAudioSession.interruptionNotification,
                object: session
            )

            NotificationCenter.default.addObserver(
                self, selector: #selector(handleMediaServicesReset),
                name: AVAudioSession.mediaServicesWereResetNotification, object: session
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

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioSessionIsActive = false
            self.playbackSuspendedByInterruption = true
            self.pauseRegardlessOfOwnership()
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            } catch { print("Failed to restore audio category: \(error)") }
            ReaderRunLog.write("AUDIO media services reset; explicit play required")
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
                self.audioSessionIsActive = false
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
                    try self.activateAudioSessionIfNeeded()
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
        sleepTimer.checkDeadline()
        syncPlaybackStateFromPlayer(reason: "app-active")
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.sleepTimer.resumeByUser()
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
        if let externalPlayback {
            // Speech callbacks provide text ranges, not a reliable duration.
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: externalPlayback.controls.title,
                MPMediaItemPropertyArtist: "CastReader",
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
            ]
            return
        }
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

        // 封面：优先当前账号 History 的本地封面；惰性加载一次后缓存。
        // 未激活账号作用域时绝不回读旧版 Documents/History。
        if currentCoverImage == nil, let id = currentBookId { currentCoverImage = Self.localCoverImage(forID: id) }
        if let image = currentCoverImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        } else if let coverUrlString = currentCoverUrl?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !coverUrlString.isEmpty,
                  let coverUrl = Self.makeArtworkURL(coverUrlString) {
            let routedCoverURL = coverUrl.absoluteString
            if let image = ImageCache.shared.get(routedCoverURL) {
                currentCoverImage = image
                nowPlayingInfo[MPMediaItemPropertyArtwork] =
                    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            } else {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                let requestKey = "\(currentBookId ?? "")|\(routedCoverURL)"
                if artworkLoadKey != requestKey {
                    loadArtwork(
                        from: coverUrl,
                        sourceURL: routedCoverURL,
                        requestKey: requestKey
                    )
                }
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }

    /// Reads only the active route x account History partition. The opaque
    /// scope pointer is shared with extensions and validated before it becomes
    /// a path component; a signed-out process deliberately has no local cover.
    static func localCoverImage(forID id: String) -> UIImage? {
        let cleanedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedID.isEmpty,
              cleanedID != ".",
              cleanedID != "..",
              cleanedID.utf8.count <= 255,
              !cleanedID.contains("/"),
              !cleanedID.contains("\\"),
              !cleanedID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let historyDirectory: URL
        #if DEBUG
        if AccountContentScopeBridge.usesLegacyTestingStorage {
            historyDirectory = docs.appendingPathComponent("History", isDirectory: true)
        } else {
            guard let storageID = AccountContentScopeBridge.activeStorageID else { return nil }
            historyDirectory = docs
                .appendingPathComponent("AccountData", isDirectory: true)
                .appendingPathComponent(storageID, isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
        }
        #else
        guard let storageID = AccountContentScopeBridge.activeStorageID else { return nil }
        historyDirectory = docs
            .appendingPathComponent("AccountData", isDirectory: true)
            .appendingPathComponent(storageID, isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        #endif

        let url = historyDirectory
            .appendingPathComponent("\(cleanedID).cover.jpg")
            .standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL
                == historyDirectory.standardizedFileURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private static func makeArtworkURL(_ raw: String) -> URL? {
        let parsed = URL(string: raw)
            ?? raw.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ).flatMap(URL.init(string:))
        return parsed.flatMap {
            OwnedAPIRedirectPolicy.routedResponseURL($0)
        }
    }

    private func loadArtwork(
        from url: URL,
        sourceURL: String,
        requestKey: String
    ) {
        cancelArtworkLoad()
        artworkLoadKey = requestKey
        let expectedGeneration = artworkRequestGeneration
        let request = OwnedAPIURLSession.shared.dataTask(with: url) { [weak self] data, response, error in
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
        let rawCoverURL = currentCoverUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coverURL = Self.makeArtworkURL(rawCoverURL)?.absoluteString ?? rawCoverURL
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
        guard !hasTerminalPlaybackFailure else { return false }
        segmentsQueue.append(segment)
        if segmentsQueue.count > currentSegmentIndex + 1 { prestageSegments([segment]) }

        guard permitsAutomaticPlayback() else { return true }
        guard !playbackSuspendedByInterruption else {
            isWaitingForNextSegment = false
            print("🔊 loadSegment: Queued while interrupted; waiting for user resume")
            return true
        }

        // If we were waiting for the next segment, play it now
        if isWaitingForNextSegment, autoPlay, !isExplicitlyPaused {
            print("🔊 loadSegment: Was waiting, now playing segment \(segmentsQueue.count - 1)")
            isWaitingForNextSegment = false
            return playSegment(at: segmentsQueue.count - 1)
        }
        // If this is the first segment and we're not playing, start playback
        else if autoPlay && !isExplicitlyPaused && segmentsQueue.count == 1 && !isPlaying {
            print("🔊 loadSegment: First segment, starting playback")
            return playSegment(at: 0)
        } else {
            // Retain the drained position when paused: Resume must start the
            // newly queued tail rather than replaying the completed prefix.
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
        let incomingIDs = Set(segments.map(\.id))
        let incomingBoundary = presentationBoundary.flatMap { edge in
            edge.session == effectiveSession && incomingIDs.contains(edge.segmentID) ? edge : nil
        }
        stop(preservingPrestagedIDs: Set(segments.map(\.id)))
        segmentsQueue.removeAll()
        currentSegmentIndex = 0
        _ = playbackOwnership.attachQueue(to: effectiveSession)
        // The VM validates and arms a promoted source cue before queue commit.
        // Retain only that incoming cue, never an old paragraph's hold.
        presentationBoundary = incomingBoundary

        // Add new segments
        segmentsQueue.append(contentsOf: segments)
        prestageSegments(segments)

        // Accept late generated audio into the queue, but do not start it after
        // a timer expiry. False is reserved for rejection/playback failure.
        guard permitsAutomaticPlayback() else { return true }

        // Start playback from the first segment
        if !segmentsQueue.isEmpty, autoPlay {
            print("🔊 loadSegments: Starting playSegment(at: 0)")
            return playSegment(at: 0)
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
        prestageSegments(segments)
        print("🔊 appendPreparedSegments: Added \(segments.count) segments after \(predecessor ?? "none")")

        guard permitsAutomaticPlayback() else { return predecessor }
        guard !playbackSuspendedByInterruption else {
            isWaitingForNextSegment = false
            return predecessor
        }
        if isWaitingForNextSegment, !isExplicitlyPaused {
            isWaitingForNextSegment = false
            playSegment(at: firstAppendedIndex)
        } else if currentSegment == nil, !isPlaying, !isExplicitlyPaused {
            playSegment(at: firstAppendedIndex)
        }
        return predecessor
    }

    // MARK: Boundary pre-staging

    /// A preparation lease owns both the decoded player and its file until
    /// `take` transfers them. Status/preroll callbacks never mutate the active
    /// queue. In particular, discarding an old page cannot pause an adopted player.
    private final class PreparedMedia {
        enum Ownership { case prepared, taken, released }
        let url: URL
        let player: AVPlayer
        let item: AVPlayerItem
        var segmentIDs: Set<String>
        private(set) var ownership = Ownership.prepared
        private(set) var decoded = false
        private var observation: AnyCancellable?
        private var prerollStarted = false
        private var preparationRate: Float
        private var prerollRevision = 0

        init(url: URL, segmentID: String, rate: Float) {
            self.url = url
            preparationRate = rate
            segmentIDs = [segmentID]
            item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain
            player = AVPlayer(playerItem: item)
            // preroll prepares at rate zero and does not emit audio. Changing
            // mute at takeover would reconfigure an already decoded renderer.
            observation = player.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self, self.ownership == .prepared,
                          status == .readyToPlay else { return }
                    self.prepare(rate: self.preparationRate)
                }
        }

        func prepare(rate: Float) {
            guard ownership == .prepared else { return }
            if preparationRate != rate {
                prerollRevision += 1
                player.cancelPendingPrerolls()
                preparationRate = rate
                prerollStarted = false
                decoded = false
            }
            guard player.status == .readyToPlay, !prerollStarted else { return }
            prerollStarted = true
            let revision = prerollRevision
            player.preroll(atRate: rate) { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self, self.ownership == .prepared,
                          self.prerollRevision == revision else { return }
                    self.decoded = finished
                    ReaderRunLog.write("AUDIO prepared decoded=\(finished) rate=\(rate) mono=\(ProcessInfo.processInfo.systemUptime)")
                }
            }
        }

        func take() {
            precondition(ownership == .prepared)
            ownership = .taken
            observation?.cancel()
            observation = nil
            if !decoded { player.cancelPendingPrerolls() }
        }

        func release() {
            guard ownership == .prepared else { return }
            ownership = .released
            observation?.cancel()
            observation = nil
            player.cancelPendingPrerolls()
            player.pause()
            player.replaceCurrentItem(with: nil)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // AudioSegment.id is page-local and reused when the voice changes. Full
    // audio bytes identify a lease; rebasing a segment for handoff preserves it.
    /// A prepared explanation owns this pin until it is taken or discarded.
    /// Clearing the previous page's queue cannot destroy the successor decoder.
    final class PreparedMediaLease {
        private let releasePin: () -> Void
        fileprivate init(release: @escaping () -> Void) { releasePin = release }
        deinit { releasePin() }
    }

    private var preparedMediaPins: [ObjectIdentifier: Int] = [:]

    func retainPreparedSegments(_ segments: [AudioSegment]) -> PreparedMediaLease {
        prestageSegments(segments)
        // A byte-identical segment can be prepared again after its predecessor
        // was taken. A lease pins that exact decoder, never a future cache entry.
        let entries = Set(segments.map(preparationKey)).compactMap { key in
            preparedMedia[key].map { (key, $0) }
        }
        for (_, media) in entries { preparedMediaPins[ObjectIdentifier(media), default: 0] += 1 }
        return PreparedMediaLease { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                for (key, media) in entries {
                    let identity = ObjectIdentifier(media)
                    let remaining = (self.preparedMediaPins[identity] ?? 0) - 1
                    if remaining > 0 {
                        self.preparedMediaPins[identity] = remaining
                    } else {
                        self.preparedMediaPins.removeValue(forKey: identity)
                        if self.preparedMedia[key] === media {
                            self.preparedMedia.removeValue(forKey: key)
                        }
                        media.release()
                    }
                }
            }
        }
    }

    private var preparedMedia: [String: PreparedMedia] = [:]
    private static let maximumPreparedMedia = 6

    private func preparationKey(_ segment: AudioSegment) -> String {
        SHA256.hash(data: segment.audioData).map { String(format: "%02x", $0) }.joined()
            + (segment.isWavFormat ? ".wav" : ".mp3")
    }

    func prestageSegments(_ segments: [AudioSegment]) {
        for segment in segments where !segment.audioData.isEmpty {
            let key = preparationKey(segment)
            if let existing = preparedMedia[key] {
                existing.segmentIDs.insert(segment.id)
                continue
            }
            guard preparedMedia.count < Self.maximumPreparedMedia else { break }
            let url = playbackTemporaryDirectory.appendingPathComponent("prepared_" + UUID().uuidString + "_" + key)
            do {
                try FileManager.default.createDirectory(at: playbackTemporaryDirectory, withIntermediateDirectories: true)
                try segment.audioData.write(to: url, options: .atomic)
                preparedMedia[key] = PreparedMedia(url: url, segmentID: segment.id, rate: playbackRate)
            } catch {
                ReaderRunLog.write("AUDIO preparation failed reason=file_stage")
            }
        }
    }

    private func takePreparedMedia(for segment: AudioSegment) -> PreparedMedia? {
        guard let media = preparedMedia.removeValue(forKey: preparationKey(segment)) else { return nil }
        guard FileManager.default.fileExists(atPath: media.url.path), media.item.status != .failed else {
            media.release()
            return nil
        }
        media.take()
        return media
    }

    func isPreparedForPlayback(_ segment: AudioSegment) -> Bool {
        guard let media = preparedMedia[preparationKey(segment)] else { return false }
        return media.ownership == .prepared && media.decoded && media.item.status == .readyToPlay
    }

    func discardPrestagedSegments(preserving preservedIDs: Set<String> = []) {
        for (key, media) in preparedMedia where media.segmentIDs.isDisjoint(with: preservedIDs)
            && preparedMediaPins[ObjectIdentifier(media), default: 0] == 0 {
            preparedMedia.removeValue(forKey: key)
            media.release()
        }
    }

    #if DEBUG
    func preparedMediaForTesting(_ segment: AudioSegment) -> (player: AVPlayer, decoded: Bool)? {
        preparedMedia[preparationKey(segment)].map { ($0.player, $0.decoded) }
    }
    var activePlayerForTesting: AVPlayer? { player }
    #endif

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
        guard !isExplicitlyPaused, !playbackSuspendedByInterruption,
              let index = gatedSegmentIndex else { return }
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
        initialTime: Double? = nil,
        autoPlay: Bool,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        let effectiveSession = token
        guard playbackOwnership.permitsPlayback(requestedBy: effectiveSession) else {
            return false
        }
        guard let index = segmentsQueue.firstIndex(where: { $0.id == id }) else { return false }
        return playSegment(
            at: index,
            initialProgress: min(0.98, max(0, progress)),
            initialTime: initialTime,
            autoPlayWhenReady: autoPlay
        )
    }

    @discardableResult
    func play(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        if presentationHold != nil {
            guard playbackOwnership.permitsPlayback(requestedBy: token) else { return false }
            playbackIntentRevision &+= 1
            isExplicitlyPaused = false
            playbackRequested = true
            return true
        }
        guard permitsAutomaticPlayback() else { return false }
        if let externalPlayback {
            guard token == externalPlayback.token, isPlaybackSessionActive(externalPlayback.token) else { return false }
            playbackIntentRevision &+= 1
            externalPlayback.controls.play()
            return true
        }
        guard playbackOwnership.permitsPlayback(requestedBy: token) else {
            return false
        }
        guard !hasTerminalPlaybackFailure else { return false }
        playbackIntentRevision &+= 1
        isExplicitlyPaused = false
        playbackRequested = true
        playbackSuspendedByInterruption = false
        if let index = gatedSegmentIndex {
            return playSegment(at: index)
        }
        if currentItemDrained {
            if currentSegmentIndex + 1 < segmentsQueue.count {
                return playSegment(at: currentSegmentIndex + 1)
            }
            // The producer or paragraph coordinator owns the next item. Never
            // resume an AVPlayerItem which has already emitted completion.
            if !moreSegmentsExpected { publishDrainedQueueCompletion() }
            return true
        }
        // A restored/replayed item must reach its requested position before
        // Play can emit audio. The readiness callback consumes this intent.
        if isSeekingInitialPosition { return true }
        if segmentsQueue.isEmpty, moreSegmentsExpected { return true }
        if playerItem?.status == .failed || player?.status == .failed
            || (currentTempFileURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false) {
            playbackRequested = true
            return recoverPlaybackFailure(stage: .resume, error: playerItem?.error ?? player?.error)
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
        playbackRequested = true
        progressEvidence = AudioPlaybackProgressEvidence()
        hasAudibleProgress = false
        do {
            try activateAudioSessionIfNeeded()
        } catch {
            print("❌ Failed to activate audio session before play: \(error)")
        }
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
        updateNowPlayingInfo()
        return true
    }

    private func pauseRegardlessOfOwnership(recordsUserIntent: Bool = true) {
        externalPlayback?.controls.pause()
        if recordsUserIntent {
            playbackIntentRevision &+= 1
            isExplicitlyPaused = true
        }
        playbackRequested = false
        player?.pause()
        currentTime = playbackPosition
        isPlaying = false
        updateNowPlayingInfo()
    }

    /// Retain the queue for an explicit recovery/replay decision, but drop all
    /// producer-transient state owned by the outgoing session. Otherwise a
    /// cancelled stream can leave the next mode permanently "buffering".
    private func suspendQueueForOwnershipChange() {
        revokePagePresentation()
        // Claim/release fences the old queue; it is not a user Pause on the
        // new session (including a freshly created player's empty queue).
        pauseRegardlessOfOwnership(recordsUserIntent: false)
        moreSegmentsExpected = false
        isWaitingForNextSegment = false
        isBuffering = false
        gatedSegmentIndex = nil
    }

    @discardableResult
    func pause(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        if let externalPlayback {
            guard token == externalPlayback.token, isPlaybackSessionActive(externalPlayback.token) else { return false }
            pauseRegardlessOfOwnership()
            return true
        }
        guard playbackOwnership.permitsPlayback(requestedBy: token) else { return false }
        pauseRegardlessOfOwnership()
        return true
    }

    /// A paragraph entitlement refresh can stop the transport while preserving
    /// the user's intent. A real Pause during the await still sets the flag and
    /// prevents the coordinator from automatically advancing afterwards.
    @discardableResult
    func pauseForEntitlementRefresh(session token: AudioPlaybackSessionToken) -> Bool {
        guard playbackOwnership.permitsPlayback(requestedBy: token) else { return false }
        pauseRegardlessOfOwnership(recordsUserIntent: false)
        return true
    }

    @discardableResult
    func togglePlayPause(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        if let externalPlayback {
            guard token == externalPlayback.token, isPlaybackSessionActive(externalPlayback.token) else { return false }
            if isPlaying || isBuffering { return pause(session: token) }
            sleepTimer.resumeByUser()
            return play(session: token)
        }
        guard playbackOwnership.permitsPlayback(requestedBy: token) else {
            return false
        }
        if isPlaying || (presentationHold != nil && hasPlaybackRequest) {
            return pause(session: token)
        } else {
            sleepTimer.resumeByUser()
            return play(session: token)
        }
    }

    func stop() {
        stop(preservingPrestagedIDs: [])
    }

    /// Hard privacy boundary used before publishing a different or signed-out
    /// account. `stop()` intentionally preserves queue/book presentation for a
    /// normal pause/reader dismissal, so it is insufficient here: every title,
    /// cover, caption, callback and lock-screen field must disappear together.
    func clearForAccountBoundary() {
        let outgoing = ownershipRevoked
        ownershipRevoked = nil
        outgoing?()
        playbackIntentRevision &+= 1
        readerAppearanceHold = nil
        sleepTimer.endPlaybackSession()
        cancelArtworkLoad()
        stop(preservingPrestagedIDs: [])
        // Account invalidation revokes even still-retained prefetch payloads.
        for media in preparedMedia.values { media.release() }
        preparedMedia.removeAll()
        preparedMediaPins.removeAll()
        segmentsQueue.removeAll()
        currentSegmentIndex = 0
        gatedSegmentIndex = nil
        moreSegmentsExpected = false
        isWaitingForNextSegment = false
        canStartQueuedSegment = nil
        onSegmentComplete = nil
        onPlaybackComplete = nil
        onPlaybackError = nil
        currentBookId = nil
        currentBookTitle = nil
        currentChapterTitle = nil
        currentCoverUrl = nil
        currentCaption = nil
        currentCoverImage = nil
        playbackOwnership.invalidateAll()
        clearNowPlayingInfo()
    }

    private func stop(preservingPrestagedIDs: Set<String>) {
        revokePagePresentation()
        detachExternalPlayback()
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
        playbackRequested = false
        isExplicitlyPaused = false
        currentItemDrained = false
        currentItemCompletionDelivered = false
        queueCompletionDelivered = false
        isSeekingInitialPosition = false
        recoveryBudget = AudioPlaybackRecoveryBudget()
        lastPlaybackFailureCode = nil
        progressEvidence = AudioPlaybackProgressEvidence()
        hasAudibleProgress = false
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
            preserving: Set(preparedMedia.values.map(\.url))
        )
        print("🔊 stop(): Playback stopped, currentSegment is now nil")
    }

    @discardableResult
    func seek(
        to time: Double,
        session token: AudioPlaybackSessionToken? = nil
    ) -> Bool {
        guard externalPlayback == nil else { return false }
        guard playbackOwnership.permitsPlayback(requestedBy: token) else { return false }
        guard time.isFinite else { return false }
        if currentItemDrained, duration.isFinite, duration > 0, time < duration,
           segmentsQueue.indices.contains(currentSegmentIndex) {
            // A user rewind is a new playback of this item, even while the
            // producer is preparing its tail. Rebuild through the existing
            // position-restoration path so old end notifications cannot mark
            // the replay drained or let a late segment bypass it.
            let shouldResume = playbackRequested && !isExplicitlyPaused && !playbackSuspendedByInterruption
            isWaitingForNextSegment = false
            return playSegment(
                at: currentSegmentIndex,
                initialProgress: max(0, time) / duration,
                autoPlayWhenReady: shouldResume
            )
        }
        progressEvidence = AudioPlaybackProgressEvidence()
        hasAudibleProgress = false
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
        guard externalPlayback == nil else { return }
        playbackRate = rate
        for media in preparedMedia.values { media.prepare(rate: rate) }
        if isPlaying, permitsAutomaticPlayback() {
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
    func nextSegment(
        session token: AudioPlaybackSessionToken? = nil,
        automatically: Bool = false
    ) -> Bool {
        guard permitsAutomaticPlayback() else { return false }
        if let externalPlayback {
            guard !automatically, token == externalPlayback.token, isPlaybackSessionActive(externalPlayback.token) else { return false }
            externalPlayback.controls.next()
            return true
        }
        guard !hasTerminalPlaybackFailure else { return false }
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
        if !automatically {
            isExplicitlyPaused = false
            playbackRequested = true
            playbackSuspendedByInterruption = false
        }
        currentItemDrained = true
        // UI/remote Next remains an explicit transport action. A natural end
        // callback, however, may race with Pause and must retain that intent.
        if automatically, isExplicitlyPaused { return true }
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
            publishDrainedQueueCompletion()
        }
        return true
    }

    private func publishDrainedQueueCompletion() {
        guard currentItemDrained, !moreSegmentsExpected,
              !isExplicitlyPaused, !hasTerminalPlaybackFailure,
              !queueCompletionDelivered, permitsAutomaticPlayback() else { return }
        queueCompletionDelivered = true
        isWaitingForNextSegment = false
        isBuffering = false
        onPlaybackComplete?()
    }

    @discardableResult
    func previousSegment(session token: AudioPlaybackSessionToken? = nil) -> Bool {
        if let externalPlayback {
            guard token == externalPlayback.token, isPlaybackSessionActive(externalPlayback.token), permitsAutomaticPlayback() else { return false }
            externalPlayback.controls.previous()
            return true
        }
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
        initialTime: Double? = nil,
        autoPlayWhenReady: Bool = true,
        recoveryPosition: Double? = nil
    ) -> Bool {
        guard !autoPlayWhenReady || permitsAutomaticPlayback() else { return false }
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

        if recoveryPosition == nil {
            recoveryBudget = AudioPlaybackRecoveryBudget()
            lastPlaybackFailureCode = nil
        }
        currentItemDrained = false
        currentItemCompletionDelivered = false
        queueCompletionDelivered = false
        isExplicitlyPaused = !autoPlayWhenReady
        playbackRequested = autoPlayWhenReady

        // Release the previous asset and callbacks before removing its file.
        removeTimeObserver()
        presentationMediaLimit = nil
        playerItemStatusCancellable?.cancel()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil

        // 删除上一个临时文件（释放磁盘空间）
        if let oldURL = currentTempFileURL {
            try? FileManager.default.removeItem(at: oldURL)
        }

        currentSegmentIndex = index
        // `currentTime` still belongs to the AVPlayerItem that just finished.
        // Publish the new segment only after rebasing its clock, otherwise
        // page-handoff observers can adopt the new segment with the old item's
        // terminal time and permanently skip the first highlighted words.
        if let recoveryPosition {
            currentTime = recoveryPosition
        } else {
            currentTime = 0
            duration = segment.duration
            currentSegment = segment
        }
        ReaderRunLog.write(
            "AUDIO stage segment=\(segment.id) index=\(index)/\(segmentsQueue.count) " +
            "duration=\(String(format: "%.2f", segment.duration))"
        )

        print("🔊 playSegment[\(index)]: audioData size: \(segment.audioData.count), duration: \(segment.duration)")

        // A paragraph boundary is the one moment where this work is audible, so
        // reuse the file the prefetch already staged when there is one.
        if recoveryPosition == nil, let staged = takePreparedMedia(for: segment) {
            currentTempFileURL = staged.url
            ReaderRunLog.write("AUDIO prepared adopted segment=\(segment.id) decoded=\(staged.decoded) mono=\(ProcessInfo.processInfo.systemUptime)")
            playAudio(
                from: staged.url,
                prepared: staged,
                initialProgress: initialProgress,
                initialSeconds: recoveryPosition ?? initialTime,
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
            try FileManager.default.createDirectory(at: playbackTemporaryDirectory, withIntermediateDirectories: true)
            try segment.audioData.write(to: tempURL, options: .atomic)
            print("🔊 playSegment[\(index)]: Written to \(tempURL.lastPathComponent), calling playAudio")
            playAudio(
                from: tempURL,
                initialProgress: initialProgress,
                initialSeconds: recoveryPosition ?? initialTime,
                autoPlayWhenReady: autoPlayWhenReady,
                expectedSession: expectedSession
            )
            return true
        } catch {
            return recoverPlaybackFailure(stage: .staging, error: error)
        }
    }

    private func playAudio(
        from url: URL,
        prepared: PreparedMedia? = nil,
        initialProgress: Double? = nil,
        initialSeconds: Double? = nil,
        autoPlayWhenReady: Bool = true,
        expectedSession: AudioPlaybackSessionToken?
    ) {
        removeTimeObserver()

        // Ensure audio session is active
        do {
            try activateAudioSessionIfNeeded()
        } catch {
            print("Failed to activate audio session: \(error)")
        }

        playerItem = prepared?.item ?? AVPlayerItem(url: url)
        if prepared == nil { playerItem?.audioTimePitchAlgorithm = .timeDomain }
        playerItemSession = expectedSession
        progressEvidence = AudioPlaybackProgressEvidence()
        hasAudibleProgress = false
        isSeekingInitialPosition = initialSeconds != nil || initialProgress != nil
        reportedPlaybackFailureItemID = nil
        playerItemReadinessWorkItem?.cancel()
        playerItemReadinessWorkItem = nil

        // Create or update player
        if let prepared {
            playerStateCancellable?.cancel()
            player = prepared.player
        } else if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        observePlayerPlaybackState()
        installPresentationObserver()

        isBuffering = presentationHold != nil || playerItem?.status != .readyToPlay

        // Observe player item status
        guard let observedItem = playerItem else { return }
        playerItemStatusCancellable?.cancel()
        var handledReady = false
        let handleStatus: (AVPlayerItem.Status) -> Void = { [weak self, weak observedItem] status in
                guard let self = self else { return }
                guard let observedItem,
                      observedItem === self.playerItem,
                      self.currentItemCanPublishPlaybackState() else {
                    return
                }
                switch status {
                case .readyToPlay:
                    guard !handledReady else { return }
                    handledReady = true
                    self.playerItemReadinessWorkItem?.cancel()
                    self.playerItemReadinessWorkItem = nil
                    self.isBuffering = self.presentationHold != nil
                    let seconds = observedItem.duration.seconds
                    // Check for valid duration (not NaN or infinite)
                    if seconds.isFinite && seconds > 0 {
                        self.duration = seconds
                    }
                    if (initialProgress != nil || initialSeconds != nil), seconds.isFinite, seconds > 0 {
                        self.isBuffering = true
                        let requestedSeconds = initialSeconds ?? seconds * min(0.98, max(0, initialProgress ?? 0))
                        let targetSeconds = min(max(0, seconds - 0.001), max(0, requestedSeconds.isFinite ? requestedSeconds : 0))
                        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
                        let expectedItem = self.playerItem
                        self.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak expectedItem] completed in
                            DispatchQueue.main.async {
                                guard let self,
                                      expectedItem === self.playerItem,
                                      self.currentItemCanPublishPlaybackState() else { return }
                                guard completed, expectedItem != nil else {
                                    if let expectedItem { self.reportPlaybackFailure(for: expectedItem, stage: .resume, error: nil) }
                                    return
                                }
                                self.isBuffering = false
                                self.progressEvidence = AudioPlaybackProgressEvidence()
                                self.hasAudibleProgress = false
                                self.isSeekingInitialPosition = false
                                self.currentTime = targetSeconds
                                if self.playbackRequested && !self.playbackSuspendedByInterruption && self.permitsAutomaticPlayback() {
                                    self.player?.playImmediately(atRate: self.playbackRate)
                                    self.isPlaying = true
                                } else {
                                    self.player?.pause()
                                    self.isPlaying = false
                                }
                                self.updateNowPlayingInfo()
                                print("Audio restored at \(targetSeconds)s / \(seconds)s")
                            }
                        }
                    } else if self.playbackRequested && !self.playbackSuspendedByInterruption && self.permitsAutomaticPlayback() {
                        self.isSeekingInitialPosition = false
                        self.player?.playImmediately(atRate: self.playbackRate)
                        self.isPlaying = true
                        self.updateNowPlayingInfo()
                    } else {
                        self.isSeekingInitialPosition = false
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
                    self.reportPlaybackFailure(
                        for: observedItem,
                        stage: .itemStatus,
                        error: observedItem.error
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
                stage: .readiness,
                error: nil
            )
        }
        playerItemReadinessWorkItem = readinessWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 12,
            execute: readinessWorkItem
        )

        playerItemStatusCancellable = observedItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: handleStatus)

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
        // Ready media already has a decoder. Install all observers, then start
        // synchronously; the queued initial KVO notification is idempotent.
        if observedItem.status == .readyToPlay { handleStatus(.readyToPlay) }
    }

    private var lastNowPlayingUpdateTime: Double = 0

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600) // 50ms updates for smooth highlighting
        guard let observedItem = playerItem, let observedPlayer = player else { return }
        let onTime: (CMTime) -> Void = { [weak self, weak observedItem, weak observedPlayer] time in
            guard let self = self,
                  observedItem === self.playerItem,
                  observedPlayer === self.player,
                  !self.isSeekingInitialPosition,
                  self.currentItemCanPublishPlaybackState() else { return }
            self.sleepTimer.checkDeadline()
            self.progressEvidence.observe(
                position: time.seconds,
                actuallyPlaying: self.player?.timeControlStatus == .playing
                    && (self.player?.rate ?? 0) > 0
            )
            self.hasAudibleProgress = self.progressEvidence.hasAdvanced
            // A queued periodic sample from before the source edge must not
            // rewind the visual cursor while the actual decoder is held there.
            self.currentTime = self.presentationHold == nil ? time.seconds : self.playbackPosition

            // Update Now Playing info every second for lock screen progress
            if abs(time.seconds - self.lastNowPlayingUpdateTime) >= 1.0 {
                self.lastNowPlayingUpdateTime = time.seconds
                self.updateNowPlayingElapsedTime()
            }
        }
        #if DEBUG
        timeSampleForTesting = onTime
        #endif
        timeObserver = observedPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main, using: onTime)
    }

    private func updateNowPlayingElapsedTime() {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func observePlayerPlaybackState() {
        playerStateCancellable?.cancel()
        let observedPlayer = player
        playerStateCancellable = observedPlayer?
            .publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak observedPlayer] _ in
                guard let self, observedPlayer === self.player else { return }
                self.syncPlaybackStateFromPlayer(reason: "time-control")
            }
    }

    private func syncPlaybackStateFromPlayer(reason: String) {
        guard externalPlayback == nil else { return }
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
        let waiting = presentationSuspended || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if waiting {
            isBuffering = true
        } else if playerItem?.status == .readyToPlay
                    || playerItem?.status == .failed {
            isBuffering = false
        }
        let actuallyPlaying = !currentItemDrained
            && player.timeControlStatus == .playing && player.rate > 0
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
        removePresentationObserver()
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
        ReaderRunLog.write("AUDIO native end item=\(itemID) current=\(playerItem.map { String(describing: ObjectIdentifier($0)) } ?? "nil") time=\(finishedItem.currentTime().seconds) duration=\(finishedItem.duration.seconds) limit=\(finishedItem.forwardPlaybackEndTime.seconds) main=\(Thread.isMainThread)")
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
        if let limit = presentationMediaLimit, limit.itemID == itemID,
           abs(playbackPosition - limit.time) <= 0.002 {
            // Only the exact artificial endpoint belongs to the visual hold.
            // MP3 padding and server duration estimates can differ from the
            // genuine item end; comparing against full duration would swallow
            // that real completion and strand the following paragraph.
            if let edge = presentationBoundary, let player {
                reachPresentationBoundary(edge, player: player)
            }
            if let edge = presentationHold, let player {
                suspendForPresentationIfNeeded(edge, player: player)
            }
            return
        }
        let finishedSession = playerItemSession
        // The terminal notification is authoritative even if time-control KVO
        // is delivered later. Publish this before invoking client callbacks so
        // a Play tap cannot be misclassified as Pause on the ended prefix.
        currentItemDrained = true
        isPlaying = false
        updateNowPlayingInfo()
        // At an end-aligned cue, AVPlayer may send didEnd before its boundary
        // observer. The source edge still owns the page presentation gate.
        if let edge = presentationBoundary, edge.segmentID == currentSegment?.id,
           let player, edge.atItemEnd || playbackPosition + 0.001 >= edge.time {
            reachPresentationBoundary(edge, player: player)
        }
        // A synchronously acknowledged page can finish this same item and
        // install its successor inside reachPresentationBoundary. The outer
        // terminal callback still belongs to the old item; it must not mark
        // the successor's completion as already delivered.
        guard let itemAfterBoundary = playerItem,
              ObjectIdentifier(itemAfterBoundary) == itemID,
              playbackOwnership.permitsCallback(from: finishedSession) else { return }
        guard permitsAutomaticPlayback(), !currentItemCompletionDelivered else { return }
        currentItemCompletionDelivered = true
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
        _ = nextSegment(session: finishedSession, automatically: true)
    }

    @objc private func playerFailedToPlayToEnd(_ notification: Notification) {
        guard let failedItem = notification.object as? AVPlayerItem else {
            return
        }
        let itemID = ObjectIdentifier(failedItem)
        let error =
            (notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? Error) ?? failedItem.error
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePlayerFailedToPlayToEnd(
                    itemID: itemID,
                    error: error
                )
            }
            return
        }
        handlePlayerFailedToPlayToEnd(
            itemID: itemID,
            error: error
        )
    }

    private func handlePlayerFailedToPlayToEnd(
        itemID: ObjectIdentifier,
        error: Error?
    ) {
        guard let currentItem = playerItem,
              ObjectIdentifier(currentItem) == itemID,
              currentItemCanPublishPlaybackState() else {
            return
        }
        reportPlaybackFailure(for: currentItem, stage: .itemEnd, error: error)
    }

    private func reportPlaybackFailure(
        for item: AVPlayerItem,
        stage: AudioPlaybackFailureStage,
        error: Error?
    ) {
        let itemID = ObjectIdentifier(item)
        guard item === playerItem, currentItemCanPublishPlaybackState(),
              reportedPlaybackFailureItemID != itemID else { return }
        reportedPlaybackFailureItemID = itemID
        _ = recoverPlaybackFailure(stage: stage, error: error)
    }

    @discardableResult
    private func recoverPlaybackFailure(stage: AudioPlaybackFailureStage, error: Error?) -> Bool {
        guard playbackOwnership.permitsPlayback(requestedBy: playbackOwnership.queueSession),
              segmentsQueue.indices.contains(currentSegmentIndex) else { return false }
        let segment = segmentsQueue[currentSegmentIndex]
        let attributes = currentTempFileURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let diagnostic = AudioPlaybackFailureDiagnostic(
            timestamp: Date().timeIntervalSince1970,
            stage: stage,
            errors: AudioPlaybackFailureDiagnostic.errorCodes(error),
            byteCount: segment.audioData.count,
            mediaKind: AudioPlaybackFailureDiagnostic.mediaKind(segment.audioData),
            fileExists: currentTempFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            fileBytes: (attributes?[.size] as? NSNumber)?.intValue,
            itemStatus: playerItem.map { $0.status.rawValue },
            playerStatus: player.map { $0.status.rawValue },
            timeControlStatus: player.map { $0.timeControlStatus.rawValue },
            position: currentTime.isFinite ? max(0, currentTime) : 0,
            recoveryAttempt: recoveryBudget.attempts
        )
        AudioPlaybackDiagnostics.record(diagnostic)
        lastPlaybackFailureCode = diagnostic.analyticsCode
        let position = diagnostic.position
        let shouldResume = playbackRequested && !playbackSuspendedByInterruption
        playerItemReadinessWorkItem?.cancel()
        playerItemReadinessWorkItem = nil
        player?.pause()
        isPlaying = false

        if recoveryBudget.claimRetry() {
            // Rebuild from already-generated bytes, at the same segment-local
            // clock. No new TTS request, voice/route change or queue replacement.
            removeTimeObserver()
            playerItemStatusCancellable?.cancel()
            playerStateCancellable?.cancel()
            player = nil
            playerItem = nil
            return playSegment(
                at: currentSegmentIndex,
                autoPlayWhenReady: shouldResume,
                recoveryPosition: position
            )
        }

        isBuffering = false
        moreSegmentsExpected = false
        isWaitingForNextSegment = false
        playbackRequested = false
        updateNowPlayingInfo()
        onPlaybackError?(diagnostic.analyticsCode)
        return false
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
