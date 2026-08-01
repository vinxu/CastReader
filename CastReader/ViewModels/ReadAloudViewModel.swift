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
    private var preloaded = Set<Int>()
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

    // .web 源：段落由 WebView extractor 提取后注入；朗读输出经 bridge 驱动 DOM 高亮。
    private var webParagraphs: [ReadingParagraph]? = nil
    private var webLanguage: String? = nil
    private var preferredLiveWebStartIndex: Int?
    private struct PendingLiveWebResume {
        let anchor: WeReadPlaybackResumeAnchor
        let paragraphIndex: Int
    }
    private var pendingLiveWebResume: PendingLiveWebResume?
    private var isAwaitingLiveWebCarryCompletion = false
    private var pendingLiveWebCarryStartIndex: Int?
    private var paras: [ReadingParagraph] { webParagraphs ?? document.paragraphs }
    /// 有效朗读语言：.web 源用从正文检测的语言，否则用 document.language。
    private var docLanguage: String { webLanguage ?? document.language }
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
    private var lastSegmentMaxTime: Double = 0
    private var graceSeconds: Double = 0
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
    private var analyticsReadSessionId: String?
    private var analyticsReadStartedAt: Date?
    private var analyticsFirstAudioTracked = false
    private var analyticsPlaybackSeconds: Double = 0
    private var analyticsMilestones = Set<Int>()
    private var analyticsLastSegmentId: String?
    private var analyticsLastPosition: Double?
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

    init(document: ReadingDocument, analyticsContext: AnalyticsContentContext? = nil) {
        self.document = document
        self.analyticsContext = analyticsContext ?? AnalyticsContentContext.fallback(for: document)
        self.playbackVoiceID = AppSettings.shared.voice(for: document.language)
        recomputeReadableIndices()
        bind()
    }

    func configurePlaybackMetadata(id: String, title: String, coverURL: String?, chapterTitle: String? = nil) {
        playbackBookID = id
        playbackTitle = title
        playbackCoverURL = coverURL
        playbackChapterTitle = chapterTitle
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
    func detachForContinuousPageHandoff() -> AppReviewReadSessionProgress? {
        guard ownsAudioQueue else { return nil }
        invalidateAccessRetry()
        let reviewSession = appReviewReadSession
        generationEpoch &+= 1
        commitListen()
        endAnalyticsReadSession(
            result: .success,
            reason: "kindle_page_handoff",
            preserveAppReviewReadSession: true
        )
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
              analyticsReadSessionId == nil else { return false }
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
        guard analyticsReadSessionId != nil else { return nil }
        return AppReviewAutomaticPageContinuation.candidate(
            appReviewReadSession,
            for: document.sourceKind
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
        updateNowPlayingCaption(adoptionTime)

        preloadNext(after: paragraphIndex)
        return true
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
            .filter { $0.element.type.isReadable && SpeechTextSanitizer.containsSpeakableContent($0.element.text) }
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
        guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else {
            if allowAccessRefresh {
                refreshAccessThenRetryStart()
                return
            }
            status = .pending
            showPaywall = true
            return
        }
        invalidateAccessRetry()
        beginAnalyticsReadSessionIfNeeded(resume: false)
        activate()
        applyPlaybackMetadata()
        applySpeed()
        let preferred = preferredLiveWebStartIndex.flatMap { readableIndices.contains($0) ? $0 : nil }
        preferredLiveWebStartIndex = nil
        generate(preferred ?? readableIndices[0])
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
        if !audio.isPlaying, !pro.isPro, !quota.canStartListen(isPro: pro.isPro) {
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
            guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else {
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
        guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else {
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
        guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else {
            if allowAccessRefresh {
                refreshAccessThenRetryJump(to: paragraphIndex)
                return
            }
            status = .pending
            showPaywall = true
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
        beginAnalyticsReadSessionIfNeeded(resume: currentParagraphIndex >= 0)
        generate(paragraphIndex)
    }

    /// 用外部已经生成好的首段音频启动朗读。Kindle 页级预加载会使用这个入口：
    /// 页面 OCR/文档和下一页首段 TTS 都提前完成时，翻页后无需再等首字节。
    func startWithPrefetchedSegments(_ segments: [AudioSegment], paragraphIndex: Int) {
        startWithPrefetchedSegments(segments, paragraphIndex: paragraphIndex, allowAccessRefresh: true)
    }

    private func startWithPrefetchedSegments(_ segments: [AudioSegment], paragraphIndex: Int, allowAccessRefresh: Bool) {
        guard readableIndices.contains(paragraphIndex), !segments.isEmpty else {
            jump(to: paragraphIndex)
            return
        }
        guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else {
            if allowAccessRefresh {
                refreshAccessThenRetryPrefetched(segments, paragraphIndex: paragraphIndex)
                return
            }
            status = .pending
            showPaywall = true
            return
        }

        invalidateAccessRetry()
        beginAnalyticsReadSessionIfNeeded(resume: currentParagraphIndex >= 0)
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
        _ = audio.loadSegments(
            segments,
            autoPlay: !liveWebTurnIntentSuspended,
            session: token
        )

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
            if self.pro.isPro || self.quota.canStartListen(isPro: self.pro.isPro) {
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

    private func refreshAccessThenRetryPrefetched(_ segments: [AudioSegment], paragraphIndex: Int) {
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
                allowAccessRefresh: false
            )
        }
    }

    func setSpeed(_ s: Double) {
        settings.speed = s   // 触发 applySpeed 经由订阅
    }

    private func applySpeed() {
        audio.setPlaybackRate(Float(settings.effectiveSpeed(isPro: pro.isPro)))
    }

    func stop() {
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
        status = .pending
        if let switchID = activeVoiceSwitchID {
            VoiceSwitchStatusCenter.shared.finish(switchID)
            activeVoiceSwitchID = nil
        }
        commitListen()
        endAnalyticsReadSession(result: .cancelled, reason: "closed")
    }

    // MARK: - Generation

    private func generate(
        _ index: Int,
        voiceOverride: String? = nil,
        autoPlay: Bool = true,
        voiceSwitchID: UUID? = nil
    ) {
        guard isActive, paras.indices.contains(index) else { return }
        guard let session = ensureAudioSessionClaim() else { return }
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
        segmentsByParagraph[index] = []
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
                NSLog("CRDBG generate request begin para=%d voice=%@ epoch=%llu", index, voice, epoch)
                try await TTSService.shared.generateTTSForParagraph(
                    paragraphIndex: index,
                    text: SpeechTextSanitizer.sanitizedForTTS(para.text),
                    voice: voice,
                    speed: 1.0,                       // 1.0 生成，播放用 playbackRate
                    language: self.docLanguage
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
                if self.generationEpoch == epoch, self.isActive {
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

    private func handleVoicePreferenceChanged() {
        let newVoiceID = settings.voice(for: docLanguage)
        guard newVoiceID != playbackVoiceID else { return }
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
        _ = preloaded.insert(index)
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
        let epoch = generationEpoch
        let para = paras[nextIndex]
        let voice = settings.voice(for: docLanguage)
        let lang = docLanguage
        NSLog("CRDBG prefetch start para=%d", nextIndex)
        ReaderRunLog.write(
            "READ prefetch start para=\(nextIndex) epoch=\(epoch) " +
            "chars=\(para.text.utf16.count)"
        )
        prefetchTask = Task { [weak self] in
            do {
                let collected = try await TTSService.shared.generatePrefetchSegments(
                    paragraphIndex: nextIndex,
                    text: SpeechTextSanitizer.sanitizedForTTS(para.text),
                    voice: voice,
                    speed: 1.0,
                    language: lang
                )
                guard let self,
                      !Task.isCancelled,
                      self.isActive,
                      self.generationEpoch == epoch,
                      self.prefetchingIndex == nextIndex else { return }
                self.prefetchedSegments = collected
                self.prefetchedIndex = nextIndex
                self.prefetchingIndex = nil
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
    }

    /// 把已预取的下一段缓存「转正」为当前段：重置高亮状态 + 一次性入队播放（无 TTS 等待），并继续预取再下一段。
    private func promotePrefetch(to index: Int) {
        guard isActive else { return }
        guard let session = ensureAudioSessionClaim() else { return }
        let segs = prefetchedSegments
        prefetchedSegments = []
        prefetchedIndex = nil
        prefetchingIndex = nil
        prefetchTask = nil
        guard !segs.isEmpty else { generate(index); return }
        NSLog("CRDBG promote prefetch para=%d segs=%d", index, segs.count)
        ReaderRunLog.write(
            "READ prefetch promote para=\(index) segs=\(segs.count)"
        )

        // 重置段/高亮状态（对齐 generate 开头），但不重新请求 TTS。
        segmentsByParagraph[index] = segs
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
                endAnalyticsReadSession(result: .success, reason: "completed")
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
            endAnalyticsReadSession(result: .success, reason: "completed")
            onDocumentFinished?(automaticPageContinuation)
            return
        }
        // 段落边界做额度闸门（“读完本篇”自然边界）
        if !pro.isPro && !quota.canStartListen(isPro: pro.isPro) {
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
        let nextIndex = readableIndices[nextPos]
        // ① 预取已就绪 → 秒接，无需重新请求 TTS（消除段间等首字节的 gap）
        if prefetchedIndex == nextIndex, !prefetchedSegments.isEmpty {
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
                    self.generate(nextIndex)
                }
            }
            return
        }
        // ③ 无预取 → 正常生成
        ReaderRunLog.write(
            "READ boundary no prefetch next=\(nextIndex); foreground generate"
        )
        generate(nextIndex)
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
        updateHighlight(t)
        updateNowPlayingCaption(t)
        signalPageBoundaryIfNeeded(t)
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
                highlightRange = NSRange(location: base + content.location, length: content.length)
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
                    photoHighlightWordRange = range
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
                highlightRange = r
            }
        } else if document.sourceKind.isOCRImageRendered {
            ensureOCRWordAligned()
            let gIdx = wordHighlightSegments(segs).prefix(segPos).reduce(0) { $0 + $1.timestamps.count } + localIdx
            if gIdx >= 0, gIdx < ocrWordIndexes.count, let idx = ocrWordIndexes[gIdx] {
                let next = max(photoHighlightWordIndex ?? -1, idx)
                photoHighlightWordRange = next..<(next + 1)
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
            allowFallback: allowFallback
        )
        ocrAlignedPara = currentParagraphIndex
        ocrAlignedSegCount = segs.count
        #if DEBUG
        let hit = ocrWordIndexes.compactMap { $0 }.count
        let total = ocrWordIndexes.count
        if total > 0 {
            NSLog("CRDBG ocr align para=%d hit=%d/%d mode=%@",
                  currentParagraphIndex,
                  hit,
                  total,
                  allowFallback ? "fallback" : "strict")
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
        guard analyticsReadSessionId == nil else { return }
        if preserveAppReviewSessionOnNextAnalyticsBegin {
            preserveAppReviewSessionOnNextAnalyticsBegin = false
        } else {
            appReviewReadSession = AppReviewReadSessionProgress()
            onAppReviewReadSessionInvalidated?()
        }
        analyticsReadSessionId = UUID().uuidString
        analyticsReadStartedAt = Date()
        analyticsFirstAudioTracked = false
        analyticsPlaybackSeconds = 0
        analyticsMilestones.removeAll()
        analyticsLastSegmentId = nil
        analyticsLastPosition = nil
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
                resume: resume || analyticsContext.entryPoint == "history_resume",
                storefront: analyticsContext.storefront
            )
        )
    }

    private func handlePlaybackState(_ playing: Bool) {
        let ownedPlaying = playing && ownsAudioQueue
        isPlaying = ownedPlaying
        guard ownedPlaying else {
            analyticsLastSegmentId = nil
            analyticsLastPosition = nil
            return
        }
        guard !analyticsFirstAudioTracked,
              analyticsReadSessionId != nil,
              audio.currentSegment != nil else { return }
        analyticsFirstAudioTracked = true
        let latency = max(0, Int(Date().timeIntervalSince(analyticsReadStartedAt ?? Date()) * 1000))
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
              analyticsReadSessionId != nil,
              let segment = audio.currentSegment else { return }
        if analyticsLastSegmentId == segment.id,
           let previous = analyticsLastPosition,
           currentTime >= previous {
            let rawPlaybackDelta = currentTime - previous
            // Preserve the existing analytics cap, but give onboarding the raw
            // delta so a manual seek is rejected instead of becoming two fake
            // seconds of activation.
            let playbackDelta = min(2.0, rawPlaybackDelta)
            analyticsPlaybackSeconds += playbackDelta
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
        analyticsLastSegmentId = segment.id
        analyticsLastPosition = currentTime

        for milestone in [30, 180, 300, 600, 1800]
        where analyticsPlaybackSeconds >= Double(milestone) && !analyticsMilestones.contains(milestone) {
            analyticsMilestones.insert(milestone)
            if milestone >= 300 { ProductAnalytics.shared.noteMeaningfulReadReached() }
            ProductAnalytics.shared.track(
                .readMilestone,
                context: analyticsEventContext,
                properties: .init(
                    milestoneSeconds: milestone,
                    playbackSeconds: Int(analyticsPlaybackSeconds),
                    completionBucket: analyticsCompletionBucket,
                    storefront: analyticsContext.storefront
                )
            )
        }
    }

    private func endAnalyticsReadSession(
        result: AnalyticsResult,
        reason: String,
        errorStage: String? = nil,
        errorCode: String? = nil,
        preserveAppReviewReadSession: Bool = false
    ) {
        if analyticsReadSessionId != nil {
            ProductAnalytics.shared.track(
                .readEnd,
                context: analyticsEventContext,
                properties: .init(
                    result: result.rawValue,
                    errorStage: errorStage,
                    errorCode: errorCode,
                    playbackSeconds: Int(analyticsPlaybackSeconds),
                    completionBucket: analyticsCompletionBucket,
                    endReason: reason,
                    storefront: analyticsContext.storefront
                )
            )
        }
        analyticsReadSessionId = nil
        analyticsReadStartedAt = nil
        analyticsFirstAudioTracked = false
        analyticsLastSegmentId = nil
        analyticsLastPosition = nil
        if !preserveAppReviewReadSession {
            appReviewReadSession = AppReviewReadSessionProgress()
            preserveAppReviewSessionOnNextAnalyticsBegin = false
            onAppReviewReadSessionInvalidated?()
        }
    }

    private var analyticsEventContext: AnalyticsEventContext {
        AnalyticsEventContext(
            productArea: .readAloud,
            surface: document.sourceKind == .kindle ? "kindle_reader" : "reader",
            entryPoint: analyticsContext.entryPoint,
            contentSessionId: analyticsContext.contentSessionId,
            readSessionId: analyticsReadSessionId
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
        if seg.id == lastSegmentId {
            if t > lastSegmentMaxTime { lastSegmentMaxTime = t }
        } else {
            commitListen()
            lastSegmentId = seg.id
            lastSegmentMaxTime = t
        }
        // 宽限硬上限：超额后继续播放累计，超过 graceCap 强制停止
        if !pro.isPro && quota.listenRemaining <= 0 {
            if graceSeconds > quota.graceCapSeconds {
                refreshAccessThenHandleListenCap()
            }
        }
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
        guard lastSegmentMaxTime > 0 else { return }
        let delta = lastSegmentMaxTime
        if !pro.isPro && quota.listenRemaining <= 0 {
            graceSeconds += delta
        }
        quota.addListen(delta)
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
