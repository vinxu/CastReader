//
//  PDFReaderView.swift
//  CastReader
//
//  PDF 本地原生渲染（PDFKit PDFView，保排版、不重排，故无换行问题）。
//  朗读时按 currentParagraphIndex 在 PDF 上用 characterBounds 画当前句高亮 annotation + 自动滚动。
//  解读手写标注为后续阶段（MVP 先做朗读）。
//

import SwiftUI
import PDFKit
import Combine

struct PDFReaderView: UIViewRepresentable {
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .systemBackground
        if let data = document.fileData { v.document = PDFDocument(data: data) }
        context.coordinator.pdfView = v
        context.coordinator.attach(readVM: readVM, explainVM: explainVM, doc: document)
        // 点击 PDF 任意句 → 从该句开始朗读（配合滚动翻页实现跳读/跳页）。
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        v.addGestureRecognizer(tap)
        // 翻页 → 把当前页范围告诉解读 VM（点解读时只对当前页生成讲解，而非全文从头）。
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: v)
        DispatchQueue.main.async { context.coordinator.updatePdfScope() }
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        context.coordinator.setMode(mode)
    }

    @MainActor
    final class Coordinator {
        weak var pdfView: PDFView?
        weak var readVM: ReadAloudViewModel?
        weak var explainVM: ExplainViewModel?
        private var cancellables = Set<AnyCancellable>()
        private var doc: ReadingDocument?
        private var shown: [(page: PDFPage, ann: PDFAnnotation)] = []
        private var markShown: [(page: PDFPage, ann: PDFAnnotation)] = []
        private var autoScroll = true
        private var lastMode: ReaderMode?
        private var lastSel: PDFSelection?      // 上一句的 selection：顺序前向 findString，解决长 PDF 重复句歧义 + 提速
        private var lastHlIdx = -1
        private var lastMarkScrollId: UUID?     // 解读标注上次滚到的 mark：mark 变化且超出视野才滚、同 mark 重画不抖
        // 词级高亮缓存（英文）：当前句各词的 page 矩形，句内顺序 findString 增量算、避免每 tick 重复定位。
        private var wordAnn: (page: PDFPage, ann: PDFAnnotation)?
        private var wordRects: [CGRect] = []
        private var wordRectsPara = -1
        private var wordSearchLoc = 0           // 句内 findString 顺序游标（page.string 绝对字符位置）

        /// 切模式：朗读模式清解读标注、解读模式清朗读高亮（两层互不残留）。
        func setMode(_ mode: ReaderMode) {
            guard mode != lastMode else { return }
            lastMode = mode
            if mode == .read { clearMarkAnnotations() } else { clearHighlights() }
        }

        func attach(readVM: ReadAloudViewModel, explainVM: ExplainViewModel, doc: ReadingDocument) {
            self.doc = doc
            self.readVM = readVM
            self.explainVM = explainVM
            readVM.$currentParagraphIndex
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] idx in self?.highlight(idx) }
                .store(in: &cancellables)
            // 英文词级：当前句内 findString 定位 TTS 词 → 画词矩形（叠在句级淡高亮上，“老师指读”）。
            readVM.$pdfHighlight
                .compactMap { $0 }
                .receive(on: RunLoop.main)
                .sink { [weak self] cmd in self?.highlightWord(cmd) }
                .store(in: &cancellables)
            readVM.$autoScrollEnabled
                .removeDuplicates()
                .sink { [weak self] on in self?.autoScroll = on }
                .store(in: &cancellables)
            // 解读手写标注：activeMarks → 在 PDF 上画对应 annotation（findString 定位）。
            explainVM.$activeMarks
                .receive(on: RunLoop.main)
                .sink { [weak self] marks in self?.showMarks(marks) }
                .store(in: &cancellables)
        }

        private func clearMarkAnnotations() {
            for item in markShown { item.page.removeAnnotation(item.ann) }
            markShown.removeAll()
        }

        private func showMarks(_ marks: [ResolvedMark]) {
            guard let pdfDoc = pdfView?.document, let doc else { return }
            clearMarkAnnotations()
            guard !marks.isEmpty else { lastMarkScrollId = nil; return }   // 清空（重播/退出）→ 复位
            var lastDrawnSel: PDFSelection?     // 最后一个成功画出的 mark（= 最新出现）→ 滚动跟随它
            var lastDrawnId: UUID?
            let ink = UIColor(hexString: AppSettings.shared.highlightColorHex).withAlphaComponent(0.85)   // #FD5F01 统一橙（深浅都清晰）
            let primary = UIColor(hexString: AppSettings.shared.highlightColorHex)
            for m in marks {
                guard m.paragraphIndex >= 0, m.paragraphIndex < doc.paragraphs.count else { continue }
                let para = doc.paragraphs[m.paragraphIndex]
                guard let pageIdx = para.pdfPageIndex, let page = pdfDoc.page(at: pageIdx) else { continue }
                let chars = Array(para.text)
                guard m.charRange.lowerBound >= 0, m.charRange.upperBound <= chars.count,
                      m.charRange.lowerBound < m.charRange.upperBound else { continue }
                let markText = String(chars[m.charRange])
                    .replacingOccurrences(of: "\n", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard markText.count >= 1 else { continue }
                let sels = pdfDoc.findString(markText, withOptions: [.caseInsensitive])
                guard let sel = sels.first(where: { $0.pages.contains(page) }) ?? sels.first else { continue }
                // 收集该 mark 在当前页的各行 bounds（page 坐标）
                var lineBounds: [CGRect] = []
                for lineSel in sel.selectionsByLine() {
                    for p in lineSel.pages where p == page {
                        let b = lineSel.bounds(for: p)
                        if !b.isNull && b.width > 1 && b.height > 1 { lineBounds.append(b) }
                    }
                }
                guard !lineBounds.isEmpty else { continue }
                // 自定义手写 annotation：draw 里画 HandwrittenMark 同款手绘 path（与拍摄/纯文本/网页视觉一致）。
                let union = lineBounds.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -12, dy: -10)
                let ann = HandwrittenPDFAnnotation(bounds: union, forType: .stamp, withProperties: nil)
                ann.markRects = lineBounds
                ann.markAction = m.action
                ann.markSeed = m.seed
                ann.markN = m.n
                ann.markWeight = m.weight
                ann.inkColor = ink
                ann.primaryColor = primary
                page.addAnnotation(ann)
                markShown.append((page, ann))
                lastDrawnSel = sel; lastDrawnId = m.id   // 跟踪最新画出的 mark
            }
            // 滚动跟随最新标注：mark 变化且已移出视野才滚（同页从上到下、跨页都跟随；在视野内不跳、同 mark 不抖）。
            if autoScroll, let sel = lastDrawnSel, lastDrawnId != lastMarkScrollId,
               let pv = pdfView, let p = sel.pages.first {
                lastMarkScrollId = lastDrawnId
                if markIsOffscreen(sel.bounds(for: p), page: p, in: pv) { pv.go(to: sel) }
            }
        }

        /// mark 是否在当前可见区域外（在视野内就不滚，避免每个 mark 都跳到顶部）。
        private func markIsOffscreen(_ pageBounds: CGRect, page: PDFPage, in pv: PDFView) -> Bool {
            guard !pageBounds.isNull else { return false }
            let viewRect = pv.convert(pageBounds, from: page)   // page 坐标 → PDFView 坐标
            let safe = pv.bounds.insetBy(dx: 0, dy: 60)         // 上下留 60pt 余量
            return !safe.contains(CGPoint(x: viewRect.midX, y: viewRect.midY))
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let pdfView, let doc else { return }
            let pt = g.location(in: pdfView)
            guard let page = pdfView.page(for: pt, nearest: true) else { return }
            let pagePt = pdfView.convert(pt, to: page)
            let charIdx = page.characterIndex(at: pagePt)
            guard charIdx >= 0 else { return }
            let pageIdx = pdfView.document?.index(for: page) ?? -1
            guard pageIdx >= 0 else { return }
            // 找包含点击字符的句 → 从该句朗读（跳读/跳页）
            if let para = doc.paragraphs.first(where: {
                $0.pdfPageIndex == pageIdx && NSLocationInRange(charIdx, $0.pdfRange ?? NSRange(location: 0, length: 0))
            }) {
                readVM?.jump(to: para.id)
            }
        }

        @objc func pageChanged() { updatePdfScope() }

        /// 当前可见页的句 → 告诉解读 VM，限定解读范围为当前页（点解读时只对当前页生成讲解）。
        func updatePdfScope() {
            guard let pdfView, let doc, let page = pdfView.currentPage else { return }
            let pageIdx = pdfView.document?.index(for: page) ?? -1
            guard pageIdx >= 0 else { return }
            // 解读进行中不改起点（解读自己逐页推进至末尾）；仅 idle 时把当前可见页设为下次解读起点。
            guard explainVM?.isExplainIdle ?? true else { return }
            explainVM?.setPdfScope(doc.paragraphs.filter { $0.pdfPageIndex == pageIdx }, all: doc.paragraphs)
        }

        private func clearHighlights() {
            for item in shown { item.page.removeAnnotation(item.ann) }
            shown.removeAll()
            if let w = wordAnn { w.page.removeAnnotation(w.ann); wordAnn = nil }
            wordRectsPara = -1
            wordRects = []
        }

        private func highlight(_ idx: Int) {
            guard let pdfView, let doc, idx >= 0, idx < doc.paragraphs.count,
                  let pdfDoc = pdfView.document else { return }
            let para = doc.paragraphs[idx]
            guard let pageIdx = para.pdfPageIndex, let page = pdfDoc.page(at: pageIdx),
                  let range = para.pdfRange else { return }
            clearHighlights()
            let color = UIColor(hexString: AppSettings.shared.highlightColorHex).withAlphaComponent(0.33)
            let ns = (page.string ?? "") as NSString

            guard range.location >= 0, range.location + range.length <= ns.length else { lastHlIdx = idx; return }
            // needle 用「句在 page.string 的精确子串」（原样、含 \n/空格）—— 它一定是 page.string 子串、findString 必匹配；
            // PDFSelection 位置由 PDFKit 内部映射文本↔位置，不依赖 page.string 索引↔characterBounds（后者在某些 PDF
            // 整体错位几字符 → 高亮偏移/跨句）。之前去 \n、用已 trim 的 para.text 破坏了「精确子串」才导致大多数句失配。
            let needle = ns.substring(with: range)
            guard needle.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { lastHlIdx = idx; return }
            let opts: NSString.CompareOptions = [.caseInsensitive]
            var selection: PDFSelection?
            // 顺序前向：朗读逐句推进，从上一句之后找下一个 → 长 PDF 重复句拿到「正在读的那一处」。
            if idx == lastHlIdx + 1, let from = lastSel {
                selection = pdfDoc.findString(needle, fromSelection: from, withOptions: opts)
            }
            if selection == nil {   // 首句 / 跳读 → 全文找，优先落当前页
                let all = pdfDoc.findString(needle, withOptions: opts)
                selection = all.first(where: { $0.pages.contains(page) }) ?? all.first
            }
            if selection == nil, range.length > 18 {   // 精确子串都没命中（极少）→ 句首片段兜底
                let head = ns.substring(with: NSRange(location: range.location, length: 18))
                let all = pdfDoc.findString(head, withOptions: opts)
                selection = all.first(where: { $0.pages.contains(page) }) ?? all.first
            }
            lastHlIdx = idx
            guard let selection = selection else { return }
            lastSel = selection
            for lineSel in selection.selectionsByLine() {
                for p in lineSel.pages {
                    let b = lineSel.bounds(for: p)
                    if b.isNull || b.width < 1 || b.height < 1 { continue }
                    let ann = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
                    ann.color = color
                    p.addAnnotation(ann)
                    shown.append((p, ann))
                }
            }
            if autoScroll { pdfView.go(to: selection) }
        }

        /// 英文词级高亮：在当前句的 page.string 范围内顺序 findString 每个 TTS 词，按字符位置取 PDFSelection 画词矩形。
        /// 复用句级同款 findString 路径（不依赖易错位的 characterBounds）；词矩形按句缓存，tick 高频调用仅查缓存。
        private func highlightWord(_ cmd: PDFWordHighlight) {
            guard let pdfView, let doc, let pdfDoc = pdfView.document,
                  cmd.paragraphIndex >= 0, cmd.paragraphIndex < doc.paragraphs.count else { return }
            let para = doc.paragraphs[cmd.paragraphIndex]
            guard let pageIdx = para.pdfPageIndex, let page = pdfDoc.page(at: pageIdx),
                  let range = para.pdfRange else { return }
            let ns = (page.string ?? "") as NSString
            guard range.location >= 0, range.location + range.length <= ns.length else { return }
            // 句变 → 重置词缓存，游标回句首。
            if wordRectsPara != cmd.paragraphIndex {
                wordRectsPara = cmd.paragraphIndex
                wordRects = []
                wordSearchLoc = range.location
            }
            let sentenceEnd = range.location + range.length
            // 增量定位到 wordIndex：句内顺序 findString，前向游标解决句内重复词歧义。
            while wordRects.count <= cmd.wordIndex && wordRects.count < cmd.words.count {
                let w = cmd.words[wordRects.count].trimmingCharacters(in: .whitespacesAndNewlines)
                let span = max(0, sentenceEnd - wordSearchLoc)
                guard !w.isEmpty, span > 0 else { wordRects.append(.null); continue }
                let found = ns.range(of: w, options: [.caseInsensitive], range: NSRange(location: wordSearchLoc, length: span))
                if found.location == NSNotFound {
                    wordRects.append(.null)   // 词在句里找不到（标点/规范化差异）→ 该词不画，保留上一个
                } else {
                    let sel = pdfDoc.selection(from: page, atCharacterIndex: found.location,
                                               to: page, atCharacterIndex: found.location + found.length)
                    wordRects.append(sel?.bounds(for: page) ?? .null)
                    wordSearchLoc = found.location + found.length
                }
            }
            guard cmd.wordIndex < wordRects.count else { return }
            let rect = wordRects[cmd.wordIndex]
            guard !rect.isNull, rect.width > 1, rect.height > 1 else { return }   // 没定位到 → 保留上一个词高亮
            if let prev = wordAnn { prev.page.removeAnnotation(prev.ann) }
            let color = UIColor(hexString: AppSettings.shared.highlightColorHex).withAlphaComponent(0.5)
            let ann = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            ann.color = color
            page.addAnnotation(ann)
            wordAnn = (page, ann)
        }
    }
}

/// PDF 解读手写标注：在 `draw` 里复用 native `HandwrittenMark` 的手绘 path，
/// 让 PDF 的 mark 与拍摄/纯文本/网页走同一套视觉（手写圈/下划线/荧光/序号），而非 PDFKit 原生标注。
/// mark 的「计算」（ResolvedMark：段落+字符范围+action+seed）由 ExplainViewModel 统一产出，与其它源完全一致。
final class HandwrittenPDFAnnotation: PDFAnnotation {
    var markRects: [CGRect] = []          // page 坐标（原点左下、y 向上）
    var markAction = ""
    var markSeed: UInt64 = 0
    var markN: Int?
    var markWeight: String?               // P1：重要度分层 → 笔触粗细
    var inkColor = UIColor(hexString: AppSettings.shared.highlightColorHex).withAlphaComponent(0.85)   // #FD5F01 统一橙（深浅都清晰）
    var primaryColor: UIColor = .systemOrange

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !markRects.isEmpty else { return }
        let b = bounds
        // page 坐标(y 上) → annotation 局部(原点左上、y 下)，喂给 HandwrittenMark（其几何按 y 下，同 SwiftUI）。
        let local = markRects.map {
            CGRect(x: $0.minX - b.minX, y: b.maxY - $0.maxY, width: $0.width, height: $0.height)
        }
        let path: Path
        let stroke: UIColor
        let lineWidth: CGFloat
        var alpha: CGFloat = 1

        context.saveGState()
        // 移到 annotation 左上原点并翻 y → 进入「局部 y 下」坐标系（HandwrittenMark / UIKit 文本都按此）。
        context.translateBy(x: b.minX, y: b.maxY)
        context.scaleBy(x: 1, y: -1)

        let wMul = HandwrittenMark.weightMultiplier(markWeight)
        switch markAction {
        case "highlight":
            path = HandwrittenMark.highlightPath(over: local, seed: markSeed)
            stroke = primaryColor
            lineWidth = (local.map { $0.height }.max() ?? 18) * 0.85 * wMul
            alpha = 0.28
            context.setBlendMode(.multiply)
        case "circle", "number":
            path = HandwrittenMark.circlePath(around: local, seed: markSeed)
            stroke = (markAction == "number") ? inkColor : primaryColor
            lineWidth = 2.4 * wMul
        case "underline":
            path = HandwrittenMark.underlinePath(over: local, seed: markSeed)
            stroke = inkColor
            lineWidth = 2.2 * wMul
        case "wave":
            path = HandwrittenMark.wavePath(over: local, seed: markSeed)
            stroke = inkColor
            lineWidth = 2.2 * wMul
            alpha = 0.9
        case "strike":
            path = HandwrittenMark.strikePath(over: local, seed: markSeed)
            stroke = inkColor
            lineWidth = 2.2 * wMul
        case "star":
            path = HandwrittenMark.starPath(near: local, seed: markSeed)
            stroke = inkColor
            lineWidth = 2.2 * wMul
            alpha = 0.9
        default:
            path = HandwrittenMark.underlinePath(over: local, seed: markSeed)
            stroke = inkColor
            lineWidth = 2.0 * wMul
        }

        context.addPath(path.cgPath)
        context.setStrokeColor(stroke.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()

        // 序号徽标：在翻转后的局部 y 下坐标系里直接画文字（正立）。
        if markAction == "number", let n = markN {
            context.setBlendMode(.normal)
            let ring = HandwrittenMark.numberRingRect(near: local)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: ring.height * 0.55, weight: .bold),
                .foregroundColor: inkColor
            ]
            let s = NSAttributedString(string: "\(n)", attributes: attrs)
            let sz = s.size()
            UIGraphicsPushContext(context)
            s.draw(at: CGPoint(x: ring.midX - sz.width / 2, y: ring.midY - sz.height / 2))
            UIGraphicsPopContext()
        }

        context.restoreGState()
    }
}
