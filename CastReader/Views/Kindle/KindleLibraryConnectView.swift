//
//  KindleLibraryConnectView.swift
//  CastReader
//

import SwiftUI
import WebKit

/// 连接状态机已提升为与书库无关的共享类型（见
/// `BoundLibraryOnboardingComponents.swift`），微信读书引导复用同一组语义。
/// 保留这个名字以免改动 Kindle 侧既有调用点。
typealias KindleOnboardingConnectionState = BoundLibraryOnboardingConnectionState

struct KindleLibraryConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: KindleLibrarySyncViewModel
    @ObservedObject private var store = KindleLibraryStore.shared

    init(
        analyticsSession: AnalyticsLibraryConnectionSession? = nil,
        entryTapAlreadyTracked: Bool = false
    ) {
        let session = analyticsSession ?? AnalyticsLibraryConnectionSession(
            source: .kindle,
            entryPoint: "kindle_connect"
        )
        _model = StateObject(
            wrappedValue: KindleLibrarySyncViewModel(
                analyticsSession: session,
                entryTapAlreadyTracked: entryTapAlreadyTracked
            )
        )
    }

    var body: some View {
        NavigationView {
            ZStack {
                KindleWebView(webView: model.webView)
                    .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 0) {
                    storefrontBar
                    Spacer()
                    statusBar
                }
            }
            .navigationTitle("绑定 Kindle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("同步") { Task { await model.syncLibrary() } }
                        .disabled(model.isSyncing)
                }
            }
            .onAppear {
                model.recordConnectionPresented()
                model.loadIfNeeded()
            }
            .onDisappear { model.closeConnection() }
        }
        .navigationViewStyle(.stack)
    }

    private var storefrontBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("亚马逊站点")
                    .font(.caption2)
                    .foregroundColor(AppTheme.mutedForeground)
                Text("选择你的 Kindle 书籍所在的亚马逊站点。")
                    .font(.caption)
                    .foregroundColor(AppTheme.foreground)
                    .lineLimit(2)
            }
            Spacer()
            Menu {
                ForEach(store.orderedStorefrontCandidates) { storefront in
                    Button {
                        model.switchStorefront(to: storefront)
                    } label: {
                        Label(
                            "\(storefront.flag) \(storefront.displayName)",
                            systemImage: storefront.id == store.boundStorefrontID ? "checkmark" : "globe"
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("\(store.boundStorefront.flag) \(store.boundStorefront.displayName)")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(AppTheme.primary.opacity(0.12), in: Capsule())
            }
            .disabled(model.isSyncing)
            .accessibilityIdentifier("kindleStorefrontMenu")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if model.isSyncing {
                    ProgressView()
                } else {
                    Image(systemName: store.boundBooks.isEmpty ? "book.closed" : "checkmark.circle.fill")
                        .foregroundColor(store.boundBooks.isEmpty ? AppTheme.primary : .green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                        .lineLimit(2)
                    Text(model.secondaryStatusText(bookCount: store.boundBooks.count))
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)
                }
                Spacer()
                if !store.boundBooks.isEmpty {
                    Button("完成") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.primary)
                }
            }

            if model.currentReaderBook != nil {
                HStack(spacing: 10) {
                    Text("当前是 Kindle 书籍页面，请回到书架后同步。")
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(2)
                    Spacer()
                    Button("Kindle 书架") {
                        model.loadLibrary()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.primary, in: Capsule())
                }
            }

            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundColor(AppTheme.destructive)
                    .lineLimit(2)
            }

            if model.showsEmptyShelfRecovery {
                VStack(alignment: .leading, spacing: 8) {
                    Text("书架是空的？")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                    Text("你的书可能在其他亚马逊站点。")
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.recoveryStorefronts) { storefront in
                                Button("\(storefront.flag) \(storefront.displayName)") {
                                    model.switchStorefront(to: storefront)
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundColor(AppTheme.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(AppTheme.primary.opacity(0.1), in: Capsule())
                                .disabled(model.isSyncing)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("kindleEmptyShelfRecovery")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

struct KindleViewportCrop: Equatable {
    var scale: CGFloat
    var heightScale: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat

    init(scale: CGFloat, heightScale: CGFloat? = nil, offsetX: CGFloat, offsetY: CGFloat) {
        self.scale = scale
        self.heightScale = heightScale ?? scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    static let identity = KindleViewportCrop(scale: 1, heightScale: 1, offsetX: 0, offsetY: 0)

    var isIdentity: Bool {
        abs(scale - 1) < 0.001 &&
            abs(heightScale - 1) < 0.001 &&
            abs(offsetX) < 0.5 &&
            abs(offsetY) < 0.5
    }
}

/// Cookie consent remains Amazon UI. CastReader only switches viewport presentation so the
/// original action area is reachable, then returns to the normal reader crop after it disappears.
enum KindleCookieConsentViewportPolicy {
    static func effectiveCrop(
        normalCrop: KindleViewportCrop,
        isConsentVisible: Bool
    ) -> KindleViewportCrop {
        isConsentVisible ? .identity : normalCrop
    }
}

/// Every operation that can observe or mutate the paged Kindle surface passes
/// through one policy. This keeps a visible Amazon notice from being captured,
/// OCR'd, paged past, or used to start more TTS work while the user is handling
/// Amazon's own UI.
enum KindleCookieConsentPipelineOperation: String, CaseIterable {
    case readerSetup
    case layoutRepair
    case capture
    case ocr
    case pageTurn
    case automaticPageTurn
    case ttsPreparation
    case visualRecovery
    case reload
}

enum KindleCookieConsentPipelinePolicy {
    static func allows(
        _ operation: KindleCookieConsentPipelineOperation,
        isConsentVisible: Bool
    ) -> Bool {
        _ = operation
        return !isConsentVisible
    }
}

enum KindleCookieConsentDecision: String, CaseIterable {
    case notVisible = "not_visible"
    case autoClosed = "auto_closed"
    case manualNoClose = "manual_no_close"
    case manualMultipleCloses = "manual_multiple_closes"
    case manualMultipleNotices = "manual_multiple_notices"
    case manualAfterCloseAttempt = "manual_after_close_attempt"
    case manualCloseClickFailed = "manual_close_click_failed"
    case manualProbeOnly = "manual_probe_only"
    case resolved
}

struct KindleCookieConsentBridgePayload: Equatable {
    let runtimeToken: String
    let documentToken: String
    let storefrontID: String
    let visible: Bool
    let attemptedAutoClose: Bool
    let decision: KindleCookieConsentDecision

    init?(dictionary: [String: Any]) {
        guard dictionary["type"] as? String == "kindle-cookie-consent",
              let runtimeToken = dictionary["token"] as? String,
              !runtimeToken.isEmpty,
              let documentToken = dictionary["documentToken"] as? String,
              !documentToken.isEmpty,
              let storefrontID = dictionary["storefront"] as? String,
              KindleStorefront.entry(id: storefrontID) != nil,
              let visible = dictionary["visible"] as? Bool,
              let attemptedAutoClose = dictionary["attempted"] as? Bool,
              let rawDecision = dictionary["decision"] as? String,
              let decision = KindleCookieConsentDecision(rawValue: rawDecision) else {
            return nil
        }
        self.runtimeToken = runtimeToken
        self.documentToken = documentToken
        self.storefrontID = storefrontID
        self.visible = visible
        self.attemptedAutoClose = attemptedAutoClose
        self.decision = decision
    }
}

enum KindleCookieConsentBridgePolicy {
    static func accepts(
        _ payload: KindleCookieConsentBridgePayload,
        expectedRuntimeToken: String,
        activeDocumentToken: String?,
        retiredDocumentTokens: Set<String>,
        isMainFrame: Bool,
        isExpectedWebView: Bool,
        sourceURL: URL?,
        currentURL: URL?,
        expectedStorefrontID: String,
        expectedASIN: String
    ) -> Bool {
        guard isMainFrame,
              isExpectedWebView,
              payload.runtimeToken == expectedRuntimeToken,
              payload.storefrontID == expectedStorefrontID,
              !retiredDocumentTokens.contains(payload.documentToken),
              activeDocumentToken.map({ $0 == payload.documentToken }) ?? true,
              KindleStorefrontNavigationPolicy.isExactReaderURL(
                  sourceURL,
                  expectedStorefrontID: expectedStorefrontID,
                  expectedASIN: expectedASIN
              ),
              KindleStorefrontNavigationPolicy.isExactReaderURL(
                  currentURL,
                  expectedStorefrontID: expectedStorefrontID,
                  expectedASIN: expectedASIN
              ) else {
            return false
        }
        return true
    }
}

enum KindleCookieConsentStateChangeReason: String {
    case observer
    case navigationStart
    case readerHidden
    case destroy
    case rendererReplacement
}

enum KindleCookieConsentRecoveryPolicy {
    static func shouldScheduleRecovery(
        wasVisible: Bool,
        isVisible: Bool,
        reason: KindleCookieConsentStateChangeReason,
        isSyncDialogVisible: Bool
    ) -> Bool {
        wasVisible &&
            !isVisible &&
            reason == .observer &&
            !isSyncDialogVisible
    }
}

final class KindleWebViewContainer: UIView {
    let webView: WKWebView
    var crop: KindleViewportCrop = .identity {
        didSet {
            if crop != oldValue {
                setNeedsLayout()
            }
        }
    }

    init(webView: WKWebView, crop: KindleViewportCrop = .identity) {
        self.webView = webView
        self.crop = crop
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        webView.transform = .identity
        if crop.isIdentity {
            webView.frame = bounds
            return
        }

        let widthScale = max(1, min(crop.scale, 2.4))
        let heightScale = max(1, min(crop.heightScale, 2.4))
        webView.frame = CGRect(
            x: crop.offsetX,
            y: crop.offsetY,
            width: size.width * widthScale,
            height: size.height * heightScale
        )
    }
}

struct KindleWebView: UIViewRepresentable {
    let webView: WKWebView
    var crop: KindleViewportCrop = .identity

    func makeUIView(context: Context) -> KindleWebViewContainer {
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 13.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        return KindleWebViewContainer(webView: webView, crop: crop)
    }

    func updateUIView(_ uiView: KindleWebViewContainer, context: Context) {
        uiView.webView.underPageBackgroundColor = .systemBackground
        uiView.webView.scrollView.backgroundColor = .systemBackground
        uiView.crop = crop
    }
}

@MainActor
final class KindleLibrarySyncViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isSyncing = false
    @Published var statusText = AppLocalized("打开 Amazon Kindle 并登录。")
    @Published var errorText: String?
    @Published var currentReaderBook: KindleBook?
    @Published var showsEmptyShelfRecovery = false
    @Published private(set) var onboardingState: KindleOnboardingConnectionState = .idle
    @Published private(set) var discoveredBookCount = 0

    let webView: WKWebView
    private var didLoad = false
    private let store = KindleLibraryStore.shared
    private var onboardingAutomationTask: Task<Void, Never>?
    private var onboardingAttemptID = 0
    private var onboardingAutomationEnabled = false
    private let connectionAnalytics: AnalyticsLibraryConnectionRecorder

    var recoveryStorefronts: [KindleStorefront] {
        Array(store.orderedStorefrontCandidates.filter { $0.id != store.boundStorefrontID }.prefix(4))
    }

    override convenience init() {
        self.init(
            analyticsSession: AnalyticsLibraryConnectionSession(
                source: .kindle,
                entryPoint: "kindle_connect"
            ),
            entryTapAlreadyTracked: false
        )
    }

    init(
        analyticsSession: AnalyticsLibraryConnectionSession,
        entryTapAlreadyTracked: Bool
    ) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        connectionAnalytics = AnalyticsLibraryConnectionRecorder(
            session: analyticsSession,
            entryTapAlreadyTracked: entryTapAlreadyTracked
        )
        super.init()
        webView.navigationDelegate = self
    }

    func recordConnectionPresented() { connectionAnalytics.presented() }

    func closeConnection() {
        connectionAnalytics.close()
        stopOnboardingAutomation()
        webView.stopLoading()
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        KindleRunLog.write("KINDLE shelf load reason=first-open storefront=\(store.boundStorefrontID) sinceReaderOK=\(KindleSessionFreshness.sinceReaderOK) sinceShelfOK=\(KindleSessionFreshness.sinceShelfOK)")
        KindleSessionProbe.logCookies(reason: "shelf-load-first-open")
        webView.load(URLRequest(url: KindleWebScripts.libraryURL(for: store.boundStorefront)))
    }

    func startOnboardingAutomation() {
        onboardingAutomationEnabled = true
        loadIfNeeded()
        restartOnboardingAutomation(reason: "start")
    }

    func stopOnboardingAutomation() {
        onboardingAutomationEnabled = false
        onboardingAttemptID += 1
        onboardingAutomationTask?.cancel()
        onboardingAutomationTask = nil
        if case .ready = onboardingState { return }
        onboardingState = .idle
    }

    func retryOnboardingScan() {
        errorText = nil
        showsEmptyShelfRecovery = false
        restartOnboardingAutomation(reason: "manual-retry")
    }

    func loadLibrary() {
        currentReaderBook = nil
        showsEmptyShelfRecovery = false
        statusText = AppLocalized("打开 Kindle 书架，然后点同步。")
        KindleRunLog.write("KINDLE shelf load reason=reload storefront=\(store.boundStorefrontID) sinceReaderOK=\(KindleSessionFreshness.sinceReaderOK) sinceShelfOK=\(KindleSessionFreshness.sinceShelfOK)")
        KindleSessionProbe.logCookies(reason: "shelf-load-reload")
        webView.load(URLRequest(url: KindleWebScripts.libraryURL(for: store.boundStorefront)))
    }

    func switchStorefront(to storefront: KindleStorefront) {
        guard storefront.isSelectable, storefront.id != store.boundStorefrontID else { return }
        KindlePlaybackCenter.shared.close()
        webView.stopLoading()
        store.switchStorefront(to: storefront.id)
        currentReaderBook = nil
        showsEmptyShelfRecovery = false
        errorText = nil
        statusText = AppLocalized("Amazon 站点已切换，请登录并同步书架。")
        KindleRunLog.write("KINDLE shelf rebind storefront=\(storefront.id)")
        webView.load(URLRequest(url: KindleWebScripts.libraryURL(for: storefront)))
        if onboardingAutomationEnabled {
            restartOnboardingAutomation(reason: "switch-storefront")
        }
    }

    func secondaryStatusText(bookCount: Int) -> String {
        if currentReaderBook != nil {
            return AppLocalized("返回 Kindle 书架后再同步。")
        }
        if bookCount > 0 {
            return String(format: AppLocalized("已在本机同步 %d 本书。"), bookCount)
        }
        if store.hasConnected {
            return String(
                format: AppLocalized("当前站点：%@"),
                store.boundStorefront.displayName
            )
        }
        return AppLocalized("登录后点同步。")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        KindleRunLog.write(
            "KINDLE shelf didStart \(KindleSessionProbe.safeRouteLabel(webView.url))"
        )
        KindleSessionProbe.logCookies(reason: "shelf-didStart")
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        KindleRunLog.write(
            "KINDLE shelf redirect \(KindleSessionProbe.safeRouteLabel(webView.url))"
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard KindleStorefrontNavigationPolicy.allowsMainFrame(
            webView.url,
            expectedStorefrontID: store.boundStorefrontID,
            expectedAuthenticationReturnPath: store.boundStorefront.libraryURL.path
        ) else {
            rejectUnexpectedMainFrameDestination(webView.url)
            return
        }
        let finishedURL = webView.url?.absoluteString ?? ""
        let landing = KindleSessionProbe.landingKind(finishedURL)
        if landing == "auth" {
            connectionAnalytics.record(.loginStarted, result: .started)
        } else if (landing == "library" || landing == "reader"),
                  KindleStorefrontNavigationPolicy.allows(
                      webView.url,
                      expectedStorefrontID: store.boundStorefrontID
                  ) {
            connectionAnalytics.record(.loginSucceeded, result: .success)
        }
        KindleRunLog.write(
            "KINDLE shelf didFinish \(KindleSessionProbe.safeRouteLabel(webView.url))"
        )
        KindleSessionProbe.logCookies(reason: "shelf-didFinish-\(landing)")
        if landing == "library" { KindleSessionFreshness.markShelfOK() }
        statusText = AppLocalized("如果已经看到 Kindle 书架，请点同步。")
        Task { await refreshPageState() }
    }

    /// The shelf WebView has the same marketplace ownership boundary as the
    /// reader WebView. Amazon's localized Kindle domains may redirect from a
    /// legacy alias to the canonical host, and sign-in may temporarily visit a
    /// secure Amazon authentication endpoint; everything else is denied before
    /// it can replace the visible main frame or silently mutate the binding.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true,
              let destination = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        guard KindleStorefrontNavigationPolicy.allowsMainFrame(
            destination,
            expectedStorefrontID: store.boundStorefrontID,
            expectedAuthenticationReturnPath: store.boundStorefront.libraryURL.path
        ) else {
            decisionHandler(.cancel)
            rejectUnexpectedMainFrameDestination(destination)
            return
        }
        decisionHandler(.allow)
    }

    /// Redirect responses need their own gate: WKWebView does not guarantee a
    /// fresh action-policy callback for every server-side hop.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame,
              let destination = navigationResponse.response.url else {
            decisionHandler(.allow)
            return
        }
        guard KindleStorefrontNavigationPolicy.allowsMainFrame(
            destination,
            expectedStorefrontID: store.boundStorefrontID,
            expectedAuthenticationReturnPath: store.boundStorefront.libraryURL.path
        ) else {
            decisionHandler(.cancel)
            rejectUnexpectedMainFrameDestination(destination)
            return
        }
        decisionHandler(.allow)
    }

    private func rejectUnexpectedMainFrameDestination(_ destination: URL?) {
        webView.stopLoading()
#if DEBUG
        // Path-level evidence for live-gate diagnosis. Host and path only —
        // never the query, which can carry tokens or account identifiers.
        KindleRunLog.write(
            "KINDLE shelf blocked destination host=\(destination?.host ?? "nil") path=\(destination?.path ?? "nil")"
        )
#endif
        let expectedID = store.boundStorefrontID
        let observed = KindleStorefront.storefront(url: destination)
        let code: String
        if KindleStorefrontNavigationPolicy
            .resemblesAmazonAuthenticationURL(destination) {
            code = "auth_redirect_rejected"
            let domain = KindleStorefront.registrableDomain(for: destination?.host)
                ?? "invalid_destination"
            KindleRunLog.write(
                "KINDLE shelf auth redirect rejected expected=\(expectedID) domain=\(domain)"
            )
        } else if let observed, observed.entryEnabled, observed.id != expectedID {
            code = "storefront_mismatch"
            KindleRunLog.write(
                "KINDLE shelf navigation blocked expected=\(expectedID) observed=\(observed.id)"
            )
        } else {
            code = "navigation_blocked"
            let domain = KindleStorefront.registrableDomain(for: destination?.host)
                ?? "invalid_destination"
            KindleRunLog.write(
                "KINDLE shelf navigation blocked expected=\(expectedID) domain=\(domain)"
            )
        }

        let message = AppLocalized("当前 Amazon 站点与所选站点不一致。")
        statusText = message
        errorText = message
        showsEmptyShelfRecovery = true
        if onboardingAutomationEnabled {
            onboardingState = .failed(message: message)
        }
        connectionAnalytics.record(
            .failed,
            result: .failed,
            errorCode: code
        )
    }

    func syncLibrary(
        lightPass: Bool = false,
        expectedOnboardingAttemptID: Int? = nil
    ) async {
        if let expectedOnboardingAttemptID,
           expectedOnboardingAttemptID != onboardingAttemptID {
            return
        }
        guard !isSyncing else { return }
        connectionAnalytics.record(.syncStarted, result: .started)
        isSyncing = true
        errorText = nil
        showsEmptyShelfRecovery = false
        discoveredBookCount = 0
        defer { isSyncing = false }
        let expectedStorefrontID = store.boundStorefrontID

        do {
            statusText = AppLocalized("正在扫描 Kindle 书架…")
            var byID: [String: KindleBook] = [:]
            let maxPasses = lightPass ? 2 : 12
            var idlePasses = 0
            var sawAuthRequired = false
            var sawReaderPage = false
            var sawLibrarySignals = false
            var sawLibraryPage = false
            var sawWrongStorefront = false
            var stableEmptyEvidencePasses = 0
            var stableSnapshotPasses = 0
            var previousSnapshotKey: String?
            var completedShelfScan = false
            var lastPayload: KindleScrapeResult?
            var accountInfo: KindleAccountInfo?

            for pass in 0..<maxPasses {
                let payload = try await scrapeCurrentViewport()
                lastPayload = payload
                guard !Task.isCancelled,
                      store.boundStorefrontID == expectedStorefrontID,
                      expectedOnboardingAttemptID.map({ $0 == onboardingAttemptID }) ?? true else {
                    return
                }
                let landing = KindleSessionProbe.landingKind(payload.url ?? "")
                let isExactBoundLibrary = KindleStorefrontNavigationPolicy
                    .isExactLibraryURL(
                        payload.url.flatMap(URL.init(string:)),
                        expectedStorefrontID: store.boundStorefrontID
                    )
                KindleRunLog.write(
                    "KINDLE shelf sync pass=\(pass) storefront=\(expectedStorefrontID) landing=\(landing) books=\(payload.books.count) auth=\(payload.authRequired == true ? "Y" : "N") authState=\(payload.authState ?? "none") reader=\(payload.isReaderPage == true ? "Y" : "N") signals=\(payload.hasReaderSignals == true ? "Y" : "N") empty=\(payload.hasEmptyShelfSignal == true ? "Y" : "N") loading=\(payload.shelfLoading == true ? "Y" : "N") end=\(payload.atScrollEnd == true ? "Y" : "N")"
                )
                sawAuthRequired = sawAuthRequired || payload.authRequired == true
                if let observedStorefrontID = KindleStorefront.storefront(
                    rawURL: payload.url
                )?.id,
                   observedStorefrontID != expectedStorefrontID {
                    sawWrongStorefront = true
                    break
                }
                sawReaderPage = sawReaderPage || payload.isReaderPage == true
                sawLibrarySignals = sawLibrarySignals || payload.hasReaderSignals == true || !payload.books.isEmpty
                sawLibraryPage = sawLibraryPage
                    || isExactBoundLibrary
                let hasStableSnapshot = payload.snapshotKey?.isEmpty == false
                    && payload.snapshotKey == previousSnapshotKey
                stableSnapshotPasses = hasStableSnapshot
                    ? stableSnapshotPasses + 1
                    : 0
                previousSnapshotKey = payload.snapshotKey
                let isStableEmptyEvidence = isExactBoundLibrary
                    && payload.pageReady == true
                    && payload.hasEmptyShelfSignal == true
                    && payload.authRequired != true
                    && payload.isReaderPage != true
                    && payload.hasReaderSignals != true
                    && payload.shelfLoading != true
                    && payload.atScrollEnd == true
                    && payload.books.isEmpty
                stableEmptyEvidencePasses = isStableEmptyEvidence
                    ? stableEmptyEvidencePasses + 1
                    : 0
                if let account = payload.account, accountInfo == nil || account.email?.isEmpty == false {
                    accountInfo = account
                }
                let scraped = payload.books
                let before = byID.count
                for book in scraped { byID[book.id] = book }
                discoveredBookCount = byID.count
                if onboardingAutomationEnabled {
                    onboardingState = .scanning(found: byID.count)
                }
                if byID.count == before {
                    idlePasses += 1
                } else {
                    idlePasses = 0
                }
                if payload.authRequired == true {
                    statusText = AppLocalized("请登录 Amazon Kindle，然后点同步。")
                    break
                } else if payload.isReaderPage == true {
                    statusText = AppLocalized("当前打开的是 Kindle 书籍页面，请返回 Kindle 书架后同步。")
                } else if byID.isEmpty && payload.hasReaderSignals != true {
                    statusText = AppLocalized("打开 Kindle 书架，然后点同步。")
                } else {
                    statusText = String(format: AppLocalized("已找到 %d 本 Kindle 书…"), byID.count)
                }
                let structurallyComplete = isExactBoundLibrary
                    && payload.pageReady == true
                    && payload.shelfLoading != true
                    && payload.atScrollEnd == true
                    && stableSnapshotPasses >= 1
                if !byID.isEmpty,
                   pass >= 1,
                   idlePasses >= 1,
                   structurallyComplete {
                    completedShelfScan = true
                    break
                }
                if byID.isEmpty,
                   stableEmptyEvidencePasses >= 2,
                   structurallyComplete {
                    completedShelfScan = true
                    break
                }
                try await scrollLibraryForward()
                try await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled,
                      store.boundStorefrontID == expectedStorefrontID,
                      expectedOnboardingAttemptID.map({ $0 == onboardingAttemptID }) ?? true else {
                    return
                }
            }

            let books = Array(byID.values)
            guard store.boundStorefrontID == expectedStorefrontID,
                  expectedOnboardingAttemptID.map({ $0 == onboardingAttemptID }) ?? true else {
                return
            }
            if sawWrongStorefront {
                statusText = AppLocalized("当前 Amazon 站点与所选站点不一致。")
                errorText = statusText
                connectionAnalytics.record(
                    .failed,
                    result: .failed,
                    errorCode: "storefront_mismatch"
                )
                if onboardingAutomationEnabled {
                    onboardingState = .failed(message: statusText)
                }
            } else if sawAuthRequired {
                statusText = AppLocalized("请登录 Amazon Kindle，然后点同步。")
                errorText = nil
                if onboardingAutomationEnabled {
                    onboardingState = .awaitingLogin
                }
            } else if books.isEmpty {
                if sawReaderPage {
                    statusText = AppLocalized("当前打开的是 Kindle 书籍页面，请返回 Kindle 书架后同步。")
                } else if sawAuthRequired {
                    statusText = AppLocalized("请登录 Amazon Kindle，然后点同步。")
                } else if sawLibrarySignals {
                    statusText = AppLocalized("请滚动 Kindle 书架后再点同步。")
                } else if sawLibraryPage {
                    statusText = AppLocalized("书架是空的？")
                } else {
                    statusText = AppLocalized("打开 Kindle 书架，然后点同步。")
                }
                if !lightPass {
                    let isTrustedEmptyShelf = completedShelfScan && KindleEmptyShelfTrust.isTrusted(
                        sawLibraryPage: sawLibraryPage,
                        sawAuthRequired: sawAuthRequired,
                        sawReaderPage: sawReaderPage,
                        sawLibrarySignals: sawLibrarySignals,
                        stableEmptyEvidencePasses: stableEmptyEvidencePasses
                    )
                    if isTrustedEmptyShelf {
                        store.markConnectedWithEmptyShelf(account: accountInfo)
                        connectionAnalytics.record(
                            .failed,
                            result: .failed,
                            errorCode: "empty_shelf",
                            bookCount: 0
                        )
                        errorText = nil
                        showsEmptyShelfRecovery = true
                        if onboardingAutomationEnabled {
                            onboardingState = .empty
                        }
                    } else {
                        let lastLanding = KindleSessionProbe.landingKind(
                            lastPayload?.url ?? ""
                        )
                        let failureCode = KindleShelfScanFailureClassifier.code(
                            sawLibraryPage: sawLibraryPage,
                            sawReaderPage: sawReaderPage,
                            lastLanding: lastLanding,
                            pageReady: lastPayload?.pageReady == true,
                            shelfLoading: lastPayload?.shelfLoading == true,
                            atScrollEnd: lastPayload?.atScrollEnd == true,
                            stableSnapshotPasses: stableSnapshotPasses
                        )
                        if failureCode == "library_path_lost" {
                            errorText = AppLocalized("打开 Kindle 书架，然后点同步。")
                        } else if failureCode == "DOM_changed" {
                            errorText = AppLocalized("当前页面暂时没有找到 Kindle 书籍。")
                        } else {
                            errorText = AppLocalized("书架仍在加载，请稍后重试。")
                        }
                        connectionAnalytics.record(
                            .failed,
                            result: .failed,
                            errorCode: failureCode
                        )
                    }
                }
            } else {
                store.mergeScrapedBooks(books, account: accountInfo)
                if completedShelfScan {
                    connectionAnalytics.record(
                        .syncCompleted,
                        result: .success,
                        bookCount: books.count
                    )
                    statusText = AppLocalized("Kindle 书架已同步。")
                    errorText = nil
                } else {
                    connectionAnalytics.record(
                        .failed,
                        result: .failed,
                        errorCode: "scan_timeout",
                        bookCount: books.count
                    )
                    statusText = String(
                        format: AppLocalized("已同步 %d 本书。"),
                        books.count
                    )
                    errorText = AppLocalized("书架仍在加载，请稍后重试。")
                }
                if onboardingAutomationEnabled {
                    onboardingState = .ready
                }
                _ = try? await evaluate("window.scrollTo(0, 0);")
            }
            // The session fingerprint immediately after a sync is the missing
            // half of the picture: comparing it against the next book open shows
            // whether visiting the shelf is what refreshes Amazon's reader session.
            KindleRunLog.write("KINDLE shelf sync done storefront=\(store.boundStorefrontID) books=\(books.count) complete=\(completedShelfScan ? "Y" : "N") auth=\(sawAuthRequired ? "Y" : "N") readerPage=\(sawReaderPage ? "Y" : "N") signals=\(sawLibrarySignals ? "Y" : "N") light=\(lightPass ? "Y" : "N")")
            KindleSessionProbe.logCookies(reason: "shelf-sync-done")
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  store.boundStorefrontID == expectedStorefrontID,
                  expectedOnboardingAttemptID.map({ $0 == onboardingAttemptID }) ?? true else {
                return
            }
            statusText = AppLocalized("同步需要处理。")
            errorText = error.localizedDescription
            connectionAnalytics.record(
                .failed,
                result: .failed,
                errorCode: "scan_timeout"
            )
            if onboardingAutomationEnabled {
                onboardingState = .failed(message: error.localizedDescription)
            }
            KindleRunLog.write(
                "KINDLE shelf sync failed code=\((error as NSError).code)"
            )
            KindleSessionProbe.logCookies(reason: "shelf-sync-failed")
        }
    }

    private func restartOnboardingAutomation(reason: String) {
        guard onboardingAutomationEnabled else { return }
        onboardingAttemptID += 1
        let attemptID = onboardingAttemptID
        onboardingAutomationTask?.cancel()
        onboardingAutomationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            KindleRunLog.write("KINDLE onboarding automation start attempt=\(attemptID) reason=\(reason)")
            var scanAttempts = 0

            while !Task.isCancelled,
                  self.onboardingAutomationEnabled,
                  attemptID == self.onboardingAttemptID {
                do {
                    let payload = try await self.scrapeCurrentViewport()
                    guard !Task.isCancelled,
                          attemptID == self.onboardingAttemptID else { return }

                    let isExactLibrary = KindleStorefrontNavigationPolicy.isExactLibraryURL(
                        payload.url.flatMap(URL.init(string:)),
                        expectedStorefrontID: self.store.boundStorefrontID
                    )
                    let canScan = isExactLibrary
                        && payload.pageReady == true
                        && payload.authRequired != true
                        && payload.isReaderPage != true

                    guard canScan else {
                        self.onboardingState = .awaitingLogin
                        try await Task.sleep(nanoseconds: 700_000_000)
                        continue
                    }

                    self.onboardingState = .scanning(found: self.discoveredBookCount)
                    scanAttempts += 1
                    await self.syncLibrary(
                        lightPass: false,
                        expectedOnboardingAttemptID: attemptID
                    )
                    guard !Task.isCancelled,
                          attemptID == self.onboardingAttemptID else { return }

                    if !self.store.boundBooks.isEmpty {
                        self.onboardingState = .ready
                        return
                    }
                    if self.showsEmptyShelfRecovery {
                        self.onboardingState = .empty
                        return
                    }
                    if scanAttempts >= 2 {
                        let message = self.errorText
                            ?? AppLocalized("当前页面暂时没有找到 Kindle 书籍。")
                        self.onboardingState = .failed(message: message)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          attemptID == self.onboardingAttemptID else { return }
                    // Navigation and login pages are transient. Keep the Amazon
                    // session intact and probe again instead of rebuilding it.
                    self.onboardingState = .awaitingLogin
                }

                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    private func scrapeCurrentViewport() async throws -> KindleScrapeResult {
        let result = try await evaluate(KindleWebScripts.scrapeLibrary)
        let data = try jsonData(from: result)
        let payload = try JSONDecoder().decode(KindleScrapePayload.self, from: data)
        if payload.isReaderPage == true {
            await refreshPageState()
        }
        let storefrontID = KindleStorefront.storefront(rawURL: payload.url)?.id
            ?? store.boundStorefrontID
        return KindleScrapeResult(
            books: payload.books.map { $0.book(storefrontID: storefrontID) }.filter(\.isLikelyLibraryBook),
            authRequired: payload.authRequired,
            authState: payload.authState,
            hasReaderSignals: payload.hasReaderSignals,
            hasEmptyShelfSignal: payload.hasEmptyShelfSignal,
            pageReady: payload.pageReady,
            shelfLoading: payload.shelfLoading,
            atScrollEnd: payload.atScrollEnd,
            snapshotKey: payload.snapshotKey,
            isReaderPage: payload.isReaderPage,
            account: payload.account,
            url: payload.url,
            storefrontID: storefrontID
        )
    }

    private func refreshPageState() async {
        do {
            let result = try await evaluate(KindleWebScripts.currentPageState)
            let data = try jsonData(from: result)
            let state = try JSONDecoder().decode(KindleCurrentPageState.self, from: data)
            guard state.isReaderPage else {
                currentReaderBook = nil
                return
            }
            let id = state.asin?.isEmpty == false ? (state.asin ?? state.url) : state.url
            let book = KindleBook(
                id: id,
                asin: state.asin?.isEmpty == false ? state.asin : nil,
                title: state.title.isEmpty ? "Kindle" : state.title,
                author: "",
                coverURL: nil,
                readerURL: state.url,
                progressLabel: "",
                storefrontID: KindleStorefront.storefront(url: URL(string: state.url))?.id
                    ?? store.boundStorefrontID,
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastReadPageKey: nil,
                lastReadURL: state.url
            )
            currentReaderBook = book.isLikelyLibraryBook ? book : nil
        } catch {
            currentReaderBook = nil
        }
    }

    private func scrollLibraryForward() async throws {
        _ = try await evaluate("""
        (function() {
          var roots = [document.scrollingElement, document.body, document.documentElement].filter(Boolean);
          var all = Array.from(document.querySelectorAll('*')).filter(function(el) {
            if (roots.indexOf(el) >= 0) return true;
            try {
              var overflowY = String(getComputedStyle(el).overflowY || '').toLowerCase();
              return /^(?:auto|scroll|overlay)$/.test(overflowY) &&
                (el.clientHeight || 0) >= 48 &&
                (el.scrollHeight || 0) - (el.clientHeight || 0) > 4;
            } catch (_) { return false; }
          }).concat(roots);
          all.sort(function(a,b){ return ((b.scrollHeight||0)-(b.clientHeight||0))-((a.scrollHeight||0)-(a.clientHeight||0)); });
          var delta = Math.max(520, Math.floor((window.innerHeight || 700) * 0.82));
          for (var i=0; i<Math.min(8, all.length); i++) {
            try { all[i].scrollTop = (all[i].scrollTop || 0) + delta; } catch(e) {}
          }
          try { window.scrollBy(0, delta); } catch(e) {}
          return true;
        })();
        """)
    }

    @discardableResult
    private func evaluate(_ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as Any)
                }
            }
        }
    }

    private func jsonData(from value: Any) throws -> Data {
        if let string = value as? String, let data = string.data(using: .utf8) {
            return data
        }
        if JSONSerialization.isValidJSONObject(value) {
            return try JSONSerialization.data(withJSONObject: value)
        }
        throw NSError(domain: "KindleLibrary", code: -1, userInfo: [NSLocalizedDescriptionKey: AppLocalized("Kindle 书架响应异常。")])
    }
}

private struct KindleScrapePayload: Decodable {
    let books: [ScrapedKindleBook]
    let authRequired: Bool?
    let authState: String?
    let hasReaderSignals: Bool?
    let hasEmptyShelfSignal: Bool?
    let pageReady: Bool?
    let shelfLoading: Bool?
    let atScrollEnd: Bool?
    let snapshotKey: String?
    let isReaderPage: Bool?
    let account: KindleAccountInfo?
    let url: String?
}

private struct KindleScrapeResult {
    let books: [KindleBook]
    let authRequired: Bool?
    let authState: String?
    let hasReaderSignals: Bool?
    let hasEmptyShelfSignal: Bool?
    let pageReady: Bool?
    let shelfLoading: Bool?
    let atScrollEnd: Bool?
    let snapshotKey: String?
    let isReaderPage: Bool?
    let account: KindleAccountInfo?
    let url: String?
    let storefrontID: String
}

enum KindleEmptyShelfTrust {
    static func isTrusted(
        sawLibraryPage: Bool,
        sawAuthRequired: Bool,
        sawReaderPage: Bool,
        sawLibrarySignals: Bool,
        stableEmptyEvidencePasses: Int
    ) -> Bool {
        sawLibraryPage
            && !sawAuthRequired
            && !sawReaderPage
            && !sawLibrarySignals
            && stableEmptyEvidencePasses >= 2
    }
}

enum KindleShelfScanFailureClassifier {
    static func code(
        sawLibraryPage: Bool,
        sawReaderPage: Bool,
        lastLanding: String,
        pageReady: Bool,
        shelfLoading: Bool,
        atScrollEnd: Bool,
        stableSnapshotPasses: Int
    ) -> String {
        if !sawLibraryPage, !sawReaderPage, lastLanding != "auth" {
            return "library_path_lost"
        }
        if sawLibraryPage,
           pageReady,
           !shelfLoading,
           atScrollEnd,
           stableSnapshotPasses >= 1 {
            return "DOM_changed"
        }
        return "scan_timeout"
    }
}

private struct KindleCurrentPageState: Decodable {
    let url: String
    let title: String
    let asin: String?
    let isReaderPage: Bool
}

private struct ScrapedKindleBook: Decodable {
    let id: String
    let asin: String?
    let title: String
    let author: String?
    let coverURL: String?
    let readerURL: String
    let progressLabel: String?

    func book(storefrontID: String) -> KindleBook {
        KindleBook(
            id: id,
            asin: asin?.isEmpty == false ? asin : nil,
            title: title,
            author: author ?? "",
            coverURL: coverURL?.isEmpty == false ? coverURL : nil,
            readerURL: readerURL,
            progressLabel: progressLabel ?? "",
            storefrontID: KindleStorefront.storefront(rawURL: readerURL)?.id ?? storefrontID,
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
    }
}
