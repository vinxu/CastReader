//
//  ExplainViewModel.swift
//  CastReader
//
//  解读编排：extract-plan(SSE) → 逐块 extract-block → TTS 讲解 → compose-block 回填 at → 入队播放。
//  播放中按「块时间线」elapsed 触发 marks，用 MarkAnchoring 锚定到原文，交 reader 画手写标注。
//

import Foundation
import Combine
import CryptoKit

enum ExplainOwnershipRecoveryPlan: Equatable {
    case preparedBlock(index: Int)
    case replayBlock(index: Int)
    case restartPlanning(reusingStartedSession: Bool)

    static func resolve(
        currentBlockIndex: Int,
        hasCurrentPreparedBlock: Bool,
        replayBlockCount: Int,
        statusIsActive: Bool
    ) -> Self {
        if currentBlockIndex >= 0, hasCurrentPreparedBlock {
            return .preparedBlock(index: currentBlockIndex)
        }
        if replayBlockCount > 0 {
            let index = min(max(0, currentBlockIndex), replayBlockCount - 1)
            return .replayBlock(index: index)
        }
        return .restartPlanning(reusingStartedSession: statusIsActive)
    }
}

/// Pure hand-off contract between the fast opening and the quality plan.
///
/// The quality lane must receive only the physical suffix after `opening`.
/// Keeping this as a small value type makes the no-overlap/index contract
/// independently testable without starting networking or TTS.
struct QuickReadFastLaneHandoff {
    struct ScopeDigest: Equatable {
        let paragraphCount: Int
        let characterCount: Int
        let fingerprint: String
    }

    let opening: [ReadingParagraph]
    let qualityInput: [ReadingParagraph]
    let previousSummary: String
    let indexBase: Int

    init?(
        readableParagraphs: [ReadingParagraph],
        selectedOpening: [ReadingParagraph],
        fastNarration: String
    ) {
        let trimmedNarration = fastNarration.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedOpening.isEmpty,
              selectedOpening.count < readableParagraphs.count,
              !trimmedNarration.isEmpty,
              Array(readableParagraphs.prefix(selectedOpening.count)) == selectedOpening else {
            return nil
        }

        let suffix = Array(readableParagraphs.dropFirst(selectedOpening.count))
        let openingIDs = Set(selectedOpening.map(\.id))
        let suffixIDs = Set(suffix.map(\.id))
        guard openingIDs.isDisjoint(with: suffixIDs) else { return nil }

        opening = selectedOpening
        qualityInput = suffix
        previousSummary = fastNarration
        indexBase = 1
    }

    var reindexedQualityInput: [ReadingParagraph] {
        qualityInput.enumerated().map {
            ReadingParagraph(id: $0.offset, text: $0.element.text, type: $0.element.type)
        }
    }

    var openingDigest: ScopeDigest { Self.scopeDigest(opening) }
    var qualityDigest: ScopeDigest { Self.scopeDigest(qualityInput) }

    static func qualityBlockIndex(
        forPlaybackBlockIndex playbackBlockIndex: Int,
        indexBase: Int
    ) -> Int? {
        guard playbackBlockIndex >= indexBase else { return nil }
        return playbackBlockIndex - indexBase
    }

    static func playbackBlockIndex(
        forQualityBlockIndex qualityBlockIndex: Int,
        indexBase: Int
    ) -> Int? {
        guard qualityBlockIndex >= 0, indexBase >= 0 else { return nil }
        return qualityBlockIndex + indexBase
    }

    static func continuitySummary(
        explicitPreviousSummary: String?,
        fastNarration: String?
    ) -> String? {
        if let explicitPreviousSummary,
           !explicitPreviousSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicitPreviousSummary
        }
        if let fastNarration,
           !fastNarration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fastNarration
        }
        return nil
    }

    static func scopeDigest(_ paragraphs: [ReadingParagraph]) -> ScopeDigest {
        // IDs are intentionally excluded: the quality suffix is reindexed
        // before transport, while its content fingerprint must remain stable.
        let canonical = paragraphs.map(\.text).joined(separator: "\u{1e}")
        let fingerprint = SHA256.hash(data: Data(canonical.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return ScopeDigest(
            paragraphCount: paragraphs.count,
            characterCount: paragraphs.reduce(0) { $0 + $1.text.count },
            fingerprint: fingerprint
        )
    }
}

/// 已锚定、可绘制的标注（charRange 为段落文本的 Character 偏移）。
struct ResolvedMark: Identifiable, Equatable {
    let id: UUID
    let paragraphIndex: Int
    let charRange: Range<Int>
    let action: String
    let n: Int?
    let seed: UInt64
    var weight: String? = nil   // P1：重要度分层（primary/secondary/tertiary）→ 笔触粗细
    var role: String? = nil     // P1：语义角色（key/caution/term/example），透传
}

@MainActor
final class ExplainViewModel: ObservableObject {

    let document: ReadingDocument
    let analyticsContext: AnalyticsContentContext

    /// 场景 content_type（从首页场景入口进入时设置；通用 ➕ 导入为 nil）。仅决定后端「划什么/怎么批」prompt 分支，
    /// 与解读深度正交、**不影响 depth**（depth 始终 = 用户设置的 3 档）。由 PlayerCoordinator.open(scenario:) 注入。
    /// 内部可见（仅供单测断言「场景不覆盖深度」）。
    var scenario: String? = nil

    private var playbackBookID: String?
    private var playbackTitle: String?
    private var playbackChapterTitle: String?
    private var playbackCoverURL: String?
    var onDocumentFinished: (() -> Void)?

    /// 发给后端的解读深度：永远 = 用户在设置里选的 3 档（速览/标准/深入），场景绝不改它（content_type 与 depth 正交）。
    var requestDepth: String { settings.explainDepth }

    // .web 源：用 WebView extractor 提取的段落构成讲解/锚定文档（原始 document.paragraphs 为空）。
    private var webDoc: ReadingDocument? = nil
    private var deferredWebAutoplay = DeferredAutoplayGate()
    private var doc: ReadingDocument { webDoc ?? document }
    func loadWebParagraphs(_ p: [ReadingParagraph], language: String? = nil) {
        webDoc = ReadingDocument(id: document.id, title: document.title, sourceKind: .web,
                                 language: language ?? document.language, paragraphs: p, sourceURL: document.sourceURL)
        if deferredWebAutoplay.contentBecameReady(isReady: !doc.readableParagraphs.isEmpty) {
            ensurePlaying()
        }
    }

    /// Defers an explicit Explain request until WebKit has supplied anchorable
    /// paragraphs, while remaining useful for a second request on the same,
    /// already-loaded document.
    func requestAutoplayWhenWebReady() {
        if deferredWebAutoplay.request(isReady: !doc.readableParagraphs.isEmpty) {
            ensurePlaying()
        }
    }

    /// WebKit DOM Range consumes UTF-16 offsets, but `ResolvedMark` deliberately
    /// stays in document-level `Character` coordinates for native text/photo
    /// renderers. Convert against the current live page at the bridge boundary.
    func webUTF16Range(for mark: ResolvedMark) -> Range<Int>? {
        guard mark.paragraphIndex >= 0,
              mark.paragraphIndex < doc.paragraphs.count else { return nil }
        return MarkAnchoring.utf16Range(
            fromCharacterRange: mark.charRange,
            in: doc.paragraphs[mark.paragraphIndex].text
        )
    }

    /// Update the page-local explanation source while Read owns the shared
    /// player. This invalidates old plans/marks but deliberately avoids
    /// `stop()`, `audio.clearBook()`, and global TTS cancellation.
    func stageInactiveLiveWebPage(
        _ p: [ReadingParagraph],
        language: String? = nil
    ) {
        guard !isActive else { return }
        contentGeneration &+= 1
        accessRefreshRequestID &+= 1
        liveWebTurnIntentSuspended = false
        accessRefreshTask?.cancel()
        accessRefreshTask = nil
        orchestrationTask?.cancel()
        orchestrationTask = nil
        fastTask?.cancel()
        fastTask = nil
        clearPagePrefetch()
        prepared.removeAll()
        preparingBlocks.removeAll()
        marksByBlock.removeAll()
        replayBlocks.removeAll()
        firedMarks.removeAll()
        section0 = nil
        fastSection = nil
        jobId = ""
        totalBlocks = 0
        currentBlockIndex = -1
        explanationText = ""
        anchorCursor = nil
        completionNotified = false
        isPreparingNext = false
        isContinuingLivePage = false
        isReplayingCached = false
        loadWebParagraphs(p, language: language)
        activeMarks = []
        scrollTarget = -1
        stageText = ""
        status = .idle
    }

    var stagedLiveWebParagraphTexts: [String] {
        doc.paragraphs.map(\.text)
    }

    /// Live WebView sources (WeRead) cannot keep marks/plans from a previous
    /// canvas page.  Stop the old job, replace its anchor document, then start
    /// a new page-only explanation when the user had an active explain session.
    func replaceLiveWebPage(
        _ p: [ReadingParagraph],
        language: String? = nil,
        autoplay: Bool,
        prefetched: PrefetchedFirstBlock? = nil
    ) {
        // The bridge already captured whether playback was active before it
        // stopped the stale Canvas page.  Re-checking status here would always
        // turn autoplay back off because `stop()` has necessarily run first.
        let shouldRestart = autoplay
        stop()
        // A WeRead page is an independent explanation document. Never reuse
        // block 0, marks, or cached narration from the previous Canvas page.
        prepared.removeAll()
        preparingBlocks.removeAll()
        marksByBlock.removeAll()
        replayBlocks.removeAll()
        firedMarks.removeAll()
        section0 = nil
        jobId = ""
        totalBlocks = 0
        currentBlockIndex = -1
        explanationText = ""
        anchorCursor = nil
        completionNotified = false
        loadWebParagraphs(p, language: language)
        activeMarks = []
        scrollTarget = -1
        if shouldRestart {
            if let prefetched {
                startFromPrefetched(prefetched)
            } else {
                start()
            }
        }
    }

    @Published var status: ExplainStatus = .idle
    @Published var stageText: String = ""
    @Published var activeMarks: [ResolvedMark] = []
    @Published var currentBlockIndex: Int = -1
    @Published var explanationText: String = ""   // 当前块讲解文本（字幕用）
    @Published var showPaywall: Bool = false
    @Published var isPlaying: Bool = false
    @Published var scrollTarget: Int = -1         // 跟随讲解滚动到的段落（mark 命中时更新）
    @Published var isPreparingNext: Bool = false  // 块间等待下一段处理 → 控制条显示 loading，避免被误以为卡住
    /// Live paginated readers have finished the current Canvas page, but have
    /// not yet committed the next page.  `.completed` still represents the
    /// finished page internally; this flag prevents the UI from presenting it
    /// as the end of the whole document during the semantic-turn handshake.
    @Published private(set) var isContinuingLivePage: Bool = false
    @Published private(set) var playbackLanguage: String

    /// segment 的有效时长：云端 TTS 的 API duration 常为 0，用最后一个时间戳的 endTime 兜底。
    private func effectiveDuration(_ seg: AudioSegment) -> Double {
        if seg.duration > 0.01 { return seg.duration }
        return seg.timestamps.last?.endTime ?? 0
    }

    private let audio = AudioPlayerService.shared
    private let settings = AppSettings.shared
    private let pro = ProManager.shared
    private let quota = QuotaManager.shared
    private var audioSessionToken: AudioPlaybackSessionToken?

    fileprivate struct PreparedBlock {
        let segments: [AudioSegment]
        let marks: [QuickreadEvent]     // at 已填
        let text: String
        let sentences: [String]         // 讲解文本按句切分（字幕逐句显示，按播放进度推进）
    }

    struct PrefetchedFirstBlock {
        let jobId: String
        let totalBlocks: Int
        let outputLanguage: String
        let textFingerprint: String
        let previousSummary: String?
        fileprivate let section0: QuickreadSection
        fileprivate let block0: PreparedBlock
    }

    private var jobId: String = ""
    private var totalBlocks: Int = 0
    private var outputLanguage: String
    private var section0: QuickreadSection?
    private var playbackVoiceID: String
    private var activeVoiceSwitchID: UUID?
    private var voiceSwitchTask: Task<Void, Never>?

    private var prepared: [Int: PreparedBlock] = [:]
    private var preparingBlocks = Set<Int>()
    private var marksByBlock: [Int: [QuickreadEvent]] = [:]
    private var replayBlocks: [PreparedBlock] = []   // 完整解读播放轨道；跨 PDF/长文批次保留，供「重播」从头顺序播放
    private var isReplayingCached = false
    private var firedMarks = Set<String>()
    private var anchorCursor: Int? = nil
    private var markHit = 0, markTotal = 0   // mark 匹配成功率诊断（CRDBG）

    private func debugLog(_ format: String, _ args: CVarArg...) {
        #if DEBUG
        NSLog("CRDBG %@", String(format: format, arguments: args))
        #endif
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func kindlePerfLog(_ message: String) {
        guard doc.sourceKind == .kindle else { return }
        KindleRunLog.write("KINDLE explain perf \(message)")
    }

    // 快道（Fast-Lane）：快道占 block_0 秒开，质道吃剩余段、块顺延为 block_(idxBase+j)。idxBase=0 即未走快道（原单路）。
    private var idxBase = 0
    private var fastSection: QuickreadSection?
    private var block0Claimed = false
    private var didProjectServerExplainConsumption = false
    private var fastTask: Task<Void, Never>?
    private var forcedExplainLang: String?   // 快道激活时锁定语言（快道+质道同语言，避免开头/后续语言不一致）
    /// 质道 plan 失败标志（402/400/网络）：让 prepareBlock 的 section0 等待循环跳出，避免快道占位后死等挂起。
    private var planFailed = false
    private var planSettled = false
    private var completionNotified = false

    private var orchestrationTask: Task<Void, Never>?
    /// Membership refresh is part of a pending Start action. It must be owned
    /// by the same live-page generation; otherwise a late refresh can activate
    /// Explain after the user switched modes or replaced the page.
    private var accessRefreshTask: Task<Void, Never>?
    private var accessRefreshRequestID: UInt64 = 0
    /// Batch/page prefetch can include another TTS request. Keep the task so a
    /// page replacement can cancel it instead of merely ignoring its late
    /// result after it has already contended for the shared TTS service.
    private var pagePrefetchTask: Task<Void, Never>?
    /// A live-page replacement invalidates all plan/block work owned by the
    /// previous page. QuickRead callbacks and detached prefetches can outlive
    /// cooperative Task cancellation, so cancellation is not enough by itself.
    private var contentGeneration: UInt64 = 0
    private var liveWebTurnIntentSuspended = false
    private var cancellables = Set<AnyCancellable>()
    private(set) var isActive = false
    private var lastNowPlayingCaption: String?

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
        let token = audio.claimPlaybackSession(owner: .explain)
        audioSessionToken = token
        isPlaying = false
        return token
    }

    private func setMoreSegmentsExpected(_ expected: Bool) {
        guard let token = audioSessionToken else { return }
        _ = audio.setMoreSegmentsExpected(expected, session: token)
    }

    private func installAudioCompletionCallback() {
        audio.onPlaybackComplete = { [weak self] in
            guard let self, self.ownsAudioQueue else { return }
            self.onBlockComplete()
        }
        audio.onPlaybackError = { [weak self] _ in
            guard let self, self.ownsAudioQueue else { return }
            self.isPreparingNext = false
            self.status = .error(AppLocalized("音频播放失败，请重试"))
            self.endAnalyticsExplainSession(
                result: .failed,
                reason: "audio_playback_failed",
                errorStage: "player",
                errorCode: "player_item_failed"
            )
        }
    }
    private var analyticsExplainSessionId: String?
    private var analyticsExplainStartedAt: Date?
    private var analyticsFirstBlockTracked = false
    private var analyticsSecondBlockStarted = false
    private var analyticsFirstBlockCompleted = false
    private var analyticsBlocksStarted = Set<Int>()
    private var analyticsBlocksCompleted = Set<Int>()

    init(document: ReadingDocument, analyticsContext: AnalyticsContentContext? = nil) {
        self.document = document
        self.analyticsContext = analyticsContext ?? AnalyticsContentContext.fallback(for: document)
        let initialLanguage = VoiceCatalog.normalizedLanguage(
            AppSettings.shared.explainLangOrNil ?? document.language
        )
        self.outputLanguage = initialLanguage
        self.playbackLanguage = initialLanguage
        self.playbackVoiceID = AppSettings.shared.voice(for: initialLanguage)
        bind()
    }

    /// Explain speaks the generated narration, so its voice follows the
    /// requested output language rather than the source document language.
    var hasStartedPlayback: Bool {
        if currentBlockIndex >= 0 { return true }
        switch status {
        case .planning, .streaming, .completed:
            return true
        case .idle, .error:
            return false
        }
    }

    /// Preserve a user-started explanation across a confirmed manual page
    /// turn, while keeping an explicitly paused narration paused.
    var shouldResumeAfterManualLivePageTurn: Bool {
        if accessRefreshTask != nil { return true }
        guard isActive else { return false }
        if ownsAudioQueue, audio.isPlaying { return true }
        guard ownsAudioQueue else {
            switch status {
            case .planning, .streaming:
                return true
            case .idle, .error, .completed:
                return false
            }
        }
        switch status {
        case .planning:
            return true
        case .streaming:
            return audio.currentSegment == nil || isPreparingNext
        case .idle, .error, .completed:
            return false
        }
    }

    /// Freeze future block auto-start while Google is deciding whether a
    /// gesture actually changed the page. Generation/planning stays alive, so
    /// a cancelled edge swipe preserves work, marks, position, and quota.
    func suspendForLiveWebTurnIntent() {
        guard document.sourceKind.isLiveWebLibrary else { return }
        cancelPendingAccessRefreshForLiveWebTurn()
        liveWebTurnIntentSuspended = true
        guard isActive else { return }
        if let token = audioSessionToken {
            _ = audio.pause(session: token)
        }
    }

    func cancelPendingAccessRefreshForLiveWebTurn() {
        guard document.sourceKind.isLiveWebLibrary else { return }
        accessRefreshRequestID &+= 1
        accessRefreshTask?.cancel()
        accessRefreshTask = nil
        if stageText == AppLocalized("正在同步会员状态…") {
            stageText = ""
        }
    }

    func resumeAfterCancelledLiveWebTurnIntent() {
        guard liveWebTurnIntentSuspended else { return }
        liveWebTurnIntentSuspended = false
        guard isActive else {
            start()
            return
        }
        guard ownsAudioQueue else {
            recoverPlaybackAfterOwnershipChange()
            return
        }
        if audio.currentSegment != nil || audio.hasQueuedSegments {
            if let token = audioSessionToken {
                _ = audio.play(session: token)
            }
        }
    }

    func configurePlaybackMetadata(id: String, title: String, coverURL: String?, chapterTitle: String? = nil) {
        playbackBookID = id
        playbackTitle = title
        playbackCoverURL = coverURL
        playbackChapterTitle = chapterTitle
    }

    private func applyPlaybackMetadata() {
        audio.setBook(
            id: playbackBookID ?? document.id,
            title: playbackTitle ?? document.title,
            chapterTitle: playbackChapterTitle ?? AppLocalized("解读"),
            coverUrl: playbackCoverURL
        )
    }

    deinit {
        orchestrationTask?.cancel()
        accessRefreshTask?.cancel()
        pagePrefetchTask?.cancel()
        voiceSwitchTask?.cancel()
    }

    private func bind() {
        audio.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.onTick(t) }
            .store(in: &cancellables)
        audio.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.handleAnalyticsPlaybackState(p) }
            .store(in: &cancellables)
        // 与朗读统一：speed 改动（设置页滑杆 / 控制条倍速按钮）实时作用到解读播放，保证「显示 = 在播」。
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
        settings.$explainLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIdlePlaybackLanguage() }
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

    /// 应用全局语速到共享播放器（与 ReadAloudViewModel.applySpeed 对称，统一由 settings.speed 驱动）。
    private func applySpeed() {
        audio.setPlaybackRate(Float(settings.effectiveSpeed(isPro: pro.isPro)))
    }

    private func setOutputLanguage(_ language: String) {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard !normalized.isEmpty else { return }
        outputLanguage = normalized
        playbackLanguage = normalized
        playbackVoiceID = settings.voice(for: normalized)
    }

    private func refreshIdlePlaybackLanguage() {
        guard currentBlockIndex < 0, !isActive else { return }
        setOutputLanguage(settings.explainLangOrNil ?? doc.language)
    }

    private func handleVoicePreferenceChanged() {
        let newVoiceID = settings.voice(for: playbackLanguage)
        guard newVoiceID != playbackVoiceID else { return }
        let oldVoiceID = playbackVoiceID
        playbackVoiceID = newVoiceID

        guard isActive,
              currentBlockIndex >= 0,
              let original = prepared[currentBlockIndex] else { return }

        let blockIndex = currentBlockIndex
        let shouldAutoPlay = ownsAudioQueue && audio.isPlaying
        let previewHadSuspendedPlayback = VoicePreviewPlaybackCoordinator.shared.cancelForVoiceSwitch()
        VoiceSamplePlayer.shared.stop(resumeSuspendedPlayback: false)
        VoiceClonePreviewPlayer.shared.stop(resumeSuspendedPlayback: false)
        let resumeAfterSwitch = shouldAutoPlay || previewHadSuspendedPlayback

        voiceSwitchTask?.cancel()
        if let oldSwitchID = activeVoiceSwitchID {
            VoiceSwitchStatusCenter.shared.finish(oldSwitchID)
        }
        NotificationCenter.default.post(
            name: .castReaderPlaybackVoiceWillSwitch,
            object: self,
            userInfo: [
                "language": playbackLanguage,
                "fromVoiceID": oldVoiceID,
                "toVoiceID": newVoiceID,
            ]
        )
        let switchID = VoiceSwitchStatusCenter.shared.begin(
            language: playbackLanguage,
            from: oldVoiceID,
            to: newVoiceID
        )
        activeVoiceSwitchID = switchID
        guard let session = ensureAudioSessionClaim() else {
            VoiceSwitchStatusCenter.shared.finish(switchID)
            activeVoiceSwitchID = nil
            return
        }

        // Stop voice A immediately. The narration text/marks remain cached;
        // only the current block audio and its timing are regenerated.
        _ = audio.pause(session: session)
        _ = audio.clearQueue(session: session)
        _ = audio.setMoreSegmentsExpected(true, session: session)
        isPreparingNext = true

        voiceSwitchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rebuilt = try await self.revoicePreparedBlock(
                    original,
                    blockIndex: blockIndex,
                    language: self.playbackLanguage,
                    voiceID: newVoiceID
                )
                try Task.checkCancellation()
                guard self.activeVoiceSwitchID == switchID,
                      self.currentBlockIndex == blockIndex,
                      self.isActive,
                      self.audioSessionToken == session,
                      self.audio.isPlaybackSessionActive(session) else { return }
                self.installVoiceSwitchedBlock(
                    rebuilt,
                    replacing: original,
                    blockIndex: blockIndex,
                    autoPlay: resumeAfterSwitch,
                    session: session
                )
                VoiceSwitchStatusCenter.shared.finish(switchID)
                self.activeVoiceSwitchID = nil
            } catch is CancellationError {
                guard self.activeVoiceSwitchID == switchID,
                      self.audioSessionToken == session,
                      self.audio.isPlaybackSessionActive(session) else { return }
                _ = self.audio.setMoreSegmentsExpected(false, session: session)
                self.isPreparingNext = false
                VoiceSwitchStatusCenter.shared.finish(switchID)
                self.activeVoiceSwitchID = nil
            } catch {
                guard self.activeVoiceSwitchID == switchID,
                      self.audioSessionToken == session,
                      self.audio.isPlaybackSessionActive(session) else { return }
                // A network failure must not strand the player. Restore the
                // cached old block and preserve whether the user was playing.
                self.installVoiceSwitchedBlock(
                    original,
                    replacing: original,
                    blockIndex: blockIndex,
                    autoPlay: resumeAfterSwitch,
                    session: session
                )
                VoiceSwitchStatusCenter.shared.finish(switchID)
                self.activeVoiceSwitchID = nil
                self.debugLog("explain voice switch failed block=%d error=%@", blockIndex, error.localizedDescription)
            }
        }
    }

    private func revoicePreparedBlock(
        _ original: PreparedBlock,
        blockIndex: Int,
        language: String,
        voiceID: String
    ) async throws -> PreparedBlock {
        let segments = try await TTSService.shared.generatePrefetchSegments(
            paragraphIndex: blockIndex,
            text: original.text,
            voice: voiceID,
            speed: 1.0,
            language: language
        )
        guard !segments.isEmpty else { throw QuickReadError.noBlock0 }

        var timeline: [ComposeTimestamp] = []
        var duration = 0.0
        for segment in segments {
            let timestamps = segment.timestamps.isEmpty
                ? TTSService.shared.synthesizeTimestamps(
                    text: segment.text,
                    duration: effectiveDuration(segment)
                )
                : segment.timestamps
            for timestamp in timestamps {
                timeline.append(ComposeTimestamp(
                    word: timestamp.word,
                    start: timestamp.startTime + duration,
                    end: timestamp.endTime + duration
                ))
            }
            duration += effectiveDuration(segment)
        }

        let qualityBlockIndex = QuickReadFastLaneHandoff.qualityBlockIndex(
            forPlaybackBlockIndex: blockIndex,
            indexBase: idxBase
        )
        let recomposed: [QuickreadEvent]?
        if !jobId.isEmpty,
           let qualityBlockIndex,
           let composed = try? await QuickReadService.shared.composeBlock(
                jobId: jobId,
                blockIdx: qualityBlockIndex,
                timestamps: timeline,
                duration: duration
           ) {
            recomposed = composed.events
        } else {
            recomposed = nil
        }
        let oldDuration = original.segments.reduce(0) { $0 + effectiveDuration($1) }
        let marks = recomposed.map { ensureTiming($0, duration: duration) }
            ?? retimeEvents(original.marks, from: oldDuration, to: duration)
        return PreparedBlock(
            segments: segments,
            marks: marks,
            text: original.text,
            sentences: Self.splitSentences(original.text)
        )
    }

    private func retimeEvents(
        _ events: [QuickreadEvent],
        from oldDuration: Double,
        to newDuration: Double
    ) -> [QuickreadEvent] {
        guard oldDuration > 0.01, newDuration > 0.01 else {
            return ensureTiming(events, duration: newDuration)
        }
        let scale = newDuration / oldDuration
        let scaled = events.map { event -> QuickreadEvent in
            var value = event
            if let at = value.at {
                value.at = min(newDuration, max(0, at * scale))
            }
            return value
        }
        return ensureTiming(scaled, duration: newDuration)
    }

    private func installVoiceSwitchedBlock(
        _ block: PreparedBlock,
        replacing original: PreparedBlock,
        blockIndex: Int,
        autoPlay: Bool,
        session: AudioPlaybackSessionToken
    ) {
        guard audioSessionToken == session,
              audio.isPlaybackSessionActive(session) else { return }
        prepared[blockIndex] = block
        if let replayIndex = replayBlocks.lastIndex(where: { $0.text == original.text }) {
            replayBlocks[replayIndex] = block
        }
        marksByBlock[blockIndex] = block.marks
        currentBlockIndex = blockIndex
        explanationText = block.sentences.first ?? block.text
        updateNowPlayingCaption(explanationText)
        status = .streaming(block: blockIndex, total: totalBlocks)
        isPreparingNext = false
        _ = audio.clearQueue(session: session)
        _ = audio.setMoreSegmentsExpected(true, session: session)
        for segment in block.segments {
            audio.loadSegment(
                segment,
                autoPlay: autoPlay && !liveWebTurnIntentSuspended,
                session: session
            )
        }
        _ = audio.setMoreSegmentsExpected(false, session: session)
    }

    private func finishVoiceSwitchIfNeeded() {
        voiceSwitchTask?.cancel()
        voiceSwitchTask = nil
        if let switchID = activeVoiceSwitchID {
            VoiceSwitchStatusCenter.shared.finish(switchID)
            activeVoiceSwitchID = nil
        }
    }

    func activate() {
        if !isActive { isActive = true }
        _ = ensureAudioSessionClaim()
        installAudioCompletionCallback()
    }

    /// Generic readers mirror Kindle's mode-switch contract: if the outgoing
    /// narration was active or preparing, entering Explain immediately starts
    /// or restores it. A non-autoplay switch remains idle/actionable.
    func activateAfterModeSwitch(autoplay: Bool) {
        liveWebTurnIntentSuspended = false
        activate()
        ReaderRunLog.write(
            "EXPLAIN mode activation autoplay=\(autoplay ? "Y" : "N") " +
            "status=\(statusLogValue) paras=\(doc.readableParagraphs.count)"
        )
        if autoplay {
            if case .completed = status {
                replay()
            } else {
                recoverPlaybackAfterOwnershipChange()
            }
        } else if case .planning = status {
            // `deactivate()` cancels planning work. Never leave a spinner whose
            // task no longer exists when the user later returns while paused.
            status = .idle
            stageText = ""
        }
    }

    func deactivate() {
        // The quota/membership refresh happens before `activate()`. Invalidate
        // it even when Explain has not acquired playback ownership yet, or a
        // late refresh can start Explain after the user switched back to Read.
        let wasRefreshingAccess = accessRefreshTask != nil
        accessRefreshRequestID &+= 1
        accessRefreshTask?.cancel()
        accessRefreshTask = nil
        if wasRefreshingAccess {
            stageText = ""
        }
        let wasActive = isActive
        isActive = false
        if let token = audioSessionToken {
            audio.releasePlaybackSession(token)
        }
        audioSessionToken = nil
        guard wasActive else { return }
        endAnalyticsExplainSession(result: .cancelled, reason: "mode_switched")
        contentGeneration &+= 1
        liveWebTurnIntentSuspended = false
        orchestrationTask?.cancel()
        orchestrationTask = nil
        fastTask?.cancel()
        fastTask = nil
        preparingBlocks.removeAll()
        isPreparingNext = false
        clearPagePrefetch()
        audio.setNowPlayingCaption(nil)
        lastNowPlayingCaption = nil
        finishVoiceSwitchIfNeeded()
    }

    // MARK: - Start

    func start() {
        start(allowAccessRefresh: true)
    }

    private func start(
        allowAccessRefresh: Bool,
        reusingStartedSession: Bool = false
    ) {
        liveWebTurnIntentSuspended = false
        ReaderRunLog.write(
            "EXPLAIN start requested status=\(statusLogValue) " +
            "reuse=\(reusingStartedSession ? "Y" : "N") " +
            "paras=\(doc.readableParagraphs.count)"
        )
        guard status == .idle || isErrorState else { return }
        // 提交 LLM 前预校验：内容太短，LLM 没东西可讲 → 直接引导朗读，不发请求白等重试、也不消耗额度（而非无脑提交）。
        let contentChars = doc.readableParagraphs.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
        if contentChars < minExplainChars {
            status = .error(AppLocalized("内容太短，无法解读，试试朗读"))
            return
        }
        guard reusingStartedSession
                || pro.isPro
                || quota.canStartExplain(isPro: pro.isPro) else {
            if allowAccessRefresh {
                refreshAccessThenRetryStart()
                return
            }
            showPaywall = true
            return
        }
        beginFreshContentGeneration()
        let generation = contentGeneration
        beginAnalyticsExplainSession()
        setOutputLanguage(settings.explainLangOrNil ?? doc.language)
        if !reusingStartedSession {
            didProjectServerExplainConsumption = false
            quota.noteExplainStarted(isPro: pro.isPro)
        }
        activate()
        activeMarks = []           // 开始新解读：清上一轮残留 mark（对齐 Android startExplain；之后跨批累积不再清）
        replayBlocks.removeAll()
        preparingBlocks.removeAll()
        isReplayingCached = false
        idxBase = 0; block0Claimed = false; fastSection = nil; forcedExplainLang = nil; planFailed = false; planSettled = false; completionNotified = false; batchPrevSummary = nil
        // text/web/EPUB 的 scope 只由快道 setupQuoteScope 设；重试解读前清掉上轮残留，否则 fastLaneEligibleOpening
        // 的 `pdfScopedParagraphs == nil` 守卫失败 → 退化成只讲 rest、永久丢开头段（PDF 翻页 scope 不受影响）。
        if doc.sourceKind == .web || doc.usesNativeTextRendering {
            pdfScopedParagraphs = nil
            pdfBatchCursor = nil
        }
        applyPlaybackMetadata()
        applySpeed()
        status = .planning
        stageText = AppLocalized("通读全文…")
        ReaderRunLog.write(
            "EXPLAIN planning started reuse=\(reusingStartedSession ? "Y" : "N")"
        )

        // 快道（Fast-Lane）：text/web/EPUB 整页长文 → 先一次轻量 LLM 直出 block_0 秒开，质道吃剩余段顺延 block_1+。
        // 快道先 LLM+TTS 决定 idxBase/scope 再启动质道（失败则质道吃全量、绝不漏开头）。门控不过 → 原单路质道。
        if let opening = fastLaneEligibleOpening() {
            fastTask = Task { [weak self] in
                await self?.runFastLaneThenQuote(opening: opening, generation: generation)
            }
        } else {
            setupBatchScopeIfLarge()   // EPUB/长文：解读分批，避免整本一次 extract-plan → 后端 400
            orchestrationTask = Task { [weak self] in
                await self?.runPlan(generation: generation)
            }
        }
    }

    func startFromPrefetched(_ prefetched: PrefetchedFirstBlock) {
        startFromPrefetched(prefetched, allowAccessRefresh: true)
    }

    private func startFromPrefetched(_ prefetched: PrefetchedFirstBlock, allowAccessRefresh: Bool) {
        guard status == .idle || isErrorState else { return }
        let contentChars = doc.readableParagraphs.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
        if contentChars < minExplainChars {
            status = .error(AppLocalized("内容太短，无法解读，试试朗读"))
            return
        }
        guard pro.isPro || quota.canStartExplain(isPro: pro.isPro) else {
            if allowAccessRefresh {
                refreshAccessThenRetryStart(prefetched: prefetched)
                return
            }
            showPaywall = true
            return
        }
        beginFreshContentGeneration()
        beginAnalyticsExplainSession()
        quota.noteExplainStarted(isPro: pro.isPro)
        activate()
        activeMarks = []
        replayBlocks.removeAll()
        preparingBlocks.removeAll()
        prepared.removeAll()
        marksByBlock.removeAll()
        firedMarks.removeAll()
        isReplayingCached = false
        idxBase = 0
        block0Claimed = true
        fastSection = nil
        forcedExplainLang = nil
        planFailed = false
        planSettled = true
        completionNotified = false
        batchPrevSummary = prefetched.previousSummary
        if doc.sourceKind == .web || doc.sourceKind == .kindle || doc.usesNativeTextRendering {
            pdfScopedParagraphs = nil
            pdfBatchCursor = nil
        }
        jobId = prefetched.jobId
        totalBlocks = max(1, prefetched.totalBlocks)
        setOutputLanguage(prefetched.outputLanguage)
        section0 = prefetched.section0
        currentBlockIndex = -1
        scrollTarget = -1
        applyPlaybackMetadata()
        applySpeed()
        status = .planning
        stageText = AppLocalized("继续讲解…")
        debugLog("prefetched start job=%@ total=%d lang=%@ fp=%@",
                 prefetched.jobId, prefetched.totalBlocks, prefetched.outputLanguage,
                 String(prefetched.textFingerprint.prefix(24)))
        kindlePerfLog("prefetched-start total=\(totalBlocks) chars=\(doc.fullText.count) paras=\(doc.paragraphs.count)")
        enqueue(prefetched.block0, idx: 0)
        if totalBlocks > 1 {
            startBackgroundPrepare(block: 1, reason: "prefetched-start")
        }
    }

    private func refreshAccessThenRetryStart(prefetched: PrefetchedFirstBlock? = nil) {
        stageText = AppLocalized("正在同步会员状态…")
        accessRefreshTask?.cancel()
        accessRefreshRequestID &+= 1
        let requestID = accessRefreshRequestID
        let generation = contentGeneration
        accessRefreshTask = Task { [weak self] in
            await ProManager.shared.refresh()
            await MainActor.run {
                guard let self,
                      !Task.isCancelled,
                      self.contentGeneration == generation,
                      self.accessRefreshRequestID == requestID else { return }
                self.accessRefreshTask = nil
                self.stageText = ""
                if let prefetched {
                    self.startFromPrefetched(prefetched, allowAccessRefresh: false)
                } else {
                    self.start(allowAccessRefresh: false)
                }
            }
        }
    }

    /// Establish a token before scheduling any asynchronous work. Passing this
    /// token into task entry points is essential: a Task can be cancelled
    /// before its closure first runs, and capturing `contentGeneration` inside
    /// that late-starting closure would otherwise capture the *new* page token
    /// and revive stale work.
    private func beginFreshContentGeneration() {
        contentGeneration &+= 1
        accessRefreshRequestID &+= 1
        accessRefreshTask?.cancel()
        accessRefreshTask = nil
        orchestrationTask?.cancel()
        orchestrationTask = nil
        fastTask?.cancel()
        fastTask = nil
        clearPagePrefetch()
    }

    /// Kindle uses this to avoid spending the shared QuickRead slot on the
    /// following page before the current page's next block has been prepared.
    /// WeRead has its own page-prefetch timing in `WebReaderBridge` because a
    /// mobile page is substantially shorter and must begin preloading earlier.
    func shouldDeferExternalPagePrefetchForCurrentBlock() -> Bool {
        guard (doc.sourceKind == .kindle || doc.sourceKind == .web),
              isActive,
              status.isActive else { return false }
        guard currentBlockIndex >= 0 else { return true }
        let next = currentBlockIndex + 1
        return next < totalBlocks && prepared[next] == nil
    }

    private var isErrorState: Bool { if case .error = status { return true } else { return false } }

    /// 解读最低内容量（提交 LLM 前预校验）：中文字符密度高、阈值低；其他语言按字符计。低于此 LLM 没东西可讲。
    private var minExplainChars: Int { doc.language.hasPrefix("zh") ? 20 : 50 }

    /// 快道内容上限：rest 整段一次 extract-plan（不分批，§4.7）能被后端单次处理的体量上界（对齐「一篇长文」≈
    /// 网页文章，实测 ~6800 字 plan 正常）。超过（整本 EPUB/超长）退回分批路径，避免单次 plan 过大 → 后端 400。
    private let fastLaneMaxChars = 12000

    // MARK: - 快道（Fast-Lane）

    /// 快道门控（§5.1）：text/web/EPUB 整页长文首次解读。返回开头 N 段（累计 ~350 字 / ≤2 段）；nil = 不快道。
    private func fastLaneEligibleOpening() -> [ReadingParagraph]? {
        guard pro.isPro else { return nil }                                      // 免费额度按会话计，避免快道被后端误算一次解读
        guard doc.sourceKind == .web || doc.usesNativeTextRendering else { return nil }
        guard pdfScopedParagraphs == nil else { return nil }                       // 已设批次范围（PDF 翻页）跳过
        let readable = doc.readableParagraphs
        let totalChars = readable.reduce(0) { $0 + $1.text.count }
        // 下界：短内容质道本就快，快道不值当。上界：rest 整段喂一个 plan（不分批），整本 EPUB/超长会超后端
        // 单次 plan 上限 → 400；超上界退回原分批路径（setupBatchScopeIfLarge），保证大文档仍能逐批听完。
        guard readable.count >= 6, totalChars >= 2500, totalChars <= fastLaneMaxChars else { return nil }
        var n = 0, acc = 0
        for p in readable { n += 1; acc += p.text.count; if acc >= 350 || n >= 2 { break } }
        guard readable.count - n >= 2 else { return nil }                          // 剩余够质道跑
        return Array(readable.prefix(n))
    }

    /// 快道激活后，质道吃 rest **全部、单次** extract-plan（对齐文档 §4.7：在 rest 上正常顺序分块、running_summary
    /// 自洽，无需再分批）。重索引 0-based 让质道当成「从开头的一篇文章」；mark 锚定独立、锚 doc 全集不受影响。
    /// 注意：不能再对 rest 分批——分批会破坏 rest 块间连续性，与 prev_summary 承接冲突（实测导致跳段）。
    private func setupQuoteScope(_ handoff: QuickReadFastLaneHandoff) {
        pdfScopedParagraphs = handoff.reindexedQualityInput
        pdfBatchCursor = nil   // 不续批：rest 一次喂完
    }

    /// 快道 block_0 → 可播放块：TTS narration + ensureTiming 均匀铺 at（跳过 compose，§5.5）。
    private func prepareFastBlock(_ section: QuickreadSection, language: String) async throws -> PreparedBlock {
        var segs: [AudioSegment] = []
        try await TTSService.shared.generateTTSForParagraph(
            paragraphIndex: 0, text: section.text,
            voice: settings.voice(for: language), speed: 1.0, language: language) { segs.append($0) }
        guard !segs.isEmpty else { throw QuickReadError.noBlock0 }
        let duration = segs.reduce(0) { $0 + effectiveDuration($1) }
        let marks = ensureTiming(section.events, duration: duration)
        debugLog("fastlane prepare marks_raw=%d marks_timed=%d segs=%d duration=%.2f text=%d",
                 section.events.count, marks.count, segs.count, duration, section.text.count)
        return PreparedBlock(segments: segs, marks: marks, text: section.text, sentences: Self.splitSentences(section.text))
    }

    /// 快道执行：先 LLM(fast-block0) + TTS 决定 idxBase/scope，再启动质道。
    /// 成功 → 占 block_0 秒开 + 质道吃剩余段（idxBase=1）；失败 → idxBase=0 + 质道吃全量（绝不漏开头）。
    private func runFastLaneThenQuote(
        opening: [ReadingParagraph],
        generation: UInt64
    ) async {
        guard generation == contentGeneration, !Task.isCancelled else { return }
        let lang = settings.explainLangOrNil ?? doc.language   // 锁定确定语言（快道+质道同语言，不让 server 对快道默认 en）
        await MainActor.run {
            guard self.contentGeneration == generation else { return }
            self.forcedExplainLang = lang
        }
        var fastResult: (section: QuickreadSection, block: PreparedBlock)?
        if let section = try? await QuickReadService.shared.fastBlock0(
                title: doc.title, openingParas: opening.map { $0.text },
                lang: lang, depth: requestDepth, prevSummary: nil, contentType: scenario),
           let pb = try? await prepareFastBlock(section, language: lang) {
            fastResult = (section, pb)
        }
        await MainActor.run {
            guard self.contentGeneration == generation,
                  self.isActive,
                  case .planning = self.status else { return }
            let readable = self.doc.readableParagraphs
            if let result = fastResult,
               let handoff = QuickReadFastLaneHandoff(
                    readableParagraphs: readable,
                    selectedOpening: opening,
                    fastNarration: result.section.text
               ) {
                self.fastSection = result.section
                self.batchPrevSummary = handoff.previousSummary
                self.idxBase = handoff.indexBase
                self.block0Claimed = true
                self.setupQuoteScope(handoff)
                self.totalBlocks = max(1, self.idxBase + 1)   // 预估，handlePlan 收到质道总块数后修正
                self.enqueue(result.block, idx: 0)                       // 秒开
                let openingDigest = handoff.openingDigest
                let qualityDigest = handoff.qualityDigest
                let diagnostic = String(
                    format: "fastlane handoff openingParas=%d openingChars=%d openingFP=%@ qualityParas=%d qualityChars=%d qualityFP=%@ prevSummaryChars=%d idxBase=%d",
                    openingDigest.paragraphCount,
                    openingDigest.characterCount,
                    openingDigest.fingerprint,
                    qualityDigest.paragraphCount,
                    qualityDigest.characterCount,
                    qualityDigest.fingerprint,
                    handoff.previousSummary.count,
                    handoff.indexBase
                )
                self.debugLog("%@ marks=%d", diagnostic, result.block.marks.count)
                ReaderRunLog.write("EXPLAIN \(diagnostic)")
            } else {
                self.fastSection = nil
                self.batchPrevSummary = nil
                self.idxBase = 0
                self.setupBatchScopeIfLarge()                  // 快道失败兜底：质道吃全量
                self.debugLog("fastlane failed -> quote full")
            }
            self.orchestrationTask = Task { [weak self] in
                await self?.runPlan(generation: generation)
            }
        }
    }

    func stop() {
        contentGeneration &+= 1
        accessRefreshRequestID &+= 1
        liveWebTurnIntentSuspended = false
        accessRefreshTask?.cancel()
        accessRefreshTask = nil
        orchestrationTask?.cancel()
        orchestrationTask = nil
        fastTask?.cancel()
        fastTask = nil
        finishVoiceSwitchIfNeeded()
        if let token = audioSessionToken {
            _ = audio.setMoreSegmentsExpected(false, session: token)
            _ = audio.clearBook(session: token)
        }
        clearPagePrefetch()
        preparingBlocks.removeAll()
        // `PreparedBlock` owns raw MP3 Data. A closed/superseded document can
        // never replay these blocks, so keeping both caches alive makes A -> B
        // -> C -> D depend on ARC timing and any late orchestration task.
        prepared.removeAll(keepingCapacity: false)
        replayBlocks.removeAll(keepingCapacity: false)
        marksByBlock.removeAll(keepingCapacity: false)
        firedMarks.removeAll(keepingCapacity: false)
        isReplayingCached = false
        isContinuingLivePage = false
        status = .idle
        endAnalyticsExplainSession(result: .cancelled, reason: "closed")
    }

    /// A live reader could not commit a requested next page (book end,
    /// rejected action, unavailable WebView, or confirmation timeout).  Only
    /// now is the page-level completion also the document-level completion.
    func finishLivePageContinuation() {
        guard isContinuingLivePage else { return }
        isContinuingLivePage = false
        stageText = ""
        status = .completed
    }

    func togglePlayPause() {
        liveWebTurnIntentSuspended = false
        guard ownsAudioQueue,
              audio.currentSegment != nil || audio.hasQueuedSegments else {
            recoverPlaybackAfterOwnershipChange()
            return
        }
        if let token = audioSessionToken {
            _ = audio.togglePlayPause(session: token)
        }
    }

    /// Idempotent external resume entry point, symmetric with Read Aloud's
    /// `ensurePlaying`. It never pauses an active explanation and reuses cached
    /// audio when possible.
    func ensurePlaying() {
        liveWebTurnIntentSuspended = false
        if ownsAudioQueue, audio.isPlaying { return }

        switch status {
        case .idle, .error:
            start()
        case .completed:
            replay()
        case .planning, .streaming:
            if ownsAudioQueue,
               audio.currentSegment != nil || audio.hasQueuedSegments,
               let token = audioSessionToken {
                _ = audio.play(session: token)
            } else if !ownsAudioQueue {
                recoverPlaybackAfterOwnershipChange()
            }
        }
    }

    private var statusLogValue: String {
        switch status {
        case .idle:
            return "idle"
        case .planning:
            return "planning"
        case .streaming(let block, let total):
            return "streaming-\(block + 1)-of-\(total)"
        case .completed:
            return "completed"
        case .error:
            return "error"
        }
    }

    private func recoverPlaybackAfterOwnershipChange() {
        guard isActive else {
            start()
            return
        }
        guard let session = ensureAudioSessionClaim() else { return }
        let plan = ExplainOwnershipRecoveryPlan.resolve(
            currentBlockIndex: currentBlockIndex,
            hasCurrentPreparedBlock: prepared[currentBlockIndex] != nil,
            replayBlockCount: replayBlocks.count,
            statusIsActive: status.isActive
        )
        switch plan {
        case .preparedBlock(let index):
            guard let block = prepared[index] else { return }
            installCachedBlockAfterOwnershipChange(
                block,
                blockIndex: index,
                session: session
            )
        case .replayBlock(let index):
            isReplayingCached = true
            installCachedBlockAfterOwnershipChange(
                replayBlocks[index],
                blockIndex: index,
                session: session
            )
        case .restartPlanning(let reusingStartedSession):
            // A mode switch can cancel planning before block 0 exists. Reset
            // the stale planning state so the control stays actionable, but do
            // not charge the same Explain session twice.
            status = .idle
            stageText = ""
            start(
                allowAccessRefresh: true,
                reusingStartedSession: reusingStartedSession
            )
        }
    }

    private func installCachedBlockAfterOwnershipChange(
        _ block: PreparedBlock,
        blockIndex: Int,
        session: AudioPlaybackSessionToken
    ) {
        guard isActive,
              audioSessionToken == session,
              audio.isPlaybackSessionActive(session) else { return }
        _ = audio.clearQueue(session: session)
        currentBlockIndex = blockIndex
        prepared[blockIndex] = block
        marksByBlock[blockIndex] = block.marks
        explanationText = block.sentences.first ?? block.text
        updateNowPlayingCaption(explanationText)
        status = .streaming(block: blockIndex, total: max(totalBlocks, blockIndex + 1))
        isPreparingNext = false
        _ = audio.setMoreSegmentsExpected(true, session: session)
        for segment in block.segments {
            _ = audio.loadSegment(
                segment,
                autoPlay: !liveWebTurnIntentSuspended,
                session: session
            )
        }
        _ = audio.setMoreSegmentsExpected(false, session: session)
    }

    /// 重新播放已解读完的内容：复用缓存块（不重新调后端 LLM、不耗额度），从第一块重头播。
    func replay() {
        liveWebTurnIntentSuspended = false
        if replayBlocks.isEmpty {
            // 兼容旧会话/短文：若还没形成完整轨道，就把当前批缓存作为兜底；全新会话则普通开始。
            let current = prepared.keys.sorted().compactMap { prepared[$0] }
            if !current.isEmpty { replayBlocks = current } else { start(); return }
        }
        beginFreshContentGeneration()
        beginAnalyticsExplainSession()
        activate()
        isReplayingCached = true
        preparingBlocks.removeAll()
        firedMarks.removeAll()
        activeMarks = []          // 触发 bridge clearMarks，清掉上一轮 DOM 手写标注
        anchorCursor = nil
        batchPrevSummary = nil
        currentBlockIndex = -1
        scrollTarget = -1
        totalBlocks = replayBlocks.count
        applyPlaybackMetadata()
        applySpeed()
        enqueueReplayBlock(0)
    }

    // MARK: - Product analytics

    private func beginAnalyticsExplainSession() {
        guard analyticsExplainSessionId == nil else { return }
        analyticsExplainSessionId = UUID().uuidString
        analyticsExplainStartedAt = Date()
        analyticsFirstBlockTracked = false
        analyticsSecondBlockStarted = false
        analyticsFirstBlockCompleted = false
        analyticsBlocksStarted.removeAll()
        analyticsBlocksCompleted.removeAll()
        ProductAnalytics.shared.track(
            .explainStart,
            context: analyticsEventContext,
            properties: .init(
                contentSource: analyticsContext.source.rawValue,
                contentFormat: AnalyticsContentFormat(document.sourceKind).rawValue,
                language: doc.language,
                scenario: analyticsScenario,
                storefront: analyticsContext.storefront
            )
        )
    }

    private func handleAnalyticsPlaybackState(_ playing: Bool) {
        let ownedPlaying = playing && ownsAudioQueue
        isPlaying = ownedPlaying
        guard ownedPlaying,
              analyticsExplainSessionId != nil,
              currentBlockIndex >= 0,
              audio.currentSegment != nil else { return }

        analyticsBlocksStarted.insert(currentBlockIndex)
        if !analyticsFirstBlockTracked {
            analyticsFirstBlockTracked = true
            let latency = max(0, Int(Date().timeIntervalSince(analyticsExplainStartedAt ?? Date()) * 1000))
            ProductAnalytics.shared.track(
                .explainFirstBlock,
                context: analyticsEventContext,
                properties: .init(
                    latencyMs: latency,
                    scenario: analyticsScenario,
                    storefront: analyticsContext.storefront
                )
            )
        }
        if currentBlockIndex >= 1, !analyticsSecondBlockStarted {
            analyticsSecondBlockStarted = true
            ProductAnalytics.shared.track(
                .explainMilestone,
                context: analyticsEventContext,
                properties: .init(
                    milestone: "second_block_started",
                    blocksStarted: analyticsBlocksStarted.count,
                    blocksCompleted: analyticsBlocksCompleted.count,
                    storefront: analyticsContext.storefront
                )
            )
        }
    }

    private func recordAnalyticsBlockCompleted(_ index: Int) {
        guard analyticsExplainSessionId != nil, index >= 0 else { return }
        analyticsBlocksCompleted.insert(index)
        if index == 0, !analyticsFirstBlockCompleted {
            analyticsFirstBlockCompleted = true
            ProductAnalytics.shared.noteMeaningfulReadReached()
            ProductAnalytics.shared.track(
                .explainMilestone,
                context: analyticsEventContext,
                properties: .init(
                    milestone: "first_block_completed",
                    blocksStarted: analyticsBlocksStarted.count,
                    blocksCompleted: analyticsBlocksCompleted.count,
                    storefront: analyticsContext.storefront
                )
            )
        }
    }

    private func endAnalyticsExplainSession(
        result: AnalyticsResult,
        reason: String,
        errorStage: String? = nil,
        errorCode: String? = nil
    ) {
        guard analyticsExplainSessionId != nil else { return }
        ProductAnalytics.shared.track(
            .explainEnd,
            context: analyticsEventContext,
            properties: .init(
                result: result.rawValue,
                errorStage: errorStage,
                errorCode: errorCode,
                completionBucket: ProductAnalytics.completionBucket(
                    completed: analyticsBlocksCompleted.count,
                    total: max(totalBlocks, analyticsBlocksStarted.count)
                ),
                endReason: reason,
                blocksStarted: analyticsBlocksStarted.count,
                blocksCompleted: analyticsBlocksCompleted.count,
                storefront: analyticsContext.storefront
            )
        )
        analyticsExplainSessionId = nil
        analyticsExplainStartedAt = nil
    }

    private var analyticsEventContext: AnalyticsEventContext {
        AnalyticsEventContext(
            productArea: .explain,
            surface: document.sourceKind == .kindle ? "kindle_reader" : "reader",
            entryPoint: analyticsContext.entryPoint,
            contentSessionId: analyticsContext.contentSessionId,
            explainSessionId: analyticsExplainSessionId
        )
    }

    private var analyticsScenario: String {
        let value = scenario?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "general" : value
    }

    private static func analyticsErrorCode(_ error: Error) -> String {
        if error is URLError { return "network" }
        if error is CancellationError { return "cancelled" }
        if case QuickReadError.httpError(let code) = error { return "http_\(code)" }
        let description = String(describing: error).lowercased()
        if description.contains("timeout") { return "timeout" }
        return "quickread_failed"
    }

    // MARK: - Plan

    private func runPlan(generation: UInt64) async {
        guard generation == contentGeneration, !Task.isCancelled else { return }
        let req = buildPlanRequest()
        let requestScope = pdfScopedParagraphs ?? doc.paragraphs
        let requestDigest = QuickReadFastLaneHandoff.scopeDigest(requestScope)
        let requestDiagnostic = String(
            format: "plan request idxBase=%d paras=%d chars=%d fp=%@ prevSummaryChars=%d",
            idxBase,
            requestDigest.paragraphCount,
            requestDigest.characterCount,
            requestDigest.fingerprint,
            req.prev_summary?.count ?? 0
        )
        debugLog("%@", requestDiagnostic)
        ReaderRunLog.write("EXPLAIN \(requestDiagnostic)")
        do {
            let done = try await QuickReadService.shared.extractPlan(
                req,
                onStage: { [weak self] s in
                    Task { @MainActor in
                        guard let self, self.contentGeneration == generation else { return }
                        self.stageText = self.friendlyStage(s)
                    }
                },
                onBlock0: { [weak self] block0 in
                    Task { @MainActor in
                        guard let self, self.contentGeneration == generation else { return }
                        self.handlePlan(block0, generation: generation)
                    }
                }
            )
            // 权威总块数取自 done 事件：block0 事件的 total_blocks 后端常发 0 占位（plan 尚未算完总数）。
            // 之前 app 误用 block0 的 0 → max(1,0)=1 → 只播首块就"完成"。对齐扩展：用 done 的值。
            await MainActor.run {
                guard self.contentGeneration == generation else { return }
                self.planSettled = true
                let oldTotal = self.totalBlocks
                self.debugLog("explain DONE total_blocks=%d (block0 placeholder totalBlocks=%d)", done.total_blocks ?? -1, self.totalBlocks)
                if let tb = done.total_blocks, self.idxBase + tb > self.totalBlocks {
                    self.totalBlocks = self.idxBase + tb   // 快道占 idxBase 块 + 质道 tb 块（漏加 idxBase 会丢质道最后一块）
                    self.kindlePerfLog("plan-done total-update old=\(oldTotal) new=\(self.totalBlocks) current=\(self.currentBlockIndex)")
                    // done 晚于首块播完到达时会误判 .completed → 在此续播下一块。
                    if case .completed = self.status, self.currentBlockIndex + 1 < self.totalBlocks {
                        let next = self.currentBlockIndex + 1
                        self.orchestrationTask = Task { [weak self] in
                            await self?.prepareAndEnqueue(
                                block: next,
                                generation: generation
                            )
                        }
                    }
                }
                let next = max(0, self.currentBlockIndex + 1)
                if next < self.totalBlocks {
                    self.startBackgroundPrepare(block: next, reason: "plan-done")
                }
                self.notifyDocumentFinishedIfReady()
            }
        } catch {
            if case QuickReadError.httpError(402) = error {
                await ProManager.shared.refresh()
            }
            await MainActor.run {
                guard self.contentGeneration == generation else { return }
                self.planFailed = true   // 通知 prepareBlock 的 section0 等待循环跳出（快道占位后不再死等挂起）
                // server entitlement 超限 → 付费墙（对齐扩展：免费额度用满当付费墙，不当普通错误）
                if case QuickReadError.httpError(402) = error {
                    if self.pro.needsEmailSync {
                        self.status = .error(AuthService.shared.hasSyncableAccount
                            ? AppLocalized("本机已解锁；跨平台同步等待 Apple 验证接口。")
                            : (AppRegion.current == .cn
                                ? AppLocalized("已检测到购买，请登录后同步会员")
                                : AppLocalized("已检测到购买，请登录账号同步 Pro")))
                        self.stageText = AppLocalized("解读失败")
                    } else if self.pro.isPro {
                        self.status = .error(AppLocalized("解读服务暂未识别 Pro 会员，请稍后重试"))
                        self.stageText = AppLocalized("解读失败")
                    } else {
                        self.showPaywall = true
                        self.status = .idle
                        self.stageText = ""
                    }
                    self.endAnalyticsExplainSession(
                        result: .blocked,
                        reason: "explain_quota",
                        errorStage: "plan",
                        errorCode: "http_402"
                    )
                } else if case QuickReadError.httpError(400) = error {
                    // 重试 3 次仍 400：多为内容太短/不适合解读，给可读提示而非裸 HTTP 码
                    self.status = .error(AppLocalized("内容太短或暂不支持解读，请稍后重试"))
                    self.stageText = AppLocalized("解读失败")
                    self.endAnalyticsExplainSession(
                        result: .failed,
                        reason: "plan_failed",
                        errorStage: "plan",
                        errorCode: "http_400"
                    )
                } else {
                    self.status = .error(error.localizedDescription)
                    self.stageText = AppLocalized("解读失败")
                    self.endAnalyticsExplainSession(
                        result: .failed,
                        reason: "plan_failed",
                        errorStage: "plan",
                        errorCode: Self.analyticsErrorCode(error)
                    )
                }
            }
            return
        }
    }

    private func handlePlan(_ plan: PlanBlock0, generation: UInt64) {
        guard generation == contentGeneration else { return }
        if !didProjectServerExplainConsumption {
            quota.noteExplainAcceptedByServer(isPro: pro.isPro)
            didProjectServerExplainConsumption = true
        }
        jobId = plan.job_id
        totalBlocks = idxBase + max(1, plan.total_blocks)   // 快道占 idxBase 块 + 质道块
        // 快道激活（forcedExplainLang != nil）时它优先：block_0 已用此语言朗读，质道必须跟随，不能被
        // plan.output_language 盖过（否则质道与快道开头语言/音色不一致）。非快道时才用 plan 返回的语言。
        setOutputLanguage(forcedExplainLang ?? plan.output_language ?? settings.explainLangOrNil ?? doc.language)
        section0 = plan.block_0                              // 质道首块 = iOS block_idxBase
        let scoped = pdfScopedParagraphs ?? doc.paragraphs   // 实际传后端的范围（PDF 逐批时是当前批，非整本）
        debugLog("explain PLAN total_blocks=%d idxBase=%d batchParas=%d batchChars=%d depth=%@ block0Events=%d",
                 plan.total_blocks, idxBase, scoped.count, scoped.reduce(0) { $0 + $1.text.count }, requestDepth, plan.block_0.events.count)
        if !block0Claimed {
            // 快道没占（idxBase=0 / 快道失败）→ 质道占 block_0
            block0Claimed = true
            orchestrationTask = Task { [weak self] in
                await self?.prepareAndEnqueue(block: 0, generation: generation)
            }
            if totalBlocks > 1 {
                startBackgroundPrepare(block: 1, reason: "plan-block0")
            }
        } else {
            // 快道已占 block_0 → 后台预取质道首块 block_idxBase，消除块间 gap（播完 block_0 由 onBlockComplete 续接）
            startBackgroundPrepare(block: idxBase, reason: "plan-after-fastlane")
        }
    }

    // MARK: - 块准备与入队

    private func prepareAndEnqueue(block idx: Int, generation: UInt64) async {
        guard generation == contentGeneration, !Task.isCancelled else { return }
        let startedAt = Date()
        let cachedAtStart = prepared[idx] != nil
        kindlePerfLog("prepare-enqueue begin idx=\(idx) total=\(totalBlocks) cached=\(cachedAtStart ? "Y" : "N")")
        if cachedAtStart {
            kindlePerfLog("kindleExplainBlockPrefetch hit idx=\(idx) source=prepare-enqueue")
        } else {
            kindlePerfLog("kindleExplainBlockPrefetch fallback idx=\(idx) source=prepare-enqueue")
        }
        do {
            let pb = try await prepareBlock(idx, generation: generation)
            await MainActor.run {
                guard self.contentGeneration == generation else { return }
                self.enqueue(pb, idx: idx)
            }
            guard contentGeneration == generation else { return }
            kindlePerfLog("prepare-enqueue ready idx=\(idx) totalMs=\(elapsedMs(since: startedAt)) segs=\(pb.segments.count) text=\(pb.text.count)")
            // 预取下一块
            if idx + 1 < totalBlocks {
                startBackgroundPrepare(block: idx + 1, reason: "after-enqueue-\(idx)")
            }
        } catch is CancellationError {
            await MainActor.run {
                guard self.contentGeneration == generation else { return }
                self.isPreparingNext = false
            }
        } catch {
            kindlePerfLog("prepare-enqueue error idx=\(idx) totalMs=\(elapsedMs(since: startedAt)) error=\(error.localizedDescription)")
            await MainActor.run {
                guard self.contentGeneration == generation else { return }
                self.status = .error(error.localizedDescription)
                self.isPreparingNext = false
                self.endAnalyticsExplainSession(
                    result: .failed,
                    reason: "block_failed",
                    errorStage: "block_prepare",
                    errorCode: Self.analyticsErrorCode(error)
                )
            }
        }
    }

    private func startBackgroundPrepare(block idx: Int, reason: String) {
        guard idx >= 0, idx < totalBlocks else { return }
        guard prepared[idx] == nil, !preparingBlocks.contains(idx) else {
            kindlePerfLog("background-prepare skip reason=\(reason) idx=\(idx) cached=\(prepared[idx] == nil ? "N" : "Y") preparing=\(preparingBlocks.contains(idx) ? "Y" : "N")")
            return
        }
        kindlePerfLog("background-prepare schedule reason=\(reason) idx=\(idx) total=\(totalBlocks)")
        kindlePerfLog("kindleExplainBlockPrefetch start reason=\(reason) idx=\(idx) total=\(totalBlocks)")
        let generation = contentGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let pb = try await self.prepareBlock(idx, detachedTTS: true, generation: generation)
                await MainActor.run {
                    guard self.contentGeneration == generation else { return }
                    if self.prepared[idx] == nil {
                        self.prepared[idx] = pb
                    }
                    self.kindlePerfLog("background-prepare ready reason=\(reason) idx=\(idx) segs=\(pb.segments.count) text=\(pb.text.count)")
                    self.kindlePerfLog("kindleExplainBlockPrefetch ready reason=\(reason) idx=\(idx) segs=\(pb.segments.count) text=\(pb.text.count)")
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.contentGeneration == generation else { return }
                    self.kindlePerfLog("background-prepare cancelled reason=\(reason) idx=\(idx)")
                }
            } catch {
                await MainActor.run {
                    guard self.contentGeneration == generation else { return }
                    self.kindlePerfLog("background-prepare miss reason=\(reason) idx=\(idx) error=\(error.localizedDescription)")
                }
            }
        }
    }

    private func prepareBlock(
        _ idx: Int,
        detachedTTS: Bool = false,
        generation expectedGeneration: UInt64? = nil
    ) async throws -> PreparedBlock {
        let generation = expectedGeneration ?? contentGeneration
        guard generation == contentGeneration else { throw CancellationError() }
        let startedAt = Date()
        if let cached = prepared[idx] {
            kindlePerfLog("prepare-block cache-hit idx=\(idx) detached=\(detachedTTS ? "Y" : "N")")
            return cached
        }
        var waitedMs = 0
        let waitStartedAt = Date()
        while preparingBlocks.contains(idx) {
            try await Task.sleep(nanoseconds: 80_000_000)
            guard generation == contentGeneration else { throw CancellationError() }
            if let cached = prepared[idx] { return cached }
            if !isActive { throw CancellationError() }
        }
        waitedMs = elapsedMs(since: waitStartedAt)
        preparingBlocks.insert(idx)
        defer {
            if generation == contentGeneration {
                preparingBlocks.remove(idx)
            }
        }

        if let cached = prepared[idx] {
            kindlePerfLog("prepare-block cache-hit-after-wait idx=\(idx) detached=\(detachedTTS ? "Y" : "N") waitedMs=\(waitedMs)")
            return cached
        }
        // 快道占 block_0（idxBase=1）→ iOS idx 映射到质道块 qIdx = idx - idxBase。
        // 质道首块（qIdx<=0）用 plan 的 section0；快道占位时 block_0 播放期间质道 plan 通常已返回，
        // 极端未到则短暂等待（block_0 narration 音频较长，足够质道 plan 完成）。其余拉 extract-block。
        guard let qIdx = QuickReadFastLaneHandoff.qualityBlockIndex(
            forPlaybackBlockIndex: idx,
            indexBase: idxBase
        ) else {
            // The fast block is prepared independently and must never enter
            // the quality extract/compose pipeline.
            throw CancellationError()
        }
        let section: QuickreadSection
        let sectionStartedAt = Date()
        if qIdx <= 0 {
            // 等质道 plan 返回 section0；plan 失败（planFailed）或失活则跳出，避免快道占位后死等挂起。
            // 失败时静默抛 CancellationError——错误/付费墙状态已由 runPlan 的 catch 设置，prepareAndEnqueue 不覆盖。
            while section0 == nil, isActive, !planFailed {
                try await Task.sleep(nanoseconds: 200_000_000)
                guard generation == contentGeneration else { throw CancellationError() }
            }
            guard let s0 = section0 else { throw CancellationError() }
            section = s0
        } else {
            section = try await QuickReadService.shared.extractBlock(jobId: jobId, blockIdx: qIdx)
        }
        let sectionMs = elapsedMs(since: sectionStartedAt)
        let pb = try await prepareSection(section, idx: idx, composeIdx: qIdx, jobId: jobId, language: outputLanguage, detachedTTS: detachedTTS)
        guard generation == contentGeneration else { throw CancellationError() }
        prepared[idx] = pb
        kindlePerfLog("prepare-block ready idx=\(idx) qIdx=\(qIdx) detached=\(detachedTTS ? "Y" : "N") waitedMs=\(waitedMs) sectionMs=\(sectionMs) totalMs=\(elapsedMs(since: startedAt))")
        return pb
    }

    /// 讲解 section → 可播放块（TTS + 拼时间线 + composeBlock 回填 mark.at）。参数化 jobId/语言 → 当前页与页间预取共用。
    /// idx = iOS 块序（TTS 段标识、匹配 currentBlockIndex）；composeIdx = 质道块号（快道激活后两者差 idxBase）。
    private func prepareSection(_ section: QuickreadSection, idx: Int, composeIdx: Int, jobId: String, language: String, detachedTTS: Bool = false) async throws -> PreparedBlock {
        let startedAt = Date()
        // TTS 讲解文本（收集全部 segment）
        var segs: [AudioSegment] = []
        let ttsStartedAt = Date()
        if detachedTTS {
            segs = try await TTSService.shared.generatePrefetchSegments(
                paragraphIndex: idx,
                text: section.text,
                voice: settings.voice(for: language),
                speed: 1.0,
                language: language
            )
        } else {
            try await TTSService.shared.generateTTSForParagraph(
                paragraphIndex: idx,
                text: section.text,
                voice: settings.voice(for: language),
                speed: 1.0,
                language: language
            ) { segment in
                segs.append(segment)
            }
        }
        let ttsMs = elapsedMs(since: ttsStartedAt)

        // 拼块时间线 → composeBlock 回填 at
        var timeline: [ComposeTimestamp] = []
        var offset = 0.0
        for seg in segs {
            // 中文等无词时间戳的 segment：解读需要时间线回填 mark.at，按音频时长合成字符级时间戳（仅解读路径）。
            let segTimestamps = seg.timestamps.isEmpty
                ? TTSService.shared.synthesizeTimestamps(text: seg.text, duration: effectiveDuration(seg))
                : seg.timestamps
            for ts in segTimestamps {
                timeline.append(ComposeTimestamp(word: ts.word, start: ts.startTime + offset, end: ts.endTime + offset))
            }
            offset += effectiveDuration(seg)
        }
        let duration = offset

        var marks: [QuickreadEvent]
        var composedCount: Int?
        let composeStartedAt = Date()
        if let composed = try? await QuickReadService.shared.composeBlock(
            jobId: jobId, blockIdx: composeIdx, timestamps: timeline, duration: duration) {
            marks = composed.events
            composedCount = composed.events.count
        } else {
            marks = section.events
        }
        let composeMs = elapsedMs(since: composeStartedAt)
        marks = ensureTiming(marks, duration: duration)
        debugLog("prepareSection idx=%d composeIdx=%d sectionMarks=%d composedMarks=%@ finalMarks=%d segs=%d timeline=%d duration=%.2f text=%d",
                 idx, composeIdx, section.events.count, composedCount.map(String.init) ?? "nil",
                 marks.count, segs.count, timeline.count, duration, section.text.count)
        kindlePerfLog("prepare-section idx=\(idx) qIdx=\(composeIdx) detached=\(detachedTTS ? "Y" : "N") ttsMs=\(ttsMs) composeMs=\(composeMs) totalMs=\(elapsedMs(since: startedAt)) sectionMarks=\(section.events.count) composedMarks=\(composedCount.map(String.init) ?? "nil") finalMarks=\(marks.count) segs=\(segs.count) text=\(section.text.count)")

        return PreparedBlock(segments: segs, marks: marks, text: section.text, sentences: Self.splitSentences(section.text))
    }

    private func enqueue(_ pb: PreparedBlock, idx: Int) {
        guard let session = ensureAudioSessionClaim() else { return }
        prepared[idx] = pb   // 缓存每块（含 block 0），供 replay 复用、不重新 TTS/调后端
        if !isReplayingCached {
            replayBlocks.append(pb)
        }
        _ = audio.clearQueue(session: session)
        currentBlockIndex = idx
        explanationText = pb.sentences.first ?? pb.text
        updateNowPlayingCaption(explanationText)
        marksByBlock[idx] = pb.marks
        debugLog("enqueue block=%d total=%d marks=%d text=%d segs=%d",
                 idx, totalBlocks, pb.marks.count, pb.text.count, pb.segments.count)
        status = .streaming(block: idx, total: totalBlocks)
        isPreparingNext = false
        _ = audio.setMoreSegmentsExpected(true, session: session)
        for seg in pb.segments {
            _ = audio.loadSegment(
                seg,
                autoPlay: !liveWebTurnIntentSuspended,
                session: session
            )
        }
        _ = audio.setMoreSegmentsExpected(false, session: session)
        // PDF 连续解读：当前页一开始播就后台预取下一页首块，切页时秒接（消除页间 gap）。
        if !isReplayingCached { prefetchNextPage() }
    }

    private func onBlockComplete() {
        recordAnalyticsBlockCompleted(currentBlockIndex)
        if isReplayingCached {
            let next = currentBlockIndex + 1
            if next < replayBlocks.count {
                enqueueReplayBlock(next)
            } else {
                isReplayingCached = false
                status = .completed
                endAnalyticsExplainSession(result: .success, reason: "replay_completed")
            }
            return
        }
        let next = currentBlockIndex + 1
        if next < totalBlocks {
            // 下一块未预取好 → 显示「准备下一段」loading，避免块间静默被误以为卡住。
            let nextReady = prepared[next] != nil
            kindlePerfLog("block-complete current=\(currentBlockIndex) next=\(next) total=\(totalBlocks) nextReady=\(nextReady ? "Y" : "N")")
            if nextReady {
                kindlePerfLog("kindleExplainBlockPrefetch hit current=\(currentBlockIndex) next=\(next)")
            } else {
                kindlePerfLog("kindleExplainBlockPrefetch await current=\(currentBlockIndex) next=\(next)")
                isPreparingNext = true
            }
            let generation = contentGeneration
            orchestrationTask = Task { [weak self] in
                await self?.prepareAndEnqueue(block: next, generation: generation)
            }
            return
        }
        // 当前批讲解播完 → 自动推进下一批续播，直到全书末尾（听完整本）。
        if let next = pdfBatchCursor {
            advanceBatch(fromGlobalIndex: next)
            return
        }
        status = .completed
        endAnalyticsExplainSession(result: .success, reason: "completed")
        notifyDocumentFinishedIfReady()
    }

    /// `block0.total_blocks` can be a placeholder while the SSE plan is still
    /// running.  Never advance a live paginated reader until the authoritative
    /// `done` event has settled the final block count; otherwise a short first
    /// block could flip the page while later blocks from the old page are still
    /// arriving.
    private func notifyDocumentFinishedIfReady() {
        guard planSettled,
              !completionNotified,
              case .completed = status,
              currentBlockIndex + 1 >= totalBlocks,
              pdfBatchCursor == nil else { return }
        completionNotified = true
        if let onDocumentFinished {
            // Set this before invoking the bridge. SwiftUI may observe the
            // `.completed` assignment from `onBlockComplete`; the companion
            // flag makes that same render a continuation state, never a false
            // whole-document completion flash.
            isContinuingLivePage = true
            stageText = AppLocalized("继续讲解…")
            debugLog("live-page explanation completed; awaiting semantic next-page commit")
            onDocumentFinished()
        }
    }

    private func enqueueReplayBlock(_ idx: Int) {
        guard idx >= 0, idx < replayBlocks.count else {
            isReplayingCached = false
            status = .completed
            endAnalyticsExplainSession(result: .success, reason: "replay_completed")
            return
        }
        enqueue(replayBlocks[idx], idx: idx)
    }

    /// PDF 连续解读：切到下一批续播。命中批间预取 → 跳过 extract-plan；否则实时规划（显示「继续讲解…」）。
    private func advanceBatch(fromGlobalIndex start: Int) {
        let batch = pdfBatch(fromGlobalIndex: start)
        guard !batch.paras.isEmpty else {
            status = .completed
            endAnalyticsExplainSession(result: .success, reason: "completed")
            return
        }
        let prevSummary = makeBatchContinuitySummary()
        let prefetchedForBatch = prefetchedBatch.flatMap {
            $0.startIndex == start ? $0 : nil
        }
        // A new batch reuses the same user session, but none of the previous
        // batch's delayed block tasks may write into its page-local block keys.
        beginFreshContentGeneration()
        let generation = contentGeneration
        batchPrevSummary = prevSummary
        debugLog("advanceBatch start=%d paras=%d chars=%d prevSummary=%d prefetched=%@",
                 start, batch.paras.count, batch.paras.reduce(0) { $0 + $1.text.count },
                 prevSummary?.count ?? 0, (prefetchedBatch?.startIndex == start) ? "yes" : "no")
        pdfScopedParagraphs = batch.paras
        pdfBatchCursor = batch.next
        // 重置上一批块状态（保留 isActive / audio 设置）。注意 activeMarks 跨批**累积、不清**——
        // 否则切到下一批时前面批的手写标注全没了（对齐 Android：整个解读过程 mark 留在原文上）。
        prepared.removeAll()
        preparingBlocks.removeAll()
        marksByBlock.removeAll()
        firedMarks.removeAll()
        anchorCursor = batch.paras.first?.id   // mark 锚定优先当前批段落（不回前面批找重复文本）
        currentBlockIndex = -1
        scrollTarget = -1

        // 命中批间预取 → 已规划好（跳过 extract-plan「通读」那段 gap）；block0 TTS 在此生成（此刻 TTS 空闲、不冲突）。
        if let pf = prefetchedForBatch {
            jobId = pf.jobId
            totalBlocks = pf.totalBlocks
            setOutputLanguage(pf.outputLanguage)
            section0 = pf.section0       // prepareBlock(0) 直接用、跳过 extract-block
            batchPrevSummary = pf.prevSummary ?? batchPrevSummary
            isPreparingNext = true
            stageText = AppLocalized("继续讲解…")
            status = .planning
            if let pb0 = pf.preparedBlock0 {
                isPreparingNext = false
                enqueue(pb0, idx: 0)
                if totalBlocks > 1 {
                    startBackgroundPrepare(block: 1, reason: "batch-prefetched-block0")
                }
            } else {
                orchestrationTask = Task { [weak self] in
                    await self?.prepareAndEnqueue(block: 0, generation: generation)
                }
            }
            return
        }
        // 未预取 → 实时规划。
        section0 = nil
        jobId = ""
        totalBlocks = 0
        isPreparingNext = true
        stageText = AppLocalized("继续讲解…")
        status = .planning
        orchestrationTask = Task { [weak self] in
            await self?.runPlan(generation: generation)
        }
    }

    // MARK: - 页间预取（连续解读：当前页播放时后台预规划 + 预生成下一页首块，切页秒接）

    private struct BatchPlan {
        let startIndex: Int
        let jobId: String
        let totalBlocks: Int
        let outputLanguage: String
        let prevSummary: String?
        let section0: QuickreadSection   // 仅预规划首块文本，不预生成 TTS（TTSService 单请求，预生成会取消当前播放的 TTS）
        let preparedBlock0: PreparedBlock?
    }
    private var prefetchedBatch: BatchPlan?
    private var prefetchingBatchStart: Int?

    private func clearPagePrefetch() {
        pagePrefetchTask?.cancel()
        pagePrefetchTask = nil
        prefetchedBatch = nil
        prefetchingBatchStart = nil
    }

    /// 后台预规划下一批：倒数第二块播起先 plan，最后一块播起再生成下一批 block0 TTS，切批时直接播放。
    private func prefetchNextPage() {
        guard pro.isPro else { return }
        guard let start = pdfBatchCursor else { return }
        let batch = pdfBatch(fromGlobalIndex: start)
        guard !batch.paras.isEmpty else { return }
        let prevSummary = makeBatchContinuitySummary()

        if let existing = prefetchedBatch, existing.startIndex == start {
            guard existing.preparedBlock0 == nil,
                  currentBlockIndex >= max(0, totalBlocks - 1),
                  prefetchingBatchStart == nil else { return }
            prefetchingBatchStart = start
            let generation = contentGeneration
            pagePrefetchTask = Task { [weak self] in
                guard let self else { return }
                guard generation == self.contentGeneration, !Task.isCancelled else { return }
                do {
                    let pb0 = try await self.prepareSection(existing.section0, idx: 0, composeIdx: 0,
                                                            jobId: existing.jobId, language: existing.outputLanguage)
                    await MainActor.run {
                        guard generation == self.contentGeneration,
                              !Task.isCancelled else { return }
                        if self.prefetchedBatch?.startIndex == start {
                            self.prefetchedBatch = BatchPlan(startIndex: existing.startIndex,
                                                             jobId: existing.jobId,
                                                             totalBlocks: existing.totalBlocks,
                                                             outputLanguage: existing.outputLanguage,
                                                             prevSummary: existing.prevSummary,
                                                             section0: existing.section0,
                                                             preparedBlock0: pb0)
                            self.debugLog("prefetchBatch block0 READY start=%d marks=%d text=%d",
                                          start, pb0.marks.count, pb0.text.count)
                        }
                        if self.prefetchingBatchStart == start { self.prefetchingBatchStart = nil }
                        self.pagePrefetchTask = nil
                    }
                } catch {
                    await MainActor.run {
                        guard generation == self.contentGeneration else { return }
                        if self.prefetchingBatchStart == start { self.prefetchingBatchStart = nil }
                        self.pagePrefetchTask = nil
                    }
                }
            }
            return
        }

        guard prefetchedBatch == nil, prefetchingBatchStart == nil else { return }
        guard currentBlockIndex >= max(0, totalBlocks - 2) else { return }
        prefetchingBatchStart = start
        let generation = contentGeneration
        pagePrefetchTask = Task { [weak self] in
            guard let self else { return }
            guard generation == self.contentGeneration, !Task.isCancelled else { return }
            do {
                let plan = try await self.planBatch(startIndex: start, paras: batch.paras, prevSummary: prevSummary)
                guard generation == self.contentGeneration,
                      !Task.isCancelled else { return }
                if self.prefetchingBatchStart == start {
                    self.prefetchedBatch = plan
                    self.debugLog("prefetchBatch PLAN start=%d total=%d prevSummary=%d",
                                  start, plan.totalBlocks, plan.prevSummary?.count ?? 0)
                }
                self.prefetchingBatchStart = nil
                self.pagePrefetchTask = nil
                if self.currentBlockIndex >= max(0, self.totalBlocks - 1) {
                    self.prefetchNextPage()
                }
            } catch {
                guard generation == self.contentGeneration else { return }
                if self.prefetchingBatchStart == start { self.prefetchingBatchStart = nil }
                self.pagePrefetchTask = nil
            }
        }
    }

    /// 对给定批 extract-plan（仅规划，**不生成 TTS**）→ 切批时跳过「通读」那段 gap。
    /// 关键：不碰 TTSService（其为单请求模型，预生成 TTS 会取消当前正在播放的 TTS → "request was cancelled"）。
    private func planBatch(startIndex: Int, paras: [ReadingParagraph], prevSummary: String?) async throws -> BatchPlan {
        let req = buildPlanRequest(paras: paras, prevSummary: prevSummary)
        // onBlock0 在 QuickReadService actor 同步回调，用 Sendable box 收集（不写当前播放状态）。
        let box = PlanBlock0Box()
        let done = try await QuickReadService.shared.extractPlan(req, onStage: { _ in }, onBlock0: { box.set($0) })
        guard let b = box.value else { throw QuickReadError.noBlock0 }
        let lang = b.output_language ?? settings.explainLangOrNil ?? doc.language
        var total = max(1, b.total_blocks)
        if let tb = done.total_blocks, tb > total { total = tb }
        return BatchPlan(startIndex: startIndex, jobId: b.job_id, totalBlocks: total,
                         outputLanguage: lang, prevSummary: prevSummary, section0: b.block_0,
                         preparedBlock0: nil)
    }

    func currentContinuitySummary() -> String? {
        makeBatchContinuitySummary()
    }

    func prefetchFirstBlock(
        for targetDocument: ReadingDocument,
        previousSummary: String?,
        textFingerprint: String
    ) async throws -> PrefetchedFirstBlock {
        guard pro.isPro else { throw CancellationError() }
        let readableChars = targetDocument.readableParagraphs.reduce(0) {
            $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        guard readableChars >= minExplainChars else { throw QuickReadError.noBlock0 }
        let req = buildPlanRequest(document: targetDocument, paras: targetDocument.paragraphs, prevSummary: previousSummary)
        let box = PlanBlock0Box()
        let done = try await QuickReadService.shared.extractPlan(
            req,
            onStage: { _ in },
            onBlock0: { box.set($0) }
        )
        guard let b = box.value else { throw QuickReadError.noBlock0 }
        let lang = b.output_language ?? settings.explainLangOrNil ?? targetDocument.language
        var total = max(1, b.total_blocks)
        if let tb = done.total_blocks, tb > total { total = tb }
        let pb0 = try await prepareSection(
            b.block_0,
            idx: 0,
            composeIdx: 0,
            jobId: b.job_id,
            language: lang,
            detachedTTS: true
        )
        debugLog("prefetch first block READY job=%@ total=%d marks=%d text=%d fp=%@",
                 b.job_id, total, pb0.marks.count, pb0.text.count, String(textFingerprint.prefix(24)))
        return PrefetchedFirstBlock(
            jobId: b.job_id,
            totalBlocks: total,
            outputLanguage: lang,
            textFingerprint: textFingerprint,
            previousSummary: previousSummary,
            section0: b.block_0,
            block0: pb0
        )
    }

    // MARK: - marks 触发（块时间线）

    private func onTick(_ t: Double) {
        guard ownsAudioQueue else { return }
        guard let seg = audio.currentSegment, seg.paragraphIndex == currentBlockIndex else { return }
        let segs = prepared[currentBlockIndex]?.segments ?? marksContextSegments
        let priorDuration = segs.prefix(while: { $0.id != seg.id }).reduce(0) { $0 + effectiveDuration($1) }
        let blockElapsed = priorDuration + t

        // 字幕逐句：按块内播放进度选当前句（解读后端常把整块合成一个大 segment，不能用 seg.text 当一句）。
        if let sentences = prepared[currentBlockIndex]?.sentences {
            let blockDur = segs.reduce(0) { $0 + effectiveDuration($1) }
            let progress = blockDur > 0.01 ? blockElapsed / blockDur : 0
            if currentBlockIndex == 0,
               ProductAnalytics.isMeaningfulExplainBlockProgress(progress) {
                recordAnalyticsBlockCompleted(0)
            }
            if let cur = Self.subtitleForProgress(sentences, progress: progress), explanationText != cur {
                explanationText = cur
                updateNowPlayingCaption(cur)
            }
        }

        guard let events = marksByBlock[currentBlockIndex] else { return }
        for (i, ev) in events.enumerated() {
            guard let at = ev.at, at <= blockElapsed else { continue }
            let key = "\(currentBlockIndex)#\(i)"
            if firedMarks.contains(key) { continue }
            firedMarks.insert(key)
            resolveAndShow(ev)
        }
    }

    private func updateNowPlayingCaption(_ caption: String?) {
        guard caption != lastNowPlayingCaption else { return }
        lastNowPlayingCaption = caption
        audio.setNowPlayingCaption(caption)
    }

    /// 当前块入队后 segments 也存于 prepared；兜底空数组。
    private var marksContextSegments: [AudioSegment] { prepared[currentBlockIndex]?.segments ?? [] }

    // MARK: - 字幕分句（纯函数，可自测）

    /// 讲解文本切成字幕条：①按句末标点切句（中文 。！？；+ 英文 !?; + … + 换行，英文句点仅后接空格/结尾才切避免小数）；
    /// ②过长句（>chunkLimit）再按逗号/分号/顿号二次切——否则中文长句一条字幕就是一大段（对齐扩展 buildLines 的 CHUNK 切分）。
    static func splitSentences(_ text: String) -> [String] {
        let chunkLimit = 24   // 单条字幕上限（中文≈1.5 行）：长句按逗号切到此长度，短小一条一条出
        guard !text.isEmpty else { return [] }
        // ① 与朗读/PDF/Now Playing 共享九语句界（含 Hindi ।/॥）。
        var sentences = ReadingSentenceContract.segments(text, lineBreakIsBoundary: true)
        if sentences.isEmpty { sentences = [text] }
        // ② 过长句按逗号/分号/顿号二次切到 ≤chunkLimit（字幕条短小、一条一条出）
        var out: [String] = []
        for s in sentences {
            if s.count <= chunkLimit { out.append(s); continue }
            var buf = ""
            for part in commaParts(s) {
                if !buf.isEmpty && (buf.count + part.count) > chunkLimit {
                    out.append(buf); buf = part
                } else {
                    buf += part
                }
            }
            if !buf.isEmpty { out.append(buf) }
        }
        return out.isEmpty ? [text] : out
    }

    /// 按逗号/分号/顿号切分（保留分隔标点），供过长句二次切分。
    private static func commaParts(_ s: String) -> [String] {
        let seps: Set<Character> = ["，", ",", "；", ";", "、"]
        var parts: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if seps.contains(ch) { parts.append(cur); cur = "" }
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.isEmpty ? [s] : parts
    }

    /// 按播放进度（0..1）选当前句：累积字符比例首次 ≥ progress 的句。
    static func subtitleForProgress(_ sentences: [String], progress: Double) -> String? {
        guard !sentences.isEmpty else { return nil }
        let p = min(1, max(0, progress))
        let total = sentences.reduce(0) { $0 + $1.count }
        guard total > 0 else { return sentences.first }
        let target = Double(total) * p
        var acc = 0.0
        for s in sentences {
            acc += Double(s.count)
            if acc >= target { return s }
        }
        return sentences.last
    }

    private func resolveAndShow(_ ev: QuickreadEvent) {
        guard let anchorText = ev.text, !anchorText.isEmpty else { return }
        markTotal += 1
        guard let hit = MarkAnchoring.locate(markText: anchorText, in: doc, near: anchorCursor) else {
            debugLog("mark MISS %d/%d [%@]", markHit, markTotal, String(anchorText.prefix(28)))
            return
        }
        markHit += 1
        debugLog("mark HIT %d/%d para=%d [%@]", markHit, markTotal, hit.paragraphIndex, String(anchorText.prefix(28)))
        anchorCursor = hit.paragraphIndex
        let seed = "\(hit.paragraphIndex)-\(hit.range.lowerBound)-\(ev.action)".stableSeed
        let mark = ResolvedMark(id: ev.id, paragraphIndex: hit.paragraphIndex,
                                charRange: hit.range, action: ev.action, n: ev.n, seed: seed,
                                weight: ev.weight, role: ev.role)
        activeMarks.append(mark)
        scrollTarget = hit.paragraphIndex   // 跟随讲解滚动
    }

    // MARK: - Helpers

    private func ensureTiming(_ marks: [QuickreadEvent], duration: Double) -> [QuickreadEvent] {
        guard !marks.isEmpty else { return marks }
        let missing = marks.contains { $0.at == nil }
        guard missing, duration > 0 else { return marks.sorted { ($0.at ?? 0) < ($1.at ?? 0) } }
        // 均匀铺开
        return marks.enumerated().map { (i, ev) in
            var copy = ev
            if copy.at == nil {
                copy.at = duration * Double(i) / Double(max(1, marks.count))
            }
            return copy
        }.sorted { ($0.at ?? 0) < ($1.at ?? 0) }
    }

    private var pdfScopedParagraphs: [ReadingParagraph]?
    private var pdfAllParagraphs: [ReadingParagraph]?   // PDF 全部段落（有序，连续解读用）
    private var pdfBatchCursor: Int?                     // 下一批起始全局段索引（nil = 已到末尾）
    private var batchPrevSummary: String?                // 长文分批承接：上一批讲解摘要，传给下一批 prev_summary
    /// 单次 plan 的内容上限（字符）。对齐「网页解读一次喂一篇文章」的体量——批太大后端切块变粗、mark 摊薄
    /// （实测 9000 字才 6 块/20 mark → PDF 一页才一个）；太小则批边界频繁、衔接差。
    /// ~3000 字≈5 页≈一篇短文，让后端对每批的切块/标注密度回到网页那种水平（mark 密）。后端 plan 无续接上下文，批内才连贯。
    private let pdfBatchCharLimit = 3000

    /// PDF：解读从当前可见页起，按「批」连续规划（批内连贯有衔接），播完一批自动续下一批直到末尾（听完整本）。
    func setPdfScope(_ paras: [ReadingParagraph]?, all: [ReadingParagraph]? = nil) {
        if let all { pdfAllParagraphs = all }
        clearPagePrefetch()
        batchPrevSummary = nil
        guard let startId = paras?.first?.id, !(paras?.isEmpty ?? true) else {
            pdfScopedParagraphs = nil; pdfBatchCursor = nil; return
        }
        let batch = pdfBatch(fromGlobalIndex: startId)
        pdfScopedParagraphs = batch.paras.isEmpty ? nil : batch.paras
        pdfBatchCursor = batch.next
        anchorCursor = batch.paras.first?.id   // mark 锚定优先当前批段落（不回前面批找重复文本）
    }

    /// 内容超过一批阈值时（整本 EPUB 4094 段等），解读改分批：设第一批 scope，复用 PDF 连续解读续批，
    /// 避免把整本书一次性 extract-plan（请求体过大 → 后端 400）。PDF 已由翻页设 scope，这里不覆盖。
    private func setupBatchScopeIfLarge() {
        guard pdfScopedParagraphs == nil else { return }
        let paras = doc.paragraphs
        let total = paras.reduce(0) { $0 + $1.text.count }
        guard total > pdfBatchCharLimit, let first = paras.first else { return }
        setPdfScope([first], all: paras)
    }

    /// 解读未启动 → PDFReaderView 翻页时据此决定是否把当前可见页设为解读起点（进行中翻页不改起点）。
    var isExplainIdle: Bool { status == .idle || isErrorState }

    /// 从全局段索引 start 起累积一批（直到字数上限或末尾）。返回批段落 + 下一批起始索引（nil=末尾）。
    /// 依赖 fromPDFNative 里 ReadingParagraph.id 连续递增（id == all 数组下标）。
    private func pdfBatch(fromGlobalIndex start: Int) -> (paras: [ReadingParagraph], next: Int?) {
        let all = pdfAllParagraphs ?? []
        guard start >= 0, start < all.count else { return ([], nil) }
        var paras: [ReadingParagraph] = []
        var chars = 0
        var i = start
        while i < all.count {
            paras.append(all[i])
            chars += all[i].text.count
            i += 1
            if chars >= pdfBatchCharLimit { break }
        }
        return (paras, i < all.count ? i : nil)
    }

    private func buildPlanRequest() -> ExtractPlanRequest {
        buildPlanRequest(paras: pdfScopedParagraphs ?? doc.paragraphs, prevSummary: batchPrevSummary)
    }

    private func buildPlanRequest(paras sourceParas: [ReadingParagraph], prevSummary: String?) -> ExtractPlanRequest {
        buildPlanRequest(document: doc, paras: sourceParas, prevSummary: prevSummary)
    }

    /// A cloud document's stable local ID is derived from provider/account/item
    /// identifiers and must never leave the device as a long-lived pseudonym.
    /// The remote filename is metadata too, so QuickRead receives a generic
    /// title while still receiving the user-requested document text.
    static func quickReadSourceURL(for document: ReadingDocument) -> String {
        guard document.origin == nil else { return "castreader://cloud-document" }
        return document.sourceURL ?? "castreader://doc/\(document.id)"
    }

    static func quickReadTitle(for document: ReadingDocument) -> String {
        document.origin == nil ? document.title : "Cloud document"
    }

    private func buildPlanRequest(document targetDoc: ReadingDocument, paras sourceParas: [ReadingParagraph], prevSummary: String?) -> ExtractPlanRequest {
        let paras = sourceParas.map { QuickreadParagraphDTO(text: $0.text, type: typeString($0.type)) }
        let fullText = sourceParas.map(\.text).joined(separator: "\n\n")
        let src = Self.quickReadSourceURL(for: targetDoc)
        let continuity = QuickReadFastLaneHandoff.continuitySummary(
            explicitPreviousSummary: prevSummary,
            fastNarration: fastSection?.text
        )
        return ExtractPlanRequest(
            source_url: src,
            title: Self.quickReadTitle(for: targetDoc),
            lang: forcedExplainLang ?? settings.explainLangOrNil,   // 快道激活 → 用锁定语言，与快道 block_0 一致
            depth: requestDepth,                                    // 永远=用户设置的 3 档；场景不改深度（与 content_type 正交）
            text: fullText,
            fullText: fullText,
            paragraphs: paras,
            // prev_summary 有两种来源：①快道 narration → 质道接着讲；②长文分批上一批摘要 → 下一批接着讲。
            // 后端看到该字段后应避免重新开场、复述全文，而是从本批开头顺序续讲。
            prev_summary: continuity,
            content_type: scenario                                  // 场景信号（nil = 通用解读）
        )
    }

    private func makeBatchContinuitySummary() -> String? {
        let texts = (0..<max(0, totalBlocks))
            .compactMap { prepared[$0]?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !texts.isEmpty else { return batchPrevSummary }
        let joined = texts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return batchPrevSummary }
        let clipped = String(joined.suffix(900))
        if let previous = batchPrevSummary, !previous.isEmpty {
            let combined = (previous + " " + clipped)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(combined.suffix(1200))
        }
        return clipped
    }

    private func typeString(_ t: ReadingParagraphType) -> String {
        switch t {
        case .paragraph: return "paragraph"
        case .heading: return "heading"
        case .blockquote: return "blockquote"
        case .code: return "code"
        case .list: return "list"
        case .caption: return "caption"
        case .image: return "caption"   // 图片段（text 已置空）映射为后端已知类型，避免未知 type
        }
    }

    private func friendlyStage(_ s: String) -> String {
        switch s {
        case "extract": return AppLocalized("通读全文…")
        case "compose": return AppLocalized("组织讲解…")
        default: return s
        }
    }
}

/// 跨 actor 收集 SSE block0：extractPlan 的 onBlock0 在 QuickReadService actor 上同步回调，
/// 用 Sendable box 把结果带回 @MainActor 的预取流程（避免在并发上下文写局部 var）。
private final class PlanBlock0Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PlanBlock0?
    var value: PlanBlock0? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: PlanBlock0) { lock.lock(); stored = v; lock.unlock() }
}
