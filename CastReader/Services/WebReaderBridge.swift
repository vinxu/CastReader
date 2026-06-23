//
//  WebReaderBridge.swift
//  CastReader
//
//  WKWebView 的 native↔JS 桥（WebReaderView 的 Coordinator）：
//  - JS→native：ready / rendered（正文段落）/ paragraphTapped / log / error
//  - native→JS：CR.init / updateAudioSegments / updateSentenceHighlight / updateWordHighlight / scrollTo / setColor / setActive
//  订阅 ReadAloudViewModel 的 .web 输出（webAudioSegments / webHighlight / currentParagraphIndex）驱动 DOM 高亮。
//  TTS 全部走 native（ReadAloudViewModel + AudioPlayerService），WebView 仅渲染 + 高亮。
//

import Foundation
import WebKit
import Combine

@MainActor
final class WebReaderBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "castreader"

    weak var webView: WKWebView?
    var pendingDocxBase64: String?              // 仅 docx：待 JS ready 后交 mammoth 渲染的字节
    var pendingEpubBase64: String?              // 仅 epub：待 JS ready 后交 epub.js 渲染的字节
    private weak var readVM: ReadAloudViewModel?
    private weak var explainVM: ExplainViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var didInit = false
    private var didAutoStart = false
    private var isReadMode = true        // 当前模式；onRendered 自动开播据此决定启动朗读还是解读
    private var shownMarkIds = Set<String>()

    // MARK: - 关联 VM + 订阅

    func attach(readVM: ReadAloudViewModel, explainVM: ExplainViewModel) {
        guard self.readVM == nil else { return }   // 只关联一次
        self.readVM = readVM
        self.explainVM = explainVM

        readVM.$webHighlight
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] cmd in self?.pushHighlight(cmd) }
            .store(in: &cancellables)
        readVM.$currentParagraphIndex
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] idx in
                guard idx >= 0, self?.readVM?.autoScrollEnabled == true else { return }
                self?.call("scrollTo", ["paragraphIndex": idx, "anchor": 0.3])
            }
            .store(in: &cancellables)

        // 解读：activeMarks → DOM 手写标注；scrollTarget → 跟随滚动。
        explainVM.$activeMarks
            .receive(on: RunLoop.main)
            .sink { [weak self] marks in self?.pushMarks(marks) }
            .store(in: &cancellables)
        explainVM.$scrollTarget
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] idx in
                guard idx >= 0 else { return }
                self?.call("scrollTo", ["paragraphIndex": idx, "anchor": 0.35])
            }
            .store(in: &cancellables)
    }

    // MARK: - JS → native

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor [weak self] in self?.handle(body) }
    }

    private func handle(_ body: Any) {
        guard let msg = WebInboundMessage(body) else { return }
        switch msg.type {
        case "ready":
            print("[WebReader] ✅ JS ready: \(msg.payload)")
            if let b64 = pendingDocxBase64 {
                pendingDocxBase64 = nil
                NSLog("CRDBG docx render base64Len=%d", b64.count)
                call("renderDocx", ["base64": b64])
            }
            if let b64 = pendingEpubBase64 {
                pendingEpubBase64 = nil
                NSLog("CRDBG epub render base64Len=%d", b64.count)
                call("renderEpub", ["base64": b64])
            }
        case "rendered":
            let raw = msg.payload["paragraphs"] as? [[String: Any]] ?? []
            let paras = raw.compactMap { WebRenderedParagraph($0) }
            print("[WebReader] 📄 rendered paragraphs=\(paras.count)")
            onRendered(paras)
        case "paragraphTapped":
            if let i = msg.payload["paragraphIndex"] as? Int { readVM?.jump(to: i) }
        case "log":
            NSLog("CRDBG JS %@", "\(msg.payload["message"] ?? "")")
        case "error":
            print("[WebReader] ⚠️ JS error: \(msg.payload)")
        default:
            print("[WebReader] JS event: \(msg.type)")
        }
    }

    /// 正文提取完成 → 重建 paragraphs 喂 TTS + CR.init 段落 + 自动朗读。
    private func onRendered(_ paras: [WebRenderedParagraph]) {
        guard let readVM, !paras.isEmpty else { return }
        let rps = paras.map { ReadingParagraph(id: $0.paragraphIndex, text: $0.text, type: .paragraph) }
        // 从提取的正文检测语言（中文网页→zh 音色），统一系统化判定，避免中文用英文音色。
        let detected = LanguageDetector.detect(rps.prefix(30).map { $0.text }.joined(separator: " "))
        print("[WebReader] 🌐 detected language=\(detected)")
        readVM.loadWebParagraphs(rps, language: detected)
        explainVM?.loadWebParagraphs(rps, language: detected)

        let segs = rps.map { ["paragraphIndex": $0.id, "text": $0.text] as [String: Any] }
        call("init", ["segments": segs, "color": AppSettings.shared.highlightColorHex])
        didInit = true

        // 段落就绪后才自动开播，且按「当前模式」启动对应 VM（剪贴板/网址 autoplay 进解读时启动解读，
        // 避免用空段落请求后端 → 解读 HTTP 400 / 朗读无内容）。从 Mini Player 展开会重建 bridge（didAutoStart 重置），
        // 此时 readVM 已有进度（currentParagraphIndex>=0）→ 不重复开播。
        if AppSettings.shared.autoPlay && !didAutoStart {
            didAutoStart = true
            if isReadMode {
                if readVM.currentParagraphIndex < 0 { readVM.start() }
            } else {
                explainVM?.start()
            }
        }
    }

    // MARK: - native → JS

    private func pushHighlight(_ cmd: WebHighlightCmd) {
        guard didInit else { return }
        if cmd.isWord {
            call("highlightWord", ["paragraphIndex": cmd.paragraphIndex, "segSeq": cmd.segSeq,
                                   "words": cmd.words ?? [], "wordIndex": cmd.wordIndex])
        } else {
            call("highlightRange", ["paragraphIndex": cmd.paragraphIndex, "charStart": cmd.charStart, "charEnd": cmd.charEnd])
        }
    }

    /// 解读 marks（已锚定到 DOM 段落字符范围）→ JS showMark 画手写标注；清空→clearMarks。
    private func pushMarks(_ marks: [ResolvedMark]) {
        guard didInit else { return }
        if marks.isEmpty {
            shownMarkIds.removeAll()
            call("clearMarks")
            return
        }
        for m in marks where !shownMarkIds.contains(m.id.uuidString) {
            shownMarkIds.insert(m.id.uuidString)
            var payload: [String: Any] = [
                "id": m.id.uuidString,
                "paragraphIndex": m.paragraphIndex,
                "charStart": m.charRange.lowerBound,
                "charEnd": m.charRange.upperBound,
                "action": m.action,
                "seed": Int(truncatingIfNeeded: m.seed & 0xFFFFFFFF),
            ]
            if let n = m.n { payload["n"] = n }
            call("showMark", payload)
        }
    }

    /// 切朗读/解读模式：启停 DOM 高亮层。
    func setActive(readMode: Bool) {
        isReadMode = readMode
        call("setActive", ["active": readMode])
    }

    func setColor(_ hex: String) { call("setColor", ["hex": hex]) }

    /// 调 window.CR.<fn>(<jsonPayload>)。
    func call(_ fn: String, _ payload: [String: Any] = [:]) {
        guard let webView = webView else { return }
        var arg = ""
        if !payload.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: data, encoding: .utf8) {
            arg = s
        }
        let dbg = payload["audioSegmentIndex"] ?? payload["paragraphIndex"] ?? (payload["audioSegments"] != nil ? "segs=\((payload["audioSegments"] as? [Any])?.count ?? 0)" : "")
        NSLog("CRDBG →JS %@(%@)", fn, "\(dbg)")
        let js = "window.CR && window.CR.\(fn) && window.CR.\(fn)(\(arg))"
        webView.evaluateJavaScript(js) { _, err in
            if let err = err { print("[WebReader] call \(fn) error: \(err)") }
        }
    }
}
