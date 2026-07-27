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

enum WebExtractionReadiness {
    static let minimumParagraphCount = 3
    static let minimumCharacterCount = 200

    static func isWeak(_ paragraphs: [WebRenderedParagraph]) -> Bool {
        let meaningful = paragraphs.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let characterCount = meaningful.reduce(into: 0) { $0 += $1.text.count }
        return meaningful.count < minimumParagraphCount || characterCount < minimumCharacterCount
    }
}

@MainActor
final class WebReaderBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let handlerName = "castreader"

    weak var webView: WKWebView?
    var onWeReadViewport: ((Double, Double) -> Void)?
    var onWeReadSurfaceStable: (() -> Void)?
    var onWeReadNeedsLoadingCover: (() -> Void)?
    var pendingDocxBase64: String?              // 仅 docx：待 JS ready 后交 mammoth 渲染的字节
    var pendingEpubBase64: String?              // 仅 epub：待 JS ready 后交 epub.js 渲染的字节
    private weak var readVM: ReadAloudViewModel?
    private weak var explainVM: ExplainViewModel?
    private weak var weReadTOCController: WeReadTOCController?
    private var cancellables = Set<AnyCancellable>()
    private var didInit = false
    private var didAutoStart = false
    private var isWeReadInitialPlaybackPending = false
    private var weReadInitialPlaybackTask: Task<Void, Never>?
    private var isReadMode = true        // 当前模式；onRendered 自动开播据此决定启动朗读还是解读
    private var shownMarkIds = Set<String>()
    private var lastRefocusToken = 0
    private var expectsDynamicWebContent = false
    private var weakExtractionRetryCount = 0
    private var extractionRetryTask: Task<Void, Never>?
    private var isWeRead = false
    private var lastWeReadFingerprint = ""
    private var lastWeReadEvidence: WeReadPageEvidence?
    private var pendingWeReadTurn = false
    private var automaticAppReviewContinuation = AppReviewAutomaticPageContinuation()
    private var suppressAppReviewContinuationForPendingTurn = false
    private var pendingWeReadManualTurn = false
    private var pendingWeReadTOCJump = false
    private var pendingWeReadTOCEntry: WeReadTOCEntry?
    private var pendingWeReadActionID = ""
    private var weReadTurnTimeout: Task<Void, Never>?
    private var weReadManualIntentTimeout: Task<Void, Never>?
    private var weReadManualCommitTask: Task<Void, Never>?
    private var weReadTOCLoadTimeout: Task<Void, Never>?
    private var weReadNativeTOCTask: Task<Void, Never>?
    private var weReadNativeTOCBookID = ""
    private var resumeReadAfterWeReadTurn = false
    private var resumeExplainAfterWeReadTurn = false
    private var pendingWeReadPreview: WeReadPagePreview?
    private var preparedWeReadPage: WeReadPreparedPage?
    private var weReadPreviewTask: Task<Void, Never>?
    private var preparedWeReadExplanation: WeReadPreparedExplanation?
    private var weReadExplainPrefetchTask: Task<Void, Never>?
    private var continuousWeReadHandoff: WeReadContinuousHandoff?
    private var activeWeReadCarry: WeReadActiveCarry?
    private var pendingWeReadBoundaryTurn: WeReadBoundaryTurn?
    private var continuousWeReadSerial = 0
    private var weReadTurnRequestedAt: Date?
    private var observedWeReadTurnLatencySeconds = 0.53
    private var weReadRefreshTask: Task<Void, Never>?
    private var weReadRefreshSerial = 0
    private var isApplicationActive = true
    private var lastApplicationActivityState: Bool?
    private var shouldReloadWeReadOnForeground = false
    private var weReadForegroundProbeSerial = 0
    private var weReadForegroundProbeAttemptSerial = 0
    private var weReadEntryReadinessTask: Task<Void, Never>?
    private var weReadShelfRecoveryTask: Task<Void, Never>?
    private var weReadRecoveryAttemptedURLs = Set<String>()
    private var didAttemptWeReadShelfRecovery = false

    private enum WeReadEntryRecoveryStage {
        case idle
        case loadingLocalFallback
        case scanningShelf
        case awaitingLogin
        case loadingRecoveredEntry
    }
    private var weReadEntryRecoveryStage = WeReadEntryRecoveryStage.idle
    private var lastWeReadMainFrameStatus: Int?
    private var weReadNetworkRetries = 0

    private struct WeReadRefreshState {
        let serial: Int
        let reason: String
        let sourceFingerprint: String
        let resumeRead: Bool
        let resumeExplain: Bool
        let anchor: WeReadPlaybackResumeAnchor?
        var didStopPlayback: Bool
    }
    private var weReadRefreshState: WeReadRefreshState?

    private var weReadVisualTurnLeadSeconds: Double {
        min(1.0, max(0.45, observedWeReadTurnLatencySeconds + 0.12))
    }

    private struct WeReadPagePreview {
        let sourceFingerprint: String
        let contentFingerprint: String
        let page: [ReadingParagraph]
        let language: String
        let confidence: String
        let preparedParagraphIndex: Int
        let preparedText: String
        let carryParagraphIndex: Int?
        let carryUTF16Length: Int
        let boundary: WeReadPageSpeechBoundary?
    }

    private struct WeReadPreparedPage {
        let preview: WeReadPagePreview
        let voiceID: String
        let segments: [AudioSegment]
    }

    private struct WeReadPreparedExplanation {
        let preview: WeReadPagePreview
        let payload: ExplainViewModel.PrefetchedFirstBlock
        let voiceID: String
        let depth: String
        let requestedLanguage: String
    }

    private struct WeReadContinuousHandoff {
        let serial: Int
        let sourceFingerprint: String
        let predictedContentFingerprint: String
        let voiceID: String
        let page: [ReadingParagraph]
        let language: String
        let segments: [AudioSegment]
        let segmentIDs: Set<String>
        let predecessorSegmentID: String
        let boundaryCue: WeReadBoundaryAudioCue?
        let carryParagraphIndex: Int?
        let carryUTF16Length: Int
    }

    private struct WeReadBoundaryTurn {
        let sourceFingerprint: String
        let cue: WeReadBoundaryAudioCue
    }

    private struct WeReadPageCandidate {
        let priorFingerprint: String
        let fingerprint: String
        let evidence: WeReadPageEvidence
        let page: [ReadingParagraph]
        let language: String
        let readerURL: String?
        let progress: String?
        let geometrySource: String
        let mappedGlyphs: Int
        let isConfirmedTurn: Bool
        let boundary: WeReadPageSpeechBoundary?
        let carryParagraphIndex: Int?
        let carryUTF16Length: Int
    }

    private struct WeReadActiveCarry {
        let segmentID: String
        let boundaryTime: Double
        let paragraphIndex: Int
        let visibleUTF16Length: Int
        var didPaint = false
    }

    func configure(expectsDynamicWebContent: Bool, isWeRead: Bool = false) {
        self.expectsDynamicWebContent = expectsDynamicWebContent
        self.isWeRead = isWeRead
        self.isWeReadInitialPlaybackPending = isWeRead
        if isWeRead {
            // Baseline before WeRead touches the shared website data store.
            KindleSessionProbe.logCookies(reason: "weread-create")
        }
    }

    // MARK: - 关联 VM + 订阅

    func attach(readVM: ReadAloudViewModel, explainVM: ExplainViewModel) {
        guard self.readVM == nil else { return }   // 只关联一次
        self.readVM = readVM
        self.explainVM = explainVM

        if isWeRead {
            readVM.onAppReviewReadSessionInvalidated = { [weak self] in
                guard let self else { return }
                let shouldSuppressPendingTurn =
                    self.pendingWeReadTurn
                        || self.automaticAppReviewContinuation.pendingProgress != nil
                self.automaticAppReviewContinuation.cancel()
                if shouldSuppressPendingTurn {
                    self.suppressAppReviewContinuationForPendingTurn = true
                }
            }
            readVM.onDocumentFinished = { [weak self] appReviewContinuation in
                guard let self else { return }
                guard self.isReadMode else {
                    self.automaticAppReviewContinuation.cancel()
                    return
                }
                if let appReviewContinuation {
                    self.automaticAppReviewContinuation.arm(appReviewContinuation)
                    self.suppressAppReviewContinuationForPendingTurn = false
                }
                self.requestWeReadNextPage()
            }
            readVM.onPageBoundaryApproaching = { [weak self] in
                self?.handleWeReadPageBoundaryApproaching()
            }
            explainVM.onDocumentFinished = { [weak self] in
                guard self?.isReadMode == false else { return }
                self?.requestWeReadNextPage()
            }
            readVM.$status
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.maybeStartWeReadPreviewPrefetch()
                    self?.maybeArmWeReadContinuousHandoff(reason: "read-status")
                }
                .store(in: &cancellables)
            explainVM.$status
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.maybeStartWeReadExplainPrefetch()
                }
                .store(in: &cancellables)
            explainVM.$currentBlockIndex
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.maybeStartWeReadExplainPrefetch()
                }
                .store(in: &cancellables)
            AudioPlayerService.shared.$currentTime
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    if let handoff = self.continuousWeReadHandoff {
                        self.beginWeReadVisualTurnIfAtBoundary(handoff)
                    }
                    self.updateWeReadCarryHighlightIfNeeded()
                }
                .store(in: &cancellables)
        }

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

    func attachWeReadTOC(_ controller: WeReadTOCController, bookID: String) {
        weReadTOCController = controller
        controller.configure(bookID: bookID)
        controller.onLoad = { [weak self] in self?.requestWeReadTOC() }
        controller.onSelect = { [weak self] entry in self?.jumpToWeReadTOCEntry(entry) }
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
            receiveRendered(paras)
        case "wereadPage":
            receiveWeReadPage(msg.payload)
        case "wereadPagePreview":
            receiveWeReadPagePreview(msg.payload)
        case "wereadTOC":
            receiveWeReadTOC(msg.payload)
        case "wereadTOCCatalogRequest":
            requestNativeWeReadTOC(
                bookID: (msg.payload["bookID"] as? String) ?? ""
            )
        case "wereadTOCError":
            weReadTOCLoadTimeout?.cancel()
            weReadTOCLoadTimeout = nil
            weReadTOCController?.failLoading()
        case "wereadTOCJumpRejected":
            failWeReadTOCJump(reason: (msg.payload["reason"] as? String) ?? "javascript-rejected")
        case "wereadTOCJumpTrace":
            ReaderRunLog.write(
                "WEREAD toc jump trace stage=\((msg.payload["stage"] as? String) ?? "unknown") " +
                "index=\(Int(Self.double(msg.payload["chapterIndex"]) ?? -1)) " +
                "uid=\((msg.payload["chapterUID"] as? String) ?? "") " +
                "method=\((msg.payload["method"] as? String) ?? (msg.payload["tag"] as? String) ?? "")"
            )
        case "wereadTOCDiagnostic":
            let stage = (msg.payload["stage"] as? String) ?? "unknown"
            let rows = Int(Self.double(msg.payload["rows"]) ?? 0)
            let hrefUIDs = Int(Self.double(msg.payload["hrefUIDs"]) ?? 0)
            let anchors = Int(Self.double(msg.payload["anchors"]) ?? 0)
            let status = Int(Self.double(msg.payload["status"]) ?? 0)
            let chapters = Int(Self.double(msg.payload["chapters"]) ?? 0)
            let roots = Int(Self.double(msg.payload["roots"]) ?? 0)
            let bookIDCount = Int(Self.double(msg.payload["bookIDCount"]) ?? 0)
            let kinds = (msg.payload["bookIDKinds"] as? [String])?.joined(separator: ",") ?? ""
            let path = (msg.payload["path"] as? String) ?? ""
            let selector = (msg.payload["selector"] as? String) ?? ""
            let responseKeys = ((msg.payload["responseKeys"] as? [String]) ?? []).joined(separator: ",")
            let dataKeys = ((msg.payload["dataKeys"] as? [String]) ?? []).joined(separator: ",")
            let bodyKeys = ((msg.payload["bodyKeys"] as? [String]) ?? []).joined(separator: ",")
            let requestSource = (msg.payload["requestSource"] as? String) ?? ""
            let candidateSource = (msg.payload["candidateSource"] as? String) ?? ""
            let code = (msg.payload["code"] as? String) ??
                Self.double(msg.payload["code"]).map { String(format: "%.0f", $0) } ?? ""
            let message = (msg.payload["message"] as? String) ?? ""
            let bytes = Int(Self.double(msg.payload["bytes"]) ?? 0)
            let updatedCount = Int(Self.double(msg.payload["updatedCount"]) ?? 0)
            let hasUID = (msg.payload["hasChapterUID"] as? Bool) == true ? "Y" : "N"
            let hasIndex = (msg.payload["hasChapterIndex"] as? Bool) == true ? "Y" : "N"
            let hasUpdated = (msg.payload["hasUpdated"] as? Bool) == true ? "Y" : "N"
            let framework = ((msg.payload["appFrameworkKeys"] as? [String]) ??
                (msg.payload["rowFrameworkKeys"] as? [String]) ?? []).joined(separator: ",")
            ReaderRunLog.write(
                "WEREAD toc diagnostic stage=\(stage) rows=\(rows) hrefUIDs=\(hrefUIDs) anchors=\(anchors) " +
                "status=\(status) chapters=\(chapters) roots=\(roots) ids=\(bookIDCount)[\(kinds)] " +
                "path=\(path) selector=\(selector) framework=\(framework) code=\(code) bytes=\(bytes) " +
                "flags=\(hasUID)/\(hasIndex)/\(hasUpdated) keys=\(responseKeys) dataKeys=\(dataKeys) " +
                "bodyKeys=\(bodyKeys) updated=\(updatedCount) request=\(requestSource) candidate=\(candidateSource) " +
                "message=\(message)"
            )
        case "wereadPreviewState":
            let source = (msg.payload["sourceFingerprint"] as? String) ?? ""
            let reason = (msg.payload["reason"] as? String) ?? "unknown"
            let geometry = (msg.payload["geometrySource"] as? String) ?? "unknown"
            let layouts = Int(Self.double(msg.payload["layouts"]) ?? 0)
            let layoutParagraphs = Int(Self.double(msg.payload["layoutParagraphs"]) ?? 0)
            let layoutCharacters = Int(Self.double(msg.payload["layoutCharacters"]) ?? 0)
            let pageCharacters = Int(Self.double(msg.payload["pageCharacters"]) ?? 0)
            ReaderRunLog.write(
                "WEREAD preload unavailable source=\(String(source.prefix(12))) reason=\(reason) geometry=\(geometry) layouts=\(layouts) layout=\(layoutParagraphs)p/\(layoutCharacters)c page=\(pageCharacters)c"
            )
        case "wereadViewport":
            if let left = Self.double(msg.payload["contentLeftRatio"]),
               let right = Self.double(msg.payload["contentRightRatio"]) {
                onWeReadViewport?(left, right)
            }
        case "wereadExtractionState":
            let layouts = Int(Self.double(msg.payload["layouts"]) ?? 0)
            let calls = Int(Self.double(msg.payload["fillTextCalls"]) ?? 0)
            let draws = Int(Self.double(msg.payload["draws"]) ?? 0)
            let width = Int(Self.double(msg.payload["innerWidth"]) ?? 0)
            let height = Int(Self.double(msg.payload["innerHeight"]) ?? 0)
            ReaderRunLog.write(
                "WEREAD extraction pending layouts=\(layouts) fillText=\(calls) draws=\(draws) css=\(width)x\(height)"
            )
        case "wereadLayoutStable":
            finishWeReadLayoutIfStable(msg.payload)
        case "wereadPageChanging":
            prepareForWeReadPageChange(msg.payload)
        case "wereadTurnRequested":
            pendingWeReadActionID = (msg.payload["actionID"] as? String) ?? pendingWeReadActionID
            NSLog("CRDBG WeRead semantic turn requested %@", "\(msg.payload)")
        case "wereadTurnRejected":
            automaticAppReviewContinuation.cancel()
            suppressAppReviewContinuationForPendingTurn = false
            pendingWeReadTurn = false
            pendingWeReadManualTurn = false
            pendingWeReadActionID = ""
            pendingWeReadBoundaryTurn = nil
            weReadTurnRequestedAt = nil
            weReadTurnTimeout?.cancel()
            weReadManualIntentTimeout?.cancel()
            weReadManualIntentTimeout = nil
            cancelWeReadContinuousHandoff(reason: "semantic-turn-rejected")
            if !isReadMode {
                explainVM?.finishLivePageContinuation()
            }
            NSLog("CRDBG WeRead semantic turn rejected %@", "\(msg.payload)")
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

    /// Dynamic news pages can finish navigation before Nuxt/React reveals the server-rendered
    /// article body. Do not commit the first title/skeleton-only extraction: retry the same
    /// shared Visual Zone extractor while the DOM settles, matching Android's contract.
    private func receiveRendered(_ paras: [WebRenderedParagraph]) {
        if isWeRead { return }
        guard !didInit else {
            print("[WebReader] ignoring rendered payload after content commit")
            return
        }
        if expectsDynamicWebContent,
           WebExtractionReadiness.isWeak(paras),
           weakExtractionRetryCount < 2 {
            let retry = weakExtractionRetryCount
            weakExtractionRetryCount += 1
            extractionRetryTask?.cancel()
            let delay: UInt64 = retry == 0 ? 1_100_000_000 : 1_800_000_000
            let characterCount = paras.reduce(into: 0) { $0 += $1.text.count }
            NSLog(
                "CRDBG weak web extraction %dp/%dc retry=%d",
                paras.count,
                characterCount,
                weakExtractionRetryCount
            )
            extractionRetryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self?.call("extract")
            }
            return
        }
        extractionRetryTask?.cancel()
        extractionRetryTask = nil
        onRendered(paras)
    }

    private func receiveWeReadTOC(_ payload: [String: Any]) {
        let raw = payload["entries"] as? [[String: Any]] ?? []
        let entries = raw.enumerated().compactMap { offset, value -> WeReadTOCEntry? in
            let title = ((value["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return WeReadTOCEntry(
                index: Int(Self.double(value["index"]) ?? Double(offset)),
                chapterIndex: Int(Self.double(value["chapterIndex"]) ?? Double(offset)),
                chapterUID: (value["chapterUID"] as? String) ?? "",
                title: title,
                level: Int(Self.double(value["level"]) ?? 0)
            )
        }
        let currentUID = payload["currentChapterUID"] as? String
        let currentIndex = Self.double(payload["currentChapterIndex"]).map(Int.init)
        weReadTOCLoadTimeout?.cancel()
        weReadTOCLoadTimeout = nil
        weReadTOCController?.receive(
            entries,
            currentChapterUID: currentUID,
            currentChapterIndex: currentIndex
        )
        ReaderRunLog.write(
            "WEREAD toc loaded count=\(entries.count) uids=\(entries.filter { !$0.chapterUID.isEmpty }.count) " +
            "source=\((payload["source"] as? String) ?? "unknown")"
        )
    }

    private func requestWeReadTOC() {
        guard isWeRead, let webView else {
            weReadTOCController?.failLoading()
            return
        }
        weReadTOCLoadTimeout?.cancel()
        weReadTOCLoadTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.weReadTOCLoadTimeout = nil
            self.weReadTOCController?.failLoading()
            ReaderRunLog.write("WEREAD toc load timeout")
        }
        webView.evaluateJavaScript(
            "(()=>{ window.CastReaderWeReadTOC?.load?.(); return true; })()"
        ) { [weak self] _, error in
            guard let self, let error else { return }
            self.weReadTOCLoadTimeout?.cancel()
            self.weReadTOCLoadTimeout = nil
            self.weReadTOCController?.failLoading()
            ReaderRunLog.write("WEREAD toc load bridge-error=\(error.localizedDescription)")
        }
    }

    private func requestNativeWeReadTOC(bookID: String) {
        let cleanBookID = bookID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWeRead,
              !cleanBookID.isEmpty,
              cleanBookID.allSatisfy(\.isNumber),
              let webView else {
            weReadTOCController?.failLoading()
            return
        }
        if weReadNativeTOCTask != nil, weReadNativeTOCBookID == cleanBookID {
            return
        }
        weReadNativeTOCTask?.cancel()
        weReadNativeTOCBookID = cleanBookID
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let userAgent = webView.customUserAgent ?? WeReadWebScripts.desktopUserAgent
        let referer = webView.url?.absoluteString ?? "https://weread.qq.com/"

        weReadNativeTOCTask = Task { @MainActor [weak self, weak webView] in
            defer {
                self?.weReadNativeTOCTask = nil
                self?.weReadNativeTOCBookID = ""
            }
            let cookies = await withCheckedContinuation { continuation in
                cookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }
            let sessionCookies = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                return domain == "weread.qq.com" ||
                    domain.hasSuffix(".weread.qq.com") ||
                    domain == "qq.com" ||
                    domain.hasSuffix(".qq.com")
            }
            guard let url = URL(string: "https://i.weread.qq.com/book/chapterInfos") else {
                self?.weReadTOCController?.failLoading()
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: [
                    "bookIds": [cleanBookID],
                    "synckeys": [0],
                    "teenmode": 0
                ]
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://weread.qq.com", forHTTPHeaderField: "Origin")
            request.setValue(referer, forHTTPHeaderField: "Referer")
            let cookieValues = Dictionary(
                sessionCookies.map { ($0.name.lowercased(), $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            // Current wrweb-next routes every authenticated API call through
            // its g4 wrapper, which promotes the login cookies to request
            // headers. Cookies alone now receive 401 from i.weread.qq.com.
            request.setValue(
                cookieValues["wr_vid"] ?? cookieValues["wr_localvid"] ?? "",
                forHTTPHeaderField: "x-vid"
            )
            request.setValue(
                cookieValues["wr_skey"] ?? "",
                forHTTPHeaderField: "x-skey"
            )
            request.setValue(
                UUID().uuidString.lowercased(),
                forHTTPHeaderField: "X-SSR-Request-Id"
            )
            if let cookieHeader = HTTPCookie.requestHeaderFields(
                with: sessionCookies
            )["Cookie"] {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let object = try JSONSerialization.jsonObject(with: data)
                let root = object as? [String: Any]
                let first = (root?["data"] as? [[String: Any]])?.first
                let updatedCount = (first?["updated"] as? [Any])?.count ?? 0
                ReaderRunLog.write(
                    "WEREAD toc native response status=\(status) bytes=\(data.count) " +
                    "cookies=\(sessionCookies.map(\.name).sorted().joined(separator: ",")) " +
                    "updated=\(updatedCount)"
                )
                guard (200..<300).contains(status), updatedCount > 0,
                      let serialized = String(data: data, encoding: .utf8),
                      let webView else {
                    self?.weReadTOCController?.failLoading()
                    return
                }
                let quotedData = try JSONEncoder().encode(serialized)
                guard let quoted = String(data: quotedData, encoding: .utf8) else {
                    self?.weReadTOCController?.failLoading()
                    return
                }
                webView.evaluateJavaScript(
                    "window.CastReaderWeReadTOC?.installNativeCatalog?.(\(quoted))"
                ) { [weak self] result, error in
                    if let error {
                        self?.weReadTOCController?.failLoading()
                        ReaderRunLog.write(
                            "WEREAD toc native install error=\(error.localizedDescription)"
                        )
                    } else {
                        ReaderRunLog.write(
                            "WEREAD toc native install accepted=\((result as? Bool) == true ? "Y" : "N")"
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.weReadTOCController?.failLoading()
                ReaderRunLog.write(
                    "WEREAD toc native request error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func jumpToWeReadTOCEntry(_ entry: WeReadTOCEntry) {
        guard isWeRead, didInit, let webView else {
            weReadTOCController?.failJump()
            return
        }
        guard entry.isActionable else {
            weReadTOCController?.failJump(
                AppLocalized("正在同步微信读书目录，请稍后重试。")
            )
            ReaderRunLog.write(
                "WEREAD toc jump rejected reason=missing-authoritative-uid index=\(entry.chapterIndex)"
            )
            return
        }
        guard !pendingWeReadTOCJump else { return }

        let wasReading = isReadMode && readVM?.isPlaying == true
        let wasExplaining = !isReadMode &&
            (explainVM?.isPlaying == true || explainVM?.status.isActive == true)

        weReadManualCommitTask?.cancel()
        weReadManualCommitTask = nil
        automaticAppReviewContinuation.cancel()
        suppressAppReviewContinuationForPendingTurn = true
        weReadManualIntentTimeout?.cancel()
        weReadManualIntentTimeout = nil
        pendingWeReadTurn = false
        pendingWeReadManualTurn = true
        pendingWeReadTOCJump = true
        pendingWeReadTOCEntry = entry
        pendingWeReadActionID = "toc-jump:\(entry.chapterUID.isEmpty ? String(entry.chapterIndex) : entry.chapterUID)"
        resumeReadAfterWeReadTurn = wasReading
        resumeExplainAfterWeReadTurn = wasExplaining
        pendingWeReadBoundaryTurn = nil
        activeWeReadCarry = nil
        cancelWeReadContinuousHandoff(reason: "toc-jump")
        invalidateWeReadPreview(reason: "toc-jump")
        invalidateWeReadExplainPrefetch(reason: "toc-jump")
        if wasReading { readVM?.stop() }
        if wasExplaining { explainVM?.stop() }
        call("clearHighlight")
        call("clearMarks")

        let payload: [String: Any] = [
            "index": entry.index,
            "chapterIndex": entry.chapterIndex,
            "chapterUID": entry.chapterUID,
            "title": entry.title,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let argument = String(data: data, encoding: .utf8) else {
            failWeReadTOCJump(reason: "payload-encoding")
            return
        }
        let script = "window.CastReaderWeReadTOC && window.CastReaderWeReadTOC.jump && window.CastReaderWeReadTOC.jump(\(argument))"
        ReaderRunLog.write(
            "WEREAD toc jump requested index=\(entry.chapterIndex) uid=\(entry.chapterUID) read=\(wasReading ? "Y" : "N") explain=\(wasExplaining ? "Y" : "N")"
        )
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            if error != nil || (value as? Bool) != true {
                self.failWeReadTOCJump(reason: error?.localizedDescription ?? "javascript-returned-false")
                return
            }
            self.weReadTurnTimeout?.cancel()
            self.weReadTurnTimeout = Task { @MainActor [weak self] in
                // Chapter selection is one full reader-route navigation. The
                // transaction completes only after the newly visible Canvas
                // publishes a different stable page fingerprint.
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self, !Task.isCancelled, self.pendingWeReadTOCJump else { return }
                self.failWeReadTOCJump(reason: "confirmation-timeout")
            }
        }
    }

    private func failWeReadTOCJump(reason: String) {
        guard pendingWeReadTOCJump || weReadTOCController?.isJumping == true else { return }
        let shouldResumeRead = resumeReadAfterWeReadTurn
        let shouldResumeExplain = resumeExplainAfterWeReadTurn
        pendingWeReadTOCJump = false
        pendingWeReadTOCEntry = nil
        pendingWeReadManualTurn = false
        suppressAppReviewContinuationForPendingTurn = false
        pendingWeReadActionID = ""
        resumeReadAfterWeReadTurn = false
        resumeExplainAfterWeReadTurn = false
        weReadTurnTimeout?.cancel()
        weReadTurnTimeout = nil
        weReadManualIntentTimeout?.cancel()
        weReadManualIntentTimeout = nil
        weReadTOCController?.failJump()
        if shouldResumeRead, isReadMode { readVM?.start() }
        if shouldResumeExplain, !isReadMode { explainVM?.start() }
        ReaderRunLog.write("WEREAD toc jump failed reason=\(reason)")
    }

    /// Commit a canvas page only when the visible-surface fingerprint changed.
    /// This is the iOS counterpart of the extension's page fingerprint gate:
    /// no "tap + keyboard + retry" fallbacks are allowed, so one completion
    /// can never advance two pages.
    private func receiveWeReadPage(_ payload: [String: Any]) {
        let raw = payload["paragraphs"] as? [[String: Any]] ?? []
        let rawTexts = raw.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawTexts.isEmpty else { return }
        let fingerprint = (payload["fingerprint"] as? String) ?? ""
        let isRefresh = weReadRefreshState != nil
        guard !fingerprint.isEmpty,
              fingerprint != lastWeReadFingerprint || isRefresh else { return }
        finishWeReadEntryRecoveryIfNeeded()
        let prior = lastWeReadFingerprint
        if !prior.isEmpty,
           !WeReadExplainPageEventContract.shouldHandleVisualChange(
               isReadMode: isReadMode,
               reason: (payload["reason"] as? String) ?? "canvas",
               hasPendingSemanticTurn: pendingWeReadTurn,
               hasPendingManualTurn: pendingWeReadManualTurn,
               refreshActive: isRefresh
           ) {
            ReaderRunLog.write(
                "WEREAD explain visual-reflow ignored prior=\(String(prior.prefix(12))) next=\(String(fingerprint.prefix(12)))"
            )
            return
        }
        let evidence = WeReadPageEvidence(
            contentFingerprint: (payload["contentFingerprint"] as? String) ?? fingerprint,
            layoutFingerprint: (payload["layoutFingerprint"] as? String) ?? "",
            columnFingerprint: (payload["columnFingerprint"] as? String) ?? "",
            canvasEpoch: Int(Self.double(payload["canvasEpoch"]) ?? 0)
        )
        let actionID: String
        if pendingWeReadTOCJump {
            actionID = pendingWeReadActionID.isEmpty ? "toc-jump" : pendingWeReadActionID
        } else if pendingWeReadTurn {
            actionID = pendingWeReadActionID.isEmpty ? "semantic-next" : pendingWeReadActionID
        } else if pendingWeReadManualTurn {
            actionID = "manual-pointer-turn"
        } else {
            actionID = "manual-page-change"
        }
        let isConfirmedTurn = !prior.isEmpty && WeReadPageTurnContract.canCommit(
            previous: lastWeReadEvidence,
            next: evidence,
            actionID: actionID
        )
        if !prior.isEmpty, !isConfirmedTurn {
            ReaderRunLog.write(
                "WEREAD page reject reason=no-visible-evidence prior=\(String(prior.prefix(12))) next=\(String(fingerprint.prefix(12))) action=\(actionID)"
            )
            return
        }
        let consumedCursor = pendingWeReadTurn && pendingWeReadBoundaryTurn?.sourceFingerprint == prior
            ? pendingWeReadBoundaryTurn?.cue.consumedCursor
            : nil
        let slices = raw.enumerated().map { index, value in
            WeReadSourceTextSlice(
                visibleParagraphIndex: index,
                sourceParagraphIndex: Self.double(value["sourceParagraphIndex"]).map { Int($0) },
                sourceUTF16Start: Self.double(value["sourceCharStart"]).map { Int($0) },
                sourceUTF16End: Self.double(value["sourceCharEnd"]).map { Int($0) },
                text: ((value["text"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let consumption = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: slices,
            through: consumedCursor
        )
        let page = consumption.texts.enumerated().map {
            ReadingParagraph(id: $0.offset, text: $0.element, type: .paragraph)
        }
        let speechTexts = consumption.texts.filter { SpeechTextSanitizer.containsSpeakableContent($0) }
        let boundary = Self.weReadBoundary(from: raw).map { value in
            guard value.paragraphIndex == consumption.carryParagraphIndex,
                  consumption.carryUTF16Length > 0 else { return value }
            return WeReadPageSpeechBoundary(
                paragraphIndex: value.paragraphIndex,
                visibleUTF16Offset: max(0, value.visibleUTF16Offset - consumption.carryUTF16Length),
                speechUTF16Length: max(0, value.speechUTF16Length - consumption.carryUTF16Length),
                sourceParagraphIndex: value.sourceParagraphIndex,
                sourceSpeechEnd: value.sourceSpeechEnd
            )
        }
        let candidate = WeReadPageCandidate(
            priorFingerprint: prior,
            fingerprint: fingerprint,
            evidence: evidence,
            page: page,
            language: LanguageDetector.detect((speechTexts.isEmpty ? rawTexts : speechTexts).prefix(24).joined(separator: " ")),
            readerURL: payload["readerURL"] as? String,
            progress: payload["progressLabel"] as? String,
            geometrySource: payload["geometrySource"] as? String ?? "unknown",
            mappedGlyphs: Int(Self.double(payload["mappedGlyphs"]) ?? 0),
            isConfirmedTurn: isConfirmedTurn,
            boundary: boundary,
            carryParagraphIndex: consumption.carryParagraphIndex,
            carryUTF16Length: consumption.carryUTF16Length
        )

        // Initial content and an evidence-confirmed automatic turn commit as
        // soon as JS has supplied a stable Canvas snapshot.  Manual A→B→C turns
        // mirror the extension: every candidate replaces the previous one and
        // only the final surface is committed after 600 ms.
        if prior.isEmpty || pendingWeReadTurn || pendingWeReadTOCJump || isRefresh {
            weReadManualCommitTask?.cancel()
            weReadManualCommitTask = nil
            commitWeReadPage(candidate)
        } else {
            weReadManualCommitTask?.cancel()
            weReadManualCommitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: WeReadPageTurnContract.manualRestartDelayNanoseconds)
                guard let self, !Task.isCancelled else { return }
                self.weReadManualCommitTask = nil
                self.commitWeReadPage(candidate)
            }
        }
    }

    /// The WebView predicts one visible page ahead from the same transient HTML
    /// layout used to paint the current Canvas.  Native may prepare audio for
    /// that text, but it remains speculative until the next visible surface
    /// confirms the exact content fingerprint.
    private func receiveWeReadPagePreview(_ payload: [String: Any]) {
        let sourceFingerprint = (payload["sourceFingerprint"] as? String) ?? ""
        let contentFingerprint = (payload["contentFingerprint"] as? String) ?? ""
        guard !sourceFingerprint.isEmpty,
              sourceFingerprint == lastWeReadFingerprint,
              !contentFingerprint.isEmpty else { return }
        let raw = payload["paragraphs"] as? [[String: Any]] ?? []
        let texts = raw.compactMap {
            ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { SpeechTextSanitizer.containsSpeakableContent($0) }
        guard !texts.isEmpty else { return }
        let page = texts.enumerated().map {
            ReadingParagraph(id: $0.offset, text: $0.element, type: .paragraph)
        }
        let preparedInput = raw.enumerated().compactMap { index, value -> (Int, String)? in
            let text = ((value["prefetchText"] as? String) ?? (value["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SpeechTextSanitizer.containsSpeakableContent(text) ? (index, text) : nil
        }.first
        guard let preparedInput else { return }
        let carryInput = raw.enumerated().compactMap { index, value -> (Int, Int)? in
            let length = Int(Self.double(value["carryUTF16Length"]) ?? 0)
            return length > 0 ? (index, length) : nil
        }.first
        let preview = WeReadPagePreview(
            sourceFingerprint: sourceFingerprint,
            contentFingerprint: contentFingerprint,
            page: page,
            language: LanguageDetector.detect(texts.prefix(24).joined(separator: " ")),
            confidence: (payload["confidence"] as? String) ?? "unknown",
            preparedParagraphIndex: preparedInput.0,
            preparedText: preparedInput.1,
            carryParagraphIndex: carryInput?.0,
            carryUTF16Length: carryInput?.1 ?? 0,
            boundary: Self.weReadBoundary(from: raw)
        )
        if pendingWeReadPreview?.sourceFingerprint != sourceFingerprint ||
            pendingWeReadPreview?.contentFingerprint != contentFingerprint {
            weReadPreviewTask?.cancel()
            weReadPreviewTask = nil
            preparedWeReadPage = nil
            invalidateWeReadExplainPrefetch(reason: "prediction-changed")
        }
        pendingWeReadPreview = preview
        ReaderRunLog.write(
            "WEREAD preload preview source=\(String(sourceFingerprint.prefix(12))) next=\(String(contentFingerprint.prefix(12))) confidence=\(preview.confidence) paras=\(page.count)"
        )
        maybeStartWeReadPreviewPrefetch()
        maybeStartWeReadExplainPrefetch()
    }

    private func maybeStartWeReadPreviewPrefetch() {
        guard isWeRead,
              isReadMode,
              didInit,
              readVM?.isActive == true,
              continuousWeReadHandoff == nil,
              let preview = pendingWeReadPreview,
              preview.sourceFingerprint == lastWeReadFingerprint else { return }
        let voiceID = AppSettings.shared.voice(for: preview.language)
        if let prepared = preparedWeReadPage {
            if prepared.preview.sourceFingerprint == preview.sourceFingerprint,
               prepared.preview.contentFingerprint == preview.contentFingerprint,
               prepared.voiceID == voiceID {
                maybeArmWeReadContinuousHandoff(reason: "preload-cache")
                return
            }
            preparedWeReadPage = nil
        }
        guard weReadPreviewTask == nil else { return }
        let token = "\(preview.sourceFingerprint)|\(preview.contentFingerprint)|\(voiceID)"
        weReadPreviewTask = Task { [weak self] in
            do {
                let segments = try await TTSService.shared.generatePrefetchSegments(
                    paragraphIndex: preview.preparedParagraphIndex,
                    text: preview.preparedText,
                    voice: voiceID,
                    speed: 1.0,
                    language: preview.language
                )
                try Task.checkCancellation()
                guard let self else { return }
                self.weReadPreviewTask = nil
                let currentVoice = AppSettings.shared.voice(for: preview.language)
                let currentToken = self.pendingWeReadPreview.map {
                    "\($0.sourceFingerprint)|\($0.contentFingerprint)|\(currentVoice)"
                }
                guard token == currentToken,
                      preview.sourceFingerprint == self.lastWeReadFingerprint,
                      !segments.isEmpty else { return }
                self.preparedWeReadPage = WeReadPreparedPage(
                    preview: preview,
                    voiceID: voiceID,
                    segments: segments
                )
                ReaderRunLog.write(
                    "WEREAD preload audio ready source=\(String(preview.sourceFingerprint.prefix(12))) next=\(String(preview.contentFingerprint.prefix(12))) voice=\(voiceID) segs=\(segments.count)"
                )
                self.maybeArmWeReadContinuousHandoff(reason: "preload-ready")
            } catch is CancellationError {
                self?.weReadPreviewTask = nil
            } catch {
                self?.weReadPreviewTask = nil
                ReaderRunLog.write("WEREAD preload audio failed error=\(error.localizedDescription)")
            }
        }
    }

    /// QuickRead owns a page-only document on WeRead. While that page is still
    /// speaking, use the immutable next-column preview to prepare the next
    /// page's plan, first narration block, audio, and mark timeline. The result
    /// remains speculative until the real Canvas fingerprint is committed.
    private func maybeStartWeReadExplainPrefetch() {
        guard isWeRead,
              !isReadMode,
              didInit,
              let vm = explainVM,
              vm.isActive,
              vm.status.isActive,
              vm.currentBlockIndex >= 0,
              let preview = pendingWeReadPreview,
              preview.sourceFingerprint == lastWeReadFingerprint else { return }

        let settings = AppSettings.shared
        let depth = settings.explainDepth
        let requestedLanguage = settings.explainLanguage
        if let prepared = preparedWeReadExplanation {
            let selectedVoice = settings.voice(for: prepared.payload.outputLanguage)
            if prepared.preview.sourceFingerprint == preview.sourceFingerprint,
               prepared.preview.contentFingerprint == preview.contentFingerprint,
               prepared.voiceID == selectedVoice,
               prepared.depth == depth,
               prepared.requestedLanguage == requestedLanguage {
                return
            }
            invalidateWeReadExplainPrefetch(reason: "settings-or-preview-changed")
        }
        guard ProManager.shared.isPro, weReadExplainPrefetchTask == nil else { return }

        let token = [
            preview.sourceFingerprint,
            preview.contentFingerprint,
            requestedLanguage,
            depth,
        ].joined(separator: "|")
        let target = ReadingDocument(
            id: vm.document.id,
            title: vm.document.title,
            sourceKind: .web,
            language: preview.language,
            paragraphs: preview.page,
            sourceURL: vm.document.sourceURL
        )
        let previousSummary = vm.currentContinuitySummary()
        ReaderRunLog.write(
            "WEREAD explain preload start source=\(String(preview.sourceFingerprint.prefix(12))) next=\(String(preview.contentFingerprint.prefix(12))) paras=\(preview.page.count)"
        )
        weReadExplainPrefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await vm.prefetchFirstBlock(
                    for: target,
                    previousSummary: previousSummary,
                    textFingerprint: preview.contentFingerprint
                )
                try Task.checkCancellation()
                let currentSettings = AppSettings.shared
                let currentToken = [
                    self.pendingWeReadPreview?.sourceFingerprint ?? "",
                    self.pendingWeReadPreview?.contentFingerprint ?? "",
                    currentSettings.explainLanguage,
                    currentSettings.explainDepth,
                ].joined(separator: "|")
                guard token == currentToken,
                      preview.sourceFingerprint == self.lastWeReadFingerprint else {
                    self.weReadExplainPrefetchTask = nil
                    return
                }
                let voiceID = currentSettings.voice(for: payload.outputLanguage)
                self.preparedWeReadExplanation = WeReadPreparedExplanation(
                    preview: preview,
                    payload: payload,
                    voiceID: voiceID,
                    depth: depth,
                    requestedLanguage: requestedLanguage
                )
                self.weReadExplainPrefetchTask = nil
                ReaderRunLog.write(
                    "WEREAD explain preload ready source=\(String(preview.sourceFingerprint.prefix(12))) next=\(String(preview.contentFingerprint.prefix(12))) blocks=\(payload.totalBlocks)"
                )
            } catch is CancellationError {
                self.weReadExplainPrefetchTask = nil
            } catch {
                self.weReadExplainPrefetchTask = nil
                ReaderRunLog.write("WEREAD explain preload miss error=\(error.localizedDescription)")
            }
        }
    }

    private func consumeWeReadExplainPrefetch(
        for candidate: WeReadPageCandidate
    ) -> ExplainViewModel.PrefetchedFirstBlock? {
        guard let prepared = preparedWeReadExplanation else {
            invalidateWeReadExplainPrefetch(reason: "page-commit-miss")
            return nil
        }
        defer { invalidateWeReadExplainPrefetch(reason: "page-commit-consumed") }
        let selectedVoice = AppSettings.shared.voice(for: prepared.payload.outputLanguage)
        let textMatch = WeReadSpeculativeTextContract.evaluate(
            predicted: prepared.preview.page.map(\.text),
            visible: candidate.page.map(\.text)
        )
        let canConsume = WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: prepared.preview.sourceFingerprint,
            previousFingerprint: candidate.priorFingerprint,
            predictedContentFingerprint: prepared.preview.contentFingerprint,
            visibleContentFingerprint: candidate.evidence.contentFingerprint,
            predictedText: prepared.preview.page.map(\.text),
            visibleText: candidate.page.map(\.text),
            payloadTextFingerprint: prepared.payload.textFingerprint,
            preparedVoiceID: prepared.voiceID,
            selectedVoiceID: selectedVoice,
            preparedDepth: prepared.depth,
            selectedDepth: AppSettings.shared.explainDepth
        ) && prepared.requestedLanguage == AppSettings.shared.explainLanguage
        ReaderRunLog.write(
            "WEREAD explain preload consume next=\(String(candidate.fingerprint.prefix(12))) hit=\(canConsume ? "Y" : "N") match=\(textMatch.matchedCharacters)c predicted=\(String(format: "%.2f", textMatch.predictedCoverage)) visible=\(String(format: "%.2f", textMatch.visibleCoverage))"
        )
        return canConsume ? prepared.payload : nil
    }

    /// Append the prepared first utterance behind the current page's final
    /// segment.  The player gate prevents it from becoming audible before the
    /// semantic next-page action has produced a matching visible Canvas page.
    private func maybeArmWeReadContinuousHandoff(reason: String) {
        guard continuousWeReadHandoff == nil,
              isReadMode,
              !pendingWeReadTurn,
              let vm = readVM,
              vm.canContinueAcrossLivePageBoundary,
              let prepared = preparedWeReadPage else { return }
        let selectedVoice = AppSettings.shared.voice(for: prepared.preview.language)
        vm.weReadBoundaryTurnLeadSeconds = weReadVisualTurnLeadSeconds
        guard prepared.voiceID == selectedVoice else {
            preparedWeReadPage = nil
            maybeStartWeReadPreviewPrefetch()
            return
        }
        let audio = AudioPlayerService.shared
        guard WeReadContinuousPageHandoffContract.shouldArm(
            sourceFingerprint: prepared.preview.sourceFingerprint,
            currentFingerprint: lastWeReadFingerprint,
            hasPreparedAudio: !prepared.segments.isEmpty,
            isLastReadableParagraph: vm.isOnLastReadableParagraph,
            currentTTSComplete: vm.currentTTSCompleteForPageHandoff,
            audioIsPlaying: audio.isPlaying
        ), let predecessor = audio.queuedTailSegmentID else { return }

        continuousWeReadSerial += 1
        let serial = continuousWeReadSerial
        let rebased = prepared.segments.enumerated().map { offset, segment in
            AudioSegment(
                paragraphIndex: segment.paragraphIndex,
                segmentIndex: 800_000_000 + (serial % 100_000) * 1_000 + offset,
                audioData: segment.audioData,
                timestamps: segment.timestamps,
                duration: segment.duration,
                text: segment.text,
                isWavFormat: segment.isWavFormat,
                unprocessedText: segment.unprocessedText,
                speaker: segment.speaker
            )
        }
        let handoff = WeReadContinuousHandoff(
            serial: serial,
            sourceFingerprint: prepared.preview.sourceFingerprint,
            predictedContentFingerprint: prepared.preview.contentFingerprint,
            voiceID: prepared.voiceID,
            page: prepared.preview.page,
            language: prepared.preview.language,
            segments: rebased,
            segmentIDs: Set(rebased.map(\.id)),
            predecessorSegmentID: predecessor,
            boundaryCue: vm.currentWeReadBoundaryCue,
            carryParagraphIndex: prepared.preview.carryParagraphIndex,
            carryUTF16Length: prepared.preview.carryUTF16Length
        )
        continuousWeReadHandoff = handoff
        audio.canStartQueuedSegment = { [weak self] segment in
            guard let self,
                  let active = self.continuousWeReadHandoff,
                  active.serial == serial,
                  active.segmentIDs.contains(segment.id) else { return true }
            self.requestWeReadNextPage()
            return false
        }
        let appendedAfter = audio.appendPreparedSegmentsForContinuousPlayback(rebased)
        guard appendedAfter == predecessor else {
            cancelWeReadContinuousHandoff(reason: "queue-boundary-changed")
            return
        }
        ReaderRunLog.write(
            "WEREAD continuous armed reason=\(reason) serial=\(serial) source=\(String(handoff.sourceFingerprint.prefix(12))) next=\(String(handoff.predictedContentFingerprint.prefix(12))) predecessor=\(predecessor) segs=\(rebased.count)"
        )
        beginWeReadVisualTurnIfAtBoundary(handoff)
    }

    private func handleWeReadPageBoundaryApproaching() {
        if let cue = readVM?.currentWeReadBoundaryCue {
            pendingWeReadBoundaryTurn = WeReadBoundaryTurn(
                sourceFingerprint: lastWeReadFingerprint,
                cue: cue
            )
        } else {
            pendingWeReadBoundaryTurn = nil
        }
        maybeArmWeReadContinuousHandoff(reason: "audio-tail")
        if let handoff = continuousWeReadHandoff {
            beginWeReadVisualTurnIfAtBoundary(handoff)
        } else {
            // Visual correctness cannot depend on speculative TTS. Even when
            // no preview audio exists, turn at the consumed source boundary;
            // the immutable cross-page sentence remains the carry item.
            requestWeReadNextPage()
        }
    }

    private func beginWeReadVisualTurnIfAtBoundary(_ handoff: WeReadContinuousHandoff) {
        let audio = AudioPlayerService.shared
        if let cue = handoff.boundaryCue {
            guard WeReadCrossPageSpeechContract.shouldRequestTurn(
                currentSegmentID: audio.currentSegment?.id,
                cue: cue,
                currentTime: audio.currentTime,
                playbackRate: audio.playbackRate,
                leadSeconds: weReadVisualTurnLeadSeconds
            ) else { return }
            requestWeReadNextPage()
            return
        }
        let remaining = max(0, audio.duration - audio.currentTime)
        guard WeReadContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: audio.currentSegment?.id,
            predecessorSegmentID: handoff.predecessorSegmentID,
            remainingAudioSeconds: remaining,
            playbackRate: audio.playbackRate,
            leadSeconds: weReadVisualTurnLeadSeconds
        ) else { return }
        requestWeReadNextPage()
    }

    private func commitWeReadPage(_ candidate: WeReadPageCandidate) {
        let refresh = weReadRefreshState
        let committedTOCEntry = pendingWeReadTOCEntry
        guard candidate.priorFingerprint == lastWeReadFingerprint,
              candidate.fingerprint != lastWeReadFingerprint || refresh != nil else { return }

        let liveWasReading = readVM?.isActive == true || readVM?.isPlaying == true
        let liveWasExplaining = !isReadMode &&
            (explainVM?.status.isActive == true || explainVM?.isPlaying == true)
        let wasReading = refresh?.resumeRead == true || resumeReadAfterWeReadTurn || liveWasReading || pendingWeReadTurn
        // Capture the semantic auto-turn before clearing pendingWeReadTurn.
        // The old page has normally reached `.completed` by now, so neither
        // status.isActive nor isPlaying can carry the continuation intent.
        let wasExplaining = !isReadMode && WeReadExplainPageEventContract.shouldResumeExplanation(
            isAutomaticTurn: pendingWeReadTurn,
            resumeAlreadyArmed: refresh?.resumeExplain == true || resumeExplainAfterWeReadTurn,
            wasLiveExplaining: liveWasExplaining
        )
        let selectedVoice = AppSettings.shared.voice(for: candidate.language)
        let continuous = continuousWeReadHandoff
        let boundaryTurn = pendingWeReadBoundaryTurn
        let canCommitContinuously = continuous.map {
            candidate.isConfirmedTurn &&
                WeReadContinuousPageHandoffContract.canReleasePreparedAudio(
                    sourceFingerprint: $0.sourceFingerprint,
                    previousFingerprint: candidate.priorFingerprint,
                    predictedContentFingerprint: $0.predictedContentFingerprint,
                    visibleContentFingerprint: candidate.evidence.contentFingerprint,
                    predictedText: $0.page.map(\.text),
                    visibleText: candidate.page.map(\.text),
                    preparedVoiceID: $0.voiceID,
                    selectedVoiceID: selectedVoice
                )
        } ?? false
        let canCommitBoundaryCarry = candidate.isConfirmedTurn && boundaryTurn.map {
            $0.sourceFingerprint == candidate.priorFingerprint &&
                AudioPlayerService.shared.currentSegment?.id == $0.cue.segmentID
        } == true
        let isConfirmedAutomaticReadCommit =
            isReadMode
                && pendingWeReadTurn
                && candidate.isConfirmedTurn
                && !suppressAppReviewContinuationForPendingTurn
        let queuedAppReviewReadSession = automaticAppReviewContinuation
            .takeForConfirmedAutomaticCommit(isConfirmedAutomaticReadCommit)
        // When visual confirmation wins the race against natural audio
        // completion there is no queued callback token yet. Snapshot only when
        // this commit will take the fallback stop/restart path.
        let fallbackWillResetActiveProgress =
            !canCommitContinuously && !canCommitBoundaryCarry
        let activeFallbackAppReviewReadSession =
            isConfirmedAutomaticReadCommit && fallbackWillResetActiveProgress
            ? readVM?.snapshotAppReviewReadSessionForActiveAutomaticPageCommit()
            : nil
        let appReviewReadSession = AppReviewAutomaticPageContinuation
            .progressForConfirmedCommit(
                queuedProgress: queuedAppReviewReadSession,
                activeProgress: activeFallbackAppReviewReadSession,
                isConfirmedAutomaticCommit: isConfirmedAutomaticReadCommit,
                fallbackWillResetActiveProgress: fallbackWillResetActiveProgress
            )
        if pendingWeReadTurn, let requestedAt = weReadTurnRequestedAt {
            let measured = max(0.1, min(2.0, Date().timeIntervalSince(requestedAt)))
            observedWeReadTurnLatencySeconds = observedWeReadTurnLatencySeconds * 0.65 + measured * 0.35
            ReaderRunLog.write(
                "WEREAD turn latency measured=\(String(format: "%.3f", measured))s nextLead=\(String(format: "%.3f", weReadVisualTurnLeadSeconds))s"
            )
        }

        // Page evidence is also an authoritative stop boundary when a pointer
        // intent was missed.  No stale queue may survive into the new surface.
        if didInit, candidate.isConfirmedTurn, !canCommitContinuously, !canCommitBoundaryCarry {
            if isReadMode, liveWasReading {
                readVM?.stop()
            } else if !isReadMode, liveWasExplaining {
                explainVM?.stop()
            }
        }

        lastWeReadFingerprint = candidate.fingerprint
        lastWeReadEvidence = candidate.evidence
        pendingWeReadTurn = false
        suppressAppReviewContinuationForPendingTurn = false
        pendingWeReadManualTurn = false
        pendingWeReadTOCJump = false
        pendingWeReadTOCEntry = nil
        pendingWeReadActionID = ""
        pendingWeReadBoundaryTurn = nil
        resumeReadAfterWeReadTurn = false
        resumeExplainAfterWeReadTurn = false
        weReadTurnTimeout?.cancel()
        weReadTurnTimeout = nil
        weReadManualIntentTimeout?.cancel()
        weReadManualIntentTimeout = nil
        weReadTurnRequestedAt = nil
        if let committedTOCEntry {
            weReadTOCController?.finishJump(to: committedTOCEntry)
            ReaderRunLog.write(
                "WEREAD toc jump confirmed index=\(committedTOCEntry.chapterIndex) uid=\(committedTOCEntry.chapterUID)"
            )
        }
        WeReadLibraryStore.shared.updateProgress(
            bookID: readVM?.document.id ?? "",
            readerURL: candidate.readerURL ?? "",
            fingerprint: candidate.fingerprint,
            progressLabel: candidate.progress
        )
        ReaderRunLog.write("WEREAD page commit prior=\(String(candidate.priorFingerprint.prefix(12))) next=\(String(candidate.fingerprint.prefix(12))) confirmed=\(candidate.isConfirmedTurn) epoch=\(candidate.evidence.canvasEpoch) cols=\(String(candidate.evidence.columnFingerprint.prefix(32))) geometry=\(candidate.geometrySource) glyphs=\(candidate.mappedGlyphs) paras=\(candidate.page.count)")

        if didInit {
            if isReadMode {
                if let appReviewReadSession,
                   readVM?.inheritAppReviewReadSession(appReviewReadSession) != true {
                    ReaderRunLog.write(
                        "WEREAD automatic review session adoption rejected next=\(String(candidate.fingerprint.prefix(12)))"
                    )
                }
                var committedContinuously = false
                var committedHandoff: WeReadContinuousHandoff?
                if canCommitContinuously, let continuous {
                    committedContinuously = readVM?.commitContinuousLiveWebPage(
                        candidate.page,
                        language: candidate.language,
                        preparedSegments: continuous.segments,
                        weReadBoundary: candidate.boundary
                    ) == true
                    if committedContinuously { committedHandoff = continuous }
                }
                if committedContinuously, let continuous = committedHandoff {
                    if let cue = continuous.boundaryCue,
                       let paragraphIndex = candidate.carryParagraphIndex,
                       candidate.carryUTF16Length > 0 {
                        let visibleLength = candidate.carryUTF16Length
                        activeWeReadCarry = WeReadActiveCarry(
                            segmentID: cue.segmentID,
                            boundaryTime: cue.boundaryTime,
                            paragraphIndex: paragraphIndex,
                            visibleUTF16Length: visibleLength
                        )
                    } else {
                        activeWeReadCarry = nil
                    }
                    AudioPlayerService.shared.canStartQueuedSegment = nil
                    continuousWeReadHandoff = nil
                    invalidateWeReadPreview(reason: "continuous-committed")
                    AudioPlayerService.shared.resumeGatedSegmentIfPossible()
                    updateWeReadCarryHighlightIfNeeded()
                    ReaderRunLog.write(
                        "WEREAD continuous committed serial=\(continuous.serial) next=\(String(candidate.fingerprint.prefix(12)))"
                    )
                } else {
                    if continuousWeReadHandoff != nil {
                        cancelWeReadContinuousHandoff(reason: "visible-fingerprint-mismatch")
                    }
                    let committedCarry = canCommitBoundaryCarry && boundaryTurn.map { turn in
                        readVM?.commitLiveWebPageDuringActiveCarry(
                            candidate.page,
                            language: candidate.language,
                            carrySegmentID: turn.cue.segmentID,
                            weReadBoundary: candidate.boundary
                        ) == true
                    } == true
                    if committedCarry, let turn = boundaryTurn {
                        if let paragraphIndex = candidate.carryParagraphIndex,
                           candidate.carryUTF16Length > 0 {
                            activeWeReadCarry = WeReadActiveCarry(
                                segmentID: turn.cue.segmentID,
                                boundaryTime: turn.cue.boundaryTime,
                                paragraphIndex: paragraphIndex,
                                visibleUTF16Length: candidate.carryUTF16Length
                            )
                        } else {
                            activeWeReadCarry = nil
                        }
                        invalidateWeReadPreview(reason: "boundary-carry-committed")
                        updateWeReadCarryHighlightIfNeeded()
                        ReaderRunLog.write(
                            "WEREAD boundary carry committed next=\(String(candidate.fingerprint.prefix(12))) trim=\(candidate.carryUTF16Length)"
                        )
                    } else {
                        activeWeReadCarry = nil
                        readVM?.replaceLiveWebPage(
                            candidate.page,
                            language: candidate.language,
                            autoplay: wasReading,
                            weReadBoundary: candidate.boundary,
                            resumeAnchor: refresh?.didStopPlayback == true ? refresh?.anchor : nil
                        )
                    }
                }
            } else {
                cancelWeReadContinuousHandoff(reason: "explain-page-commit")
                let prefetched = wasExplaining ? consumeWeReadExplainPrefetch(for: candidate) : nil
                if !wasExplaining {
                    invalidateWeReadExplainPrefetch(reason: "page-commit-without-resume")
                }
                ReaderRunLog.write(
                    "WEREAD explain confirmed-page restart=\(wasExplaining ? "Y" : "N") prefetched=\(prefetched == nil ? "N" : "Y") prior=\(String(candidate.priorFingerprint.prefix(12))) next=\(String(candidate.fingerprint.prefix(12)))"
                )
                explainVM?.replaceLiveWebPage(
                    candidate.page,
                    language: candidate.language,
                    autoplay: wasExplaining,
                    prefetched: prefetched
                )
                invalidateWeReadPreview(reason: "explain-page-committed")
            }
            let segments = candidate.page.map {
                ["paragraphIndex": $0.id, "text": $0.text] as [String: Any]
            }
            call("init", ["segments": segments, "color": AppSettings.shared.highlightColorHex])
        } else {
            onRendered(candidate.page.map {
                WebRenderedParagraph(paragraphIndex: $0.id, text: $0.text, type: "paragraph")
            }, weReadBoundary: candidate.boundary, allowAutoStart: !isWeReadInitialPlaybackPending)
        }
        if isWeReadInitialPlaybackPending {
            scheduleWeReadInitialPlayback()
        }
        finishWeReadRefresh(reason: "page-commit")
    }

    /// While one natural sentence spans two visual pages, the audio item stays
    /// unchanged. Paint the visible continuation only after its proportional
    /// source position is reached; the next API segment then replaces it via
    /// the normal segment-driven highlighter.
    private func updateWeReadCarryHighlightIfNeeded() {
        guard var carry = activeWeReadCarry else { return }
        let audio = AudioPlayerService.shared
        guard audio.currentSegment?.id == carry.segmentID else {
            activeWeReadCarry = nil
            return
        }
        guard !carry.didPaint, audio.currentTime + 0.02 >= carry.boundaryTime else { return }
        carry.didPaint = true
        activeWeReadCarry = carry
        call("highlightRange", [
            "paragraphIndex": carry.paragraphIndex,
            "charStart": 0,
            "charEnd": carry.visibleUTF16Length,
            "segSeq": 0,
            "segmentTexts": [],
        ])
    }

    private func requestWeReadNextPage() {
        guard isWeRead, didInit else {
            automaticAppReviewContinuation.cancel()
            if !isReadMode { explainVM?.finishLivePageContinuation() }
            return
        }
        // A semantic turn may already be in flight (for example, a boundary
        // cue fired just before the block-complete callback). Its eventual
        // commit/reject/timeout owns resolution of the continuation state.
        guard !pendingWeReadTurn else { return }
        pendingWeReadManualTurn = false
        weReadManualIntentTimeout?.cancel()
        weReadManualIntentTimeout = nil
        weReadManualCommitTask?.cancel()
        weReadManualCommitTask = nil
        pendingWeReadTurn = true
        pendingWeReadActionID = ""
        weReadTurnRequestedAt = Date()
        ReaderRunLog.write("WEREAD page turn action=semantic-next fingerprint=\(String(lastWeReadFingerprint.prefix(12)))")
        guard let webView else {
            automaticAppReviewContinuation.cancel()
            suppressAppReviewContinuationForPendingTurn = false
            pendingWeReadTurn = false
            pendingWeReadBoundaryTurn = nil
            weReadTurnRequestedAt = nil
            cancelWeReadContinuousHandoff(reason: "webview-unavailable")
            if !isReadMode { explainVM?.finishLivePageContinuation() }
            return
        }
        webView.evaluateJavaScript("window.CastReaderWeRead && window.CastReaderWeRead.nextPage && window.CastReaderWeRead.nextPage()") { [weak self] value, error in
            guard let self else { return }
            if let error { NSLog("CRDBG WeRead nextPage error %@", "\(error)") }
            if (value as? Bool) != true {
                self.automaticAppReviewContinuation.cancel()
                self.suppressAppReviewContinuationForPendingTurn = false
                self.pendingWeReadTurn = false
                self.pendingWeReadBoundaryTurn = nil
                self.weReadTurnRequestedAt = nil
                self.cancelWeReadContinuousHandoff(reason: "semantic-next-unavailable")
                if !self.isReadMode { self.explainVM?.finishLivePageContinuation() }
                return
            }
            // Confirmation is observational only.  Timeout never performs a
            // second click; the user remains on the current page safely.
            self.weReadTurnTimeout?.cancel()
            self.weReadTurnTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled, self.pendingWeReadTurn else { return }
                self.automaticAppReviewContinuation.cancel()
                self.suppressAppReviewContinuationForPendingTurn = false
                self.pendingWeReadTurn = false
                self.pendingWeReadActionID = ""
                self.pendingWeReadBoundaryTurn = nil
                self.weReadTurnRequestedAt = nil
                self.resumeReadAfterWeReadTurn = false
                self.resumeExplainAfterWeReadTurn = false
                self.cancelWeReadContinuousHandoff(reason: "turn-confirmation-timeout")
                if !self.isReadMode { self.explainVM?.finishLivePageContinuation() }
                ReaderRunLog.write("WEREAD page turn confirmation timeout no-retry")
            }
        }
    }

    /// A Canvas fingerprint is visual evidence, not navigation intent. Read
    /// mode still uses it as a defensive stop boundary, while QuickRead only
    /// accepts it after an explicit manual intent, its own semantic auto-turn,
    /// or a native refresh. This mirrors the extension and prevents mark/status
    /// repaints from feeding back into stop -> reload -> start.
    private func prepareForWeReadPageChange(_ payload: [String: Any]) {
        guard isWeRead, didInit else { return }
        let reason = (payload["reason"] as? String) ?? "canvas"
        if reason == "manual-intent" {
            automaticAppReviewContinuation.cancel()
            suppressAppReviewContinuationForPendingTurn = true
        }
        if reason == "manual-intent", !pendingWeReadTurn {
            armWeReadManualIntent()
        }
        guard WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: isReadMode,
            reason: reason,
            hasPendingSemanticTurn: pendingWeReadTurn,
            hasPendingManualTurn: pendingWeReadManualTurn,
            refreshActive: weReadRefreshState != nil
        ) else {
            ReaderRunLog.write("WEREAD explain canvas-repaint ignored reason=\(reason)")
            return
        }
        activeWeReadCarry = nil
        // A second manual intent supersedes an uncommitted B-page candidate.
        // Keep the resume intent, but never let B restart while the user is
        // already moving toward C.
        weReadManualCommitTask?.cancel()
        weReadManualCommitTask = nil
        if isWeReadInitialPlaybackPending {
            // The first Canvas candidate was provisional. Keep the already
            // visible WebView alive, but do not let it start audio before the
            // replacement surface is committed.
            weReadInitialPlaybackTask?.cancel()
            weReadInitialPlaybackTask = nil
            call("clearHighlight")
            call("clearMarks")
            ReaderRunLog.write(
                "WEREAD initial surface superseded reason=\(payload["reason"] ?? "canvas")"
            )
            return
        }
        if var refresh = weReadRefreshState {
            cancelWeReadContinuousHandoff(reason: "layout-refresh")
            invalidateWeReadPreview(reason: "layout-refresh")
            invalidateWeReadExplainPrefetch(reason: "layout-refresh")
            if !refresh.didStopPlayback {
                refresh.didStopPlayback = true
                weReadRefreshState = refresh
                if isReadMode, refresh.resumeRead {
                    readVM?.stop()
                } else if !isReadMode, refresh.resumeExplain {
                    explainVM?.stop()
                }
            }
            call("clearHighlight")
            call("clearMarks")
            ReaderRunLog.write(
                "WEREAD layout changing reason=\(payload["reason"] ?? refresh.reason) serial=\(refresh.serial) read=\(refresh.resumeRead ? "Y" : "N") explain=\(refresh.resumeExplain ? "Y" : "N")"
            )
            return
        }

        let isExpectedContinuousTurn = pendingWeReadTurn && continuousWeReadHandoff != nil
        let isExpectedBoundaryCarry = pendingWeReadTurn && pendingWeReadBoundaryTurn.map {
            AudioPlayerService.shared.currentSegment?.id == $0.cue.segmentID
        } == true
        if isReadMode, isExpectedContinuousTurn || isExpectedBoundaryCarry {
            resumeReadAfterWeReadTurn = true
        } else if isReadMode {
            cancelWeReadContinuousHandoff(reason: "manual-page-change")
            invalidateWeReadPreview(reason: "manual-page-change")
            let shouldResume = pendingWeReadTurn || readVM?.isActive == true || readVM?.isPlaying == true
            resumeReadAfterWeReadTurn = resumeReadAfterWeReadTurn || shouldResume
            if shouldResume { readVM?.stop() }
        } else {
            cancelWeReadContinuousHandoff(reason: "explain-page-change")
            // Keep an automatic next-page prediction alive until the real
            // Canvas commits and validates it. Manual turns may go backward or
            // skip, so their speculative explanation must be discarded.
            if pendingWeReadTurn {
                invalidateWeReadPreview(reason: "explain-auto-turn", preservePrediction: true)
            } else {
                invalidateWeReadPreview(reason: "explain-manual-page-change")
                invalidateWeReadExplainPrefetch(reason: "explain-manual-page-change")
            }
            let shouldResume = WeReadExplainPageEventContract.shouldResumeExplanation(
                isAutomaticTurn: pendingWeReadTurn
            )
            resumeExplainAfterWeReadTurn = resumeExplainAfterWeReadTurn || shouldResume
            if shouldResume || pendingWeReadManualTurn,
               explainVM?.isActive == true || explainVM?.isPlaying == true {
                explainVM?.stop()
            }
        }
        call("clearHighlight")
        call("clearMarks")
        ReaderRunLog.write(
            "WEREAD page changing reason=\(payload["reason"] ?? "canvas") read=\(resumeReadAfterWeReadTurn ? "Y" : "N") explain=\(resumeExplainAfterWeReadTurn ? "Y" : "N")"
        )
    }

    private func armWeReadManualIntent() {
        automaticAppReviewContinuation.cancel()
        suppressAppReviewContinuationForPendingTurn = true
        pendingWeReadManualTurn = true
        weReadManualIntentTimeout?.cancel()
        weReadManualIntentTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.pendingWeReadManualTurn else { return }
            self.pendingWeReadManualTurn = false
            self.resumeExplainAfterWeReadTurn = false
            ReaderRunLog.write("WEREAD manual intent expired without page evidence")
        }
    }

    private func invalidateWeReadPreview(reason: String, preservePrediction: Bool = false) {
        weReadPreviewTask?.cancel()
        weReadPreviewTask = nil
        if !preservePrediction {
            pendingWeReadPreview = nil
        }
        preparedWeReadPage = nil
        ReaderRunLog.write("WEREAD preload invalidated reason=\(reason) preserve=\(preservePrediction ? "Y" : "N")")
    }

    private func invalidateWeReadExplainPrefetch(reason: String) {
        weReadExplainPrefetchTask?.cancel()
        weReadExplainPrefetchTask = nil
        preparedWeReadExplanation = nil
        ReaderRunLog.write("WEREAD explain preload invalidated reason=\(reason)")
    }

    private func cancelWeReadContinuousHandoff(reason: String) {
        guard let handoff = continuousWeReadHandoff else { return }
        let audio = AudioPlayerService.shared
        _ = audio.removePendingSegments(withIDs: handoff.segmentIDs)
        audio.canStartQueuedSegment = nil
        continuousWeReadHandoff = nil
        ReaderRunLog.write("WEREAD continuous cancelled reason=\(reason) serial=\(handoff.serial)")
    }

    /// 正文提取完成 → 重建 paragraphs 喂 TTS + CR.init 段落 + 自动朗读。
    private func onRendered(
        _ paras: [WebRenderedParagraph],
        weReadBoundary: WeReadPageSpeechBoundary? = nil,
        allowAutoStart: Bool = true
    ) {
        guard let readVM, !paras.isEmpty else { return }
        let rps = paras.map { ReadingParagraph(id: $0.paragraphIndex, text: $0.text, type: .paragraph) }
        // 从提取的正文检测语言（中文网页→zh 音色），统一系统化判定，避免中文用英文音色。
        let detected = LanguageDetector.detect(rps.prefix(30).map { $0.text }.joined(separator: " "))
        print("[WebReader] 🌐 detected language=\(detected)")
        HistoryStore.shared.updateDetectedLanguage(documentID: readVM.document.id, language: detected)
        readVM.loadWebParagraphs(rps, language: detected, weReadBoundary: weReadBoundary)
        explainVM?.loadWebParagraphs(rps, language: detected)

        let segs = rps.map { ["paragraphIndex": $0.id, "text": $0.text] as [String: Any] }
        call("init", ["segments": segs, "color": AppSettings.shared.highlightColorHex])
        didInit = true

        // 段落就绪后才自动开播，且按「当前模式」启动对应 VM（剪贴板/网址 autoplay 进解读时启动解读，
        // 避免用空段落请求后端 → 解读 HTTP 400 / 朗读无内容）。从 Mini Player 展开会重建 bridge（didAutoStart 重置），
        // 此时 readVM 已有进度（currentParagraphIndex>=0）→ 不重复开播。
        if allowAutoStart { startAutoPlaybackIfNeeded() }
    }

    private func scheduleWeReadInitialPlayback() {
        guard isWeRead, isWeReadInitialPlaybackPending else { return }
        weReadInitialPlaybackTask?.cancel()
        let fingerprint = lastWeReadFingerprint
        weReadInitialPlaybackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: WeReadInitialPlaybackContract.stabilityDelayNanoseconds)
            guard let self,
                  !Task.isCancelled,
                  self.isWeReadInitialPlaybackPending,
                  !fingerprint.isEmpty,
                  fingerprint == self.lastWeReadFingerprint else { return }
            self.weReadInitialPlaybackTask = nil
            self.isWeReadInitialPlaybackPending = false
            KindleSessionProbe.logCookies(reason: "weread-playback-start")
            self.startAutoPlaybackIfNeeded()
            ReaderRunLog.write(
                "WEREAD initial surface stable autoplay=\(AppSettings.shared.autoPlay ? "Y" : "N") fingerprint=\(String(fingerprint.prefix(12)))"
            )
        }
    }

    private func startAutoPlaybackIfNeeded() {
        guard AppSettings.shared.autoPlay, !didAutoStart else { return }
        didAutoStart = true
        if isReadMode {
            if let readVM, readVM.currentParagraphIndex < 0, !readVM.isActive, !readVM.isPlaying {
                readVM.start()
            }
        } else {
            explainVM?.start()
        }
    }

    // MARK: - native → JS

    private func pushHighlight(_ cmd: WebHighlightCmd) {
        guard didInit else { return }
        if cmd.isWord {
            call("highlightWord", ["paragraphIndex": cmd.paragraphIndex, "segSeq": cmd.segSeq,
                                   "words": cmd.words ?? [], "wordIndex": cmd.wordIndex])
        } else {
            call("highlightRange", [
                "paragraphIndex": cmd.paragraphIndex,
                "charStart": cmd.charStart,
                "charEnd": cmd.charEnd,
                "segSeq": cmd.segSeq,
                "segmentTexts": cmd.segmentTexts ?? [],
            ])
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
            if let w = m.weight { payload["weight"] = w }   // P1：重要度分层
            if let r = m.role { payload["role"] = r }
            call("showMark", payload)
        }
    }

    /// 切朗读/解读模式：启停 DOM 高亮层。
    func setActive(readMode: Bool) {
        if isWeRead, !readMode, isReadMode {
            automaticAppReviewContinuation.cancel()
            suppressAppReviewContinuationForPendingTurn = true
            cancelWeReadContinuousHandoff(reason: "mode-switched")
            invalidateWeReadPreview(reason: "mode-switched-to-explain", preservePrediction: true)
            activeWeReadCarry = nil
        } else if isWeRead, readMode, !isReadMode {
            suppressAppReviewContinuationForPendingTurn = false
            invalidateWeReadExplainPrefetch(reason: "mode-switched-to-read")
        }
        isReadMode = readMode
        call("setActive", ["active": readMode])
        if isWeRead, readMode {
            maybeStartWeReadPreviewPrefetch()
        } else if isWeRead {
            maybeStartWeReadExplainPrefetch()
        }
    }

    func refocusIfNeeded(_ token: Int, readMode: Bool) {
        guard token != lastRefocusToken else { return }
        lastRefocusToken = token
        if readMode {
            guard let readVM, readVM.autoScrollEnabled, readVM.currentParagraphIndex >= 0 else { return }
            ReaderRunLog.write("WEB refocus read para=\(readVM.currentParagraphIndex) token=\(token) didInit=\(didInit)")
            call("scrollTo", ["paragraphIndex": readVM.currentParagraphIndex, "anchor": 0.3, "reason": "refocus"])
        } else {
            let target = explainVM?.activeMarks.last?.paragraphIndex ?? explainVM?.scrollTarget ?? -1
            guard target >= 0 else { return }
            ReaderRunLog.write("WEB refocus explain para=\(target) token=\(token) didInit=\(didInit)")
            call("scrollTo", ["paragraphIndex": target, "anchor": 0.35, "reason": "refocus"])
        }
    }

    // MARK: - WeRead lifecycle / viewport recovery

    func applicationActivityChanged(isActive: Bool) {
        guard isWeRead else { return }
        guard lastApplicationActivityState != isActive else { return }
        lastApplicationActivityState = isActive
        isApplicationActive = isActive
        weReadForegroundProbeSerial &+= 1
        weReadForegroundProbeAttemptSerial &+= 1
        if !isActive {
            ReaderRunLog.write("WEREAD background preserve-webview fingerprint=\(String(lastWeReadFingerprint.prefix(12)))")
            return
        }
        if shouldReloadWeReadOnForeground {
            shouldReloadWeReadOnForeground = false
            recoverWeReadWebContent(reason: "foreground-after-process-termination")
            return
        }
        guard didInit, webView != nil else { return }
        scheduleWeReadForegroundProbe(attempt: 0, serial: weReadForegroundProbeSerial)
    }

    private func scheduleWeReadForegroundProbe(attempt: Int, serial: Int) {
        guard attempt < WeReadBackgroundLifecycleContract.foregroundProbeDelays.count else {
            guard serial == weReadForegroundProbeSerial, isApplicationActive else { return }
            if WeReadBackgroundLifecycleContract.shouldReload(
                probeSucceeded: false,
                webContentProcessTerminationObserved: shouldReloadWeReadOnForeground
            ) {
                shouldReloadWeReadOnForeground = false
                recoverWeReadWebContent(reason: "foreground-after-process-termination")
            } else {
                // A healthy but still-resuming WKWebView must remain attached.
                // Reloading here would rewind WeRead to the chapter opening.
                ReaderRunLog.write("WEREAD foreground probe inconclusive preserve-live-webview attempts=\(attempt)")
            }
            return
        }
        let delay = WeReadBackgroundLifecycleContract.foregroundProbeDelays[attempt]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  serial == self.weReadForegroundProbeSerial,
                  self.isApplicationActive,
                  let webView = self.webView else { return }
            self.weReadForegroundProbeAttemptSerial &+= 1
            let attemptSerial = self.weReadForegroundProbeAttemptSerial
            let probe = "Boolean(window.__castReaderWeReadBridgeV2 && window.CastReaderWeRead && document.readyState !== 'loading')"
            webView.evaluateJavaScript(probe) { [weak self] value, error in
                Task { @MainActor in
                    guard let self,
                          serial == self.weReadForegroundProbeSerial,
                          attemptSerial == self.weReadForegroundProbeAttemptSerial,
                          self.isApplicationActive else { return }
                    self.weReadForegroundProbeAttemptSerial &+= 1
                    if error == nil, (value as? Bool) == true {
                        self.callWeRead("resumeAfterForeground", ["reason": "foreground"])
                        ReaderRunLog.write("WEREAD foreground reused-live-webview attempt=\(attempt + 1)")
                    } else {
                        ReaderRunLog.write("WEREAD foreground probe deferred attempt=\(attempt + 1) error=\(error == nil ? "N" : "Y")")
                        self.scheduleWeReadForegroundProbe(attempt: attempt + 1, serial: serial)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + WeReadBackgroundLifecycleContract.foregroundProbeTimeout
            ) { [weak self] in
                guard let self,
                      serial == self.weReadForegroundProbeSerial,
                      attemptSerial == self.weReadForegroundProbeAttemptSerial,
                      self.isApplicationActive else { return }
                self.weReadForegroundProbeAttemptSerial &+= 1
                ReaderRunLog.write("WEREAD foreground probe timeout attempt=\(attempt + 1)")
                self.scheduleWeReadForegroundProbe(attempt: attempt + 1, serial: serial)
            }
        }
    }

    /// Called immediately before an intentional navigation such as a native
    /// theme switch. The current sentence is captured before the old JavaScript
    /// world disappears, and the new page resumes from that sentence/progress.
    func prepareWeReadReload(reason: String) {
        guard isWeRead, didInit else { return }
        beginWeReadRefresh(reason: reason, stopPlayback: true)
    }

    private func beginWeReadRefresh(reason: String, stopPlayback: Bool) {
        guard isWeRead else { return }
        automaticAppReviewContinuation.cancel()
        suppressAppReviewContinuationForPendingTurn = true
        if var existing = weReadRefreshState {
            if stopPlayback, !existing.didStopPlayback {
                existing.didStopPlayback = true
                weReadRefreshState = existing
                if existing.resumeRead { readVM?.stop() }
                if existing.resumeExplain { explainVM?.stop() }
            }
            return
        }
        weReadRefreshSerial &+= 1
        let resumeRead = isReadMode && (readVM?.isPlaying == true)
        let resumeExplain = !isReadMode && (explainVM?.isPlaying == true)
        var state = WeReadRefreshState(
            serial: weReadRefreshSerial,
            reason: reason,
            sourceFingerprint: lastWeReadFingerprint,
            resumeRead: resumeRead,
            resumeExplain: resumeExplain,
            anchor: readVM?.makeWeReadPlaybackResumeAnchor(),
            didStopPlayback: false
        )
        if stopPlayback {
            state.didStopPlayback = true
            if resumeRead { readVM?.stop() }
            if resumeExplain { explainVM?.stop() }
        }
        weReadRefreshState = state
        cancelWeReadContinuousHandoff(reason: "refresh-\(reason)")
        invalidateWeReadPreview(reason: "refresh-\(reason)")
        invalidateWeReadExplainPrefetch(reason: "refresh-\(reason)")
        onWeReadNeedsLoadingCover?()
        if WeReadBackgroundLifecycleContract.shouldScheduleRefreshFallback(
            applicationIsActive: isApplicationActive
        ) {
            scheduleWeReadRefreshFallback(serial: state.serial)
        }
        ReaderRunLog.write(
            "WEREAD refresh begin reason=\(reason) serial=\(state.serial) stop=\(stopPlayback ? "Y" : "N") read=\(resumeRead ? "Y" : "N")"
        )
    }

    private func scheduleWeReadRefreshFallback(serial: Int) {
        weReadRefreshTask?.cancel()
        weReadRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.weReadRefreshState?.serial == serial else { return }
            self.recoverWeReadWebContent(reason: "layout-stability-timeout")
        }
    }

    private func finishWeReadLayoutIfStable(_ payload: [String: Any]) {
        onWeReadSurfaceStable?()
        guard let refresh = weReadRefreshState else { return }
        let fingerprint = (payload["fingerprint"] as? String) ?? ""
        // Same visible page after a successful resize: WebView and AVPlayer
        // were never torn down, so retain both without a synthetic restart.
        if !refresh.didStopPlayback,
           !fingerprint.isEmpty,
           fingerprint == lastWeReadFingerprint {
            finishWeReadRefresh(reason: "same-page-layout-stable")
        }
    }

    private func finishWeReadRefresh(reason: String) {
        guard let refresh = weReadRefreshState else { return }
        weReadRefreshTask?.cancel()
        weReadRefreshTask = nil
        weReadRefreshState = nil
        onWeReadSurfaceStable?()
        ReaderRunLog.write("WEREAD refresh complete reason=\(reason) serial=\(refresh.serial)")
    }

    private func recoverWeReadWebContent(reason: String) {
        guard isWeRead else { return }
        beginWeReadRefresh(reason: reason, stopPlayback: true)
        guard isApplicationActive else {
            shouldReloadWeReadOnForeground = true
            return
        }
        guard let webView else { return }
        onWeReadNeedsLoadingCover?()
        ReaderRunLog.write("WEREAD web-content reload reason=\(reason)")
        if webView.url != nil {
            webView.reload()
        } else if let raw = readVM?.document.sourceURL, let url = URL(string: raw) {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - WeRead stale book-entry recovery

    private func finishWeReadEntryRecoveryIfNeeded() {
        guard weReadEntryRecoveryStage != .idle else { return }
        weReadEntryReadinessTask?.cancel()
        weReadEntryReadinessTask = nil
        weReadShelfRecoveryTask?.cancel()
        weReadShelfRecoveryTask = nil
        weReadEntryRecoveryStage = .idle
        ReaderRunLog.write("WEREAD entry recovery completed")
    }

    private func startWeReadEntryRecovery(failedURL: String?, reason: String, forceShelf: Bool = false) {
        guard isWeRead,
              let webView,
              let bookID = readVM?.document.id,
              !bookID.isEmpty else { return }

        weReadEntryReadinessTask?.cancel()
        weReadEntryReadinessTask = nil
        beginWeReadRefresh(reason: "entry-\(reason)", stopPlayback: true)

        if !forceShelf,
           let fallback = WeReadLibraryStore.shared.localRecoveryURL(bookID: bookID, failedURL: failedURL),
           !weReadRecoveryAttemptedURLs.contains(fallback),
           let url = URL(string: fallback) {
            weReadRecoveryAttemptedURLs.insert(fallback)
            weReadEntryRecoveryStage = .loadingLocalFallback
            ReaderRunLog.write("WEREAD entry recovery local-fallback reason=\(reason)")
            onWeReadNeedsLoadingCover?()
            webView.load(URLRequest(url: themedWeReadURL(url, for: webView)))
            return
        }

        guard !didAttemptWeReadShelfRecovery else {
            WeReadLibraryStore.shared.reportRecoveryError(AppLocalized("微信读书书籍链接已失效，请重新登录并同步书架。"))
            ReaderRunLog.write("WEREAD entry recovery exhausted reason=\(reason)")
            onWeReadSurfaceStable?()
            return
        }

        didAttemptWeReadShelfRecovery = true
        weReadEntryRecoveryStage = .scanningShelf
        ReaderRunLog.write("WEREAD entry recovery shelf-scan reason=\(reason)")
        onWeReadNeedsLoadingCover?()
        webView.load(URLRequest(url: themedWeReadURL(WeReadWebScripts.shelfURL, for: webView)))
    }

    private func continueWeReadShelfRecoveryAfterNavigation() {
        switch weReadEntryRecoveryStage {
        case .scanningShelf, .awaitingLogin:
            break
        default:
            return
        }
        guard weReadShelfRecoveryTask == nil else { return }
        weReadShelfRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.weReadShelfRecoveryTask = nil }
            await self.scanWeReadShelfForRecovery()
        }
    }

    private func scanWeReadShelfForRecovery() async {
        guard let webView,
              let targetID = readVM?.document.id,
              let storedBook = WeReadLibraryStore.shared.book(for: targetID) else { return }

        var unauthenticatedProbes = 0
        for pass in 0..<9 {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: pass == 0 ? .milliseconds(650) : .milliseconds(500))
            guard let result = try? await evaluateWeReadLibraryScan(in: webView) else { continue }

            if result.authRequired || !result.authenticated {
                unauthenticatedProbes += 1
                guard unauthenticatedProbes >= 2 else { continue }
                weReadEntryRecoveryStage = .awaitingLogin
                WeReadLibraryStore.shared.reportRecoveryError(AppLocalized("微信读书登录已失效，请重新登录后继续。"))
                ReaderRunLog.write("WEREAD entry recovery awaiting-login")
                onWeReadSurfaceStable?()
                if isWeReadShelfURL(webView.url) {
                    webView.load(URLRequest(url: themedWeReadURL(WeReadWebScripts.homeURL, for: webView)))
                }
                return
            }

            if !isWeReadShelfURL(webView.url) {
                weReadEntryRecoveryStage = .scanningShelf
                webView.load(URLRequest(url: themedWeReadURL(WeReadWebScripts.shelfURL, for: webView)))
                return
            }

            let refreshed = result.books.first { candidate in
                candidate.id == targetID ||
                    (storedBook.bookID != nil && candidate.bookID == storedBook.bookID)
            }
            if let refreshed,
               let recoveredURL = WeReadLibraryStore.shared.installRecoveredEntry(refreshed, for: targetID),
               let url = URL(string: recoveredURL) {
                weReadEntryRecoveryStage = .loadingRecoveredEntry
                weReadRecoveryAttemptedURLs.insert(recoveredURL)
                ReaderRunLog.write("WEREAD entry recovery shelf-match pass=\(pass + 1)")
                webView.load(URLRequest(url: themedWeReadURL(url, for: webView)))
                return
            }

            _ = try? await webView.evaluateJavaScript(
                "window.scrollBy({top:Math.max(window.innerHeight*.82,520),behavior:'auto'})"
            )
        }

        WeReadLibraryStore.shared.reportRecoveryError(AppLocalized("书架中没有找到这本书，请重新同步微信读书书架。"))
        ReaderRunLog.write("WEREAD entry recovery shelf-book-not-found")
        onWeReadSurfaceStable?()
    }

    private func scheduleWeReadEntryReadinessProbe(for url: URL?) {
        guard isWeRead,
              lastWeReadFingerprint.isEmpty,
              let url,
              isWeReadReaderURL(url) else { return }
        weReadEntryReadinessTask?.cancel()
        let expected = url.absoluteString
        weReadEntryReadinessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self,
                  !Task.isCancelled,
                  self.lastWeReadFingerprint.isEmpty,
                  self.webView?.url?.absoluteString == expected else { return }
            let forceShelf = self.weReadEntryRecoveryStage == .loadingLocalFallback ||
                self.weReadEntryRecoveryStage == .loadingRecoveredEntry
            self.startWeReadEntryRecovery(failedURL: expected, reason: "reader-ready-timeout", forceShelf: forceShelf)
        }
    }

    private func evaluateWeReadLibraryScan(in webView: WKWebView) async throws -> WeReadScanResult {
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(WeReadWebScripts.libraryScan) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as Any) }
            }
        }
        guard let raw = value as? [String: Any] else { throw NSError(domain: "WeReadRecovery", code: 1) }
        return WeReadScanResult(raw)
    }

    private func isWeReadReaderURL(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased().hasSuffix("weread.qq.com") == true else { return false }
        return url.path.lowercased().contains("reader")
    }

    private func isWeReadShelfURL(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased().hasSuffix("weread.qq.com") == true else { return false }
        return url.path.lowercased().contains("shelf")
    }

    private func themedWeReadURL(_ url: URL, for webView: WKWebView) -> URL {
        WeReadNativeTheme.themedURL(url, isDark: webView.overrideUserInterfaceStyle == .dark)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isWeRead else { return }
        // Amazon-session snapshot taken from the WeRead side, written into the
        // Kindle probe log so both readers share one timeline. Observation only.
        KindleSessionProbe.logCookies(reason: "weread-didFinish")
        // The layout width was fixed before navigation, so revealing the
        // native reader here can no longer expose a second-width flash. Do not
        // keep an opaque app-side cover up while geometry/TTS indexing runs.
        onWeReadSurfaceStable?()
        switch weReadEntryRecoveryStage {
        case .scanningShelf, .awaitingLogin:
            continueWeReadShelfRecoveryAfterNavigation()
        case .loadingLocalFallback:
            if isWeReadReaderURL(webView.url) {
                scheduleWeReadEntryReadinessProbe(for: webView.url)
            } else {
                startWeReadEntryRecovery(
                    failedURL: readVM?.document.sourceURL,
                    reason: "local-fallback-redirected",
                    forceShelf: true
                )
            }
        case .loadingRecoveredEntry:
            if isWeReadReaderURL(webView.url) {
                scheduleWeReadEntryReadinessProbe(for: webView.url)
            } else {
                // A recovered URL that returns to Home is normally an expired
                // account session. Keep the recovery state alive so login can
                // complete in this same WebView and resume the shelf scan.
                weReadEntryRecoveryStage = .awaitingLogin
                continueWeReadShelfRecoveryAfterNavigation()
            }
        case .idle:
            if isWeReadReaderURL(webView.url) {
                scheduleWeReadEntryReadinessProbe(for: webView.url)
            } else {
                startWeReadEntryRecovery(
                    failedURL: webView.url?.absoluteString ?? readVM?.document.sourceURL,
                    reason: "redirected-away-from-reader"
                )
            }
        }
        if weReadRefreshState != nil {
            callWeRead("resumeAfterForeground", ["reason": "navigation-finished"])
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleWeReadNavigationFailure(webView, error: error, phase: "provisional")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWeReadNavigationFailure(webView, error: error, phase: "committed")
    }

    /// WeRead's main-frame status. Recorded only — WeRead's entry recovery owns
    /// every decision, and it must keep owning them because its login session
    /// cannot survive an outside re-navigation.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if isWeRead,
           navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            lastWeReadMainFrameStatus = http.statusCode
            ReaderRunLog.write("WEREAD response status=\(http.statusCode) url=\(http.url?.absoluteString ?? "")")
        }
        decisionHandler(.allow)
    }

    private static func isTransientNetworkError(_ code: Int) -> Bool {
        [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
         NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
         NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed].contains(code)
    }

    private func handleWeReadNavigationFailure(_ webView: WKWebView, error: Error, phase: String) {
        guard isWeRead else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        if pendingWeReadTOCJump {
            failWeReadTOCJump(reason: "navigation-\(phase)-\(nsError.code)")
            return
        }
        ReaderRunLog.write("WEREAD navigation failed phase=\(phase) code=\(nsError.code) status=\(lastWeReadMainFrameStatus.map(String.init) ?? "-")")

        // A dropped connection means the page never loaded, so there is no live
        // login session to protect and retrying the same URL is safe. Sending it
        // into entry recovery instead would push an offline user through shelf
        // scanning and a login prompt for what is only a lost connection.
        if Self.isTransientNetworkError(nsError.code),
           weReadEntryRecoveryStage == .idle,
           weReadNetworkRetries < 2,
           let retryURL = webView.url ?? readVM?.document.sourceURL.flatMap(URL.init(string:)) {
            weReadNetworkRetries += 1
            let delay = UInt64(weReadNetworkRetries * 2) * 1_000_000_000
            ReaderRunLog.write("WEREAD network retry \(weReadNetworkRetries)/2 in \(weReadNetworkRetries * 2)s")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self, self.weReadEntryRecoveryStage == .idle else { return }
                self.webView?.load(URLRequest(url: retryURL))
            }
            return
        }
        weReadNetworkRetries = 0
        let forceShelf = weReadEntryRecoveryStage == .loadingLocalFallback ||
            weReadEntryRecoveryStage == .loadingRecoveredEntry
        startWeReadEntryRecovery(
            failedURL: webView.url?.absoluteString ?? readVM?.document.sourceURL,
            reason: "navigation-\(phase)-\(nsError.code)",
            forceShelf: forceShelf
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard isWeRead else { return }
        ReaderRunLog.write("WEREAD web-content process terminated active=\(isApplicationActive ? "Y" : "N")")
        if isApplicationActive {
            recoverWeReadWebContent(reason: "process-terminated")
        } else {
            beginWeReadRefresh(reason: "process-terminated-background", stopPlayback: true)
            shouldReloadWeReadOnForeground = true
        }
    }

    func setColor(_ hex: String) { call("setColor", ["hex": hex]) }

    private func callWeRead(_ fn: String, _ payload: [String: Any] = [:]) {
        guard let webView else { return }
        var arg = "{}"
        if !payload.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let value = String(data: data, encoding: .utf8) {
            arg = value
        }
        let js = "window.CastReaderWeRead && window.CastReaderWeRead.\(fn) && window.CastReaderWeRead.\(fn)(\(arg))"
        webView.evaluateJavaScript(js) { _, error in
            if let error { print("[WebReader] WeRead call \(fn) error: \(error)") }
        }
    }

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

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func weReadBoundary(
        from raw: [[String: Any]]
    ) -> WeReadPageSpeechBoundary? {
        for (index, value) in raw.enumerated().reversed() {
            let visible = Int(double(value["boundaryUTF16Offset"]) ?? 0)
            let speech = Int(double(value["extendedUTF16Length"]) ?? 0)
            let boundary = WeReadPageSpeechBoundary(
                paragraphIndex: index,
                visibleUTF16Offset: visible,
                speechUTF16Length: speech,
                sourceParagraphIndex: double(value["sourceParagraphIndex"]).map { Int($0) },
                sourceSpeechEnd: double(value["sourceSpeechEnd"]).map { Int($0) }
            )
            if boundary.isCrossPage { return boundary }
        }
        return nil
    }
}
