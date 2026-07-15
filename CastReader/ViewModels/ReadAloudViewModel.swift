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

/// PDF 词级高亮指令：当前句(段)内、跨 segment 拼接的词数组 + 当前词全局索引。
/// PDFReaderView 据此在句范围内 findString 定位词并画矩形（英文有词时间戳→逐词；中文无→不更新，保留句级淡高亮）。
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

    private var segmentsByParagraph: [Int: [AudioSegment]] = [:]
    private var generationTask: Task<Void, Never>?
    private var listenCapRefreshTask: Task<Void, Never>?
    private var preloaded = Set<Int>()
    private var cancellables = Set<AnyCancellable>()
    private var readableIndices: [Int] = []

    // 预生成下一段 TTS（消除段间等首字节的 gap）：当前段生成完即后台预取下一段到缓存，advance 命中则秒接。
    private var prefetchTask: Task<Void, Never>?
    private var prefetchingIndex: Int? = nil     // 正在预取中的段
    private var prefetchedIndex: Int? = nil       // 已预取完成、可秒接的段
    private var prefetchedSegments: [AudioSegment] = []

    // .web 源：段落由 WebView extractor 提取后注入；朗读输出经 bridge 驱动 DOM 高亮。
    private var webParagraphs: [ReadingParagraph]? = nil
    private var webLanguage: String? = nil
    private var paras: [ReadingParagraph] { webParagraphs ?? document.paragraphs }
    /// 有效朗读语言：.web 源用从正文检测的语言，否则用 document.language。
    private var docLanguage: String { webLanguage ?? document.language }
    @Published var webAudioSegments: [AudioSegment] = []   // 扁平全局顺序（供 bridge 转 JS audioSegments）
    @Published var webHighlight: WebHighlightCmd? = nil     // 当前 DOM 高亮指令（句级/词级）
    @Published var pdfHighlight: PDFWordHighlight? = nil    // PDF 词级高亮（英文逐词；中文无词时间戳→不更新，保留句级淡高亮）

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

    // 产品分析会话只使用播放器真实推进时间；跳读造成的大跨度 currentTime 不计入里程碑。
    private var analyticsReadSessionId: String?
    private var analyticsReadStartedAt: Date?
    private var analyticsFirstAudioTracked = false
    private var analyticsPlaybackSeconds: Double = 0
    private var analyticsMilestones = Set<Int>()
    private var analyticsLastSegmentId: String?
    private var analyticsLastPosition: Double?

    private var playbackBookID: String?
    private var playbackTitle: String?
    private var playbackChapterTitle: String?
    private var playbackCoverURL: String?
    var onDocumentFinished: (() -> Void)?

    init(document: ReadingDocument, analyticsContext: AnalyticsContentContext? = nil) {
        self.document = document
        self.analyticsContext = analyticsContext ?? AnalyticsContentContext.fallback(for: document)
        recomputeReadableIndices()
        bind()
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
            chapterTitle: playbackChapterTitle,
            coverUrl: playbackCoverURL
        )
    }

    deinit {
        generationTask?.cancel()
        listenCapRefreshTask?.cancel()
    }

    private func recomputeReadableIndices() {
        readableIndices = paras.enumerated()
            .filter { $0.element.type.isReadable && SpeechTextSanitizer.containsSpeakableContent($0.element.text) }
            .map { $0.offset }
    }

    /// .web：注入 WebView extractor 提取的正文段落，准备朗读。
    func loadWebParagraphs(_ p: [ReadingParagraph], language: String? = nil) {
        webParagraphs = p
        if let language { webLanguage = language }
        webAudioSegments = []
        recomputeReadableIndices()
    }

    private func setWebHighlight(_ c: WebHighlightCmd) {
        guard webHighlight != c else { return }
        webHighlight = c
    }

    /// 按句末标点切句，返回每句在原文中的字符范围（去句首空白）。
    private func sentenceRanges(_ text: String) -> [Range<Int>] {
        let chars = Array(text)
        var ranges: [Range<Int>] = []
        var start = 0
        func flush(_ end: Int) {
            var s = start
            while s < end, chars[s].isWhitespace || chars[s].isNewline { s += 1 }
            if s < end { ranges.append(s..<end) }
            start = end
        }
        for i in 0..<chars.count where "。！？!?；;\n".contains(chars[i]) { flush(i + 1) }
        if start < chars.count { flush(chars.count) }
        return ranges.isEmpty ? [0..<chars.count] : ranges
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
            .sink { [weak self] b in self?.isBuffering = b }
            .store(in: &cancellables)
        settings.$speed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySpeed() }
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
        isActive = true
        audio.onPlaybackComplete = { [weak self] in self?.advance() }
    }

    /// 退出激活（切到解读模式时调用）：必须停掉生成/预取，否则流式生成的新 segment 经 loadSegment 会自动
    /// 重新 playSegment（首段未播放时），导致「切到解读后朗读还在响」。
    func deactivate() {
        endAnalyticsReadSession(result: .cancelled, reason: "mode_switched")
        isActive = false
        generationTask?.cancel()
        listenCapRefreshTask?.cancel()
        listenCapRefreshTask = nil
        clearPrefetch()
        Task { await TTSService.shared.cancelCurrentRequest() }
        audio.moreSegmentsExpected = false
        audio.pause()
        audio.setNowPlayingCaption(nil)
        lastNowPlayingCaption = nil
        // 清朗读高亮状态，避免切到解读后残留（web 源 DOM 另由 setActive→clearOverlay 清）
        highlightRange = nil
        photoHighlightWordIndex = nil
        webHighlight = nil
        pdfHighlight = nil
    }

    // MARK: - Start / control

    func start() {
        start(allowAccessRefresh: true)
    }

    private func start(allowAccessRefresh: Bool) {
        guard !readableIndices.isEmpty else { status = .error(String(localized: "无可朗读内容")); return }
        guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else {
            if allowAccessRefresh {
                refreshAccessThenRetryStart()
                return
            }
            status = .pending
            showPaywall = true
            return
        }
        beginAnalyticsReadSessionIfNeeded(resume: false)
        activate()
        applyPlaybackMetadata()
        applySpeed()
        generate(readableIndices[0])
    }

    func togglePlayPause() {
        if currentParagraphIndex < 0 { start(); return }
        // 从暂停恢复播放时补额度闸门：否则免费用户在「宽限硬上限」弹墙后关墙、再点播放即可无限续听。
        if !audio.isPlaying, !pro.isPro, !quota.canStartListen(isPro: pro.isPro) {
            refreshAccessThenRetryResume()
            return
        }
        if !audio.isPlaying { beginAnalyticsReadSessionIfNeeded(resume: true) }
        audio.togglePlayPause()
    }

    /// Idempotent entry-point for external "Continue Listening" actions.
    /// Reattaching while audio is playing or TTS is still loading must not pause
    /// playback or start a duplicate generation request.
    func ensurePlaying() {
        if audio.isPlaying { return }
        if currentParagraphIndex < 0 {
            start()
            return
        }
        if status.isLoading || isBuffering || (status.isStreaming && audio.currentSegment == nil) {
            return
        }
        guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else {
            refreshAccessThenRetryResume()
            return
        }
        if audio.currentSegment != nil {
            beginAnalyticsReadSessionIfNeeded(resume: true)
            audio.play()
        } else if !isFinished {
            jump(to: currentParagraphIndex)
        }
    }

    func skipForward() { audio.skipForward(seconds: 15) }
    func skipBackward() { audio.skipBackward(seconds: 15) }

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

        beginAnalyticsReadSessionIfNeeded(resume: currentParagraphIndex >= 0)
        activate()
        applyPlaybackMetadata()
        applySpeed()
        isFinished = false
        generationTask?.cancel()
        clearPrefetch()

        audio.clearQueue()
        audio.moreSegmentsExpected = false
        segmentsByParagraph[paragraphIndex] = segments
        currentParagraphIndex = paragraphIndex
        processedDisplayText = segments.map { $0.text }.joined()
        highlightRange = nil
        photoHighlightWordIndex = nil
        pdfHighlight = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        status = .ready
        if document.sourceKind.isWebRendered { webAudioSegments.append(contentsOf: segments) }
        audio.loadSegments(segments)

        Task { [weak self] in await self?.preloadNext(after: paragraphIndex) }
    }

    private func refreshAccessThenRetryStart() {
        status = .loading
        Task { [weak self] in
            await ProManager.shared.refresh()
            self?.start(allowAccessRefresh: false)
        }
    }

    private func refreshAccessThenRetryResume() {
        Task { [weak self] in
            await ProManager.shared.refresh()
            await MainActor.run {
                guard let self else { return }
                if self.pro.isPro || self.quota.canStartListen(isPro: self.pro.isPro) {
                    self.beginAnalyticsReadSessionIfNeeded(resume: true)
                    self.audio.togglePlayPause()
                } else {
                    self.showPaywall = true
                }
            }
        }
    }

    private func refreshAccessThenRetryJump(to paragraphIndex: Int) {
        status = .loading
        Task { [weak self] in
            await ProManager.shared.refresh()
            self?.jump(to: paragraphIndex, allowAccessRefresh: false)
        }
    }

    private func refreshAccessThenRetryPrefetched(_ segments: [AudioSegment], paragraphIndex: Int) {
        status = .loading
        Task { [weak self] in
            await ProManager.shared.refresh()
            self?.startWithPrefetchedSegments(segments, paragraphIndex: paragraphIndex, allowAccessRefresh: false)
        }
    }

    func setSpeed(_ s: Double) {
        settings.speed = s   // 触发 applySpeed 经由订阅
    }

    private func applySpeed() {
        audio.setPlaybackRate(Float(settings.effectiveSpeed(isPro: pro.isPro)))
    }

    func stop() {
        generationTask?.cancel()
        listenCapRefreshTask?.cancel()
        listenCapRefreshTask = nil
        clearPrefetch()
        Task { await TTSService.shared.cancelCurrentRequest() }
        audio.clearBook()
        commitListen()
        endAnalyticsReadSession(result: .cancelled, reason: "closed")
    }

    // MARK: - Generation

    private func generate(_ index: Int) {
        NSLog("CRDBG generate para=%d lang=%@ web=%@", index, docLanguage, document.sourceKind.isWebRendered ? "Y" : "N")
        isFinished = false   // 开始播放某段 → 未完成
        generationTask?.cancel()
        clearPrefetch()   // 重新生成某段 → 作废旧预取

        audio.clearQueue()
        audio.moreSegmentsExpected = true
        segmentsByParagraph[index] = []
        currentParagraphIndex = index
        processedDisplayText = nil
        highlightRange = nil
        photoHighlightWordIndex = nil
        pdfHighlight = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        status = .loading

        let para = paras[index]
        let voice = settings.voice(for: docLanguage)

        generationTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                // 顺序很重要：自动翻页后会立刻启动下一页 TTS。这里不能在外层丢一个
                // fire-and-forget cancel，否则它可能晚于新请求执行，把下一页请求取消掉。
                await TTSService.shared.cancelCurrentRequest()
                try Task.checkCancellation()
                NSLog("CRDBG generate request begin para=%d", index)
                try await TTSService.shared.generateTTSForParagraph(
                    paragraphIndex: index,
                    text: SpeechTextSanitizer.sanitizedForTTS(para.text),
                    voice: voice,
                    speed: 1.0,                       // 1.0 生成，播放用 playbackRate
                    language: self.docLanguage
                ) { [weak self] segment in
                    self?.appendSegment(segment, paragraph: index)
                }
                await MainActor.run {
                    self.audio.moreSegmentsExpected = false
                    if self.currentParagraphIndex == index { self.status = .ready }
                }
                await self.preloadNext(after: index)
            } catch is CancellationError {
                // 切段取消，忽略
            } catch TTSError.cancelled {
                NSLog("CRDBG generate request cancelled para=%d", index)
            } catch {
                await MainActor.run {
                    self.audio.moreSegmentsExpected = false
                    if self.currentParagraphIndex == index {
                        self.status = .error(error.localizedDescription)
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

    private func appendSegment(_ segment: AudioSegment, paragraph: Int) {
        guard paragraph == currentParagraphIndex else { return }
        segmentsByParagraph[paragraph, default: []].append(segment)
        let segs = segmentsByParagraph[paragraph] ?? []
        processedDisplayText = segs.map { $0.text }.joined()
        if document.sourceKind.isWebRendered { webAudioSegments.append(segment) }
        audio.loadSegment(segment)
        status = .streaming
    }

    /// 当前段生成完后调用：后台预生成下一段 TTS 到缓存（不入队播放），advance 命中时秒接，消除段间等首字节的 gap。
    private func preloadNext(after index: Int) async {
        _ = preloaded.insert(index)
        guard let pos = readableIndices.firstIndex(of: index) else { return }
        let nextPos = pos + 1
        guard nextPos < readableIndices.count else { return }
        let nextIndex = readableIndices[nextPos]
        if prefetchingIndex == nextIndex || prefetchedIndex == nextIndex { return }   // 已在预取/已就绪
        startPrefetch(nextIndex)
    }

    /// 后台生成 nextIndex 段的全部 segment 到 `prefetchedSegments`（不碰播放器）。
    /// 安全前提：仅在当前段生成完成后调用，故不会与当前段争用 TTSService 的 currentRequestId。
    private func startPrefetch(_ nextIndex: Int) {
        guard nextIndex >= 0, nextIndex < paras.count else { return }
        prefetchTask?.cancel()
        prefetchingIndex = nextIndex
        prefetchedIndex = nil
        prefetchedSegments = []
        let para = paras[nextIndex]
        let voice = settings.voice(for: docLanguage)
        let lang = docLanguage
        NSLog("CRDBG prefetch start para=%d", nextIndex)
        prefetchTask = Task { [weak self] in
            var collected: [AudioSegment] = []
            do {
                try await TTSService.shared.generateTTSForParagraph(
                    paragraphIndex: nextIndex,
                    text: SpeechTextSanitizer.sanitizedForTTS(para.text),
                    voice: voice,
                    speed: 1.0,
                    language: lang
                ) { segment in
                    collected.append(segment)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self, self.prefetchingIndex == nextIndex else { return }
                    self.prefetchingIndex = nil
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self = self, self.prefetchingIndex == nextIndex else { return }   // 期间被改→丢弃
                self.prefetchedSegments = collected
                self.prefetchedIndex = nextIndex
                self.prefetchingIndex = nil
                NSLog("CRDBG prefetch done para=%d segs=%d", nextIndex, collected.count)
            }
        }
    }

    /// 取消并清空预取缓存（jump / stop / 重新 generate 时）。
    private func clearPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchingIndex = nil
        prefetchedIndex = nil
        prefetchedSegments = []
    }

    /// 把已预取的下一段缓存「转正」为当前段：重置高亮状态 + 一次性入队播放（无 TTS 等待），并继续预取再下一段。
    private func promotePrefetch(to index: Int) {
        let segs = prefetchedSegments
        prefetchedSegments = []
        prefetchedIndex = nil
        prefetchingIndex = nil
        prefetchTask = nil
        guard !segs.isEmpty else { generate(index); return }
        NSLog("CRDBG promote prefetch para=%d segs=%d", index, segs.count)

        // 重置段/高亮状态（对齐 generate 开头），但不重新请求 TTS。
        segmentsByParagraph[index] = segs
        currentParagraphIndex = index
        processedDisplayText = segs.map { $0.text }.joined()
        highlightRange = nil
        photoHighlightWordIndex = nil
        pdfHighlight = nil
        photoCursor = 0
        clearOCRWordAlignment()
        lastWordKey = ""
        if document.sourceKind.isWebRendered { webAudioSegments.append(contentsOf: segs) }

        // 完整缓存一次性入队；无 moreSegmentsExpected，播完正常 advance。
        audio.moreSegmentsExpected = false
        audio.loadSegments(segs)
        status = .ready

        // 立即预取再下一段，保持「始终领先一段」。
        Task { [weak self] in await self?.preloadNext(after: index) }
    }

    private func advance() {
        advance(allowAccessRefresh: true)
    }

    private func advance(allowAccessRefresh: Bool) {
        commitListen()
        NSLog("CRDBG advance from para=%d readable=%d", currentParagraphIndex, readableIndices.count)
        guard let pos = readableIndices.firstIndex(of: currentParagraphIndex) else { return }
        let nextPos = pos + 1
        guard nextPos < readableIndices.count else {
            status = .ready
            isFinished = true
            NSLog("CRDBG read document finished para=%d readable=%d", currentParagraphIndex, readableIndices.count)
            endAnalyticsReadSession(result: .success, reason: "completed")
            onDocumentFinished?()
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
            audio.pause()
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
            Task { [weak self] in
                _ = await task.value
                await MainActor.run {
                    guard let self = self else { return }
                    if self.prefetchedIndex == nextIndex, !self.prefetchedSegments.isEmpty {
                        self.promotePrefetch(to: nextIndex)
                    } else {
                        self.generate(nextIndex)
                    }
                }
            }
            return
        }
        // ③ 无预取 → 正常生成
        generate(nextIndex)
    }

    private func refreshAccessThenRetryAdvance() {
        status = .loading
        audio.pause()
        Task { [weak self] in
            await ProManager.shared.refresh()
            self?.advance(allowAccessRefresh: false)
        }
    }

    // MARK: - 高亮

    private func onTick(_ t: Double) {
        guard isActive else { return }
        accountAnalyticsPlayback(t)
        accountListen(t)
        updateHighlight(t)
        updateNowPlayingCaption(t)
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
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let chars = Array(text)
        var ranges: [NSRange] = []
        var start = 0
        func appendRange(end: Int) {
            guard end > start else { start = end; return }
            let raw = String(chars[start..<end])
            let leading = raw.prefix { $0.isWhitespace || $0.isNewline }.count
            let trailing = raw.reversed().prefix { $0.isWhitespace || $0.isNewline }.count
            let location = start + leading
            let length = max(0, end - trailing - location)
            if length > 0 { ranges.append(NSRange(location: location, length: length)) }
            start = end
        }
        for i in chars.indices {
            var shouldCut = "。！？!?；;\n".contains(chars[i])
            if chars[i] == "." {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                shouldCut = next.isWhitespace || next.isNewline
            }
            if shouldCut { appendRange(end: i + 1) }
        }
        if start < chars.count { appendRange(end: chars.count) }
        return ranges.isEmpty ? [NSRange(location: 0, length: ns.length)] : ranges
    }

    private func updateHighlight(_ t: Double) {
        guard let seg = audio.currentSegment, seg.paragraphIndex == currentParagraphIndex else { return }

        // .web/.docx 源：高亮在 WebView DOM 上，bridge 下发段内 charRange（UTF-16 对齐 JS textContent）。
        if document.sourceKind.isWebRendered {
            let segs = segmentsByParagraph[currentParagraphIndex] ?? []
            guard let segPos = segs.firstIndex(where: { $0.id == seg.id }) else { return }
            let total = (paras[currentParagraphIndex].text as NSString).length
            let base = segs.prefix(segPos).reduce(0) { $0 + ($1.text as NSString).length }

            // 有词时间戳（英文）→ 逐词：下发词数组+索引+segment序号，JS 在 DOM 虚拟全文前向匹配（不靠字符偏移，对齐扩展 highlight-sync）。
            if !seg.timestamps.isEmpty {
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
            if charEnd > charStart {
                setWebHighlight(WebHighlightCmd(paragraphIndex: currentParagraphIndex, charStart: charStart, charEnd: charEnd))
            }
            return
        }

        // .pdf：句级淡高亮由 PDFReaderView 按 currentParagraphIndex 画；此处额外算「当前词」(英文有词时间戳)，
        // 发 pdfHighlight 让 PDFReaderView 在句范围内 findString 定位词、画词矩形（中文无词时间戳→不发，仅句级）。
        if document.sourceKind == .pdf {
            let segs = segmentsByParagraph[currentParagraphIndex] ?? []
            guard let segPos = segs.firstIndex(where: { $0.id == seg.id }), !seg.timestamps.isEmpty else { return }
            var localIdx = -1
            for (i, ts) in seg.timestamps.enumerated() {
                if t + 0.02 >= ts.startTime { localIdx = i } else { break }
            }
            guard localIdx >= 0 else { return }
            let priorWords = segs.prefix(segPos).reduce(0) { $0 + $1.timestamps.count }
            let words = segs.flatMap { $0.timestamps.map { $0.word } }
            let cmd = PDFWordHighlight(paragraphIndex: currentParagraphIndex, words: words, wordIndex: priorWords + localIdx)
            if pdfHighlight != cmd { pdfHighlight = cmd }
            return
        }

        let segs = segmentsByParagraph[currentParagraphIndex] ?? []
        guard let segPos = segs.firstIndex(where: { $0.id == seg.id }) else { return }
        let base = segs.prefix(segPos).reduce(0) { $0 + ($1.text as NSString).length }

        // 对齐扩展：无词时间戳（中文等语言后端不返回）→ 高亮当前整句（整个 segment 文本），随 segment 推进；
        // 有词时间戳（英文）→ 词级逐字高亮（"老师指读"）。判断依据是「该 segment 是否有词时间戳」，与语言无关。
        if seg.timestamps.isEmpty {
            if document.sourceKind.isNativeTextRendered {
                let content = contentRange(in: seg.text as NSString)
                highlightRange = NSRange(location: base + content.location, length: content.length)
            } else if document.sourceKind.isOCRImageRendered {
                // OCR 图片源 + 无词时间戳（中文云端 TTS 不返回词级时间戳）：按段内 segment 进度线性推进
                // OCR 词高亮，否则照片/Kindle 中文永远不高亮。单调不减，防流式 segment 数抖动导致回跳。
                let wordCount = document.paragraphs[currentParagraphIndex].words.count
                let segDur = audio.duration > 0.01 ? audio.duration : (seg.duration > 0.01 ? seg.duration : 0)
                let segProg = segDur > 0.01 ? min(1.0, max(0, t) / segDur) : 0
                if let idx = Self.photoWordIndex(wordCount: wordCount, segPos: segPos, segCount: segs.count, segProgress: segProg) {
                    let next = max(photoHighlightWordIndex ?? -1, idx)
                    if next != photoHighlightWordIndex { photoHighlightWordIndex = next }
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

        if document.sourceKind.isNativeTextRendered {
            // 预对齐查表（绝对位置，已含前序 segment 偏移）；对齐失败的词保留上一个高亮、不跳
            ensureWordAligned()
            let gIdx = segs.prefix(segPos).reduce(0) { $0 + $1.timestamps.count } + localIdx
            if gIdx >= 0, gIdx < wordRanges.count, let r = wordRanges[gIdx] {
                highlightRange = r
            }
        } else if document.sourceKind.isOCRImageRendered {
            ensureOCRWordAligned()
            let gIdx = segs.prefix(segPos).reduce(0) { $0 + $1.timestamps.count } + localIdx
            if gIdx >= 0, gIdx < ocrWordIndexes.count, let idx = ocrWordIndexes[gIdx] {
                let next = max(photoHighlightWordIndex ?? -1, idx)
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
        for seg in segs {
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
        let segs = segmentsByParagraph[currentParagraphIndex] ?? []
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

    /// photo：把当前 TTS 词对齐到 OCR 词（游标只前进，匹配优先，否则顺移）。
    private func advancePhotoCursor(toward word: String) {
        guard currentParagraphIndex >= 0, currentParagraphIndex < document.paragraphs.count else { return }
        let words = document.paragraphs[currentParagraphIndex].words
        guard !words.isEmpty else { photoHighlightWordIndex = nil; return }
        let target = normalize(word)
        let window = 6
        let upper = min(words.count, photoCursor + window)
        if photoCursor < words.count {
            for i in photoCursor..<upper {
                if normalize(words[i].text) == target {
                    photoHighlightWordIndex = i
                    photoCursor = i + 1
                    return
                }
            }
        }
        let idx = min(photoCursor, words.count - 1)
        photoHighlightWordIndex = idx
        photoCursor = idx + 1
    }

    private func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: - Product analytics

    private func beginAnalyticsReadSessionIfNeeded(resume: Bool) {
        guard analyticsReadSessionId == nil else { return }
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
                resume: resume || analyticsContext.entryPoint == "history_resume"
            )
        )
    }

    private func handlePlaybackState(_ playing: Bool) {
        isPlaying = playing
        guard playing else {
            analyticsLastSegmentId = nil
            analyticsLastPosition = nil
            return
        }
        guard isActive,
              !analyticsFirstAudioTracked,
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
                voiceId: settings.voice(for: docLanguage)
            )
        )
    }

    private func accountAnalyticsPlayback(_ currentTime: Double) {
        guard audio.isPlaying,
              analyticsReadSessionId != nil,
              let segment = audio.currentSegment else { return }
        if analyticsLastSegmentId == segment.id,
           let previous = analyticsLastPosition,
           currentTime >= previous {
            // Cap a single tick so a manual seek does not manufacture usage.
            analyticsPlaybackSeconds += min(2.0, currentTime - previous)
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
                    completionBucket: analyticsCompletionBucket
                )
            )
        }
    }

    private func endAnalyticsReadSession(
        result: AnalyticsResult,
        reason: String,
        errorStage: String? = nil,
        errorCode: String? = nil
    ) {
        guard analyticsReadSessionId != nil else { return }
        ProductAnalytics.shared.track(
            .readEnd,
            context: analyticsEventContext,
            properties: .init(
                result: result.rawValue,
                errorStage: errorStage,
                errorCode: errorCode,
                playbackSeconds: Int(analyticsPlaybackSeconds),
                completionBucket: analyticsCompletionBucket,
                endReason: reason
            )
        )
        analyticsReadSessionId = nil
        analyticsReadStartedAt = nil
        analyticsFirstAudioTracked = false
        analyticsLastSegmentId = nil
        analyticsLastPosition = nil
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
                self.audio.pause()
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
    func dbgPreloadNext(after i: Int) async { await preloadNext(after: i) }
    func dbgWaitPrefetch() async { _ = await prefetchTask?.value }
    func dbgPromote(to i: Int) { promotePrefetch(to: i) }
    func dbgGenerate(_ i: Int) { generate(i) }
    func dbgWaitGeneration() async { _ = await generationTask?.value }
}
#endif
