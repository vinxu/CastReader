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
    @Published var isBuffering: Bool = false
    @Published var status: TTSStatus = .pending
    @Published var isFinished = false      // 全部段落播完 → Mini Player 显示「已播完」+ 点播放从头重读
    @Published var showPaywall: Bool = false
    @Published var autoScrollEnabled: Bool = true

    private let audio = AudioPlayerService.shared
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
    private var prefetchingIndex: Int? = nil     // 正在预取中的段
    private var prefetchedIndex: Int? = nil       // 已预取完成、可秒接的段
    private var prefetchedSegments: [AudioSegment] = []
    /// `true` only when the prepared paragraph came from the persistent
    /// YouTube TTS cache. Freshly generated prefetches remain billable even
    /// after their bytes are persisted for a future replay.
    private var prefetchedYouTubeAudioIsQuotaExempt = false

    // .web 源：段落由 WebView extractor 提取后注入；朗读输出经 bridge 驱动 DOM 高亮。
    private var webParagraphs: [ReadingParagraph]? = nil
    private var webLanguage: String? = nil
    private var deferredWebAutoplay = DeferredAutoplayGate()
    private var preferredLiveWebStartIndex: Int?
    private struct PendingLiveWebResume {
        let anchor: WeReadPlaybackResumeAnchor
        let paragraphIndex: Int
    }
    private var pendingLiveWebResume: PendingLiveWebResume?
    private var isAwaitingLiveWebCarryCompletion = false
    private var pendingLiveWebCarryStartIndex: Int?
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
        audio.onPlaybackError = { [weak self] message in
            guard let self, self.ownsAudioQueue else { return }
            ReaderRunLog.write(
                "READ playback error para=\(self.currentParagraphIndex) " +
                "error=\(message)"
            )
            self.status = .error(AppLocalized("音频播放失败，请重试"))
            self.endAnalyticsReadSession(
                result: .failed,
                reason: "audio_playback_failed",
                errorStage: "player",
                errorCode: "player_item_failed"
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
        analyticsSessionCoordinator: ReadAnalyticsSessionCoordinator? = nil
    ) {
        self.document = document
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

    /// A speculative next-page cache must never bypass the ordinary listen
    /// quota gate merely because its audio was generated early.
    var canContinueAcrossLivePageBoundary: Bool {
        pro.isPro || quota.canStartListen(isPro: pro.isPro)
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
        guard !isPlaying, !isFinished else { return false }
        if isBuffering { return true }
        return (status.isLoading || status.isStreaming)
            && !audio.hasPlayableAudio
    }

    /// A confirmed manual page turn should continue only when the user was
    /// actually listening, or when a user-started TTS request had not produced
    /// its first audio item yet. Merely owning the current reader mode does not
    /// count: a deliberately paused page must stay paused after the turn.
    var shouldResumeAfterManualLivePageTurn: Bool {
        if accessRetryTask != nil { return true }
        guard isActive, !isFinished else { return false }
        if ownsAudioQueue, audio.isPlaying { return true }
        guard ownsAudioQueue else {
            return status.isLoading || status.isStreaming || isBuffering
        }
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
        clearPrefetch()

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

        photoHighlightWordRange = mapped..<(mapped + 1)
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
        generationTask?.cancel()
        listenCapRefreshTask?.cancel()
        accessRetryTask?.cancel()
        prefetchPromotionTask?.cancel()
        prefetchTask?.cancel()
    }

    private func invalidateAccessRetry() {
        accessRetryEpoch &+= 1
        accessRetryTask?.cancel()
        accessRetryTask = nil
    }

    private func recomputeReadableIndices() {
        readableIndices = paras.enumerated()
            .filter {
                $0.element.type.isReadable &&
                    SpeechTextSanitizer.containsSpeakableContent(
                        $0.element.resolvedSpeechText
                    )
            }
            .map { $0.offset }
    }

    /// .web：注入 WebView extractor 提取的正文段落，准备朗读。
    func loadWebParagraphs(
        _ p: [ReadingParagraph],
        language: String? = nil,
        weReadBoundary: WeReadPageSpeechBoundary? = nil
    ) {
        webParagraphs = p
        if let language { webLanguage = language }
        weReadSpeechBoundary = weReadBoundary
        if !isActive, currentParagraphIndex < 0 {
            playbackVoiceID = settings.voice(for: docLanguage)
        }
        webAudioSegments = []
        recomputeReadableIndices()
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
        invalidateAccessRetry()
        generationEpoch &+= 1
        liveWebTurnIntentSuspended = false
        generationTask?.cancel()
        generationTask = nil
        clearPrefetch()
        webParagraphs = p
        if let language { webLanguage = language }
        weReadSpeechBoundary = weReadBoundary
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
        let token = ensureAudioSessionClaim()
        invalidateAccessRetry()
        generationEpoch &+= 1
        liveWebTurnIntentSuspended = false
        generationTask?.cancel()
        generationTask = nil
        clearPrefetch()
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
        if autoplay, !readableIndices.isEmpty {
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
        invalidateAccessRetry()
        generationEpoch &+= 1
        generationTask?.cancel()
        generationTask = nil
        clearPrefetch()
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
    /// the old page's final natural sentence is still playing. No speculative
    /// audio is required: when that immutable carry segment completes, normal
    /// generation begins at the first unconsumed paragraph on the new page.
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

        invalidateAccessRetry()
        generationEpoch &+= 1
        generationTask?.cancel()
        generationTask = nil
        clearPrefetch()
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
        return true
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

    // MARK: - Bind

    private func bind() {
        audio.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.onTick(t) }
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
        settings.$voicesByLanguage
            .combineLatest(settings.$clonedVoicesByLanguage)
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
        clearPrefetch()
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
        start(allowAccessRefresh: true)
    }

    private func start(allowAccessRefresh: Bool) {
        liveWebTurnIntentSuspended = false
        guard !readableIndices.isEmpty else { status = .error(AppLocalized("无可朗读内容")); return }
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
        generate(
            preferred ?? readableIndices[0],
            allowAccessRefresh: allowAccessRefresh
        )
    }

    func togglePlayPause() {
        liveWebTurnIntentSuspended = false
        if currentParagraphIndex < 0 { start(); return }
        if case .error = status {
            generate(currentParagraphIndex)
            return
        }
        // A second tap while the first cloud request is still waiting for
        // playable audio is not a retry. Restarting it cancels valid work and
        // makes a slow network request take roughly twice as long.
        if (status.isLoading || status.isStreaming || isBuffering),
           audio.currentSegment == nil,
           !audio.hasQueuedSegments {
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
        if !audio.isPlaying, !audio.hasQueuedSegments, audio.currentSegment == nil, !isFinished {
            generate(currentParagraphIndex)
            return
        }
        if let token = audioSessionToken {
            _ = audio.togglePlayPause(session: token)
        }
    }

    /// Idempotent entry-point for external "Continue Listening" actions.
    /// Reattaching while audio is playing or TTS is still loading must not pause
    /// playback or start a duplicate generation request.
    func ensurePlaying() {
        liveWebTurnIntentSuspended = false
        if ownsAudioQueue, audio.isPlaying { return }
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
        if (status.isLoading || isBuffering || status.isStreaming),
           audio.currentSegment == nil,
           !audio.hasQueuedSegments {
            return
        }
        guard currentAudioIsQuotaExempt
                || pro.isPro
                || quota.canStartListen(isPro: pro.isPro) else {
            refreshAccessThenRetryResume()
            return
        }
        invalidateAccessRetry()
        if audio.currentSegment != nil || audio.hasQueuedSegments {
            beginAnalyticsReadSessionIfNeeded(resume: true)
            if let token = audioSessionToken {
                _ = audio.play(session: token)
            }
        } else if !isFinished {
            jump(to: currentParagraphIndex)
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
            clearPrefetch()
            _ = audio.clearQueue(session: token)
            _ = audio.setMoreSegmentsExpected(false, session: token)
            _ = audio.loadSegments(
                cached,
                autoPlay: true,
                session: token
            )
            isFinished = false
            status = .ready
        case .regenerateParagraph:
            generate(currentParagraphIndex)
        }
    }

    /// 点击段落跳读。
    func jump(to paragraphIndex: Int) {
        jump(to: paragraphIndex, allowAccessRefresh: true)
    }

    private func jump(to paragraphIndex: Int, allowAccessRefresh: Bool) {
        guard readableIndices.contains(paragraphIndex) else { return }
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
        guard readableIndices.contains(paragraphIndex), !segments.isEmpty else {
            jump(to: paragraphIndex)
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
        clearPrefetch()

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
        if let requestedID = initialSegmentID,
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
        accessRetryTask = Task { [weak self] in
            await ProManager.shared.refresh()
            guard let self,
                  !Task.isCancelled,
                  self.accessRetryEpoch == retryEpoch,
                  self.isActive,
                  self.currentParagraphIndex == paragraphIndex else { return }
            self.accessRetryTask = nil
            if self.currentAudioIsQuotaExempt
                || self.pro.isPro
                || self.quota.canStartListen(isPro: self.pro.isPro) {
                self.beginAnalyticsReadSessionIfNeeded(resume: true)
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
    }

    /// Stops playback synchronously and returns the final YouTube persistence
    /// fence. Callers that own a lifecycle boundary may await the task; legacy
    /// UI call sites can safely ignore it because the VM retains the lane tail.
    @discardableResult
    func stop() -> Task<Void, Never>? {
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
        listenCapRefreshTask?.cancel()
        listenCapRefreshTask = nil
        clearPrefetch()
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

    private func generate(
        _ index: Int,
        voiceOverride: String? = nil,
        autoPlay: Bool = true,
        voiceSwitchID: UUID? = nil,
        allowAccessRefresh: Bool = true
    ) {
        guard isActive, paras.indices.contains(index) else { return }
        guard let session = ensureAudioSessionClaim() else { return }
        if document.sourceKind == .youtube {
            // A manual jump or voice switch can replace the player before its
            // next tick. Commit the previous fresh paragraph now so the cache-
            // miss authorization below observes the true remaining quota.
            // Persisted replay never enters the listen accumulator.
            commitListen()
        }
        invalidateAccessRetry()
        isAwaitingLiveWebCarryCompletion = false
        pendingLiveWebCarryStartIndex = nil
        generationEpoch &+= 1
        let epoch = generationEpoch
        let voice = voiceOverride ?? settings.voice(for: docLanguage)
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
        clearPrefetch()   // 重新生成某段 → 作废旧预取

        _ = audio.clearQueue(session: session)
        _ = audio.setMoreSegmentsExpected(true, session: session)
        setYouTubeAudioQuotaOrigin(
            paragraphIndex: index,
            persistentCacheHit: false
        )
        retainYouTubeAudioMemory(for: index)
        segmentsByParagraph[index] = []
        youtubeCompletionSubmittedParagraph = nil
        currentParagraphIndex = index
        processedDisplayText = nil
        highlightRange = nil
        photoHighlightWordIndex = nil
        photoHighlightWordRange = nil
        pdfHighlight = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        status = .loading

        let para = paras[index]
        generationTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try Task.checkCancellation()
                guard await self.authorizeFreshYouTubeGeneration(
                    paragraphIndex: index,
                    epoch: epoch,
                    session: session,
                    allowAccessRefresh: allowAccessRefresh
                ) else { return }
                NSLog("CRDBG generate request begin para=%d voice=%@ epoch=%llu", index, voice, epoch)
                try await TTSService.shared.generateTTSForParagraph(
                    paragraphIndex: index,
                    text: SpeechTextSanitizer.sanitizedForTTS(
                        para.resolvedSpeechText
                    ),
                    voice: voice,
                    speed: 1.0,                       // 1.0 生成，播放用 playbackRate
                    language: self.docLanguage,
                    includeVoiceCode: self.includeVoiceCodeForTTS,
                    speaker: para.speaker
                ) { [weak self] segment in
                    self?.appendSegment(
                        segment,
                        paragraph: index,
                        epoch: epoch,
                        session: session,
                        autoPlay: autoPlay,
                        voiceSwitchID: voiceSwitchID
                    )
                }
                await MainActor.run {
                    guard self.generationEpoch == epoch,
                          self.currentParagraphIndex == index,
                          self.audioSessionToken == session,
                          self.audio.isPlaybackSessionActive(session) else { return }
                    self.finishPendingLiveWebResumeIfNeeded(
                        paragraph: index,
                        session: session
                    )
                    _ = self.audio.finishStreamingProducer(session: session)
                    self.status = .ready
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
                    if let voiceSwitchID, self.activeVoiceSwitchID == voiceSwitchID {
                        VoiceSwitchStatusCenter.shared.finish(voiceSwitchID)
                        self.activeVoiceSwitchID = nil
                    }
                }
                if self.generationEpoch == epoch,
                   self.currentParagraphIndex == index,
                   self.audioSessionToken == session,
                   self.audio.isPlaybackSessionActive(session),
                   self.isActive {
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
                    _ = self.audio.setMoreSegmentsExpected(false, session: session)
                    if self.currentParagraphIndex == index {
                        ReaderRunLog.write(
                            "READ generate failed para=\(index) epoch=\(epoch) " +
                            "error=\(error.localizedDescription)"
                        )
                        self.status = .error(error.localizedDescription)
                        if let voiceSwitchID, self.activeVoiceSwitchID == voiceSwitchID {
                            VoiceSwitchStatusCenter.shared.finish(voiceSwitchID)
                            self.activeVoiceSwitchID = nil
                        }
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

    private func appendSegment(
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
        if let pending = pendingLiveWebResume,
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
        status = .streaming
        // Start the next paragraph as soon as the current paragraph has yielded
        // its first playable item. Waiting for the entire current request to
        // finish wastes most of the audible lead time on multi-part paragraphs.
        if segs.count == 1 {
            preloadNext(after: paragraph)
        }
        if let voiceSwitchID, activeVoiceSwitchID == voiceSwitchID {
            VoiceSwitchStatusCenter.shared.finish(voiceSwitchID)
            activeVoiceSwitchID = nil
        }
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
        if let voiceSwitchID, activeVoiceSwitchID == voiceSwitchID {
            VoiceSwitchStatusCenter.shared.finish(voiceSwitchID)
            activeVoiceSwitchID = nil
        }
    }

    private func handleVoicePreferenceChanged(forceRestart: Bool = false) {
        let newVoiceID = settings.voice(for: docLanguage)
        guard forceRestart || newVoiceID != playbackVoiceID else { return }
        let oldVoiceID = playbackVoiceID
        playbackVoiceID = newVoiceID

        guard isActive,
              currentParagraphIndex >= 0,
              readableIndices.contains(currentParagraphIndex),
              !isFinished else { return }

        let previewHadSuspendedPlayback = VoicePreviewPlaybackCoordinator.shared.cancelForVoiceSwitch()
        VoiceSamplePlayer.shared.stop(resumeSuspendedPlayback: false)
        VoiceClonePreviewPlayer.shared.stop(resumeSuspendedPlayback: false)
        let shouldAutoPlay = audio.isPlaying ||
            audio.isQueuedSegmentGated ||
            previewHadSuspendedPlayback ||
            status.isLoading ||
            (status.isStreaming && audio.currentSegment == nil && !audio.hasQueuedSegments)
        NotificationCenter.default.post(
            name: .castReaderPlaybackVoiceWillSwitch,
            object: self,
            userInfo: [
                "language": VoiceCatalog.normalizedLanguage(docLanguage),
                "fromVoiceID": oldVoiceID,
                "toVoiceID": newVoiceID,
            ]
        )
        let switchID = VoiceSwitchStatusCenter.shared.begin(
            language: docLanguage,
            from: oldVoiceID,
            to: newVoiceID
        )
        activeVoiceSwitchID = switchID
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
            currentParagraphIndex,
            voiceOverride: newVoiceID,
            autoPlay: shouldAutoPlay,
            voiceSwitchID: switchID
        )
    }

    /// 当前段生成完后调用：后台预生成下一段 TTS 到缓存（不入队播放），advance 命中时秒接，消除段间等首字节的 gap。
    private func preloadNext(after index: Int) {
        guard isActive else { return }
        guard let pos = readableIndices.firstIndex(of: index) else { return }
        let nextPos = pos + 1
        guard nextPos < readableIndices.count else { return }
        let nextIndex = readableIndices[nextPos]
        if prefetchingIndex == nextIndex || prefetchedIndex == nextIndex { return }   // 已在预取/已就绪
        startPrefetch(nextIndex)
    }

    /// 后台生成 nextIndex 段的全部 segment 到 `prefetchedSegments`（不碰播放器，
    /// 也不参与 TTSService 的前台 currentRequestId 所有权）。
    private func startPrefetch(_ nextIndex: Int) {
        guard isActive, nextIndex >= 0, nextIndex < paras.count else { return }
        prefetchTask?.cancel()
        prefetchingIndex = nextIndex
        prefetchedIndex = nil
        prefetchedSegments = []
        prefetchedYouTubeAudioIsQuotaExempt = false
        let epoch = generationEpoch
        let para = paras[nextIndex]
        let voice = settings.voice(for: docLanguage)
        let lang = docLanguage
        let includeVoiceCode = includeVoiceCodeForTTS
        NSLog("CRDBG prefetch start para=%d", nextIndex)
        ReaderRunLog.write(
            "READ prefetch start para=\(nextIndex) epoch=\(epoch) " +
            "chars=\(para.resolvedSpeechText.utf16.count)"
        )
        prefetchTask = Task { [weak self] in
            do {
                if let self,
                   self.document.sourceKind == .youtube,
                   !self.canStartAudio(persistentYouTubeCacheHit: false) {
                    if self.generationEpoch == epoch,
                       self.prefetchingIndex == nextIndex {
                        self.prefetchingIndex = nil
                    }
                    return
                }
                let collected = try await TTSService.shared.generatePrefetchSegments(
                    paragraphIndex: nextIndex,
                    text: SpeechTextSanitizer.sanitizedForTTS(
                        para.resolvedSpeechText
                    ),
                    voice: voice,
                    speed: 1.0,
                    language: lang,
                    includeVoiceCode: includeVoiceCode,
                    speaker: para.speaker
                )
                guard let self,
                      !Task.isCancelled,
                      self.isActive,
                      self.generationEpoch == epoch,
                      self.prefetchingIndex == nextIndex else { return }
                // Publish the generated segments before doing cache I/O. The
                // player may reach this paragraph while the cache actor is
                // pruning/scanning a large store; playback must not wait for it.
                self.prefetchedSegments = collected
                self.prefetchedIndex = nextIndex
                self.prefetchingIndex = nil
                // Do the disk write and asset parse now, while the current
                // paragraph is still playing. At the boundary this is the
                // difference between ~70ms of silence and almost none.
                self.audio.prestageSegments(collected)
                self.prefetchedYouTubeAudioIsQuotaExempt = false
                NSLog("CRDBG prefetch done para=%d segs=%d", nextIndex, collected.count)
                ReaderRunLog.write(
                    "READ prefetch done para=\(nextIndex) epoch=\(epoch) " +
                    "segs=\(collected.count)"
                )
            } catch {
                guard let self,
                      self.generationEpoch == epoch,
                      self.prefetchingIndex == nextIndex else { return }
                self.prefetchingIndex = nil
                ReaderRunLog.write(
                    "READ prefetch failed para=\(nextIndex) epoch=\(epoch) " +
                    "error=\(error.localizedDescription)"
                )
            }
        }
    }

    /// 取消并清空预取缓存（jump / stop / 重新 generate 时）。
    private func clearPrefetch() {
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
        guard let session = ensureAudioSessionClaim() else { return }
        let segs = prefetchedSegments
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

        // 完整缓存一次性入队；无 moreSegmentsExpected，播完正常 advance。
        _ = audio.setMoreSegmentsExpected(false, session: session)
        _ = audio.loadSegments(
            segs,
            autoPlay: !liveWebTurnIntentSuspended,
            session: session
        )
        status = .ready

        // 立即预取再下一段，保持「始终领先一段」。
        preloadNext(after: index)
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
        guard isActive else {
            ReaderRunLog.write(
                "READ advance ignored reason=inactive para=\(currentParagraphIndex)"
            )
            return
        }
        if isAwaitingLiveWebCarryCompletion {
            let startIndex = pendingLiveWebCarryStartIndex
            isAwaitingLiveWebCarryCompletion = false
            pendingLiveWebCarryStartIndex = nil
            commitListen()
            if let startIndex {
                ReaderRunLog.write("WEREAD carry completed; continue para=\(startIndex)")
                generate(startIndex)
            } else {
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
        if document.sourceKind == .youtube,
           prefetchingIndex == nextIndex,
           let task = prefetchTask {
            status = .loading
            ReaderRunLog.write(
                "READ boundary waiting YouTube cache origin from=\(currentParagraphIndex) " +
                "next=\(nextIndex)"
            )
            let epoch = generationEpoch
            let sourceParagraphIndex = currentParagraphIndex
            prefetchPromotionTask?.cancel()
            prefetchPromotionTask = Task { [weak self] in
                _ = await task.value
                guard let self,
                      !Task.isCancelled,
                      self.isActive,
                      self.generationEpoch == epoch,
                      self.currentParagraphIndex == sourceParagraphIndex else { return }
                self.prefetchPromotionTask = nil
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
            prefetchPromotionTask?.cancel()
            prefetchPromotionTask = Task { [weak self] in
                _ = await task.value
                guard let self,
                      !Task.isCancelled,
                      self.isActive,
                      self.generationEpoch == epoch,
                      self.currentParagraphIndex == sourceParagraphIndex else { return }
                self.prefetchPromotionTask = nil
                if self.prefetchedIndex == nextIndex, !self.prefetchedSegments.isEmpty {
                    self.promotePrefetch(to: nextIndex)
                } else {
                    ReaderRunLog.write(
                        "READ boundary prefetch miss next=\(nextIndex); foreground generate"
                    )
                    self.generate(
                        nextIndex,
                        allowAccessRefresh: allowAccessRefresh
                    )
                }
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

    private func refreshAccessThenRetryAdvance() {
        status = .loading
        if let token = audioSessionToken {
            _ = audio.pause(session: token)
        }
        invalidateAccessRetry()
        let retryEpoch = accessRetryEpoch
        let paragraphIndex = currentParagraphIndex
        accessRetryTask = Task { [weak self] in
            await ProManager.shared.refresh()
            guard let self,
                  !Task.isCancelled,
                  self.accessRetryEpoch == retryEpoch,
                  self.isActive,
                  self.currentParagraphIndex == paragraphIndex else { return }
            self.accessRetryTask = nil
            self.advance(allowAccessRefresh: false)
        }
    }

    // MARK: - 高亮

    private func onTick(_ t: Double) {
        guard ownsAudioQueue else { return }
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
        TTSTimestampQuality.hasReliableWordGranularity(
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
                                                segSeq: segPos))
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
                let range = next..<(next + 1)
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
        ocrWordIndexes = OCRWordAligner.mapTimestampWords(
            in: document.paragraphs[currentParagraphIndex],
            segments: segs,
            allowFallback: allowFallback,
            allowBoundedFallback: document.sourceKind == .kindle
        )
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
        let ownedPlaying = playing && ownsAudioQueue
        isPlaying = ownedPlaying
        guard ownedPlaying else {
            analyticsSessionCoordinator.resetPlaybackCursor(
                ownerID: analyticsSessionOwnerID
            )
            return
        }
        guard audio.currentSegment != nil,
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
            ResumeReminderManager.shared.recordPlayback(
                documentID: document.id,
                title: document.title,
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
}
#endif
