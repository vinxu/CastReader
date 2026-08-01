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
    var onLiveWebSurfaceStable: (() -> Void)?
    var onLiveWebNeedsLoadingCover: (() -> Void)?
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
    /// Actual platform. `isGoogleBooks` below is retained as the private name
    /// of the proven paginated-DOM engine while Kobo migrates onto it.
    private var livePlatform: LiveWebPlatformID?
    private var liveBookID = ""
    /// O'Reilly chapter navigation may change slug/path/hash, but it must never
    /// escape the exact host and content ID proven by the bound shelf item.
    private var oreillyBoundReaderHost: String?
    private var oreillyBoundContentID: String?
    private var isGoogleBooks = false
    private var liveWebSurfaceSize: CGSize = .zero
    private var liveWebBottomOcclusion: CGFloat = 0
    private var hasLiveWebViewport = false
    private var lastGoogleBooksSignature = ""
    private var lastGoogleBooksEvidence: GoogleBooksPageEvidence?
    private var lastGoogleBooksParagraphTexts: [String] = []
    private var lastGoogleBooksLanguage = ""
    private var googleBooksReadDOMSegments: [[String: Any]] = []
    private var googleBooksExplainDOMSegments: [[String: Any]] = []
    private var activeGoogleBooksFrameSessionID: String?
    private var googleBooksFailedTurnSignature: String?
    private var googleBooksLateTurn: GoogleBooksLateTurn?
    private var googleBooksLateTurnVisualsSuppressed = false
    private var googleBooksLateTurnVisualSuppressionTask:
        Task<Void, Never>?
    private var pendingGoogleBooksTurn = false
    private var googleBooksTurnIdentity: GoogleBooksTurnIdentity?
    private var googleBooksTurnLogicalBaseline = ""
    private var googleBooksTurnPriorCursor: LiveWebPageConsumedCursor?
    private enum GoogleBooksTurnOwner: Equatable {
        case read
        case explain
    }
    private var googleBooksTurnOwner: GoogleBooksTurnOwner?
    private var googleBooksTurnTimeout: Task<Void, Never>?
    private var googleBooksTurnSuspendedInBackground = false
    private var googleBooksTurnActionDeferredForForeground = false
    private var googleBooksManualIntentProbeTask: Task<Void, Never>?
    private var googleBooksManualRestartTask: Task<Void, Never>?
    private var pendingGoogleBooksManualTurn = false
    private var googleBooksManualTurnIdentity: GoogleBooksManualTurnIdentity?
    private var googleBooksManualLogicalBaseline = ""
    /// Absolute source cursor activated only after the current page really
    /// finishes speaking and a semantic next-page request begins.
    private var googleBooksConsumedCursor: LiveWebPageConsumedCursor?
    /// Candidate produced while parsing the current page. It is not consumed
    /// by refresh/reflow until natural playback completion promotes it.
    private var googleBooksPageCompletionCursor: LiveWebPageConsumedCursor?
    private var googleBooksCurrentBoundarySourceUTF16End: Int?
    private var pendingGoogleBooksBoundaryTurn: GoogleBooksBoundaryTurn?
    private var googleBooksCarryAdvance: GoogleBooksCarryAdvance?
    private var activeGoogleBooksCarry: GoogleBooksActiveCarry?
    private var pendingGoogleBooksPagePreview: GoogleBooksPagePreview?
    private var preparedGoogleBooksReadPage: GoogleBooksPreparedReadPage?
    private var googleBooksReadPreloadTask: Task<Void, Never>?
    private var googleBooksPreloadGeneration: UInt64 = 0
    private var pendingGoogleBooksSpeechPreview:
        GoogleBooksSpeechPreviewCandidate?
    private var preparedGoogleBooksSpeechPreview:
        GoogleBooksPreparedSpeechPreview?
    private var googleBooksSpeechPreloadTask: Task<Void, Never>?
    private var googleBooksSpeechPreloadGeneration: UInt64 = 0
    private var continuousGoogleBooksSpeechHandoff:
        GoogleBooksSpeechContinuousHandoff?
    private var preparedGoogleBooksExplanation:
        GoogleBooksPreparedExplanation?
    private var googleBooksExplainPrefetchTask: Task<Void, Never>?
    private var continuousGoogleBooksHandoff: GoogleBooksContinuousHandoff?
    private var googleBooksContinuousSerial = 0
    private var googleBooksResumeReadAfterTurn = false
    private var googleBooksResumeExplainAfterTurn = false
    private var googleBooksRecoveryOwner: GoogleBooksTurnOwner?
    private var googleBooksRecoveryShouldResume = false
    private var googleBooksManualPageDidChange = false
    private var googleBooksManualTurnCompletedGate = false
    private var didAttemptGoogleBooksLocalRecovery = false
    private var googleBooksNetworkRetries = 0
    private var koboSessionRecoveryAttempts = 0
    private var koboSessionRecoveryTask: Task<Void, Never>?
    private var googleBooksReadinessRetries = 0
    private var googleBooksReadinessTask: Task<Void, Never>?
    private var googleBooksMainFrameWatchdogTask: Task<Void, Never>?
    private var googleBooksAwaitingReaderRecovery = false
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

    private struct GoogleBooksBoundaryTurn {
        let sourceFingerprint: String
        let cue: WeReadBoundaryAudioCue
        let sourceBoundaryUTF16End: Int
    }

    private struct GoogleBooksTurnIdentity: Equatable {
        let turnID: String
        /// Immutable wire baseline. Equivalent reflows retarget only the
        /// logical baseline used to identify the still-current page.
        let baselineSignature: String
        let originFrameSessionID: String

        var payload: [String: Any] {
            [
                "turnID": turnID,
                "baselineSignature": baselineSignature,
                "originFrameSessionID": originFrameSessionID,
            ]
        }
    }

    private struct GoogleBooksManualTurnIdentity: Equatable {
        let intentID: String
        let baselineSignature: String
        let originFrameSessionID: String

        var payload: [String: Any] {
            [
                "manualIntentID": intentID,
                "baselineSignature": baselineSignature,
                "originFrameSessionID": originFrameSessionID,
            ]
        }
    }

    private struct GoogleBooksLateTurn {
        let identity: GoogleBooksTurnIdentity
        var logicalBaselineSignature: String
        let owner: GoogleBooksTurnOwner
        let priorCursor: LiveWebPageConsumedCursor?
        let consumedCursor: LiveWebPageConsumedCursor?
        let boundaryTurn: GoogleBooksBoundaryTurn?
        var shouldResume: Bool
        let expiresAt: Date
    }

    private struct GoogleBooksCarryAdvance {
        let turn: GoogleBooksBoundaryTurn
        let segmentID: String
        let turnTime: Double
    }

    private struct GoogleBooksActiveCarry {
        let segmentID: String
        let startTime: Double
        let endTime: Double
        let paragraphIndex: Int
        let domUTF16Start: Int
        let domUTF16End: Int
        var lastPaintedDOMUTF16End: Int?
    }

    private struct GoogleBooksPagePreview {
        let sourceSignature: String
        let contentFingerprint: String
        let readPage: [ReadingParagraph]
        let explainPage: [ReadingParagraph]
        let language: String
        let preparedParagraphIndex: Int
        let preparedText: String
    }

    private struct GoogleBooksPreparedReadPage {
        let preview: GoogleBooksPagePreview
        let voiceID: String
        let segments: [AudioSegment]
    }

    private struct GoogleBooksPreparedSpeechPreview {
        let candidate: GoogleBooksSpeechPreviewCandidate
        let language: String
        let voiceID: String
        let segments: [AudioSegment]
    }

    private struct GoogleBooksPreparedExplanation {
        let preview: GoogleBooksPagePreview
        let payload: ExplainViewModel.PrefetchedFirstBlock
        let voiceID: String
        let depth: String
        let requestedLanguage: String
    }

    private struct GoogleBooksContinuousHandoff {
        let serial: Int
        let preview: GoogleBooksPagePreview
        let voiceID: String
        let segments: [AudioSegment]
        let segmentIDs: Set<String>
        let predecessorSegmentID: String
        let boundaryCue: WeReadBoundaryAudioCue?
        var issuedTurnIdentity: GoogleBooksTurnIdentity?
    }

    private struct GoogleBooksSpeechContinuousHandoff {
        let serial: Int
        let prepared: GoogleBooksPreparedSpeechPreview
        let segments: [AudioSegment]
        let segmentIDs: Set<String>
        let predecessorSegmentID: String
        let boundaryCue: WeReadBoundaryAudioCue?
        var issuedTurnIdentity: GoogleBooksTurnIdentity?
    }

    private struct GoogleBooksSpeechCommit {
        let prepared: GoogleBooksPreparedSpeechPreview
        let split: GoogleBooksSpeechPageSplit
        let rebasedSegments: [AudioSegment]
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

    func configure(
        expectsDynamicWebContent: Bool,
        isWeRead: Bool = false,
        livePlatform: LiveWebPlatformID? = nil,
        bookID: String = "",
        readerURL: String? = nil
    ) {
        self.expectsDynamicWebContent = expectsDynamicWebContent
        self.isWeRead = isWeRead
        self.livePlatform = livePlatform
        self.liveBookID = bookID
        self.oreillyBoundReaderHost = nil
        self.oreillyBoundContentID = nil
        if livePlatform == .oreilly,
           let usable = OReillyBookValidator.usableReaderURL(readerURL),
           let url = URL(string: usable),
           let host = url.host?.lowercased(),
           let contentID = OReillyBookValidator.contentID(from: url),
           bookID == OReillyBookValidator.stableID(contentID: contentID) {
            self.oreillyBoundReaderHost = host
            self.oreillyBoundContentID = contentID
        }
        self.koboSessionRecoveryAttempts = 0
        self.koboSessionRecoveryTask?.cancel()
        self.koboSessionRecoveryTask = nil
        // Reuse one native paging coordinator. Platform-specific DOM/actions
        // stay in the JavaScript adapter and URL/session behavior in profile.
        self.isGoogleBooks = livePlatform != nil
        self.isWeReadInitialPlaybackPending = isWeRead
        if isWeRead {
            // Baseline before WeRead touches the shared website data store.
            KindleSessionProbe.logCookies(reason: "weread-create")
        }
    }

    private func allowsLiveMainFrameNavigation(_ url: URL?) -> Bool {
        guard let livePlatform,
              livePlatform.allowsMainFrameNavigation(url) else {
            return false
        }
        guard livePlatform == .oreilly else { return true }
        guard let url,
              let expectedHost = oreillyBoundReaderHost,
              let expectedContentID = oreillyBoundContentID,
              url.host?.lowercased() == expectedHost,
              OReillyBookValidator.contentID(from: url)
                == expectedContentID else {
            return false
        }
        return true
    }

    private func allowsBoundOReillyFrame(
        _ frame: GoogleBooksScriptMessageFrame
    ) -> Bool {
        guard livePlatform == .oreilly else { return true }
        guard frame.isMainFrame,
              frame.securityHost.lowercased() == oreillyBoundReaderHost,
              let raw = frame.requestURL,
              allowsLiveMainFrameNavigation(URL(string: raw)) else {
            return false
        }
        return true
    }

    /// SwiftUI's geometry value is the authoritative native reader surface.
    /// Kobo needs it explicitly because its viewport resize arrives before the
    /// host's size-class callback, and its landscape player floats over the
    /// bottom of the WebView.
    func updateLiveWebViewport(
        surfaceSize: CGSize,
        bottomOcclusion: CGFloat
    ) {
        guard livePlatform != nil,
              surfaceSize.width > 1,
              surfaceSize.height > 1 else { return }
        let occlusion = max(
            0,
            min(bottomOcclusion, surfaceSize.height - 1)
        )
        let hadViewport = hasLiveWebViewport
        let changed = !hasLiveWebViewport
            || abs(liveWebSurfaceSize.width - surfaceSize.width) > 1
            || abs(liveWebSurfaceSize.height - surfaceSize.height) > 1
            || abs(liveWebBottomOcclusion - occlusion) > 1
        guard changed else { return }
        liveWebSurfaceSize = surfaceSize
        liveWebBottomOcclusion = occlusion
        hasLiveWebViewport = true
        if hadViewport, livePlatform?.needsViewportRelayout == true {
            onLiveWebNeedsLoadingCover?()
        }
        sendLiveWebViewport(reason: "surface-size")
    }

    private func sendLiveWebViewport(reason: String) {
        guard let livePlatform,
              livePlatform.needsViewportRelayout,
              hasLiveWebViewport else { return }
        ReaderRunLog.write(
            "\(livePlatform.logPrefix) viewport update reason=\(reason) " +
            "surface=\(Int(liveWebSurfaceSize.width))x" +
            "\(Int(liveWebSurfaceSize.height)) " +
            "bottom=\(Int(liveWebBottomOcclusion))"
        )
        call(
            "gbRelayout",
            [
                "reason": reason,
                "width": liveWebSurfaceSize.width,
                "height": liveWebSurfaceSize.height,
                "bottomOcclusion": liveWebBottomOcclusion,
            ]
        )
    }

    /// Native playback-bar page buttons are manual navigation, just like a
    /// swipe inside the reader. They must pause the old page immediately and
    /// let the existing stable-page transaction decide whether to restart the
    /// active Read/Explain mode after the new page commits.
    func requestUserPageTurn(_ direction: LiveWebPageTurnDirection) {
        guard didInit, isApplicationActive else {
            ReaderRunLog.write(
                "LIVEWEB page button ignored direction=\(direction.rawValue) " +
                "ready=\(didInit ? "Y" : "N") active=\(isApplicationActive ? "Y" : "N")"
            )
            return
        }
        if isWeRead {
            requestWeReadUserPage(direction)
            return
        }
        guard isGoogleBooks,
              activeGoogleBooksFrameSessionID != nil,
              !pendingGoogleBooksTurn,
              !pendingGoogleBooksManualTurn else {
            ReaderRunLog.write(
                "LIVEWEB page button unavailable direction=\(direction.rawValue) " +
                "auto=\(pendingGoogleBooksTurn ? "Y" : "N") " +
                "manual=\(pendingGoogleBooksManualTurn ? "Y" : "N")"
            )
            return
        }
        ReaderRunLog.write(
            "\(livePlatform?.logPrefix ?? "LIVEWEB") manual page button " +
            "direction=\(direction.rawValue) mode=\(isReadMode ? "read" : "explain")"
        )
        call("gbManualPage", ["direction": direction.rawValue])
    }

    func retryLiveWebReader() {
        guard let livePlatform,
              livePlatform.supportsReaderRetry,
              let webView else { return }
        livePlatform.clearReaderError()
        onLiveWebNeedsLoadingCover?()
        if livePlatform == .kobo {
            koboSessionRecoveryAttempts = 0
            beginKoboSessionRecovery(reason: "user-retry")
        } else {
            invalidateGoogleBooksLivePage(
                reason: "user-retry",
                clearConsumedCursor: false
            )
            webView.reloadFromOrigin()
        }
    }

    private func requestWeReadUserPage(
        _ direction: LiveWebPageTurnDirection
    ) {
        guard !pendingWeReadTurn,
              !pendingWeReadManualTurn,
              !pendingWeReadTOCJump,
              let webView else {
            ReaderRunLog.write(
                "WEREAD manual page button busy direction=\(direction.rawValue)"
            )
            return
        }

        // The ordinary DOM intent handler deliberately keeps a paused
        // explanation paused. Capture explicit native-button playback intent
        // before JavaScript posts that same manual intent so an actively
        // playing explanation follows the newly selected page.
        resumeReadAfterWeReadTurn =
            isReadMode
                && readVM?.shouldResumeAfterManualLivePageTurn == true
        resumeExplainAfterWeReadTurn =
            !isReadMode
                && explainVM?.shouldResumeAfterManualLivePageTurn == true
        // Lock before evaluateJavaScript returns. The JS intent message is
        // asynchronous; without this native-side claim, two fast taps can
        // both click the site's pager before the first message arrives.
        pendingWeReadManualTurn = true

        let script =
            "window.CastReaderWeRead && " +
            "window.CastReaderWeRead.userPage && " +
            "window.CastReaderWeRead.userPage('\(direction.rawValue)')"
        ReaderRunLog.write(
            "WEREAD manual page button direction=\(direction.rawValue) " +
            "read=\(resumeReadAfterWeReadTurn ? "Y" : "N") " +
            "explain=\(resumeExplainAfterWeReadTurn ? "Y" : "N")"
        )
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            guard error == nil, (value as? Bool) == true else {
                self.pendingWeReadManualTurn = false
                self.resumeReadAfterWeReadTurn = false
                self.resumeExplainAfterWeReadTurn = false
                ReaderRunLog.write(
                    "WEREAD manual page button rejected direction=\(direction.rawValue) " +
                    "error=\(error?.localizedDescription ?? "unavailable")"
                )
                return
            }
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

        if isGoogleBooks {
            // 一页读完 → 翻下一页 → 新页提交后继续播。朗读与解读共用同一条链路。
            readVM.onAppReviewReadSessionInvalidated = { [weak self] in
                self?.automaticAppReviewContinuation.cancel()
            }
            readVM.onDocumentFinished = { [weak self] appReviewContinuation in
                guard let self, self.isReadMode else { return }
                if let appReviewContinuation {
                    self.automaticAppReviewContinuation.arm(appReviewContinuation)
                }
                guard GoogleBooksAudioPageBoundaryContract
                    .canRequestPhysicalTurn(after: .documentFinished) else {
                    return
                }
                self.requestGoogleBooksNextPage()
            }
            readVM.onPageBoundaryApproaching = { [weak self] in
                self?.handleGoogleBooksPageBoundaryApproaching()
            }
            explainVM.onDocumentFinished = { [weak self] in
                guard let self, !self.isReadMode else { return }
                guard GoogleBooksAudioPageBoundaryContract
                    .canRequestPhysicalTurn(after: .documentFinished) else {
                    return
                }
                self.requestGoogleBooksNextPage()
            }
            readVM.$status
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.maybeStartGoogleBooksReadPreload()
                    self?.maybeStartGoogleBooksSpeechPreload()
                    self?.maybeArmGoogleBooksContinuousHandoff(
                        reason: "read-status"
                    )
                    self?.maybeArmGoogleBooksSpeechContinuousHandoff(
                        reason: "read-status"
                    )
                }
                .store(in: &cancellables)
            explainVM.$status
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.maybeStartGoogleBooksExplainPrefetch()
                }
                .store(in: &cancellables)
            explainVM.$currentBlockIndex
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.maybeStartGoogleBooksExplainPrefetch()
                }
                .store(in: &cancellables)
            AudioPlayerService.shared.$currentTime
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.updateGoogleBooksCarryHighlightIfNeeded()
                }
                .store(in: &cancellables)
            NotificationCenter.default.publisher(
                for: .castReaderPlaybackVoiceWillSwitch
            )
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.cancelGoogleBooksContinuousHandoff(
                        reason: "voice-switch"
                    )
                    self.cancelGoogleBooksSpeechContinuousHandoff(
                        reason: "voice-switch"
                    )
                    self.invalidateGoogleBooksReadPreload(
                        reason: "voice-switch",
                        preservePrediction: true
                    )
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
        // WebKit delivers script-message callbacks on its UI/main executor,
        // although the legacy Objective-C protocol is not concurrency
        // annotated. Make that boundary explicit before reading WKFrameInfo.
        MainActor.assumeIsolated { [weak self] in
            self?.receiveScriptMessage(message)
        }
    }

    private func receiveScriptMessage(_ message: WKScriptMessage) {
        let body = message.body
        let frameInfo = message.frameInfo
        let securityOrigin = frameInfo.securityOrigin
        let frame = GoogleBooksScriptMessageFrame(
            isMainFrame: frameInfo.isMainFrame,
            securityScheme: securityOrigin.protocol,
            securityHost: securityOrigin.host,
            securityPort: securityOrigin.port,
            requestURL: frameInfo.request.url?.absoluteString
        )
        let messageType = (body as? [String: Any])?["type"] as? String
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let platform = self.livePlatform,
               !platform.allowsScriptMessage(type: messageType, frame: frame) {
                let path = frame.requestURL.flatMap { URL(string: $0) }?.path ?? ""
                ReaderRunLog.write(
                    "\(platform.logPrefix) ignored bridge source main=\(frame.isMainFrame ? "Y" : "N") " +
                    "host=\(frame.securityHost.lowercased()) path=\(path) " +
                    "type=\(messageType ?? "")"
                )
                return
            }
            if !self.allowsBoundOReillyFrame(frame) {
                ReaderRunLog.write(
                    "OREILLY ignored bridge event outside bound book " +
                    "host=\(frame.securityHost.lowercased()) " +
                    "type=\(messageType ?? "")"
                )
                return
            }
            self.handle(body)
        }
    }

    private func handle(_ body: Any) {
        guard let msg = WebInboundMessage(body) else { return }
        switch msg.type {
        case "ready":
            print("[WebReader] ✅ JS ready: \(msg.payload)")
            sendLiveWebViewport(reason: "bridge-ready")
            restoreOReillyReadingAnchorIfPossible()
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
            if isGoogleBooks {
                guard GoogleBooksPageTurnContract.isReaderPagePayload(msg.payload) else {
                    ReaderRunLog.write("GBOOKS ignored auxiliary-frame rendered payload")
                    return
                }
                receiveGoogleBooksPage(msg.payload)
                return
            }
            let raw = msg.payload["paragraphs"] as? [[String: Any]] ?? []
            let paras = raw.compactMap { WebRenderedParagraph($0) }
            print("[WebReader] 📄 rendered paragraphs=\(paras.count)")
            receiveRendered(paras)
        case "googleBooksTurnRequested":
            guard acceptsActiveGoogleBooksFrameEvent(msg.payload) else { return }
            guard pendingGoogleBooksTurn,
                  googleBooksTurnIdentity(from: msg.payload)
                    == googleBooksTurnIdentity else {
                ReaderRunLog.write("GBOOKS ignored requested event with stale turn identity")
                return
            }
            ReaderRunLog.write(
                "GBOOKS turn requested method=\((msg.payload["method"] as? String) ?? "")"
            )
        case "googleBooksTurnFailed":
            guard acceptsActiveGoogleBooksFrameEvent(msg.payload) else { return }
            guard pendingGoogleBooksTurn,
                  googleBooksTurnIdentity(from: msg.payload)
                    == googleBooksTurnIdentity else {
                ReaderRunLog.write("GBOOKS ignored failure with stale turn identity")
                return
            }
            finishGoogleBooksTurn(
                reason: "javascript-no-change",
                preserveLateResult: (msg.payload["lateEligible"] as? Bool) != false
            )
        case "googleBooksPageChanging":
            guard acceptsActiveGoogleBooksFrameEvent(msg.payload) else { return }
            prepareForGoogleBooksPageChange(msg.payload)
        case "googleBooksPagePreview":
            guard acceptsActiveGoogleBooksFrameEvent(msg.payload) else { return }
            receiveGoogleBooksPagePreview(msg.payload)
        case "googleBooksSpeechPreview":
            guard acceptsActiveGoogleBooksFrameEvent(msg.payload) else { return }
            receiveGoogleBooksSpeechPreview(msg.payload)
        case "googleBooksPreviewDiagnostic":
            guard acceptsActiveGoogleBooksFrameEvent(msg.payload) else { return }
            receiveGoogleBooksPreviewDiagnostic(msg.payload)
        case "googleBooksLocation":
            guard acceptsActiveGoogleBooksFrameEvent(msg.payload) else { return }
            recordGoogleBooksLocation(
                (msg.payload["href"] as? String) ?? "",
                fingerprint:
                    (msg.payload["signature"] as? String)
                        ?? lastGoogleBooksSignature,
                payload: msg.payload
            )
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
            let message = "\(msg.payload["message"] ?? "")"
            NSLog("CRDBG JS %@", message)
            if let livePlatform {
                ReaderRunLog.write(
                    "\(livePlatform.logPrefix) JS \(String(message.prefix(800)))"
                )
            }
        case "error":
            if livePlatform == .kobo,
               (msg.payload["code"] as? String) == "missing-session" {
                handleKoboMissingSession()
                return
            }
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

        let liveWasReading =
            readVM?.shouldResumeAfterManualLivePageTurn == true
        let liveWasExplaining = !isReadMode &&
            explainVM?.shouldResumeAfterManualLivePageTurn == true
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
            let shouldResume =
                pendingWeReadTurn
                    || readVM?.shouldResumeAfterManualLivePageTurn == true
            resumeReadAfterWeReadTurn = resumeReadAfterWeReadTurn || shouldResume
            if shouldResume {
                readVM?.suspendForLiveWebTurnIntent()
            }
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
                if resumeExplainAfterWeReadTurn {
                    explainVM?.suspendForLiveWebTurnIntent()
                }
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
            let shouldResumeRead = self.resumeReadAfterWeReadTurn
            let shouldResumeExplain = self.resumeExplainAfterWeReadTurn
            self.pendingWeReadManualTurn = false
            self.suppressAppReviewContinuationForPendingTurn = false
            self.resumeReadAfterWeReadTurn = false
            self.resumeExplainAfterWeReadTurn = false
            if shouldResumeRead, self.isReadMode {
                self.readVM?.resumeAfterCancelledLiveWebTurnIntent()
            }
            if shouldResumeExplain, !self.isReadMode {
                self.explainVM?.resumeAfterCancelledLiveWebTurnIntent()
            }
            if self.isReadMode, let highlight = self.readVM?.webHighlight {
                self.pushHighlight(highlight)
            } else if !self.isReadMode, let explainVM = self.explainVM {
                self.shownMarkIds.removeAll()
                self.pushMarks(explainVM.activeMarks)
            }
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

    // MARK: - Google Play 图书（实时网页书库的分页循环）

    private struct GoogleBooksParsedPage {
        /// Read may extend the final visible slice to its natural sentence end.
        let paragraphs: [ReadingParagraph]
        /// Explain is strictly visible-page scoped so marks never target
        /// off-screen text that will be clipped from the following page.
        let explainParagraphs: [ReadingParagraph]
        let boundary: LiveWebPageSpeechBoundary?
        let nextCursor: LiveWebPageConsumedCursor?
        let evidence: GoogleBooksPageEvidence
        let language: String
        /// Final UTF-16 origin in the complete source `<p>` for every native
        /// paragraph after cross-page clipping and whitespace trimming.
        let readDOMCharacterOffsets: [Int]
        /// Native paragraph ids normally equal DOM paragraph ids. An exact
        /// source-speech split can alias two native paragraphs to one DOM `<p>`.
        let readDOMParagraphIndices: [Int]
        /// Exact source coordinates retained only for commit-time verification
        /// of a speculative source-speech sentence.
        let sourceSlices: [LiveWebPageSourceSlice]
        /// Explain describes the complete visible page, even when Read has
        /// already spoken a prefix as cross-page carry audio.
        let explainDOMCharacterOffsets: [Int]
        /// Absolute source coordinate of the visual edge that caused Read to
        /// extend the last visible slice to a natural sentence ending.
        let boundarySourceVisibleEnd: Int?
        let carryParagraphIndex: Int?
        let carryUTF16Length: Int
        let carryDOMUTF16Start: Int?
    }

    /// JS 已把可见区裁剪好，这里只做两件 native 该做的事：
    /// 裁掉上一页跨页多读的前缀，以及把末段延长到句末交给 TTS。
    private func parseGoogleBooksPage(_ payload: [String: Any]) -> GoogleBooksParsedPage? {
        parseGoogleBooksPage(
            payload,
            consumedCursor: googleBooksConsumedCursor
        )
    }

    /// Preview parsing is deliberately pure: it can model the cursor that will
    /// be promoted after natural completion without changing ownership of the
    /// currently visible page.
    private func parseGoogleBooksPage(
        _ payload: [String: Any],
        consumedCursor: LiveWebPageConsumedCursor?
    ) -> GoogleBooksParsedPage? {
        let raw = payload["paragraphs"] as? [[String: Any]] ?? []
        guard !raw.isEmpty else { return nil }

        let slices = raw.enumerated().map { index, item in
            LiveWebPageSourceSlice(
                visibleParagraphIndex: index,
                sourceParagraphIndex: Self.double(item["sourceParagraphIndex"]).map { Int($0) },
                sourceUTF16Start: Self.double(item["sourceUTF16Start"]).map { Int($0) },
                sourceUTF16End: Self.double(item["sourceUTF16End"]).map { Int($0) },
                text: (item["text"] as? String) ?? ""
            )
        }
        let consumption = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: slices,
            through: consumedCursor
        )
        var texts = consumption.texts
        let explainParagraphs = slices.map(\.text).enumerated().map {
            ReadingParagraph(id: $0.offset, text: $0.element, type: .paragraph)
        }
        let readDOMCharacterOffsets = GoogleBooksCrossPageContract.domCharacterOffsets(
            in: slices,
            through: consumedCursor
        )
        let explainDOMCharacterOffsets = slices.map {
            max(0, $0.sourceUTF16Start ?? 0)
        }

        var boundary: LiveWebPageSpeechBoundary?
        var boundarySourceVisibleEnd: Int?
        // If this visual page is wholly inside the sentence already spoken by
        // the previous page, retain the source cursor while advancing again.
        // Dropping it here would make a three-page paragraph repeat.
        var nextCursor = GoogleBooksCrossPageContract.retainedCursor(
            previous: consumedCursor,
            carryParagraphIndex: consumption.carryParagraphIndex
        )
        if let lastIndex = texts.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            let item = raw[lastIndex]
            let sourceStart = Int(Self.double(item["sourceUTF16Start"]) ?? 0)
            let sourceParagraphIndex =
                Self.double(item["sourceParagraphIndex"]).map { Int($0) }
            let speechOrigin = Int(Self.double(item["speechUTF16Start"]) ?? Double(sourceStart))
            if let rawSpeech = item["speechText"] as? String, !rawSpeech.isEmpty {
                let speech = GoogleBooksCrossPageContract.remainingSpeechText(
                    rawSpeech,
                    sourceUTF16Start: speechOrigin,
                    domCharacterOffset: readDOMCharacterOffsets[lastIndex],
                    sourceParagraphIndex: sourceParagraphIndex,
                    consumedCursor: consumedCursor
                )
                let visible = (texts[lastIndex] as NSString).length
                if !speech.isEmpty,
                   speech.hasPrefix(texts[lastIndex]),
                   (speech as NSString).length > visible {
                    texts[lastIndex] = speech
                    let candidate = LiveWebPageSpeechBoundary(
                        paragraphIndex: lastIndex,
                        visibleUTF16Offset: visible,
                        speechUTF16Length: (speech as NSString).length,
                        sourceParagraphIndex: sourceParagraphIndex,
                        sourceSpeechEnd: Self.double(item["sourceSpeechEnd"]).map { Int($0) }
                    )
                    if candidate.isCrossPage {
                        boundary = candidate
                        boundarySourceVisibleEnd =
                            Self.double(item["sourceUTF16End"]).map { Int($0) }
                                ?? candidate.sourceSpeechEnd.map {
                                    $0 - (
                                        candidate.speechUTF16Length
                                            - candidate.visibleUTF16Offset
                                    )
                                }
                        nextCursor = candidate.sourceParagraphIndex.flatMap { sourceParagraphIndex in
                            if let sourceSpeechEnd = candidate.sourceSpeechEnd {
                                return LiveWebPageConsumedCursor(
                                    sourceParagraphIndex: sourceParagraphIndex,
                                    sourceUTF16End: sourceSpeechEnd
                                )
                            }
                            return GoogleBooksCrossPageContract.consumedCursor(
                                boundary: candidate,
                                sourceParagraphIndex: sourceParagraphIndex,
                                sourceVisibleEnd: Self.double(item["sourceUTF16End"]).map { Int($0) }
                            )
                        }
                    }
                }
            }
        }

        // 空段落保留占位：DOM 的 data-cr-para 下标必须与这里的 id 一一对应，
        // 否则跨页裁剪之后所有高亮/mark 都会错行。
        let paragraphs = texts.enumerated().map {
            ReadingParagraph(id: $0.offset, text: $0.element, type: .paragraph)
        }
        let spoken = paragraphs.map(\.text).joined(separator: " ")
        let visibleSpoken = explainParagraphs.map(\.text).joined(separator: " ")
        let language = LanguageDetector.detect(String(spoken.prefix(1200)))
        return GoogleBooksParsedPage(
            paragraphs: paragraphs,
            explainParagraphs: explainParagraphs,
            boundary: boundary,
            nextCursor: nextCursor,
            evidence: GoogleBooksPageEvidence(
                signature: (payload["signature"] as? String) ?? "",
                contentFingerprint: String(visibleSpoken.prefix(120)),
                paragraphCount: paragraphs.count
            ),
            language: language,
            readDOMCharacterOffsets: readDOMCharacterOffsets,
            readDOMParagraphIndices: Array(paragraphs.indices),
            sourceSlices: slices,
            explainDOMCharacterOffsets: explainDOMCharacterOffsets,
            boundarySourceVisibleEnd: boundarySourceVisibleEnd,
            carryParagraphIndex: consumption.carryParagraphIndex,
            carryUTF16Length: consumption.carryUTF16Length,
            carryDOMUTF16Start: consumption.carryParagraphIndex.flatMap { index in
                guard slices.indices.contains(index) else { return nil }
                return slices[index].sourceUTF16Start
            }
        )
    }

    /// Resolve a prepared source sentence against the actual committed page.
    /// This is the authorization point: preparation alone never changes native
    /// paragraph ids or makes speculative audio audible.
    private func makeGoogleBooksSpeechCommit(
        parsed: GoogleBooksParsedPage,
        previousSignature: String,
        turnOriginFrameSessionID: String
    ) -> (page: GoogleBooksParsedPage, commit: GoogleBooksSpeechCommit)? {
        guard isReadMode,
              let activeFrameSessionID =
                activeGoogleBooksFrameSessionID,
              turnOriginFrameSessionID == activeFrameSessionID,
              let prepared =
                preparedGoogleBooksSpeechPreview,
              prepared.candidate.originFrameSessionID
                == turnOriginFrameSessionID,
              prepared.candidate.sourceSignature
                == previousSignature,
              !prepared.segments.isEmpty else {
            return nil
        }
        let selectedVoice =
            AppSettings.shared.voice(for: parsed.language)
        guard prepared.voiceID == selectedVoice,
              let split =
                GoogleBooksSpeechPreloadContract.splitCommittedPage(
                    candidate: prepared.candidate,
                    previousSignature: previousSignature,
                    activeFrameSessionID: activeFrameSessionID,
                    sourceSlices: parsed.sourceSlices,
                    paragraphs: parsed.paragraphs.map(\.text),
                    domCharacterOffsets:
                        parsed.readDOMCharacterOffsets
                ) else {
            return nil
        }

        let shift = split.insertedRemainder ? 1 : 0
        func shiftedIndex(_ index: Int) -> Int {
            index > split.splitOriginalParagraphIndex
                ? index + shift
                : index
        }
        let adjustedBoundary:
            LiveWebPageSpeechBoundary? = {
            guard let boundary = parsed.boundary else {
                return nil
            }
            guard boundary.paragraphIndex
                    == split.splitOriginalParagraphIndex,
                  split.insertedRemainder else {
                return LiveWebPageSpeechBoundary(
                    paragraphIndex:
                        shiftedIndex(boundary.paragraphIndex),
                    visibleUTF16Offset:
                        boundary.visibleUTF16Offset,
                    speechUTF16Length:
                        boundary.speechUTF16Length,
                    sourceParagraphIndex:
                        boundary.sourceParagraphIndex,
                    sourceSpeechEnd: boundary.sourceSpeechEnd
                )
            }
            let removed =
                split.prefixUTF16Length
                    + split
                        .remainderLeadingWhitespaceUTF16Length
            let candidate = LiveWebPageSpeechBoundary(
                paragraphIndex:
                    split.splitOriginalParagraphIndex + 1,
                visibleUTF16Offset:
                    max(0, boundary.visibleUTF16Offset - removed),
                speechUTF16Length:
                    max(0, boundary.speechUTF16Length - removed),
                sourceParagraphIndex:
                    boundary.sourceParagraphIndex,
                sourceSpeechEnd: boundary.sourceSpeechEnd
            )
            return candidate.isCrossPage ? candidate : nil
        }()

        var splitSlices: [LiveWebPageSourceSlice] = []
        splitSlices.reserveCapacity(split.paragraphs.count)
        for index in parsed.sourceSlices.indices {
            let source = parsed.sourceSlices[index]
            guard index == split.splitOriginalParagraphIndex else {
                splitSlices.append(source)
                continue
            }
            splitSlices.append(
                LiveWebPageSourceSlice(
                    visibleParagraphIndex:
                        splitSlices.count,
                    sourceParagraphIndex:
                        prepared.candidate
                            .sourceParagraphIndex,
                    sourceUTF16Start:
                        prepared.candidate.sourceUTF16Start,
                    sourceUTF16End:
                        prepared.candidate.sourceUTF16End,
                    text: prepared.candidate.text
                )
            )
            if split.insertedRemainder {
                let remainderIndex = splitSlices.count
                splitSlices.append(
                    LiveWebPageSourceSlice(
                        visibleParagraphIndex: remainderIndex,
                        sourceParagraphIndex:
                            source.sourceParagraphIndex,
                        sourceUTF16Start:
                            split.domCharacterOffsets[
                                remainderIndex
                            ],
                        sourceUTF16End:
                            source.sourceUTF16End,
                        text: split.paragraphs[
                            remainderIndex
                        ]
                    )
                )
            }
        }
        // Rebase untouched slices after an inserted remainder to their native
        // page-local ids. Source coordinates and text remain exact.
        splitSlices = splitSlices.enumerated().map { index, slice in
            LiveWebPageSourceSlice(
                visibleParagraphIndex: index,
                sourceParagraphIndex:
                    slice.sourceParagraphIndex,
                sourceUTF16Start: slice.sourceUTF16Start,
                sourceUTF16End: slice.sourceUTF16End,
                text: slice.text
            )
        }

        let page = GoogleBooksParsedPage(
            paragraphs: split.paragraphs.enumerated().map {
                ReadingParagraph(
                    id: $0.offset,
                    text: $0.element,
                    type: .paragraph
                )
            },
            explainParagraphs: parsed.explainParagraphs,
            boundary: adjustedBoundary,
            nextCursor: parsed.nextCursor,
            evidence: GoogleBooksPageEvidence(
                signature: parsed.evidence.signature,
                contentFingerprint:
                    parsed.evidence.contentFingerprint,
                paragraphCount: split.paragraphs.count
            ),
            language: parsed.language,
            readDOMCharacterOffsets:
                split.domCharacterOffsets,
            readDOMParagraphIndices:
                split.domParagraphIndices,
            sourceSlices: splitSlices,
            explainDOMCharacterOffsets:
                parsed.explainDOMCharacterOffsets,
            boundarySourceVisibleEnd:
                parsed.boundarySourceVisibleEnd,
            carryParagraphIndex:
                parsed.carryParagraphIndex.map(shiftedIndex),
            carryUTF16Length: parsed.carryUTF16Length,
            carryDOMUTF16Start:
                parsed.carryDOMUTF16Start
        )
        let rebased = rebaseGoogleBooksSpeechSegments(
            prepared.segments,
            paragraphIndex: split.preparedParagraphIndex
        )
        return (
            page,
            GoogleBooksSpeechCommit(
                prepared: prepared,
                split: split,
                rebasedSegments: rebased
            )
        )
    }

    /// Google keeps a nearby CSS column in the reader DOM on many layouts.
    /// JavaScript observes that column without moving the viewport and sends
    /// it here as speculation. Parsing uses the cursor that *would* be promoted
    /// after natural completion, while the live cursor and page stay untouched.
    private func receiveGoogleBooksPagePreview(_ payload: [String: Any]) {
        let sourceSignature = (payload["sourceSignature"] as? String) ?? ""
        let contentFingerprint = (payload["contentFingerprint"] as? String) ?? ""
        guard isGoogleBooks,
              !sourceSignature.isEmpty,
              sourceSignature == lastGoogleBooksSignature,
              !contentFingerprint.isEmpty,
              !pendingGoogleBooksTurn,
              !pendingGoogleBooksManualTurn,
              let parsed = parseGoogleBooksPage(
                  payload,
                  consumedCursor: googleBooksPageCompletionCursor
              ) else { return }

        // A geometry preview describes the complete next visual page and is
        // strictly stronger than the one-sentence source fallback. Never keep
        // both speculative suffixes attached to the shared audio queue.
        cancelGoogleBooksSpeechContinuousHandoff(
            reason: "geometry-preview-available"
        )
        invalidateGoogleBooksSpeechPreload(
            reason: "geometry-preview-available",
            preserveCandidate: false
        )

        guard let preparedInput = parsed.paragraphs.first(where: {
            SpeechTextSanitizer.containsSpeakableContent($0.text)
        }) else { return }
        let preview = GoogleBooksPagePreview(
            sourceSignature: sourceSignature,
            contentFingerprint: contentFingerprint,
            readPage: parsed.paragraphs,
            explainPage: parsed.explainParagraphs,
            language: parsed.language,
            preparedParagraphIndex: preparedInput.id,
            preparedText: preparedInput.text
        )
        if pendingGoogleBooksPagePreview?.sourceSignature != sourceSignature ||
            pendingGoogleBooksPagePreview?.contentFingerprint != contentFingerprint {
            cancelGoogleBooksContinuousHandoff(reason: "prediction-changed")
            invalidateGoogleBooksReadPreload(
                reason: "prediction-changed",
                preservePrediction: false
            )
            invalidateGoogleBooksExplainPrefetch(
                reason: "prediction-changed"
            )
        }
        pendingGoogleBooksPagePreview = preview
        ReaderRunLog.write(
            "GBOOKS preload preview source=\(String(sourceSignature.prefix(12))) " +
            "next=\(String(contentFingerprint.prefix(12))) paras=\(parsed.paragraphs.count)"
        )
        maybeStartGoogleBooksReadPreload()
        maybeStartGoogleBooksExplainPrefetch()
    }

    /// Geometry can legitimately miss before Google materializes the adjacent
    /// CSS column. The reader frame may then expose exactly one natural sentence
    /// from the same immutable source stream. This handler authorizes only the
    /// currently-owned frame and committed source page; the exact coordinates
    /// and text are checked again against the real next page at commit time.
    private func receiveGoogleBooksSpeechPreview(
        _ payload: [String: Any]
    ) {
        guard isGoogleBooks,
              didInit,
              !pendingGoogleBooksTurn,
              !pendingGoogleBooksManualTurn,
              !googleBooksAwaitingReaderRecovery,
              pendingGoogleBooksPagePreview == nil,
              preparedGoogleBooksReadPage == nil,
              continuousGoogleBooksHandoff == nil,
              let activeFrameSessionID =
                activeGoogleBooksFrameSessionID,
              let sourceSignature =
                Self.nonemptyGoogleBooksString(
                    payload["sourceSignature"]
                ),
              let originFrameSessionID =
                Self.nonemptyGoogleBooksString(
                    payload["originFrameSessionID"]
                ),
              let contentFingerprint =
                Self.nonemptyGoogleBooksString(
                    payload["contentFingerprint"]
                ),
              let sourceParagraphIndex =
                Self.exactNonnegativeInteger(
                    payload["sourceParagraphIndex"]
                ),
              let sourceUTF16Start =
                Self.exactNonnegativeInteger(
                    payload["sourceUTF16Start"]
                ),
              let sourceUTF16End =
                Self.exactNonnegativeInteger(
                    payload["sourceUTF16End"]
                ),
              let text = payload["text"] as? String else {
            ReaderRunLog.write(
                "GBOOKS speech preview rejected reason=state-or-schema"
            )
            return
        }
        let candidate = GoogleBooksSpeechPreviewCandidate(
            sourceSignature: sourceSignature,
            originFrameSessionID: originFrameSessionID,
            contentFingerprint: contentFingerprint,
            sourceParagraphIndex: sourceParagraphIndex,
            sourceUTF16Start: sourceUTF16Start,
            sourceUTF16End: sourceUTF16End,
            text: text
        )
        guard GoogleBooksSpeechPreloadContract.canPrepare(
            candidate: candidate,
            exactText: payload["exactText"] as? Bool == true,
            currentSourceSignature: lastGoogleBooksSignature,
            activeFrameSessionID: activeFrameSessionID
        ) else {
            ReaderRunLog.write(
                "GBOOKS speech preview rejected reason=authorization-or-coordinate " +
                "source=\(String(sourceSignature.prefix(12)))"
            )
            return
        }
        if pendingGoogleBooksSpeechPreview == candidate ||
            preparedGoogleBooksSpeechPreview?.candidate == candidate {
            return
        }
        cancelGoogleBooksSpeechContinuousHandoff(
            reason: "speech-prediction-changed"
        )
        invalidateGoogleBooksSpeechPreload(
            reason: "speech-prediction-changed",
            preserveCandidate: false
        )
        pendingGoogleBooksSpeechPreview = candidate
        ReaderRunLog.write(
            "GBOOKS speech preview accepted " +
            "source=\(String(sourceSignature.prefix(12))) " +
            "fingerprint=\(contentFingerprint) " +
            "sourcePara=\(sourceParagraphIndex) " +
            "range=\(sourceUTF16Start)-\(sourceUTF16End)"
        )
        maybeStartGoogleBooksSpeechPreload()
    }

    /// Diagnostics are metadata-only and pass through the same active-frame and
    /// source-signature fence as content previews. Never log preview text.
    private func receiveGoogleBooksPreviewDiagnostic(
        _ payload: [String: Any]
    ) {
        guard let event =
                Self.nonemptyGoogleBooksString(payload["event"]),
              event == "geometry-miss" || event == "source-preview",
              let sourceSignature =
                Self.nonemptyGoogleBooksString(
                    payload["sourceSignature"]
                ),
              sourceSignature == lastGoogleBooksSignature else {
            return
        }
        let attempt =
            Self.exactNonnegativeInteger(payload["attempt"]) ?? 0
        let fingerprint =
            Self.nonemptyGoogleBooksString(
                payload["contentFingerprint"]
            ) ?? "-"
        ReaderRunLog.write(
            "GBOOKS preview diagnostic event=\(event) " +
            "source=\(String(sourceSignature.prefix(12))) " +
            "attempt=\(min(attempt, 99_999)) " +
            "fingerprint=\(String(fingerprint.prefix(12)))"
        )
    }

    private func maybeStartGoogleBooksSpeechPreload() {
        guard isGoogleBooks,
              isReadMode,
              didInit,
              let readVM,
              readVM.isActive,
              !pendingGoogleBooksTurn,
              !pendingGoogleBooksManualTurn,
              !googleBooksAwaitingReaderRecovery,
              pendingGoogleBooksPagePreview == nil,
              preparedGoogleBooksReadPage == nil,
              continuousGoogleBooksHandoff == nil,
              let candidate = pendingGoogleBooksSpeechPreview,
              candidate.sourceSignature == lastGoogleBooksSignature,
              candidate.originFrameSessionID
                == activeGoogleBooksFrameSessionID else {
            return
        }
        // The visible page always owns network priority until its first audio
        // item is playable. A speculative next-page request that starts first
        // can double the user's initial wait on constrained mobile networks.
        if readVM.isWaitingForPlayableAudio {
            if googleBooksSpeechPreloadTask != nil {
                invalidateGoogleBooksSpeechPreload(
                    reason: "foreground-first-audio",
                    preserveCandidate: true
                )
            }
            return
        }
        let language = lastGoogleBooksLanguage.isEmpty
            ? LanguageDetector.detect(candidate.text)
            : lastGoogleBooksLanguage
        let voiceID = AppSettings.shared.voice(for: language)
        if let prepared = preparedGoogleBooksSpeechPreview {
            if prepared.candidate == candidate,
               prepared.language == language,
               prepared.voiceID == voiceID {
                maybeArmGoogleBooksSpeechContinuousHandoff(
                    reason: "prepared-cache"
                )
                return
            }
            invalidateGoogleBooksSpeechPreload(
                reason: "speech-settings-changed",
                preserveCandidate: true
            )
        }
        guard googleBooksSpeechPreloadTask == nil else { return }

        googleBooksSpeechPreloadGeneration &+= 1
        let generation = googleBooksSpeechPreloadGeneration
        let token = [
            candidate.sourceSignature,
            candidate.originFrameSessionID,
            candidate.contentFingerprint,
            voiceID,
        ].joined(separator: "|")
        ReaderRunLog.write(
            "GBOOKS speech preload start " +
            "source=\(String(candidate.sourceSignature.prefix(12))) " +
            "fingerprint=\(candidate.contentFingerprint) voice=\(voiceID)"
        )
        googleBooksSpeechPreloadTask = Task { [weak self] in
            do {
                let segments =
                    try await TTSService.shared.generatePrefetchSegments(
                        paragraphIndex: 0,
                        text: candidate.text,
                        voice: voiceID,
                        speed: 1.0,
                        language: language
                    )
                try Task.checkCancellation()
                guard let self,
                      self.googleBooksSpeechPreloadGeneration
                        == generation else {
                    return
                }
                self.googleBooksSpeechPreloadTask = nil
                let selectedVoice =
                    AppSettings.shared.voice(for: language)
                let currentToken =
                    self.pendingGoogleBooksSpeechPreview.map {
                        [
                            $0.sourceSignature,
                            $0.originFrameSessionID,
                            $0.contentFingerprint,
                            selectedVoice,
                        ].joined(separator: "|")
                    }
                guard !segments.isEmpty,
                      token == currentToken,
                      self.pendingGoogleBooksPagePreview == nil,
                      self.isCurrentGoogleBooksPredictionSource(
                        candidate.sourceSignature
                      ) else {
                    self.maybeStartGoogleBooksSpeechPreload()
                    return
                }
                self.preparedGoogleBooksSpeechPreview =
                    GoogleBooksPreparedSpeechPreview(
                        candidate: candidate,
                        language: language,
                        voiceID: voiceID,
                        segments: segments
                    )
                ReaderRunLog.write(
                    "GBOOKS speech preload ready " +
                    "source=\(String(candidate.sourceSignature.prefix(12))) " +
                    "fingerprint=\(candidate.contentFingerprint) " +
                    "voice=\(voiceID) segs=\(segments.count)"
                )
                self.maybeArmGoogleBooksSpeechContinuousHandoff(
                    reason: "preload-ready"
                )
            } catch is CancellationError {
                guard let self,
                      self.googleBooksSpeechPreloadGeneration
                        == generation else {
                    return
                }
                self.googleBooksSpeechPreloadTask = nil
            } catch {
                guard let self,
                      self.googleBooksSpeechPreloadGeneration
                        == generation else {
                    return
                }
                self.googleBooksSpeechPreloadTask = nil
                ReaderRunLog.write(
                    "GBOOKS speech preload failed " +
                    "error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func maybeStartGoogleBooksReadPreload() {
        guard isGoogleBooks,
              isReadMode,
              didInit,
              let readVM,
              readVM.isActive,
              continuousGoogleBooksHandoff == nil,
              !pendingGoogleBooksTurn,
              !pendingGoogleBooksManualTurn,
              let preview = pendingGoogleBooksPagePreview,
              preview.sourceSignature == lastGoogleBooksSignature else { return }

        if readVM.isWaitingForPlayableAudio {
            if googleBooksReadPreloadTask != nil {
                invalidateGoogleBooksReadPreload(
                    reason: "foreground-first-audio",
                    preservePrediction: true
                )
            }
            return
        }
        let voiceID = AppSettings.shared.voice(for: preview.language)
        if let prepared = preparedGoogleBooksReadPage {
            if prepared.preview.sourceSignature == preview.sourceSignature,
               prepared.preview.contentFingerprint == preview.contentFingerprint,
               prepared.voiceID == voiceID {
                maybeArmGoogleBooksContinuousHandoff(
                    reason: "prepared-cache"
                )
                return
            }
            preparedGoogleBooksReadPage = nil
        }
        guard googleBooksReadPreloadTask == nil else { return }

        googleBooksPreloadGeneration &+= 1
        let generation = googleBooksPreloadGeneration
        let token =
            "\(preview.sourceSignature)|\(preview.contentFingerprint)|\(voiceID)"
        googleBooksReadPreloadTask = Task { [weak self] in
            do {
                let segments = try await TTSService.shared.generatePrefetchSegments(
                    paragraphIndex: preview.preparedParagraphIndex,
                    text: preview.preparedText,
                    voice: voiceID,
                    speed: 1.0,
                    language: preview.language
                )
                try Task.checkCancellation()
                guard let self,
                      self.googleBooksPreloadGeneration == generation else {
                    return
                }
                self.googleBooksReadPreloadTask = nil
                let selectedVoice = AppSettings.shared.voice(for: preview.language)
                let currentToken = self.pendingGoogleBooksPagePreview.map {
                    "\($0.sourceSignature)|\($0.contentFingerprint)|\(selectedVoice)"
                }
                guard !segments.isEmpty else { return }
                guard token == currentToken else {
                    self.maybeStartGoogleBooksReadPreload()
                    return
                }
                guard self.isCurrentGoogleBooksPredictionSource(
                    preview.sourceSignature
                ) else { return }
                self.preparedGoogleBooksReadPage = GoogleBooksPreparedReadPage(
                    preview: preview,
                    voiceID: voiceID,
                    segments: segments
                )
                ReaderRunLog.write(
                    "GBOOKS preload audio ready source=\(String(preview.sourceSignature.prefix(12))) " +
                    "next=\(String(preview.contentFingerprint.prefix(12))) voice=\(voiceID) " +
                    "segs=\(segments.count)"
                )
                self.maybeArmGoogleBooksContinuousHandoff(
                    reason: "preload-ready"
                )
            } catch is CancellationError {
                guard let self,
                      self.googleBooksPreloadGeneration == generation else {
                    return
                }
                self.googleBooksReadPreloadTask = nil
            } catch {
                guard let self,
                      self.googleBooksPreloadGeneration == generation else {
                    return
                }
                self.googleBooksReadPreloadTask = nil
                ReaderRunLog.write(
                    "GBOOKS preload audio failed error=\(error.localizedDescription)"
                )
            }
        }
    }

    /// Prepare the next page's QuickRead plan, first narration block, audio,
    /// and marks while the current explanation is still playing. Unlike Read,
    /// this payload is adopted only after the visible Google page commits.
    private func maybeStartGoogleBooksExplainPrefetch() {
        guard isGoogleBooks,
              !isReadMode,
              didInit,
              !pendingGoogleBooksTurn,
              !pendingGoogleBooksManualTurn,
              let vm = explainVM,
              vm.isActive,
              vm.status.isActive,
              vm.currentBlockIndex >= 0,
              let preview = pendingGoogleBooksPagePreview,
              preview.sourceSignature == lastGoogleBooksSignature else {
            return
        }

        let settings = AppSettings.shared
        let depth = settings.explainDepth
        let requestedLanguage = settings.explainLanguage
        if let prepared = preparedGoogleBooksExplanation {
            let selectedVoice = settings.voice(
                for: prepared.payload.outputLanguage
            )
            if prepared.preview.sourceSignature
                    == preview.sourceSignature,
               prepared.preview.contentFingerprint
                    == preview.contentFingerprint,
               prepared.voiceID == selectedVoice,
               prepared.depth == depth,
               prepared.requestedLanguage == requestedLanguage {
                return
            }
            invalidateGoogleBooksExplainPrefetch(
                reason: "settings-or-preview-changed"
            )
        }
        guard ProManager.shared.isPro,
              googleBooksExplainPrefetchTask == nil else { return }

        let token = [
            preview.sourceSignature,
            preview.contentFingerprint,
            requestedLanguage,
            depth,
        ].joined(separator: "|")
        let target = ReadingDocument(
            id: vm.document.id,
            title: vm.document.title,
            sourceKind: vm.document.sourceKind,
            language: preview.language,
            paragraphs: preview.explainPage,
            sourceURL: vm.document.sourceURL
        )
        let previousSummary = vm.currentContinuitySummary()
        ReaderRunLog.write(
            "GBOOKS explain preload start " +
            "source=\(String(preview.sourceSignature.prefix(12))) " +
            "next=\(String(preview.contentFingerprint.prefix(12))) " +
            "paras=\(preview.explainPage.count)"
        )
        googleBooksExplainPrefetchTask = Task { [weak self] in
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
                    self.pendingGoogleBooksPagePreview?.sourceSignature ?? "",
                    self.pendingGoogleBooksPagePreview?.contentFingerprint
                        ?? "",
                    currentSettings.explainLanguage,
                    currentSettings.explainDepth,
                ].joined(separator: "|")
                guard token == currentToken,
                      self.isCurrentGoogleBooksPredictionSource(
                        preview.sourceSignature
                      ) else {
                    self.googleBooksExplainPrefetchTask = nil
                    return
                }
                let voiceID = currentSettings.voice(
                    for: payload.outputLanguage
                )
                self.preparedGoogleBooksExplanation =
                    GoogleBooksPreparedExplanation(
                        preview: preview,
                        payload: payload,
                        voiceID: voiceID,
                        depth: depth,
                        requestedLanguage: requestedLanguage
                    )
                self.googleBooksExplainPrefetchTask = nil
                ReaderRunLog.write(
                    "GBOOKS explain preload ready " +
                    "source=\(String(preview.sourceSignature.prefix(12))) " +
                    "next=\(String(preview.contentFingerprint.prefix(12))) " +
                    "blocks=\(payload.totalBlocks)"
                )
            } catch is CancellationError {
                self.googleBooksExplainPrefetchTask = nil
            } catch {
                self.googleBooksExplainPrefetchTask = nil
                ReaderRunLog.write(
                    "GBOOKS explain preload miss " +
                    "error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func consumeGoogleBooksExplainPrefetch(
        sourceSignature: String,
        visibleParagraphs: [ReadingParagraph]
    ) -> ExplainViewModel.PrefetchedFirstBlock? {
        guard let prepared = preparedGoogleBooksExplanation else {
            invalidateGoogleBooksExplainPrefetch(
                reason: "page-commit-miss"
            )
            return nil
        }
        defer {
            invalidateGoogleBooksExplainPrefetch(
                reason: "page-commit-consumed"
            )
        }
        let settings = AppSettings.shared
        let selectedVoice = settings.voice(
            for: prepared.payload.outputLanguage
        )
        let canConsume =
            GoogleBooksExplainPagePrefetchContract.canConsume(
                sourceSignature: prepared.preview.sourceSignature,
                previousSignature: sourceSignature,
                predictedContentFingerprint:
                    prepared.preview.contentFingerprint,
                payloadTextFingerprint:
                    prepared.payload.textFingerprint,
                predictedParagraphs:
                    prepared.preview.explainPage.map(\.text),
                visibleParagraphs: visibleParagraphs.map(\.text),
                preparedVoiceID: prepared.voiceID,
                selectedVoiceID: selectedVoice,
                preparedDepth: prepared.depth,
                selectedDepth: settings.explainDepth,
                requestedLanguage: prepared.requestedLanguage,
                selectedLanguage: settings.explainLanguage
            )
        ReaderRunLog.write(
            "GBOOKS explain preload consume " +
            "next=\(String(prepared.preview.contentFingerprint.prefix(12))) " +
            "hit=\(canConsume ? "Y" : "N")"
        )
        return canConsume ? prepared.payload : nil
    }

    private func invalidateGoogleBooksExplainPrefetch(reason: String) {
        googleBooksExplainPrefetchTask?.cancel()
        googleBooksExplainPrefetchTask = nil
        preparedGoogleBooksExplanation = nil
        ReaderRunLog.write(
            "GBOOKS explain preload invalidated reason=\(reason)"
        )
    }

    /// Put the predicted first utterance directly behind the current page's
    /// queue. It remains inaudible behind a fail-closed gate until the exact
    /// Google turn identity and visible full-page text have committed.
    private func maybeArmGoogleBooksContinuousHandoff(reason: String) {
        guard continuousGoogleBooksHandoff == nil,
              isGoogleBooks,
              isReadMode,
              didInit,
              !pendingGoogleBooksTurn,
              !pendingGoogleBooksManualTurn,
              googleBooksFailedTurnSignature != lastGoogleBooksSignature,
              let vm = readVM,
              vm.isActive,
              vm.canContinueAcrossLivePageBoundary,
              let prepared = preparedGoogleBooksReadPage,
              prepared.preview.sourceSignature == lastGoogleBooksSignature else {
            return
        }

        let selectedVoice = AppSettings.shared.voice(
            for: prepared.preview.language
        )
        guard prepared.voiceID == selectedVoice else {
            preparedGoogleBooksReadPage = nil
            maybeStartGoogleBooksReadPreload()
            return
        }

        let audio = AudioPlayerService.shared
        guard WeReadContinuousPageHandoffContract.shouldArm(
            sourceFingerprint: prepared.preview.sourceSignature,
            currentFingerprint: lastGoogleBooksSignature,
            hasPreparedAudio: !prepared.segments.isEmpty,
            isLastReadableParagraph: vm.isOnLastReadableParagraph,
            currentTTSComplete: vm.currentTTSCompleteForPageHandoff,
            audioIsPlaying: audio.isPlaying
        ), let predecessor = audio.queuedTailSegmentID else { return }

        googleBooksContinuousSerial += 1
        let serial = googleBooksContinuousSerial
        let rebased = prepared.segments.enumerated().map { offset, segment in
            AudioSegment(
                paragraphIndex: segment.paragraphIndex,
                segmentIndex:
                    900_000_000 + (serial % 100_000) * 1_000 + offset,
                audioData: segment.audioData,
                timestamps: segment.timestamps,
                duration: segment.duration,
                text: segment.text,
                isWavFormat: segment.isWavFormat,
                unprocessedText: segment.unprocessedText,
                speaker: segment.speaker
            )
        }
        let handoff = GoogleBooksContinuousHandoff(
            serial: serial,
            preview: prepared.preview,
            voiceID: prepared.voiceID,
            segments: rebased,
            segmentIDs: Set(rebased.map(\.id)),
            predecessorSegmentID: predecessor,
            boundaryCue: vm.currentWeReadBoundaryCue,
            issuedTurnIdentity: nil
        )
        continuousGoogleBooksHandoff = handoff
        audio.canStartQueuedSegment = { [weak self] segment in
            guard let self,
                  let active = self.continuousGoogleBooksHandoff,
                  active.serial == serial,
                  active.segmentIDs.contains(segment.id) else {
                return true
            }
            guard GoogleBooksAudioPageBoundaryContract
                .canRequestPhysicalTurn(after: .queuedSuccessorGate) else {
                return false
            }
            let ownsTurn = self.requestGoogleBooksNextPage()
            if !ownsTurn {
                // `playSegment` latches `gatedSegmentIndex` only after this
                // closure returns. Cleanup must therefore run on the next main
                // turn or it would miss the newly-held segment forever.
                Task { @MainActor [weak self] in
                    guard let self,
                          self.continuousGoogleBooksHandoff?.serial
                            == serial else { return }
                    self.cancelGoogleBooksContinuousHandoff(
                        reason: "gate-request-unavailable",
                        completeGatedPage: true
                    )
                }
            }
            return false
        }
        let appendedAfter = audio.appendPreparedSegmentsForContinuousPlayback(
            rebased
        )
        guard appendedAfter == predecessor else {
            cancelGoogleBooksContinuousHandoff(
                reason: "queue-boundary-changed"
            )
            return
        }
        ReaderRunLog.write(
            "GBOOKS continuous armed reason=\(reason) serial=\(serial) " +
            "source=\(String(handoff.preview.sourceSignature.prefix(12))) " +
            "next=\(String(handoff.preview.contentFingerprint.prefix(12))) " +
            "predecessor=\(predecessor) segs=\(rebased.count)"
        )
    }

    /// Queue the exact source sentence behind the current page. Paragraph index
    /// zero is provisional: continuous release is allowed only when the real
    /// page proves that the sentence is native paragraph zero. If the committed
    /// page has leading empty placeholders, the same prepared audio is rebased
    /// and consumed by the ordinary post-commit path instead.
    private func maybeArmGoogleBooksSpeechContinuousHandoff(
        reason: String
    ) {
        guard continuousGoogleBooksSpeechHandoff == nil,
              continuousGoogleBooksHandoff == nil,
              isGoogleBooks,
              isReadMode,
              didInit,
              !pendingGoogleBooksTurn,
              !pendingGoogleBooksManualTurn,
              !googleBooksAwaitingReaderRecovery,
              googleBooksFailedTurnSignature
                != lastGoogleBooksSignature,
              pendingGoogleBooksPagePreview == nil,
              preparedGoogleBooksReadPage == nil,
              let vm = readVM,
              vm.isActive,
              vm.canContinueAcrossLivePageBoundary,
              let prepared = preparedGoogleBooksSpeechPreview,
              prepared.candidate.sourceSignature
                == lastGoogleBooksSignature,
              prepared.candidate.originFrameSessionID
                == activeGoogleBooksFrameSessionID else {
            return
        }
        let selectedVoice =
            AppSettings.shared.voice(for: prepared.language)
        guard prepared.voiceID == selectedVoice else {
            invalidateGoogleBooksSpeechPreload(
                reason: "speech-voice-changed",
                preserveCandidate: true
            )
            return
        }

        let audio = AudioPlayerService.shared
        guard WeReadContinuousPageHandoffContract.shouldArm(
            sourceFingerprint: prepared.candidate.sourceSignature,
            currentFingerprint: lastGoogleBooksSignature,
            hasPreparedAudio: !prepared.segments.isEmpty,
            isLastReadableParagraph: vm.isOnLastReadableParagraph,
            currentTTSComplete: vm.currentTTSCompleteForPageHandoff,
            audioIsPlaying: audio.isPlaying
        ), let predecessor = audio.queuedTailSegmentID else {
            return
        }

        googleBooksContinuousSerial += 1
        let serial = googleBooksContinuousSerial
        let rebased = rebaseGoogleBooksSpeechSegments(
            prepared.segments,
            paragraphIndex: 0,
            segmentIndexBase:
                910_000_000 + (serial % 100_000) * 1_000
        )
        let handoff = GoogleBooksSpeechContinuousHandoff(
            serial: serial,
            prepared: prepared,
            segments: rebased,
            segmentIDs: Set(rebased.map(\.id)),
            predecessorSegmentID: predecessor,
            boundaryCue: vm.currentWeReadBoundaryCue,
            issuedTurnIdentity: nil
        )
        continuousGoogleBooksSpeechHandoff = handoff
        audio.canStartQueuedSegment = { [weak self] segment in
            guard let self,
                  let active =
                    self.continuousGoogleBooksSpeechHandoff,
                  active.serial == serial,
                  active.segmentIDs.contains(segment.id) else {
                return true
            }
            guard GoogleBooksAudioPageBoundaryContract
                .canRequestPhysicalTurn(after: .queuedSuccessorGate) else {
                return false
            }
            let ownsTurn = self.requestGoogleBooksNextPage()
            if !ownsTurn {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.continuousGoogleBooksSpeechHandoff?
                            .serial == serial else {
                        return
                    }
                    self.cancelGoogleBooksSpeechContinuousHandoff(
                        reason: "gate-request-unavailable",
                        completeGatedPage: true
                    )
                }
            }
            return false
        }
        let appendedAfter =
            audio.appendPreparedSegmentsForContinuousPlayback(rebased)
        guard appendedAfter == predecessor else {
            cancelGoogleBooksSpeechContinuousHandoff(
                reason: "queue-boundary-changed"
            )
            return
        }
        ReaderRunLog.write(
            "GBOOKS speech continuous armed reason=\(reason) " +
            "serial=\(serial) " +
            "source=\(String(prepared.candidate.sourceSignature.prefix(12))) " +
            "fingerprint=\(prepared.candidate.contentFingerprint) " +
            "predecessor=\(predecessor) segs=\(rebased.count)"
        )
    }

    /// Remove only the speculative suffix. The current page's audible queue is
    /// retained, so a mismatch/manual gesture can never cut the current word.
    @discardableResult
    private func cancelGoogleBooksContinuousHandoff(
        reason: String,
        completeGatedPage: Bool = false
    ) -> Bool {
        guard let handoff = continuousGoogleBooksHandoff else {
            return false
        }
        let audio = AudioPlayerService.shared
        let wasGated = audio.isQueuedSegmentGated
        _ = audio.removePendingSegments(withIDs: handoff.segmentIDs)
        audio.canStartQueuedSegment = nil
        continuousGoogleBooksHandoff = nil
        ReaderRunLog.write(
            "GBOOKS continuous cancelled reason=\(reason) " +
            "serial=\(handoff.serial) gated=\(wasGated ? "Y" : "N")"
        )
        if completeGatedPage, wasGated {
            readVM?.continueAfterAdoptedPlaybackCompleted()
        }
        return wasGated
    }

    @discardableResult
    private func cancelGoogleBooksSpeechContinuousHandoff(
        reason: String,
        completeGatedPage: Bool = false
    ) -> Bool {
        guard let handoff =
                continuousGoogleBooksSpeechHandoff else {
            return false
        }
        let audio = AudioPlayerService.shared
        let wasGated = audio.isQueuedSegmentGated
        _ = audio.removePendingSegments(
            withIDs: handoff.segmentIDs
        )
        audio.canStartQueuedSegment = nil
        continuousGoogleBooksSpeechHandoff = nil
        ReaderRunLog.write(
            "GBOOKS speech continuous cancelled reason=\(reason) " +
            "serial=\(handoff.serial) gated=\(wasGated ? "Y" : "N")"
        )
        if completeGatedPage, wasGated {
            readVM?.continueAfterAdoptedPlaybackCompleted()
        }
        return wasGated
    }

    private func rebaseGoogleBooksSpeechSegments(
        _ segments: [AudioSegment],
        paragraphIndex: Int,
        segmentIndexBase: Int? = nil
    ) -> [AudioSegment] {
        segments.enumerated().map { offset, segment in
            AudioSegment(
                paragraphIndex: paragraphIndex,
                segmentIndex:
                    segmentIndexBase.map { $0 + offset }
                        ?? segment.segmentIndex,
                audioData: segment.audioData,
                timestamps: segment.timestamps,
                duration: segment.duration,
                text: segment.text,
                isWavFormat: segment.isWavFormat,
                unprocessedText: segment.unprocessedText,
                speaker: segment.speaker
            )
        }
    }

    /// A speculative result is consumed exactly once and only after the real
    /// page has committed the predicted text behind the same source signature.
    /// Reflow, reverse swipe, cross-page cursor differences, and voice changes
    /// all fail closed and use the ordinary generation path.
    private func takePreparedGoogleBooksReadPage(
        previousSignature: String,
        visibleParagraphs: [ReadingParagraph]
    ) -> GoogleBooksPreparedReadPage? {
        defer {
            invalidateGoogleBooksReadPreload(
                reason: "visible-page-committed",
                preservePrediction: false
            )
        }
        guard isReadMode, let prepared = preparedGoogleBooksReadPage else {
            return nil
        }
        let selectedVoice = AppSettings.shared.voice(
            for: prepared.preview.language
        )
        let canConsume = GoogleBooksSinglePagePreloadContract.canConsume(
            sourceSignature: prepared.preview.sourceSignature,
            previousSignature: previousSignature,
            predictedParagraphs: prepared.preview.readPage.map(\.text),
            visibleParagraphs: visibleParagraphs.map(\.text),
            preparedVoiceID: prepared.voiceID,
            selectedVoiceID: selectedVoice
        )
        guard canConsume,
              visibleParagraphs.indices.contains(
                  prepared.preview.preparedParagraphIndex
              ),
              visibleParagraphs[prepared.preview.preparedParagraphIndex].text
                == prepared.preview.preparedText,
              !prepared.segments.isEmpty else {
            return nil
        }
        return prepared
    }

    private func invalidateGoogleBooksReadPreload(
        reason: String,
        preservePrediction: Bool
    ) {
        cancelGoogleBooksSpeechContinuousHandoff(
            reason: reason
        )
        invalidateGoogleBooksSpeechPreload(
            reason: reason,
            preserveCandidate:
                preservePrediction
                    && pendingGoogleBooksPagePreview == nil
        )
        googleBooksPreloadGeneration &+= 1
        googleBooksReadPreloadTask?.cancel()
        googleBooksReadPreloadTask = nil
        preparedGoogleBooksReadPage = nil
        if !preservePrediction {
            pendingGoogleBooksPagePreview = nil
        }
        ReaderRunLog.write("GBOOKS preload invalidated reason=\(reason)")
    }

    private func invalidateGoogleBooksSpeechPreload(
        reason: String,
        preserveCandidate: Bool
    ) {
        googleBooksSpeechPreloadGeneration &+= 1
        googleBooksSpeechPreloadTask?.cancel()
        googleBooksSpeechPreloadTask = nil
        preparedGoogleBooksSpeechPreview = nil
        if !preserveCandidate {
            pendingGoogleBooksSpeechPreview = nil
        }
        ReaderRunLog.write(
            "GBOOKS speech preload invalidated reason=\(reason) " +
            "preserve=\(preserveCandidate ? "Y" : "N")"
        )
    }

    private func googleBooksTurnIdentity(
        from payload: [String: Any]
    ) -> GoogleBooksTurnIdentity? {
        guard let turnID = Self.nonemptyGoogleBooksString(payload["turnID"]),
              let baseline =
                GoogleBooksPageTurnContract.opaqueSignature(
                    from: payload["baselineSignature"]
                ),
              let origin =
                Self.nonemptyGoogleBooksString(payload["originFrameSessionID"]) else {
            return nil
        }
        return GoogleBooksTurnIdentity(
            turnID: turnID,
            baselineSignature: baseline,
            originFrameSessionID: origin
        )
    }

    private func googleBooksManualTurnIdentity(
        from payload: [String: Any]
    ) -> GoogleBooksManualTurnIdentity? {
        guard let intentID =
                Self.nonemptyGoogleBooksString(payload["manualIntentID"]),
              let baseline =
                GoogleBooksPageTurnContract.opaqueSignature(
                    from: payload["baselineSignature"]
                ),
              let origin =
                Self.nonemptyGoogleBooksString(payload["originFrameSessionID"]) else {
            return nil
        }
        return GoogleBooksManualTurnIdentity(
            intentID: intentID,
            baselineSignature: baseline,
            originFrameSessionID: origin
        )
    }

    private static func nonemptyGoogleBooksString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isCurrentGoogleBooksPredictionSource(
        _ sourceSignature: String
    ) -> Bool {
        sourceSignature == lastGoogleBooksSignature
            || (
                pendingGoogleBooksTurn
                    && googleBooksTurnIdentity?.baselineSignature
                        == sourceSignature
            )
            || googleBooksLateTurn?.identity.baselineSignature
                == sourceSignature
    }

    private func expireGoogleBooksLateTurnIfNeeded() {
        guard let late = googleBooksLateTurn, late.expiresAt <= Date() else {
            return
        }
        googleBooksLateTurn = nil
        clearGoogleBooksLateTurnVisualSuppression(
            reason: "late-turn-expired",
            restoreCurrentPage: true
        )
        ReaderRunLog.write("GBOOKS expired late-turn tombstone")
    }

    private func armGoogleBooksLateTurnVisualSuppression(
        identity: GoogleBooksTurnIdentity,
        expiresAt: Date
    ) {
        googleBooksLateTurnVisualSuppressionTask?.cancel()
        googleBooksLateTurnVisualsSuppressed = true
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        googleBooksLateTurnVisualSuppressionTask =
            Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                guard let self,
                      !Task.isCancelled,
                      self.googleBooksLateTurn?.identity == identity,
                      self.googleBooksLateTurn?.expiresAt ?? .distantFuture
                        <= Date() else {
                    return
                }
                self.googleBooksLateTurn = nil
                self.clearGoogleBooksLateTurnVisualSuppression(
                    reason: "late-turn-expired",
                    restoreCurrentPage: true
                )
                ReaderRunLog.write("GBOOKS expired late-turn tombstone")
            }
    }

    private func clearGoogleBooksLateTurnVisualSuppression(
        reason: String,
        restoreCurrentPage: Bool = false
    ) {
        googleBooksLateTurnVisualSuppressionTask?.cancel()
        googleBooksLateTurnVisualSuppressionTask = nil
        let wasSuppressed = googleBooksLateTurnVisualsSuppressed
        googleBooksLateTurnVisualsSuppressed = false
        guard wasSuppressed else { return }
        ReaderRunLog.write(
            "GBOOKS late-turn visuals released reason=\(reason)"
        )
        if restoreCurrentPage {
            restoreGoogleBooksPageVisualsIfPossible(reason: reason)
        }
    }

    private func retargetGoogleBooksLogicalBaseline(
        from oldSignature: String,
        to newSignature: String,
        identity: GoogleBooksTurnIdentity?
    ) {
        guard !newSignature.isEmpty, oldSignature != newSignature else { return }
        if pendingGoogleBooksTurn,
           googleBooksTurnLogicalBaseline == oldSignature {
            googleBooksTurnLogicalBaseline = newSignature
        }
        if var late = googleBooksLateTurn,
           late.logicalBaselineSignature == oldSignature {
            late.logicalBaselineSignature = newSignature
            googleBooksLateTurn = late
        }
        if googleBooksFailedTurnSignature == oldSignature {
            googleBooksFailedTurnSignature = newSignature
        }
        if pendingGoogleBooksManualTurn,
           googleBooksManualLogicalBaseline == oldSignature {
            googleBooksManualLogicalBaseline = newSignature
        }
        if let identity {
            call("gbRetargetTurnBaseline", [
                "turnID": identity.turnID,
                "detectionBaselineSignature": newSignature,
            ])
        }
    }

    private func receiveGoogleBooksPage(_ payload: [String: Any]) {
        guard livePlatform?.acceptsPayloadSource(
            payload["source"] as? String
        ) == true else {
            ReaderRunLog.write(
                "\(livePlatform?.logPrefix ?? "LIVEWEB") ignored mismatched payload source"
            )
            return
        }
        var reason = GoogleBooksPageEventReason(rawValue: (payload["reason"] as? String) ?? "")
            ?? .refresh
        let signature = (payload["signature"] as? String) ?? ""
        let previousCommittedSignature = lastGoogleBooksSignature
        let rawCount = (payload["paragraphs"] as? [[String: Any]])?.count ?? 0
        guard let incomingSessionID =
                GoogleBooksPageTurnContract.frameSessionID(from: payload) else {
            ReaderRunLog.write("GBOOKS ignored reader payload without frame session")
            return
        }

        expireGoogleBooksLateTurnIfNeeded()
        let automaticIdentity = googleBooksTurnIdentity(from: payload)
        let manualIdentity = googleBooksManualTurnIdentity(from: payload)
        let matchingPendingAutomatic =
            pendingGoogleBooksTurn
                && automaticIdentity == googleBooksTurnIdentity
                && googleBooksTurnLogicalBaseline == lastGoogleBooksSignature
        let matchingLateTurn: GoogleBooksLateTurn? = {
            guard !pendingGoogleBooksTurn,
                  let late = googleBooksLateTurn,
                  automaticIdentity == late.identity,
                  late.logicalBaselineSignature == lastGoogleBooksSignature else {
                return nil
            }
            return late
        }()
        let matchingPendingManual =
            pendingGoogleBooksManualTurn
                && manualIdentity == googleBooksManualTurnIdentity
                && googleBooksManualLogicalBaseline == lastGoogleBooksSignature
        let visualManualFallback =
            !pendingGoogleBooksManualTurn
                && manualIdentity?.originFrameSessionID
                    == activeGoogleBooksFrameSessionID
                && manualIdentity?.baselineSignature
                    == lastGoogleBooksSignature
        let authorizedAutomatic = matchingPendingAutomatic || matchingLateTurn != nil
        let authorizedManual = matchingPendingManual || visualManualFallback

        if authorizedAutomatic {
            // A 5.2-second JS timeout deliberately clears `pendingAuto`.
            // Its first later visual departure can therefore be reported as
            // refresh/initial; the immutable identity restores the original
            // automatic-turn semantics.
            reason = .auto
        } else if reason == .auto {
            // An absent/already-consumed/stale token from the current frame is
            // geometry refresh, never a second automatic continuation.
            reason = .refresh
        }
        if authorizedManual {
            reason = .manual
        } else if reason == .manual {
            reason = .refresh
        }

        var shouldAdoptIncomingSession = false
        if let activeSessionID = activeGoogleBooksFrameSessionID,
           activeSessionID != incomingSessionID {
            // A Google SPA turn can replace the cross-origin iframe. Transfer
            // ownership only when the replacement carries the exact identity
            // issued to the old frame. The mere existence of a tombstone must
            // never authorize an arbitrary preloaded/sibling reader.
            guard rawCount > 0 else { return }
            if authorizedAutomatic {
                reason = .auto
            } else if authorizedManual {
                reason = .manual
            } else if googleBooksAwaitingReaderRecovery {
                reason = .refresh
            } else {
                ReaderRunLog.write("GBOOKS ignored non-owner frame without matching turn identity")
                return
            }
            shouldAdoptIncomingSession = true
        } else if activeGoogleBooksFrameSessionID == nil {
            // Do not let an empty preload frame win ownership. If no readable
            // frame ever reports, the independent main-frame watchdog handles
            // recovery after Google's own 15-second boot window.
            guard rawCount > 0 else { return }
            shouldAdoptIncomingSession = true
        }

        // The user script is installed in every frame. Google can briefly keep
        // an old reader frame alive while creating the new one, and both report
        // `initial`. Once a page owns the native VMs, only a recovery navigation
        // may establish a second initial surface.
        if reason == .initial,
           didInit,
           !googleBooksAwaitingReaderRecovery,
           !authorizedAutomatic,
           !authorizedManual {
            ReaderRunLog.write("GBOOKS ignored duplicate initial frame payload")
            return
        }
        if reason == .refresh,
           (pendingGoogleBooksTurn || pendingGoogleBooksManualTurn),
           !authorizedAutomatic,
           !authorizedManual {
            // Resize/reflow of the still-old frame is not evidence that an
            // in-flight physical turn committed. Parsing it through the
            // promoted carry cursor can also make unchanged text look
            // different. Wait for the adapter's auto/manual commit instead.
            ReaderRunLog.write("GBOOKS ignored refresh while page turn is pending")
            return
        }

        guard GoogleBooksPageTurnContract.shouldCommit(
            reason: reason,
            previousSignature: lastGoogleBooksSignature,
            incomingSignature: signature,
            paragraphCount: rawCount
        ) else {
            if reason == .manual,
               pendingGoogleBooksManualTurn,
               matchingPendingManual,
               incomingSessionID == activeGoogleBooksFrameSessionID,
               !signature.isEmpty,
               signature == lastGoogleBooksSignature {
                // Edge/rubber-band gesture returned to the original page.
                // Nothing was destroyed at phase=changed, so resume the exact
                // queue/request and clear the tentative turn.
                if googleBooksResumeReadAfterTurn, isReadMode {
                    readVM?.resumeAfterCancelledLiveWebTurnIntent()
                }
                if googleBooksResumeExplainAfterTurn, !isReadMode {
                    explainVM?.resumeAfterCancelledLiveWebTurnIntent()
                }
                call(
                    "gbCompleteTurn",
                    ["manualIntentID": manualIdentity?.intentID ?? ""]
                )
                let shouldAdvanceCompletedGate =
                    googleBooksManualTurnCompletedGate
                        && googleBooksResumeReadAfterTurn
                        && isReadMode
                resetGoogleBooksManualTurnState(clearResumeIntent: true)
                restoreGoogleBooksPageVisualsIfPossible(
                    reason: "manual-returned-to-baseline"
                )
                if shouldAdvanceCompletedGate {
                    readVM?.continueAfterAdoptedPlaybackCompleted()
                }
                ReaderRunLog.write("GBOOKS manual gesture returned to original signature")
            }
            if rawCount == 0 {
                handleEmptyGoogleBooksPage(reason: reason)
            }
            return
        }
        googleBooksMainFrameWatchdogTask?.cancel()
        googleBooksMainFrameWatchdogTask = nil

        // A visual signature is the final authority. If the pointer-intent
        // listener missed a gesture, still latch/stop the old page before the
        // replacement is parsed. Clearing the old cross-page cursor afterwards
        // would already have clipped the user's unrelated destination page.
        if reason == .manual, didInit, !googleBooksManualPageDidChange {
            var inferredPayload = payload
            inferredPayload["reason"] = GoogleBooksPageEventReason.manual.rawValue
            inferredPayload["phase"] = "changed"
            prepareForGoogleBooksPageChange(inferredPayload)
        }
        if shouldAdoptIncomingSession {
            activeGoogleBooksFrameSessionID = incomingSessionID
            ReaderRunLog.write(
                "GBOOKS adopted frame session reason=\(reason.rawValue)"
            )
        }
        if reason == .manual {
            // Only a confirmed different signature may discard the old
            // page's cross-sentence cursor. The intent/animation phase can
            // rubber-band back to the original page.
            googleBooksConsumedCursor = nil
            googleBooksPageCompletionCursor = nil
            googleBooksCurrentBoundarySourceUTF16End = nil
            googleBooksLateTurn = nil
            clearGoogleBooksLateTurnVisualSuppression(
                reason: "manual-page-change"
            )
        }
        let applicableLateTurn =
            reason == .auto && signature != lastGoogleBooksSignature
                ? matchingLateTurn
                : nil
        if let applicableLateTurn {
            // A physical turn can land after native's confirmation timeout.
            // Parse it through the original one-shot cursor so the natural
            // sentence spoken before timeout is never reintroduced.
            googleBooksConsumedCursor = applicableLateTurn.consumedCursor
        }
        guard let parsedPage = parseGoogleBooksPage(payload) else {
            return
        }
        var parsed = parsedPage
        guard let readVM else { return }

        let incomingParagraphTexts = parsed.explainParagraphs.map(\.text)
        let isEquivalentRefresh =
            (reason == .refresh || authorizedAutomatic)
                && didInit
                && incomingParagraphTexts == lastGoogleBooksParagraphTexts
        var pageForDOMMapping = parsed
        if isEquivalentRefresh, authorizedAutomatic {
            // A resize can be the first geometry departure after JS timed out.
            // It carries the late token, but is still the old logical page.
            // Remap it through the old cursor while retaining the promoted
            // cursor for the eventual physical page.
            let promotedCursor = googleBooksConsumedCursor
            googleBooksConsumedCursor =
                matchingPendingAutomatic
                    ? googleBooksTurnPriorCursor
                    : applicableLateTurn?.priorCursor
            if let reparsed = parseGoogleBooksPage(payload) {
                pageForDOMMapping = reparsed
            }
            googleBooksConsumedCursor = promotedCursor
        }
        var readSegments = pageForDOMMapping.paragraphs.enumerated().map { index, paragraph in
            [
                "paragraphIndex": paragraph.id,
                "text": paragraph.text,
                "domParagraphIndex":
                    pageForDOMMapping
                        .readDOMParagraphIndices[index],
                "domCharOffset": pageForDOMMapping.readDOMCharacterOffsets[index],
            ] as [String: Any]
        }
        let explainSegments = pageForDOMMapping.explainParagraphs.enumerated().map { index, paragraph in
            [
                "paragraphIndex": paragraph.id,
                "text": paragraph.text,
                "domCharOffset": pageForDOMMapping.explainDOMCharacterOffsets[index],
            ] as [String: Any]
        }

        if isEquivalentRefresh {
            // This path must run before resolving automatic/manual turns or
            // consuming carry state. A resize emitted while a turn is in
            // flight is geometry evidence only, not confirmation that the
            // requested page committed.
            let previousSignature = lastGoogleBooksSignature
            retargetGoogleBooksLogicalBaseline(
                from: previousSignature,
                to: signature,
                identity: automaticIdentity
            )
            lastGoogleBooksSignature = signature
            lastGoogleBooksEvidence = pageForDOMMapping.evidence
            lastGoogleBooksParagraphTexts = incomingParagraphTexts
            lastGoogleBooksLanguage = pageForDOMMapping.language
            googleBooksReadDOMSegments = readSegments
            googleBooksExplainDOMSegments = explainSegments
            googleBooksReadinessTask?.cancel()
            googleBooksReadinessTask = nil
            googleBooksReadinessRetries = 0
            googleBooksAwaitingReaderRecovery = false
            googleBooksNetworkRetries = 0
            if livePlatform?.needsViewportRelayout == true {
                koboSessionRecoveryAttempts = 0
                koboSessionRecoveryTask?.cancel()
                koboSessionRecoveryTask = nil
                onLiveWebSurfaceStable?()
            }
            livePlatform?.clearReaderError()
            HistoryStore.shared.updateDetectedLanguage(
                documentID: readVM.document.id,
                language: pageForDOMMapping.language
            )
            installGoogleBooksDOMMapping()
            call("clearHighlight")
            if isReadMode,
               !googleBooksPageVisualsAreSuspended,
               let highlight = readVM.webHighlight {
                pushHighlight(highlight)
            }
            if isReadMode,
               !googleBooksPageVisualsAreSuspended,
               var carry = activeGoogleBooksCarry {
                carry.lastPaintedDOMUTF16End = nil
                activeGoogleBooksCarry = carry
                updateGoogleBooksCarryHighlightIfNeeded()
            } else if !isReadMode,
                      !googleBooksPageVisualsAreSuspended {
                shownMarkIds.removeAll()
                call("clearMarks")
                if let explainVM {
                    pushMarks(explainVM.activeMarks)
                }
            }
            let preservesIssuedContinuousTurn =
                authorizedAutomatic
                    && continuousGoogleBooksHandoff?.issuedTurnIdentity
                        == automaticIdentity
            if !preservesIssuedContinuousTurn {
                cancelGoogleBooksContinuousHandoff(
                    reason: "equivalent-refresh-reflow"
                )
            }
            cancelGoogleBooksSpeechContinuousHandoff(
                reason: "equivalent-refresh-reflow"
            )
            invalidateGoogleBooksSpeechPreload(
                reason: "equivalent-refresh-reflow",
                preserveCandidate: false
            )
            if !preservesIssuedContinuousTurn,
               pendingGoogleBooksPagePreview != nil ||
                preparedGoogleBooksReadPage != nil ||
                googleBooksReadPreloadTask != nil {
                invalidateGoogleBooksReadPreload(
                    reason: "equivalent-refresh-reflow",
                    preservePrediction: false
                )
            }
            if !authorizedAutomatic {
                invalidateGoogleBooksExplainPrefetch(
                    reason: "equivalent-refresh-reflow"
                )
            }
            ReaderRunLog.write("GBOOKS equivalent refresh remapped without playback restart")
            return
        }

        var speechCommit: GoogleBooksSpeechCommit?
        let speechTurnIdentity: GoogleBooksTurnIdentity? = {
            if matchingPendingAutomatic,
               googleBooksTurnOwner == .read {
                return googleBooksTurnIdentity
            }
            if applicableLateTurn?.owner == .read,
               applicableLateTurn?.shouldResume == true {
                return applicableLateTurn?.identity
            }
            return nil
        }()
        if isReadMode,
           reason == .auto,
           let speechTurnIdentity,
           let resolved = makeGoogleBooksSpeechCommit(
                parsed: parsed,
                previousSignature:
                    speechTurnIdentity.baselineSignature,
                turnOriginFrameSessionID:
                    speechTurnIdentity.originFrameSessionID
           ) {
            parsed = resolved.page
            pageForDOMMapping = resolved.page
            speechCommit = resolved.commit
            readSegments =
                pageForDOMMapping.paragraphs.enumerated().map {
                    index, paragraph in
                    [
                        "paragraphIndex": paragraph.id,
                        "text": paragraph.text,
                        "domParagraphIndex":
                            pageForDOMMapping
                                .readDOMParagraphIndices[index],
                        "domCharOffset":
                            pageForDOMMapping
                                .readDOMCharacterOffsets[index],
                    ] as [String: Any]
                }
            ReaderRunLog.write(
                "GBOOKS speech preload exact commit " +
                "source=\(String(resolved.commit.prepared.candidate.sourceSignature.prefix(12))) " +
                "fingerprint=\(resolved.commit.prepared.candidate.contentFingerprint) " +
                "paragraph=\(resolved.commit.split.preparedParagraphIndex) " +
                "remainder=\(resolved.commit.split.insertedRemainder ? "Y" : "N")"
            )
        } else if pendingGoogleBooksSpeechPreview != nil ||
                    preparedGoogleBooksSpeechPreview != nil ||
                    continuousGoogleBooksSpeechHandoff != nil {
            cancelGoogleBooksSpeechContinuousHandoff(
                reason: "page-commit-mismatch"
            )
            invalidateGoogleBooksSpeechPreload(
                reason: "page-commit-mismatch",
                preserveCandidate: false
            )
            ReaderRunLog.write(
                "GBOOKS speech preload commit miss " +
                "reason=\(reason.rawValue)"
            )
        }

        let refreshReadAnchor =
            reason == .refresh ? readVM.makeWeReadPlaybackResumeAnchor() : nil
        let expectedTurnOwner: GoogleBooksTurnOwner = isReadMode ? .read : .explain
        let wasPendingAutomaticTurn =
            matchingPendingAutomatic
                && googleBooksTurnOwner == expectedTurnOwner
        let wasResumableLateTurn =
            applicableLateTurn?.owner == expectedTurnOwner
                && applicableLateTurn?.shouldResume == true
        let wasAutomaticTurn =
            wasPendingAutomaticTurn || wasResumableLateTurn
        let shouldResumeRecovery =
            googleBooksRecoveryShouldResume
                && googleBooksRecoveryOwner == expectedTurnOwner
        let boundaryTurn: GoogleBooksBoundaryTurn? = {
            guard isReadMode else { return nil }
            if wasPendingAutomaticTurn {
                return pendingGoogleBooksBoundaryTurn
            }
            if applicableLateTurn?.owner == .read,
               applicableLateTurn?.shouldResume == true {
                return applicableLateTurn?.boundaryTurn
            }
            return nil
        }()
        let continuousHandoff = continuousGoogleBooksHandoff
        let continuousQueueIsIntact = continuousHandoff.map { handoff in
            let audio = AudioPlayerService.shared
            return audio.queuedTailSegmentID == handoff.segments.last?.id
                && (
                    audio.currentSegment?.id == handoff.predecessorSegmentID
                        || audio.isQueuedSegmentGated
                )
        } == true
        let canCommitContinuously = continuousHandoff.map { handoff in
            let selectedVoice = AppSettings.shared.voice(
                for: handoff.preview.language
            )
            let preparedParagraphIsExact =
                parsed.paragraphs.indices.contains(
                    handoff.preview.preparedParagraphIndex
                )
                    && parsed.paragraphs[
                        handoff.preview.preparedParagraphIndex
                    ].text == handoff.preview.preparedText
                    && handoff.segments.allSatisfy {
                        $0.paragraphIndex
                            == handoff.preview.preparedParagraphIndex
                    }
            let identityMatches =
                automaticIdentity != nil
                    && handoff.issuedTurnIdentity == automaticIdentity
                    && handoff.issuedTurnIdentity?.baselineSignature
                        == handoff.preview.sourceSignature
            return preparedParagraphIsExact
                && GoogleBooksContinuousPageHandoffContract.canRelease(
                    isAuthorizedAutomaticTurn:
                        isReadMode
                            && wasPendingAutomaticTurn
                            && reason == .auto,
                    issuedTurnIdentityMatches: identityMatches,
                    queueIsIntact: continuousQueueIsIntact,
                    canContinueListening:
                        readVM.canContinueAcrossLivePageBoundary,
                    sourceSignature: handoff.preview.sourceSignature,
                    issuedBaselineSignature:
                        handoff.issuedTurnIdentity?.baselineSignature ?? "",
                    predictedParagraphs:
                        handoff.preview.readPage.map(\.text),
                    visibleParagraphs: parsed.paragraphs.map(\.text),
                    preparedVoiceID: handoff.voiceID,
                    selectedVoiceID: selectedVoice
                )
        } == true
        let speechContinuousHandoff =
            continuousGoogleBooksSpeechHandoff
        let speechContinuousQueueIsIntact =
            speechContinuousHandoff.map { handoff in
                let audio = AudioPlayerService.shared
                return audio.queuedTailSegmentID
                    == handoff.segments.last?.id
                    && (
                        audio.currentSegment?.id
                            == handoff.predecessorSegmentID
                            || audio.isQueuedSegmentGated
                    )
            } == true
        let canCommitSpeechContinuously =
            speechContinuousHandoff.map { handoff in
                let selectedVoice =
                    AppSettings.shared.voice(for: parsed.language)
                let identityMatches =
                    automaticIdentity != nil
                        && handoff.issuedTurnIdentity
                            == automaticIdentity
                        && handoff.issuedTurnIdentity?
                            .baselineSignature
                            == handoff.prepared.candidate
                                .sourceSignature
                        && handoff.issuedTurnIdentity?
                            .originFrameSessionID
                            == handoff.prepared.candidate
                                .originFrameSessionID
                let exactCommit =
                    speechCommit?.prepared.candidate
                        == handoff.prepared.candidate
                let queuedParagraphIndex =
                    handoff.segments.first?.paragraphIndex ?? -1
                return GoogleBooksSpeechContinuousHandoffContract
                    .canRelease(
                        isAuthorizedAutomaticTurn:
                            isReadMode
                                && wasPendingAutomaticTurn
                                && reason == .auto,
                        issuedTurnIdentityMatches:
                            identityMatches,
                        queueIsIntact:
                            speechContinuousQueueIsIntact,
                        canContinueListening:
                            readVM
                                .canContinueAcrossLivePageBoundary,
                        candidateMatchesCommittedSplit:
                            exactCommit,
                        preparedVoiceID:
                            handoff.prepared.voiceID,
                        selectedVoiceID: selectedVoice,
                        preparedParagraphIndex:
                            speechCommit?.split
                                .preparedParagraphIndex ?? -1,
                        queuedParagraphIndex:
                            queuedParagraphIndex
                    )
            } == true
        // A reflow can arrive while the first TTS/LLM request is still
        // producing and no AVPlayerItem exists yet. Preserve that user-started
        // intent as well as audible playback; otherwise rotation/resize stops
        // the session permanently.
        let wasReading =
            readVM.isPlaying
                || readVM.shouldResumeAfterManualLivePageTurn
        let wasExplaining =
            explainVM?.isPlaying == true
                || explainVM?.shouldResumeAfterManualLivePageTurn == true
        let appReviewContinuation = automaticAppReviewContinuation
            .takeForConfirmedAutomaticCommit(
                isReadMode && wasAutomaticTurn && reason == .auto
            )
        finishGoogleBooksTurn(reason: "committed")
        if let automaticIdentity {
            call("gbCompleteTurn", ["turnID": automaticIdentity.turnID])
        }
        if let manualIdentity {
            call(
                "gbCompleteTurn",
                ["manualIntentID": manualIdentity.intentID]
            )
        }
        googleBooksLateTurn = nil
        clearGoogleBooksLateTurnVisualSuppression(
            reason: "page-committed"
        )
        pendingGoogleBooksBoundaryTurn = nil
        googleBooksCarryAdvance = nil
        resetGoogleBooksManualTurnState(clearResumeIntent: false)

        lastGoogleBooksSignature = signature
        googleBooksFailedTurnSignature = nil
        lastGoogleBooksEvidence = parsed.evidence
        lastGoogleBooksParagraphTexts = incomingParagraphTexts
        lastGoogleBooksLanguage = parsed.language
        googleBooksReadDOMSegments = readSegments
        googleBooksExplainDOMSegments = explainSegments
        // Keep the cursor that shaped this visual page until the next physical
        // turn replaces it. A resize/reflow of the same page must parse through
        // the identical cursor or it would restore and repeat the carried text.
        googleBooksPageCompletionCursor = parsed.nextCursor
        googleBooksCurrentBoundarySourceUTF16End = parsed.boundarySourceVisibleEnd
        googleBooksReadinessTask?.cancel()
        googleBooksReadinessTask = nil
        googleBooksReadinessRetries = 0
        googleBooksAwaitingReaderRecovery = false
        googleBooksNetworkRetries = 0
        if livePlatform?.needsViewportRelayout == true {
            koboSessionRecoveryAttempts = 0
            koboSessionRecoveryTask?.cancel()
            koboSessionRecoveryTask = nil
            onLiveWebSurfaceStable?()
        }
        livePlatform?.clearReaderError()
        ReaderRunLog.write(
            "GBOOKS page commit reason=\(reason.rawValue) paras=\(parsed.paragraphs.count) " +
            "cross=\(parsed.boundary != nil ? "Y" : "N") sig=\(String(signature.prefix(24)))"
        )

        HistoryStore.shared.updateDetectedLanguage(
            documentID: readVM.document.id,
            language: parsed.language
        )

        // Google rebuilds/clones paragraph nodes while paging. Reinitialize the
        // page-local DOM mapping on every committed signature, not just page 1.
        installGoogleBooksDOMMapping()

        if !didInit {
            readVM.loadWebParagraphs(
                parsed.paragraphs,
                language: parsed.language,
                weReadBoundary: parsed.boundary
            )
            explainVM?.loadWebParagraphs(
                parsed.explainParagraphs,
                language: parsed.language
            )
            didInit = true
            startAutoPlaybackIfNeeded()
            return
        }

        let wasPlaying = isReadMode
            ? (wasReading || googleBooksResumeReadAfterTurn)
            : (wasExplaining || googleBooksResumeExplainAfterTurn)
        let shouldResume = GoogleBooksPageTurnContract.shouldResumePlayback(
            reason: reason,
            wasAutomaticTurn: wasAutomaticTurn,
            wasPlaying: wasPlaying
        ) || shouldResumeRecovery
        googleBooksRecoveryOwner = nil
        googleBooksRecoveryShouldResume = false
        googleBooksResumeReadAfterTurn = false
        googleBooksResumeExplainAfterTurn = false
        shownMarkIds.removeAll()
        call("clearHighlight")
        call("clearMarks")

        let activeParagraphs = isReadMode ? parsed.paragraphs : parsed.explainParagraphs
        let hasSpeakableContent = activeParagraphs.contains {
            SpeechTextSanitizer.containsSpeakableContent($0.text)
        }

        if canCommitContinuously, let handoff = continuousHandoff {
            explainVM?.stageInactiveLiveWebPage(
                parsed.explainParagraphs,
                language: parsed.language
            )
            if let appReviewContinuation {
                _ = readVM.inheritAppReviewReadSession(
                    appReviewContinuation
                )
            }
            let committed = readVM.commitContinuousLiveWebPage(
                parsed.paragraphs,
                language: parsed.language,
                preparedSegments: handoff.segments,
                weReadBoundary: parsed.boundary
            )
            if committed {
                if let boundaryTurn {
                    configureGoogleBooksActiveCarry(
                        boundaryTurn,
                        parsed: parsed
                    )
                } else {
                    activeGoogleBooksCarry = nil
                }
                let audio = AudioPlayerService.shared
                audio.canStartQueuedSegment = nil
                continuousGoogleBooksHandoff = nil
                invalidateGoogleBooksReadPreload(
                    reason: "continuous-committed",
                    preservePrediction: false
                )
                audio.resumeGatedSegmentIfPossible()
                updateGoogleBooksCarryHighlightIfNeeded()
                ReaderRunLog.write(
                    "GBOOKS continuous committed serial=\(handoff.serial) " +
                    "next=\(String(handoff.preview.contentFingerprint.prefix(12)))"
                )
                return
            }
            cancelGoogleBooksContinuousHandoff(
                reason: "vm-continuous-commit-rejected"
            )
            invalidateGoogleBooksReadPreload(
                reason: "vm-continuous-commit-rejected",
                preservePrediction: false
            )
        } else if continuousHandoff != nil {
            cancelGoogleBooksContinuousHandoff(
                reason: "visible-page-mismatch"
            )
        }

        if canCommitSpeechContinuously,
           let handoff = speechContinuousHandoff {
            explainVM?.stageInactiveLiveWebPage(
                parsed.explainParagraphs,
                language: parsed.language
            )
            if let appReviewContinuation {
                _ = readVM.inheritAppReviewReadSession(
                    appReviewContinuation
                )
            }
            let committed = readVM.commitContinuousLiveWebPage(
                parsed.paragraphs,
                language: parsed.language,
                preparedSegments: handoff.segments,
                weReadBoundary: parsed.boundary
            )
            if committed {
                if let boundaryTurn {
                    configureGoogleBooksActiveCarry(
                        boundaryTurn,
                        parsed: parsed
                    )
                } else {
                    activeGoogleBooksCarry = nil
                }
                let audio = AudioPlayerService.shared
                audio.canStartQueuedSegment = nil
                continuousGoogleBooksSpeechHandoff = nil
                invalidateGoogleBooksSpeechPreload(
                    reason: "speech-continuous-committed",
                    preserveCandidate: false
                )
                audio.resumeGatedSegmentIfPossible()
                updateGoogleBooksCarryHighlightIfNeeded()
                ReaderRunLog.write(
                    "GBOOKS speech continuous committed " +
                    "serial=\(handoff.serial) " +
                    "fingerprint=\(handoff.prepared.candidate.contentFingerprint)"
                )
                return
            }
            cancelGoogleBooksSpeechContinuousHandoff(
                reason: "vm-continuous-commit-rejected"
            )
        } else if speechContinuousHandoff != nil {
            cancelGoogleBooksSpeechContinuousHandoff(
                reason: "visible-page-mismatch"
            )
        }

        if isReadMode,
           let boundaryTurn,
           GoogleBooksAudioPageBoundaryContract.canCommitActiveCarry(
                carryParagraphIndex: parsed.carryParagraphIndex,
                carryUTF16Length: parsed.carryUTF16Length,
                carryDOMUTF16Start: parsed.carryDOMUTF16Start
           ),
           readVM.commitLiveWebPageDuringActiveCarry(
                parsed.paragraphs,
                language: parsed.language,
                carrySegmentID: boundaryTurn.cue.segmentID,
                weReadBoundary: parsed.boundary
           ) {
            explainVM?.stageInactiveLiveWebPage(
                parsed.explainParagraphs,
                language: parsed.language
            )
            configureGoogleBooksActiveCarry(
                boundaryTurn,
                parsed: parsed
            )
            updateGoogleBooksCarryHighlightIfNeeded()
            if !hasSpeakableContent {
                // One natural sentence can cover an entire middle visual page.
                // Keep the immutable carry audio and absolute cursor. The next
                // visual page is requested only when playback reaches this
                // middle page's own source edge, not immediately on commit.
                pendingGoogleBooksBoundaryTurn = boundaryTurn
                if let domStart = parsed.carryDOMUTF16Start,
                   let consumedEnd = boundaryTurn.cue.consumedCursor?.sourceUTF16End {
                    googleBooksCarryAdvance = GoogleBooksCarryAdvance(
                        turn: boundaryTurn,
                        segmentID: boundaryTurn.cue.segmentID,
                        turnTime: GoogleBooksCrossPageContract.visualTurnTime(
                            boundaryTime: boundaryTurn.cue.boundaryTime,
                            segmentDuration: boundaryTurn.cue.segmentDuration,
                            sourceBoundaryUTF16End:
                                boundaryTurn.sourceBoundaryUTF16End,
                            visibleCarryUTF16End:
                                domStart + parsed.carryUTF16Length,
                            consumedUTF16End: consumedEnd
                        )
                    )
                    maybeAdvanceGoogleBooksCarryPage()
                }
            }
            ReaderRunLog.write(
                "GBOOKS boundary carry committed trim=\(parsed.carryUTF16Length)"
            )
            invalidateGoogleBooksReadPreload(
                reason: "boundary-carry-committed",
                preservePrediction: false
            )
            return
        }
        activeGoogleBooksCarry = nil

        if !hasSpeakableContent {
            invalidateGoogleBooksReadPreload(
                reason: "fully-consumed-page",
                preservePrediction: false
            )
            ReaderRunLog.write(
                "GBOOKS committed page is fully consumed; advance=\(wasAutomaticTurn ? "Y" : "N")"
            )
            if isReadMode {
                explainVM?.stageInactiveLiveWebPage(
                    parsed.explainParagraphs,
                    language: parsed.language
                )
                readVM.replaceLiveWebPage(
                    parsed.paragraphs,
                    language: parsed.language,
                    autoplay: false,
                    weReadBoundary: parsed.boundary
                )
            } else {
                readVM.stageInactiveLiveWebPage(
                    parsed.paragraphs,
                    language: parsed.language,
                    weReadBoundary: parsed.boundary
                )
                explainVM?.replaceLiveWebPage(
                    parsed.explainParagraphs,
                    language: parsed.language,
                    autoplay: false
                )
            }
            if wasAutomaticTurn {
                if let appReviewContinuation {
                    automaticAppReviewContinuation.arm(appReviewContinuation)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.requestGoogleBooksNextPage()
                }
            }
            return
        }

        let preparedReadPage: GoogleBooksPreparedReadPage?
        if speechCommit == nil {
            preparedReadPage = takePreparedGoogleBooksReadPage(
                previousSignature: previousCommittedSignature,
                visibleParagraphs: parsed.paragraphs
            )
        } else {
            preparedReadPage = nil
            invalidateGoogleBooksSpeechPreload(
                reason: "speech-visible-page-committed",
                preserveCandidate: false
            )
        }

        if isReadMode {
            explainVM?.stageInactiveLiveWebPage(
                parsed.explainParagraphs,
                language: parsed.language
            )
            if let appReviewContinuation {
                _ = readVM.inheritAppReviewReadSession(appReviewContinuation)
            }
            if shouldResume, let speechCommit {
                readVM.replaceLiveWebPage(
                    parsed.paragraphs,
                    language: parsed.language,
                    autoplay: false,
                    weReadBoundary: parsed.boundary,
                    resumeAnchor: refreshReadAnchor
                )
                readVM.startWithPrefetchedSegments(
                    speechCommit.rebasedSegments,
                    paragraphIndex:
                        speechCommit.split
                            .preparedParagraphIndex
                )
                ReaderRunLog.write(
                    "GBOOKS speech preload consumed " +
                    "fingerprint=\(speechCommit.prepared.candidate.contentFingerprint) " +
                    "paragraph=\(speechCommit.split.preparedParagraphIndex) " +
                    "segs=\(speechCommit.rebasedSegments.count)"
                )
            } else if shouldResume, let preparedReadPage {
                readVM.replaceLiveWebPage(
                    parsed.paragraphs,
                    language: parsed.language,
                    autoplay: false,
                    weReadBoundary: parsed.boundary,
                    resumeAnchor: refreshReadAnchor
                )
                readVM.startWithPrefetchedSegments(
                    preparedReadPage.segments,
                    paragraphIndex:
                        preparedReadPage.preview.preparedParagraphIndex
                )
                ReaderRunLog.write(
                    "GBOOKS preload consumed next=\(String(preparedReadPage.preview.contentFingerprint.prefix(12))) " +
                    "segs=\(preparedReadPage.segments.count)"
                )
            } else {
                readVM.replaceLiveWebPage(
                    parsed.paragraphs,
                    language: parsed.language,
                    autoplay: shouldResume,
                    weReadBoundary: parsed.boundary,
                    resumeAnchor: refreshReadAnchor
                )
            }
        } else {
            readVM.stageInactiveLiveWebPage(
                parsed.paragraphs,
                language: parsed.language,
                weReadBoundary: parsed.boundary
            )
            let explainPrefetched:
                ExplainViewModel.PrefetchedFirstBlock?
            if shouldResume {
                let preloadSourceSignature =
                    wasAutomaticTurn
                        ? (
                            automaticIdentity?.baselineSignature
                                ?? previousCommittedSignature
                        )
                        : previousCommittedSignature
                explainPrefetched =
                    consumeGoogleBooksExplainPrefetch(
                        sourceSignature: preloadSourceSignature,
                        visibleParagraphs: parsed.explainParagraphs
                    )
            } else {
                invalidateGoogleBooksExplainPrefetch(
                    reason: "page-commit-without-resume"
                )
                explainPrefetched = nil
            }
            explainVM?.replaceLiveWebPage(
                parsed.explainParagraphs,
                language: parsed.language,
                autoplay: shouldResume,
                prefetched: explainPrefetched
            )
        }
    }

    private func configureGoogleBooksActiveCarry(
        _ boundaryTurn: GoogleBooksBoundaryTurn,
        parsed: GoogleBooksParsedPage
    ) {
        guard let paragraphIndex = parsed.carryParagraphIndex,
              let domStart = parsed.carryDOMUTF16Start,
              parsed.carryUTF16Length > 0 else {
            activeGoogleBooksCarry = nil
            return
        }
        let domEnd = domStart + parsed.carryUTF16Length
        let visibleCarryStart = max(
            domStart,
            boundaryTurn.sourceBoundaryUTF16End
        )
        guard let consumedEnd =
                boundaryTurn.cue.consumedCursor?.sourceUTF16End,
              domEnd > visibleCarryStart else {
            activeGoogleBooksCarry = nil
            return
        }
        activeGoogleBooksCarry = GoogleBooksActiveCarry(
            segmentID: boundaryTurn.cue.segmentID,
            startTime: GoogleBooksCrossPageContract.visualTurnTime(
                boundaryTime: boundaryTurn.cue.boundaryTime,
                segmentDuration: boundaryTurn.cue.segmentDuration,
                sourceBoundaryUTF16End:
                    boundaryTurn.sourceBoundaryUTF16End,
                visibleCarryUTF16End: visibleCarryStart,
                consumedUTF16End: consumedEnd
            ),
            endTime: GoogleBooksCrossPageContract.visualTurnTime(
                boundaryTime: boundaryTurn.cue.boundaryTime,
                segmentDuration: boundaryTurn.cue.segmentDuration,
                sourceBoundaryUTF16End:
                    boundaryTurn.sourceBoundaryUTF16End,
                visibleCarryUTF16End: domEnd,
                consumedUTF16End: consumedEnd
            ),
            paragraphIndex: paragraphIndex,
            domUTF16Start: visibleCarryStart,
            domUTF16End: domEnd,
            lastPaintedDOMUTF16End: nil
        )
    }

    private func handleGoogleBooksPageBoundaryApproaching() {
        guard isGoogleBooks,
              isReadMode else { return }
        // `currentWeReadBoundaryCue` is currently derived from a UTF-16
        // character fraction, not a reliable TTS word timestamp. It may be
        // used to prepare work, but it has no authority to move the visible
        // Google page before the AVPlayerItem actually ends.
        //
        // Prepared audio remains behind `canStartQueuedSegment`: when the old
        // item ends, that gate requests one physical turn and releases only
        // after the exact new page commits. Without prepared audio,
        // `onDocumentFinished` takes the same item-end path.
        pendingGoogleBooksBoundaryTurn = nil
        maybeArmGoogleBooksContinuousHandoff(reason: "audio-tail")
        maybeArmGoogleBooksSpeechContinuousHandoff(
            reason: "audio-tail"
        )
        let canTurnEarly = GoogleBooksAudioPageBoundaryContract
            .canRequestPhysicalTurn(after: .estimatedBoundary)
        ReaderRunLog.write(
            "GBOOKS page boundary observed; physical turn " +
            (canTurnEarly ? "authorized" : "deferred until audio item end")
        )
        if canTurnEarly {
            requestGoogleBooksNextPage()
        }
    }

    private func maybeAdvanceGoogleBooksCarryPage() {
        guard let advance = googleBooksCarryAdvance else { return }
        guard GoogleBooksAudioPageBoundaryContract
            .canRequestPhysicalTurn(after: .estimatedBoundary) else {
            googleBooksCarryAdvance = nil
            ReaderRunLog.write(
                "GBOOKS proportional carry edge ignored; wait for audio item end"
            )
            return
        }
        let audio = AudioPlayerService.shared
        guard audio.currentSegment?.id == advance.segmentID else {
            googleBooksCarryAdvance = nil
            return
        }
        guard audio.currentTime + 0.02 >= advance.turnTime else { return }
        googleBooksCarryAdvance = nil
        pendingGoogleBooksBoundaryTurn = advance.turn
        ReaderRunLog.write(
            "GBOOKS multi-page carry reached visual edge time=\(advance.turnTime)"
        )
        requestGoogleBooksNextPage()
    }

    /// Paint the visible continuation using absolute source-DOM coordinates.
    /// CR's ordinary paragraph offset already points *after* the consumed
    /// prefix for future narration, so a carry needs this one explicit range.
    /// Progress follows the immutable audio segment instead of highlighting a
    /// whole middle page as soon as it appears.
    private func updateGoogleBooksCarryHighlightIfNeeded() {
        maybeAdvanceGoogleBooksCarryPage()
        guard !googleBooksPageVisualsAreSuspended else { return }
        guard var carry = activeGoogleBooksCarry else { return }
        let audio = AudioPlayerService.shared
        guard audio.currentSegment?.id == carry.segmentID else {
            activeGoogleBooksCarry = nil
            return
        }
        guard audio.currentTime + 0.02 >= carry.startTime else { return }
        let duration = max(0.001, carry.endTime - carry.startTime)
        let fraction = min(
            1,
            max(0, (audio.currentTime - carry.startTime) / duration)
        )
        let length = carry.domUTF16End - carry.domUTF16Start
        let paintedEnd = min(
            carry.domUTF16End,
            carry.domUTF16Start + max(1, Int((Double(length) * fraction).rounded(.up)))
        )
        guard carry.lastPaintedDOMUTF16End != paintedEnd else { return }
        carry.lastPaintedDOMUTF16End = paintedEnd
        activeGoogleBooksCarry = carry
        call("highlightRange", [
            "paragraphIndex": carry.paragraphIndex,
            "charStart": 0,
            "charEnd": 0,
            "domCharStart": carry.domUTF16Start,
            "domCharEnd": paintedEnd,
        ])
    }

    /// 用户手动翻页（滑动/点击/键盘）：立刻停掉旧页的音频，记住原本是否在播，
    /// 新页提交后再决定要不要续播。自动翻页由 native 自己发起，不走这里。
    private func prepareForGoogleBooksPageChange(_ payload: [String: Any]) {
        guard isGoogleBooks, didInit else { return }
        guard (payload["reason"] as? String) == "manual" else { return }
        guard let identity = googleBooksManualTurnIdentity(from: payload) else {
            ReaderRunLog.write("GBOOKS ignored manual event without intent identity")
            return
        }
        let phase = (payload["phase"] as? String) ?? "changed"

        automaticAppReviewContinuation.cancel()
        googleBooksFailedTurnSignature = nil
        let isFirstManualEvent = !pendingGoogleBooksManualTurn
        if isFirstManualEvent {
            guard identity.originFrameSessionID == activeGoogleBooksFrameSessionID,
                  identity.baselineSignature == lastGoogleBooksSignature else {
                ReaderRunLog.write("GBOOKS ignored stale manual intent")
                return
            }
            let audioWasGated =
                AudioPlayerService.shared.isQueuedSegmentGated
            let shouldResumeReadBeforeCancellation =
                isReadMode
                    && (
                        readVM?.shouldResumeAfterManualLivePageTurn == true
                            || audioWasGated
                    )
            let cancelledCompletedGate =
                cancelGoogleBooksContinuousHandoff(reason: "manual-turn")
                    || cancelGoogleBooksSpeechContinuousHandoff(
                        reason: "manual-turn"
                    )
            invalidateGoogleBooksSpeechPreload(
                reason: "manual-turn",
                preserveCandidate: false
            )
            if pendingGoogleBooksTurn {
                finishGoogleBooksTurn(reason: "manual-override")
            }
            googleBooksLateTurn = nil
            clearGoogleBooksLateTurnVisualSuppression(
                reason: "manual-turn"
            )
            pendingGoogleBooksBoundaryTurn = nil
            googleBooksCarryAdvance = nil
            activeGoogleBooksCarry = nil
            pendingGoogleBooksManualTurn = true
            googleBooksManualTurnIdentity = identity
            googleBooksManualLogicalBaseline = lastGoogleBooksSignature
            googleBooksManualPageDidChange = false
            googleBooksManualTurnCompletedGate =
                audioWasGated || cancelledCompletedGate
            googleBooksResumeReadAfterTurn =
                shouldResumeReadBeforeCancellation
            googleBooksResumeExplainAfterTurn =
                !isReadMode && (explainVM?.shouldResumeAfterManualLivePageTurn == true)
            clearGoogleBooksPageVisuals(reason: "manual-turn")
            // Entitlement refresh may have started before a VM became active.
            // It still belongs to the old page and must never activate after a
            // gesture. Suspension is based on the captured playback intent,
            // whether JS delivered `intent` first or native inferred a missed
            // gesture from the changed signature.
            readVM?.cancelPendingAccessRetryForLiveWebTurn()
            explainVM?.cancelPendingAccessRefreshForLiveWebTurn()
            if googleBooksResumeReadAfterTurn, isReadMode {
                readVM?.suspendForLiveWebTurnIntent()
            }
            if googleBooksResumeExplainAfterTurn, !isReadMode {
                explainVM?.suspendForLiveWebTurnIntent()
            }
        } else if identity != googleBooksManualTurnIdentity {
            // A delayed event from gesture N must not cancel or restart the
            // watchdog already owned by gesture N+1.
            ReaderRunLog.write("GBOOKS ignored out-of-order manual intent")
            return
        }

        if phase == "cancelled" {
            guard pendingGoogleBooksManualTurn else { return }
            guard !googleBooksManualPageDidChange else {
                ReaderRunLog.write("GBOOKS ignored reordered cancelled after changed")
                return
            }
            let cancelledSignature =
                Self.nonemptyGoogleBooksString(payload["signature"])
            guard cancelledSignature == nil
                    || cancelledSignature == googleBooksManualLogicalBaseline else {
                ReaderRunLog.write("GBOOKS ignored cancelled with non-baseline signature")
                return
            }
            if googleBooksResumeReadAfterTurn, isReadMode {
                readVM?.resumeAfterCancelledLiveWebTurnIntent()
            }
            if googleBooksResumeExplainAfterTurn, !isReadMode {
                explainVM?.resumeAfterCancelledLiveWebTurnIntent()
            }
            call("gbCompleteTurn", ["manualIntentID": identity.intentID])
            let shouldAdvanceCompletedGate =
                googleBooksManualTurnCompletedGate
                    && googleBooksResumeReadAfterTurn
                    && isReadMode
            resetGoogleBooksManualTurnState(clearResumeIntent: true)
            restoreGoogleBooksPageVisualsIfPossible(
                reason: "manual-turn-cancelled"
            )
            if shouldAdvanceCompletedGate {
                readVM?.continueAfterAdoptedPlaybackCompleted()
            }
            ReaderRunLog.write("GBOOKS manual gesture cancelled by stable signature")
            return
        }

        if phase == "intent" {
            guard !googleBooksManualPageDidChange else {
                ReaderRunLog.write("GBOOKS ignored reordered intent after changed")
                return
            }
            // Suspend future segment auto-start without discarding a cloud
            // request, Explain plan, marks, position, or quota. A late response
            // from the old page remains silent; a cancelled edge swipe resumes
            // the same work rather than starting the page over.
            guard googleBooksManualIntentProbeTask == nil else { return }
            googleBooksManualIntentProbeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: GoogleBooksPageTurnContract.manualIntentTimeoutNanoseconds
                )
                guard let self,
                      !Task.isCancelled,
                      self.pendingGoogleBooksManualTurn,
                      !self.googleBooksManualPageDidChange,
                      self.googleBooksManualTurnIdentity == identity else {
                    return
                }
                // A long press can legitimately exceed the old 2-second
                // heuristic. Never revive old-page audio merely because the
                // finger is still down; ask the same frame for visual proof.
                self.call("gbRefresh", identity.payload)
                ReaderRunLog.write("GBOOKS manual intent timeout — probing baseline")
                try? await Task.sleep(
                    nanoseconds:
                        GoogleBooksPageTurnContract
                            .manualChangeConfirmationTimeoutNanoseconds
                )
                guard !Task.isCancelled,
                      self.pendingGoogleBooksManualTurn,
                      !self.googleBooksManualPageDidChange,
                      self.googleBooksManualTurnIdentity == identity else {
                    return
                }
                self.rememberGoogleBooksRecoveryPlaybackIntent()
                self.resetGoogleBooksManualTurnState(clearResumeIntent: true)
                self.activeGoogleBooksFrameSessionID = nil
                self.googleBooksAwaitingReaderRecovery = true
                self.googleBooksReadinessRetries = 0
                self.handleEmptyGoogleBooksPage(reason: .manual)
                ReaderRunLog.write("GBOOKS unresolved manual intent entered recovery")
            }
            ReaderRunLog.write("GBOOKS manual page intent — paused current queue")
            return
        }

        guard !googleBooksManualPageDidChange else { return }
        googleBooksManualIntentProbeTask?.cancel()
        googleBooksManualIntentProbeTask = nil
        googleBooksManualPageDidChange = true
        // Do not destroy the old queue during Google's animation. A page-edge
        // gesture may rubber-band back to the original signature; the VM-level
        // suspension keeps both current and future segments silent until a
        // genuinely different rendered payload commits.
        guard googleBooksManualRestartTask == nil else { return }
        googleBooksManualRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: GoogleBooksPageTurnContract.manualChangeConfirmationTimeoutNanoseconds
            )
            guard let self,
                  !Task.isCancelled,
                  self.pendingGoogleBooksManualTurn,
                  self.googleBooksManualPageDidChange,
                  self.googleBooksManualTurnIdentity == identity else { return }
            self.rememberGoogleBooksRecoveryPlaybackIntent()
            self.resetGoogleBooksManualTurnState(clearResumeIntent: true)
            self.activeGoogleBooksFrameSessionID = nil
            self.googleBooksAwaitingReaderRecovery = true
            self.googleBooksReadinessRetries = 0
            self.handleEmptyGoogleBooksPage(reason: .manual)
            ReaderRunLog.write("GBOOKS manual page extraction timeout")
        }
        ReaderRunLog.write("GBOOKS manual page animation — suspended pending stable commit")
    }

    private func resetGoogleBooksManualTurnState(clearResumeIntent: Bool) {
        googleBooksManualIntentProbeTask?.cancel()
        googleBooksManualIntentProbeTask = nil
        googleBooksManualRestartTask?.cancel()
        googleBooksManualRestartTask = nil
        pendingGoogleBooksManualTurn = false
        googleBooksManualTurnIdentity = nil
        googleBooksManualLogicalBaseline = ""
        googleBooksManualPageDidChange = false
        googleBooksManualTurnCompletedGate = false
        if clearResumeIntent {
            googleBooksResumeReadAfterTurn = false
            googleBooksResumeExplainAfterTurn = false
        }
    }

    @discardableResult
    private func requestGoogleBooksNextPage() -> Bool {
        guard isGoogleBooks, didInit else { return false }
        if pendingGoogleBooksTurn { return true }
        guard let originFrameSessionID = activeGoogleBooksFrameSessionID,
              !lastGoogleBooksSignature.isEmpty else {
            ReaderRunLog.write("GBOOKS next page deferred without owned baseline")
            return false
        }
        expireGoogleBooksLateTurnIfNeeded()
        guard googleBooksFailedTurnSignature != lastGoogleBooksSignature else {
            ReaderRunLog.write("GBOOKS suppressed duplicate action after confirmed turn failure")
            return false
        }
        googleBooksTurnPriorCursor = googleBooksConsumedCursor
        googleBooksConsumedCursor =
            isReadMode ? googleBooksPageCompletionCursor : nil
        googleBooksLateTurn = nil
        clearGoogleBooksLateTurnVisualSuppression(
            reason: "new-automatic-turn"
        )
        pendingGoogleBooksTurn = true
        googleBooksTurnOwner = isReadMode ? .read : .explain
        googleBooksTurnIdentity = GoogleBooksTurnIdentity(
            turnID: UUID().uuidString,
            baselineSignature: lastGoogleBooksSignature,
            originFrameSessionID: originFrameSessionID
        )
        if var handoff = continuousGoogleBooksHandoff,
           handoff.preview.sourceSignature == lastGoogleBooksSignature {
            handoff.issuedTurnIdentity = googleBooksTurnIdentity
            continuousGoogleBooksHandoff = handoff
        }
        if var handoff = continuousGoogleBooksSpeechHandoff,
           handoff.prepared.candidate.sourceSignature
                == lastGoogleBooksSignature {
            handoff.issuedTurnIdentity = googleBooksTurnIdentity
            continuousGoogleBooksSpeechHandoff = handoff
        }
        googleBooksTurnLogicalBaseline = lastGoogleBooksSignature
        // Keep the last owned overlay while Google animates the old page.
        // The commit path clears it only after stable new-page evidence and a
        // new DOM mapping exist. Clearing here made the final highlight vanish
        // seconds before the AVPlayerItem actually finished.
        ReaderRunLog.write(
            "GBOOKS next page requested sig=\(String(lastGoogleBooksSignature.prefix(24))) " +
            "visuals=retained-until-commit"
        )
        if isApplicationActive {
            // 主帧只有转发壳，真正的翻页在跨源阅读帧里执行。
            googleBooksTurnActionDeferredForForeground = false
            call("gbNextPage", googleBooksTurnIdentity?.payload ?? [:])
            armGoogleBooksTurnTimeout()
        } else {
            googleBooksTurnSuspendedInBackground = true
            googleBooksTurnActionDeferredForForeground = true
            ReaderRunLog.write("GBOOKS next page deferred until foreground")
        }
        return true
    }

    private func armGoogleBooksTurnTimeout() {
        googleBooksTurnTimeout?.cancel()
        googleBooksTurnTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: GoogleBooksPageTurnContract.turnConfirmationTimeoutNanoseconds
            )
            guard let self, !Task.isCancelled, self.pendingGoogleBooksTurn else { return }
            // 只观察不重试：重试点击会跳页。
            self.finishGoogleBooksTurn(reason: "confirmation-timeout")
        }
    }

    private func finishGoogleBooksTurn(
        reason: String,
        preserveLateResult: Bool = true
    ) {
        googleBooksTurnTimeout?.cancel()
        googleBooksTurnTimeout = nil
        googleBooksTurnSuspendedInBackground = false
        googleBooksTurnActionDeferredForForeground = false
        guard pendingGoogleBooksTurn else { return }
        let wasAwaitingReaderRecovery =
            googleBooksAwaitingReaderRecovery
        let owner = googleBooksTurnOwner
        let priorCursor = googleBooksTurnPriorCursor
        let consumedCursor = googleBooksConsumedCursor
        let boundaryTurn = pendingGoogleBooksBoundaryTurn
        let identity = googleBooksTurnIdentity
        let logicalBaseline = googleBooksTurnLogicalBaseline
        pendingGoogleBooksTurn = false
        googleBooksTurnOwner = nil
        googleBooksTurnIdentity = nil
        googleBooksTurnLogicalBaseline = ""
        googleBooksTurnPriorCursor = nil
        ReaderRunLog.write("GBOOKS turn resolved reason=\(reason)")
        guard reason != "committed" else { return }
        // A failed/abandoned turn no longer owns reader recovery. Leaving this
        // flag set would suppress every future highlight and mark forever when
        // no late payload arrives. A still-late page remains protected by the
        // one-shot late-turn identity below and clears any surfaced error when
        // it successfully commits.
        googleBooksReadinessTask?.cancel()
        googleBooksReadinessTask = nil
        googleBooksReadinessRetries = 0
        googleBooksAwaitingReaderRecovery = false
        if wasAwaitingReaderRecovery,
            reason != "manual-override",
           reason != "mode-switched" {
            livePlatform?.reportReaderError(
                AppLocalized("内容暂时无法打开，请重试")
            )
        }
        if reason != "mode-switched", reason != "manual-override" {
            googleBooksFailedTurnSignature = lastGoogleBooksSignature
        }
        let shouldCompleteGatedRead =
            owner == .read
                && reason != "mode-switched"
                && reason != "manual-override"
        cancelGoogleBooksContinuousHandoff(
            reason: "turn-\(reason)",
            completeGatedPage: shouldCompleteGatedRead
        )
        cancelGoogleBooksSpeechContinuousHandoff(
            reason: "turn-\(reason)",
            completeGatedPage: shouldCompleteGatedRead
        )
        if !preserveLateResult {
            invalidateGoogleBooksReadPreload(
                reason: "turn-\(reason)",
                preservePrediction: false
            )
            invalidateGoogleBooksExplainPrefetch(
                reason: "turn-\(reason)"
            )
        }
        if preserveLateResult, let owner, let identity {
            let expiresAt = Date().addingTimeInterval(30)
            googleBooksLateTurn = GoogleBooksLateTurn(
                identity: identity,
                logicalBaselineSignature:
                    logicalBaseline.isEmpty
                        ? lastGoogleBooksSignature
                        : logicalBaseline,
                owner: owner,
                priorCursor: priorCursor,
                consumedCursor: consumedCursor,
                boundaryTurn: boundaryTurn,
                shouldResume: reason != "mode-switched"
                    && reason != "manual-override",
                expiresAt: expiresAt
            )
            armGoogleBooksLateTurnVisualSuppression(
                identity: identity,
                expiresAt: expiresAt
            )
        } else {
            googleBooksLateTurn = nil
            clearGoogleBooksLateTurnVisualSuppression(
                reason: "turn-\(reason)"
            )
        }
        pendingGoogleBooksBoundaryTurn = nil
        googleBooksCarryAdvance = nil
        activeGoogleBooksCarry = nil
        googleBooksConsumedCursor = nil
        automaticAppReviewContinuation.cancel()
        if owner == .explain { explainVM?.finishLivePageContinuation() }
        if GoogleBooksPageVisualStateContract.shouldRestoreAfterFailedTurn(
            preserveLateResult: preserveLateResult
        ) {
            restoreGoogleBooksPageVisualsIfPossible(
                reason: "turn-\(reason)"
            )
        }
    }

    private func handleEmptyGoogleBooksPage(reason: GoogleBooksPageEventReason) {
        if didInit, !googleBooksAwaitingReaderRecovery {
            if pendingGoogleBooksTurn {
                ReaderRunLog.write(
                    "GBOOKS page empty after automatic turn — observe until readable"
                )
                googleBooksAwaitingReaderRecovery = true
            } else {
                // A confirmed manual/reflow signature already stopped the old
                // page. Do not silently keep its stale VM forever when the new
                // DOM is temporarily empty; probe until readable or surface a
                // visible retry/rebind state.
                googleBooksAwaitingReaderRecovery = true
                googleBooksReadinessRetries = 0
                ReaderRunLog.write(
                    "GBOOKS empty changed page awaiting readable DOM reason=\(reason.rawValue)"
                )
            }
        }

        let maximumAttempts = pendingGoogleBooksTurn ? 6 : 3
        guard googleBooksReadinessRetries < maximumAttempts else {
            googleBooksReadinessTask?.cancel()
            googleBooksReadinessTask = nil
            if pendingGoogleBooksTurn {
                ReaderRunLog.write(
                    "GBOOKS automatic turn remained empty after readiness retries"
                )
                finishGoogleBooksTurn(reason: "empty-page-timeout")
                return
            }
            googleBooksAwaitingReaderRecovery = false
            googleBooksReadinessRetries = 0
            livePlatform?.reportReaderError(
                AppLocalized("内容暂时无法打开，请重试")
            )
            ReaderRunLog.write("GBOOKS initial reader remained empty after readiness retries")
            return
        }
        googleBooksReadinessRetries += 1
        let attempt = googleBooksReadinessRetries
        googleBooksReadinessTask?.cancel()
        googleBooksReadinessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 900_000_000)
            guard let self,
                  !Task.isCancelled,
                  !self.didInit || self.googleBooksAwaitingReaderRecovery,
                  self.googleBooksReadinessRetries == attempt else { return }
            self.call(
                "gbRefresh",
                self.pendingGoogleBooksTurn
                    ? (self.googleBooksTurnIdentity?.payload ?? [:])
                    : [:]
            )
            ReaderRunLog.write(
                "GBOOKS readiness retry \(attempt)/\(maximumAttempts) " +
                "turn=\(self.pendingGoogleBooksTurn ? "Y" : "N")"
            )
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled,
                  !self.didInit || self.googleBooksAwaitingReaderRecovery,
                  self.googleBooksReadinessRetries == attempt else { return }
            self.handleEmptyGoogleBooksPage(reason: .refresh)
        }
    }

    private func invalidateGoogleBooksLivePage(
        reason: String,
        clearConsumedCursor: Bool
    ) {
        rememberGoogleBooksRecoveryPlaybackIntent()
        activeGoogleBooksFrameSessionID = nil
        googleBooksFailedTurnSignature = nil
        googleBooksLateTurn = nil
        clearGoogleBooksLateTurnVisualSuppression(
            reason: "reader-invalidated"
        )
        googleBooksMainFrameWatchdogTask?.cancel()
        googleBooksMainFrameWatchdogTask = nil
        googleBooksReadinessTask?.cancel()
        googleBooksReadinessTask = nil
        googleBooksReadinessRetries = 0
        googleBooksAwaitingReaderRecovery = true
        googleBooksTurnTimeout?.cancel()
        googleBooksTurnTimeout = nil
        googleBooksTurnSuspendedInBackground = false
        googleBooksTurnActionDeferredForForeground = false
        pendingGoogleBooksTurn = false
        googleBooksTurnOwner = nil
        googleBooksTurnIdentity = nil
        googleBooksTurnLogicalBaseline = ""
        googleBooksTurnPriorCursor = nil
        pendingGoogleBooksBoundaryTurn = nil
        googleBooksCarryAdvance = nil
        activeGoogleBooksCarry = nil
        cancelGoogleBooksContinuousHandoff(
            reason: "live-page-\(reason)"
        )
        invalidateGoogleBooksReadPreload(
            reason: "live-page-\(reason)",
            preservePrediction: false
        )
        invalidateGoogleBooksExplainPrefetch(
            reason: "live-page-\(reason)"
        )
        automaticAppReviewContinuation.cancel()
        resetGoogleBooksManualTurnState(clearResumeIntent: true)
        if clearConsumedCursor {
            googleBooksConsumedCursor = nil
            googleBooksPageCompletionCursor = nil
            googleBooksCurrentBoundarySourceUTF16End = nil
        }
        lastGoogleBooksSignature = ""
        lastGoogleBooksEvidence = nil
        lastGoogleBooksParagraphTexts = []
        lastGoogleBooksLanguage = ""
        googleBooksReadDOMSegments = []
        googleBooksExplainDOMSegments = []
        if isReadMode {
            readVM?.stop()
        } else {
            explainVM?.stop()
        }
        shownMarkIds.removeAll()
        call("clearHighlight")
        call("clearMarks")
        ReaderRunLog.write("GBOOKS live page invalidated reason=\(reason)")
    }

    private func rememberGoogleBooksRecoveryPlaybackIntent() {
        guard isGoogleBooks, !googleBooksRecoveryShouldResume else { return }
        let readShouldResume =
            isReadMode
                && (
                    readVM?.shouldResumeAfterManualLivePageTurn == true
                        || googleBooksResumeReadAfterTurn
                        || (
                            pendingGoogleBooksTurn
                                && googleBooksTurnOwner == .read
                        )
                )
        let explainShouldResume =
            !isReadMode
                && (
                    explainVM?.shouldResumeAfterManualLivePageTurn == true
                        || googleBooksResumeExplainAfterTurn
                        || (
                            pendingGoogleBooksTurn
                                && googleBooksTurnOwner == .explain
                        )
                )
        if readShouldResume {
            googleBooksRecoveryOwner = .read
            googleBooksRecoveryShouldResume = true
        } else if explainShouldResume {
            googleBooksRecoveryOwner = .explain
            googleBooksRecoveryShouldResume = true
        }
    }

    /// Play 图书是 SPA，翻页只改 URL 的 pg 参数 —— 地址本身就是可续读的进度锚。
    private func recordGoogleBooksLocation(
        _ href: String,
        fingerprint: String,
        payload: [String: Any]
    ) {
        guard let livePlatform,
              !href.isEmpty,
              !fingerprint.isEmpty,
              let readVM,
              allowsLiveMainFrameNavigation(URL(string: href)) else {
            return
        }
        livePlatform.updateProgress(
            bookID: readVM.document.id,
            readerURL: href,
            fingerprint: fingerprint,
            progressLabel: nil,
            scrollOffset: Self.double(payload["scrollOffset"]),
            scrollMaximum: Self.double(payload["scrollMaximum"]),
            scrollRatio: Self.double(payload["scrollRatio"]),
            sourceParagraphIndex:
                Self.exactNonnegativeInteger(
                    payload["sourceParagraphIndex"]
                ),
            sourceUTF16Start:
                Self.exactNonnegativeInteger(
                    payload["sourceUTF16Start"]
                ),
            sourceUTF16End:
                Self.exactNonnegativeInteger(
                    payload["sourceUTF16End"]
                )
        )
    }

    private func restoreOReillyReadingAnchorIfPossible() {
        guard livePlatform == .oreilly,
              let readVM,
              let anchor = OReillyLibraryStore.shared.anchor(
                  for: readVM.document.id
              ),
              allowsLiveMainFrameNavigation(URL(string: anchor.readerURL))
        else {
            return
        }
        var payload: [String: Any] = [
            "expectedHref": anchor.readerURL,
            "pageFingerprint": anchor.pageFingerprint,
        ]
        if let value = anchor.scrollOffset {
            payload["scrollOffset"] = value
        }
        if let value = anchor.scrollMaximum {
            payload["scrollMaximum"] = value
        }
        if let value = anchor.scrollRatio {
            payload["scrollRatio"] = value
        }
        if let value = anchor.sourceParagraphIndex {
            payload["sourceParagraphIndex"] = value
        }
        if let value = anchor.sourceUTF16Start {
            payload["sourceUTF16Start"] = value
        }
        if let value = anchor.sourceUTF16End {
            payload["sourceUTF16End"] = value
        }
        call("gbRestoreAnchor", payload)
        ReaderRunLog.write(
            "OREILLY requested in-chapter anchor restore " +
                "source=\(anchor.sourceParagraphIndex ?? -1):" +
                "\(anchor.sourceUTF16Start ?? -1)"
        )
    }

    // MARK: - native → JS

    private func installGoogleBooksDOMMapping() {
        guard isGoogleBooks else { return }
        call("init", [
            "segments": isReadMode
                ? googleBooksReadDOMSegments
                : googleBooksExplainDOMSegments,
            "color": AppSettings.shared.highlightColorHex,
        ])
    }

    private var googleBooksPageVisualsAreSuspended: Bool {
        isGoogleBooks
            && GoogleBooksPageVisualStateContract.shouldSuppress(
                pendingAutomaticTurn: pendingGoogleBooksTurn,
                pendingManualTurn: pendingGoogleBooksManualTurn,
                awaitingReaderRecovery: googleBooksAwaitingReaderRecovery,
                awaitingLateAutomaticTurn:
                    googleBooksLateTurnVisualsSuppressed
            )
    }

    /// Clear before ownership can move to a replacement iframe. The ordinary
    /// commit clear remains as a second pass for the newly-owned frame.
    private func clearGoogleBooksPageVisuals(reason: String) {
        guard isGoogleBooks else { return }
        shownMarkIds.removeAll()
        call("clearHighlight")
        call("clearMarks")
        ReaderRunLog.write("GBOOKS page visuals cleared reason=\(reason)")
    }

    private func restoreGoogleBooksPageVisualsIfPossible(reason: String) {
        guard isGoogleBooks,
              didInit,
              !googleBooksPageVisualsAreSuspended else { return }
        installGoogleBooksDOMMapping()
        call("clearHighlight")
        call("clearMarks")
        if isReadMode, let highlight = readVM?.webHighlight {
            pushHighlight(highlight)
        } else if !isReadMode, let explainVM {
            shownMarkIds.removeAll()
            pushMarks(explainVM.activeMarks)
        }
        ReaderRunLog.write("GBOOKS page visuals restored reason=\(reason)")
    }

    private func pushHighlight(_ cmd: WebHighlightCmd) {
        guard didInit else { return }
        guard !googleBooksPageVisualsAreSuspended else { return }
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
        guard !googleBooksPageVisualsAreSuspended else { return }
        if marks.isEmpty {
            shownMarkIds.removeAll()
            call("clearMarks")
            return
        }
        for m in marks where !shownMarkIds.contains(m.id.uuidString) {
            // Every WebReader DOM API is UTF-16. Invalid page-local marks are
            // fail-open (skip), never fall back to Character offsets after an
            // emoji and never mark them shown before successful conversion.
            guard let domRange = explainVM?.webUTF16Range(for: m) else { continue }
            shownMarkIds.insert(m.id.uuidString)
            var payload: [String: Any] = [
                "id": m.id.uuidString,
                "paragraphIndex": m.paragraphIndex,
                "charStart": domRange.lowerBound,
                "charEnd": domRange.upperBound,
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
        let modeChanged = readMode != isReadMode
        if isGoogleBooks, readMode != isReadMode, !readMode {
            // Remove the read-owned speculative suffix before Explain claims
            // AudioPlayer ownership; afterwards removal is intentionally
            // rejected by the ownership guard.
            cancelGoogleBooksContinuousHandoff(reason: "mode-switched")
            cancelGoogleBooksSpeechContinuousHandoff(
                reason: "mode-switched"
            )
        }
        // Make mode ownership and the bridge flag one main-actor transaction.
        // SwiftUI's ReaderHost and updateUIView callbacks can arrive in either
        // order; idempotent VM activate/deactivate methods make the later
        // duplicate harmless.
        if readMode != isReadMode {
            if readMode {
                explainVM?.deactivate()
                readVM?.activate()
            } else {
                readVM?.deactivate()
                explainVM?.activate()
            }
        }
        if isGoogleBooks, pendingGoogleBooksTurn {
            let incomingOwner: GoogleBooksTurnOwner = readMode ? .read : .explain
            if googleBooksTurnOwner != incomingOwner {
                // The physical turn may already be in flight, but continuation
                // intent belongs to the mode that completed the old page.
                // Resolve it permanently now; switching back before the late
                // payload arrives must not resurrect automatic continuation.
                automaticAppReviewContinuation.cancel()
                finishGoogleBooksTurn(reason: "mode-switched")
            }
        }
        if isGoogleBooks, readMode != isReadMode {
            if var late = googleBooksLateTurn {
                // Mode ownership is monotonic for an issued physical turn.
                // Switching back before a late page lands must not resurrect
                // the old mode's continuation intent.
                late.shouldResume = false
                googleBooksLateTurn = late
            }
            if pendingGoogleBooksManualTurn {
                googleBooksResumeReadAfterTurn = false
                googleBooksResumeExplainAfterTurn = false
            }
            pendingGoogleBooksBoundaryTurn = nil
            googleBooksCarryAdvance = nil
            activeGoogleBooksCarry = nil
            if !readMode {
                invalidateGoogleBooksReadPreload(
                    reason: "mode-switched-to-explain",
                    preservePrediction: true
                )
            } else {
                invalidateGoogleBooksExplainPrefetch(
                    reason: "mode-switched-to-read"
                )
            }
        }
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
        if isGoogleBooks, didInit, modeChanged {
            installGoogleBooksDOMMapping()
        }
        call("setActive", ["active": readMode])
        if isWeRead, readMode {
            maybeStartWeReadPreviewPrefetch()
        } else if isWeRead {
            maybeStartWeReadExplainPrefetch()
        } else if isGoogleBooks, readMode {
            maybeStartGoogleBooksReadPreload()
            maybeStartGoogleBooksSpeechPreload()
        } else if isGoogleBooks {
            maybeStartGoogleBooksExplainPrefetch()
        }
    }

    func refocusIfNeeded(_ token: Int, readMode: Bool) {
        guard token != lastRefocusToken else { return }
        lastRefocusToken = token
        // Google Play Books and Kobo own pagination through transforms /
        // columns. Generic element.scrollIntoView during an orientation burst
        // can move that internal surface after it has already reflowed,
        // producing the visible "two columns, then one column" jump and
        // exposing edge fragments as new speech paragraphs.
        guard !isGoogleBooks else {
            ReaderRunLog.write(
                "\(livePlatform?.logPrefix ?? "LIVEWEB") refocus retained paged surface token=\(token)"
            )
            return
        }
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
        if isGoogleBooks {
            guard lastApplicationActivityState != isActive else { return }
            lastApplicationActivityState = isActive
            isApplicationActive = isActive
            if !isActive {
                if pendingGoogleBooksTurn {
                    // iOS suspends WebKit timers/evaluation in the background.
                    // Do not let a wall-clock timeout discard semantic turn
                    // ownership while the frame has had no chance to respond.
                    googleBooksTurnTimeout?.cancel()
                    googleBooksTurnTimeout = nil
                    googleBooksTurnSuspendedInBackground = true
                }
                return
            }
            guard didInit else { return }
            if pendingGoogleBooksTurn, googleBooksTurnSuspendedInBackground {
                googleBooksTurnSuspendedInBackground = false
                if googleBooksTurnActionDeferredForForeground {
                    googleBooksTurnActionDeferredForForeground = false
                    call("gbNextPage", googleBooksTurnIdentity?.payload ?? [:])
                    ReaderRunLog.write(
                        "GBOOKS sent foreground-deferred next page " +
                        "visuals=retained-until-commit"
                    )
                } else {
                    call("gbRefresh", googleBooksTurnIdentity?.payload ?? [:])
                }
                armGoogleBooksTurnTimeout()
            } else {
                call("gbRefresh")
            }
            return
        }
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let livePlatform else {
            decisionHandler(.allow)
            return
        }

        // Google owns subresource/frame navigation. The native security
        // boundary is enforced when a frame tries to post a bridge message.
        // `targetFrame == nil` is a new-window/top-level attempt and is subject
        // to the same strict reader URL policy.
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        guard allowsLiveMainFrameNavigation(
            navigationAction.request.url
        ) else {
            decisionHandler(.cancel)
            rejectGoogleBooksMainFrameNavigation(
                navigationAction.request.url,
                phase: "action"
            )
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let livePlatform {
            if allowsLiveMainFrameNavigation(webView.url) {
                googleBooksNetworkRetries = 0
                if (!didInit || googleBooksAwaitingReaderRecovery),
                   googleBooksReadinessTask == nil,
                   googleBooksMainFrameWatchdogTask == nil {
                    // Main-frame success does not prove that Google created the
                    // cross-origin reader iframe. A missing/blocked frame emits
                    // no rendered=[] message. The injected frame waits up to
                    // 15 seconds, so this independent watchdog deliberately
                    // starts recovery only after that boot budget expires.
                    googleBooksMainFrameWatchdogTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(
                            nanoseconds: GoogleBooksPageTurnContract.readerBootstrapTimeoutNanoseconds
                        )
                        guard let self,
                              !Task.isCancelled,
                              !self.didInit || self.googleBooksAwaitingReaderRecovery else { return }
                        self.googleBooksMainFrameWatchdogTask = nil
                        self.handleEmptyGoogleBooksPage(reason: .initial)
                    }
                }
                return
            }
            ReaderRunLog.write(
                "\(livePlatform.logPrefix) reader redirected away " +
                "host=\(webView.url?.host ?? "")"
            )
            invalidateGoogleBooksLivePage(
                reason: "redirected-away-from-reader",
                clearConsumedCursor: true
            )
            if attemptGoogleBooksLocalRecovery(reason: "redirected-away-from-reader") {
                return
            }
            livePlatform.reportReaderError(expiredSessionMessage)
            return
        }
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
        if isGoogleBooks {
            handleGoogleBooksNavigationFailure(webView, error: error, phase: "provisional")
            return
        }
        handleWeReadNavigationFailure(webView, error: error, phase: "provisional")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isGoogleBooks {
            handleGoogleBooksNavigationFailure(webView, error: error, phase: "committed")
            return
        }
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
        if livePlatform != nil,
           navigationResponse.isForMainFrame,
           !allowsLiveMainFrameNavigation(navigationResponse.response.url) {
            decisionHandler(.cancel)
            rejectGoogleBooksMainFrameNavigation(
                navigationResponse.response.url,
                phase: "response"
            )
            return
        }
        if isWeRead,
           navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            lastWeReadMainFrameStatus = http.statusCode
            ReaderRunLog.write("WEREAD response status=\(http.statusCode) url=\(http.url?.absoluteString ?? "")")
        }
        decisionHandler(.allow)
    }

    private func rejectGoogleBooksMainFrameNavigation(_ url: URL?, phase: String) {
        guard let livePlatform else { return }
        ReaderRunLog.write(
            "\(livePlatform.logPrefix) blocked main navigation phase=\(phase) " +
            "host=\(url?.host?.lowercased() ?? "") path=\(url?.path ?? "")"
        )
        // If the reader has already committed, cancellation preserves the
        // current page and playback; an incidental external link should simply
        // be inert. Before the first page exists, a redirect away is normally
        // an expired Google session and must surface the rebind recovery UI.
        guard !didInit else { return }
        invalidateGoogleBooksLivePage(
            reason: "blocked-main-navigation-\(phase)",
            clearConsumedCursor: true
        )
        livePlatform.reportReaderError(expiredSessionMessage)
    }

    private var expiredSessionMessage: String {
        switch livePlatform {
        case .kobo:
            return AppLocalized("Kobo 登录已过期，请重新绑定 Kobo。")
        case .oreilly:
            return AppLocalized("O’Reilly 登录已过期，请重新绑定 O’Reilly。")
        case .googleBooks, .none:
            return AppLocalized("Google 登录已过期，请重新绑定 Google Play 图书。")
        }
    }

    private func handleKoboMissingSession() {
        guard livePlatform == .kobo else { return }
        beginKoboSessionRecovery(reason: "missing-session")
    }

    /// A Kobo account cookie can remain valid while the short-lived reader
    /// service session has disappeared. Retry from origin first; if that fails,
    /// reissue the original trusted reader request without cache. Cookies,
    /// sessionStorage and the shared WKWebsiteDataStore remain untouched, so
    /// Google and Kobo account sign-in are preserved.
    private func beginKoboSessionRecovery(reason: String) {
        guard livePlatform == .kobo,
              koboSessionRecoveryTask == nil,
              let webView else { return }
        guard koboSessionRecoveryAttempts < 2 else {
            ReaderRunLog.write(
                "KOBO session recovery exhausted reason=\(reason)"
            )
            livePlatform?.reportReaderError(
                AppLocalized(
                    "Kobo 阅读会话暂时失效。请重试打开；仍失败时再重新登录 Kobo。"
                )
            )
            return
        }

        koboSessionRecoveryAttempts += 1
        let attempt = koboSessionRecoveryAttempts
        livePlatform?.clearReaderError()
        onLiveWebNeedsLoadingCover?()
        invalidateGoogleBooksLivePage(
            reason: "kobo-session-\(reason)-\(attempt)",
            clearConsumedCursor: false
        )
        ReaderRunLog.write(
            "KOBO session recovery attempt=\(attempt)/2 reason=\(reason)"
        )

        koboSessionRecoveryTask = Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(
                nanoseconds: attempt == 1 ? 450_000_000 : 850_000_000
            )
            guard let self, let webView, !Task.isCancelled else { return }
            self.koboSessionRecoveryTask = nil
            if attempt == 1 {
                webView.reloadFromOrigin()
                return
            }

            let rawTarget =
                self.readVM?.document.sourceURL
                    ?? self.livePlatform?.canonicalReaderURL(
                        bookID: self.liveBookID
                    )
                    ?? webView.url?.absoluteString
            guard let rawTarget, let target = URL(string: rawTarget) else {
                self.livePlatform?.reportReaderError(
                    AppLocalized("Kobo 内容暂时无法打开，请重试。")
                )
                return
            }
            guard self.livePlatform == .kobo else { return }
            let request = URLRequest(
                url: target,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 30
            )
            webView.load(request)
        }
    }

    private static func isTransientNetworkError(_ code: Int) -> Bool {
        [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
         NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
         NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed].contains(code)
    }

    private func attemptGoogleBooksLocalRecovery(reason: String) -> Bool {
        guard let livePlatform,
              !didAttemptGoogleBooksLocalRecovery,
              let webView,
              let readVM,
              let fallback = livePlatform.localRecoveryURL(
                bookID: readVM.document.id,
                failedURL: readVM.document.sourceURL
              ),
              let url = URL(string: fallback) else { return false }
        didAttemptGoogleBooksLocalRecovery = true
        livePlatform.clearReaderError()
        ReaderRunLog.write(
            "\(livePlatform.logPrefix) local entry recovery reason=\(reason)"
        )
        webView.load(URLRequest(url: url))
        return true
    }

    private func handleGoogleBooksNavigationFailure(
        _ webView: WKWebView,
        error: Error,
        phase: String
    ) {
        guard let livePlatform else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        ReaderRunLog.write(
            "\(livePlatform.logPrefix) navigation failed " +
            "phase=\(phase) code=\(nsError.code)"
        )
        invalidateGoogleBooksLivePage(
            reason: "navigation-\(phase)-\(nsError.code)",
            clearConsumedCursor: true
        )
        if Self.isTransientNetworkError(nsError.code) {
            if googleBooksNetworkRetries < 2 {
                googleBooksNetworkRetries += 1
                if webView.url != nil {
                    webView.reload()
                } else if let raw = readVM?.document.sourceURL, let url = URL(string: raw) {
                    webView.load(URLRequest(url: url))
                }
                return
            }
            // Connectivity failures say nothing about the validity of a saved
            // Google `pg` anchor. Preserve it so an offline retry cannot rewind
            // the user's book to its canonical first page.
            livePlatform.reportReaderError(AppLocalized("网络连接失败，请重试。"))
            return
        }
        if attemptGoogleBooksLocalRecovery(reason: "navigation-\(phase)-\(nsError.code)") {
            return
        }
        livePlatform.reportReaderError(AppLocalized("网络连接失败，请重试。"))
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
        if let livePlatform {
            ReaderRunLog.write(
                "\(livePlatform.logPrefix) web content process terminated — reloading reader"
            )
            invalidateGoogleBooksLivePage(
                reason: "web-content-process-terminated",
                clearConsumedCursor: true
            )
            if webView.url != nil {
                webView.reload()
            } else if let raw = readVM?.document.sourceURL, let url = URL(string: raw) {
                webView.load(URLRequest(url: url))
            } else {
                livePlatform.reportReaderError(AppLocalized("网络连接失败，请重试。"))
            }
            return
        }
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
        var routedPayload = payload
        if isGoogleBooks,
           routedPayload["__gbFrameSessionID"] == nil,
           let frameSessionID = activeGoogleBooksFrameSessionID {
            routedPayload["__gbFrameSessionID"] = frameSessionID
        }
        var arg = ""
        if !routedPayload.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: routedPayload),
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

    private func acceptsActiveGoogleBooksFrameEvent(_ payload: [String: Any]) -> Bool {
        guard isGoogleBooks,
              livePlatform?.acceptsPayloadSource(
                  payload["source"] as? String
              ) == true,
              let activeGoogleBooksFrameSessionID,
              GoogleBooksPageTurnContract.frameSessionID(from: payload)
                == activeGoogleBooksFrameSessionID else {
            ReaderRunLog.write("GBOOKS ignored event from non-owner frame")
            return false
        }
        return true
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func exactNonnegativeInteger(
        _ value: Any?
    ) -> Int? {
        guard let number = double(value),
              number.isFinite,
              number >= 0,
              number <= Double(Int.max),
              number.rounded(.towardZero) == number else {
            return nil
        }
        return Int(number)
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
