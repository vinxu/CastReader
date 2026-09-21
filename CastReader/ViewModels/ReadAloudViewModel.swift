//
//  ReadAloudViewModel.swift
//  CastReader
//
//  朗读编排：ReadingDocument 逐段 TTS（流式入队播放）+ 词级高亮 + 自动推进 + 额度计时。
//  词级高亮统一在 currentSegment.timestamps 内按时间定位：
//   - text 源：映射为 processedDisplayText 内的字符范围 highlightRange
//   - photo 源：用游标对齐到 OCR 词 photoHighlightWordIndex（由 PhotoReaderCanvas 取 bbox）
//

import Foundation
import Combine
import UIKit

enum ReadAloudOwnershipRecoveryPlan: Equatable {
    case reloadCachedParagraph
    case regenerateParagraph

    static func resolve(isReady: Bool, cachedSegmentCount: Int) -> Self {
        isReady && cachedSegmentCount > 0
            ? .reloadCachedParagraph
            : .regenerateParagraph
    }
}

/// PDF 词级高亮指令：当前句(段)内、跨 segment 拼接的词数组 + 当前词全局索引。
/// PDFReaderView 据此在句范围内 findString 定位词并画矩形（当前音频段时间戳质量通过→逐词；否则保留句级淡高亮）。
struct PDFWordHighlight: Equatable {
    let paragraphIndex: Int
    let words: [String]
    let wordIndex: Int
}

/// One user-initiated read can cross several page-local Kindle documents.
/// Keep its analytics clock/counters outside any single ReadAloudViewModel so
/// replacing the visual page owner does not manufacture read_end/read_start
/// pairs or reset long-listen milestones.
struct ReadAnalyticsLogicalSessionSnapshot: Equatable, Sendable {
    let sessionID: String
    let startedAt: Date
    let firstAudioTracked: Bool
    let playbackSeconds: Double
    let milestones: Set<Int>
    let lastSegmentID: String?
    let lastPosition: Double?
}

struct ReadAnalyticsPlaybackUpdate: Equatable, Sendable {
    let rawPlaybackDelta: Double?
    let playbackSeconds: Double
    let newlyReachedMilestones: [Int]
}

/// Main-thread custody for one logical read analytics session.
///
/// Each page VM has a unique owner ID. A confirmed page replacement claims the
/// same coordinator; terminal calls from the retired VM are then ignored. This
/// makes start/end exactly-once even when SwiftUI keeps an old page VM alive for
/// another run-loop turn during an audio-queue handoff.
@MainActor
final class ReadAnalyticsSessionCoordinator {
    private var session: ReadAnalyticsLogicalSessionSnapshot?
    private var ownerID: UUID?

    var sessionID: String? { session?.sessionID }
    var activeSnapshot: ReadAnalyticsLogicalSessionSnapshot? { session }

    /// Returns true only when a new logical session was created. Claiming an
    /// existing Kindle session for its next page intentionally returns false.
    @discardableResult
    func begin(ownerID: UUID, at date: Date = Date()) -> Bool {
        guard session == nil else { return false }
        self.ownerID = ownerID
        session = ReadAnalyticsLogicalSessionSnapshot(
            sessionID: UUID().uuidString,
            startedAt: date,
            firstAudioTracked: false,
            playbackSeconds: 0,
            milestones: [],
            lastSegmentID: nil,
            lastPosition: nil
        )
        return true
    }

    func isOwned(by candidate: UUID) -> Bool {
        session != nil && ownerID == candidate
    }

    /// Moves custody without creating a session or emitting read_start. Used
    /// after a confirmed automatic visual-page commit, including the slower
    /// path where the next page may still need entitlement refresh/TTS.
    @discardableResult
    func claimExisting(ownerID candidate: UUID) -> Bool {
        guard session != nil else { return false }
        ownerID = candidate
        return true
    }

    /// Returns the logical start date exactly once, for first-audio latency.
    func markFirstAudio(ownerID candidate: UUID) -> Date? {
        guard ownerID == candidate, let current = session,
              !current.firstAudioTracked else { return nil }
        session = ReadAnalyticsLogicalSessionSnapshot(
            sessionID: current.sessionID,
            startedAt: current.startedAt,
            firstAudioTracked: true,
            playbackSeconds: current.playbackSeconds,
            milestones: current.milestones,
            lastSegmentID: current.lastSegmentID,
            lastPosition: current.lastPosition
        )
        return current.startedAt
    }

    func resetPlaybackCursor(ownerID candidate: UUID) {
        guard ownerID == candidate, let current = session else { return }
        session = ReadAnalyticsLogicalSessionSnapshot(
            sessionID: current.sessionID,
            startedAt: current.startedAt,
            firstAudioTracked: current.firstAudioTracked,
            playbackSeconds: current.playbackSeconds,
            milestones: current.milestones,
            lastSegmentID: nil,
            lastPosition: nil
        )
    }

    /// Records the exact queue position at a visual-owner boundary without
    /// adding playback time. If the same AVPlayer item starts before the next
    /// page VM adopts it, the next tick can account for that handoff interval
    /// instead of silently dropping it.
    func seedPlaybackCursor(
        ownerID candidate: UUID,
        segmentID: String,
        position: Double
    ) {
        guard ownerID == candidate, let current = session else { return }
        session = ReadAnalyticsLogicalSessionSnapshot(
            sessionID: current.sessionID,
            startedAt: current.startedAt,
            firstAudioTracked: current.firstAudioTracked,
            playbackSeconds: current.playbackSeconds,
            milestones: current.milestones,
            lastSegmentID: segmentID,
            lastPosition: max(0, position)
        )
    }

    func accountPlayback(
        ownerID candidate: UUID,
        segmentID: String,
        position: Double,
        milestoneSeconds: [Int] = [30, 180, 300, 600, 1800]
    ) -> ReadAnalyticsPlaybackUpdate? {
        guard ownerID == candidate, let current = session else { return nil }

        var playbackSeconds = current.playbackSeconds
        var rawDelta: Double?
        if current.lastSegmentID == segmentID,
           let previous = current.lastPosition,
           position >= previous {
            let delta = position - previous
            rawDelta = delta
            playbackSeconds += min(2.0, delta)
        }

        var milestones = current.milestones
        let newlyReached = milestoneSeconds.filter {
            playbackSeconds >= Double($0) && !milestones.contains($0)
        }
        milestones.formUnion(newlyReached)
        session = ReadAnalyticsLogicalSessionSnapshot(
            sessionID: current.sessionID,
            startedAt: current.startedAt,
            firstAudioTracked: current.firstAudioTracked,
            playbackSeconds: playbackSeconds,
            milestones: milestones,
            lastSegmentID: segmentID,
            lastPosition: position
        )
        return ReadAnalyticsPlaybackUpdate(
            rawPlaybackDelta: rawDelta,
            playbackSeconds: playbackSeconds,
            newlyReachedMilestones: newlyReached
        )
    }

    /// Ends only for the current page owner. Repeated cancellation/close calls,
    /// or a late callback from a retired page VM, therefore cannot duplicate
    /// read_end.
    @discardableResult
    func end(ownerID candidate: UUID) -> ReadAnalyticsLogicalSessionSnapshot? {
        guard ownerID == candidate, let ended = session else { return nil }
        session = nil
        ownerID = nil
        return ended
    }
}

enum YouTubeTTSRequestPolicy {
    /// The legacy `voice_code` alias is unsupported for YouTube caption tracks
    /// outside English and Chinese. Every other document source deliberately
    /// keeps the pre-existing request body.
    static func includeVoiceCode(
        sourceKind: ReadingSourceKind,
        language: String
    ) -> Bool {
        guard sourceKind == .youtube else { return true }
        guard let canonical = SupportedTTSLanguage(identifier: language)?.rawValue else {
            return false
        }
        return canonical == "en" || canonical == "zh"
    }
}

enum YouTubePersistentAudioQuotaPolicy {
    static func isQuotaExempt(
        sourceKind: ReadingSourceKind,
        persistentCacheHit: Bool
    ) -> Bool {
        sourceKind == .youtube && persistentCacheHit
    }

    static func canStart(
        sourceKind: ReadingSourceKind,
        persistentCacheHit: Bool,
        isPro: Bool,
        hasListenQuota: Bool
    ) -> Bool {
        isQuotaExempt(
            sourceKind: sourceKind,
            persistentCacheHit: persistentCacheHit
        ) || isPro || hasListenQuota
    }

    static func shouldAccount(
        sourceKind: ReadingSourceKind,
        persistentCacheHit: Bool
    ) -> Bool {
        !isQuotaExempt(
            sourceKind: sourceKind,
            persistentCacheHit: persistentCacheHit
        )
    }
}

enum YouTubePlaybackAcceptancePolicy {
    static func shouldConfirm(
        currentTime: Double,
        segmentID: String,
        lastConfirmedSegmentID: String
    ) -> Bool {
        currentTime.isFinite
            && currentTime > 0.05
            && !segmentID.isEmpty
            && lastConfirmedSegmentID != segmentID
    }

    static func didCompleteFirstListen(currentTime: Double) -> Bool {
        currentTime.isFinite && currentTime >= 1
    }
}

/// Disk checkpoints are deliberately much slower than the 20 Hz playback
/// clock. The visible reader still receives every tick for highlighting, while
/// durable state is written at a bounded cadence and once at lifecycle edges.
enum YouTubePlaybackPersistencePolicy {
    static let progressInterval: TimeInterval = 10
    static let historyInterval: TimeInterval = 30

    static func shouldPersistProgress(
        now: Date,
        lastWriteAt: Date?,
        force: Bool
    ) -> Bool {
        force || lastWriteAt.map {
            now.timeIntervalSince($0) >= progressInterval
        } ?? true
    }

    static func shouldPersistHistory(
        now: Date,
        lastWriteAt: Date?,
        force: Bool
    ) -> Bool {
        force || lastWriteAt.map {
            now.timeIntervalSince($0) >= historyInterval
        } ?? true
    }
}

struct YouTubePlaybackCheckpoint: Equatable, Sendable {
    let sequence: UInt64
    let accountBoundaryToken: AccountContentBoundaryToken?
    let transcriptKey: YouTubeTranscriptCacheKey
    let paragraphIndex: Int
    let segmentID: String
    let segmentIndex: Int
    let segmentFraction: Double
    let paragraphFraction: Double

    init(
        sequence: UInt64,
        accountBoundaryToken: AccountContentBoundaryToken? = nil,
        transcriptKey: YouTubeTranscriptCacheKey,
        paragraphIndex: Int,
        segmentID: String,
        segmentIndex: Int,
        segmentFraction: Double,
        paragraphFraction: Double
    ) {
        self.sequence = sequence
        self.accountBoundaryToken = accountBoundaryToken
        self.transcriptKey = transcriptKey
        self.paragraphIndex = paragraphIndex
        self.segmentID = segmentID
        self.segmentIndex = segmentIndex
        self.segmentFraction = segmentFraction
        self.paragraphFraction = paragraphFraction
    }

    var identity: String {
        transcriptKey.storageKey
    }
}

enum YouTubePlaybackPersistenceWork: Equatable, Sendable {
    case progress(YouTubePlaybackCheckpoint)
    case completion(YouTubePlaybackCheckpoint)

    var checkpoint: YouTubePlaybackCheckpoint {
        switch self {
        case .progress(let checkpoint), .completion(let checkpoint):
            return checkpoint
        }
    }
}

/// One serial lane shared by every reader session. Ordinary checkpoints are
/// latest-wins for the whole transcript, while paragraph completions are
/// barriers that cannot be overwritten by the following paragraph. Work
/// carries only metadata, never MP3 bytes, so a slow cache actor cannot keep an
/// old video's audio alive after A -> B -> C -> D.
actor YouTubePlaybackPersistenceCoordinator {
    typealias Writer = @Sendable (YouTubePlaybackPersistenceWork) async -> Void

    struct Metrics: Equatable, Sendable {
        let maximumQueuedWork: Int
        let acceptedWork: Int
        let completedWork: Int
    }

    private let writer: Writer
    private var queue: [YouTubePlaybackPersistenceWork] = []
    private var latestAcceptedSequence: [String: UInt64] = [:]
    private var worker: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var maximumQueuedWork = 0
    private var acceptedWork = 0
    private var completedWork = 0

    init(writer: @escaping Writer) {
        self.writer = writer
    }

    func submit(_ work: YouTubePlaybackPersistenceWork) {
        let checkpoint = work.checkpoint
        let identity = checkpoint.identity
        guard checkpoint.sequence > (latestAcceptedSequence[identity] ?? 0) else {
            return
        }
        latestAcceptedSequence[identity] = checkpoint.sequence
        acceptedWork += 1

        switch work {
        case .progress:
            if let last = queue.indices.last,
               case .progress(let pending) = queue[last],
               pending.identity == identity {
                queue[last] = work
            } else {
                queue.append(work)
            }
        case .completion:
            if let last = queue.indices.last,
               case .progress(let pending) = queue[last],
               pending.identity == identity {
                // Completion contains the terminal progress and supersedes an
                // ordinary checkpoint for the same transcript. A preceding
                // completion is a barrier and must never be coalesced away.
                queue[last] = work
            } else {
                queue.append(work)
            }
        }
        maximumQueuedWork = max(maximumQueuedWork, queue.count)
        startWorkerIfNeeded()
    }

    func waitUntilIdle() async {
        guard worker != nil || !queue.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func metrics() -> Metrics {
        Metrics(
            maximumQueuedWork: maximumQueuedWork,
            acceptedWork: acceptedWork,
            completedWork: completedWork
        )
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            await writer(next)
            completedWork += 1
        }
        worker = nil
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Sequence values are assigned synchronously on the main actor, before any
/// async hop. They therefore describe user-visible playback order even when an
/// older reader session reaches the shared persistence actor later.
@MainActor
enum YouTubePlaybackPersistenceSequence {
    private static var value: UInt64 = 0

    static func next() -> UInt64 {
        value &+= 1
        if value == 0 { value = 1 }
        return value
    }
}

/// The process-wide coordinator closes the A -> B -> A race between separate
/// reader VMs. The transcript-level sequence gate rejects a late checkpoint
/// from an older session, while the actor keeps all disk writes single-flight.
enum YouTubePlaybackPersistenceRuntime {
    static let coordinator = YouTubePlaybackPersistenceCoordinator { work in
        guard let boundary = work.checkpoint.accountBoundaryToken,
              await AccountContentIsolation.isCurrent(boundary) else { return }
        guard let cache = YouTubeCacheProvider.shared else { return }
        do {
            switch work {
            case .progress(let checkpoint):
                try await cache.saveProgress(
                    paragraphIndex: checkpoint.paragraphIndex,
                    segmentId: checkpoint.segmentID,
                    segmentIndex: checkpoint.segmentIndex,
                    fractionalProgress: checkpoint.segmentFraction,
                    paragraphFractionalProgress:
                        checkpoint.paragraphFraction,
                    for: checkpoint.transcriptKey
                )
            case .completion(let checkpoint):
                // Completion is durable transcript progress, not an audio
                // cache eligibility signal. Saving it must succeed even when
                // the app intentionally keeps no full YouTube MP3 on disk.
                try await cache.saveProgress(
                    paragraphIndex: checkpoint.paragraphIndex,
                    segmentId: checkpoint.segmentID,
                    segmentIndex: checkpoint.segmentIndex,
                    fractionalProgress: 1,
                    paragraphFractionalProgress: 1,
                    for: checkpoint.transcriptKey
                )
            }
        } catch {
            // Cache persistence is best-effort and cannot interrupt playback.
        }
    }
}

/// Main-actor submissions are chained before entering the actor. This removes
/// the untracked-Task reorder window and gives lifecycle edges a concrete Task
/// they can await until both the writer and deferred manifest flush are done.
@MainActor
final class YouTubePlaybackPersistenceSubmissionLane {
    typealias Finalizer = @Sendable () async -> Void

    private let coordinator: YouTubePlaybackPersistenceCoordinator
    private var tail: Task<Void, Never>?

    init(coordinator: YouTubePlaybackPersistenceCoordinator) {
        self.coordinator = coordinator
    }

    @discardableResult
    func submit(_ work: YouTubePlaybackPersistenceWork) -> Task<Void, Never> {
        let predecessor = tail
        let coordinator = coordinator
        let task = Task {
            await predecessor?.value
            await coordinator.submit(work)
        }
        tail = task
        return task
    }

    @discardableResult
    func flush(
        finalizer: Finalizer? = nil
    ) -> Task<Void, Never> {
        let predecessor = tail
        let coordinator = coordinator
        let task = Task {
            await predecessor?.value
            await coordinator.waitUntilIdle()
            if let finalizer { await finalizer() }
        }
        tail = task
        return task
    }
}

/// YouTube raw audio is ephemeral/regenerable. Keep only the current paragraph
/// in the VM; the separately bounded prefetch buffer owns the next paragraph.
/// Other reader sources retain their established replay model.
enum YouTubeAudioMemoryWindow {
    static func prune<Value>(
        _ values: inout [Int: Value],
        sourceKind: ReadingSourceKind,
        keeping paragraphIndex: Int?
    ) {
        guard sourceKind == .youtube else { return }
        guard let paragraphIndex else {
            values.removeAll(keepingCapacity: false)
            return
        }
        values = values.filter { $0.key == paragraphIndex }
    }
}

/// A bounded lead-time target, not an assertion that estimated text is already
/// playable. Only complete READY audio contributes measured duration.
enum KindleParagraphPrefetchHorizon {
    struct Candidate {
        let index: Int
        let utf16Count: Int
        let readyDuration: Double?
    }
    struct Selection {
        let indices: [Int]
        let estimatedSeconds: Double
        let additionalCharacters: Int
    }
    static func select(_ candidates: [Candidate], speed: Double) -> Selection {
        let rate = speed.isFinite && speed > 0 ? speed : 1
        var selected: [Int] = []
        var seconds = 0.0
        var extraCharacters = 0
        for candidate in candidates {
            guard selected.count < 8 else { break }
            if selected.count >= 2 {
                guard seconds < 12 else { break }
                guard candidate.utf16Count <= 1600 - extraCharacters else { break }
                extraCharacters += candidate.utf16Count
            }
            selected.append(candidate.index)
            let duration = candidate.readyDuration.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            } ?? max(0.1, Double(candidate.utf16Count) / 24)
            seconds += duration / rate
        }
        return Selection(indices: selected, estimatedSeconds: seconds,
                         additionalCharacters: extraCharacters)
    }
}

@MainActor
final class ReadAloudViewModel: ObservableObject {

    let document: ReadingDocument
    let analyticsContext: AnalyticsContentContext

    // 渲染状态
    @Published var currentParagraphIndex: Int = -1
    @Published var processedDisplayText: String? = nil   // 当前段已朗读文本（text 模式渲染）
    @Published var highlightRange: NSRange? = nil          // 当前词字符范围（processedDisplayText 内）
    @Published var photoHighlightWordIndex: Int? = nil     // photo 模式：OCR 词索引
    @Published var photoHighlightWordRange: Range<Int>? = nil // OCR 图片：单词或当前 segment 的词范围
    @Published var isPlaying: Bool = false
    @Published private(set) var isPlaybackPausedByUser = false
    @Published var isBuffering: Bool = false
    @Published var status: TTSStatus = .pending
    @Published var isFinished = false      // 全部段落播完 → Mini Player 显示「已播完」+ 点播放从头重读
    @Published var showPaywall: Bool = false
    @Published var autoScrollEnabled: Bool = true

    private let audio: AudioPlayerService
    private let tts: TTSService
    private struct ParagraphContinuation {
        let paragraphIndex: Int
        let voice: String
        let language: String
        let checkpoint: TTSContinuation
    }
    private var paragraphContinuation: ParagraphContinuation?
    private var pendingPrefetchAdvanceFrom: Int?
    private let historyStore: HistoryStore
    private let speechGenerator: any ParagraphSpeechGenerating
    private let progressBoundaryToken: UUID?
    private var resumeDocumentIndex = ReadingResumeDocumentIndex(paragraphs: [])
    private var pendingReadingAudioCursor: ReadingResumeAudioCursor?
    private var lastReadingCheckpoint: ReadingResumeCheckpoint?
    private var lastReadingCheckpointWrite = Date.distantPast
    private var hasObservedReadingPlayback = false
    private var restoredReadingStructure: String?
    @Published private(set) var resumeNotice: String?
    @Published private(set) var resumeSourceRange: NSRange?
#if DEBUG
    @Published private(set) var debugResumeFirstPlaybackSeconds: Double?
    private var debugResumeAwaitingFirstTick = false
#endif
    private var resumeSourceParagraphIndex = -1
    var initialResumeViewportRange: NSRange? {
        guard currentParagraphIndex == resumeSourceParagraphIndex,
              !hasObservedReadingPlayback || pendingReadingAudioCursor != nil else { return nil }
        return resumeSourceRange
    }
    private let settings = AppSettings.shared
    private let pro = ProManager.shared
    private let quota = QuotaManager.shared
    private let analyticsSessionCoordinator: ReadAnalyticsSessionCoordinator
    private let analyticsSessionOwnerID = UUID()
    private let accountBoundaryToken: AccountContentBoundaryToken?
    let youtubeTranscriptCacheKey: YouTubeTranscriptCacheKey?
    let youtubeReadableParagraphIndexes: [Int]
    private let youtubePersistenceLane: YouTubePlaybackPersistenceSubmissionLane
    private var audioSessionToken: AudioPlaybackSessionToken?

    private var segmentsByParagraph: [Int: [AudioSegment]] = [:]
    private var generationTask: Task<Void, Never>?
    private var liveWebTurnIntentSuspended = false
    private var listenCapRefreshTask: Task<Void, Never>?
    /// Entitlement refreshes outlive the tap that started them. Keep exactly one
    /// retry owner so a response from a previously selected reader mode cannot
    /// activate this VM or mutate the shared player after a mode/page change.
    private var accessRetryTask: Task<Void, Never>?
    private var accessRetryEpoch: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    private var readableIndices: [Int] = []
    private var generationEpoch: UInt64 = 0
    private var playbackVoiceID: String
    private var activeVoiceSwitchID: UUID?

    // 预生成下一段 TTS（消除段间等首字节的 gap）：当前段生成完即后台预取下一段到缓存，advance 命中则秒接。
    private var prefetchTask: Task<Void, Never>?
    /// Waits for an in-flight paragraph prefetch at an audio boundary. This must
    /// be cancelled together with the prefetch itself; otherwise its fallback
    /// `generate` can resurrect an inactive VM and clear the new mode's queue.
    private var prefetchPromotionTask: Task<Void, Never>?
    private var readAheadStreams: [Int: SpeechStreamBuffer] = [:]
    private var foregroundStream: SpeechStreamBuffer?
    private var completedVoiceAudio: [(key: String, segments: [AudioSegment])] = []
    private var prefetchingIndex: Int? = nil     // 正在预取中的段
    private var prefetchedIndex: Int? = nil       // 已预取完成、可秒接的段
    private var prefetchedSegments: [AudioSegment] = []
    // Kindle ordinary voices can buffer a bounded duration across short
    // paragraphs. The legacy next-paragraph fields above remain the single
    // promotion interface; these tables only own speculative producers/data.
    private var kindlePrefetchedSegments: [Int: [AudioSegment]] = [:]
    private var kindlePrefetchFailures = Set<Int>()
    /// One cloned-voice request id survives the prefetch -> foreground fallback
    /// for the same page, speech text and voice. This keeps backend reservation and
    /// settlement idempotent when a transient failure crosses a paragraph edge.
    private var cloneRequestIDs: [String: String] = [:]
    /// `true` only when the prepared paragraph came from the persistent
    /// YouTube TTS cache. Freshly generated prefetches remain billable even
    /// after their bytes are persisted for a future replay.
    private var prefetchedYouTubeAudioIsQuotaExempt = false

    // .web 源：段落由 WebView extractor 提取后注入；朗读输出经 bridge 驱动 DOM 高亮。
    private var webParagraphs: [ReadingParagraph]? = nil
    private var webLanguage: String? = nil
    private var deferredWebAutoplay = DeferredAutoplayGate()
    var prepareReadableWebPage: (() async -> Bool)?
    private var readablePageTask: Task<Void, Never>?
    var isPreparingReadablePage: Bool { readablePageTask != nil }
    var hasReadableWebContent: Bool { !readableIndices.isEmpty }
    private var preferredLiveWebStartIndex: Int?
    /// History-restored start position for own-content documents. Consumed by
    /// the first `start()`; a manual paragraph tap (`jump`) simply ignores it.
    private var pendingResumeParagraphIndex: Int?
    private struct PendingLiveWebResume {
        let anchor: WeReadPlaybackResumeAnchor
        let paragraphIndex: Int
    }
    private var pendingLiveWebResume: PendingLiveWebResume?
    private var isAwaitingLiveWebCarryCompletion = false
    private var pendingLiveWebCarryStartIndex: Int?
    /// Exact, confirmed WeRead-page audio prepared while the immutable
    /// cross-page sentence is still playing.  This buffer deliberately does
    /// not touch the shared player queue or `moreSegmentsExpected` until the
    /// carry item has completed.
    private var liveWebCarryPrewarmIndex: Int?
    private var liveWebCarryPrewarmEpoch: UInt64?
    private var liveWebCarryPrewarmSession: AudioPlaybackSessionToken?
    private var liveWebCarryPrewarmSourceText = ""
    private var liveWebCarryPrewarmVoiceID = ""
    private var liveWebCarryPrewarmLanguage = ""
    private var liveWebCarryPrewarmSegments: [AudioSegment] = []
    private var liveWebCarryPrewarmProducerFinished = false
    private var liveWebCarryPrewarmPlaybackDue = false
    private var liveWebCarryPrewarmPlaybackStarted = false
    /// First exact-page segment staged while a manual turn gesture has paused
    /// autoplay.  Resuming the cancelled gesture must start this queued item,
    /// not try to replay the already-ended carry item.
    private var liveWebCarryPrewarmDeferredStartSegmentID: String?
    private var liveWebCarryPrewarmDeferredPredecessorSegmentID: String?
    private var liveWebCarryPrewarmError: String?
    private var liveWebCarryPrewarmSerial: UInt64 = 0
    /// 用户亲手更正的朗读语言，压过逐页检测与文档自带语言。
    /// 检测每翻一页重判一次，而章节标题/题记/图注这类稀疏页证据不足会回落英语，
    /// 于是一本意大利语书读到那样一页就换成英语音色；用户的选择不能被下一页推翻。
    private var correctedLanguage: String? = nil
    private var paras: [ReadingParagraph] { webParagraphs ?? document.paragraphs }
    /// 有效朗读语言：用户更正 > .web 源从正文检测的语言 > document.language。
    private var docLanguage: String { correctedLanguage ?? webLanguage ?? document.language }
    @Published var webAudioSegments: [AudioSegment] = []   // 扁平全局顺序（供 bridge 转 JS audioSegments）
    @Published var webHighlight: WebHighlightCmd? = nil     // 当前 DOM 高亮指令（句级/词级）
    @Published var pdfHighlight: PDFWordHighlight? = nil    // PDF 词级高亮（当前段质量通过才更新，否则保留句级淡高亮）

    // 高亮/计时游标
    private var lastWordKey = ""
    // 词级高亮预对齐缓存（对齐 Android ensureWordAligned）：整段 TTS 词序一次性对齐到 processedDisplayText 字符区间，
    // 游标单向只进，根治每帧 indexOf 重复定位 + 短词子串带偏 + 一词找不到全盘 nil（EPUB 长段卡死的根因）。
    private var alignedPara = -1
    private var alignedSegCount = -1
    private var wordRanges: [NSRange?] = []
    private var ocrAlignedPara = -1
    private var ocrAlignedSegCount = -1
    private var ocrWordIndexes: [Int?] = []
    private var ocrWordRanges: [Range<Int>?] = []
    private var photoCursor = 0
    private var lastSegmentId = ""
    private var lastSegmentBaselineTime: Double = 0
    private var lastSegmentMaxTime: Double = 0
    private var lastYouTubeProgressWriteAt: Date?
    private var lastYouTubeHistoryProgressWriteAt: Date?
    private var lastYouTubePlaybackSignalSegmentID = ""
    private var didRecordYouTubeFirstListen: Bool
    private var youtubeCompletionSubmittedParagraph: Int?
    /// Paragraphs loaded from the persistent YouTube audio cache. All segments
    /// of one paragraph have one origin, so this survives queue reconstruction
    /// without relying on globally reusable `paragraph-segment` IDs.
    private var youtubeQuotaExemptParagraphs = Set<Int>()
    private var graceSeconds: Double = 0
    private(set) var isActive = false
    private var lastNowPlayingCaption: String?
    private var lastCaptionEvaluationSegmentID = ""
    private var lastCaptionEvaluationTime: Double = -.greatestFiniteMagnitude

    private var ownsAudioQueue: Bool {
        guard isActive, let token = audioSessionToken else { return false }
        return audio.isPlaybackSessionActive(token)
            && audio.isQueueOwned(by: token)
            && audio.canControlPlayback(session: token)
    }

    @discardableResult
    private func ensureAudioSessionClaim() -> AudioPlaybackSessionToken? {
        guard isActive else { return nil }
        if let token = audioSessionToken,
           audio.isPlaybackSessionActive(token) {
            return token
        }
        let token = audio.claimPlaybackSession(owner: .readAloud)
        audioSessionToken = token
        // A restored page may be activated before ensurePlaying()/jump(),
        // bypassing start(). Bind the book whenever we claim its audio session;
        // Kindle's page-turn watcher also uses this identity after TTS is ready.
        applyPlaybackMetadata()
        isPlaying = false
        isBuffering = false
        return token
    }

    private func setMoreSegmentsExpected(_ expected: Bool) {
        guard let token = audioSessionToken else { return }
        _ = audio.setMoreSegmentsExpected(expected, session: token)
    }

    private func installAudioCompletionCallback() {
        audio.onPlaybackComplete = { [weak self] in
            guard let self else { return }
            guard !self.audio.hasTerminalPlaybackFailure else { return }
            guard self.ownsAudioQueue else {
                ReaderRunLog.write(
                    "READ completion ignored reason=ownership-lost " +
                    "para=\(self.currentParagraphIndex)"
                )
                return
            }
            ReaderRunLog.write(
                "READ completion accepted para=\(self.currentParagraphIndex) " +
                "status=\(Self.statusLogValue(self.status))"
            )
            self.advance()
        }
        audio.onPlaybackError = { [weak self] code in
            guard let self, self.ownsAudioQueue else { return }
            ReaderRunLog.write(
                "READ playback error para=\(self.currentParagraphIndex) " +
                "error=\(code)"
            )
            self.flushReadingProgress()
            self.retainReadingCursorForQueueRebuild()
            // Local player reconstruction has already exhausted its one retry.
            // Fence callbacks already in flight as well as cancelling the task.
            self.generationEpoch &+= 1
            self.generationTask?.cancel()
            self.generationTask = nil
            self.clearPrefetch()
            self.setMoreSegmentsExpected(false)
            self.status = .error(AppLocalized("音频播放失败，请重试"))
            self.endAnalyticsReadSession(
                result: .failed,
                reason: "audio_playback_failed",
                errorStage: "player",
                errorCode: code
            )
        }
    }

    // 产品分析会话只使用播放器真实推进时间；跳读造成的大跨度 currentTime 不计入里程碑。
    private var analyticsReadSessionId: String? {
        analyticsSessionCoordinator.sessionID
    }
    private var appReviewReadSession = AppReviewReadSessionProgress()
    private var preserveAppReviewSessionOnNextAnalyticsBegin = false

    private var playbackBookID: String?
    private var playbackTitle: String?
    private var playbackChapterTitle: String?
    private var playbackCoverURL: String?
    /// The optional token is emitted only for a naturally completed paged
    /// Kindle/WeRead surface. Its owner may carry it into one confirmed
    /// automatic next-page commit; every other completion remains a reset.
    var onDocumentFinished: ((AppReviewReadSessionProgress?) -> Void)?
    var onAppReviewReadSessionInvalidated: (() -> Void)?
    var onPageBoundaryApproaching: (() -> Void)?
    private var didSignalPageBoundaryApproaching = false
    private var weReadSpeechBoundary: WeReadPageSpeechBoundary?
    var weReadBoundaryTurnLeadSeconds = WeReadContinuousPageHandoffContract.visualTurnLeadSeconds

    init(
        document: ReadingDocument,
        analyticsContext: AnalyticsContentContext? = nil,
        analyticsSessionCoordinator: ReadAnalyticsSessionCoordinator? = nil,
        audioService: AudioPlayerService = .shared,
        ttsService: TTSService = .shared,
        historyStore: HistoryStore = .shared,
        speechGenerator: (any ParagraphSpeechGenerating)? = nil
    ) {
        self.audio = audioService
        self.tts = ttsService
        self.document = document
        self.historyStore = historyStore
        self.speechGenerator = speechGenerator ?? ttsService
        self.progressBoundaryToken = historyStore.progressBoundaryToken
        self.analyticsContext = analyticsContext ?? AnalyticsContentContext.fallback(for: document)
        self.analyticsSessionCoordinator = analyticsSessionCoordinator
            ?? ReadAnalyticsSessionCoordinator()
        self.accountBoundaryToken = AccountContentIsolation.captureBoundaryToken()
        self.youtubeTranscriptCacheKey = document.youtubeTranscript.map {
            YouTubeCacheStore.cacheKey(for: $0)
        }
        self.youtubeReadableParagraphIndexes = document.sourceKind == .youtube
            ? document.paragraphs.filter {
                $0.type.isReadable &&
                    SpeechTextSanitizer.containsSpeakableContent(
                        $0.resolvedSpeechText
                    )
            }.map(\.id)
            : []
        self.youtubePersistenceLane =
            YouTubePlaybackPersistenceSubmissionLane(
                coordinator: YouTubePlaybackPersistenceRuntime.coordinator
            )
        self.didRecordYouTubeFirstListen = UserDefaults.standard.bool(
            forKey: "youtube.didCompleteFirstListen"
        )
        // A correction the user made for this book outlives the session: reopening
        // it must not hand the book back to whatever the first page detects.
        // YouTube is the exception to book-level identity: each selected caption
        // track is its own content session. A stale correction for the video must
        // never override a newly selected track in another language.
        let initialLanguageContentID = document.sourceKind == .youtube
            ? document.contentSessionKey
            : document.id
        self.correctedLanguage = ReadingLanguageStore.shared.override(
            for: ReadingLanguageStore.contentKey(
                namespace: document.sourceKind.rawValue,
                bookID: initialLanguageContentID
            )
        )
        self.playbackVoiceID = AppSettings.shared
            .voice(for: correctedLanguage ?? document.language)
        recomputeReadableIndices()
        bind()
        restoreSavedReadingPosition()
        GrowthLoopConversionCoordinator.shared.contentBecameReady(document)
    }

    /// Where this book's reading-language correction is filed.
    ///
    /// Kindle builds a fresh `ReadingDocument` for every page, so `document.id` is a
    /// per-page UUID there and the stable book identity arrives with the playback
    /// metadata instead. Keying on that is what makes a correction survive a page
    /// turn on the very shelf the report came from.
    var readingLanguageContentKey: String {
        if document.sourceKind == .youtube {
            return ReadingLanguageStore.contentKey(
                namespace: document.sourceKind.rawValue,
                bookID: document.contentSessionKey
            )
        }
        let bookID = playbackBookID?.trimmed ?? ""
        return ReadingLanguageStore.contentKey(
            namespace: document.sourceKind.rawValue,
            bookID: bookID.isEmpty ? document.id : bookID
        )
    }

    /// The book identity can arrive after `init`; pick the stored correction up
    /// again when it does, or a Kindle page turn would quietly drop it.
    private func adoptStoredReadingLanguageCorrection() {
        guard correctedLanguage == nil,
              let stored = ReadingLanguageStore.shared.override(for: readingLanguageContentKey)
        else { return }
        correctedLanguage = stored
        if !isActive, currentParagraphIndex < 0 {
            playbackVoiceID = settings.voice(for: docLanguage)
        }
    }

    func configurePlaybackMetadata(id: String, title: String, coverURL: String?, chapterTitle: String? = nil) {
        playbackBookID = id
        playbackTitle = title
        playbackCoverURL = coverURL
        playbackChapterTitle = chapterTitle
        adoptStoredReadingLanguageCorrection()
        restoreSavedReadingPosition()
    }

    /// A Kindle page handoff is safe only after the last readable chunk has
    /// finished generating all of its own segments. At that point, appending the
    /// next page's prepared audio cannot reorder a still-streaming current page.
    var isOnLastReadableParagraph: Bool {
        currentParagraphIndex >= 0 && currentParagraphIndex == readableIndices.last
    }

    var currentTTSCompleteForPageHandoff: Bool {
        guard ownsAudioQueue, !isFinished, status.isReady,
              let current = audio.currentSegment,
              current.paragraphIndex == currentParagraphIndex,
              segmentsByParagraph[currentParagraphIndex]?.contains(where: { $0.id == current.id }) == true,
              !audio.moreSegmentsExpected else { return false }
        return true
    }

    /// Include the generated remainder of this page, even when its final
    /// paragraph is only a short phrase. This is preparation evidence only;
    /// the coordinator must still wait for that paragraph to own the queue
    /// before appending next-page audio.
    var preparedKindlePageAudioTail: KindleContinuousPageHandoffContract.PreparedAudioTail? {
        guard document.sourceKind == .kindle,
              currentTTSCompleteForPageHandoff,
              let current = audio.currentSegment,
              let position = readableIndices.firstIndex(of: currentParagraphIndex),
              let currentSegments = segmentsByParagraph[currentParagraphIndex] else { return nil }
        var paragraphs = [currentSegments]
        for index in readableIndices.dropFirst(position + 1) {
            if let ready = kindlePrefetchedSegments[index], !ready.isEmpty {
                paragraphs.append(ready)
            } else if prefetchedIndex == index, !prefetchedSegments.isEmpty,
                      readAheadStreams[index]?.finished != false {
                paragraphs.append(prefetchedSegments)
            } else {
                return nil
            }
        }
        return KindleContinuousPageHandoffContract.preparedAudioTail(
            paragraphs: paragraphs, currentSegmentID: current.id,
            currentTime: audio.currentTime, currentDuration: audio.duration
        )
    }

    /// A speculative next-page cache must never bypass the ordinary listen
    /// quota gate merely because its audio was generated early.
    var canContinueAcrossLivePageBoundary: Bool {
        !isPlaybackPausedByUser && (pro.isPro || quota.canStartListen(isPro: pro.isPro))
    }

    /// Timing of the visual page edge inside one whole natural-sentence audio
    /// segment. The segment text is the API's processed text, so this uses the
    /// same immutable sequence that drives sentence highlighting.
    var currentWeReadBoundaryCue: WeReadBoundaryAudioCue? {
        guard ownsAudioQueue,
              document.sourceKind.isLiveWebLibrary,
              let boundary = weReadSpeechBoundary,
              boundary.isCrossPage,
              let segments = segmentsByParagraph[boundary.paragraphIndex],
              let mapped = WeReadCrossPageSpeechContract.boundarySegment(
                segmentTexts: segments.map(\.text),
                boundaryUTF16Offset: boundary.visibleUTF16Offset
              ),
              mapped.sequence >= 0,
              mapped.sequence < segments.count else { return nil }
        let segment = segments[mapped.sequence]
        let duration = audio.currentSegment?.id == segment.id && audio.duration > 0.01
            ? audio.duration
            : segment.duration
        guard duration > 0.01 else { return nil }
        return WeReadBoundaryAudioCue(
            segmentID: segment.id,
            segmentSequence: mapped.sequence,
            boundaryTime: duration * mapped.fraction,
            segmentDuration: duration,
            consumedCursor: boundary.sourceParagraphIndex.flatMap { sourceParagraphIndex in
                boundary.sourceSpeechEnd.map {
                    WeReadConsumedTextCursor(
                        sourceLayoutFingerprint: boundary.sourceLayoutFingerprint,
                        sourceParagraphIndex: sourceParagraphIndex,
                        sourceUTF16End: $0
                    )
                }
            }
        )
    }

    /// Loading/streaming does not imply the play control must be locked: a
    /// paused voice switch may already have a prepared queue item.
    var canResumePlayback: Bool {
        ownsAudioQueue && (audio.currentSegment != nil || audio.hasQueuedSegments)
    }

    /// True only when the reader is actively waiting for playable audio. A
    /// finished AVPlayer item remains addressable until the next paragraph is
    /// promoted, so `currentSegment != nil` alone cannot distinguish a paused
    /// item from a drained queue.
    var isWaitingForPlayableAudio: Bool {
        guard !isPlaybackPausedByUser, !isPlaying, !isFinished else { return false }
        if isBuffering || isPreparingReadablePage { return true }
        return (status.isLoading || status.isStreaming)
            && !audio.hasPlayableAudio
    }

    /// A confirmed manual page turn should continue only when the user was
    /// actually listening, or when a user-started TTS request had not produced
    /// its first audio item yet. Merely owning the current reader mode does not
    /// count: a deliberately paused page must stay paused after the turn.
    var shouldResumeAfterManualLivePageTurn: Bool {
        guard !isPlaybackPausedByUser else { return false }
        if accessRetryTask != nil { return true }
        guard isActive, !isFinished else { return false }
        if ownsAudioQueue, audio.isPlaying { return true }
        guard ownsAudioQueue else {
            return status.isLoading || status.isStreaming || isBuffering
        }
        // AVPlayer retains the finished segment while a streamed successor is
        // still arriving. That natural gap carries the same playback intent.
        if audio.isWaitingForNextSegment && audio.moreSegmentsExpected { return true }
        return audio.currentSegment == nil
            && !audio.hasQueuedSegments
            && (status.isLoading || status.isStreaming || isBuffering)
    }

    /// A gesture begins before Google confirms that the visible page changed.
    /// Suspend auto-start without cancelling generation so a late cloud
    /// response cannot speak the stale page, while a cancelled edge swipe can
    /// resume the exact queue/request without restarting or consuming quota.
    func suspendForLiveWebTurnIntent() {
        guard document.sourceKind.isLiveWebLibrary else { return }
        invalidateAccessRetry()
        liveWebTurnIntentSuspended = true
        guard isActive else { return }
        if let token = audioSessionToken {
            audio.pause(session: token)
        }
    }

    /// A gesture owns the next live page even when entitlement refresh began
    /// before this VM acquired the shared player.
    func cancelPendingAccessRetryForLiveWebTurn() {
        guard document.sourceKind.isLiveWebLibrary else { return }
        invalidateAccessRetry()
    }

    func resumeAfterCancelledLiveWebTurnIntent() {
        guard liveWebTurnIntentSuspended else { return }
        liveWebTurnIntentSuspended = false
        guard isActive else {
            if currentParagraphIndex < 0 { start() }
            return
        }
        guard ownsAudioQueue else {
            ensurePlaying()
            return
        }
        if audio.currentSegment != nil || audio.hasQueuedSegments {
            if let token = audioSessionToken {
                if let deferredID = liveWebCarryPrewarmDeferredStartSegmentID {
                    let predecessorID = liveWebCarryPrewarmDeferredPredecessorSegmentID
                    let currentID = audio.currentSegment?.id
                    let stillWaitingAtDeferredBoundary = predecessorID.map {
                        currentID == $0
                    } ?? (currentID == nil)
                    if stillWaitingAtDeferredBoundary {
                        let didStart = audio.startQueuedSegment(
                           id: deferredID,
                           progress: 0,
                           autoPlay: true,
                           session: token
                        )
                        if didStart {
                            liveWebCarryPrewarmDeferredStartSegmentID = nil
                            liveWebCarryPrewarmDeferredPredecessorSegmentID = nil
                        }
                        return
                    }
                    // Another explicit playback action already advanced to this
                    // item (or beyond it). Consume the stale resume marker, but
                    // never seek the finished first item back to zero.
                    liveWebCarryPrewarmDeferredStartSegmentID = nil
                    liveWebCarryPrewarmDeferredPredecessorSegmentID = nil
                }
                _ = audio.play(session: token)
            }
        }
    }

    /// Player-facing voice controls must follow the language that is actually
    /// being read. Web content learns this only after DOM extraction, while
    /// PDF/text/Kindle content already carries it on the document.
    var playbackLanguage: String {
        VoiceCatalog.normalizedLanguage(docLanguage)
    }

    /// The user correcting, from the voice panel, which language this content is
    /// narrated in — the front door for a misdetected page. Re-narrates with the
    /// voice they already prefer for that language; the voice itself remains
    /// changeable in the same panel.
    func correctReadingLanguage(_ language: String) {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard !normalized.isEmpty, normalized != playbackLanguage else { return }
        let previous = playbackLanguage
        correctedLanguage = normalized
        // Persist per book, so the correction still holds on the next page and the
        // next time this book is opened — otherwise the very next detection undoes it.
        ReadingLanguageStore.shared.setOverride(normalized, for: readingLanguageContentKey)
        ReaderRunLog.write(
            "READ language corrected from=\(previous) to=\(normalized) doc=\(document.id)"
        )
        // Force the restart: a cloned voice can be shared across languages, and
        // comparing voice ids alone would then read "nothing changed" even though
        // the language — and therefore the TTS request — just did.
        handleVoicePreferenceChanged(forceRestart: true)
    }

    /// The voice avatar is deliberately hidden before the first Play action.
    /// Once a paragraph has entered the playback pipeline it remains available
    /// while paused or completed, so the user can switch voices without having
    /// to start the old voice again first.
    var hasStartedPlayback: Bool {
        currentParagraphIndex >= 0 && !status.isPending
    }

    /// Relinquish callback/highlight ownership while leaving the shared player
    /// and its queue untouched. The next Kindle page VM adopts the already
    /// playing queued item, so calling the normal `deactivate()` here would
    /// introduce exactly the pause this handoff is designed to remove.
    @discardableResult
    func detachForContinuousPageHandoff(
        nextSegmentID: String? = nil
    ) -> AppReviewReadSessionProgress? {
        guard ownsAudioQueue else { return nil }
        invalidateAccessRetry()
        let reviewSession = appReviewReadSession
        generationEpoch &+= 1
        commitListen()
        // This is a visual/page-owner transition, not the end of listening.
        // The shared Kindle coordinator remains open and the next page VM will
        // claim it when adopting the already queued audio.
        if let nextSegmentID {
            analyticsSessionCoordinator.seedPlaybackCursor(
                ownerID: analyticsSessionOwnerID,
                segmentID: nextSegmentID,
                position: 0
            )
        } else if let segment = audio.currentSegment {
            analyticsSessionCoordinator.seedPlaybackCursor(
                ownerID: analyticsSessionOwnerID,
                segmentID: segment.id,
                position: audio.currentTime
            )
        }
        isActive = false
        audioSessionToken = nil
        generationTask?.cancel()
        generationTask = nil
        resetLiveWebCarryPrewarmState()
        listenCapRefreshTask?.cancel()
        listenCapRefreshTask = nil
        clearPrefetch()
        return reviewSession
    }

    /// An automatic visual page turn may replace/reset page-local playback
    /// state, but it is still one user-initiated session for review eligibility.
    /// Manual navigation never calls this method and therefore starts fresh.
    @discardableResult
    func inheritAppReviewReadSession(_ progress: AppReviewReadSessionProgress) -> Bool {
        guard document.sourceKind == .kindle
                || document.sourceKind == .weread
                || document.sourceKind == .googleBooks
                || document.sourceKind == .kobo
                || document.sourceKind == .oreilly,
              !progress.sessionID.isEmpty,
              !analyticsSessionCoordinator.isOwned(by: analyticsSessionOwnerID)
        else { return false }
        appReviewReadSession = progress
        preserveAppReviewSessionOnNextAnalyticsBegin = true
        return true
    }

    /// WeRead can confirm the next Canvas before the old page reaches its
    /// terminal callback. If its seamless/carry adoption then fails, the bridge
    /// must snapshot this still-active session before fallback `stop()` resets
    /// it. A completed/stopped/manual session has no analytics owner and cannot
    /// be revived through this path.
    func snapshotAppReviewReadSessionForActiveAutomaticPageCommit()
        -> AppReviewReadSessionProgress? {
        guard analyticsSessionCoordinator.isOwned(by: analyticsSessionOwnerID)
        else { return nil }
        return AppReviewAutomaticPageContinuation.candidate(
            appReviewReadSession,
            for: document.sourceKind
        )
    }

    /// Claims an already-open logical session after Kindle has confirmed the
    /// next visual page. This emits neither read_start nor read_end.
    @discardableResult
    func claimLogicalAnalyticsSessionForPageHandoff() -> Bool {
        analyticsSessionCoordinator.claimExisting(
            ownerID: analyticsSessionOwnerID
        )
    }

    /// Adopt next-page segments that AudioPlayerService is already playing.
    /// This updates paragraph/highlight/callback ownership without clearing the
    /// queue or restarting the current AVPlayerItem.
    @discardableResult
    func adoptContinuousPlayback(_ segments: [AudioSegment], paragraphIndex: Int) -> Bool {
        guard readableIndices.contains(paragraphIndex),
              !segments.isEmpty,
              let current = audio.currentSegment,
              segments.contains(where: { $0.id == current.id }) else {
            return false
        }

        discardReadingResumeForConfirmedNavigation()
        guard let token = audio.transferActiveQueueSession(to: .readAloud) else {
            return false
        }
        isActive = true
        audioSessionToken = token
        installAudioCompletionCallback()
        beginAnalyticsReadSessionIfNeeded(resume: false)
        invalidateAccessRetry()
        applyPlaybackMetadata()
        applySpeed()
        playbackVoiceID = settings.voice(for: docLanguage)
        isFinished = false
        generationEpoch &+= 1
        generationTask?.cancel()
        generationTask = nil
        resetLiveWebCarryPrewarmState()
        clearPrefetch()
        cloneRequestIDs.removeAll(keepingCapacity: false)

        setMoreSegmentsExpected(false)
        segmentsByParagraph[paragraphIndex] = segments
        currentParagraphIndex = paragraphIndex
        processedDisplayText = segments.map { $0.text }.joined()
        highlightRange = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        pdfHighlight = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        status = .ready
        if document.sourceKind.isWebRendered { webAudioSegments.append(contentsOf: segments) }

        // The new page owner is installed after the shared AVPlayerItem may
        // already have started. @Published does not replay a time tick merely
        // because `isActive` changed, so synchronously catch the visual state up
        // to the exact player time instead of skipping the first words.
        let adoptionTime = audio.currentTime
        updateHighlight(adoptionTime)
        primeKindleHighlightForContinuousAdoption(at: adoptionTime)
        updateNowPlayingCaption(adoptionTime)

        preloadNext(after: paragraphIndex)
        return true
    }

    /// The queued next-page item is adopted at a rebased time of zero. Cloud
    /// timestamps commonly start a fraction of a second later, so the normal
    /// tick path intentionally publishes no word yet. Kindle's audio gate needs
    /// a concrete first bbox before it can release audio; prime only that first
    /// locally aligned word and let subsequent ticks resume normal ownership.
    private func primeKindleHighlightForContinuousAdoption(at time: Double) {
        guard document.sourceKind == .kindle,
              photoHighlightWordRange == nil,
              time <= 0.35,
              let segment = audio.currentSegment,
              segment.paragraphIndex == currentParagraphIndex,
              hasReliableWordHighlight(segment) else { return }

        let segments = wordHighlightSegments(segmentsByParagraph[currentParagraphIndex] ?? [])
        guard let segmentPosition = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        ensureOCRWordAligned()
        let firstGlobalIndex = segments.prefix(segmentPosition).reduce(0) { $0 + $1.timestamps.count }
        let end = min(ocrWordIndexes.count, firstGlobalIndex + segment.timestamps.count)
        guard firstGlobalIndex < end,
              let mapped = ocrWordIndexes[firstGlobalIndex..<end].compactMap({ $0 }).first else { return }

        photoHighlightWordRange = ocrWordRanges[firstGlobalIndex..<end].compactMap { $0 }.first
            ?? (mapped..<(mapped + 1))
        photoHighlightWordIndex = mapped
        #if DEBUG
        NSLog(
            "CRDBG kindle continuous highlight primed para=%d word=%d timeMs=%d",
            currentParagraphIndex,
            mapped,
            Int(time * 1_000)
        )
        #endif
    }

    /// Covers the rare case where a very short prefetched utterance finishes
    /// while the Kindle visual surface is still committing the page turn.
    func continueAfterAdoptedPlaybackCompleted() {
        guard isActive, currentParagraphIndex >= 0 else { return }
        advance()
    }

    private func applyPlaybackMetadata() {
        audio.setBook(
            id: playbackBookID ?? document.id,
            title: playbackTitle ?? document.title,
            chapterTitle: playbackChapterTitle,
            coverUrl: playbackCoverURL
        )
    }

    deinit {
        readablePageTask?.cancel()
        generationTask?.cancel()
        listenCapRefreshTask?.cancel()
        accessRetryTask?.cancel()
        prefetchPromotionTask?.cancel()
        prefetchTask?.cancel()
    }

    private func cancelReadablePagePreparation() {
        readablePageTask?.cancel()
        readablePageTask = nil
    }

    private func prepareOpeningWebPage() -> Bool {
        guard let prepareReadableWebPage else { return false }
        guard readablePageTask == nil else { return true }
        status = .loading
        readablePageTask = Task { @MainActor [weak self] in
            let ready = await prepareReadableWebPage()
            guard !Task.isCancelled, let self else { return }
            self.readablePageTask = nil
            guard !self.isPlaybackPausedByUser,
                  self.audio.sleepTimer.permitsAutomaticPlayback() else {
                self.status = .pending
                return
            }
            guard ready, self.hasReadableWebContent else {
                self.status = .error(AppLocalized("无可朗读内容"))
                return
            }
            self.status = .pending
            self.start()
        }
        return true
    }

    private func invalidateAccessRetry() {
        accessRetryEpoch &+= 1
        accessRetryTask?.cancel()
        accessRetryTask = nil
    }

    private func recomputeReadableIndices() {
        if webParagraphs == nil, let cached = document.precomputedResumeIndex,
           cached.fingerprints.count == paras.count {
            resumeDocumentIndex = cached
        } else {
            resumeDocumentIndex = ReadingResumeDocumentIndex(paragraphs: paras)
        }
        readableIndices = resumeDocumentIndex.readable.sorted()
    }

    /// .web：注入 WebView extractor 提取的正文段落，准备朗读。
    func loadWebParagraphs(
        _ p: [ReadingParagraph],
        language: String? = nil,
        weReadBoundary: WeReadPageSpeechBoundary? = nil
    ) {
        cloneRequestIDs.removeAll(keepingCapacity: false)
        webParagraphs = p
        if let language { webLanguage = language }
        weReadSpeechBoundary = weReadBoundary
        if !isActive, currentParagraphIndex < 0 {
            playbackVoiceID = settings.voice(for: docLanguage)
        }
        webAudioSegments = []
        recomputeReadableIndices()
        restoreSavedReadingPosition()
        if deferredWebAutoplay.contentBecameReady(isReady: !readableIndices.isEmpty) {
            ensurePlaying()
        }
    }

    /// Explicit system/clipboard actions must start even when the user's
    /// general "Auto Play" setting is off. If WebKit already extracted the
    /// article this resumes immediately; otherwise the request is consumed by
    /// `loadWebParagraphs` exactly once.
    func requestAutoplayWhenWebReady() {
        if deferredWebAutoplay.request(isReady: !readableIndices.isEmpty) {
            ensurePlaying()
        }
    }

    /// Keep the non-owning mode aligned with a newly committed live WebView
    /// page without touching the shared AVPlayer/TTS request currently owned
    /// by Explain. Calling the normal replacement path here would clear the
    /// active mode's queue.
    func stageInactiveLiveWebPage(
        _ p: [ReadingParagraph],
        language: String? = nil,
        weReadBoundary: WeReadPageSpeechBoundary? = nil
    ) {
        guard !isActive else { return }
        pendingReadingAudioCursor = nil
        pendingResumeParagraphIndex = nil
        resumeNotice = nil
        invalidateAccessRetry()
        generationEpoch &+= 1
        liveWebTurnIntentSuspended = false
        generationTask?.cancel()
        generationTask = nil
        resetLiveWebCarryPrewarmState()
        clearPrefetch()
        cloneRequestIDs.removeAll(keepingCapacity: false)
        webParagraphs = p
        if let language { webLanguage = language }
        weReadSpeechBoundary = weReadBoundary
        segmentsByParagraph.removeAll(keepingCapacity: false)
        webAudioSegments = []
        recomputeReadableIndices()
        currentParagraphIndex = -1
        playbackVoiceID = settings.voice(for: docLanguage)
        processedDisplayText = nil
        highlightRange = nil
        webHighlight = nil
        pdfHighlight = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        isFinished = false
        didSignalPageBoundaryApproaching = false
        preferredLiveWebStartIndex = nil
        isAwaitingLiveWebCarryCompletion = false
        pendingLiveWebCarryStartIndex = nil
        pendingLiveWebResume = nil
        status = .pending
    }

    // A blocked web document must not restart through its toolbar, mini player,
    // or a delayed access retry, even after shared-player ownership changes.
    var webContentBlockMessage: String?

    func invalidateAO3Content(message: String) {
        guard document.sourceKind == .web, AO3PageUpdate.isAO3URL(document.sourceURL) else { return }
        invalidateWebContent(message: message)
    }

    func invalidateWebContent(message: String) {
        guard document.sourceKind.isWebRendered else { return }
        stop() // Clear this owner's queue before releasing its session.
        deactivate()
        segmentsByParagraph.removeAll(keepingCapacity: false)
        stageInactiveLiveWebPage([])
        webContentBlockMessage = message
        status = .error(message)
    }

    private func requireWebContentReady() -> Bool {
        guard let message = webContentBlockMessage else { return true }
        status = .error(message)
        return false
    }

    var stagedLiveWebParagraphTexts: [String] {
        webParagraphs?.map(\.text) ?? []
    }

    func makeWeReadPlaybackResumeAnchor() -> WeReadPlaybackResumeAnchor? {
        guard ownsAudioQueue,
              document.sourceKind.isLiveWebLibrary,
              let segment = audio.currentSegment,
              currentParagraphIndex >= 0,
              currentParagraphIndex < paras.count else { return nil }
        let duration = audio.duration > 0.01 ? audio.duration : segment.duration
        let progress = duration > 0.01 ? min(0.98, max(0, audio.currentTime / duration)) : 0
        return WeReadPlaybackResumeAnchor(
            segmentText: segment.text,
            sourceParagraphText: paras[currentParagraphIndex].text,
            segmentProgress: progress,
            wasPlaying: audio.isPlaying
        )
    }

    /// A WeRead reader page is a live, replaceable surface rather than a
    /// static article.  Replacing it must cancel the old page's stream and
    /// clear the player before starting the confirmed new page; otherwise a
    /// stale queue can speak one more paragraph after a manual page turn.
    func replaceLiveWebPage(
        _ p: [ReadingParagraph],
        language: String? = nil,
        autoplay: Bool,
        weReadBoundary: WeReadPageSpeechBoundary? = nil,
        resumeAnchor: WeReadPlaybackResumeAnchor? = nil
    ) {
        flushReadingProgress()
        pendingReadingAudioCursor = nil
        pendingResumeParagraphIndex = nil
        resumeNotice = nil
        let token = ensureAudioSessionClaim()
        invalidateAccessRetry()
        generationEpoch &+= 1
        liveWebTurnIntentSuspended = false
        generationTask?.cancel()
        generationTask = nil
        resetLiveWebCarryPrewarmState()
        clearPrefetch()
        cloneRequestIDs.removeAll(keepingCapacity: false)
        if let token {
            _ = audio.setMoreSegmentsExpected(false, session: token)
            _ = audio.clearQueue(session: token)
        }
        webParagraphs = p
        if let language { webLanguage = language }
        weReadSpeechBoundary = weReadBoundary
        let resumedParagraph = resumeAnchor.flatMap {
            WeReadPlaybackResumeContract.paragraphIndex(in: p, anchor: $0)
        }
        preferredLiveWebStartIndex = resumedParagraph
        isAwaitingLiveWebCarryCompletion = false
        pendingLiveWebCarryStartIndex = nil
        pendingLiveWebResume = resumeAnchor.flatMap { anchor in
            resumedParagraph.map { PendingLiveWebResume(anchor: anchor, paragraphIndex: $0) }
        }
        webAudioSegments = []
        recomputeReadableIndices()
        currentParagraphIndex = -1
        processedDisplayText = nil
        highlightRange = nil
        webHighlight = nil
        pdfHighlight = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        isFinished = false
        didSignalPageBoundaryApproaching = false
        playbackVoiceID = settings.voice(for: docLanguage)
        status = .pending
        if autoplay, !isPlaybackPausedByUser, !readableIndices.isEmpty {
            start()
        }
    }

    /// Replace a confirmed WeRead Canvas page while preserving the shared
    /// AVPlayer queue.  The first paragraph is already appended behind the old
    /// page's tail; this method transfers text/highlight ownership without
    /// stopping that tail or restarting the prepared item.
    @discardableResult
    func commitContinuousLiveWebPage(
        _ p: [ReadingParagraph],
        language: String,
        preparedSegments: [AudioSegment],
        weReadBoundary: WeReadPageSpeechBoundary? = nil
    ) -> Bool {
        guard ownsAudioQueue,
              !p.isEmpty,
              !preparedSegments.isEmpty,
              canContinueAcrossLivePageBoundary else { return false }
        discardReadingResumeForConfirmedNavigation()
        invalidateAccessRetry()
        generationEpoch &+= 1
        generationTask?.cancel()
        generationTask = nil
        resetLiveWebCarryPrewarmState()
        clearPrefetch()
        cloneRequestIDs.removeAll(keepingCapacity: false)
        isAwaitingLiveWebCarryCompletion = false
        pendingLiveWebCarryStartIndex = nil

        webParagraphs = p
        webLanguage = language
        weReadSpeechBoundary = weReadBoundary
        recomputeReadableIndices()
        guard let preparedParagraph = preparedSegments.first?.paragraphIndex,
              readableIndices.contains(preparedParagraph),
              preparedSegments.allSatisfy({ $0.paragraphIndex == preparedParagraph }) else { return false }

        activate()
        applyPlaybackMetadata()
        applySpeed()
        playbackVoiceID = settings.voice(for: docLanguage)
        segmentsByParagraph.removeAll(keepingCapacity: true)
        segmentsByParagraph[preparedParagraph] = preparedSegments
        webAudioSegments = preparedSegments
        currentParagraphIndex = preparedParagraph
        processedDisplayText = preparedSegments.map(\.text).joined()
        highlightRange = nil
        webHighlight = nil
        pdfHighlight = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        lastNowPlayingCaption = nil
        isFinished = false
        didSignalPageBoundaryApproaching = false
        setMoreSegmentsExpected(false)
        status = .ready

        preloadNext(after: preparedParagraph)
        return true
    }

    /// Move visual/highlight ownership to the confirmed next WeRead page while
    /// the old page's final natural sentence is still playing. Unlike a
    /// prediction, this exact committed page can safely prewarm its first
    /// paragraph off-queue; the buffer is promoted only after the immutable
    /// carry segment completes.
    @discardableResult
    func commitLiveWebPageDuringActiveCarry(
        _ p: [ReadingParagraph],
        language: String,
        carrySegmentID: String,
        weReadBoundary: WeReadPageSpeechBoundary? = nil
    ) -> Bool {
        guard ownsAudioQueue,
              !p.isEmpty,
              !isFinished,
              audio.currentSegment?.id == carrySegmentID else { return false }

        discardReadingResumeForConfirmedNavigation()
        invalidateAccessRetry()
        generationEpoch &+= 1
        let epoch = generationEpoch
        generationTask?.cancel()
        generationTask = nil
        resetLiveWebCarryPrewarmState()
        clearPrefetch()
        cloneRequestIDs.removeAll(keepingCapacity: false)
        webParagraphs = p
        webLanguage = language
        weReadSpeechBoundary = weReadBoundary
        recomputeReadableIndices()
        segmentsByParagraph.removeAll(keepingCapacity: true)
        webAudioSegments = []
        currentParagraphIndex = -1
        processedDisplayText = nil
        highlightRange = nil
        webHighlight = nil
        pdfHighlight = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        clearOCRWordAlignment()
        lastWordKey = ""
        lastNowPlayingCaption = nil
        isFinished = false
        didSignalPageBoundaryApproaching = false
        isAwaitingLiveWebCarryCompletion = true
        pendingLiveWebCarryStartIndex = readableIndices.first
        setMoreSegmentsExpected(false)
        status = .ready
        if let startIndex = pendingLiveWebCarryStartIndex,
           let session = audioSessionToken {
            startLiveWebCarryPrewarm(
                paragraphIndex: startIndex,
                epoch: epoch,
                session: session
            )
        }
        return true
    }

    /// Clears page-local exact prewarm state. The caller owns cancellation of
    /// `generationTask`; keeping cancellation explicit avoids accidentally
    /// stopping ordinary foreground generation from an unrelated reset.
    private func resetLiveWebCarryPrewarmState() {
        liveWebCarryPrewarmIndex = nil
        liveWebCarryPrewarmEpoch = nil
        liveWebCarryPrewarmSession = nil
        liveWebCarryPrewarmSourceText = ""
        liveWebCarryPrewarmVoiceID = ""
        liveWebCarryPrewarmLanguage = ""
        liveWebCarryPrewarmSegments.removeAll(keepingCapacity: false)
        liveWebCarryPrewarmProducerFinished = false
        liveWebCarryPrewarmPlaybackDue = false
        liveWebCarryPrewarmPlaybackStarted = false
        liveWebCarryPrewarmDeferredStartSegmentID = nil
        liveWebCarryPrewarmDeferredPredecessorSegmentID = nil
        liveWebCarryPrewarmError = nil
    }

    private func liveWebCarryPrewarmIdentityIsCurrent(
        paragraphIndex: Int,
        epoch: UInt64,
        session: AudioPlaybackSessionToken,
        sourceText: String,
        voiceID: String,
        language: String,
        serial: UInt64
    ) -> Bool {
        guard document.sourceKind == .weread,
              isActive,
              generationEpoch == epoch,
              liveWebCarryPrewarmEpoch == epoch,
              liveWebCarryPrewarmSession == session,
              liveWebCarryPrewarmIndex == paragraphIndex,
              liveWebCarryPrewarmSourceText == sourceText,
              liveWebCarryPrewarmVoiceID == voiceID,
              liveWebCarryPrewarmLanguage == language,
              liveWebCarryPrewarmSerial == serial,
              audioSessionToken == session,
              audio.isPlaybackSessionActive(session),
              paras.indices.contains(paragraphIndex),
              paras[paragraphIndex].resolvedSpeechText == sourceText,
              settings.voice(for: docLanguage) == voiceID,
              docLanguage == language else { return false }
        return true
    }

    private func liveWebCarryPrewarmCanAcceptCallbacks(
        paragraphIndex: Int,
        epoch: UInt64,
        session: AudioPlaybackSessionToken,
        sourceText: String,
        voiceID: String,
        language: String,
        serial: UInt64
    ) -> Bool {
        liveWebCarryPrewarmIdentityIsCurrent(
            paragraphIndex: paragraphIndex,
            epoch: epoch,
            session: session,
            sourceText: sourceText,
            voiceID: voiceID,
            language: language,
            serial: serial
        ) && !liveWebCarryPrewarmProducerFinished
            && liveWebCarryPrewarmError == nil
    }

    private func startLiveWebCarryPrewarm(
        paragraphIndex: Int,
        epoch: UInt64,
        session: AudioPlaybackSessionToken
    ) {
        guard document.sourceKind == .weread,
              isAwaitingLiveWebCarryCompletion,
              paras.indices.contains(paragraphIndex),
              audioSessionToken == session,
              audio.isPlaybackSessionActive(session) else { return }

        let paragraph = paras[paragraphIndex]
        let sourceText = paragraph.resolvedSpeechText
        let voiceID = settings.voice(for: docLanguage)
        let language = docLanguage
        liveWebCarryPrewarmSerial &+= 1
        let serial = liveWebCarryPrewarmSerial
        liveWebCarryPrewarmIndex = paragraphIndex
        liveWebCarryPrewarmEpoch = epoch
        liveWebCarryPrewarmSession = session
        liveWebCarryPrewarmSourceText = sourceText
        liveWebCarryPrewarmVoiceID = voiceID
        liveWebCarryPrewarmLanguage = language
        liveWebCarryPrewarmSegments = []
        liveWebCarryPrewarmProducerFinished = false
        liveWebCarryPrewarmPlaybackDue = false
        liveWebCarryPrewarmPlaybackStarted = false
        liveWebCarryPrewarmDeferredStartSegmentID = nil
        liveWebCarryPrewarmDeferredPredecessorSegmentID = nil
        liveWebCarryPrewarmError = nil
        playbackVoiceID = voiceID
        ReaderRunLog.write(
            "WEREAD exact prewarm start para=\(paragraphIndex) epoch=\(epoch) " +
            "serial=\(serial) chars=\(sourceText.utf16.count)"
        )

        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.speechGenerator.generatePrefetchSegments(
                    paragraphIndex: paragraphIndex,
                    text: SpeechTextSanitizer.sanitizedForTTS(sourceText),
                    voice: voiceID,
                    speed: 1.0,
                    language: language,
                    includeVoiceCode: self.includeVoiceCodeForTTS,
                    speaker: paragraph.speaker
                ) { [weak self] rawSegment in
                    self?.receiveLiveWebCarryPrewarmSegment(
                        rawSegment,
                        paragraphIndex: paragraphIndex,
                        epoch: epoch,
                        session: session,
                        sourceText: sourceText,
                        voiceID: voiceID,
                        language: language,
                        serial: serial
                    )
                }
                try Task.checkCancellation()
                self.finishLiveWebCarryPrewarm(
                    paragraphIndex: paragraphIndex,
                    epoch: epoch,
                    session: session,
                    sourceText: sourceText,
                    voiceID: voiceID,
                    language: language,
                    serial: serial
                )
            } catch is CancellationError, TTSError.cancelled {
                guard self.liveWebCarryPrewarmIdentityIsCurrent(
                    paragraphIndex: paragraphIndex,
                    epoch: epoch,
                    session: session,
                    sourceText: sourceText,
                    voiceID: voiceID,
                    language: language,
                    serial: serial
                ) else { return }
                self.generationTask = nil
                ReaderRunLog.write(
                    "WEREAD exact prewarm cancelled para=\(paragraphIndex) " +
                    "epoch=\(epoch) serial=\(serial)"
                )
            } catch {
                self.failLiveWebCarryPrewarm(
                    error,
                    paragraphIndex: paragraphIndex,
                    epoch: epoch,
                    session: session,
                    sourceText: sourceText,
                    voiceID: voiceID,
                    language: language,
                    serial: serial
                )
            }
        }
    }

    private func receiveLiveWebCarryPrewarmSegment(
        _ rawSegment: AudioSegment,
        paragraphIndex: Int,
        epoch: UInt64,
        session: AudioPlaybackSessionToken,
        sourceText: String,
        voiceID: String,
        language: String,
        serial: UInt64
    ) {
        guard liveWebCarryPrewarmCanAcceptCallbacks(
            paragraphIndex: paragraphIndex,
            epoch: epoch,
            session: session,
            sourceText: sourceText,
            voiceID: voiceID,
            language: language,
            serial: serial
        ), rawSegment.paragraphIndex == paragraphIndex else { return }

        // Page-local paragraph/segment indexes restart at zero. Rebase this
        // exact producer so a late callback cannot collide with a prior page's
        // queue item or pre-staged file.
        let segment = AudioSegment(
            paragraphIndex: paragraphIndex,
            segmentIndex: 850_000_000
                + Int(serial % 5_000) * 10_000
                + rawSegment.segmentIndex,
            audioData: rawSegment.audioData,
            timestamps: rawSegment.timestamps,
            duration: rawSegment.duration,
            text: rawSegment.text,
            isWavFormat: rawSegment.isWavFormat,
            unprocessedText: rawSegment.unprocessedText,
            speaker: rawSegment.speaker
        )
        liveWebCarryPrewarmSegments.append(segment)
        ReaderRunLog.write(
            "WEREAD exact prewarm segment para=\(paragraphIndex) " +
            "seg=\(rawSegment.segmentIndex) buffered=\(liveWebCarryPrewarmSegments.count) " +
            "due=\(liveWebCarryPrewarmPlaybackDue ? "Y" : "N")"
        )

        if liveWebCarryPrewarmPlaybackStarted {
            let shouldDeferDrainedQueueStart = liveWebTurnIntentSuspended
                && audio.isWaitingForNextSegment
            let deferredPredecessorID = shouldDeferDrainedQueueStart
                ? audio.currentSegment?.id
                : nil
            segmentsByParagraph[paragraphIndex, default: []].append(segment)
            processedDisplayText = segmentsByParagraph[paragraphIndex]?.map(\.text).joined()
            webAudioSegments.append(segment)
            guard audio.loadSegment(
                segment,
                autoPlay: !liveWebTurnIntentSuspended,
                session: session
            ) else {
                failLiveWebCarryPrewarm(
                    TTSError.generationFailed("audio_queue_rejected"),
                    paragraphIndex: paragraphIndex,
                    epoch: epoch,
                    session: session,
                    sourceText: sourceText,
                    voiceID: voiceID,
                    language: language,
                    serial: serial
                )
                return
            }
            if shouldDeferDrainedQueueStart,
               liveWebCarryPrewarmDeferredStartSegmentID == nil {
                liveWebCarryPrewarmDeferredStartSegmentID = segment.id
                liveWebCarryPrewarmDeferredPredecessorSegmentID = deferredPredecessorID
            }
            status = .streaming
        } else if liveWebCarryPrewarmPlaybackDue {
            startLiveWebCarryPlaybackIfReady(paragraphIndex: paragraphIndex)
        }
    }

    private func finishLiveWebCarryPrewarm(
        paragraphIndex: Int,
        epoch: UInt64,
        session: AudioPlaybackSessionToken,
        sourceText: String,
        voiceID: String,
        language: String,
        serial: UInt64
    ) {
        guard liveWebCarryPrewarmCanAcceptCallbacks(
            paragraphIndex: paragraphIndex,
            epoch: epoch,
            session: session,
            sourceText: sourceText,
            voiceID: voiceID,
            language: language,
            serial: serial
        ) else { return }
        generationTask = nil
        liveWebCarryPrewarmProducerFinished = true
        if liveWebCarryPrewarmSegments.isEmpty {
            liveWebCarryPrewarmError = AppLocalized("音频播放失败，请重试")
        }
        ReaderRunLog.write(
            "WEREAD exact prewarm done para=\(paragraphIndex) epoch=\(epoch) " +
            "serial=\(serial) segs=\(liveWebCarryPrewarmSegments.count)"
        )
        let wasAlreadyPlaying = liveWebCarryPrewarmPlaybackStarted
        if liveWebCarryPrewarmPlaybackDue,
           !liveWebCarryPrewarmPlaybackStarted {
            startLiveWebCarryPlaybackIfReady(paragraphIndex: paragraphIndex)
        }
        if wasAlreadyPlaying {
            _ = audio.finishStreamingProducer(session: session)
            status = .ready
            preloadNext(after: paragraphIndex)
        }
    }

    private func failLiveWebCarryPrewarm(
        _ error: Error,
        paragraphIndex: Int,
        epoch: UInt64,
        session: AudioPlaybackSessionToken,
        sourceText: String,
        voiceID: String,
        language: String,
        serial: UInt64
    ) {
        guard liveWebCarryPrewarmCanAcceptCallbacks(
            paragraphIndex: paragraphIndex,
            epoch: epoch,
            session: session,
            sourceText: sourceText,
            voiceID: voiceID,
            language: language,
            serial: serial
        ) else { return }
        generationTask?.cancel()
        generationTask = nil
        liveWebCarryPrewarmProducerFinished = true
        liveWebCarryPrewarmDeferredStartSegmentID = nil
        liveWebCarryPrewarmDeferredPredecessorSegmentID = nil
        liveWebCarryPrewarmError = AppLocalized("音频播放失败，请重试")
        if liveWebCarryPrewarmPlaybackDue {
            currentParagraphIndex = paragraphIndex
            status = .error(AppLocalized("音频播放失败，请重试"))
        }
        // If one or more exact segments are already playing, deliberately keep
        // the producer open. Letting the queue complete would call `advance`
        // and silently skip the missing remainder; a user retry safely
        // regenerates the exact paragraph instead.
        ReaderRunLog.write(
            "WEREAD exact prewarm failed para=\(paragraphIndex) epoch=\(epoch) " +
            "serial=\(serial) buffered=\(liveWebCarryPrewarmSegments.count) " +
            "started=\(liveWebCarryPrewarmPlaybackStarted ? "Y" : "N") " +
            "error=\(error.localizedDescription)"
        )
    }

    private func startLiveWebCarryPlaybackIfReady(paragraphIndex: Int) {
        guard liveWebCarryPrewarmPlaybackDue,
              !liveWebCarryPrewarmPlaybackStarted,
              liveWebCarryPrewarmIndex == paragraphIndex,
              let epoch = liveWebCarryPrewarmEpoch,
              let session = liveWebCarryPrewarmSession else { return }

        currentParagraphIndex = paragraphIndex
        if let error = liveWebCarryPrewarmError {
            status = .error(error)
            return
        }
        let initialSegments = liveWebCarryPrewarmSegments
        guard !initialSegments.isEmpty else {
            if liveWebCarryPrewarmProducerFinished {
                status = .error(AppLocalized("音频播放失败，请重试"))
            } else {
                _ = audio.setMoreSegmentsExpected(true, session: session)
                status = .loading
            }
            return
        }
        guard generationEpoch == epoch,
              audioSessionToken == session,
              audio.isPlaybackSessionActive(session),
              paras.indices.contains(paragraphIndex),
              paras[paragraphIndex].resolvedSpeechText == liveWebCarryPrewarmSourceText,
              settings.voice(for: docLanguage) == liveWebCarryPrewarmVoiceID,
              docLanguage == liveWebCarryPrewarmLanguage else {
            return
        }

        liveWebCarryPrewarmPlaybackStarted = true
        segmentsByParagraph[paragraphIndex] = initialSegments
        processedDisplayText = initialSegments.map(\.text).joined()
        webAudioSegments = initialSegments
        highlightRange = nil
        webHighlight = nil
        pdfHighlight = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        lastNowPlayingCaption = nil
        isFinished = false
        didSignalPageBoundaryApproaching = false
        let shouldAutoPlay = !liveWebTurnIntentSuspended
        liveWebCarryPrewarmDeferredStartSegmentID = shouldAutoPlay
            ? nil
            : initialSegments.first?.id
        liveWebCarryPrewarmDeferredPredecessorSegmentID = nil
        guard audio.loadSegments(
            initialSegments,
            autoPlay: shouldAutoPlay,
            session: session
        ) else {
            liveWebCarryPrewarmPlaybackStarted = false
            failLiveWebCarryPrewarm(
                TTSError.generationFailed("audio_queue_rejected"),
                paragraphIndex: paragraphIndex,
                epoch: epoch,
                session: session,
                sourceText: liveWebCarryPrewarmSourceText,
                voiceID: liveWebCarryPrewarmVoiceID,
                language: liveWebCarryPrewarmLanguage,
                serial: liveWebCarryPrewarmSerial
            )
            return
        }
        _ = audio.setMoreSegmentsExpected(
            !liveWebCarryPrewarmProducerFinished,
            session: session
        )
        status = liveWebCarryPrewarmProducerFinished ? .ready : .streaming
        ReaderRunLog.write(
            "WEREAD exact prewarm promoted para=\(paragraphIndex) epoch=\(epoch) " +
            "buffered=\(initialSegments.count) " +
            "producer=\(liveWebCarryPrewarmProducerFinished ? "done" : "active")"
        )
        if liveWebCarryPrewarmProducerFinished {
            preloadNext(after: paragraphIndex)
        }
    }

    private func setWebHighlight(_ c: WebHighlightCmd) {
        guard webHighlight != c else { return }
        webHighlight = c
    }

    /// 按句末标点切句，返回每句在原文中的字符范围（去句首空白）。
    private func sentenceRanges(_ text: String) -> [Range<Int>] {
        ReadingSentenceContract.characterRanges(in: text, lineBreakIsBoundary: true)
    }

    /// 按字数比例估算当前播放时间对应的句子字符范围（中文无词时间戳时的句级推进）。
    private func currentSentenceRange(in text: String, at t: Double, duration: Double) -> Range<Int>? {
        let total = text.count
        guard total > 0 else { return nil }
        let ranges = sentenceRanges(text)
        guard duration > 0.01 else { return ranges.first }
        let frac = min(1.0, max(0.0, t / duration))
        let target = Int(frac * Double(total))
        for r in ranges where target < r.upperBound { return r }
        return ranges.last
    }

    /// 朗读高亮 + 解读 mark 统一基色（设置可选，默认 #FD5F01；橙色深浅模式都清晰可见）
    var markBaseColor: UIColor { UIColor(hexString: settings.highlightColorHex) }
    /// 朗读词高亮背景：基色半透明（文字透出不被遮盖，深浅都可见）
    var highlightUIColor: UIColor { markBaseColor.withAlphaComponent(0.4) }

    // MARK: - Durable read position

    private var readingProgressID: String { playbackBookID ?? document.id }
    private var readingProgressVariant: String? {
        document.sourceKind == .youtube ? youtubeTranscriptCacheKey?.storageKey : nil
    }

    private func restoreSavedReadingPosition() {
        guard !hasObservedReadingPlayback,
              !readableIndices.isEmpty,
              progressBoundaryToken == historyStore.progressBoundaryToken else { return }
        let key = readingProgressID + ":" + resumeDocumentIndex.fingerprint
        guard restoredReadingStructure != key else { return }
        restoredReadingStructure = key
        if let checkpoint = historyStore.readingCheckpoint(for: readingProgressID, variant: readingProgressVariant),
           checkpoint.sourceKind == document.sourceKind {
            let restored = resumeDocumentIndex.resolve(checkpoint) != nil ? checkpoint
                : ReadingResumeContract.relocatedKindleCheckpoint(checkpoint, paragraphs: paras)
#if DEBUG
            if let restored, restored.paragraphFingerprint != checkpoint.paragraphFingerprint {
                ReaderRunLog.write("READ resume reflow source=\(document.sourceKind.rawValue) oldPara=\(checkpoint.paragraphIndex) newPara=\(restored.paragraphIndex) word=\(restored.audio?.semanticWordFingerprint?.prefix(12) ?? "-") fraction=\(restored.audio?.wordFraction ?? -1)")
            }
#endif
            guard let checkpoint = restored, let index = resumeDocumentIndex.resolve(checkpoint) else {
                // Live providers may initially deliver a loading/earlier page.
                // Retain the checkpoint until the actual saved page arrives.
                resumeNotice = AppLocalized("内容已变化，无法准确恢复。请选择从哪里继续朗读。")
                return
            }
            lastReadingCheckpoint = checkpoint
            pendingReadingAudioCursor = checkpoint.audio
            pendingResumeParagraphIndex = index
            currentParagraphIndex = index
            resumeSourceRange = checkpoint.visual?.range(in: paras[index].text)
            resumeSourceParagraphIndex = index
            if let range = resumeSourceRange, document.sourceKind.isOCRImageRendered {
                let source = paras[index].text as NSString
                var cursor = 0
                for (wordIndex, word) in paras[index].words.enumerated() {
                    let found = source.range(of: word.text, range: NSRange(location: cursor, length: source.length - cursor))
                    guard found.location != NSNotFound else { continue }
                    if NSIntersectionRange(found, range).length > 0 {
                        photoHighlightWordIndex = wordIndex
                        photoHighlightWordRange = wordIndex..<(wordIndex + 1)
                        break
                    }
                    cursor = NSMaxRange(found)
                }
            }
            resumeNotice = nil
            ReaderRunLog.write("READ resume located source=\(document.sourceKind.rawValue) para=\(index)")
        } else if historyStore.hasReadingCheckpoint(for: readingProgressID, variant: readingProgressVariant) {
            resumeNotice = AppLocalized("无法读取上次的朗读位置。请选择从哪里继续朗读。")
        } else if let legacy = historyStore.resumeParagraphIndex(for: readingProgressID),
                  readableIndices.contains(legacy) {
            restoreReadingPosition(legacy)
        }
    }

    func flushReadingProgress() {
        saveReadingProgress(force: true)
        historyStore.flushProgressProjection()
    }

    var hasPendingReadingResume: Bool {
        pendingResumeParagraphIndex != nil || pendingReadingAudioCursor != nil
    }

    /// A confirmed page turn is a new position chosen by the user or by natural
    /// completion. A previous-page checkpoint must not hijack its warm audio.
    func discardReadingResumeForConfirmedNavigation() {
        flushReadingProgress()
        if hasPendingReadingResume, !hasObservedReadingPlayback { currentParagraphIndex = -1 }
        pendingResumeParagraphIndex = nil
        pendingReadingAudioCursor = nil
        resumeSourceRange = nil
        resumeNotice = nil
    }

    private func prepareReadingAudioResumeRetry() -> Bool {
        guard resumeNotice != nil else { return true }
        guard pendingReadingAudioCursor != nil,
              let checkpoint = lastReadingCheckpoint,
              resumeDocumentIndex.resolve(checkpoint) == currentParagraphIndex else { return false }
        resumeNotice = nil
        return true
    }

    private func retainReadingCursorForQueueRebuild() {
        // A voice change can arrive before the periodic history write. Capture
        // the actual queue cursor first; never rewind to an older saved tick.
        if ownsAudioQueue, audio.hasAudibleProgress,
           let current = audio.currentSegment, current.paragraphIndex == currentParagraphIndex,
           let cursor = ReadingResumeContract.captureAudio(
                segments: segmentsByParagraph[currentParagraphIndex] ?? [],
                currentSegmentID: current.id, time: audio.playbackPosition) {
            pendingReadingAudioCursor = cursor
            pendingResumeParagraphIndex = currentParagraphIndex
            if paras.indices.contains(currentParagraphIndex) {
                resumeSourceRange = ReadingResumeContract.captureVisual(
                    output: (segmentsByParagraph[currentParagraphIndex] ?? []).map(\.text).joined(),
                    offset: cursor.outputUTF16Offset, length: cursor.outputUTF16Length,
                    source: paras[currentParagraphIndex].text)?.range(in: paras[currentParagraphIndex].text)
                resumeSourceParagraphIndex = currentParagraphIndex
            }
            return
        }
        guard let checkpoint = lastReadingCheckpoint,
              resumeDocumentIndex.resolve(checkpoint) == currentParagraphIndex else { return }
        pendingReadingAudioCursor = checkpoint.audio
        pendingResumeParagraphIndex = currentParagraphIndex
        if paras.indices.contains(currentParagraphIndex) {
            resumeSourceRange = checkpoint.visual?.range(in: paras[currentParagraphIndex].text)
            resumeSourceParagraphIndex = currentParagraphIndex
        }
    }

    private func saveReadingProgress(force: Bool) {
        guard hasObservedReadingPlayback,
              ownsAudioQueue, !audio.isBuffering, pendingReadingAudioCursor == nil,
              let segment = audio.currentSegment,
              segment.paragraphIndex == currentParagraphIndex,
              progressBoundaryToken == historyStore.progressBoundaryToken else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastReadingCheckpointWrite) >= 2 else { return }
        let segments = segmentsByParagraph[currentParagraphIndex] ?? []
        guard let cursor = ReadingResumeContract.captureAudio(
            segments: segments, currentSegmentID: segment.id, time: audio.playbackPosition
        ), var checkpoint = resumeDocumentIndex.checkpoint(
            sourceKind: document.sourceKind, paragraphIndex: currentParagraphIndex, audio: cursor, now: now
        ) else { return }
        if paras.indices.contains(currentParagraphIndex) {
            checkpoint.visual = ReadingResumeContract.captureVisual(
                output: segments.map(\.text).joined(), offset: cursor.outputUTF16Offset,
                length: cursor.outputUTF16Length,
                source: paras[currentParagraphIndex].text)
            if document.sourceKind == .kindle {
                checkpoint.reflow = ReadingResumeContract.captureReflow(
                    source: paras[currentParagraphIndex].text, visual: checkpoint.visual, audio: cursor,
                    precedingSource: paras.prefix(currentParagraphIndex).filter { $0.type.isReadable }.map(\.text).joined(),
                    followingSource: paras.dropFirst(currentParagraphIndex + 1).filter { $0.type.isReadable }.map(\.text).joined())
            }
        }
        if historyStore.saveReadingCheckpoint(checkpoint, for: readingProgressID, boundary: progressBoundaryToken, variant: readingProgressVariant) {
            lastReadingCheckpoint = checkpoint
            lastReadingCheckpointWrite = now
            if force {
                historyStore.updateReadingPosition(documentID: readingProgressID,
                                                   paragraphIndex: currentParagraphIndex)
                ReaderRunLog.write(
                    "READ checkpoint saved source=\(document.sourceKind.rawValue) " +
                    "item=\(ReadingResumeContract.fingerprint(readingProgressID).prefix(12)) " +
                    "para=\(currentParagraphIndex) seg=\(cursor.segmentIndex) " +
                    "time=\(cursor.segmentTime) offset=\(cursor.outputUTF16Offset) " +
                    "visual=\(checkpoint.visual != nil) reflow=\(checkpoint.reflow != nil) " +
                    "word=\(cursor.semanticWordFingerprint?.prefix(12) ?? "-") fraction=\(cursor.wordFraction)"
                )
            }
        }
    }

    /// Used after regenerated output has reached the saved word. Earlier audio
    /// never enters the playing queue, so there is no burst from paragraph zero.
    private func loadResumedReadingAudio(
        _ segments: [AudioSegment], cursor: ReadingResumeAudioCursor,
        isComplete: Bool, autoPlay: Bool, session: AudioPlaybackSessionToken
    ) -> Bool {
        switch ReadingResumeContract.resolveAudio(cursor, segments: segments, isComplete: isComplete) {
        case .waiting:
            return false
        case .unavailable:
#if DEBUG
            ReaderRunLog.write("READ resume unavailable source=\(document.sourceKind.rawValue) " + ReadingResumeContract.audioResumeDiagnostic(cursor, segments: segments))
#endif
            resumeNotice = AppLocalized("语音内容已变化，无法准确恢复。请选择从哪里继续朗读。")
            _ = audio.setMoreSegmentsExpected(false, session: session)
            status = .error(resumeNotice!)
            return false
        case let .seek(segmentIndex, seconds):
#if DEBUG
            debugResumeFirstPlaybackSeconds = nil
            debugResumeAwaitingFirstTick = true
#endif
            let remaining = Array(segments.dropFirst(segmentIndex))
            guard let first = remaining.first,
                  audio.loadSegments(remaining, autoPlay: false, session: session),
                  audio.startQueuedSegment(id: first.id, progress: 0, initialTime: seconds,
                                           autoPlay: autoPlay, session: session) else {
                _ = audio.setMoreSegmentsExpected(false, session: session)
                status = .error(AppLocalized("音频队列已中断，请重试"))
                return false
            }
            pendingReadingAudioCursor = nil
            // Pre-seed accounting so the seek itself never consumes listen time.
            primeListenAccounting(segmentID: first.id, position: seconds)
            analyticsSessionCoordinator.seedPlaybackCursor(
                ownerID: analyticsSessionOwnerID, segmentID: first.id, position: seconds
            )
            ReaderRunLog.write("READ resume audio para=\(currentParagraphIndex) seg=\(segmentIndex) time=\(seconds)")
            return true
        }
    }

    // MARK: - Bind

    private func bind() {
        audio.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.onTick(t) }
            .store(in: &cancellables)
        // Selection and prefetch are not listening. Only the owned player's
        // actual position may replace a durable checkpoint.
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.flushReadingProgress() }
            .store(in: &cancellables)
        audio.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.handlePlaybackState(p) }
            .store(in: &cancellables)
        audio.$isBuffering
            .receive(on: RunLoop.main)
            .sink { [weak self] b in
                guard let self else { return }
                self.isBuffering = b && self.ownsAudioQueue
            }
            .store(in: &cancellables)
        settings.$speed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySpeed() }
            .store(in: &cancellables)
        settings.$voiceSelectionRevision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleVoicePreferenceChanged() }
            .store(in: &cancellables)
        pro.$storeKitLocalPro
            .combineLatest(pro.$serverPro)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySpeed() }
            .store(in: &cancellables)
        #if DEBUG
        pro.$debugForcePro
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySpeed() }
            .store(in: &cancellables)
        #endif
    }

    /// 成为当前激活模式（接管音频回调）。
    func activate() {
        if !isActive { isActive = true }
        _ = ensureAudioSessionClaim()
        installAudioCompletionCallback()
    }

    /// 退出激活（切到解读模式时调用）：必须停掉生成/预取，否则流式生成的新 segment 经 loadSegment 会自动
    /// 重新 playSegment（首段未播放时），导致「切到解读后朗读还在响」。
    func deactivate() {
        cancelReadablePagePreparation()
        flushReadingProgress()
        retainReadingCursorForQueueRebuild()
        // The initial quota refresh happens before `activate()`. Invalidate it
        // even when this VM has not yet acquired playback ownership.
        invalidateAccessRetry()
        let wasActive = isActive
        if wasActive,
           youtubeCompletionSubmittedParagraph != currentParagraphIndex {
            saveYouTubeProgress(
                audio.currentTime,
                force: true,
                waitForPersistence: true
            )
        }
        isActive = false
        if let token = audioSessionToken {
            audio.releasePlaybackSession(token)
        }
        audioSessionToken = nil
        guard wasActive else { return }
        endAnalyticsReadSession(result: .cancelled, reason: "mode_switched")
        generationEpoch &+= 1
        liveWebTurnIntentSuspended = false
        generationTask?.cancel()
        listenCapRefreshTask?.cancel()
        listenCapRefreshTask = nil
        resetLiveWebCarryPrewarmState()
        clearPrefetch()
        cloneRequestIDs.removeAll(keepingCapacity: false)
        isAwaitingLiveWebCarryCompletion = false
        pendingLiveWebCarryStartIndex = nil
        audio.setNowPlayingCaption(nil)
        lastNowPlayingCaption = nil
        // 清朗读高亮状态，避免切到解读后残留（web 源 DOM 另由 setActive→clearOverlay 清）
        highlightRange = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        webHighlight = nil
        pdfHighlight = nil
        if let switchID = activeVoiceSwitchID {
            VoiceSwitchStatusCenter.shared.finish(switchID)
            activeVoiceSwitchID = nil
        }
    }

    // MARK: - Start / control

    func start() {
        guard requireWebContentReady() else { return }
        guard audio.sleepTimer.permitsAutomaticPlayback() else { return }
        start(allowAccessRefresh: true)
    }

    private func start(allowAccessRefresh: Bool) {
        guard requireWebContentReady() else { return }
        guard resumeNotice == nil, readablePageTask == nil else { return }
        isPlaybackPausedByUser = false
        if currentParagraphIndex >= 0, ownsAudioQueue,
           audio.currentSegment != nil || status.isLoading || status.isStreaming {
            ensurePlaying()
            return
        }
        liveWebTurnIntentSuspended = false
        guard !readableIndices.isEmpty else {
            if !prepareOpeningWebPage() { status = .error(AppLocalized("无可朗读内容")) }
            return
        }
        if presentElapsedGrowthWallIfNeeded(resumeAfterPurchase: { [weak self] in
            self?.start(allowAccessRefresh: true)
        }) {
            return
        }
        // YouTube must probe its persistent TTS cache before deciding whether
        // fresh-listen quota is required. Other sources keep the synchronous
        // gate and retry behavior unchanged.
        guard document.sourceKind == .youtube
                || canStartAudio(persistentYouTubeCacheHit: false) else {
            if allowAccessRefresh {
                refreshAccessThenRetryStart()
                return
            }
            status = .pending
            showPaywall = true
            endAnalyticsReadSession(result: .blocked, reason: "listen_quota")
            return
        }
        invalidateAccessRetry()
        beginAnalyticsReadSessionIfNeeded(resume: false)
        activate()
        applyPlaybackMetadata()
        applySpeed()
        let preferred = preferredLiveWebStartIndex.flatMap { readableIndices.contains($0) ? $0 : nil }
        preferredLiveWebStartIndex = nil
        let resume = pendingResumeParagraphIndex.flatMap { readableIndices.contains($0) ? $0 : nil }
        pendingResumeParagraphIndex = nil
        generate(
            preferred ?? resume ?? (readableIndices.contains(currentParagraphIndex) ? currentParagraphIndex : readableIndices[0]),
            allowAccessRefresh: allowAccessRefresh
        )
    }

    /// Seed the start position from the History index (own-content documents
    /// reopened from the library). Only effective before the first playback.
    func restoreReadingPosition(_ paragraphIndex: Int) {
        guard currentParagraphIndex < 0, paragraphIndex >= 0 else { return }
        pendingResumeParagraphIndex = paragraphIndex
        if readableIndices.contains(paragraphIndex) { currentParagraphIndex = paragraphIndex }
    }

    /// A reflowed provider page can contain the tail of the completed page.
    /// Seed an exact source-word cursor so newly generated audio starts at the
    /// first unread word, using the same verified timestamp resolver as resume.
    @discardableResult
    func prepareKindleWordStart(paragraphIndex: Int, wordIndex: Int) -> Bool {
        guard document.sourceKind == .kindle, !hasObservedReadingPlayback,
              paras.indices.contains(paragraphIndex),
              paras[paragraphIndex].words.indices.contains(wordIndex) else { return false }
        let paragraph = paras[paragraphIndex]
        let source = paragraph.text as NSString
        var offset = 0
        for (index, word) in paragraph.words.enumerated() {
            let range = source.range(of: word.text, range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound else { return false }
            offset = NSMaxRange(range)
            guard index == wordIndex else { continue }
            guard let cursor = ReadingResumeContract.sourceWordCursor(source: paragraph.text, range: range) else { return false }
            pendingReadingAudioCursor = cursor
            pendingResumeParagraphIndex = paragraphIndex
            currentParagraphIndex = paragraphIndex
            resumeSourceRange = range
            resumeSourceParagraphIndex = paragraphIndex
            lastReadingCheckpoint = resumeDocumentIndex.checkpoint(sourceKind: .kindle,
                paragraphIndex: paragraphIndex, audio: cursor)
            resumeNotice = nil
            return true
        }
        return false
    }

    /// Selecting a TOC destination is browsing. Cancel old streaming work and
    /// persist the new position even if the user never starts audio there.
    @Published var epubNavigationParagraphIndex: Int? = nil

    func navigateToEpubParagraph(_ paragraph: Int) {
        guard document.sourceKind == .epub, paras.indices.contains(paragraph) else { return }
        stop()
        pendingReadingAudioCursor = nil
        pendingResumeParagraphIndex = nil
        resumeSourceRange = nil
        resumeNotice = nil
        hasObservedReadingPlayback = false
        isPlaying = false
        isBuffering = false
        isPlaybackPausedByUser = true
        isFinished = false
        highlightRange = nil
        processedDisplayText = nil
        autoScrollEnabled = true
        let readable = readableIndices.first(where: { $0 >= paragraph }) ?? readableIndices.last
        currentParagraphIndex = readable ?? paragraph
        pendingResumeParagraphIndex = readable
        epubNavigationParagraphIndex = paragraph
        if let readable, let checkpoint = resumeDocumentIndex.checkpoint(
            sourceKind: .epub, paragraphIndex: readable, audio: nil
        ), historyStore.saveReadingCheckpoint(checkpoint, for: readingProgressID,
                                             boundary: progressBoundaryToken, variant: readingProgressVariant) {
            lastReadingCheckpoint = checkpoint
            historyStore.updateReadingPosition(documentID: readingProgressID, paragraphIndex: readable)
            historyStore.flushProgressProjection()
        }
        ReaderRunLog.write("EPUB toc selected paragraph=\(paragraph) speech=\(readable ?? -1)")
    }

    /// A pause also owns audio that has not arrived yet. Keep the request and
    /// checkpoint, but prevent late segments or page commits from restarting it.
    func pausePlayback() {
        cancelReadablePagePreparation()
        isPlaybackPausedByUser = true
        liveWebTurnIntentSuspended = true
        invalidateAccessRetry()
        if let token = audioSessionToken { _ = audio.pause(session: token) }
        isPlaying = false
        isBuffering = false
        flushReadingProgress()
    }

    func togglePlayPause() {
        guard requireWebContentReady() else { return }
        if isPreparingReadablePage { pausePlayback(); return }
        audio.sleepTimer.resumeByUser()
        guard prepareReadingAudioResumeRetry() else { return }
        isPlaybackPausedByUser = false
        liveWebTurnIntentSuspended = false
        if currentParagraphIndex < 0 { start(); return }
        if !audio.isPlaying,
           presentElapsedGrowthWallIfNeeded(resumeAfterPurchase: { [weak self] in
               self?.togglePlayPause()
           }) {
            return
        }
        if ownsAudioQueue, audio.isPlaying {
            pausePlayback()
            return
        }
        if case .error = status {
            retryCurrentParagraph()
            return
        }
        if ownsAudioQueue,
           !audio.isExplicitlyPaused,
           (audio.isPlaying || status.isLoading || status.isStreaming || isBuffering) {
            pausePlayback()
            return
        }
        // A second tap while the first cloud request is still waiting for
        // playable audio is not a retry. Restarting it cancels valid work and
        // makes a slow network request take roughly twice as long.
        if pendingPrefetchAdvanceFrom != nil {
            resumePendingParagraphAdvance()
            return
        }
        // 从暂停恢复播放时补额度闸门：否则免费用户在「宽限硬上限」弹墙后关墙、再点播放即可无限续听。
        if !audio.isPlaying,
           !currentAudioIsQuotaExempt,
           !pro.isPro,
           !quota.canStartListen(isPro: pro.isPro) {
            refreshAccessThenRetryResume()
            return
        }
        invalidateAccessRetry()
        if !ownsAudioQueue {
            beginAnalyticsReadSessionIfNeeded(resume: true)
            rebuildCurrentParagraphAfterOwnershipChange()
            return
        }
        if !audio.isPlaying { beginAnalyticsReadSessionIfNeeded(resume: true) }
        if (status.isLoading || status.isStreaming),
           let token = audioSessionToken {
            _ = audio.play(session: token)
            return
        }
        if !audio.isPlaying, !audio.hasQueuedSegments, audio.currentSegment == nil, !isFinished {
            generate(currentParagraphIndex)
            return
        }
        if let token = audioSessionToken {
            _ = audio.togglePlayPause(session: token)
            if !audio.isPlaying { flushReadingProgress() }
        }
    }

    /// Idempotent entry-point for external "Continue Listening" actions.
    /// Reattaching while audio is playing or TTS is still loading must not pause
    /// playback or start a duplicate generation request.
    func ensurePlaying() {
        guard requireWebContentReady() else { return }
        guard audio.sleepTimer.permitsAutomaticPlayback() else { return }
        guard resumeNotice == nil else { return }
        isPlaybackPausedByUser = false
        liveWebTurnIntentSuspended = false
        if case .error = status, currentParagraphIndex >= 0 {
            retryCurrentParagraph()
            return
        }
        if ownsAudioQueue, audio.isPlaying { return }
        if pendingPrefetchAdvanceFrom != nil {
            resumePendingParagraphAdvance()
            return
        }
        if presentElapsedGrowthWallIfNeeded(resumeAfterPurchase: { [weak self] in
            self?.ensurePlaying()
        }) {
            return
        }
        if currentParagraphIndex < 0 {
            start()
            return
        }
        if !ownsAudioQueue {
            guard currentAudioIsQuotaExempt
                    || pro.isPro
                    || quota.canStartListen(isPro: pro.isPro) else {
                refreshAccessThenRetryResume()
                return
            }
            beginAnalyticsReadSessionIfNeeded(resume: true)
            rebuildCurrentParagraphAfterOwnershipChange()
            return
        }
        guard currentAudioIsQuotaExempt
                || pro.isPro
                || quota.canStartListen(isPro: pro.isPro) else {
            refreshAccessThenRetryResume()
            return
        }
        invalidateAccessRetry()
        if audio.currentSegment != nil || audio.hasQueuedSegments
            || status.isLoading || status.isStreaming {
            beginAnalyticsReadSessionIfNeeded(resume: true)
            if let token = audioSessionToken {
                _ = audio.play(session: token)
            }
        } else if !isFinished {
            generate(currentParagraphIndex)
        }
    }

    func skipForward() {
        guard let token = audioSessionToken else { return }
        _ = audio.skipForward(seconds: 15, session: token)
    }

    func skipBackward() {
        guard let token = audioSessionToken else { return }
        _ = audio.skipBackward(seconds: 15, session: token)
    }

    private func rebuildCurrentParagraphAfterOwnershipChange() {
        guard isActive, currentParagraphIndex >= 0 else {
            start()
            return
        }
        guard let token = ensureAudioSessionClaim() else { return }
        let cached = segmentsByParagraph[currentParagraphIndex] ?? []
        switch ReadAloudOwnershipRecoveryPlan.resolve(
            isReady: status.isReady,
            cachedSegmentCount: cached.count
        ) {
        case .reloadCachedParagraph:
            generationEpoch &+= 1
            generationTask?.cancel()
            generationTask = nil
            resetLiveWebCarryPrewarmState()
            clearPrefetch()
            _ = audio.clearQueue(session: token)
            _ = audio.setMoreSegmentsExpected(false, session: token)
            if let cursor = pendingReadingAudioCursor {
                guard loadResumedReadingAudio(cached, cursor: cursor, isComplete: true,
                                              autoPlay: true, session: token) else { return }
            } else {
                guard audio.loadSegments(cached, autoPlay: true, session: token) else { return }
            }
            isFinished = false
            status = .ready
        case .regenerateParagraph:
            generate(currentParagraphIndex)
        }
    }

    /// 点击段落跳读。
    func jump(to paragraphIndex: Int) {
        guard requireWebContentReady() else { return }
        jump(to: paragraphIndex, allowAccessRefresh: true)
    }

    private func jump(to paragraphIndex: Int, allowAccessRefresh: Bool) {
        guard requireWebContentReady() else { return }
        guard readableIndices.contains(paragraphIndex) else { return }
        flushReadingProgress()
        pendingReadingAudioCursor = nil
        pendingResumeParagraphIndex = nil
        resumeNotice = nil
        guard document.sourceKind == .youtube
                || canStartAudio(persistentYouTubeCacheHit: false) else {
            if allowAccessRefresh {
                refreshAccessThenRetryJump(to: paragraphIndex)
                return
            }
            status = .pending
            showPaywall = true
            endAnalyticsReadSession(result: .blocked, reason: "listen_quota")
            return
        }
        invalidateAccessRetry()
        // 首次直接点击句子跳读（未经 start）→ 必须补激活：否则 audio.onPlaybackComplete 未挂，读完一句不 advance
        //（“只读一句就停、没看到加载下一句”），且 isActive=false 时 onTick 直接 return（无高亮、不计额度）。
        // activate 幂等；已 start 过再点句重复设回调/setBook 无害。
        if !isActive {
            activate()
            applyPlaybackMetadata()
            applySpeed()
        }
        if document.sourceKind == .youtube,
           currentParagraphIndex >= 0,
           currentParagraphIndex != paragraphIndex {
            saveYouTubeProgress(
                audio.currentTime,
                force: true,
                waitForPersistence: false
            )
        }
        beginAnalyticsReadSessionIfNeeded(resume: currentParagraphIndex >= 0)
        generate(
            paragraphIndex,
            allowAccessRefresh: allowAccessRefresh
        )
    }

    /// 用外部已经生成好的首段音频启动朗读。Kindle 页级预加载会使用这个入口：
    /// 页面 OCR/文档和下一页首段 TTS 都提前完成时，翻页后无需再等首字节。
    func startWithPrefetchedSegments(_ segments: [AudioSegment], paragraphIndex: Int) {
        startWithPrefetchedSegments(
            segments,
            paragraphIndex: paragraphIndex,
            allowAccessRefresh: true
        )
    }

    /// Starts a locally cached YouTube paragraph at its persisted stable
    /// segment/fraction without emitting a short burst from the segment start.
    /// Persistent YouTube replay is quota-exempt; fresh audio remains on the
    /// normal daily listen meter.
    func startWithCachedSegments(
        _ segments: [AudioSegment],
        paragraphIndex: Int,
        segmentID: String?,
        progress: Double,
        isReplayEligible: Bool,
        autoplay: Bool = true
    ) {
        startWithPrefetchedSegments(
            segments,
            paragraphIndex: paragraphIndex,
            allowAccessRefresh: true,
            initialSegmentID: segmentID,
            initialProgress: progress,
            autoplay: autoplay,
            persistentYouTubeCacheHit: isReplayEligible
        )
    }

    /// A route can reuse an existing reader VM. Reset its one-shot playback
    /// confirmation so the enclosing share flow can wait for real audio rather
    /// than treating transcript extraction as listening success.
    func prepareForYouTubePlaybackAcceptanceSignal() {
        guard document.sourceKind == .youtube else { return }
        lastYouTubePlaybackSignalSegmentID = ""
    }

    private func startWithPrefetchedSegments(
        _ segments: [AudioSegment],
        paragraphIndex: Int,
        allowAccessRefresh: Bool,
        initialSegmentID: String? = nil,
        initialProgress: Double = 0,
        autoplay: Bool = true,
        persistentYouTubeCacheHit: Bool = false
    ) {
        guard resumeNotice == nil else { return }
        if let restored = pendingResumeParagraphIndex, restored != paragraphIndex {
            start()
            return
        }
        guard readableIndices.contains(paragraphIndex), !segments.isEmpty else {
            jump(to: paragraphIndex)
            return
        }
        flushReadingProgress()
        if presentElapsedGrowthWallIfNeeded(resumeAfterPurchase: { [weak self] in
            self?.startWithPrefetchedSegments(
                segments,
                paragraphIndex: paragraphIndex,
                allowAccessRefresh: true,
                initialSegmentID: initialSegmentID,
                initialProgress: initialProgress,
                autoplay: autoplay,
                persistentYouTubeCacheHit: persistentYouTubeCacheHit
            )
        }) {
            return
        }
        guard canStartAudio(
            persistentYouTubeCacheHit: persistentYouTubeCacheHit
        ) else {
            if allowAccessRefresh {
                refreshAccessThenRetryPrefetched(
                    segments,
                    paragraphIndex: paragraphIndex,
                    initialSegmentID: initialSegmentID,
                    initialProgress: initialProgress,
                    autoplay: autoplay,
                    persistentYouTubeCacheHit: persistentYouTubeCacheHit
                )
                return
            }
            status = .pending
            showPaywall = true
            endAnalyticsReadSession(result: .blocked, reason: "listen_quota")
            return
        }

        invalidateAccessRetry()
        beginAnalyticsReadSessionIfNeeded(
            resume: currentParagraphIndex >= 0 || initialProgress > 0
        )
        activate()
        guard let token = ensureAudioSessionClaim() else { return }
        applyPlaybackMetadata()
        applySpeed()
        playbackVoiceID = settings.voice(for: docLanguage)
        isFinished = false
        generationEpoch &+= 1
        generationTask?.cancel()
        resetLiveWebCarryPrewarmState()
        clearPrefetch()

        hasObservedReadingPlayback = false
        _ = audio.clearQueue(session: token)
        _ = audio.setMoreSegmentsExpected(false, session: token)
        setYouTubeAudioQuotaOrigin(
            paragraphIndex: paragraphIndex,
            persistentCacheHit: persistentYouTubeCacheHit
        )
        retainYouTubeAudioMemory(for: paragraphIndex)
        segmentsByParagraph[paragraphIndex] = segments
        youtubeCompletionSubmittedParagraph = nil
        currentParagraphIndex = paragraphIndex
        processedDisplayText = segments.map { $0.text }.joined()
        highlightRange = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        pdfHighlight = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        status = .ready
        if document.sourceKind.isWebRendered { webAudioSegments.append(contentsOf: segments) }
        let shouldAutoplay = autoplay && !liveWebTurnIntentSuspended
        pendingResumeParagraphIndex = nil
        if let cursor = pendingReadingAudioCursor {
            guard loadResumedReadingAudio(segments, cursor: cursor, isComplete: true,
                                          autoPlay: shouldAutoplay, session: token) else { return }
        } else if let requestedID = initialSegmentID,
           segments.contains(where: { $0.id == requestedID }) {
            let loaded = audio.loadSegments(
                segments,
                autoPlay: false,
                session: token
            )
            if loaded {
                let didStart = audio.startQueuedSegment(
                    id: requestedID,
                    progress: initialProgress,
                    autoPlay: shouldAutoplay,
                    session: token
                )
                if didStart,
                   let requested = segments.first(where: { $0.id == requestedID }) {
                    let initialPosition = max(
                        0,
                        requested.duration * min(0.98, max(0, initialProgress))
                    )
                    if YouTubePersistentAudioQuotaPolicy.shouldAccount(
                        sourceKind: document.sourceKind,
                        persistentCacheHit: persistentYouTubeCacheHit
                    ) {
                        primeListenAccounting(
                            segmentID: requestedID,
                            position: initialPosition
                        )
                    } else {
                        // Flush any prior billable segment, but never seed the
                        // listen meter from a quota-exempt persisted replay.
                        commitListen()
                    }
                    analyticsSessionCoordinator.seedPlaybackCursor(
                        ownerID: analyticsSessionOwnerID,
                        segmentID: requestedID,
                        position: initialPosition
                    )
                }
            }
        } else {
            _ = audio.loadSegments(
                segments,
                autoPlay: shouldAutoplay,
                session: token
            )
        }

        preloadNext(after: paragraphIndex)
    }

    private func refreshAccessThenRetryStart() {
        status = .loading
        invalidateAccessRetry()
        let retryEpoch = accessRetryEpoch
        accessRetryTask = Task { [weak self] in
            await ProManager.shared.refresh()
            guard let self,
                  !Task.isCancelled,
                  self.accessRetryEpoch == retryEpoch else { return }
            self.accessRetryTask = nil
            self.start(allowAccessRefresh: false)
        }
    }

    private func refreshAccessThenRetryResume() {
        invalidateAccessRetry()
        let retryEpoch = accessRetryEpoch
        let paragraphIndex = currentParagraphIndex
        let epoch = generationEpoch
        let session = audioSessionToken
        accessRetryTask = Task { [weak self] in
            await ProManager.shared.refresh()
            guard let self,
                  !Task.isCancelled,
                  self.accessRetryEpoch == retryEpoch,
                  self.isActive,
                  self.currentParagraphIndex == paragraphIndex,
                  self.generationEpoch == epoch,
                  self.audioSessionToken == session else { return }
            self.accessRetryTask = nil
            if self.currentAudioIsQuotaExempt
                || self.pro.isPro
                || self.quota.canStartListen(isPro: self.pro.isPro) {
                self.beginAnalyticsReadSessionIfNeeded(resume: true)
                if case .error = self.status {
                    self.retryCurrentParagraph()
                    return
                }
                if self.pendingPrefetchAdvanceFrom != nil {
                    self.resumePendingParagraphAdvance()
                    return
                }
                // This is a retry of an explicit Resume action. `play()` is
                // idempotent; toggle could pause audio started by a newer event.
                if self.ownsAudioQueue, let token = self.audioSessionToken {
                    _ = self.audio.play(session: token)
                } else {
                    self.rebuildCurrentParagraphAfterOwnershipChange()
                }
            } else {
                self.showPaywall = true
                self.endAnalyticsReadSession(
                    result: .blocked,
                    reason: "listen_quota"
                )
            }
        }
    }

    private func refreshAccessThenRetryJump(to paragraphIndex: Int) {
        status = .loading
        invalidateAccessRetry()
        let retryEpoch = accessRetryEpoch
        accessRetryTask = Task { [weak self] in
            await ProManager.shared.refresh()
            guard let self,
                  !Task.isCancelled,
                  self.accessRetryEpoch == retryEpoch else { return }
            self.accessRetryTask = nil
            self.jump(to: paragraphIndex, allowAccessRefresh: false)
        }
    }

    private func refreshAccessThenRetryPrefetched(
        _ segments: [AudioSegment],
        paragraphIndex: Int,
        initialSegmentID: String? = nil,
        initialProgress: Double = 0,
        autoplay: Bool = true,
        persistentYouTubeCacheHit: Bool = false
    ) {
        status = .loading
        invalidateAccessRetry()
        let retryEpoch = accessRetryEpoch
        accessRetryTask = Task { [weak self] in
            await ProManager.shared.refresh()
            guard let self,
                  !Task.isCancelled,
                  self.accessRetryEpoch == retryEpoch else { return }
            self.accessRetryTask = nil
            self.startWithPrefetchedSegments(
                segments,
                paragraphIndex: paragraphIndex,
                allowAccessRefresh: false,
                initialSegmentID: initialSegmentID,
                initialProgress: initialProgress,
                autoplay: autoplay,
                persistentYouTubeCacheHit: persistentYouTubeCacheHit
            )
        }
    }

    func setSpeed(_ s: Double) {
        settings.speed = s   // 触发 applySpeed 经由订阅
    }

    private func applySpeed() {
        audio.setPlaybackRate(Float(settings.effectiveSpeed(isPro: pro.isPro)))
        if document.sourceKind == .kindle, currentParagraphIndex >= 0 {
            preloadNext(after: currentParagraphIndex)
        }
    }

    /// Stops playback synchronously and returns the final YouTube persistence
    /// fence. Callers that own a lifecycle boundary may await the task; legacy
    /// UI call sites can safely ignore it because the VM retains the lane tail.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        cancelReadablePagePreparation()
        flushReadingProgress()
        retainReadingCursorForQueueRebuild()
        if !isFinished,
           youtubeCompletionSubmittedParagraph != currentParagraphIndex {
            saveYouTubeProgress(
                audio.currentTime,
                force: true,
                waitForPersistence: false
            )
        } else if document.sourceKind == .youtube {
            persistYouTubeHistorySummary(
                paragraphFraction: 1,
                now: Date(),
                force: true
            )
        }
        invalidateAccessRetry()
        generationEpoch &+= 1
        liveWebTurnIntentSuspended = false
        generationTask?.cancel()
        generationTask = nil
        resetLiveWebCarryPrewarmState()
        listenCapRefreshTask?.cancel()
        listenCapRefreshTask = nil
        clearPrefetch()
        cloneRequestIDs.removeAll(keepingCapacity: false)
        isAwaitingLiveWebCarryCompletion = false
        pendingLiveWebCarryStartIndex = nil
        if let token = audioSessionToken {
            _ = audio.setMoreSegmentsExpected(false, session: token)
            _ = audio.clearBook(session: token)
        }
        YouTubeAudioMemoryWindow.prune(
            &segmentsByParagraph,
            sourceKind: document.sourceKind,
            keeping: nil
        )
        if document.sourceKind == .youtube {
            youtubeQuotaExemptParagraphs.removeAll(keepingCapacity: false)
        }
        status = .pending
        if let switchID = activeVoiceSwitchID {
            VoiceSwitchStatusCenter.shared.finish(switchID)
            activeVoiceSwitchID = nil
        }
        commitListen()
        endAnalyticsReadSession(result: .cancelled, reason: "closed")
        return document.sourceKind == .youtube
            ? waitForYouTubePersistence()
            : nil
    }

    /// Final lifecycle checkpoint for app backgrounding. Unlike the periodic
    /// cadence, this waits inside the persistence lane and also commits any
    /// deferred cache LRU touches before iOS suspends the process.
    @discardableResult
    func flushYouTubeProgressForLifecycle() -> Task<Void, Never>? {
        guard document.sourceKind == .youtube else { return nil }
        if isFinished {
            persistYouTubeHistorySummary(
                paragraphFraction: 1,
                now: Date(),
                force: true
            )
        } else {
            saveYouTubeProgress(
                audio.currentTime,
                force: true,
                waitForPersistence: false
            )
        }
        return waitForYouTubePersistence()
    }

    // MARK: - Generation

    private var includeVoiceCodeForTTS: Bool {
        YouTubeTTSRequestPolicy.includeVoiceCode(
            sourceKind: document.sourceKind,
            language: docLanguage
        )
    }

    private func setYouTubeAudioQuotaOrigin(
        paragraphIndex: Int,
        persistentCacheHit: Bool
    ) {
        guard document.sourceKind == .youtube else { return }
        if YouTubePersistentAudioQuotaPolicy.isQuotaExempt(
            sourceKind: document.sourceKind,
            persistentCacheHit: persistentCacheHit
        ) {
            youtubeQuotaExemptParagraphs.insert(paragraphIndex)
        } else {
            youtubeQuotaExemptParagraphs.remove(paragraphIndex)
        }
    }

    private func retainYouTubeAudioMemory(for paragraphIndex: Int) {
        YouTubeAudioMemoryWindow.prune(
            &segmentsByParagraph,
            sourceKind: document.sourceKind,
            keeping: paragraphIndex
        )
        guard document.sourceKind == .youtube else { return }
        youtubeQuotaExemptParagraphs.formIntersection([paragraphIndex])
    }

    private func isYouTubeAudioQuotaExempt(paragraphIndex: Int) -> Bool {
        YouTubePersistentAudioQuotaPolicy.isQuotaExempt(
            sourceKind: document.sourceKind,
            persistentCacheHit: youtubeQuotaExemptParagraphs.contains(paragraphIndex)
        )
    }

    private var currentAudioIsQuotaExempt: Bool {
        guard currentParagraphIndex >= 0 else { return false }
        return isYouTubeAudioQuotaExempt(paragraphIndex: currentParagraphIndex)
    }

    /// Once the five-minute wall has reached a real paragraph boundary, every
    /// explicit continuation stays fail-closed independently of a stale quota
    /// mirror. Before that first boundary, pausing at 300 seconds may still
    /// resume so the current paragraph can finish.
    private func presentElapsedGrowthWallIfNeeded(
        resumeAfterPurchase: @escaping () -> Void
    ) -> Bool {
        guard GrowthLoopConversionCoordinator.shared.reclaimHardWallOnUserContinue(
            document: document,
            resumeAfterPurchase: resumeAfterPurchase
        ) else { return false }
        if let token = audioSessionToken {
            _ = audio.pause(session: token)
        }
        status = .ready
        endAnalyticsReadSession(
            result: .blocked,
            reason: "growth_first_value_preview"
        )
        return true
    }

    private func canStartAudio(persistentYouTubeCacheHit: Bool) -> Bool {
        YouTubePersistentAudioQuotaPolicy.canStart(
            sourceKind: document.sourceKind,
            persistentCacheHit: persistentYouTubeCacheHit,
            isPro: pro.isPro,
            hasListenQuota: quota.canStartListen(isPro: pro.isPro)
        )
    }

    /// A YouTube cache lookup must happen before the quota decision. This keeps
    /// persistent replay available offline/after the daily allowance is spent,
    /// while a cache miss still refreshes entitlement and blocks fresh TTS.
    private func authorizeFreshYouTubeGeneration(
        paragraphIndex: Int,
        epoch: UInt64,
        session: AudioPlaybackSessionToken,
        allowAccessRefresh: Bool
    ) async -> Bool {
        guard document.sourceKind == .youtube else { return true }
        if canStartAudio(persistentYouTubeCacheHit: false) { return true }

        if allowAccessRefresh {
            await ProManager.shared.refresh()
            guard !Task.isCancelled,
                  generationEpoch == epoch,
                  currentParagraphIndex == paragraphIndex,
                  audioSessionToken == session,
                  audio.isPlaybackSessionActive(session) else { return false }
            if canStartAudio(persistentYouTubeCacheHit: false) { return true }
        }

        guard generationEpoch == epoch,
              currentParagraphIndex == paragraphIndex,
              audioSessionToken == session,
              audio.isPlaybackSessionActive(session) else { return false }
        _ = audio.setMoreSegmentsExpected(false, session: session)
        status = .pending
        showPaywall = true
        endAnalyticsReadSession(result: .blocked, reason: "listen_quota")
        return false
    }

    private func retryCurrentParagraph() {
        guard isActive, currentParagraphIndex >= 0 else { return }
        guard canStartAudio(persistentYouTubeCacheHit: currentAudioIsQuotaExempt) else {
            refreshAccessThenRetryResume()
            return
        }
        let continuation = paragraphContinuation.flatMap { saved -> TTSContinuation? in
            guard ownsAudioQueue,
                  !audio.hasTerminalPlaybackFailure,
                  saved.paragraphIndex == currentParagraphIndex,
                  saved.voice == settings.voice(for: docLanguage),
                  saved.language == docLanguage,
                  saved.checkpoint.nextSegmentIndex > 0 else { return nil }
            return saved.checkpoint
        }
        generate(currentParagraphIndex, continuation: continuation)
    }

    private func resumePendingParagraphAdvance() {
        guard ownsAudioQueue, let token = audioSessionToken else { return }
        if presentElapsedGrowthWallIfNeeded(resumeAfterPurchase: { [weak self] in
            self?.resumePendingParagraphAdvance()
        }) { return }
        guard canStartAudio(persistentYouTubeCacheHit: currentAudioIsQuotaExempt) else {
            refreshAccessThenRetryResume()
            return
        }
        if accessRetryTask != nil {
            // Record an explicit Resume without outrunning the authoritative
            // refresh. This queue has drained, so play cannot replay its prefix.
            _ = audio.play(session: token)
            return
        }
        invalidateAccessRetry()
        _ = audio.play(session: token) // drained item only records resume intent
        if prefetchPromotionTask == nil {
            pendingPrefetchAdvanceFrom = nil
            advance()
        }
    }

    private func generate(
        _ index: Int,
        voiceOverride: String? = nil,
        autoPlay: Bool = true,
        voiceSwitchID: UUID? = nil,
        allowAccessRefresh: Bool = true,
        continuation: TTSContinuation? = nil
    ) {
        guard resumeNotice == nil, isActive, paras.indices.contains(index) else {
            finishVoiceSwitch(voiceSwitchID)
            return
        }
        epubNavigationParagraphIndex = nil
        flushReadingProgress()
        if index != currentParagraphIndex {
            pendingReadingAudioCursor = nil
            pendingResumeParagraphIndex = nil
        } else if voiceOverride != nil {
            retainReadingCursorForQueueRebuild()
        }
        if presentElapsedGrowthWallIfNeeded(resumeAfterPurchase: { [weak self] in
            self?.generate(
                index,
                voiceOverride: voiceOverride,
                autoPlay: autoPlay,
                voiceSwitchID: voiceSwitchID,
                allowAccessRefresh: true
            )
        }) {
            finishVoiceSwitch(voiceSwitchID)
            return
        }
        guard let session = ensureAudioSessionClaim() else {
            finishVoiceSwitch(voiceSwitchID)
            return
        }
        if document.sourceKind == .youtube {
            // A manual jump or voice switch can replace the player before its
            // next tick. Commit the previous fresh paragraph now so the cache-
            // miss authorization below observes the true remaining quota.
            // Persisted replay never enters the listen accumulator.
            commitListen()
        }
        let suffixPlan = voiceOverride.flatMap { _ in
            pendingReadingAudioCursor.flatMap { cursor in
                ReadingResumeContract.speechSuffixPlan(
                    source: paras[index].resolvedSpeechText,
                    segments: segmentsByParagraph[index] ?? [], cursor: cursor)
            }
        }
        invalidateAccessRetry()
        isAwaitingLiveWebCarryCompletion = false
        pendingLiveWebCarryStartIndex = nil
        generationEpoch &+= 1
        let epoch = generationEpoch
        let voice = voiceOverride ?? settings.voice(for: docLanguage)
        let cloneRequestID = stableCloneRequestID(
            paragraphIndex: index,
            voice: voice
        )
        if pendingLiveWebResume?.paragraphIndex != index { pendingLiveWebResume = nil }
        playbackVoiceID = voice
        NSLog("CRDBG generate para=%d lang=%@ voice=%@ epoch=%llu web=%@", index, docLanguage, voice, epoch, document.sourceKind.isWebRendered ? "Y" : "N")
        ReaderRunLog.write(
            "READ generate start para=\(index) epoch=\(epoch) " +
            "chars=\(paras[index].text.utf16.count)"
        )
        isFinished = false   // 开始播放某段 → 未完成
        didSignalPageBoundaryApproaching = false
        generationTask?.cancel()
        resetLiveWebCarryPrewarmState()
        clearPrefetch()   // 重新生成某段 → 作废旧预取

        if continuation == nil {
            hasObservedReadingPlayback = false
            paragraphContinuation = nil
            _ = audio.clearQueue(session: session)
        }
        _ = audio.setMoreSegmentsExpected(true, session: session)
        if !autoPlay { _ = audio.pause(session: session) }
        if continuation != nil, autoPlay { _ = audio.play(session: session) }
        setYouTubeAudioQuotaOrigin(
            paragraphIndex: index,
            persistentCacheHit: false
        )
        retainYouTubeAudioMemory(for: index)
        if continuation == nil { segmentsByParagraph[index] = suffixPlan?.prefix ?? [] }
        youtubeCompletionSubmittedParagraph = nil
        currentParagraphIndex = index
        processedDisplayText = segmentsByParagraph[index]?.map(\.text).joined()
        highlightRange = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        pdfHighlight = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        status = .loading

        if voiceOverride != nil, progressBoundaryToken == historyStore.progressBoundaryToken,
           accountBoundaryToken.map(AccountContentIsolation.isCurrent) ?? true,
           let cursor = pendingReadingAudioCursor,
           let cached = completedVoiceAudio.first(where: { $0.key == voiceAudioKey(index, voice: voice) })?.segments,
           case let .seek(position, _) = ReadingResumeContract.resolveAudio(cursor, segments: cached, isComplete: true),
           cached.indices.contains(position), !cached[position].audioData.isEmpty {
            segmentsByParagraph[index] = cached
            processedDisplayText = cached.map(\.text).joined()
            if loadResumedReadingAudio(cached, cursor: cursor, isComplete: true, autoPlay: autoPlay, session: session) {
                _ = finishGeneratedAudio(paragraph: index, epoch: epoch, session: session)
                finishVoiceSwitch(voiceSwitchID)
                ReaderRunLog.write("READ voice switch cache-hit para=\(index)")
                preloadNext(after: index)
                return
            }
            finishVoiceSwitch(voiceSwitchID)
            return
        }
        let requestedText = suffixPlan?.text ?? paras[index].resolvedSpeechText
        let effectiveContinuation = continuation ?? suffixPlan.map {
            TTSContinuation(requestUnits: ClonedTTSStartup.requestUnits(
                SpeechTextSanitizer.sanitizedForTTS($0.text), language: docLanguage, voice: voice),
                nextSegmentIndex: $0.nextSegmentIndex)
        }
        if let suffixPlan {
            ReaderRunLog.write("READ voice switch suffix para=\(index) skippedChars=\(suffixPlan.prefix.map(\.text).joined().utf16.count) requestChars=\(requestedText.utf16.count)")
        }
        let para = paras[index]
        let demand = SpeechStreamBuffer(paragraphIndex: index, voice: voice,
            language: docLanguage, requestID: cloneRequestID)
        demand.promoted = true
        demand.segments = (segmentsByParagraph[index] ?? []).filter { !$0.audioData.isEmpty }
        foregroundStream = demand
        generationTask = Task { [weak self] in
            guard let self = self else { return }
            // Includes failed alignment, authorization, cancellation and stale
            // completion. Matching IDs prevent an old task clearing a new switch.
            defer { self.finishVoiceSwitch(voiceSwitchID) }
            do {
                try Task.checkCancellation()
                guard await self.authorizeFreshYouTubeGeneration(
                    paragraphIndex: index,
                    epoch: epoch,
                    session: session,
                    allowAccessRefresh: allowAccessRefresh
                ) else { return }
                NSLog("CRDBG generate request begin para=%d voice=%@ epoch=%llu", index, voice, epoch)
                try await self.speechGenerator.generateBufferedSpeech(
                    paragraphIndex: index,
                    text: SpeechTextSanitizer.sanitizedForTTS(
                        requestedText
                    ),
                    voice: voice,
                    speed: 1.0,                       // 1.0 生成，播放用 playbackRate
                    language: self.docLanguage,
                    includeVoiceCode: self.includeVoiceCodeForTTS,
                    speaker: para.speaker,
                    cloneRequestID: cloneRequestID,
                    continuation: effectiveContinuation,
                    beforeRequest: { [weak self] checkpoint in
                        guard let self else { throw CancellationError() }
                        while true {
                            try Task.checkCancellation()
                            guard self.isActive, self.generationEpoch == epoch,
                                  self.currentParagraphIndex == index,
                                  self.audioSessionToken == session,
                                  self.audio.isPlaybackSessionActive(session) else { throw CancellationError() }
                            self.paragraphContinuation = ParagraphContinuation(paragraphIndex: index,
                                voice: voice, language: self.docLanguage, checkpoint: checkpoint)
                            let needsResume = self.pendingReadingAudioCursor != nil
                            let canGenerate = demand.canRequest(currentSegmentID: self.audio.currentSegment?.id,
                                position: self.audio.playbackPosition, rate: Double(self.audio.playbackRate),
                                paused: (self.audio.isExplicitlyPaused || self.isPlaybackPausedByUser) && !needsResume)
                            if canGenerate || needsResume || (demand.segments.isEmpty && !autoPlay) {
                                demand.beginRequest(checkpoint)
                                return .interactive
                            }
                            if !self.audio.isExplicitlyPaused { self.preloadNext(after: index) }
                            try await Task.sleep(nanoseconds: 75_000_000)
                        }
                    }, onSegmentReady: { [weak self] segment in
                    demand.append(segment)
                    self?.appendSegment(
                        segment,
                        paragraph: index,
                        epoch: epoch,
                        session: session,
                        autoPlay: autoPlay,
                        voiceSwitchID: voiceSwitchID
                    )
                })
                await MainActor.run {
                    guard self.generationEpoch == epoch,
                          self.currentParagraphIndex == index,
                          self.audioSessionToken == session,
                          self.audio.isPlaybackSessionActive(session) else { return }
                    if let cursor = self.pendingReadingAudioCursor {
                        guard self.loadResumedReadingAudio(
                            self.segmentsByParagraph[index] ?? [], cursor: cursor,
                            isComplete: true, autoPlay: autoPlay && !self.liveWebTurnIntentSuspended && !self.audio.isExplicitlyPaused,
                            session: session
                        ) else { return }
                    }
                    demand.finished = true
                    guard self.finishGeneratedAudio(paragraph: index, epoch: epoch, session: session) else { return }
                    self.completeCloneRequestID(matching: cloneRequestID)
                    let generatedCount =
                        self.segmentsByParagraph[index]?.count ?? 0
                    ReaderRunLog.write(
                        "READ generate done para=\(index) epoch=\(epoch) " +
                        "segs=\(generatedCount)"
                    )
                    if generatedCount == 0 {
                        ReaderRunLog.write(
                            "READ generate empty para=\(index); skip to next"
                        )
                        DispatchQueue.main.async { [weak self] in
                            guard let self,
                                  self.generationEpoch == epoch,
                                  self.currentParagraphIndex == index,
                                  self.ownsAudioQueue else { return }
                            self.advance()
                        }
                    }
                    self.finishVoiceSwitch(voiceSwitchID)
                }
                if self.generationEpoch == epoch,
                   self.currentParagraphIndex == index,
                   self.audioSessionToken == session,
                   self.audio.isPlaybackSessionActive(session),
                   self.isActive, self.resumeNotice == nil {
                    // Audio remains session-only; keep one paragraph prefetched
                    // in memory and never hand the generated MP3 Data to the
                    // persistent transcript/artwork cache actor.
                    self.preloadNext(after: index)
                }
            } catch is CancellationError {
                ReaderRunLog.write(
                    "READ generate cancelled para=\(index) epoch=\(epoch)"
                )
                self.finishCancelledGenerationIfCurrent(
                    epoch: epoch,
                    session: session,
                    voiceSwitchID: voiceSwitchID
                )
            } catch TTSError.cancelled {
                NSLog("CRDBG generate request cancelled para=%d epoch=%llu", index, epoch)
                ReaderRunLog.write(
                    "READ generate cancelled para=\(index) epoch=\(epoch) source=tts"
                )
                self.finishCancelledGenerationIfCurrent(
                    epoch: epoch,
                    session: session,
                    voiceSwitchID: voiceSwitchID
                )
            } catch {
                await MainActor.run {
                    guard self.generationEpoch == epoch,
                          self.audioSessionToken == session,
                          self.audio.isPlaybackSessionActive(session) else { return }
                    let hasPrefix = self.pendingReadingAudioCursor == nil
                        && (self.audio.hasQueuedSegments || self.audio.currentSegment != nil)
                    _ = self.audio.setMoreSegmentsExpected(hasPrefix, session: session)
                    if self.currentParagraphIndex == index {
                        ReaderRunLog.write(
                            "READ generate failed para=\(index) epoch=\(epoch) " +
                            "error=\(error.localizedDescription)"
                        )
                        self.status = .error(error.localizedDescription)
                        self.finishVoiceSwitch(voiceSwitchID)
                        self.endAnalyticsReadSession(
                            result: .failed,
                            reason: "tts_failed",
                            errorStage: "tts",
                            errorCode: Self.analyticsErrorCode(error)
                        )
                    }
                }
            }
        }
    }

    /// Shared completion boundary also exercised with an offline producer in
    /// regression tests. A player failure invalidates this producer's epoch.
    @discardableResult
    func finishGeneratedAudio(paragraph: Int, epoch: UInt64, session: AudioPlaybackSessionToken) -> Bool {
        guard generationEpoch == epoch, currentParagraphIndex == paragraph,
              audioSessionToken == session, audio.isPlaybackSessionActive(session),
              !audio.hasTerminalPlaybackFailure else { return false }
        finishPendingLiveWebResumeIfNeeded(paragraph: paragraph, session: session)
        guard generationEpoch == epoch, !audio.hasTerminalPlaybackFailure,
              audio.finishStreamingProducer(session: session) else { return false }
        paragraphContinuation = nil
        status = .ready
        cacheCompletedVoiceAudio(paragraph)
        return true
    }

    private func voiceAudioKey(_ paragraph: Int, voice: String) -> String {
        "\(resumeDocumentIndex.fingerprint)|\(paragraph)|\(voice)|\(docLanguage)"
    }

    private func cacheCompletedVoiceAudio(_ paragraph: Int) {
        guard progressBoundaryToken == historyStore.progressBoundaryToken,
              accountBoundaryToken.map(AccountContentIsolation.isCurrent) ?? true,
              let segments = segmentsByParagraph[paragraph], !segments.isEmpty else { return }
        let key = voiceAudioKey(paragraph, voice: playbackVoiceID)
        completedVoiceAudio.removeAll { $0.key == key }
        completedVoiceAudio.append((key, segments))
        while completedVoiceAudio.count > 3 || completedVoiceAudio.reduce(0, { total, entry in
            total + entry.segments.reduce(0) { $0 + $1.audioData.count }
        }) > 8 * 1024 * 1024 {
            completedVoiceAudio.removeFirst()
        }
    }

    func appendSegment(
        _ segment: AudioSegment,
        paragraph: Int,
        epoch: UInt64,
        session: AudioPlaybackSessionToken,
        autoPlay: Bool,
        voiceSwitchID: UUID?
    ) {
        guard epoch == generationEpoch,
              paragraph == currentParagraphIndex,
              audioSessionToken == session,
              audio.isPlaybackSessionActive(session) else {
            NSLog("CRDBG drop stale TTS segment para=%d epoch=%llu current=%llu", paragraph, epoch, generationEpoch)
            return
        }
        segmentsByParagraph[paragraph, default: []].append(segment)
        let segs = segmentsByParagraph[paragraph] ?? []
        ReaderRunLog.write(
            "READ segment ready para=\(paragraph) seg=\(segment.segmentIndex) " +
            "count=\(segs.count) duration=\(String(format: "%.2f", segment.duration))"
        )
        processedDisplayText = segs.map { $0.text }.joined()
        if document.sourceKind.isWebRendered { webAudioSegments.append(segment) }
        let shouldAutoPlay = autoPlay && !liveWebTurnIntentSuspended
            && !audio.isExplicitlyPaused
        if let cursor = pendingReadingAudioCursor {
            if loadResumedReadingAudio(segs, cursor: cursor, isComplete: false,
                                       autoPlay: shouldAutoPlay, session: session) {
                status = .streaming
                finishVoiceSwitch(voiceSwitchID)
            } else if case .error = status {
                finishVoiceSwitch(voiceSwitchID)
            } else if !audio.hasTerminalPlaybackFailure, resumeNotice == nil {
                status = .streaming
            }
            return
        } else if let pending = pendingLiveWebResume,
           pending.paragraphIndex == paragraph {
            guard WeReadPlaybackResumeContract.segmentMatches(segment.text, anchor: pending.anchor) else {
                status = .streaming
                return
            }
            pendingLiveWebResume = nil
            let loaded = audio.loadSegment(
                segment,
                autoPlay: false,
                session: session
            )
            let started = loaded && audio.startQueuedSegment(
                id: segment.id,
                progress: pending.anchor.segmentProgress,
                autoPlay: shouldAutoPlay && pending.anchor.wasPlaying,
                session: session
            )
            guard loaded, started else {
                ReaderRunLog.write(
                    "READ segment rejected para=\(paragraph) seg=\(segment.segmentIndex) " +
                    "path=resume loaded=\(loaded ? "Y" : "N") " +
                    "started=\(started ? "Y" : "N")"
                )
                _ = audio.setMoreSegmentsExpected(false, session: session)
                status = .error(AppLocalized("音频队列已中断，请重试"))
                return
            }
            ReaderRunLog.write(
                "WEREAD playback restored para=\(paragraph) seg=\(segment.segmentIndex) progress=\(String(format: "%.3f", pending.anchor.segmentProgress)) playing=\(shouldAutoPlay && pending.anchor.wasPlaying ? "Y" : "N")"
            )
        } else {
            let loaded = audio.loadSegment(
                segment,
                autoPlay: shouldAutoPlay,
                session: session
            )
            guard loaded else {
                ReaderRunLog.write(
                    "READ segment rejected para=\(paragraph) seg=\(segment.segmentIndex) " +
                    "path=normal"
                )
                _ = audio.setMoreSegmentsExpected(false, session: session)
                status = .error(AppLocalized("音频队列已中断，请重试"))
                return
            }
        }
        guard epoch == generationEpoch, !audio.hasTerminalPlaybackFailure else { return }
        status = .streaming
        if document.sourceKind == .kindle, !VoiceOption.requiresGenerationQuota(playbackVoiceID) {
            preloadNext(after: paragraph)
        }
        // The clone worker is intentionally single-flight on one GPU. Starting
        // the next paragraph after only the first segment makes prefetch race
        // the foreground producer for the rest of this paragraph. `generate`
        // starts prefetch immediately after the foreground request completes,
        // preserving audible lead time without manufacturing concurrent GPU
        // requests from one reader session.
        finishVoiceSwitch(voiceSwitchID)
    }

    private func finishPendingLiveWebResumeIfNeeded(
        paragraph: Int,
        session: AudioPlaybackSessionToken
    ) {
        guard let pending = pendingLiveWebResume,
              pending.paragraphIndex == paragraph else { return }
        pendingLiveWebResume = nil
        let segments = segmentsByParagraph[paragraph] ?? []
        guard !segments.isEmpty else { return }
        for segment in segments {
            audio.loadSegment(
                segment,
                autoPlay: pending.anchor.wasPlaying && !liveWebTurnIntentSuspended,
                session: session
            )
        }
        ReaderRunLog.write(
            "WEREAD playback anchor fallback para=\(paragraph) segs=\(segments.count)"
        )
    }

    private func finishVoiceSwitch(_ id: UUID?) {
        guard let id, activeVoiceSwitchID == id else { return }
        VoiceSwitchStatusCenter.shared.finish(id)
        activeVoiceSwitchID = nil
        ReaderRunLog.write("READ voice switch finished para=\(currentParagraphIndex)")
    }

    private func finishCancelledGenerationIfCurrent(
        epoch: UInt64,
        session: AudioPlaybackSessionToken,
        voiceSwitchID: UUID?
    ) {
        guard generationEpoch == epoch,
              audioSessionToken == session,
              audio.isPlaybackSessionActive(session) else { return }
        _ = audio.setMoreSegmentsExpected(false, session: session)
        status = ownsAudioQueue && (audio.hasQueuedSegments || audio.currentSegment != nil)
            ? .ready
            : .pending
        finishVoiceSwitch(voiceSwitchID)
    }

    private func handleVoicePreferenceChanged(forceRestart: Bool = false) {
        let newVoiceID = settings.voice(for: docLanguage)
        guard forceRestart || newVoiceID != playbackVoiceID else { return }
        let oldVoiceID = playbackVoiceID
        playbackVoiceID = newVoiceID

        // A deactivated reader can still hold a ready paragraph from the old
        // narrator. Ownership recovery must regenerate it, not relabel/replay it.
        let hasCurrentSession = audioSessionToken.map { audio.isPlaybackSessionActive($0) } == true
        if !isActive || !hasCurrentSession {
            // A retained reader may still be marked active after another
            // document claimed the player. Preference broadcasts must never
            // let that old reader reclaim the current document's queue.
            if isActive { deactivate() }
            segmentsByParagraph.removeAll(keepingCapacity: false)
            paragraphContinuation = nil
            clearPrefetch()
            resetLiveWebCarryPrewarmState()
            return
        }

        guard isActive,
              currentParagraphIndex >= 0,
              readableIndices.contains(currentParagraphIndex) else { return }

        let wasFinished = isFinished
        if wasFinished {
            pendingReadingAudioCursor = nil
            pendingResumeParagraphIndex = nil
            resumeNotice = nil
        }
        let retryingAudioResume = resumeNotice != nil && pendingReadingAudioCursor != nil
        guard prepareReadingAudioResumeRetry() else { return }
        let previewHadSuspendedPlayback = VoicePreviewPlaybackCoordinator.shared.cancelForVoiceSwitch()
        VoiceSamplePlayer.shared.stop(resumeSuspendedPlayback: false)
        VoiceClonePreviewPlayer.shared.stop(resumeSuspendedPlayback: false)
        let shouldAutoPlay = !wasFinished && (previewHadSuspendedPlayback ||
            (ownsAudioQueue && audio.hasPlaybackRequest && !isPlaybackPausedByUser) ||
            (retryingAudioResume && !isPlaybackPausedByUser) ||
            (!audio.isExplicitlyPaused && (audio.isPlaying ||
                audio.isQueuedSegmentGated || status.isLoading ||
                (status.isStreaming && audio.currentSegment == nil && !audio.hasQueuedSegments))))
        let switchID = VoiceSwitchStatusCenter.shared.begin(
            language: docLanguage,
            from: oldVoiceID,
            to: newVoiceID
        )
        activeVoiceSwitchID = switchID
        NotificationCenter.default.post(
            name: .castReaderPlaybackVoiceWillSwitch,
            object: self,
            userInfo: [
                "language": VoiceCatalog.normalizedLanguage(docLanguage),
                "fromVoiceID": oldVoiceID,
                "toVoiceID": newVoiceID,
            ]
        )
        ReaderRunLog.write(
            "READ voice switch begin from=\(oldVoiceID) to=\(newVoiceID) " +
            "para=\(currentParagraphIndex) auto=\(shouldAutoPlay) " +
            "requested=\(audio.hasPlaybackRequest) userPaused=\(isPlaybackPausedByUser)"
        )
        NSLog(
            "CRDBG voice switch begin lang=%@ from=%@ to=%@ para=%d autoPlay=%@",
            docLanguage,
            oldVoiceID,
            newVoiceID,
            currentParagraphIndex,
            shouldAutoPlay ? "Y" : "N"
        )
        if document.sourceKind == .youtube {
            saveYouTubeProgress(
                audio.currentTime,
                force: true,
                waitForPersistence: false
            )
        }
        generate(
            wasFinished ? (readableIndices.first ?? currentParagraphIndex) : currentParagraphIndex,
            voiceOverride: wasFinished ? nil : newVoiceID,
            autoPlay: shouldAutoPlay,
            voiceSwitchID: switchID
        )
    }

    /// A single bounded window serves every reader and both voice families.
    /// Future paragraphs remain ordered; a partial paragraph can be promoted.
    private func preloadNext(after index: Int) {
        guard isActive, ownsAudioQueue, !audio.hasTerminalPlaybackFailure,
              !audio.isExplicitlyPaused, !isPlaybackPausedByUser,
              segmentsByParagraph[index]?.isEmpty == false,
              let position = readableIndices.firstIndex(of: index),
              canStartAudio(persistentYouTubeCacheHit: false) else { return }
        for key in Array(readAheadStreams.keys) where key < index {
            readAheadStreams.removeValue(forKey: key)?.task?.cancel()
            kindlePrefetchedSegments.removeValue(forKey: key)
        }
        let candidates = readableIndices.dropFirst(position + 1).map { next in
            KindleParagraphPrefetchHorizon.Candidate(index: next,
                utf16Count: SpeechTextSanitizer.sanitizedForTTS(paras[next].resolvedSpeechText).utf16.count,
                readyDuration: kindlePrefetchedSegments[next].map { $0.reduce(0) { $0 + $1.duration } })
        }
        let selection = KindleParagraphPrefetchHorizon.select(candidates, speed: Double(audio.playbackRate))
        // One future producer, plus the foreground producer. Scheduler limits
        // are unchanged. Never cancel an admitted HTTP request just to replan.
        if !readAheadStreams.values.contains(where: { !$0.finished }),
           let next = selection.indices.first(where: {
               readAheadStreams[$0] == nil && !kindlePrefetchFailures.contains($0)
           }), readAheadFitsBudget(excluding: nil) {
            startPrefetch(next)
        }
        synchronizeNextPrefetch(after: index)
    }

    private func readAheadFitsBudget(excluding stream: SpeechStreamBuffer?) -> Bool {
        let pending = readAheadStreams.values.filter { !$0.promoted && $0 !== stream }
        let segments = pending.flatMap(\.segments)
        let seconds = segments.reduce(0) { $0 + max(0, $1.duration) } / max(0.25, Double(audio.playbackRate))
        let target = stream?.targetSeconds ?? 12
        return seconds < target && segments.count < 64
            && segments.reduce(0, { $0 + $1.audioData.count }) < 4 * 1024 * 1024
    }

    private func synchronizeNextPrefetch(after index: Int) {
        guard let position = readableIndices.firstIndex(of: index), position + 1 < readableIndices.count,
              let stream = readAheadStreams[readableIndices[position + 1]] else {
            prefetchTask = nil; prefetchingIndex = nil; prefetchedIndex = nil; prefetchedSegments = []
            return
        }
        prefetchTask = stream.finished ? nil : stream.task
        prefetchingIndex = stream.finished ? nil : stream.paragraphIndex
        prefetchedSegments = stream.segments
        prefetchedIndex = stream.segments.isEmpty ? nil : stream.paragraphIndex
        prefetchedYouTubeAudioIsQuotaExempt = false
    }

    /// Incremental read-ahead. The same task becomes the foreground producer;
    /// only its subsequent request priority changes when playback catches up.
    private func startPrefetch(_ nextIndex: Int) {
        guard isActive, paras.indices.contains(nextIndex),
              let session = audioSessionToken, ownsAudioQueue else { return }
        let epoch = generationEpoch
        let para = paras[nextIndex]
        let voice = settings.voice(for: docLanguage)
        let stream = SpeechStreamBuffer(paragraphIndex: nextIndex, voice: voice,
            language: docLanguage, requestID: stableCloneRequestID(paragraphIndex: nextIndex, voice: voice))
        readAheadStreams[nextIndex] = stream
        prefetchedYouTubeAudioIsQuotaExempt = false
        let generator = speechGenerator
        let includeVoiceCode = includeVoiceCodeForTTS
        ReaderRunLog.write("READ prefetch start para=\(nextIndex) epoch=\(epoch) chars=\(para.resolvedSpeechText.utf16.count) streaming=Y")
        let task = Task { [weak self] in
            do {
                try await generator.generateBufferedSpeech(
                    paragraphIndex: nextIndex,
                    text: SpeechTextSanitizer.sanitizedForTTS(para.resolvedSpeechText),
                    voice: voice, speed: 1, language: stream.language,
                    includeVoiceCode: includeVoiceCode, speaker: para.speaker,
                    cloneRequestID: stream.requestID, continuation: nil,
                    beforeRequest: { [weak self] checkpoint in
                        guard let self else { throw CancellationError() }
                        return try await self.prepareBufferedRequest(stream, checkpoint: checkpoint,
                            epoch: epoch, session: session)
                    }, onSegmentReady: { [weak self] segment in
                        await self?.receiveBufferedSegment(segment, stream: stream, epoch: epoch, session: session)
                    })
                guard let self, self.isCurrent(stream, epoch: epoch, session: session),
                      !Task.isCancelled else { return }
                stream.finished = true
                stream.continuation = nil
                self.completeCloneRequestID(matching: stream.requestID)
                ReaderRunLog.write("READ prefetch done para=\(nextIndex) epoch=\(epoch) segs=\(stream.segments.count) promoted=\(stream.promoted)")
                if stream.promoted {
                    _ = self.finishGeneratedAudio(paragraph: nextIndex, epoch: epoch, session: session)
                    self.readAheadStreams.removeValue(forKey: nextIndex)
                    self.preloadNext(after: nextIndex)
                } else {
                    self.kindlePrefetchedSegments[nextIndex] = stream.segments
                    self.preloadNext(after: self.currentParagraphIndex)
                }
            } catch {
                guard let self, self.isCurrent(stream, epoch: epoch, session: session),
                      !Task.isCancelled else { return }
                stream.finished = true
                stream.failure = error
                self.kindlePrefetchFailures.insert(nextIndex)
                self.synchronizeNextPrefetch(after: self.currentParagraphIndex)
                ReaderRunLog.write("READ prefetch failed para=\(nextIndex) epoch=\(epoch) promoted=\(stream.promoted) buffered=\(stream.segments.count) error=\(error.localizedDescription)")
                if stream.promoted {
                    self.status = .error(error.localizedDescription)
                    // A failed tail is not a completed paragraph. Drain the
                    // prefix, retain the exact continuation and offer Retry.
                    _ = self.audio.setMoreSegmentsExpected(!stream.segments.isEmpty, session: session)
                }
            }
        }
        stream.task = task
        synchronizeNextPrefetch(after: currentParagraphIndex)
    }

    private func isCurrent(_ stream: SpeechStreamBuffer, epoch: UInt64, session: AudioPlaybackSessionToken) -> Bool {
        readAheadStreams[stream.paragraphIndex] === stream && isActive && generationEpoch == epoch
            && audioSessionToken == session && audio.isPlaybackSessionActive(session)
            && settings.voice(for: docLanguage) == stream.voice && docLanguage == stream.language
    }

    private func prepareBufferedRequest(_ stream: SpeechStreamBuffer, checkpoint: TTSContinuation,
                                        epoch: UInt64, session: AudioPlaybackSessionToken) async throws -> PresetTTSRequestScheduler.Priority {
        stream.continuation = checkpoint
        while true {
            try Task.checkCancellation()
            guard isCurrent(stream, epoch: epoch, session: session), !audio.hasTerminalPlaybackFailure else {
                throw CancellationError()
            }
            if stream.promoted {
                paragraphContinuation = ParagraphContinuation(paragraphIndex: stream.paragraphIndex,
                    voice: stream.voice, language: stream.language, checkpoint: checkpoint)
            }
            if (stream.promoted || readAheadFitsBudget(excluding: nil)),
               stream.canRequest(currentSegmentID: stream.promoted ? audio.currentSegment?.id : nil,
                                 position: stream.promoted ? audio.playbackPosition : 0,
                                 rate: Double(audio.playbackRate),
                                 paused: audio.isExplicitlyPaused || isPlaybackPausedByUser) {
                stream.beginRequest(checkpoint)
                return stream.promoted ? .interactive : .readAhead
            }
            try await Task.sleep(nanoseconds: 75_000_000)
        }
    }

    private func receiveBufferedSegment(_ segment: AudioSegment, stream: SpeechStreamBuffer,
                                        epoch: UInt64, session: AudioPlaybackSessionToken) {
        guard isCurrent(stream, epoch: epoch, session: session), !stream.finished else { return }
        stream.append(segment)
        if stream.promoted {
            appendSegment(segment, paragraph: stream.paragraphIndex, epoch: epoch,
                          session: session, autoPlay: true, voiceSwitchID: nil)
        } else {
            synchronizeNextPrefetch(after: currentParagraphIndex)
            audio.prestageSegments([segment])
            ReaderRunLog.write("READ prefetch playable para=\(stream.paragraphIndex) seg=\(segment.segmentIndex) buffered=\(stream.segments.count)")
            if pendingPrefetchAdvanceFrom == currentParagraphIndex,
               !audio.isExplicitlyPaused, !isPlaybackPausedByUser {
                advance()
            }
        }
    }

    private func stableCloneRequestID(
        paragraphIndex: Int,
        voice: String
    ) -> String? {
        guard VoiceOption.requiresGenerationQuota(voice) else { return nil }
        guard paras.indices.contains(paragraphIndex) else { return nil }
        let speech = SpeechTextSanitizer.sanitizedForTTS(paras[paragraphIndex].resolvedSpeechText)
        let key = "\(resumeDocumentIndex.fingerprint)|\(paragraphIndex)|\(voice)|\(docLanguage)|\(ReadingResumeContract.fingerprint(speech))"
        if let existing = cloneRequestIDs[key] { return existing }
        let created = UUID().uuidString
        cloneRequestIDs[key] = created
        return created
    }

    private func completeCloneRequestID(matching requestID: String?) {
        guard let requestID else { return }
        // Match the captured identity, never recompute a key from mutable page
        // state. A late completion cannot clear a newer request's identity.
        cloneRequestIDs = cloneRequestIDs.filter { $0.value != requestID }
    }

    /// 取消并清空预取缓存（jump / stop / 重新 generate 时）。
    private func clearPrefetch() {
        readAheadStreams.values.forEach { $0.task?.cancel() }
        readAheadStreams.removeAll()
        foregroundStream = nil
        pendingPrefetchAdvanceFrom = nil
        kindlePrefetchedSegments.removeAll()
        kindlePrefetchFailures.removeAll()
        prefetchPromotionTask?.cancel()
        prefetchPromotionTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchingIndex = nil
        prefetchedIndex = nil
        prefetchedSegments = []
        prefetchedYouTubeAudioIsQuotaExempt = false
        // Whatever was staged for the discarded prefetch will never be played.
        audio.discardPrestagedSegments()
    }

    /// 把已预取的下一段缓存「转正」为当前段：重置高亮状态 + 一次性入队播放（无 TTS 等待），并继续预取再下一段。
    private func promotePrefetch(to index: Int) {
        guard isActive else { return }
        flushReadingProgress()
        pendingReadingAudioCursor = nil
        pendingResumeParagraphIndex = nil
        hasObservedReadingPlayback = false
        guard let session = ensureAudioSessionClaim() else { return }
        let segs = prefetchedSegments
        let stream = readAheadStreams[index]
        stream?.promoted = true
        if let stream, !stream.finished { generationTask = stream.task }
        prefetchPromotionTask?.cancel()
        prefetchPromotionTask = nil
        pendingPrefetchAdvanceFrom = nil
        if let checkpoint = stream?.continuation {
            paragraphContinuation = ParagraphContinuation(paragraphIndex: index,
                voice: stream!.voice, language: stream!.language, checkpoint: checkpoint)
        }
        kindlePrefetchedSegments.removeValue(forKey: index)
        let persistentYouTubeCacheHit = prefetchedYouTubeAudioIsQuotaExempt
        prefetchedSegments = []
        prefetchedIndex = nil
        prefetchingIndex = nil
        prefetchTask = nil
        prefetchedYouTubeAudioIsQuotaExempt = false
        guard !segs.isEmpty else { generate(index); return }
        NSLog("CRDBG promote prefetch para=%d segs=%d", index, segs.count)
        ReaderRunLog.write(
            "READ prefetch promote para=\(index) segs=\(segs.count)"
        )

        // 重置段/高亮状态（对齐 generate 开头），但不重新请求 TTS。
        setYouTubeAudioQuotaOrigin(
            paragraphIndex: index,
            persistentCacheHit: persistentYouTubeCacheHit
        )
        retainYouTubeAudioMemory(for: index)
        segmentsByParagraph[index] = segs
        youtubeCompletionSubmittedParagraph = nil
        currentParagraphIndex = index
        processedDisplayText = segs.map { $0.text }.joined()
        highlightRange = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        pdfHighlight = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        if document.sourceKind.isWebRendered { webAudioSegments.append(contentsOf: segs) }

        // loadSegments resets producer state, so restore it after installing
        // the first playable prefix. Later callbacks append to this same queue.
        guard audio.loadSegments(
            segs,
            autoPlay: !liveWebTurnIntentSuspended && !audio.isExplicitlyPaused,
            session: session
        ) else { return }
        let producing = stream.map { !$0.finished || $0.failure != nil } ?? false
        _ = audio.setMoreSegmentsExpected(producing, session: session)
        if let error = stream?.failure {
            status = .error(error.localizedDescription)
        } else {
            status = producing ? .streaming : .ready
        }
        if !producing {
            readAheadStreams.removeValue(forKey: index)
            cacheCompletedVoiceAudio(index)
            preloadNext(after: index)
        }
    }

    /// Persist the terminal checkpoint and replay bit through the same serial
    /// lane as ordinary progress. Audio bytes were already stored exactly once
    /// by generation/prefetch, so natural completion must never rewrite them.
    private func persistCompletedYouTubeParagraphIfNeeded() {
        let completedParagraphIndex = currentParagraphIndex
        guard document.sourceKind == .youtube,
              completedParagraphIndex >= 0,
              youtubeCompletionSubmittedParagraph != completedParagraphIndex
        else { return }
        youtubeCompletionSubmittedParagraph = completedParagraphIndex
        persistYouTubeHistorySummary(
            paragraphFraction: 1,
            now: Date(),
            force: completedParagraphIndex == readableIndices.last
        )

        guard let segments = segmentsByParagraph[completedParagraphIndex],
              !segments.isEmpty,
              let transcriptKey = youtubeTranscriptCacheKey,
              let finalSegment = segments.last else { return }

        let checkpoint = YouTubePlaybackCheckpoint(
            sequence: YouTubePlaybackPersistenceSequence.next(),
            accountBoundaryToken: accountBoundaryToken,
            transcriptKey: transcriptKey,
            paragraphIndex: completedParagraphIndex,
            segmentID: finalSegment.id,
            segmentIndex: finalSegment.segmentIndex,
            segmentFraction: 1,
            paragraphFraction: 1
        )
        submitYouTubePersistence(
            .completion(checkpoint),
            waitForPersistence: completedParagraphIndex == readableIndices.last
        )
        segmentsByParagraph.removeValue(forKey: completedParagraphIndex)
        youtubeQuotaExemptParagraphs.remove(completedParagraphIndex)
    }

    private func advance() {
        advance(allowAccessRefresh: true)
    }

    private func advance(allowAccessRefresh: Bool) {
        if case .error = status {
            ReaderRunLog.write("READ advance blocked reason=tts-error para=\(currentParagraphIndex)")
            return
        }
        guard isActive else {
            ReaderRunLog.write(
                "READ advance ignored reason=inactive para=\(currentParagraphIndex)"
            )
            return
        }
        if isAwaitingLiveWebCarryCompletion {
            commitListen()
            if GrowthLoopConversionCoordinator.shared.claimHardWallAtParagraphBoundary(
                document: document,
                resumeAfterPurchase: { [weak self] in
                    self?.advance(allowAccessRefresh: true)
                }
            ) {
                status = .ready
                endAnalyticsReadSession(
                    result: .blocked,
                    reason: "growth_first_value_preview"
                )
                return
            }
            let startIndex = pendingLiveWebCarryStartIndex
            isAwaitingLiveWebCarryCompletion = false
            pendingLiveWebCarryStartIndex = nil
            if let startIndex {
                let hasExactPrewarm: Bool
                if let epoch = liveWebCarryPrewarmEpoch,
                   let session = liveWebCarryPrewarmSession {
                    hasExactPrewarm = liveWebCarryPrewarmIdentityIsCurrent(
                        paragraphIndex: startIndex,
                        epoch: epoch,
                        session: session,
                        sourceText: liveWebCarryPrewarmSourceText,
                        voiceID: liveWebCarryPrewarmVoiceID,
                        language: liveWebCarryPrewarmLanguage,
                        serial: liveWebCarryPrewarmSerial
                    )
                } else {
                    hasExactPrewarm = false
                }
                if hasExactPrewarm {
                    liveWebCarryPrewarmPlaybackDue = true
                    ReaderRunLog.write(
                        "WEREAD carry completed; promote exact prewarm " +
                        "para=\(startIndex) buffered=\(liveWebCarryPrewarmSegments.count) " +
                        "producer=\(liveWebCarryPrewarmProducerFinished ? "done" : "active")"
                    )
                    startLiveWebCarryPlaybackIfReady(paragraphIndex: startIndex)
                } else {
                    generationTask?.cancel()
                    generationTask = nil
                    resetLiveWebCarryPrewarmState()
                    ReaderRunLog.write(
                        "WEREAD carry completed; exact prewarm unavailable; " +
                        "foreground generate para=\(startIndex)"
                    )
                    generate(startIndex)
                }
            } else {
                generationTask?.cancel()
                generationTask = nil
                resetLiveWebCarryPrewarmState()
                status = .ready
                isFinished = true
                ReaderRunLog.write("WEREAD carry completed; next page fully consumed")
                let automaticPageContinuation = AppReviewAutomaticPageContinuation.candidate(
                    appReviewReadSession,
                    for: document.sourceKind
                )
                if document.sourceKind != .kindle {
                    endAnalyticsReadSession(result: .success, reason: "completed")
                }
                AppReviewPromptManager.shared.recordPositiveOutcome(
                    .firstReadCompleted
                )
                onDocumentFinished?(automaticPageContinuation)
            }
            return
        }
        // AVPlayer completion notifications can be repeated during queue swaps or
        // interruption recovery. A finished playback generation owns exactly one
        // terminal transition; start/jump/generate explicitly clears isFinished.
        guard !isFinished else {
            NSLog("CRDBG advance ignored duplicate document-finished para=%d", currentParagraphIndex)
            return
        }
        persistCompletedYouTubeParagraphIfNeeded()
        commitListen()
        if GrowthLoopConversionCoordinator.shared.claimHardWallAtParagraphBoundary(
            document: document,
            resumeAfterPurchase: { [weak self] in
                self?.advance(allowAccessRefresh: true)
            }
        ) {
            status = .ready
            endAnalyticsReadSession(
                result: .blocked,
                reason: "growth_first_value_preview"
            )
            return
        }
        NSLog("CRDBG advance from para=%d readable=%d", currentParagraphIndex, readableIndices.count)
        ReaderRunLog.write(
            "READ advance from=\(currentParagraphIndex) readable=\(readableIndices.count) " +
            "status=\(Self.statusLogValue(status)) " +
            "prefetching=\(prefetchingIndex.map(String.init) ?? "-") " +
            "prefetched=\(prefetchedIndex.map(String.init) ?? "-")"
        )
        guard let pos = readableIndices.firstIndex(of: currentParagraphIndex) else {
            ReaderRunLog.write(
                "READ advance aborted reason=current-not-readable para=\(currentParagraphIndex)"
            )
            return
        }
        let nextPos = pos + 1
        guard nextPos < readableIndices.count else {
            status = .ready
            isFinished = true
            NSLog("CRDBG read document finished para=%d readable=%d", currentParagraphIndex, readableIndices.count)
            ReaderRunLog.write(
                "READ document finished para=\(currentParagraphIndex) " +
                "readable=\(readableIndices.count)"
            )
            let automaticPageContinuation = AppReviewAutomaticPageContinuation.candidate(
                appReviewReadSession,
                for: document.sourceKind
            )
            // A Kindle OCR document is one visual page, not one user reading
            // session. KindleBookViewModel either transfers this still-open
            // coordinator to the confirmed next page or terminates it if the
            // page advance truly fails/ends.
            if document.sourceKind != .kindle {
                endAnalyticsReadSession(result: .success, reason: "completed")
            }
            AppReviewPromptManager.shared.recordPositiveOutcome(
                .firstReadCompleted
            )
            onDocumentFinished?(automaticPageContinuation)
            return
        }
        let nextIndex = readableIndices[nextPos]
        let hasReadyPrefetch = prefetchedIndex == nextIndex
            && !prefetchedSegments.isEmpty
        let readyPrefetchIsQuotaExempt = hasReadyPrefetch
            && prefetchedYouTubeAudioIsQuotaExempt

        // A persistent YouTube cache hit is allowed to cross a quota boundary.
        // Fresh prefetches still pass through the ordinary paragraph gate.
        if readyPrefetchIsQuotaExempt {
            promotePrefetch(to: nextIndex)
            return
        }

        // At a YouTube boundary the in-flight lookup may still resolve to a
        // quota-exempt persistent hit. Wait for its origin before deciding.
        if document.sourceKind == .youtube, !hasReadyPrefetch,
           prefetchingIndex == nextIndex,
           let task = prefetchTask {
            status = .loading
            ReaderRunLog.write(
                "READ boundary waiting YouTube cache origin from=\(currentParagraphIndex) " +
                "next=\(nextIndex)"
            )
            let epoch = generationEpoch
            let sourceParagraphIndex = currentParagraphIndex
            let session = audioSessionToken
            pendingPrefetchAdvanceFrom = sourceParagraphIndex
            prefetchPromotionTask?.cancel()
            prefetchPromotionTask = Task { [weak self] in
                _ = await task.value
                guard let self,
                      !Task.isCancelled,
                      self.isActive,
                      self.generationEpoch == epoch,
                      self.currentParagraphIndex == sourceParagraphIndex,
                      self.audioSessionToken == session,
                      self.ownsAudioQueue else { return }
                self.prefetchPromotionTask = nil
                guard !self.audio.isExplicitlyPaused else { return }
                self.pendingPrefetchAdvanceFrom = nil
                self.advance(allowAccessRefresh: allowAccessRefresh)
            }
            return
        }

        // 段落边界做额度闸门（“读完本篇”自然边界）。With no prepared
        // YouTube origin, let foreground generation probe disk first; its cache
        // miss path owns the fresh-audio quota refresh/paywall decision.
        if !pro.isPro && !quota.canStartListen(isPro: pro.isPro) {
            if document.sourceKind == .youtube, !hasReadyPrefetch {
                ReaderRunLog.write(
                    "READ boundary YouTube cache probe next=\(nextIndex)"
                )
                generate(
                    nextIndex,
                    allowAccessRefresh: allowAccessRefresh
                )
                return
            }
            if allowAccessRefresh {
                refreshAccessThenRetryAdvance()
                return
            }
            status = .ready
            showPaywall = true
            pendingPrefetchAdvanceFrom = currentParagraphIndex
            if let token = audioSessionToken {
                _ = audio.pause(session: token)
            }
            endAnalyticsReadSession(result: .blocked, reason: "listen_quota")
            return
        }

        // ① 预取已就绪 → 秒接，无需重新请求 TTS（消除段间等首字节的 gap）
        if hasReadyPrefetch {
            promotePrefetch(to: nextIndex)
            return
        }
        // ② 正在预取这段（段落比生成快）→ 等它完成再转正，避免从头重启浪费已生成部分
        if prefetchingIndex == nextIndex, let task = prefetchTask {
            status = .loading
            ReaderRunLog.write(
                "READ boundary waiting prefetch from=\(currentParagraphIndex) " +
                "next=\(nextIndex)"
            )
            let epoch = generationEpoch
            let sourceParagraphIndex = currentParagraphIndex
            let session = audioSessionToken
            pendingPrefetchAdvanceFrom = sourceParagraphIndex
            prefetchPromotionTask?.cancel()
            prefetchPromotionTask = Task { [weak self] in
                _ = await task.value
                guard let self,
                      !Task.isCancelled,
                      self.isActive,
                      self.generationEpoch == epoch,
                      self.currentParagraphIndex == sourceParagraphIndex,
                      self.audioSessionToken == session,
                      self.ownsAudioQueue else { return }
                self.prefetchPromotionTask = nil
                guard !self.audio.isExplicitlyPaused else { return }
                self.pendingPrefetchAdvanceFrom = nil
                // Recheck the paragraph entitlement gate after the network wait.
                self.advance(allowAccessRefresh: allowAccessRefresh)
            }
            return
        }
        // ③ 无预取 → 正常生成
        ReaderRunLog.write(
            "READ boundary no prefetch next=\(nextIndex); foreground generate"
        )
        generate(
            nextIndex,
            allowAccessRefresh: allowAccessRefresh
        )
    }

    private static func statusLogValue(_ status: TTSStatus) -> String {
        switch status {
        case .pending:
            return "pending"
        case .loading:
            return "loading"
        case .streaming:
            return "streaming"
        case .ready:
            return "ready"
        case .error:
            return "error"
        }
    }

    private func refreshAccessThenRetryAdvance(
        refresh: @escaping @MainActor () async -> Void = { await ProManager.shared.refresh() }
    ) {
        status = .loading
        if let token = audioSessionToken {
            _ = audio.pauseForEntitlementRefresh(session: token)
        }
        invalidateAccessRetry()
        let retryEpoch = accessRetryEpoch
        let paragraphIndex = currentParagraphIndex
        let epoch = generationEpoch
        let session = audioSessionToken
        pendingPrefetchAdvanceFrom = paragraphIndex
        accessRetryTask = Task { [weak self] in
            await refresh()
            guard let self,
                  !Task.isCancelled,
                  self.accessRetryEpoch == retryEpoch,
                  self.isActive,
                  self.currentParagraphIndex == paragraphIndex,
                  self.generationEpoch == epoch,
                  self.audioSessionToken == session,
                  self.ownsAudioQueue else { return }
            self.accessRetryTask = nil
            guard !self.audio.isExplicitlyPaused else { return }
            self.pendingPrefetchAdvanceFrom = nil
            self.advance(allowAccessRefresh: false)
        }
    }

    // MARK: - 高亮

    private func onTick(_ t: Double) {
        guard ownsAudioQueue else { return }
        if audio.hasAudibleProgress { handlePlaybackState(audio.isPlaying) }
        if audio.isPlaying, audio.hasAudibleProgress, !audio.isBuffering {
#if DEBUG
            if debugResumeAwaitingFirstTick {
                debugResumeFirstPlaybackSeconds = audio.playbackPosition
                debugResumeAwaitingFirstTick = false
                let actual = audio.currentSegment.flatMap { current in
                    ReadingResumeContract.captureAudio(segments: segmentsByParagraph[currentParagraphIndex] ?? [],
                        currentSegmentID: current.id, time: audio.playbackPosition)
                }
                ReaderRunLog.write(
                    "READ resume first-play source=\(document.sourceKind.rawValue) " +
                    "item=\(ReadingResumeContract.fingerprint(readingProgressID).prefix(12)) " +
                    "para=\(currentParagraphIndex) time=\(audio.playbackPosition) " +
                    "word=\(actual?.semanticWordFingerprint?.prefix(12) ?? "-") fraction=\(actual?.wordFraction ?? -1)"
                )
            }
#endif
            hasObservedReadingPlayback = true
            saveReadingProgress(force: false)
        }
        accountAnalyticsPlayback(t)
        accountListen(t)
        saveYouTubeProgress(t)
        updateHighlight(t)
        updateNowPlayingCaption(t)
        signalPageBoundaryIfNeeded(t)
    }

    private func saveYouTubeProgress(
        _ currentTime: Double,
        force: Bool = false,
        waitForPersistence: Bool = false
    ) {
        guard document.sourceKind == .youtube,
              let segment = audio.currentSegment,
              segment.paragraphIndex == currentParagraphIndex else { return }

        // Playback acceptance is a player fact, not a persistence fact. Keep
        // it functional even when the optional on-disk cache is unavailable.
        if YouTubePlaybackAcceptancePolicy.shouldConfirm(
            currentTime: currentTime,
            segmentID: segment.id,
            lastConfirmedSegmentID: lastYouTubePlaybackSignalSegmentID
        ) {
            lastYouTubePlaybackSignalSegmentID = segment.id
            NotificationCenter.default.post(
                name: .castReaderYouTubePlaybackConfirmed,
                object: document.contentSessionKey
            )
        }
        if !didRecordYouTubeFirstListen,
           YouTubePlaybackAcceptancePolicy.didCompleteFirstListen(
               currentTime: currentTime
           ) {
            didRecordYouTubeFirstListen = true
            UserDefaults.standard.set(
                true,
                forKey: "youtube.didCompleteFirstListen"
            )
        }

        let now = Date()
        guard YouTubePlaybackPersistencePolicy.shouldPersistProgress(
            now: now,
            lastWriteAt: lastYouTubeProgressWriteAt,
            force: force
        ) else { return }
        guard let transcriptKey = youtubeTranscriptCacheKey else { return }
        let duration = audio.duration > 0.01 ? audio.duration : segment.duration
        guard duration > 0.01 else { return }
        guard let playbackPosition = YouTubeParagraphProgressContract.position(
            in: segmentsByParagraph[currentParagraphIndex] ?? [segment],
            currentSegmentID: segment.id,
            currentTime: currentTime,
            currentSegmentDuration: duration
        ) else { return }

        lastYouTubeProgressWriteAt = now
        let checkpoint = YouTubePlaybackCheckpoint(
            sequence: YouTubePlaybackPersistenceSequence.next(),
            accountBoundaryToken: accountBoundaryToken,
            transcriptKey: transcriptKey,
            paragraphIndex: segment.paragraphIndex,
            segmentID: segment.id,
            segmentIndex: segment.segmentIndex,
            segmentFraction: playbackPosition.segmentFraction,
            paragraphFraction: playbackPosition.paragraphFraction
        )
        submitYouTubePersistence(
            .progress(checkpoint),
            waitForPersistence: waitForPersistence
        )
        persistYouTubeHistorySummary(
            paragraphFraction: playbackPosition.paragraphFraction,
            now: now,
            force: force
        )

    }

    private func submitYouTubePersistence(
        _ work: YouTubePlaybackPersistenceWork,
        waitForPersistence: Bool
    ) {
        youtubePersistenceLane.submit(work)
        if waitForPersistence {
            waitForYouTubePersistence()
        }
    }

    /// Enqueues a barrier after every submission made by this VM, then waits
    /// for the process-wide writer and its batched manifest touches. Returning
    /// the retained task gives stop/background paths real awaitable semantics.
    private func waitForYouTubePersistence() -> Task<Void, Never> {
        youtubePersistenceLane.flush {
            await YouTubeCacheProvider.shared?.flushDeferredManifestUpdates()
        }
    }

    private func persistYouTubeHistorySummary(
        paragraphFraction: Double,
        now: Date,
        force: Bool
    ) {
        guard let accountBoundaryToken,
              AccountContentIsolation.isCurrent(accountBoundaryToken),
              document.sourceKind == .youtube,
              let position = readableIndices.firstIndex(of: currentParagraphIndex),
              !readableIndices.isEmpty,
              let paragraph = paras.first(where: { $0.id == currentParagraphIndex }) else {
            return
        }
        guard YouTubePlaybackPersistencePolicy.shouldPersistHistory(
            now: now,
            lastWriteAt: lastYouTubeHistoryProgressWriteAt,
            force: force
        ) else { return }
        lastYouTubeHistoryProgressWriteAt = now
        let completed = Double(position) + min(1, max(0, paragraphFraction))
        let overall = min(1, max(0, completed / Double(readableIndices.count)))
        HistoryStore.shared.updateYouTubeListeningSummary(
            documentID: document.id,
            durationMs: document.youtubeTranscript?.metadata.durationMs,
            resumeStartMs: paragraph.startMs ?? 0,
            progressFraction: overall
        )
    }

    private func signalPageBoundaryIfNeeded(_ time: Double) {
        guard !didSignalPageBoundaryApproaching,
              document.sourceKind.isLiveWebLibrary,
              isOnLastReadableParagraph,
              currentTTSCompleteForPageHandoff,
              let segment = audio.currentSegment,
              audio.duration > 0 else { return }

        if let cue = currentWeReadBoundaryCue {
            guard WeReadCrossPageSpeechContract.shouldRequestTurn(
                currentSegmentID: segment.id,
                cue: cue,
                currentTime: time,
                playbackRate: audio.playbackRate,
                leadSeconds: weReadBoundaryTurnLeadSeconds
            ) else { return }
            didSignalPageBoundaryApproaching = true
            onPageBoundaryApproaching?()
            return
        }

        guard segmentsByParagraph[currentParagraphIndex]?.last?.id == segment.id else { return }
        let remaining = max(0, audio.duration - time)
        let wallClock = remaining / max(0.25, Double(audio.playbackRate))
        guard wallClock <= WeReadContinuousPageHandoffContract.visualTurnLeadSeconds else { return }
        didSignalPageBoundaryApproaching = true
        onPageBoundaryApproaching?()
    }

    private func updateNowPlayingCaption(_ t: Double) {
        guard let seg = audio.currentSegment, seg.paragraphIndex == currentParagraphIndex else { return }
        guard seg.id != lastCaptionEvaluationSegmentID
                || t < lastCaptionEvaluationTime
                || t - lastCaptionEvaluationTime >= 0.5 else { return }
        lastCaptionEvaluationSegmentID = seg.id
        lastCaptionEvaluationTime = t
        let caption = Self.caption(for: seg, at: t, duration: audio.duration)
        guard caption != lastNowPlayingCaption else { return }
        lastNowPlayingCaption = caption
        audio.setNowPlayingCaption(caption)
    }

    private static func caption(for segment: AudioSegment, at time: Double, duration: Double) -> String {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if !segment.timestamps.isEmpty,
           let word = currentTimestampWord(in: segment, at: time),
           let sentence = sentence(containing: word.word, in: text) {
            return sentence
        }
        let effectiveDuration = duration > 0.01 ? duration : segment.duration
        if let sentence = sentenceByProgress(in: text, time: time, duration: effectiveDuration) {
            return sentence
        }
        return text
    }

    private static func currentTimestampWord(in segment: AudioSegment, at time: Double) -> TTSTimestamp? {
        var current: TTSTimestamp?
        for ts in segment.timestamps {
            if time + 0.02 >= ts.startTime { current = ts } else { break }
        }
        return current ?? segment.timestamps.first
    }

    private static func sentence(containing word: String, in text: String) -> String? {
        let ranges = sentenceRanges(in: text)
        guard !ranges.isEmpty else { return nil }
        let ns = text as NSString
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedWord.isEmpty {
            for range in ranges {
                let found = ns.range(of: normalizedWord, options: [.caseInsensitive], range: range)
                if found.location != NSNotFound {
                    return ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return ns.substring(with: ranges[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sentenceByProgress(in text: String, time: Double, duration: Double) -> String? {
        let ranges = sentenceRanges(in: text)
        guard !ranges.isEmpty else { return nil }
        guard duration > 0.01 else {
            return (text as NSString).substring(with: ranges[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ns = text as NSString
        let target = Int(min(1, max(0, time / duration)) * Double(ns.length))
        for range in ranges where target < range.location + range.length {
            return ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ns.substring(with: ranges.last!).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sentenceRanges(in text: String) -> [NSRange] {
        ReadingSentenceContract.nsRanges(in: text, lineBreakIsBoundary: true)
    }

    private func hasReliableWordHighlight(_ segment: AudioSegment) -> Bool {
        guard TTSHighlightPolicy.usesWordTimestamps(language: docLanguage) else {
            return false
        }
        return TTSTimestampQuality.hasReliableWordGranularity(
            text: segment.text,
            timestamps: segment.timestamps,
            duration: segment.duration
        )
    }

    private func wordHighlightSegments(_ segments: [AudioSegment]) -> [AudioSegment] {
        segments.map { segment in
            guard !hasReliableWordHighlight(segment) else { return segment }
            return AudioSegment(
                paragraphIndex: segment.paragraphIndex,
                segmentIndex: segment.segmentIndex,
                audioData: segment.audioData,
                timestamps: [],
                duration: segment.duration,
                text: segment.text,
                isWavFormat: segment.isWavFormat,
                unprocessedText: segment.unprocessedText,
                speaker: segment.speaker
            )
        }
    }

    private func updateHighlight(_ t: Double) {
        // A live web page can replace its paragraph array on a resize/page
        // commit while Combine still has one queued currentTime tick from the
        // old AVPlayerItem. Never index the replaceable page model until both
        // the player identity and paragraph bounds belong to the same snapshot.
        guard let seg = audio.currentSegment,
              seg.paragraphIndex == currentParagraphIndex,
              currentParagraphIndex >= 0,
              currentParagraphIndex < paras.count else { return }

        // .web/.docx 源：高亮在 WebView DOM 上，bridge 下发段内 charRange（UTF-16 对齐 JS textContent）。
        if document.sourceKind.isWebRendered {
            let segs = segmentsByParagraph[currentParagraphIndex] ?? []
            guard let segPos = segs.firstIndex(where: { $0.id == seg.id }) else { return }
            let total = (paras[currentParagraphIndex].text as NSString).length
            let base = segs.prefix(segPos).reduce(0) { $0 + ($1.text as NSString).length }

            // 当前音频段有可靠词时间戳 → 逐词：下发词数组+索引+segment序号，JS 在 DOM 虚拟全文前向匹配（不靠字符偏移，对齐扩展 highlight-sync）。
            if hasReliableWordHighlight(seg) {
                var localIdx = -1
                for (i, ts) in seg.timestamps.enumerated() {
                    if t + 0.02 >= ts.startTime { localIdx = i } else { break }
                }
                guard localIdx >= 0 else { return }
                setWebHighlight(WebHighlightCmd(paragraphIndex: currentParagraphIndex,
                                                words: seg.timestamps.map { $0.word },
                                                wordIndex: localIdx,
                                                segSeq: segPos,
                                                segmentTexts: segs.prefix(segPos).map(\.text)))
                return
            }
            let segLen = (seg.text as NSString).length
            let charStart = min(base, total)
            let charEnd = min(base + segLen, total)
            if charEnd > charStart || document.sourceKind == .weread {
                // `processedText` may normalize quotes, whitespace and punctuation,
                // so accumulated lengths are fallback evidence only.  Send the
                // immutable segment sequence to the Web bridge, which replays the
                // extension's formatting-tolerant source-text matching from zero.
                setWebHighlight(WebHighlightCmd(
                    paragraphIndex: currentParagraphIndex,
                    charStart: charStart,
                    charEnd: charEnd,
                    segSeq: segPos,
                    segmentTexts: segs.map(\.text)
                ))
            }
            return
        }

        // .pdf：句级淡高亮由 PDFReaderView 按 currentParagraphIndex 画；当前段质量门通过时额外算「当前词」，
        // 发 pdfHighlight 让 PDFReaderView 在句范围内 findString 定位词、画词矩形；否则仅保留句级反馈。
        if document.usesNativePDFRendering {
            let segs = segmentsByParagraph[currentParagraphIndex] ?? []
            guard let segPos = segs.firstIndex(where: { $0.id == seg.id }), hasReliableWordHighlight(seg) else { return }
            var localIdx = -1
            for (i, ts) in seg.timestamps.enumerated() {
                if t + 0.02 >= ts.startTime { localIdx = i } else { break }
            }
            guard localIdx >= 0 else { return }
            let wordSegments = wordHighlightSegments(segs)
            let priorWords = wordSegments.prefix(segPos).reduce(0) { $0 + $1.timestamps.count }
            let words = wordSegments.flatMap { $0.timestamps.map { $0.word } }
            let cmd = PDFWordHighlight(paragraphIndex: currentParagraphIndex, words: words, wordIndex: priorWords + localIdx)
            if pdfHighlight != cmd { pdfHighlight = cmd }
            return
        }

        let segs = segmentsByParagraph[currentParagraphIndex] ?? []
        guard let segPos = segs.firstIndex(where: { $0.id == seg.id }) else { return }
        let base = segs.prefix(segPos).reduce(0) { $0 + ($1.text as NSString).length }

        // 对齐扩展：当前段时间戳质量不通过 → 高亮当前整句（整个 segment 文本），随 segment 推进；
        // 质量门通过 → 词级逐字高亮（"老师指读"），与语言无关。
        if !hasReliableWordHighlight(seg) {
            if document.usesNativeTextRendering {
                let content = contentRange(in: seg.text as NSString)
                let range = NSRange(
                    location: base + content.location,
                    length: content.length
                )
                if highlightRange != range { highlightRange = range }
            } else if document.sourceKind.isOCRImageRendered {
                // Segment highlight is derived from the segment's own text and
                // the OCR word stream. It must not depend on `segs.count`: that
                // count grows while TTS streams and previously repartitioned an
                // already-playing Chinese/Japanese/Hindi segment on screen.
                let words = document.paragraphs[currentParagraphIndex].words.map(\.text)
                if let range = Self.alignedPhotoWordRange(
                    words: words,
                    segmentTexts: segs.map(\.text),
                    segPos: segPos
                ) {
                    if photoHighlightWordRange != range {
                        photoHighlightWordRange = range
                    }
                    if range.lowerBound != photoHighlightWordIndex { photoHighlightWordIndex = range.lowerBound }
                }
            }
            return
        }
        var localIdx = -1
        for (i, ts) in seg.timestamps.enumerated() {
            if t + 0.02 >= ts.startTime { localIdx = i } else { break }
        }
        guard localIdx >= 0 else { return }

        let wordKey = "\(seg.id)#\(localIdx)"
        #if DEBUG
        if document.sourceKind == .kindle,
           ProcessInfo.processInfo.arguments.contains("-CastReaderTTSClockDiagnostics"),
           lastWordKey.hasPrefix("\(seg.id)#"),
           let previous = lastWordKey.split(separator: "#").last.flatMap({ Int($0) }),
           localIdx > previous + 1 {
            let missed = seg.timestamps[(previous + 1)..<localIdx]
            let durations = missed.map { String(Int(($0.endTime - $0.startTime) * 1000)) }.joined(separator: ",")
            let windows = missed.enumerated().map { offset, stamp in
                String(Int((seg.timestamps[previous + 2 + offset].startTime - stamp.startTime) * 1000))
            }.joined(separator: ",")
            KindleRunLog.write("KINDLE_CLOCK missed=\(localIdx - previous - 1) segment=\(seg.id) from=\(previous) to=\(localIdx) audioMs=\(Int(t * 1000)) speechMs=\(durations) displayWindowMs=\(windows)")
        }
        #endif
        defer { lastWordKey = wordKey }

        if document.usesNativeTextRendering {
            // 预对齐查表（绝对位置，已含前序 segment 偏移）；对齐失败的词保留上一个高亮、不跳
            ensureWordAligned()
            let gIdx = wordHighlightSegments(segs).prefix(segPos).reduce(0) { $0 + $1.timestamps.count } + localIdx
            if gIdx >= 0, gIdx < wordRanges.count, let r = wordRanges[gIdx] {
                if highlightRange != r { highlightRange = r }
            }
        } else if document.sourceKind.isOCRImageRendered {
            ensureOCRWordAligned()
            let gIdx = wordHighlightSegments(segs).prefix(segPos).reduce(0) { $0 + $1.timestamps.count } + localIdx
            if gIdx >= 0, gIdx < ocrWordIndexes.count, let idx = ocrWordIndexes[gIdx] {
                let next = max(photoHighlightWordIndex ?? -1, idx)
                let mappedRange = ocrWordRanges[gIdx] ?? (idx..<(idx + 1))
                let range = next..<max(next + 1, mappedRange.upperBound)
                if photoHighlightWordRange != range {
                    photoHighlightWordRange = range
                }
                if next != photoHighlightWordIndex { photoHighlightWordIndex = next }
            } else if document.sourceKind != .kindle, wordKey != lastWordKey {
                // Fallback only when the timestamp word cannot be resolved to paragraph text.
                advancePhotoCursor(toward: seg.timestamps[localIdx].word)
            }
        }
    }

    /// segment 文本去掉首尾空白后的字符范围（句子级高亮不含两端空格/换行，更贴合视觉）。
    private func contentRange(in ns: NSString) -> NSRange {
        let full = NSRange(location: 0, length: ns.length)
        guard ns.length > 0 else { return full }
        let ws = CharacterSet.whitespacesAndNewlines.inverted
        let first = ns.rangeOfCharacter(from: ws, options: [], range: full)
        let last = ns.rangeOfCharacter(from: ws, options: [.backwards], range: full)
        guard first.location != NSNotFound, last.location != NSNotFound else { return full }
        return NSRange(location: first.location, length: last.location + last.length - first.location)
    }

    /// 在 segment 文本中定位第 index 个词的 NSRange。
    /// 一次性把当前段所有 TTS 词序对齐到 processedDisplayText（segs 拼接）字符区间，游标单向只进，缓存查表。
    /// 对齐 Android ensureWordAligned，根治 EPUB 长段词高亮卡死：
    /// ①预对齐缓存（不每帧 indexOf 重复定位）②游标单向（重复词按序命中、短词不被远处同名子串带偏）
    /// ③找不到的词存 nil 但 cursor 不动、继续后续词（不再「一词找不到就全盘失败」）。
    /// segments 流式增长（数量变化）时重对齐。
    private func ensureWordAligned() {
        let segs = segmentsByParagraph[currentParagraphIndex] ?? []
        if alignedPara == currentParagraphIndex && alignedSegCount == segs.count { return }
        let full = segs.map { $0.text }.joined() as NSString
        let punct = CharacterSet(charactersIn: ".,!?;:\"'()[]").union(.whitespacesAndNewlines)
        var ranges: [NSRange?] = []
        var cursor = 0
        for seg in wordHighlightSegments(segs) {
            for ts in seg.timestamps {
                let word = ts.word.trimmingCharacters(in: .whitespacesAndNewlines)
                if word.isEmpty { ranges.append(nil); continue }
                let tail = NSRange(location: cursor, length: max(0, full.length - cursor))
                var found = full.range(of: word, options: [.caseInsensitive], range: tail)
                var len = (word as NSString).length
                if found.location == NSNotFound {
                    let stripped = word.trimmingCharacters(in: punct)
                    if stripped.count >= 2 {
                        found = full.range(of: stripped, options: [.caseInsensitive], range: tail)
                        len = (stripped as NSString).length
                    }
                }
                if found.location != NSNotFound {
                    ranges.append(NSRange(location: found.location, length: len))
                    cursor = found.location + len
                } else {
                    ranges.append(nil)   // 找不到 → nil，cursor 不动，继续下一个词
                }
            }
        }
        wordRanges = ranges
        alignedPara = currentParagraphIndex
        alignedSegCount = segs.count
    }

    private func ensureOCRWordAligned() {
        guard currentParagraphIndex >= 0, currentParagraphIndex < document.paragraphs.count else { return }
        let segs = wordHighlightSegments(segmentsByParagraph[currentParagraphIndex] ?? [])
        if ocrAlignedPara == currentParagraphIndex && ocrAlignedSegCount == segs.count { return }
        let allowFallback = document.sourceKind != .kindle
        ocrWordRanges = OCRWordAligner.mapTimestampWordRanges(
            segs.flatMap(\.timestamps),
            in: document.paragraphs[currentParagraphIndex],
            allowFallback: allowFallback,
            allowBoundedFallback: document.sourceKind == .kindle
        )
        ocrWordIndexes = ocrWordRanges.map { $0?.lowerBound }
        ocrAlignedPara = currentParagraphIndex
        ocrAlignedSegCount = segs.count
        #if DEBUG
        let hit = ocrWordIndexes.compactMap { $0 }.count
        let total = ocrWordIndexes.count
        if total > 0 {
            let firstMapped = ocrWordIndexes.firstIndex(where: { $0 != nil })
            let mapped = ocrWordIndexes.compactMap { $0 }
            NSLog("CRDBG ocr align para=%d hit=%d/%d mode=%@",
                  currentParagraphIndex,
                  hit,
                  total,
                  allowFallback ? "fallback" : "strict")
            if document.sourceKind == .kindle {
                KindleRunLog.write(
                    "KINDLE_ALIGN p=\(currentParagraphIndex) total=\(total) hit=\(hit) " +
                    "prefixMiss=\(firstMapped ?? total) first=\(firstMapped.flatMap { ocrWordIndexes[$0] } ?? -1) " +
                    "monotonic=\(mapped == mapped.sorted() ? "Y" : "N")"
                )
            }
        }
        #endif
    }

    private func clearOCRWordAlignment() {
        ocrAlignedPara = -1
        ocrAlignedSegCount = -1
        ocrWordIndexes = []
        ocrWordRanges = []
    }

    /// photo 无词时间戳时：把「段内第 segPos 个 segment + 其内部进度」线性映射到 OCR 词索引（句子级近似）。
    /// segCount 为段内已知 segment 数（流式时可能偏小，调用方用单调不减兜底）。返回 nil = 无词可高亮。
    static func photoWordIndex(wordCount: Int, segPos: Int, segCount: Int, segProgress: Double) -> Int? {
        guard wordCount > 0 else { return nil }
        let count = max(segCount, segPos + 1)
        let progress = (Double(segPos) + min(1, max(0, segProgress))) / Double(count)
        return min(wordCount - 1, max(0, Int(progress * Double(wordCount))))
    }

    nonisolated static func photoWordRange(wordCount: Int, segPos: Int, segCount: Int) -> Range<Int>? {
        guard wordCount > 0 else { return nil }
        let count = max(segCount, segPos + 1)
        let start = min(wordCount - 1, max(0, Int(floor(Double(segPos) * Double(wordCount) / Double(count)))))
        let end = min(wordCount, max(start + 1, Int(ceil(Double(segPos + 1) * Double(wordCount) / Double(count)))))
        return start..<end
    }

    /// Align one TTS segment to OCR word boxes using normalized Unicode text.
    /// Prefix segments are deterministically replayed from the paragraph start so
    /// repeated phrases resolve monotonically, matching the extension contract.
    /// A failed match is never treated as a successful cursor match: doing that
    /// made Japanese segments jump back to, or paint only, the first glyph.
    nonisolated static func alignedPhotoWordRange(
        words: [String],
        segmentTexts: [String],
        segPos: Int
    ) -> Range<Int>? {
        guard !words.isEmpty, segPos >= 0, segPos < segmentTexts.count else { return nil }

        let normalizedWords = words.map {
            KindleLanguageContract.alignmentText($0).unicodeScalars.map(\.value)
        }
        var wordSpans: [Range<Int>] = []
        var full: [UInt32] = []
        for word in normalizedWords {
            let start = full.count
            full.append(contentsOf: word)
            wordSpans.append(start..<full.count)
        }
        guard !full.isEmpty else { return nil }

        var cursor = 0
        var target: Range<Int>?
        for index in 0...segPos {
            let needle = KindleLanguageContract.alignmentText(segmentTexts[index])
                .unicodeScalars.map(\.value)
            guard !needle.isEmpty else {
                if index == segPos { return nil }
                continue
            }
            guard let start = normalizedSubsequenceStart(
                haystack: full,
                needle: needle,
                from: cursor
            ) else {
                return nil
            }
            let end = min(full.count, start + needle.count)
            guard end > start else { return nil }
            if index == segPos { target = start..<end }
            cursor = end
        }
        guard let target else { return nil }

        guard let first = wordSpans.firstIndex(where: { $0.upperBound > target.lowerBound && !$0.isEmpty }),
              let last = wordSpans.lastIndex(where: { $0.lowerBound < target.upperBound && !$0.isEmpty }),
              last >= first else { return nil }
        // Alignment normalization intentionally removes punctuation. Vision can
        // emit Japanese/CJK sentence punctuation as its own OCR word, so carry
        // adjacent trailing punctuation-only boxes into the visual sentence.
        var upperBound = last + 1
        while upperBound < normalizedWords.count, normalizedWords[upperBound].isEmpty {
            upperBound += 1
        }
        return first..<upperBound
    }

    private nonisolated static func normalizedSubsequenceStart(
        haystack: [UInt32],
        needle: [UInt32],
        from start: Int
    ) -> Int? {
        guard !needle.isEmpty, start >= 0, start <= haystack.count,
              needle.count <= haystack.count - start else { return nil }
        let finalStart = haystack.count - needle.count
        guard start <= finalStart else { return nil }
        for index in start...finalStart {
            var matches = true
            for offset in needle.indices where haystack[index + offset] != needle[offset] {
                matches = false
                break
            }
            if matches { return index }
        }
        return nil
    }

    /// photo：把当前 TTS 词对齐到 OCR 词（游标只前进，匹配优先，否则顺移）。
    private func advancePhotoCursor(toward word: String) {
        guard currentParagraphIndex >= 0, currentParagraphIndex < document.paragraphs.count else { return }
        let words = document.paragraphs[currentParagraphIndex].words
        guard !words.isEmpty else { photoHighlightWordIndex = nil; photoHighlightWordRange = nil; return }
        let target = normalize(word)
        let window = 6
        let upper = min(words.count, photoCursor + window)
        if photoCursor < words.count {
            for i in photoCursor..<upper {
                if normalize(words[i].text) == target {
                    photoHighlightWordIndex = i
                    photoHighlightWordRange = i..<(i + 1)
                    photoCursor = i + 1
                    return
                }
            }
        }
        let idx = min(photoCursor, words.count - 1)
        photoHighlightWordIndex = idx
        photoHighlightWordRange = idx..<(idx + 1)
        photoCursor = idx + 1
    }

    private func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: - Product analytics

    private func beginAnalyticsReadSessionIfNeeded(resume: Bool) {
        let startedNewSession = analyticsSessionCoordinator.begin(
            ownerID: analyticsSessionOwnerID
        )
        guard startedNewSession else { return }
        if preserveAppReviewSessionOnNextAnalyticsBegin {
            preserveAppReviewSessionOnNextAnalyticsBegin = false
        } else {
            appReviewReadSession = AppReviewReadSessionProgress()
            onAppReviewReadSessionInvalidated?()
        }
        let voice = settings.voice(for: docLanguage)
        ProductAnalytics.shared.track(
            .readStart,
            context: analyticsEventContext,
            properties: .init(
                contentSource: analyticsContext.source.rawValue,
                contentFormat: AnalyticsContentFormat(document.sourceKind).rawValue,
                language: docLanguage,
                voiceId: voice,
                speed: settings.effectiveSpeed(isPro: pro.isPro),
                resume: resume || analyticsContext.source == .history,
                storefront: analyticsContext.storefront
            )
        )
    }

    private func handlePlaybackState(_ playing: Bool) {
        let ownedPlaying = playing && audio.isPlaying && ownsAudioQueue
        if ownedPlaying, audio.hasAudibleProgress, !audio.isBuffering { hasObservedReadingPlayback = true }
        if !playing { flushReadingProgress() }
        isPlaying = ownedPlaying
        guard ownedPlaying else {
            analyticsSessionCoordinator.resetPlaybackCursor(
                ownerID: analyticsSessionOwnerID
            )
            return
        }
        guard audio.hasAudibleProgress, audio.currentSegment != nil,
              let startedAt = analyticsSessionCoordinator.markFirstAudio(
                ownerID: analyticsSessionOwnerID
              ) else { return }
        let latency = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        ProductAnalytics.shared.track(
            .readFirstAudio,
            context: analyticsEventContext,
            properties: .init(
                latencyMs: latency,
                language: docLanguage,
                voiceId: settings.voice(for: docLanguage),
                storefront: analyticsContext.storefront
            )
        )
        GrowthLoopConversionCoordinator.shared.firstAudioBecameAudible(
            document: document
        )
    }

    private func accountAnalyticsPlayback(_ currentTime: Double) {
        guard ownsAudioQueue,
              audio.isPlaying,
              let segment = audio.currentSegment else { return }
        guard let update = analyticsSessionCoordinator.accountPlayback(
            ownerID: analyticsSessionOwnerID,
            segmentID: segment.id,
            position: currentTime
        ) else { return }
        if let rawPlaybackDelta = update.rawPlaybackDelta {
            if appReviewReadSession.record(rawPlaybackDelta: rawPlaybackDelta) {
                AppReviewPromptManager.shared.recordFiveMinuteReadSession(
                    sessionID: appReviewReadSession.sessionID
                )
            }
            BoundLibraryOnboardingStore.shared.recordPlayback(
                source: document.sourceKind,
                seconds: rawPlaybackDelta
            )
            // Reject media-position jumps before converting to wall-clock time;
            // a high playback rate must not make a seek look like real listening.
            if rawPlaybackDelta <= ResumeReminderPolicy.maxTrustedDelta {
                historyStore.recordListening(seconds: rawPlaybackDelta / Double(max(audio.playbackRate, 0.25)),
                    for: readingProgressID, boundary: progressBoundaryToken, variant: readingProgressVariant)
            }
            ResumeReminderManager.shared.recordPlayback(
                documentID: readingProgressID,
                title: document.title,
                seconds: rawPlaybackDelta
            )
            GrowthLoopConversionCoordinator.shared.recordPlayback(
                document: document,
                seconds: rawPlaybackDelta
            )
        }

        for milestone in update.newlyReachedMilestones {
            if milestone >= 300 { ProductAnalytics.shared.noteMeaningfulReadReached() }
            ProductAnalytics.shared.track(
                .readMilestone,
                context: analyticsEventContext,
                properties: .init(
                    milestoneSeconds: milestone,
                    playbackSeconds: Int(update.playbackSeconds),
                    completionBucket: analyticsCompletionBucket,
                    storefront: analyticsContext.storefront
                )
            )
        }
    }

    @discardableResult
    func finishLogicalAnalyticsSession(
        result: AnalyticsResult,
        reason: String,
        errorStage: String? = nil,
        errorCode: String? = nil
    ) -> Bool {
        endAnalyticsReadSession(
            result: result,
            reason: reason,
            errorStage: errorStage,
            errorCode: errorCode
        )
    }

    @discardableResult
    private func endAnalyticsReadSession(
        result: AnalyticsResult,
        reason: String,
        errorStage: String? = nil,
        errorCode: String? = nil,
        preserveAppReviewReadSession: Bool = false
    ) -> Bool {
        guard let ended = analyticsSessionCoordinator.end(
            ownerID: analyticsSessionOwnerID
        ) else { return false }
        ProductAnalytics.shared.track(
            .readEnd,
            context: analyticsEventContext(readSessionID: ended.sessionID),
            properties: .init(
                result: result.rawValue,
                errorStage: errorStage,
                errorCode: errorCode,
                playbackSeconds: Int(ended.playbackSeconds),
                completionBucket: analyticsCompletionBucket,
                endReason: reason,
                storefront: analyticsContext.storefront
            )
        )
        if !preserveAppReviewReadSession {
            appReviewReadSession = AppReviewReadSessionProgress()
            preserveAppReviewSessionOnNextAnalyticsBegin = false
            onAppReviewReadSessionInvalidated?()
        }
        return true
    }

    private var analyticsEventContext: AnalyticsEventContext {
        analyticsEventContext(readSessionID: analyticsReadSessionId)
    }

    private func analyticsEventContext(readSessionID: String?) -> AnalyticsEventContext {
        let surface: String
        switch document.sourceKind {
        case .kindle: surface = "kindle_reader"
        case .youtube: surface = "youtube_transcript"
        default: surface = "reader"
        }
        return AnalyticsEventContext(
            productArea: .readAloud,
            surface: surface,
            entryPoint: analyticsContext.entryPoint,
            contentSessionId: analyticsContext.contentSessionId,
            readSessionId: readSessionID
        )
    }

    private var analyticsCompletionBucket: String {
        guard let position = readableIndices.firstIndex(of: currentParagraphIndex) else { return "unknown" }
        return ProductAnalytics.completionBucket(completed: position + 1, total: readableIndices.count)
    }

    private static func analyticsErrorCode(_ error: Error) -> String {
        if let ttsError = error as? TTSError { return ttsError.analyticsCode }
        if error is URLError { return "network" }
        if error is CancellationError { return "cancelled" }
        let description = String(describing: error).lowercased()
        if description.contains("401") { return "http_401" }
        if description.contains("402") { return "http_402" }
        if description.contains("429") { return "http_429" }
        if description.contains("timeout") { return "timeout" }
        return "tts_failed"
    }

    // MARK: - 额度计时

    private func accountListen(_ t: Double) {
        guard let seg = audio.currentSegment else { return }
        guard YouTubePersistentAudioQuotaPolicy.shouldAccount(
            sourceKind: document.sourceKind,
            persistentCacheHit: youtubeQuotaExemptParagraphs.contains(seg.paragraphIndex)
        ) else {
            // `accountListen` only retains billable segments. Crossing into a
            // persisted YouTube paragraph therefore flushes the previous
            // billable delta once, then leaves replay entirely unmetered.
            if !lastSegmentId.isEmpty { commitListen() }
            return
        }
        if seg.id == lastSegmentId {
            if t > lastSegmentMaxTime { lastSegmentMaxTime = t }
        } else {
            commitListen()
            lastSegmentId = seg.id
            lastSegmentBaselineTime = 0
            lastSegmentMaxTime = t
        }
        // 宽限硬上限：超额后继续播放累计，超过 graceCap 强制停止
        if !pro.isPro && quota.listenRemaining <= 0 {
            if graceSeconds > quota.graceCapSeconds {
                refreshAccessThenHandleListenCap()
            }
        }
    }

    private func primeListenAccounting(segmentID: String, position: Double) {
        commitListen()
        lastSegmentId = segmentID
        lastSegmentBaselineTime = max(0, position)
        lastSegmentMaxTime = max(0, position)
    }

    private func refreshAccessThenHandleListenCap() {
        guard listenCapRefreshTask == nil else { return }
        status = .loading
        listenCapRefreshTask = Task { [weak self] in
            await ProManager.shared.refresh()
            guard let self else { return }
            self.listenCapRefreshTask = nil
            if self.pro.isPro {
                self.graceSeconds = 0
                self.applySpeed()
                self.status = .ready
            } else {
                if let token = self.audioSessionToken {
                    _ = self.audio.pause(session: token)
                }
                self.status = .ready
                self.showPaywall = true
                self.endAnalyticsReadSession(result: .blocked, reason: "listen_quota")
            }
        }
    }

    private func commitListen() {
        let delta = max(0, lastSegmentMaxTime - lastSegmentBaselineTime)
        guard delta > 0 else {
            lastSegmentBaselineTime = 0
            lastSegmentMaxTime = 0
            lastSegmentId = ""
            return
        }
        if !pro.isPro && quota.listenRemaining <= 0 {
            graceSeconds += delta
        }
        quota.addListen(delta)
        lastSegmentBaselineTime = 0
        lastSegmentMaxTime = 0
        lastSegmentId = ""
    }

    // MARK: - 供 TextReaderView 取每段显示文本

    func displayText(for paragraphIndex: Int) -> String {
        if paragraphIndex == currentParagraphIndex,
           let processed = processedDisplayText, !processed.isEmpty {
            return processed
        }
        return paras[paragraphIndex].text
    }
}

#if DEBUG
// 预取架构自测钩子（仅 DEBUG，供 EvalTests 验证预生成/预加载状态机，不影响发布构建）。
extension ReadAloudViewModel {
    var dbgReadableIndices: [Int] { readableIndices }
    var dbgPrefetchingIndex: Int? { prefetchingIndex }
    var dbgPrefetchedIndex: Int? { prefetchedIndex }
    var dbgPrefetchedSegments: [AudioSegment] { prefetchedSegments }
    var dbgKindlePrefetchIndices: [Int] { readAheadStreams.keys.filter { $0 > currentParagraphIndex }.sorted() }
    var dbgKindleReadyIndices: [Int] { kindlePrefetchedSegments.keys.sorted() }
    func dbgSegments(for i: Int) -> [AudioSegment] { segmentsByParagraph[i] ?? [] }
    func dbgPreloadNext(after i: Int) async {
        activate()
        preloadNext(after: i)
    }
    func dbgWaitPrefetch() async { _ = await prefetchTask?.value }
    func dbgPromote(to i: Int) {
        activate()
        promotePrefetch(to: i)
    }
    func dbgGenerate(_ i: Int) {
        activate()
        generate(i)
    }
    func dbgWaitGeneration() async { _ = await generationTask?.value }
    func dbgRefreshAccessThenRetryAdvance(refresh: @escaping @MainActor () async -> Void) {
        refreshAccessThenRetryAdvance(refresh: refresh)
    }
    var dbgIsAwaitingAccessRefresh: Bool { accessRetryTask != nil }
}
#endif
