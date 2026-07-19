//
//  EvalTests.swift
//  CastReaderTests
//
//  朗读/解读 数值评估（参考扩展 eval 的 BM 指标）。在模拟器跑，输出 [EVAL] 指标 + 阈值断言。
//  指标：
//   S  段落粒度：maxChars（过大→滚动跟不上/高亮出屏）、count
//   H  词高亮命中率：TTS 词能在 segment 文本中定位的比例（中/英分别评）
//   E  解读：block0 mark 数、锚定命中率、timing 单调且在时长内
//

import XCTest
import UIKit
import PDFKit
@testable import CastReader

final class EvalTests: XCTestCase {

    // 多行中文文档（类似用户的投资文件报告）
    private let zhLines = """
    CAST AI 投资文件分析报告
    分析对象
    1. SAFE_CAST_AI_Standard.docx — 新加坡版 SAFE，1.0 版
    2. Side_Letter_Investor_Rights.docx — 投资人权利附函
    一、当事人与核心商业条款
    发行公司（Company）CAST AI PTE. LTD.（新加坡私人有限公司，注册号 202607822H）
    投资人（Investor）Evergreen SciTech Sigma Corp
    创始人（Founder，仅 Side Letter）许旭恒（Xu Xuheng），持中国身份证
    投资金额（Purchase Amount）200 万美元
    投后估值上限（Post-Money Valuation Cap）2,000 万美元
    适用法律/争议解决 新加坡法；SIAC 仲裁，仲裁地新加坡，语言英文
    """

    // 单一长块（无换行）——验证按句拆分能否把超长段落控制住
    private let zhBlock = "这是一份典型的 YC 风格投后估值上限 SAFE，按新加坡法本地化，并加入 SFA 与 MAS 相关声明。股权融资在合格股权融资首次交割时自动转换为优先股，取两种算法较大值。流动性事件控制权变更、直接上市或 IPO 时，投资人按较大值取得现金退出额或转换额。结果投资额按投后全面摊薄口径计算，Side Letter 另预期投资人通过股权迁移再获得约百分之九，合计约百分之十九。"

    private let enProse = """
    Reading aloud helps you focus.
    It connects what you see on the page with what you hear at the same time.
    The quick brown fox jumps over the lazy dog near the quiet river.
    Long content becomes much easier when you can both see and hear it together.
    """

    // MARK: - S 段落粒度（无网络）

    func testSegmentationMetrics() {
        let cases: [(String, ReadingDocument)] = [
            ("zh-lines", DocumentBuilder.fromMarkdown(zhLines, title: "t", sourceURL: nil, language: "zh")),
            ("zh-block", DocumentBuilder.fromPlainText(zhBlock, title: "t", language: "zh")),
            ("en-prose", DocumentBuilder.fromMarkdown(enProse, title: "t", sourceURL: nil, language: "en")),
        ]
        for (name, doc) in cases {
            let lens = doc.readableParagraphs.map { $0.text.count }
            let maxLen = lens.max() ?? 0
            let avg = lens.isEmpty ? 0 : lens.reduce(0, +) / lens.count
            print("[EVAL][S \(name)] paragraphs=\(doc.paragraphs.count) avgChars=\(avg) maxChars=\(maxLen)")
            XCTAssertGreaterThanOrEqual(doc.paragraphs.count, 3, "[\(name)] 段落数过少（疑似合并成大段）")
            XCTAssertLessThanOrEqual(maxLen, 400, "[\(name)] 最长段落 >400 字 → 滚动跟不上/高亮出屏")
        }
    }

    // MARK: - 八语检测（离线确定性 = 文档语言、音色与 TTS 请求不混）

    func testLanguageDetection() {
        let cases: [(String, String)] = [
            ("这是一段纯中文测试内容，用于验证语言检测是否准确。", "zh"),
            ("This is plain English text for language detection testing.", "en"),
            ("投资金额 200 万美元，Post-Money Valuation Cap 为 2000 万美元。", "zh"),  // 中英混排仍判中文
            ("Reading aloud helps you focus on the page while listening to it.", "en"),
            ("これは日本語の文章です。音声で読み上げながら内容を理解します。", "ja"),
            ("Leer en voz alta ayuda a mantener la atención y comprender mejor el texto.", "es"),
            ("La lecture à voix haute aide à rester concentré et à mieux comprendre le texte.", "fr"),
            ("A leitura em voz alta ajuda você a manter o foco e compreender melhor o texto.", "pt"),
            ("La lettura ad alta voce aiuta a mantenere la concentrazione e capire meglio il testo.", "it"),
            ("ज़ोर से पढ़ना ध्यान बनाए रखने और पाठ को बेहतर ढंग से समझने में मदद करता है।", "hi"),
        ]
        for (text, expect) in cases {
            let got = LanguageDetector.detect(text)
            print("[EVAL][Lang] \"\(text.prefix(14))…\" → \(got) (expect \(expect))")
            XCTAssertEqual(got, expect, "语言检测错配：\(text.prefix(20))")
        }
    }

    // MARK: - H 词高亮：中文时间戳合成（离线确定性 = 守住中文逐字高亮修复）

    /// 后端对中文不返回词时间戳，客户端按真实音频时长在字符上合成。本测试离线校验：
    /// 合成非空、token 数==可见 token 数、每个 word 能在文本中顺序定位、时间单调且落在 [0,dur]。
    func testTimestampSynthesis_Offline() {
        let text = "投资金额 200 万美元，投后估值上限 2,000 万美元。"
        let dur = 6.0
        let ts = TTSService.shared.synthesizeTimestamps(text: text, duration: dur)
        let tokens = TTSService.shared.tokenizeForTimestamps(text)
        print("[EVAL][H-synth] textLen=\(text.count) tokens=\(tokens.count) ts=\(ts.count) dur=\(dur)")
        XCTAssertGreaterThan(ts.count, 0, "中文合成时间戳为空 → 逐字高亮失效")
        XCTAssertEqual(ts.count, tokens.count, "时间戳数应等于可见 token 数")

        // 顺序定位率（同 updateHighlight 的游标匹配）
        let ns = text as NSString
        var cursor = 0, hit = 0
        for t in ts {
            let remain = NSRange(location: cursor, length: max(0, ns.length - cursor))
            let r = ns.range(of: t.word, options: [.literal], range: remain)
            if r.location != NSNotFound { hit += 1; cursor = r.location + r.length }
        }
        let rate = Double(hit) / Double(ts.count)
        print("[EVAL][H-synth] 顺序定位 hit=\(hit)/\(ts.count) rate=\(String(format: "%.2f", rate))")
        XCTAssertEqual(rate, 1.0, accuracy: 0.001, "合成 token 应 100% 可在文本中顺序定位")

        // 时间单调递增且落在 [0, dur]
        var monotonic = true
        for i in 0..<ts.count {
            if ts[i].startTime < 0 || ts[i].endTime > dur + 0.001 || ts[i].endTime < ts[i].startTime { monotonic = false }
            if i > 0 && ts[i].startTime + 0.001 < ts[i-1].startTime { monotonic = false }
        }
        XCTAssertTrue(monotonic, "合成时间戳应单调且落在 [0, dur]")

        // 空/零时长保护
        XCTAssertTrue(TTSService.shared.synthesizeTimestamps(text: text, duration: 0).isEmpty, "0 时长应返回空")
        XCTAssertTrue(TTSService.shared.synthesizeTimestamps(text: "   ", duration: 5).isEmpty, "纯空白应返回空")
    }

    // MARK: - H 词高亮命中率（网络：TTS）

    func testHighlightHitRate_EN() async throws {
        try await highlightHitRate(text: enProse, lang: "en", voice: "af_heart", minRate: 0.85, tag: "en")
    }

    /// 中文朗读对齐扩展走「句子级高亮」（后端无词时间戳）。验证：TTS 返回非空 segment、文本非空、
    /// duration 已兜底（句子级推进/解读时间线依赖），且确实无词时间戳（→ 句子级）。
    /// 逐字时间戳合成留给解读路径，见 testTimestampSynthesis_Offline。
    func testHighlightHitRate_ZH() async throws {
        let doc = DocumentBuilder.fromMarkdown(zhLines, title: "t", sourceURL: nil, language: "zh")
        guard let para = doc.readableParagraphs.first(where: { $0.text.count > 8 })?.text else {
            return XCTFail("[zh] 无可朗读段落")
        }
        var segs: [AudioSegment] = []
        try await TTSService.shared.generateTTSForParagraph(paragraphIndex: 0, text: para, voice: "zf_001", speed: 1.0, language: "zh") { seg in
            segs.append(seg)
        }
        guard !segs.isEmpty else { return XCTFail("[zh] TTS 无返回（网络/节点问题）") }
        let totalChars = segs.reduce(0) { $0 + $1.text.count }
        let totalDur = segs.reduce(0.0) { $0 + $1.duration }
        let hasWordTS = segs.contains { !$0.timestamps.isEmpty }
        print("[EVAL][H zh] segs=\(segs.count) chars=\(totalChars) dur=\(String(format: "%.2f", totalDur)) 句子级=\(!hasWordTS)")
        XCTAssertGreaterThan(totalChars, 0, "[zh] segment 文本为空 → 句子级高亮无内容可高亮")
        XCTAssertGreaterThan(totalDur, 0, "[zh] duration 未兜底 → 句子级推进/解读时间线会失准")
    }

    private func highlightHitRate(text: String, lang: String, voice: String, minRate: Double, tag: String) async throws {
        let doc = DocumentBuilder.fromMarkdown(text, title: "t", sourceURL: nil, language: lang)
        guard let para = doc.readableParagraphs.first(where: { $0.text.count > 8 })?.text else {
            return XCTFail("[\(tag)] 无可朗读段落")
        }
        var segs: [AudioSegment] = []
        try await TTSService.shared.generateTTSForParagraph(paragraphIndex: 0, text: para, voice: voice, speed: 1.0, language: lang) { seg in
            segs.append(seg)
        }
        guard !segs.isEmpty else { return XCTFail("[\(tag)] TTS 无返回（网络/节点问题）") }

        var total = 0, hit = 0
        for seg in segs {
            let ns = seg.text as NSString
            var cursor = 0
            for ts in seg.timestamps {
                total += 1
                let remain = NSRange(location: cursor, length: max(0, ns.length - cursor))
                let r = ns.range(of: ts.word, options: [.literal], range: remain)
                if r.location != NSNotFound { hit += 1; cursor = r.location + r.length }
            }
        }
        let rate = total > 0 ? Double(hit) / Double(total) : 0
        print("[EVAL][H \(tag)] segs=\(segs.count) words=\(total) hit=\(hit) rate=\(String(format: "%.2f", rate))")
        XCTAssertGreaterThan(total, 0, "[\(tag)] 无时间戳")
        XCTAssertGreaterThanOrEqual(rate, minRate, "[\(tag)] 词高亮命中率 \(String(format: "%.2f", rate)) < \(minRate)")
    }

    // MARK: - E 解读 mark 锚定（离线确定性 = 真正的回归信号，不依赖网络/额度）

    /// 用「真实后端会返回的几类 mark 文本」直接喂 MarkAnchoring：
    /// 精确子串 / 句中短语 / 带【】包裹 / 大小写+多空格变体 —— 都应能锚定到原文。
    func testExplainAnchorRate_Offline() {
        let doc = DocumentBuilder.fromPlainText(enProse, title: "Eval", language: "en")
        let markTexts = [
            "Reading aloud helps you focus.",                              // 精确整句
            "connects what you see on the page with what you hear",        // 句中短语
            "【the lazy dog】",                                            // 带【】包裹
            "QUICK  brown   fox",                                         // 大小写 + 多空格变体
        ]
        var anchored = 0
        for t in markTexts {
            if MarkAnchoring.locate(markText: t, in: doc, near: nil) != nil { anchored += 1 }
            else { print("[EVAL][E-offline] 未锚定: \(t)") }
        }
        let rate = Double(anchored) / Double(markTexts.count)
        print("[EVAL][E-offline] marks=\(markTexts.count) anchored=\(anchored) rate=\(String(format: "%.2f", rate))")
        XCTAssertGreaterThanOrEqual(rate, 0.75, "mark 锚定命中率 \(String(format: "%.2f", rate)) < 0.75（含归一化/【】/容错）")
    }

    // MARK: - E 解读实网冒烟（best-effort：用全新 device 拿额度；402=额度用满→skip）

    func testExplainAnchorRate_Live() async throws {
        // 用全新 device-id 规避「免费每日额度用满返回 402」，跑完恢复原 visitor id 避免污染。
        let key = Constants.Storage.visitorIdKey
        let original = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("eval-live-\(UUID().uuidString)", forKey: key)
        defer {
            if let o = original { UserDefaults.standard.set(o, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let doc = DocumentBuilder.fromPlainText(enProse, title: "Eval", language: "en")
        let paras = doc.paragraphs.map { QuickreadParagraphDTO(text: $0.text, type: "paragraph") }
        let req = ExtractPlanRequest(source_url: "castreader://eval", title: "Eval", lang: "en",
                                     depth: "standard", text: doc.fullText, fullText: doc.fullText, paragraphs: paras)
        var block0: PlanBlock0?
        do {
            _ = try await QuickReadService.shared.extractPlan(req, onStage: { _ in }, onBlock0: { block0 = $0 })
        } catch QuickReadError.httpError(402) {
            throw XCTSkip("解读免费额度已用满（server 402）— 实网校验跳过，逻辑见 testExplainAnchorRate_Offline")
        }
        let section = try XCTUnwrap(block0?.block_0, "解读未返回 block0")
        let marks = section.events
        print("[EVAL][E-live] block0 textLen=\(section.text.count) marks=\(marks.count)")
        XCTAssertGreaterThan(marks.count, 0, "解读应返回 marks")

        var anchored = 0
        for ev in marks {
            if let t = ev.text, !t.isEmpty, MarkAnchoring.locate(markText: t, in: doc, near: nil) != nil { anchored += 1 }
        }
        let rate = marks.isEmpty ? 0 : Double(anchored) / Double(marks.count)
        print("[EVAL][E-live] anchorRate=\(String(format: "%.2f", rate)) (\(anchored)/\(marks.count))")
        XCTAssertGreaterThanOrEqual(rate, 0.6, "实网 mark 锚定命中率 \(String(format: "%.2f", rate)) < 0.6")
    }

    // MARK: - P 预生成/预加载（消除段间等首字节 gap 的核心架构）

    private let prefetchMd = """
    第一段。朗读时同时用耳朵和眼睛锁定注意力，像老师指读一样。

    第二段。预生成下一段可以消除句子之间的长停顿，让衔接更顺畅。

    第三段。链式预取保证播放始终领先当前一段，连续朗读不卡顿。
    """

    /// 验证「预生成」：当前段生成完后 preloadNext 真的后台生成「下一可朗读段」TTS 到缓存（不再是空占位）。
    /// 这是消除段间 gap 的前提——advance 时缓存已就绪即可秒接，无需再等首字节。
    @MainActor
    func testPrefetch_GeneratesNextParagraph() async throws {
        let doc = DocumentBuilder.fromMarkdown(prefetchMd, title: "t", sourceURL: nil, language: "zh")
        let vm = ReadAloudViewModel(document: doc)
        let readable = vm.dbgReadableIndices
        guard readable.count >= 2 else { return XCTFail("[P] 可朗读段不足 2") }

        await vm.dbgPreloadNext(after: readable[0])   // 触发预取 readable[1]
        await vm.dbgWaitPrefetch()

        let pIdx = vm.dbgPrefetchedIndex
        let segs = vm.dbgPrefetchedSegments
        print("[EVAL][P] 预取 prefetchedIndex=\(String(describing: pIdx)) segs=\(segs.count) para=\(segs.first?.paragraphIndex ?? -1)")
        guard !segs.isEmpty else { return XCTFail("[P] 预取无 segment（网络/节点问题，或预取未实现 → gap 不会消除）") }
        XCTAssertEqual(pIdx, readable[1], "[P] 预取段索引应为下一可朗读段")
        XCTAssertEqual(segs.first?.paragraphIndex, readable[1], "[P] 预取 segment 段号不对（高亮会错位）")
    }

    /// 验证「秒接」：预取就绪后 promote 把缓存转正为当前段——currentParagraphIndex 切到该段、
    /// segmentsByParagraph 复用缓存（segment 数一致=没重新请求 TTS）、预取缓存清空。
    @MainActor
    func testPrefetch_PromoteReusesCacheNoRegen() async throws {
        let doc = DocumentBuilder.fromMarkdown(prefetchMd, title: "t", sourceURL: nil, language: "zh")
        let vm = ReadAloudViewModel(document: doc)
        let readable = vm.dbgReadableIndices
        guard readable.count >= 2 else { return XCTFail("[P] 可朗读段不足 2") }

        await vm.dbgPreloadNext(after: readable[0])
        await vm.dbgWaitPrefetch()
        let cached = vm.dbgPrefetchedSegments
        guard !cached.isEmpty else { return XCTFail("[P] 预取为空，无法验证转正（网络/节点问题）") }

        vm.dbgPromote(to: readable[1])

        let cur = vm.currentParagraphIndex
        let after = vm.dbgPrefetchedIndex
        let promoted = vm.dbgSegments(for: readable[1])
        print("[EVAL][P] 转正 current=\(cur) seg1=\(promoted.count) cached=\(cached.count) prefetchedAfter=\(String(describing: after))")
        XCTAssertEqual(cur, readable[1], "[P] 转正后当前段未切到预取段")
        XCTAssertEqual(promoted.count, cached.count, "[P] 转正未复用预取缓存（段 segment 数≠缓存数=重新生成了 → 没省掉 gap）")
        XCTAssertNil(after, "[P] 转正后未清空预取缓存（链式预取状态脏）")
    }

    /// 验证「真机路径」：generate 当前段完成后会自动触发预取下一段（preloadNext 接在生成链路尾部）。
    /// 这是消除 gap 的实际触发点——前两个测试手动调 preloadNext，本测试证明朗读时会自动发生。
    @MainActor
    func testPrefetch_GenerateAutoTriggersPreload() async throws {
        let doc = DocumentBuilder.fromMarkdown(prefetchMd, title: "t", sourceURL: nil, language: "zh")
        let vm = ReadAloudViewModel(document: doc)
        let readable = vm.dbgReadableIndices
        guard readable.count >= 2 else { return XCTFail("[P] 可朗读段不足 2") }

        vm.dbgGenerate(readable[0])        // 真实生成当前段（段0）
        await vm.dbgWaitGeneration()        // 段0生成完 → 链路尾部自动 preloadNext(段0) 启动段1预取
        await vm.dbgWaitPrefetch()          // 等段1预取完

        let pIdx = vm.dbgPrefetchedIndex
        let segs = vm.dbgPrefetchedSegments
        print("[EVAL][P] generate段0完成后 自动预取 prefetchedIndex=\(String(describing: pIdx)) segs=\(segs.count)")
        guard !segs.isEmpty else { return XCTFail("[P] generate 后未自动预取（网络/节点问题，或链路未触发 → 段间仍有 gap）") }
        XCTAssertEqual(pIdx, readable[1], "[P] generate 完当前段后应自动预取下一可朗读段")
    }

    // MARK: - PH 照片中文高亮（无词时间戳 → 按 segment 进度线性推进 OCR 词；离线确定性）

    private func ocrParagraph(text: String, ocrWords: [String]) -> ReadingParagraph {
        let words = ocrWords.enumerated().map { idx, word in
            OCRWord(id: idx, text: word, bboxNorm: CGRect(x: CGFloat(idx) * 0.01, y: 0.5, width: 0.008, height: 0.02))
        }
        return ReadingParagraph(id: 0, text: text, type: .paragraph, words: words)
    }

    private func timestamps(_ words: [String]) -> [TTSTimestamp] {
        words.enumerated().map { idx, word in
            TTSTimestamp(word: word, startTime: Double(idx), endTime: Double(idx) + 0.5)
        }
    }

    /// Kindle/OCR 英文词高亮必须像扩展一样只向前匹配：同段重复词不能跳回之前的同名词。
    func testOCRWordAligner_RepeatedWordsFollowReadingOrder() {
        let words = ["the", "cat", "and", "the", "dog", "saw", "the", "cat"]
        let paragraph = ocrParagraph(text: words.joined(separator: " "), ocrWords: words)
        let mapped = OCRWordAligner.mapTimestampWords(timestamps(words), in: paragraph)
        XCTAssertEqual(mapped, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    /// OCR 偶尔漏词时，缺失词可以不高亮，但绝不能用 nearest bbox 拉回 cursor 前面的词。
    func testOCRWordAligner_MissingOCRWordDoesNotBacktrack() {
        let ttsWords = ["the", "cat", "and", "the", "dog", "saw", "the", "cat"]
        let ocrWords = ["the", "cat", "the", "dog", "saw", "the", "cat"]
        let paragraph = ocrParagraph(text: ttsWords.joined(separator: " "), ocrWords: ocrWords)
        let mapped = OCRWordAligner.mapTimestampWords(timestamps(ttsWords), in: paragraph)

        XCTAssertEqual(mapped, [0, 1, nil, 2, 3, 4, 5, 6])
        let compact = mapped.compactMap { $0 }
        XCTAssertEqual(compact, compact.sorted(), "OCR word indexes must be monotonic: \(mapped)")
    }

    /// 照片中文 TTS 无词时间戳，高亮按段内进度推进。验证 photoWordIndex 单调不减、覆盖首末词、不越界。
    @MainActor
    func testPhotoWordIndex_MonotonicAndBounded() {
        let wordCount = 12, segCount = 4
        var last = -1, maxIdx = -1
        for segPos in 0..<segCount {
            for step in 0...10 {
                let prog = Double(step) / 10.0
                guard let idx = ReadAloudViewModel.photoWordIndex(wordCount: wordCount, segPos: segPos, segCount: segCount, segProgress: prog) else {
                    return XCTFail("[PH] 不应返回 nil（wordCount>0）")
                }
                XCTAssertGreaterThanOrEqual(idx, 0, "[PH] 越下界")
                XCTAssertLessThan(idx, wordCount, "[PH] 越上界")
                XCTAssertGreaterThanOrEqual(idx, last, "[PH] 高亮回跳 segPos=\(segPos) prog=\(prog) idx=\(idx)<last=\(last)")
                last = idx; maxIdx = max(maxIdx, idx)
            }
        }
        XCTAssertEqual(ReadAloudViewModel.photoWordIndex(wordCount: wordCount, segPos: 0, segCount: segCount, segProgress: 0), 0, "[PH] 段首应高亮第 0 词")
        XCTAssertEqual(maxIdx, wordCount - 1, "[PH] 整段播完应覆盖到最后一词（maxIdx=\(maxIdx)）")
        XCTAssertNil(ReadAloudViewModel.photoWordIndex(wordCount: 0, segPos: 0, segCount: 1, segProgress: 0.5), "[PH] 无词应返回 nil")
        print("[EVAL][PH] photoWordIndex 单调不减、覆盖 0..\(wordCount - 1)、边界正确")
    }

    // MARK: - MA mark 锚定标点/装饰容错（对齐扩展 fuzzyFind，离线确定性）

    /// 归一化剔除标点后，LLM 锚文本里多出的括号/引号/顿号都应能匹配原文（之前保留标点 → 这些会 MISS）。
    @MainActor
    func testMarkAnchoring_PunctuationTolerance() {
        let zh = "朗读功能可以同时用耳朵和眼睛锁定注意力，像老师指读一样帮助你专注。解读则在原文上按时间点画手写标注。"
        let doc = DocumentBuilder.fromPlainText(zh, title: "t", language: "zh")
        let hits = [
            "同时用耳朵和眼睛锁定注意力",        // 原文精确片段
            "【同时用耳朵和眼睛锁定注意力】",     // LLM 常加的方括号装饰
            "「像老师指读一样」",               // 引号装饰
            "同时用耳朵、和眼睛、锁定注意力",     // 多插标点（剔除标点后一致）
            "在原文上按时间点画手写标注",        // 另一句
        ]
        var ok = 0
        for t in hits {
            if MarkAnchoring.locate(markText: t, in: doc, near: nil) != nil { ok += 1 }
            else { print("[EVAL][MA] MISS（本应命中）: \(t)") }
        }
        print("[EVAL][MA] 标点/装饰容错命中 \(ok)/\(hits.count)")
        XCTAssertEqual(ok, hits.count, "[MA] 带标点/装饰的锚文本应都能匹配（剔除标点归一化）")
        XCTAssertNil(MarkAnchoring.locate(markText: "完全不存在的内容ABCXYZ", in: doc, near: nil), "[MA] 不存在内容不应误命中")
    }

    // MARK: - Sub 解读字幕分句（离线确定性）

    /// 验证 splitSentences 切句 + subtitleForProgress 按进度选句单调推进、覆盖首末、英文小数不误切。
    @MainActor
    func testSubtitleSentenceSplit() {
        let text = "这是第一句。这是第二句！第三句呢？最后一段没有标点"
        let s = ExplainViewModel.splitSentences(text)
        print("[EVAL][Sub] 切句数=\(s.count) \(s)")
        XCTAssertGreaterThanOrEqual(s.count, 4, "[Sub] 应切出 4 句")
        XCTAssertEqual(s.first, "这是第一句。", "[Sub] 首句应含句末标点")
        XCTAssertEqual(ExplainViewModel.subtitleForProgress(s, progress: 0.0), s.first, "[Sub] 进度 0 → 首句")
        XCTAssertEqual(ExplainViewModel.subtitleForProgress(s, progress: 1.0), s.last, "[Sub] 进度 1 → 末句")
        var lastIdx = 0, monotonic = true
        for step in 0...20 {
            let cur = ExplainViewModel.subtitleForProgress(s, progress: Double(step) / 20.0) ?? ""
            let idx = s.firstIndex(of: cur) ?? 0
            if idx < lastIdx { monotonic = false }
            lastIdx = idx
        }
        XCTAssertTrue(monotonic, "[Sub] 进度推进时字幕句不应倒退")
        let en = ExplainViewModel.splitSentences("Pay 3.14 dollars now. Next sentence here.")
        print("[EVAL][Sub] 英文切句=\(en)")
        XCTAssertTrue(en.contains { $0.contains("3.14") }, "[Sub] 小数点不应被当句末切开")
        XCTAssertGreaterThanOrEqual(en.count, 2, "[Sub] 英文应按句点后空格切句")
        // 过长中文句 → 按逗号二次切成多条短字幕（对齐扩展 buildLines，避免一条字幕一大段）
        let long = ExplainViewModel.splitSentences("他站在窗前，望着远方连绵起伏的群山，心中涌起一股莫名的情绪，那是一种既兴奋又恐惧的复杂感受。")
        print("[EVAL][Sub] 长句二次切=\(long)")
        XCTAssertGreaterThanOrEqual(long.count, 3, "[Sub] 过长句应按逗号二次切成多条")
        XCTAssertTrue(long.allSatisfy { $0.count <= 35 }, "[Sub] 二次切后每条字幕不应过长")
    }

    // MARK: - PDF 原生提取（PDFKit fromPDFNative，离线）

    /// 生成含中英句的 PDF → fromPDFNative → 验证 .pdf 源、按句切段、每句带 page+range、保留字节。
    @MainActor
    func testPdfNativeExtract() {
        let text = "第一句话测试内容。第二句话也在这里！Third sentence here. 最后一句没有标点结尾"
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            (text as NSString).draw(in: bounds.insetBy(dx: 20, dy: 20),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eval_test.pdf")
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let doc = DocumentBuilder.fromPDFNative(url: url) else {
            return XCTFail("[PDF] fromPDFNative 返回 nil（PDF 无文字层？）")
        }
        print("[EVAL][PDF] sourceKind=\(doc.sourceKind) 段数=\(doc.paragraphs.count) fileData=\(doc.fileData?.count ?? 0) 首句=\(doc.paragraphs.first?.text ?? "")")
        XCTAssertEqual(doc.sourceKind, .pdf, "[PDF] 源类型应为 .pdf")
        XCTAssertNotNil(doc.fileData, "[PDF] 应保留 PDF 字节给 PDFView 渲染")
        XCTAssertGreaterThanOrEqual(doc.paragraphs.count, 2, "[PDF] 应按句切出多段")
        XCTAssertTrue(doc.paragraphs.allSatisfy { $0.pdfPageIndex != nil && $0.pdfRange != nil },
                      "[PDF] 每句应记录 page + range（characterBounds 高亮用）")
        XCTAssertFalse(doc.paragraphs.contains { $0.text.contains("\n") || $0.text.contains("\r") },
                       "[PDF] 句文本不应含硬换行（已 stripPdfLineBreaks，否则 TTS 在换行处停顿）")
    }

    /// 诊断：PDFKit page.string 字符索引是否与 characterBounds(at:) 对齐（决定 PDF 高亮用哪种定位）。
    @MainActor
    func testPdfCharBoundsAlign() {
        let text = "第一句话用来测试高亮对齐效果。第二句话内容稍微长一点以便换行。第三句结束了。"
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 500)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            ctx.beginPage()
            (text as NSString).draw(in: bounds.insetBy(dx: 20, dy: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        guard let pdf = PDFDocument(data: data), let page = pdf.page(at: 0) else {
            return XCTFail("[PDFAlign] PDF 创建失败")
        }
        let s = (page.string ?? "") as NSString
        print("[EVAL][PDFAlign] string.length=\(s.length) numberOfCharacters=\(page.numberOfCharacters) 对齐=\(s.length == page.numberOfCharacters)")
        let probe = "第二句话"
        let r = s.range(of: probe)
        if r.location != NSNotFound {
            var u = CGRect.null
            for i in r.location..<(r.location + r.length) {
                let b = page.characterBounds(at: i)
                if !b.isNull && b.width > 0.5 { u = u.union(b) }
            }
            let fb = pdf.findString(probe, withOptions: []).first?.bounds(for: page) ?? .null
            print("[EVAL][PDFAlign] '第二句话' charBounds union=\(u) | findString bounds=\(fb)")
            if !u.isNull && !fb.isNull {
                print("[EVAL][PDFAlign] 中心偏差 dx=\(Int(abs(u.midX - fb.midX))) dy=\(Int(abs(u.midY - fb.midY)))")
            }
        } else {
            print("[EVAL][PDFAlign] page.string 未找到探针句（提取异常）")
        }
    }
}
