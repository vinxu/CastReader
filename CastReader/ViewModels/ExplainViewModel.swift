//
//  ExplainViewModel.swift
//  CastReader
//
//  解读编排：extract-plan(SSE) → 逐块 extract-block → TTS 讲解 → compose-block 回填 at → 入队播放。
//  播放中按「块时间线」elapsed 触发 marks，用 MarkAnchoring 锚定到原文，交 reader 画手写标注。
//

import Foundation
import Combine

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

    /// 场景 content_type（从首页场景入口进入时设置；通用 ➕ 导入为 nil）。决定后端「划什么/怎么批」prompt 分支 +
    /// 解读深度预设（覆盖用户全局 explainDepth）。由 PlayerCoordinator.open(scenario:) 注入。
    var scenario: String? = nil

    /// 解读深度：有场景用场景预设深度（PRD §2.1 覆盖全局），否则用用户设置。
    private var effectiveDepth: String {
        if let sc = scenario, let ct = ExplainContentType(rawValue: sc) { return ct.suggestedDepth.rawValue }
        return settings.explainDepth
    }

    // .web 源：用 WebView extractor 提取的段落构成讲解/锚定文档（原始 document.paragraphs 为空）。
    private var webDoc: ReadingDocument? = nil
    private var doc: ReadingDocument { webDoc ?? document }
    func loadWebParagraphs(_ p: [ReadingParagraph], language: String? = nil) {
        webDoc = ReadingDocument(id: document.id, title: document.title, sourceKind: .web,
                                 language: language ?? document.language, paragraphs: p, sourceURL: document.sourceURL)
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

    /// segment 的有效时长：云端 TTS 的 API duration 常为 0，用最后一个时间戳的 endTime 兜底。
    private func effectiveDuration(_ seg: AudioSegment) -> Double {
        if seg.duration > 0.01 { return seg.duration }
        return seg.timestamps.last?.endTime ?? 0
    }

    private let audio = AudioPlayerService.shared
    private let settings = AppSettings.shared
    private let pro = ProManager.shared
    private let quota = QuotaManager.shared

    private struct PreparedBlock {
        let segments: [AudioSegment]
        let marks: [QuickreadEvent]     // at 已填
        let text: String
        let sentences: [String]         // 讲解文本按句切分（字幕逐句显示，按播放进度推进）
    }

    private var jobId: String = ""
    private var totalBlocks: Int = 0
    private var outputLanguage: String = "en"
    private var section0: QuickreadSection?

    private var prepared: [Int: PreparedBlock] = [:]
    private var marksByBlock: [Int: [QuickreadEvent]] = [:]
    private var firedMarks = Set<String>()
    private var anchorCursor: Int? = nil
    private var markHit = 0, markTotal = 0   // mark 匹配成功率诊断（CRDBG）

    // 快道（Fast-Lane）：快道占 block_0 秒开，质道吃剩余段、块顺延为 block_(idxBase+j)。idxBase=0 即未走快道（原单路）。
    private var idxBase = 0
    private var fastSection: QuickreadSection?
    private var block0Claimed = false
    private var fastTask: Task<Void, Never>?
    private var forcedExplainLang: String?   // 快道激活时锁定语言（快道+质道同语言，避免开头/后续语言不一致）
    /// 质道 plan 失败标志（402/400/网络）：让 prepareBlock 的 section0 等待循环跳出，避免快道占位后死等挂起。
    private var planFailed = false

    private var orchestrationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private(set) var isActive = false

    init(document: ReadingDocument) {
        self.document = document
        bind()
    }

    deinit { orchestrationTask?.cancel() }

    private func bind() {
        audio.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.onTick(t) }
            .store(in: &cancellables)
        audio.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.isPlaying = p }
            .store(in: &cancellables)
        // 与朗读统一：speed 改动（设置页滑杆 / 控制条倍速按钮）实时作用到解读播放，保证「显示 = 在播」。
        settings.$speed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySpeed() }
            .store(in: &cancellables)
    }

    /// 应用全局语速到共享播放器（与 ReadAloudViewModel.applySpeed 对称，统一由 settings.speed 驱动）。
    private func applySpeed() {
        audio.setPlaybackRate(Float(settings.effectiveSpeed(isPro: pro.isPro)))
    }

    func activate() {
        isActive = true
        audio.onPlaybackComplete = { [weak self] in self?.onBlockComplete() }
    }

    func deactivate() {
        isActive = false
        orchestrationTask?.cancel()
        isPreparingNext = false
        clearPagePrefetch()
        audio.moreSegmentsExpected = false
        audio.pause()
    }

    // MARK: - Start

    func start() {
        guard status == .idle || isErrorState else { return }
        // 提交 LLM 前预校验：内容太短，LLM 没东西可讲 → 直接引导朗读，不发请求白等重试、也不消耗额度（而非无脑提交）。
        let contentChars = doc.readableParagraphs.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count }
        if contentChars < minExplainChars {
            status = .error(String(localized: "内容太短，无法解读，试试朗读"))
            return
        }
        guard pro.isPro || quota.canStartExplain(isPro: pro.isPro) else {
            showPaywall = true
            return
        }
        quota.noteExplainStarted(isPro: pro.isPro)
        activate()
        activeMarks = []           // 开始新解读：清上一轮残留 mark（对齐 Android startExplain；之后跨批累积不再清）
        idxBase = 0; block0Claimed = false; fastSection = nil; forcedExplainLang = nil; planFailed = false
        // text/web/EPUB 的 scope 只由快道 setupQuoteScope 设；重试解读前清掉上轮残留，否则 fastLaneEligibleOpening
        // 的 `pdfScopedParagraphs == nil` 守卫失败 → 退化成只讲 rest、永久丢开头段（PDF 翻页 scope 不受影响）。
        if [.text, .web, .epub].contains(doc.sourceKind) { pdfScopedParagraphs = nil; pdfBatchCursor = nil }
        audio.setBook(id: document.id, title: document.title, chapterTitle: String(localized: "解读"), coverUrl: nil)
        applySpeed()
        status = .planning
        stageText = String(localized: "通读全文…")

        // 快道（Fast-Lane）：text/web/EPUB 整页长文 → 先一次轻量 LLM 直出 block_0 秒开，质道吃剩余段顺延 block_1+。
        // 快道先 LLM+TTS 决定 idxBase/scope 再启动质道（失败则质道吃全量、绝不漏开头）。门控不过 → 原单路质道。
        if let opening = fastLaneEligibleOpening() {
            fastTask = Task { [weak self] in await self?.runFastLaneThenQuote(opening: opening) }
        } else {
            setupBatchScopeIfLarge()   // EPUB/长文：解读分批，避免整本一次 extract-plan → 后端 400
            orchestrationTask = Task { [weak self] in await self?.runPlan() }
        }
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
        guard [.text, .web, .epub].contains(doc.sourceKind) else { return nil }   // photo/PDF 翻页跳过
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
    private func setupQuoteScope(rest: [ReadingParagraph]) {
        pdfScopedParagraphs = rest.enumerated().map {
            ReadingParagraph(id: $0.offset, text: $0.element.text, type: $0.element.type)
        }
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
        return PreparedBlock(segments: segs, marks: marks, text: section.text, sentences: Self.splitSentences(section.text))
    }

    /// 快道执行：先 LLM(fast-block0) + TTS 决定 idxBase/scope，再启动质道。
    /// 成功 → 占 block_0 秒开 + 质道吃剩余段（idxBase=1）；失败 → idxBase=0 + 质道吃全量（绝不漏开头）。
    private func runFastLaneThenQuote(opening: [ReadingParagraph]) async {
        let lang = settings.explainLangOrNil ?? doc.language   // 锁定确定语言（快道+质道同语言，不让 server 对快道默认 en）
        await MainActor.run { self.forcedExplainLang = lang }
        var fastPB: PreparedBlock?
        if let section = try? await QuickReadService.shared.fastBlock0(
                title: doc.title, openingParas: opening.map { $0.text },
                lang: lang, depth: effectiveDepth, prevSummary: nil, contentType: scenario),
           let pb = try? await prepareFastBlock(section, language: lang) {
            await MainActor.run { self.fastSection = section }
            fastPB = pb
        }
        await MainActor.run {
            guard self.isActive, case .planning = self.status else { return }
            if let pb = fastPB {
                self.idxBase = 1
                self.block0Claimed = true
                let readable = self.doc.readableParagraphs
                self.setupQuoteScope(rest: Array(readable.dropFirst(opening.count)))
                self.totalBlocks = max(1, self.idxBase + 1)   // 预估，handlePlan 收到质道总块数后修正
                self.enqueue(pb, idx: 0)                       // 秒开
                NSLog("CRDBG fastlane block_0 emit (opening=%d marks=%d)", opening.count, pb.marks.count)
            } else {
                self.idxBase = 0
                self.setupBatchScopeIfLarge()                  // 快道失败兜底：质道吃全量
                NSLog("CRDBG fastlane failed → 质道吃全量")
            }
            self.orchestrationTask = Task { [weak self] in await self?.runPlan() }
        }
    }

    func stop() {
        orchestrationTask?.cancel()
        fastTask?.cancel()
        Task { await TTSService.shared.cancelCurrentRequest() }
        audio.clearBook()
        clearPagePrefetch()
        status = .idle
    }

    func togglePlayPause() { audio.togglePlayPause() }

    /// 重新播放已解读完的内容：复用缓存块（不重新调后端 LLM、不耗额度），从第一块重头播。
    func replay() {
        guard totalBlocks > 0, !prepared.isEmpty else { start(); return }   // 没解读过 → 当普通开始
        orchestrationTask?.cancel()
        fastTask?.cancel()
        activate()
        firedMarks.removeAll()
        activeMarks = []          // 触发 bridge clearMarks，清掉上一轮 DOM 手写标注
        anchorCursor = nil
        currentBlockIndex = -1
        scrollTarget = -1
        audio.setBook(id: document.id, title: document.title, chapterTitle: String(localized: "解读"), coverUrl: nil)
        applySpeed()
        orchestrationTask = Task { [weak self] in await self?.prepareAndEnqueue(block: 0) }
    }

    // MARK: - Plan

    private func runPlan() async {
        let req = buildPlanRequest()
        do {
            let done = try await QuickReadService.shared.extractPlan(
                req,
                onStage: { [weak self] s in Task { @MainActor in self?.stageText = self?.friendlyStage(s) ?? s } },
                onBlock0: { [weak self] block0 in
                    Task { @MainActor in self?.handlePlan(block0) }
                }
            )
            // 权威总块数取自 done 事件：block0 事件的 total_blocks 后端常发 0 占位（plan 尚未算完总数）。
            // 之前 app 误用 block0 的 0 → max(1,0)=1 → 只播首块就"完成"。对齐扩展：用 done 的值。
            await MainActor.run {
                NSLog("CRDBG explain DONE total_blocks=%d (block0 占位后 totalBlocks=%d)", done.total_blocks ?? -1, self.totalBlocks)
                if let tb = done.total_blocks, self.idxBase + tb > self.totalBlocks {
                    self.totalBlocks = self.idxBase + tb   // 快道占 idxBase 块 + 质道 tb 块（漏加 idxBase 会丢质道最后一块）
                    // done 晚于首块播完到达时会误判 .completed → 在此续播下一块。
                    if case .completed = self.status, self.currentBlockIndex + 1 < self.totalBlocks {
                        Task { await self.prepareAndEnqueue(block: self.currentBlockIndex + 1) }
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.planFailed = true   // 通知 prepareBlock 的 section0 等待循环跳出（快道占位后不再死等挂起）
                // server entitlement 超限 → 付费墙（对齐扩展：免费额度用满当付费墙，不当普通错误）
                if case QuickReadError.httpError(402) = error {
                    self.showPaywall = true
                    self.status = .idle
                    self.stageText = ""
                } else if case QuickReadError.httpError(400) = error {
                    // 重试 3 次仍 400：多为内容太短/不适合解读，给可读提示而非裸 HTTP 码
                    self.status = .error(String(localized: "内容太短或暂不支持解读，请稍后重试"))
                    self.stageText = String(localized: "解读失败")
                } else {
                    self.status = .error(error.localizedDescription)
                    self.stageText = String(localized: "解读失败")
                }
            }
            return
        }
    }

    private func handlePlan(_ plan: PlanBlock0) {
        jobId = plan.job_id
        totalBlocks = idxBase + max(1, plan.total_blocks)   // 快道占 idxBase 块 + 质道块
        // 快道激活（forcedExplainLang != nil）时它优先：block_0 已用此语言朗读，质道必须跟随，不能被
        // plan.output_language 盖过（否则质道与快道开头语言/音色不一致）。非快道时才用 plan 返回的语言。
        outputLanguage = forcedExplainLang ?? plan.output_language ?? settings.explainLangOrNil ?? doc.language
        section0 = plan.block_0                              // 质道首块 = iOS block_idxBase
        let scoped = pdfScopedParagraphs ?? doc.paragraphs   // 实际传后端的范围（PDF 逐批时是当前批，非整本）
        NSLog("CRDBG explain PLAN total_blocks=%d idxBase=%d batchParas=%d batchChars=%d depth=%@ block0Events=%d",
              plan.total_blocks, idxBase, scoped.count, scoped.reduce(0) { $0 + $1.text.count }, settings.explainDepth, plan.block_0.events.count)
        if !block0Claimed {
            // 快道没占（idxBase=0 / 快道失败）→ 质道占 block_0
            block0Claimed = true
            Task { await self.prepareAndEnqueue(block: 0) }
        } else {
            // 快道已占 block_0 → 后台预取质道首块 block_idxBase，消除块间 gap（播完 block_0 由 onBlockComplete 续接）
            Task { [weak self] in
                guard let self else { return }
                if let pb = try? await self.prepareBlock(self.idxBase) {
                    await MainActor.run { if self.prepared[self.idxBase] == nil { self.prepared[self.idxBase] = pb } }
                }
            }
        }
    }

    // MARK: - 块准备与入队

    private func prepareAndEnqueue(block idx: Int) async {
        do {
            let pb = try await prepareBlock(idx)
            await MainActor.run { self.enqueue(pb, idx: idx) }
            // 预取下一块
            if idx + 1 < totalBlocks {
                Task { [weak self] in
                    if let pb2 = try? await self?.prepareBlock(idx + 1) {
                        await MainActor.run { self?.prepared[idx + 1] = pb2 }
                    }
                }
            }
        } catch is CancellationError {
            await MainActor.run { self.isPreparingNext = false }
        } catch {
            await MainActor.run { self.status = .error(error.localizedDescription); self.isPreparingNext = false }
        }
    }

    private func prepareBlock(_ idx: Int) async throws -> PreparedBlock {
        if let cached = prepared[idx] { return cached }
        // 快道占 block_0（idxBase=1）→ iOS idx 映射到质道块 qIdx = idx - idxBase。
        // 质道首块（qIdx<=0）用 plan 的 section0；快道占位时 block_0 播放期间质道 plan 通常已返回，
        // 极端未到则短暂等待（block_0 narration 音频较长，足够质道 plan 完成）。其余拉 extract-block。
        let qIdx = idx - idxBase
        let section: QuickreadSection
        if qIdx <= 0 {
            // 等质道 plan 返回 section0；plan 失败（planFailed）或失活则跳出，避免快道占位后死等挂起。
            // 失败时静默抛 CancellationError——错误/付费墙状态已由 runPlan 的 catch 设置，prepareAndEnqueue 不覆盖。
            while section0 == nil, isActive, !planFailed { try await Task.sleep(nanoseconds: 200_000_000) }
            guard let s0 = section0 else { throw CancellationError() }
            section = s0
        } else {
            section = try await QuickReadService.shared.extractBlock(jobId: jobId, blockIdx: qIdx)
        }
        return try await prepareSection(section, idx: idx, composeIdx: qIdx, jobId: jobId, language: outputLanguage)
    }

    /// 讲解 section → 可播放块（TTS + 拼时间线 + composeBlock 回填 mark.at）。参数化 jobId/语言 → 当前页与页间预取共用。
    /// idx = iOS 块序（TTS 段标识、匹配 currentBlockIndex）；composeIdx = 质道块号（快道激活后两者差 idxBase）。
    private func prepareSection(_ section: QuickreadSection, idx: Int, composeIdx: Int, jobId: String, language: String) async throws -> PreparedBlock {
        // TTS 讲解文本（收集全部 segment）
        var segs: [AudioSegment] = []
        try await TTSService.shared.generateTTSForParagraph(
            paragraphIndex: idx,
            text: section.text,
            voice: settings.voice(for: language),
            speed: 1.0,
            language: language
        ) { segment in
            segs.append(segment)
        }

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
        if let composed = try? await QuickReadService.shared.composeBlock(
            jobId: jobId, blockIdx: composeIdx, timestamps: timeline, duration: duration) {
            marks = composed.events
        } else {
            marks = section.events
        }
        marks = ensureTiming(marks, duration: duration)

        return PreparedBlock(segments: segs, marks: marks, text: section.text, sentences: Self.splitSentences(section.text))
    }

    private func enqueue(_ pb: PreparedBlock, idx: Int) {
        prepared[idx] = pb   // 缓存每块（含 block 0），供 replay 复用、不重新 TTS/调后端
        audio.clearQueue()
        currentBlockIndex = idx
        explanationText = pb.sentences.first ?? pb.text
        marksByBlock[idx] = pb.marks
        status = .streaming(block: idx, total: totalBlocks)
        isPreparingNext = false
        audio.moreSegmentsExpected = true
        for seg in pb.segments { audio.loadSegment(seg) }
        audio.moreSegmentsExpected = false
        // PDF 连续解读：当前页一开始播就后台预取下一页首块，切页时秒接（消除页间 gap）。
        prefetchNextPage()
    }

    private func onBlockComplete() {
        let next = currentBlockIndex + 1
        if next < totalBlocks {
            // 下一块未预取好 → 显示「准备下一段」loading，避免块间静默被误以为卡住。
            if prepared[next] == nil { isPreparingNext = true }
            Task { await prepareAndEnqueue(block: next) }
            return
        }
        // 当前批讲解播完 → 自动推进下一批续播，直到全书末尾（听完整本）。
        if let next = pdfBatchCursor {
            advanceBatch(fromGlobalIndex: next)
            return
        }
        status = .completed
    }

    /// PDF 连续解读：切到下一批续播。命中批间预取 → 跳过 extract-plan；否则实时规划（显示「继续讲解…」）。
    private func advanceBatch(fromGlobalIndex start: Int) {
        let batch = pdfBatch(fromGlobalIndex: start)
        guard !batch.paras.isEmpty else { status = .completed; return }
        pdfScopedParagraphs = batch.paras
        pdfBatchCursor = batch.next
        // 重置上一批块状态（保留 isActive / audio 设置）。注意 activeMarks 跨批**累积、不清**——
        // 否则切到下一批时前面批的手写标注全没了（对齐 Android：整个解读过程 mark 留在原文上）。
        prepared.removeAll()
        marksByBlock.removeAll()
        firedMarks.removeAll()
        anchorCursor = batch.paras.first?.id   // mark 锚定优先当前批段落（不回前面批找重复文本）
        currentBlockIndex = -1
        scrollTarget = -1

        // 命中批间预取 → 已规划好（跳过 extract-plan「通读」那段 gap）；block0 TTS 在此生成（此刻 TTS 空闲、不冲突）。
        if let pf = prefetchedBatch, pf.startIndex == start {
            prefetchedBatch = nil
            jobId = pf.jobId
            totalBlocks = pf.totalBlocks
            outputLanguage = pf.outputLanguage
            section0 = pf.section0       // prepareBlock(0) 直接用、跳过 extract-block
            isPreparingNext = true
            stageText = String(localized: "继续讲解…")
            status = .planning
            orchestrationTask = Task { [weak self] in await self?.prepareAndEnqueue(block: 0) }
            return
        }
        // 未预取 → 实时规划。
        section0 = nil
        jobId = ""
        totalBlocks = 0
        isPreparingNext = true
        stageText = String(localized: "继续讲解…")
        status = .planning
        orchestrationTask = Task { [weak self] in await self?.runPlan() }
    }

    // MARK: - 页间预取（连续解读：当前页播放时后台预规划 + 预生成下一页首块，切页秒接）

    private struct BatchPlan {
        let startIndex: Int
        let jobId: String
        let totalBlocks: Int
        let outputLanguage: String
        let section0: QuickreadSection   // 仅预规划首块文本，不预生成 TTS（TTSService 单请求，预生成会取消当前播放的 TTS）
    }
    private var prefetchedBatch: BatchPlan?
    private var prefetchingBatchStart: Int?

    private func clearPagePrefetch() { prefetchedBatch = nil; prefetchingBatchStart = nil }

    /// 后台预规划下一批（仅 extract-plan，不生成 TTS）→ 切批时跳过「通读」gap。非 PDF 连续模式自动 no-op。
    private func prefetchNextPage() {
        guard prefetchedBatch == nil, prefetchingBatchStart == nil else { return }
        guard let start = pdfBatchCursor else { return }
        let batch = pdfBatch(fromGlobalIndex: start)
        guard !batch.paras.isEmpty else { return }
        prefetchingBatchStart = start
        Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await self.planBatch(startIndex: start, paras: batch.paras)
                if self.prefetchingBatchStart == start { self.prefetchedBatch = plan }
                self.prefetchingBatchStart = nil
            } catch {
                if self.prefetchingBatchStart == start { self.prefetchingBatchStart = nil }
            }
        }
    }

    /// 对给定批 extract-plan（仅规划，**不生成 TTS**）→ 切批时跳过「通读」那段 gap。
    /// 关键：不碰 TTSService（其为单请求模型，预生成 TTS 会取消当前正在播放的 TTS → "request was cancelled"）。
    private func planBatch(startIndex: Int, paras: [ReadingParagraph]) async throws -> BatchPlan {
        let req = buildPlanRequest(paras: paras)
        // onBlock0 在 QuickReadService actor 同步回调，用 Sendable box 收集（不写当前播放状态）。
        let box = PlanBlock0Box()
        let done = try await QuickReadService.shared.extractPlan(req, onStage: { _ in }, onBlock0: { box.set($0) })
        guard let b = box.value else { throw QuickReadError.noBlock0 }
        let lang = b.output_language ?? settings.explainLangOrNil ?? doc.language
        var total = max(1, b.total_blocks)
        if let tb = done.total_blocks, tb > total { total = tb }
        return BatchPlan(startIndex: startIndex, jobId: b.job_id, totalBlocks: total, outputLanguage: lang, section0: b.block_0)
    }

    // MARK: - marks 触发（块时间线）

    private func onTick(_ t: Double) {
        guard isActive else { return }
        guard let seg = audio.currentSegment, seg.paragraphIndex == currentBlockIndex else { return }
        let segs = prepared[currentBlockIndex]?.segments ?? marksContextSegments
        let priorDuration = segs.prefix(while: { $0.id != seg.id }).reduce(0) { $0 + effectiveDuration($1) }
        let blockElapsed = priorDuration + t

        // 字幕逐句：按块内播放进度选当前句（解读后端常把整块合成一个大 segment，不能用 seg.text 当一句）。
        if let sentences = prepared[currentBlockIndex]?.sentences {
            let blockDur = segs.reduce(0) { $0 + effectiveDuration($1) }
            let progress = blockDur > 0.01 ? blockElapsed / blockDur : 0
            if let cur = Self.subtitleForProgress(sentences, progress: progress), explanationText != cur {
                explanationText = cur
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

    /// 当前块入队后 segments 也存于 prepared；兜底空数组。
    private var marksContextSegments: [AudioSegment] { prepared[currentBlockIndex]?.segments ?? [] }

    // MARK: - 字幕分句（纯函数，可自测）

    /// 讲解文本切成字幕条：①按句末标点切句（中文 。！？；+ 英文 !?; + … + 换行，英文句点仅后接空格/结尾才切避免小数）；
    /// ②过长句（>chunkLimit）再按逗号/分号/顿号二次切——否则中文长句一条字幕就是一大段（对齐扩展 buildLines 的 CHUNK 切分）。
    static func splitSentences(_ text: String) -> [String] {
        let chunkLimit = 24   // 单条字幕上限（中文≈1.5 行）：长句按逗号切到此长度，短小一条一条出
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        // ① 按句末标点切句
        var sentences: [String] = []
        var start = 0
        let enders: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "…", "\n"]
        for i in 0..<chars.count {
            var cut = enders.contains(chars[i])
            if chars[i] == "." {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next == " " || next == "\n" { cut = true }
            }
            if cut {
                let s = String(chars[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                start = i + 1
            }
        }
        if start < chars.count {
            let s = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
        }
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
            NSLog("CRDBG mark MISS %d/%d [%@]", markHit, markTotal, String(anchorText.prefix(28)))
            return
        }
        markHit += 1
        NSLog("CRDBG mark HIT %d/%d para=%d [%@]", markHit, markTotal, hit.paragraphIndex, String(anchorText.prefix(28)))
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
    /// 单次 plan 的内容上限（字符）。对齐「网页解读一次喂一篇文章」的体量——批太大后端切块变粗、mark 摊薄
    /// （实测 9000 字才 6 块/20 mark → PDF 一页才一个）；太小则批边界频繁、衔接差。
    /// ~3000 字≈5 页≈一篇短文，让后端对每批的切块/标注密度回到网页那种水平（mark 密）。后端 plan 无续接上下文，批内才连贯。
    private let pdfBatchCharLimit = 3000

    /// PDF：解读从当前可见页起，按「批」连续规划（批内连贯有衔接），播完一批自动续下一批直到末尾（听完整本）。
    func setPdfScope(_ paras: [ReadingParagraph]?, all: [ReadingParagraph]? = nil) {
        if let all { pdfAllParagraphs = all }
        clearPagePrefetch()
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
        buildPlanRequest(paras: pdfScopedParagraphs ?? doc.paragraphs)
    }

    private func buildPlanRequest(paras sourceParas: [ReadingParagraph]) -> ExtractPlanRequest {
        let paras = sourceParas.map { QuickreadParagraphDTO(text: $0.text, type: typeString($0.type)) }
        let fullText = sourceParas.map(\.text).joined(separator: "\n\n")
        let src = doc.sourceURL ?? "castreader://doc/\(doc.id)"
        return ExtractPlanRequest(
            source_url: src,
            title: doc.title,
            lang: forcedExplainLang ?? settings.explainLangOrNil,   // 快道激活 → 用锁定语言，与快道 block_0 一致
            depth: effectiveDepth,                                  // 有场景用场景预设深度，否则用户全局设置
            text: fullText,
            fullText: fullText,
            paragraphs: paras,
            // 传 prev_summary = 快道 narration（文档 §0.5 ②「连贯层」）：质道「接 rest[0] 顺序讲、不复述、不跳」
            // 由 server 质道承接 prompt 负责（已改目标驱动 + 上线，中英文各 2 篇验证通过）。客户端只传、不写
            // 「别复述/别跳」逻辑。快道未激活时 fastSection=nil → prev_summary=nil（质道吃全篇，正常路径）。
            prev_summary: fastSection?.text,
            content_type: scenario                                  // 场景信号（nil = 通用解读）
        )
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
        case "extract": return String(localized: "通读全文…")
        case "compose": return String(localized: "组织讲解…")
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
