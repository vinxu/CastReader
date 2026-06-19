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
    private var photoCursor = 0
    private var lastSegmentId = ""
    private var lastSegmentMaxTime: Double = 0
    private var graceSeconds: Double = 0
    private(set) var isActive = false

    init(document: ReadingDocument) {
        self.document = document
        recomputeReadableIndices()
        bind()
    }

    deinit {
        generationTask?.cancel()
    }

    private func recomputeReadableIndices() {
        readableIndices = paras.enumerated()
            .filter { $0.element.type.isReadable && !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

    var highlightUIColor: UIColor { UIColor(hexString: settings.highlightColorHex) }

    // MARK: - Bind

    private func bind() {
        audio.$currentTime
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.onTick(t) }
            .store(in: &cancellables)
        audio.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.isPlaying = p }
            .store(in: &cancellables)
        audio.$isBuffering
            .receive(on: RunLoop.main)
            .sink { [weak self] b in self?.isBuffering = b }
            .store(in: &cancellables)
        settings.$speed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySpeed() }
            .store(in: &cancellables)
    }

    /// 成为当前激活模式（接管音频回调）。
    func activate() {
        isActive = true
        audio.onPlaybackComplete = { [weak self] in self?.advance() }
    }

    /// 退出激活（切到解读模式时调用）：必须停掉生成/预取，否则流式生成的新 segment 经 loadSegment 会自动
    /// 重新 playSegment（首段未播放时），导致「切到解读后朗读还在响」。
    func deactivate() {
        isActive = false
        generationTask?.cancel()
        clearPrefetch()
        Task { await TTSService.shared.cancelCurrentRequest() }
        audio.moreSegmentsExpected = false
        audio.pause()
        // 清朗读高亮状态，避免切到解读后残留（web 源 DOM 另由 setActive→clearOverlay 清）
        highlightRange = nil
        photoHighlightWordIndex = nil
        webHighlight = nil
        pdfHighlight = nil
    }

    // MARK: - Start / control

    func start() {
        guard !readableIndices.isEmpty else { status = .error(String(localized: "无可朗读内容")); return }
        guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else {
            showPaywall = true
            return
        }
        activate()
        audio.setBook(id: document.id, title: document.title, chapterTitle: nil, coverUrl: nil)
        applySpeed()
        generate(readableIndices[0])
    }

    func togglePlayPause() {
        if currentParagraphIndex < 0 { start(); return }
        audio.togglePlayPause()
    }

    func skipForward() { audio.skipForward(seconds: 15) }
    func skipBackward() { audio.skipBackward(seconds: 15) }

    /// 点击段落跳读。
    func jump(to paragraphIndex: Int) {
        guard readableIndices.contains(paragraphIndex) else { return }
        guard pro.isPro || quota.canStartListen(isPro: pro.isPro) else { showPaywall = true; return }
        // 首次直接点击句子跳读（未经 start）→ 必须补激活：否则 audio.onPlaybackComplete 未挂，读完一句不 advance
        //（“只读一句就停、没看到加载下一句”），且 isActive=false 时 onTick 直接 return（无高亮、不计额度）。
        // activate 幂等；已 start 过再点句重复设回调/setBook 无害。
        if !isActive {
            activate()
            audio.setBook(id: document.id, title: document.title, chapterTitle: nil, coverUrl: nil)
            applySpeed()
        }
        generate(paragraphIndex)
    }

    func setSpeed(_ s: Double) {
        settings.speed = s   // 触发 applySpeed 经由订阅
    }

    private func applySpeed() {
        audio.setPlaybackRate(Float(settings.effectiveSpeed(isPro: pro.isPro)))
    }

    func stop() {
        generationTask?.cancel()
        clearPrefetch()
        Task { await TTSService.shared.cancelCurrentRequest() }
        audio.clearBook()
        commitListen()
    }

    // MARK: - Generation

    private func generate(_ index: Int) {
        NSLog("CRDBG generate para=%d lang=%@ web=%@", index, docLanguage, document.sourceKind.isWebRendered ? "Y" : "N")
        isFinished = false   // 开始播放某段 → 未完成
        generationTask?.cancel()
        clearPrefetch()   // 重新生成某段 → 作废旧预取
        Task { await TTSService.shared.cancelCurrentRequest() }

        audio.clearQueue()
        audio.moreSegmentsExpected = true
        segmentsByParagraph[index] = []
        currentParagraphIndex = index
        processedDisplayText = nil
        highlightRange = nil
        photoHighlightWordIndex = nil
        pdfHighlight = nil
        photoCursor = 0
        lastWordKey = ""
        status = .loading

        let para = paras[index]
        let voice = settings.voice(for: docLanguage)

        generationTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await TTSService.shared.generateTTSForParagraph(
                    paragraphIndex: index,
                    text: para.text,
                    voice: voice,
                    speed: 1.0,                       // 1.0 生成，播放用 playbackRate
                    language: self.docLanguage
                ) { [weak self] segment in
                    await self?.appendSegment(segment, paragraph: index)
                }
                await MainActor.run {
                    self.audio.moreSegmentsExpected = false
                    if self.currentParagraphIndex == index { self.status = .ready }
                }
                await self.preloadNext(after: index)
            } catch is CancellationError {
                // 切段取消，忽略
            } catch {
                await MainActor.run {
                    self.audio.moreSegmentsExpected = false
                    if self.currentParagraphIndex == index { self.status = .error(error.localizedDescription) }
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
                    paragraphIndex: nextIndex, text: para.text, voice: voice, speed: 1.0, language: lang
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
        commitListen()
        NSLog("CRDBG advance from para=%d readable=%d", currentParagraphIndex, readableIndices.count)
        guard let pos = readableIndices.firstIndex(of: currentParagraphIndex) else { return }
        let nextPos = pos + 1
        guard nextPos < readableIndices.count else {
            status = .ready
            isFinished = true
            return
        }
        // 段落边界做额度闸门（“读完本篇”自然边界）
        if !pro.isPro && !quota.canStartListen(isPro: pro.isPro) {
            showPaywall = true
            audio.pause()
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

    // MARK: - 高亮

    private func onTick(_ t: Double) {
        guard isActive else { return }
        accountListen(t)
        updateHighlight(t)
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
            if document.sourceKind == .text {
                let content = contentRange(in: seg.text as NSString)
                highlightRange = NSRange(location: base + content.location, length: content.length)
            } else if document.sourceKind == .photo {
                // photo + 无词时间戳（中文云端 TTS 不返回词级时间戳）：按段内 segment 进度线性推进
                // OCR 词高亮，否则照片中文永远不高亮。单调不减，防流式 segment 数抖动导致回跳。
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

        if document.sourceKind == .text {
            if let within = wordRange(in: seg.text, words: seg.timestamps.map { $0.word }, index: localIdx) {
                highlightRange = NSRange(location: base + within.location, length: within.length)
            }
        } else {
            // photo：仅当新词时推进游标
            if wordKey != lastWordKey {
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
    private func wordRange(in text: String, words: [String], index: Int) -> NSRange? {
        let ns = text as NSString
        var searchStart = 0
        for i in 0...index {
            let w = words[i]
            guard !w.isEmpty else { continue }
            let remaining = NSRange(location: searchStart, length: ns.length - searchStart)
            let found = ns.range(of: w, options: [.literal], range: remaining)
            if found.location == NSNotFound { return nil }
            if i == index { return found }
            searchStart = found.location + found.length
        }
        return nil
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
            graceSeconds += 0   // 提交在 commitListen 累加，这里仅判断
            if graceSeconds > quota.graceCapSeconds {
                audio.pause()
                showPaywall = true
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
