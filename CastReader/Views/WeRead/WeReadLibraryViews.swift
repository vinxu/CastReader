//
//  WeReadLibraryViews.swift
//  CastReader
//

import SwiftUI
import UIKit
import WebKit
import CryptoKit

extension Notification.Name {
    /// Opens the existing WeRead binding flow without constructing a second
    /// login WebView. The connect view remains the sole owner of its QR session.
    static let castReaderWeReadRebindRequested = Notification.Name("castreader.weread.rebindRequested")
}

struct WeReadHomeSection: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = WeReadLibraryStore.shared
    @ObservedObject private var onboarding = BoundLibraryOnboardingStore.shared

    var body: some View {
        Group {
            if !store.needsConnection && !store.homeBooks.isEmpty {
                VStack(alignment: .leading, spacing: HomeLayout.headerToContent) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: HomeLayout.titleToSubtitle) {
                            Text(AppLocalized("微信读书")).font(.headline).foregroundColor(AppTheme.foreground)
                            Text(AppLocalized("已同步的微信读书书架")).font(.caption).foregroundColor(AppTheme.mutedForeground)
                        }
                        Spacer()
                        NavigationLink(destination: WeReadLibraryView()) {
                            Text(AppLocalized("查看全部")).font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.primary)
                        }
                        .accessibilityIdentifier("homeShelfViewAll.weread")
                    }

                    HomeHorizontalRail(alignment: .top) {
                        ForEach(store.homeBooks) { book in
                            Button { open(book) } label: { WeReadBookRailCard(book: book) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("homeShelfBook.weread.\(book.id)")
                        }
                    }
                }
                .accessibilityIdentifier("homeShelfSection.weread")
            }
        }
    }

    private var connectCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "books.vertical").font(.system(size: 22, weight: .semibold)).foregroundColor(AppTheme.primary)
                .frame(width: 48, height: 48).background(AppTheme.primary.opacity(0.12)).cornerRadius(12)
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("绑定微信读书")).font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.foreground)
                Text(AppLocalized("登录后同步书架与阅读进度")).font(.caption).foregroundColor(AppTheme.mutedForeground)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(AppTheme.mutedForeground)
        }
        .padding(14).background(AppTheme.surface).cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border.opacity(0.7), lineWidth: 1))
    }

    private func open(_ book: WeReadBook) {
        store.markOpened(book)
        let document = ReadingDocument(
            id: book.id,
            title: book.title,
            sourceKind: .weread,
            language: Constants.TTS.defaultLanguage,
            paragraphs: [],
            sourceURL: book.effectiveReaderURL,
            coverURL: book.coverURL
        )
        let context = ProductAnalytics.shared.beginContentIntent(
            source: .weread,
            format: .weread,
            entryPoint: onboarding.analyticsEntryPoint(for: .weread) ?? "weread_library",
            intendedMode: "read"
        )
        coordinator.open(document, mode: .read, autoplay: false, analyticsContext: context)
    }
}

struct WeReadLibraryConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: WeReadLibrarySyncViewModel

    init(
        analyticsSession: AnalyticsLibraryConnectionSession? = nil,
        entryTapAlreadyTracked: Bool = false
    ) {
        let session = analyticsSession ?? AnalyticsLibraryConnectionSession(
            source: .weread,
            entryPoint: "weread_connect"
        )
        _model = StateObject(
            wrappedValue: WeReadLibrarySyncViewModel(
                analyticsSession: session,
                entryTapAlreadyTracked: entryTapAlreadyTracked
            )
        )
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                WeReadWebView(webView: model.webView).ignoresSafeArea(edges: .bottom)
                if model.showsSyncBar {
                    syncBar
                } else if model.showsLoginGuide {
                    loginGuideBar
                }
            }
            .navigationTitle(AppLocalized("绑定微信读书")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("关闭")) { dismiss() } }
            }
            .onAppear {
                model.recordConnectionPresented()
                model.updateTheme(isDark: colorScheme == .dark)
                model.loadIfNeeded()
            }
            .onChange(of: colorScheme) { _, scheme in
                model.updateTheme(isDark: scheme == .dark)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    model.resumeAfterExternalLogin()
                case .inactive, .background:
                    model.preserveLoginSessionBeforeBackground()
                @unknown default:
                    break
                }
            }
            .onDisappear { model.closeConnection() }
        }.navigationViewStyle(.stack)
    }

    private var loginGuideBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.title3.weight(.semibold))
                .foregroundColor(AppTheme.primary)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("截图二维码，用微信扫码登录"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.foreground)
                Text(AppLocalized("截图后打开微信扫一扫，从相册识别二维码。登录后会自动进入书架，供你同步到 CastReader。"))
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .accessibilityIdentifier("weReadLoginGuide")
    }

    private var syncBar: some View {
        VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        if model.isScanning || model.isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: model.availableCount > 0 ? "checkmark.circle.fill" : "book.closed")
                                .foregroundColor(model.availableCount > 0 ? .green : AppTheme.primary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.availableCount > 0
                                 ? String(format: AppLocalized("检测到 %d 本书"), model.availableCount)
                                 : model.statusText)
                                .font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.foreground).lineLimit(2)
                            Text(model.availableCount > 0
                                 ? AppLocalized("同步后即可在 CastReader 中朗读和解读。")
                                 : model.secondaryStatus)
                                .font(.caption).foregroundColor(AppTheme.mutedForeground).lineLimit(2)
                        }
                        Spacer()
                    }
                    if let error = model.errorText { Text(error).font(.caption).foregroundColor(AppTheme.destructive).lineLimit(2) }
                    Button {
                        Task {
                            if await model.syncLibrary() { dismiss() }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if model.isSyncing { ProgressView().tint(.white) }
                            Text(String(format: AppLocalized("同步 %d 本书"), model.availableCount))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .disabled(model.availableCount == 0 || model.isScanning || model.isSyncing)
                    .accessibilityIdentifier("syncWeReadLibraryButton")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

struct WeReadLibraryView: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = WeReadLibraryStore.shared
    @ObservedObject private var onboarding = BoundLibraryOnboardingStore.shared
    @State private var query = ""
    @State private var sort: WeReadLibrarySort = .recent
    @State private var page = 1
    @State private var showConnect = false

    private var visible: [WeReadBook] { Array(store.sortedBooks(sort: sort, query: query).prefix(page * 24)) }
    private var all: [WeReadBook] { store.sortedBooks(sort: sort, query: query) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker(AppLocalized("排序"), selection: $sort) { ForEach(WeReadLibrarySort.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                    Button { showConnect = true } label: { Image(systemName: "arrow.clockwise").frame(width: 36,height:36).background(AppTheme.primary.opacity(0.12),in:Circle()) }.foregroundColor(AppTheme.primary)
                }
                if visible.isEmpty { empty } else {
                    LazyVStack(spacing: 12) { ForEach(visible) { book in WeReadLibraryRow(book: book, open: { open(book) }) } }
                    if visible.count < all.count { Button(AppLocalized("加载更多")) { page += 1 }.font(.subheadline.weight(.semibold)).frame(maxWidth:.infinity).padding(.vertical,12).background(AppTheme.surface,in:RoundedRectangle(cornerRadius:14)).foregroundColor(AppTheme.primary) }
                }
            }.padding(18)
        }
        .background(AppTheme.background.ignoresSafeArea()).navigationTitle(AppLocalized("微信读书书架")).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: AppLocalized("搜索微信读书书籍"))
        .onChange(of: query) { _, _ in page = 1 }.onChange(of: sort) { _, _ in page = 1 }
        .sheet(isPresented: $showConnect) { WeReadLibraryConnectView() }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: store.needsConnection ? "books.vertical" : "magnifyingglass").font(.system(size:32,weight:.semibold)).foregroundColor(AppTheme.primary)
            Text(store.needsConnection ? AppLocalized("绑定微信读书") : AppLocalized("没有匹配的书籍")).font(.headline)
            Button(store.needsConnection ? AppLocalized("登录") : AppLocalized("刷新")) { showConnect = true }.buttonStyle(.borderedProminent).tint(AppTheme.primary)
        }.frame(maxWidth:.infinity).padding(.vertical,50)
    }

    private func open(_ book: WeReadBook) {
        store.markOpened(book)
        let document = ReadingDocument(
            id: book.id,
            title: book.title,
            sourceKind: .weread,
            language: Constants.TTS.defaultLanguage,
            paragraphs: [],
            sourceURL: book.effectiveReaderURL,
            coverURL: book.coverURL
        )
        let context = ProductAnalytics.shared.beginContentIntent(
            source: .weread,
            format: .weread,
            entryPoint: onboarding.analyticsEntryPoint(for: .weread) ?? "weread_library",
            intendedMode: "read"
        )
        coordinator.open(document, analyticsContext: context)
    }
}

private struct WeReadBookRailCard: View {
    let book: WeReadBook
    var body: some View {
        VStack(alignment: .leading, spacing: HomeLayout.mediaToTextGap) {
            WeReadCoverView(urlString: book.coverURL).frame(width:96,height:144).clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(AppTheme.border.opacity(0.65),lineWidth:1))
            Text(book.title).font(.caption.weight(.semibold)).foregroundColor(AppTheme.foreground).lineLimit(2).frame(width:104,height:34,alignment:.topLeading)
            Text(book.displayProgress).font(.caption2).foregroundColor(AppTheme.mutedForeground).lineLimit(1).frame(width:104,alignment:.leading)
        }.frame(width:108,alignment:.topLeading)
    }
}

private struct WeReadLibraryRow: View {
    let book: WeReadBook; let open: () -> Void
    var body: some View {
        HStack(spacing:12) {
            HStack(spacing:14) {
                WeReadCoverView(urlString: book.coverURL).frame(width:64,height:94).clipShape(RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(AppTheme.border.opacity(0.65),lineWidth:1))
                VStack(alignment:.leading,spacing:6) {
                    Text(book.title).font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.foreground).lineLimit(2)
                    Text(book.displayAuthor).font(.caption).foregroundColor(AppTheme.mutedForeground).lineLimit(1)
                    Text(book.displayProgress).font(.caption2).foregroundColor(AppTheme.mutedForeground).lineLimit(1)
                }; Spacer(minLength:4)
            }.contentShape(Rectangle()).onTapGesture(perform:open)
            Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundColor(AppTheme.mutedForeground.opacity(0.8)).frame(width:28)
        }.padding(12).background(AppTheme.surface).cornerRadius(16).overlay(RoundedRectangle(cornerRadius:16).stroke(AppTheme.border.opacity(0.65),lineWidth:1))
    }
}

struct WeReadCoverView: View {
    let urlString: String?
    var body: some View {
        // Same reason as KindleCoverView: AsyncImage has no persistent cache.
        if let urlString, let url = URL(string: urlString) {
            CachedAsyncImage(url: url, contentMode: .fill) {
                placeholder.overlay { ProgressView().scaleEffect(0.75) }
            }
        } else { placeholder }
    }
    private var placeholder: some View { ZStack { LinearGradient(colors:[AppTheme.primary.opacity(0.18),AppTheme.surfaceVariant],startPoint:.topLeading,endPoint:.bottomTrailing); Image(systemName:"book.closed").font(.system(size:28,weight:.semibold)).foregroundColor(AppTheme.primary) } }
}

struct WeReadWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
private final class WeReadLoginReplyProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: WeReadLibrarySyncViewModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let owner else {
            replyHandler(nil, "CastReader WeRead login bridge is unavailable.")
            return
        }
        owner.handleNativeLoginPoll(message.body, replyHandler: replyHandler)
    }
}

private struct WeReadDeferredLoginRequest {
    let uid: String
    let otp: String
    let requestID: String
}

private actor WeReadCookieHeaderGate {
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: String?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

@MainActor
final class WeReadLibrarySyncViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isScanning = false
    @Published var isSyncing = false
    @Published var showsSyncBar = false
    @Published var showsLoginGuide = false
    @Published var availableCount = 0
    @Published var statusText = AppLocalized("打开微信读书并登录。")
    @Published var errorText: String?
    /// 首启引导用的连接进度。与 Kindle 引导共用同一组语义。
    @Published private(set) var onboardingState: BoundLibraryOnboardingConnectionState = .idle
    let webView: WKWebView
    private let store = WeReadLibraryStore.shared
    private let accountBoundaryToken = AccountContentIsolation.captureBoundaryToken()
    private var didLoad = false
    private var pendingBooks: [String: WeReadBook] = [:]
    private var pendingAccount: WeReadAccountInfo?
    private var hasTrustedShelfSnapshot = false
    private var trustedSnapshotNavigationGeneration: UInt64?
    private var trustedSnapshotSessionFingerprint: String?
    private var shelfNavigationRequested = false
    private var navigationGeneration: UInt64 = 0
    private var loginPollingTask: Task<Void, Never>?
    private var foregroundResumeTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var loginPresentationTask: Task<Void, Never>?
    private var isDarkMode = false
    private var pendingLoginUID: String?
    private var pendingNativeLoginResult: [String: Any]?
    private var nativeLoginTask: Task<Void, Never>?
    private var nativeLoginRetryTask: Task<Void, Never>?
    private var nativeLoginBackgroundTaskID = UIBackgroundTaskIdentifier.invalid
    private var deferredNativeLoginRequest: WeReadDeferredLoginRequest?
    private var deferredNativeLoginReply: ((Any?, String?) -> Void)?
    private var shouldResolveNativeLoginInForeground = true
    private let loginReplyProxy: WeReadLoginReplyProxy
    private let nativeLoginSession: URLSession
    private let connectionAnalytics: AnalyticsLibraryConnectionRecorder
    private var onboardingAutomationEnabled = false
    private var onboardingAttemptID = 0
    private var onboardingAutomationTask: Task<Void, Never>?

    var secondaryStatus: String {
        if availableCount > 0 {
            return String(format: AppLocalized("书架中有 %d 本书可以同步"), availableCount)
        }
        if store.books.isEmpty { return AppLocalized("登录成功后将自动进入书架。") }
        return String(format: AppLocalized("已在本机同步 %d 本书。"), store.books.count)
    }

    override convenience init() {
        self.init(
            analyticsSession: AnalyticsLibraryConnectionSession(
                source: .weread,
                entryPoint: "weread_connect"
            ),
            entryTapAlreadyTracked: false
        )
    }

    init(
        analyticsSession: AnalyticsLibraryConnectionSession,
        entryTapAlreadyTracked: Bool
    ) {
        let replyProxy = WeReadLoginReplyProxy()
        let nativeSessionConfiguration = URLSessionConfiguration.ephemeral
        nativeSessionConfiguration.httpShouldSetCookies = false
        nativeSessionConfiguration.httpCookieStorage = nil
        nativeSessionConfiguration.urlCache = nil
        nativeSessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        loginReplyProxy = replyProxy
        nativeLoginSession = URLSession(configuration: nativeSessionConfiguration)
        connectionAnalytics = AnalyticsLibraryConnectionRecorder(
            session: analyticsSession,
            entryTapAlreadyTracked: entryTapAlreadyTracked
        )
        let config = WKWebViewConfiguration(); config.websiteDataStore = CommercialWebSession.websiteDataStore; config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.userContentController.addUserScript(
            WKUserScript(
                source: WeReadWebScripts.loginSessionBridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        config.userContentController.addScriptMessageHandler(
            replyProxy,
            contentWorld: .page,
            name: "castReaderWeReadLogin"
        )
        webView = WKWebView(frame:.zero, configuration:config); super.init()
        replyProxy.owner = self
        webView.customUserAgent = WeReadWebScripts.desktopUserAgent; webView.navigationDelegate = self
    }

    func recordConnectionPresented() {
        connectionAnalytics.presented()
    }

    func closeConnection() {
        connectionAnalytics.close()
        stop()
    }

    func updateTheme(isDark: Bool) {
        let changed = isDarkMode != isDark
        isDarkMode = isDark
        webView.overrideUserInterfaceStyle = isDark ? .dark : .light
        guard changed, didLoad else { return }

        // The visible QR code is bound to the exact login UID owned by the
        // current WeRead document. Reloading for a color-scheme change creates
        // a second UID while the user is in WeChat scanning the screenshot, so
        // WeChat can report success although this WKWebView remains signed out.
        // Keep this document and its polling context intact. The themed URL and
        // cookie are prepared before the first load; a later appearance change
        // only affects WebKit's native trait until the user explicitly reopens
        // the binding flow.
        #if DEBUG
        print("[WeReadLogin] theme change applied without navigation; QR session preserved")
        #endif
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        connectionAnalytics.record(.loginStarted, result: .started)
        // Always begin at the desktop home page.  Opening /web/shelf with a
        // cleared session renders WeRead's empty shell and hides the login
        // affordance outside the phone viewport.
        statusText = AppLocalized("打开微信读书并登录。")
        WeReadNativeTheme.prepare(webView, isDark: isDarkMode) { [weak self, weak webView] in
            guard let self, let webView else { return }
            webView.load(URLRequest(url: WeReadNativeTheme.themedURL(WeReadWebScripts.homeURL, isDark: self.isDarkMode)))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.handleFinishedPage() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationGeneration &+= 1
        clearUntrustedShelfPreview()
        // `didFinish` can arrive several seconds after WeRead has already
        // painted its homepage because analytics/images are still loading.
        // Start watching for the real visible login action as soon as the main
        // document begins rendering. The JS contract still requires that exact
        // control to be visible and preserves an already-issued UID, so this
        // earlier start cannot create a duplicate QR session.
        guard !isShelfURL(webView.url) else {
            shelfNavigationRequested = false
            return
        }
        showsSyncBar = false
        showsLoginGuide = true
        startLoginPolling()
        presentLoginQRCodeIfNeeded()
    }

    func stop() {
        loginPollingTask?.cancel()
        loginPollingTask = nil
        loginPresentationTask?.cancel()
        loginPresentationTask = nil
        previewTask?.cancel()
        previewTask = nil
        foregroundResumeTask?.cancel()
        foregroundResumeTask = nil
        nativeLoginRetryTask?.cancel()
        nativeLoginRetryTask = nil
        nativeLoginTask?.cancel()
        nativeLoginTask = nil
        nativeLoginSession.invalidateAndCancel()
        deferredNativeLoginReply?(nil, "The WeRead login session ended.")
        deferredNativeLoginRequest = nil
        deferredNativeLoginReply = nil
        pendingLoginUID = nil
        pendingNativeLoginResult = nil
        endNativeLoginBackgroundTask()
    }

    func resumeOfficialLoginObservation() {
        guard didLoad else { return }
        startLoginPolling()
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            await self?.handleFinishedPage()
        }
    }

    func preserveLoginSessionBeforeBackground() {
        guard didLoad else { return }
        // `getLoginInfo` is a one-shot long poll. WebKit suspends page-owned
        // requests as soon as the user opens WeChat, so keep that exact
        // in-memory request alive natively for the short screenshot round trip.
        shouldResolveNativeLoginInForeground = true
        startDeferredNativeLoginPollIfNeeded()
        beginNativeLoginBackgroundTaskIfNeeded()
        Task { [weak self] in
            await self?.capturePendingLoginUID()
        }
    }

    /// The page's original 60-second login request is suspended while the
    /// user opens WeChat on this same iPhone. Resume that exact server-issued
    /// UID and pass the successful response through WeRead's own Vue handler.
    func resumeAfterExternalLogin() {
        guard didLoad else { return }
        foregroundResumeTask?.cancel()
        foregroundResumeTask = Task { [weak self] in
            guard let self else { return }
            self.shouldResolveNativeLoginInForeground = true
            self.endNativeLoginBackgroundTask()
            await self.capturePendingLoginUID()
            guard self.pendingLoginUID != nil else {
                self.resumeOfficialLoginObservation()
                return
            }
            self.startDeferredNativeLoginPollIfNeeded()
            self.startLoginPolling()

            // The document-start bridge keeps WeRead's original Vue promise
            // pending while URLSession owns the exact same UID poll. Give that
            // poll time to publish its result; never start a competing request
            // that could consume the one-shot confirmation first.
            var didProbeNativeResult = false
            for attempt in 0..<80 {
                guard !Task.isCancelled else { return }
                guard self.showsLoginGuide else { return }
                if let result = self.pendingNativeLoginResult {
                    if let scan = try? await self.evaluate(WeReadWebScripts.libraryScan),
                       scan.authenticated,
                       !scan.authRequired {
                        self.finishRecoveredLogin()
                        return
                    }
                    if !didProbeNativeResult {
                        didProbeNativeResult = true
                        let value = try? await self.webView.callAsyncJavaScript(
                            "return await \(WeReadWebScripts.resumeServerPolledLogin);",
                            arguments: [
                                "loginUID": self.pendingLoginUID ?? "",
                                "nativeLoginResult": result,
                            ],
                            in: nil,
                            contentWorld: .page
                        )
                        let payload = value as? [String: Any]
                        let state = payload?["state"] as? String ?? "unknown"
                        NSLog(
                            "CRDBG WEREAD login resume state=%@ credentials=Y attempt=%d",
                            state,
                            attempt + 1
                        )
                        if state == "handled" {
                            self.finishRecoveredLogin()
                            return
                        }
                    }
                } else if self.nativeLoginTask == nil,
                          self.deferredNativeLoginRequest != nil {
                    self.startDeferredNativeLoginPollIfNeeded()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self.resumeOfficialLoginObservation()
        }
    }

    private func finishRecoveredLogin() {
        shouldResolveNativeLoginInForeground = false
        deferredNativeLoginRequest = nil
        deferredNativeLoginReply = nil
        pendingLoginUID = nil
        pendingNativeLoginResult = nil
        loginPollingTask?.cancel()
        loginPollingTask = nil
        statusText = AppLocalized("登录成功，正在进入书架…")
        showsLoginGuide = false
        showsSyncBar = false
        webView.load(
            URLRequest(
                url: WeReadNativeTheme.themedURL(
                    WeReadWebScripts.shelfURL,
                    isDark: isDarkMode
                )
            )
        )
    }

    fileprivate func handleNativeLoginPoll(
        _ body: Any,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard
            let payload = body as? [String: Any],
            let rawUID = payload["uid"] as? String
        else {
            replyHandler(nil, "The WeRead login request did not contain a UID.")
            return
        }
        let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, uid.count <= 512 else {
            replyHandler(nil, "The WeRead login UID is invalid.")
            return
        }
        let otp = (payload["otp"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = (payload["requestID"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard otp.count <= 16, requestID.count <= 512 else {
            replyHandler(nil, "The WeRead login request metadata is invalid.")
            return
        }
        pendingLoginUID = uid
        if let previousReply = deferredNativeLoginReply {
            nativeLoginTask?.cancel()
            nativeLoginTask = nil
            previousReply(nil, "A newer WeRead login session replaced this request.")
        }
        deferredNativeLoginRequest = WeReadDeferredLoginRequest(
            uid: uid,
            otp: otp,
            requestID: requestID
        )
        deferredNativeLoginReply = replyHandler
        NSLog("CRDBG WEREAD login native-poll deferred")

        // Start in URLSession while the app is active. When the user opens
        // WeChat, a short background task keeps this exact one-shot request
        // alive instead of allowing WebKit to suspend and lose its response.
        if shouldResolveNativeLoginInForeground {
            startDeferredNativeLoginPollIfNeeded()
        }
    }

    private func startDeferredNativeLoginPollIfNeeded() {
        guard
            shouldResolveNativeLoginInForeground,
            nativeLoginTask == nil,
            let loginRequest = deferredNativeLoginRequest,
            let replyHandler = deferredNativeLoginReply
        else { return }

        nativeLoginTask = Task { [weak self] in
            guard let self else {
                replyHandler(nil, "The WeRead login session ended.")
                return
            }

            var components = URLComponents(
                url: URL(string: "https://weread.qq.com/api/auth/getLoginInfo")!,
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "uid", value: loginRequest.uid),
                URLQueryItem(name: "otp", value: loginRequest.otp),
            ]
            guard let url = components.url else {
                replyHandler(nil, "The WeRead login URL is invalid.")
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 65
            request.setValue(WeReadWebScripts.desktopUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://weread.qq.com/", forHTTPHeaderField: "Referer")
            if !loginRequest.requestID.isEmpty, loginRequest.requestID.count <= 512 {
                request.setValue(loginRequest.requestID, forHTTPHeaderField: "X-SSR-Request-Id")
            }
            if let cookieHeader = await self.currentWeReadCookieHeader(),
               cookieHeader.count <= 16_384 {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            do {
                let (data, response) = try await self.nativeLoginSession.data(for: request)
                guard
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode),
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.nativeLoginTask = nil
                    self.endNativeLoginBackgroundTask()
                    self.scheduleNativeLoginRetryIfNeeded()
                    return
                }
                let succeeded = (json["succeed"] as? Bool) == true
                let hasToken = !(json["accessToken"] as? String ?? "").isEmpty
                let hasVID = json["webLoginVid"] != nil && !(json["webLoginVid"] is NSNull)
                let logicCode = json["logicCode"] as? String ?? ""
                let terminalLogicCodes = Set([
                    "NEED_OTP",
                    "OTP_EXPIRED",
                    "OTP_NOT_MATCH",
                    "LOGIN_TIMEOUT",
                ])
                let hasCredentials = hasToken && hasVID
                let terminal = hasCredentials || terminalLogicCodes.contains(logicCode)
                if hasToken && hasVID {
                    self.pendingNativeLoginResult = json
                }
                NSLog(
                    "CRDBG WEREAD login native-poll completed success=%@ credentials=%@ terminal=%@",
                    succeeded ? "Y" : "N",
                    hasCredentials ? "Y" : "N",
                    terminal ? "Y" : "N"
                )
                if terminal,
                   self.deferredNativeLoginRequest?.uid == loginRequest.uid {
                    self.deferredNativeLoginRequest = nil
                    self.deferredNativeLoginReply = nil
                    replyHandler(json, nil)
                }
                self.nativeLoginTask = nil
                self.endNativeLoginBackgroundTask()
                if !terminal {
                    self.scheduleNativeLoginRetryIfNeeded()
                }
            } catch is CancellationError {
                self.nativeLoginTask = nil
                self.endNativeLoginBackgroundTask()
            } catch {
                let nsError = error as NSError
                NSLog(
                    "CRDBG WEREAD login native-poll failed domain=%@ code=%d",
                    nsError.domain,
                    nsError.code
                )
                self.nativeLoginTask = nil
                self.endNativeLoginBackgroundTask()
                self.scheduleNativeLoginRetryIfNeeded()
            }
        }
    }

    private func currentWeReadCookieHeader() async -> String? {
        await withCheckedContinuation { continuation in
            let gate = WeReadCookieHeaderGate(continuation)
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let scoped = cookies.filter {
                    let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return domain == "weread.qq.com" || domain.hasSuffix(".weread.qq.com")
                }
                // Cookie values stay inside this ephemeral request header.
                // They are never persisted or included in diagnostics.
                let header = scoped.isEmpty
                    ? nil
                    : HTTPCookie.requestHeaderFields(with: scoped)["Cookie"]
                Task { await gate.resolve(header) }
            }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await gate.resolve(nil)
            }
        }
    }

    private func scheduleNativeLoginRetryIfNeeded() {
        nativeLoginRetryTask?.cancel()
        guard shouldResolveNativeLoginInForeground,
              deferredNativeLoginRequest != nil,
              UIApplication.shared.applicationState == .active else { return }
        nativeLoginRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.nativeLoginRetryTask = nil
            self?.startDeferredNativeLoginPollIfNeeded()
        }
    }

    private func beginNativeLoginBackgroundTaskIfNeeded() {
        guard nativeLoginBackgroundTaskID == .invalid,
              nativeLoginTask != nil || deferredNativeLoginRequest != nil else { return }
        nativeLoginBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "CastReader.WeReadLogin"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.nativeLoginTask?.cancel()
                self?.endNativeLoginBackgroundTask()
            }
        }
    }

    private func endNativeLoginBackgroundTask() {
        guard nativeLoginBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(nativeLoginBackgroundTaskID)
        nativeLoginBackgroundTaskID = .invalid
    }

    // MARK: - 首启引导自动化
    //
    // 引导屏不自己驱动导航：登录与书架加载仍然由 WeRead 页面自身的生命周期
    // （didCommit / didFinish）推进，这里只做两件事——把分散的信号归纳成
    // `onboardingState`，以及在书架就绪时替用户按下那次「同步」。
    //
    // ⚠️ 铁律（docs/WeRead-iOS-Login-Session-Contract.md）：二维码可见到进入书架
    // 期间必须保持同一个 WKWebView、同一个 document、同一个登录 UID。所以这里
    // 只调 `loadIfNeeded()`（首次加载，自带 didLoad 保护），**绝不** load/reload/
    // goBack，也不因为主题或几何变化重新导航。

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
        // 已经就绪的结果要保留：引导切屏时不该把「书架已备好」退回未开始。
        if case .ready = onboardingState { return }
        onboardingState = .idle
    }

    func retryOnboardingScan() {
        errorText = nil
        restartOnboardingAutomation(reason: "manual-retry")
    }

    private func restartOnboardingAutomation(reason: String) {
        guard onboardingAutomationEnabled else { return }
        onboardingAttemptID += 1
        let attemptID = onboardingAttemptID
        onboardingAutomationTask?.cancel()
        onboardingAutomationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var syncAttempts = 0

            while !Task.isCancelled,
                  self.onboardingAutomationEnabled,
                  attemptID == self.onboardingAttemptID {
                let scan = try? await self.evaluate(WeReadWebScripts.libraryScan)
                guard !Task.isCancelled,
                      attemptID == self.onboardingAttemptID else { return }

                // 还没登录：页面自己在轮询并展示二维码，这里只负责报告状态。
                guard let scan, scan.authenticated, !scan.authRequired else {
                    self.onboardingState = .awaitingLogin
                    try? await Task.sleep(for: .milliseconds(700))
                    continue
                }

                // Authentication may complete while the retained WebView is
                // still showing WeRead's home page. That page contains valid
                // recommendation `/reader/` links, but it is not the user's
                // shelf and must never feed onboarding or persistence.
                guard self.isTrustedShelfResult(scan) else {
                    self.clearUntrustedShelfPreview()
                    self.onboardingState = .scanning(found: 0)
                    self.statusText = AppLocalized("正在打开微信读书书架…")
                    self.navigateToShelfIfNeeded()
                    try? await Task.sleep(for: .milliseconds(700))
                    continue
                }

                self.onboardingState = .scanning(
                    found: max(self.availableCount, scan.books.count)
                )

                // 页面自身的扫描/同步正在跑，等它。
                if self.isScanning || self.isSyncing {
                    try? await Task.sleep(for: .milliseconds(600))
                    continue
                }

                if self.pendingBooks.isEmpty {
                    // didFinish 尚未把书架抓完（例如刚从登录跳过来），补一次。
                    await self.refreshPreview()
                    guard !Task.isCancelled,
                          attemptID == self.onboardingAttemptID else { return }
                }

                if !self.pendingBooks.isEmpty {
                    syncAttempts += 1
                    let synced = await self.syncLibrary()
                    guard !Task.isCancelled,
                          attemptID == self.onboardingAttemptID else { return }
                    if synced, !self.store.books.isEmpty {
                        self.onboardingState = .ready
                        return
                    }
                    if syncAttempts >= 2 {
                        self.onboardingState = .failed(
                            message: self.errorText
                                ?? AppLocalized("暂时没能同步微信读书书架，请重试。")
                        )
                        return
                    }
                } else if self.hasTrustedShelfSnapshot {
                    self.onboardingState = .empty
                    return
                } else if let errorText = self.errorText {
                    self.onboardingState = .failed(message: errorText)
                    return
                }

                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    func syncLibrary() async -> Bool {
        if pendingBooks.isEmpty && !hasTrustedShelfSnapshot { await refreshPreview() }
        let observedSessionFingerprint = await currentAuthenticatedWeReadSessionFingerprint()
        // This is the final boundary check after the final suspension point.
        // An A→B CastReader account/route switch can occur while cookie lookup
        // awaits WKWebView; no A-owned rows may then reach B's active store.
        guard let accountBoundaryToken,
              AccountContentIsolation.isCurrent(accountBoundaryToken),
              !isSyncing,
              hasTrustedShelfSnapshot,
              isShelfURL(webView.url),
              !pendingBooks.isEmpty,
              trustedSnapshotNavigationGeneration == navigationGeneration,
              let trustedSnapshotSessionFingerprint,
              trustedSnapshotSessionFingerprint == observedSessionFingerprint else {
            connectionAnalytics.record(
                .failed,
                result: .failed,
                errorCode: "sync_snapshot_unavailable"
            )
            return false
        }
        connectionAnalytics.record(.syncStarted, result: .started)
        isSyncing = true
        errorText = nil
        defer { isSyncing = false }
        // Release synchronization is intentionally additive. A virtualised
        // shelf or transient parse miss may omit a real row; it must never
        // delete an existing book, reading position or anchor. The one known
        // pre-release polluted snapshot is cleared only by the DEBUG-scoped
        // recovery argument before this verified shelf is merged.
        store.mergeScrapedBooks(Array(pendingBooks.values), account: pendingAccount)
        if let commitError = store.lastError {
            errorText = commitError
            connectionAnalytics.record(
                .failed,
                result: .failed,
                errorCode: "local_commit_failed"
            )
            return false
        }
        let verifiedBookCount = pendingBooks.count
        guard connectionAnalytics.record(
            .syncCompleted,
            result: .success,
            bookCount: verifiedBookCount
        ) else {
            errorText = AppLocalized("书架已保存，但同步确认未完成，请重试。")
            return false
        }
        statusText = String(
            format: AppLocalized("已同步 %d 本微信读书书籍。"),
            verifiedBookCount
        )
        return true
    }

    private func handleFinishedPage() async {
        guard let result = try? await evaluate(WeReadWebScripts.libraryScan) else {
            showsLoginGuide = true
            startLoginPolling()
            presentLoginQRCodeIfNeeded()
            return
        }
        if result.authRequired || !result.authenticated {
            resetUnauthenticatedPreview()
            statusText = AppLocalized("请先登录微信读书，登录后会自动进入书架。")
            startLoginPolling()
            presentLoginQRCodeIfNeeded()
            return
        }
        connectionAnalytics.record(.loginSucceeded, result: .success)
        loginPollingTask?.cancel()
        loginPresentationTask?.cancel()
        loginPresentationTask = nil
        showsLoginGuide = false
        if !isTrustedShelfResult(result) {
            clearUntrustedShelfPreview()
            showsSyncBar = false
            statusText = AppLocalized("正在打开微信读书书架…")
            navigateToShelfIfNeeded()
            return
        }
        showsSyncBar = true
        await refreshPreview()
    }

    private func refreshPreview() async {
        guard !isScanning else { return }
        isScanning = true
        errorText = nil
        hasTrustedShelfSnapshot = false
        trustedSnapshotNavigationGeneration = nil
        trustedSnapshotSessionFingerprint = nil
        pendingBooks = [:]
        pendingAccount = nil
        availableCount = 0
        defer {
            isScanning = false
            webView.evaluateJavaScript(
                WeReadWebScripts.shelfScanResetToTop,
                completionHandler: nil
            )
        }
        guard isShelfURL(webView.url) else {
            navigateToShelfIfNeeded()
            return
        }
        let scanNavigationGeneration = navigationGeneration
        guard let scanSessionFingerprint = await currentAuthenticatedWeReadSessionFingerprint() else {
            resetUnauthenticatedPreview()
            statusText = AppLocalized("请先登录微信读书，登录后会自动进入书架。")
            startLoginPolling()
            presentLoginQRCodeIfNeeded()
            return
        }
        _ = try? await webView.evaluateJavaScript(WeReadWebScripts.shelfScanResetToTop)
        try? await Task.sleep(for: .milliseconds(250))
        var all: [String: WeReadBook] = [:]
        var stableEndPasses = 0
        var account: WeReadAccountInfo?
        var completedSnapshot = false
        var lastScan: WeReadScanResult?
        let clock = ContinuousClock()
        let startedAt = clock.now
        var lastProgressAt = startedAt
        for _ in 0..<280 {
            guard !Task.isCancelled,
                  scanNavigationGeneration == navigationGeneration else { return }
            statusText = String(format: AppLocalized("正在扫描微信读书书架…（%d）"), all.count)
            guard let result = try? await evaluate(WeReadWebScripts.libraryScan) else {
                try? await Task.sleep(for: .milliseconds(350))
                continue
            }
            if result.authRequired || !result.authenticated {
                resetUnauthenticatedPreview()
                statusText = AppLocalized("请先登录微信读书，登录后会自动进入书架。")
                startLoginPolling()
                presentLoginQRCodeIfNeeded()
                return
            }
            guard isTrustedShelfResult(result) else {
                clearUntrustedShelfPreview()
                statusText = AppLocalized("正在打开微信读书书架…")
                navigateToShelfIfNeeded()
                return
            }
            lastScan = result
            if let label = result.account { account = WeReadAccountInfo(label: label) }
            let before = all.count
            // Rows the native validator rejects are definitively not library
            // books; drop them from the sync set instead of vetoing the pass.
            result.books
                .filter(WeReadBookValidator.isLikelyLibraryBook)
                .forEach { all[$0.id] = $0 }
            pendingBooks = all
            pendingAccount = account
            availableCount = all.count
            if all.count > before { lastProgressAt = clock.now }
            let stableAtEnd = WeReadShelfSnapshotContract.isStableEndPass(
                result,
                accumulatedUnchanged: all.count == before
            )
            stableEndPasses = stableAtEnd ? stableEndPasses + 1 : 0
            let requiredStablePasses = WeReadShelfSnapshotContract.requiredStablePasses(
                accumulatedIsEmpty: all.isEmpty,
                hasAddTile: result.hasAddTile
            )
            if stableEndPasses >= requiredStablePasses {
                // An empty DOM shell is not an authoritative empty shelf.
                guard !all.isEmpty || result.emptyShelfEvidence else {
                    finishFailedScan(reason: "empty_without_evidence", lastScan: result)
                    return
                }
                completedSnapshot = true
                break
            }
            if startedAt.duration(to: clock.now) >= WeReadShelfSnapshotContract.hardBudget
                || lastProgressAt.duration(to: clock.now) >= WeReadShelfSnapshotContract.idleBudget {
                break
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        guard completedSnapshot else {
            pendingBooks = [:]
            pendingAccount = nil
            availableCount = 0
            finishFailedScan(
                reason: WeReadShelfSnapshotContract.failureReason(lastScan: lastScan),
                lastScan: lastScan
            )
            return
        }
        guard scanNavigationGeneration == navigationGeneration,
              scanSessionFingerprint == (await currentAuthenticatedWeReadSessionFingerprint()) else {
            clearUntrustedShelfPreview()
            finishFailedScan(reason: "session_changed", lastScan: lastScan)
            return
        }
        if let lastScan {
            NSLog(
                "CRDBG WEREAD shelf-scan complete books=%d raw=%d pending=%d excluded=%d addTile=%@ passes=%d",
                all.count,
                lastScan.rawBookCount,
                lastScan.pendingRowCount,
                lastScan.excludedRowCount,
                lastScan.hasAddTile ? "Y" : "N",
                stableEndPasses
            )
        }
        hasTrustedShelfSnapshot = true
        trustedSnapshotNavigationGeneration = scanNavigationGeneration
        trustedSnapshotSessionFingerprint = scanSessionFingerprint
        guard !all.isEmpty else {
            statusText = AppLocalized("你的微信读书书架还没有书")
            return
        }
        statusText = String(format: AppLocalized("已找到 %d 本微信读书书籍。"), all.count)
    }

    /// One place for scan-failure exit: reason-coded analytics + log (counts
    /// only, never titles/URLs/account data) and a user-facing message that
    /// distinguishes network trouble from an unrecognised shelf.
    private func finishFailedScan(reason: String, lastScan: WeReadScanResult?) {
        NSLog(
            "CRDBG WEREAD shelf-scan failed reason=%@ raw=%d parsed=%d pending=%d excluded=%d addTile=%@ ready=%@ end=%@ loading=%@ err=%@",
            reason,
            lastScan?.rawBookCount ?? -1,
            lastScan?.books.count ?? -1,
            lastScan?.pendingRowCount ?? -1,
            lastScan?.excludedRowCount ?? -1,
            (lastScan?.hasAddTile ?? false) ? "Y" : "N",
            (lastScan?.documentReady ?? false) ? "Y" : "N",
            (lastScan?.reachedShelfEnd ?? false) ? "Y" : "N",
            (lastScan?.loading ?? false) ? "Y" : "N",
            (lastScan?.loadError ?? false) ? "Y" : "N"
        )
        connectionAnalytics.record(
            .failed,
            result: .failed,
            errorCode: "shelf_scan_\(reason)"
        )
        errorText = WeReadShelfSnapshotContract.isNetworkShapedFailure(reason)
            ? AppLocalized("书架仍在加载，请稍后重试。")
            : AppLocalized("暂时没能同步微信读书书架，请重试。")
    }

    private func capturePendingLoginUID() async {
        guard let value = try? await webView.evaluateJavaScript(
            "String(window.__castreaderWeReadLoginSession?.uid || '')"
        ),
        let uid = value as? String,
        !uid.isEmpty else { return }
        // In-memory only. Never persist or print WeRead's one-time login UID.
        pendingLoginUID = uid
    }

    private func startLoginPolling() {
        guard loginPollingTask == nil else { return }
        loginPollingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loginPollingTask = nil }
            for _ in 0..<180 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard let result = try? await self.evaluate(WeReadWebScripts.libraryScan),
                      !result.authRequired, result.authenticated else { continue }
                self.statusText = AppLocalized("登录成功，正在进入书架…")
                self.loginPresentationTask?.cancel()
                self.loginPresentationTask = nil
                self.showsLoginGuide = false
                if self.isShelfURL(self.webView.url) {
                    self.showsSyncBar = true
                    await self.refreshPreview()
                } else {
                    self.showsSyncBar = false
                    self.navigateToShelfIfNeeded()
                }
                return
            }
        }
    }

    /// Presents WeRead's own UID-backed login modal after its Vue tree has
    /// hydrated. Repeated observations never replace a valid UID: the JS
    /// contract returns the existing visible QR as soon as one has been issued.
    /// This method performs no navigation, so the screenshot, polling request
    /// and foreground recovery all remain attached to one page document.
    private func presentLoginQRCodeIfNeeded() {
        guard showsLoginGuide, loginPresentationTask == nil else { return }
        loginPresentationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loginPresentationTask = nil }
            for attempt in 0..<160 {
                guard !Task.isCancelled, self.showsLoginGuide, !self.showsSyncBar else { return }
                let payload: [String: Any]?
                do {
                    let value = try await self.webView.evaluateJavaScript(WeReadWebScripts.openLoginQRCode)
                    payload = value as? [String: Any]
                } catch {
                    payload = nil
                    if attempt == 0 || attempt.isMultiple(of: 10) {
                        let nsError = error as NSError
                        NSLog(
                            "CRDBG WEREAD login auto-present script-error domain=%@ code=%d",
                            nsError.domain,
                            nsError.code
                        )
                    }
                }
                if attempt == 0 || attempt.isMultiple(of: 10) {
                    NSLog(
                        "CRDBG WEREAD login auto-present state=%@ vue=%@ candidates=%@ strategy=%@",
                        payload?["state"] as? String ?? "no-result",
                        (payload?["vueReady"] as? Bool) == true ? "Y" : "N",
                        String(describing: payload?["exactLoginTextCount"] ?? 0),
                        payload?["strategy"] as? String ?? ""
                    )
                }
                if let uid = payload?["loginUID"] as? String, !uid.isEmpty {
                    self.pendingLoginUID = uid
                }
                if payload?["state"] as? String == "visible",
                   self.pendingLoginUID != nil {
                    return
                }
                // During initial rendering the login action usually appears
                // within a few animation frames. A short poll avoids waiting
                // for WKNavigationDelegate.didFinish while keeping all login
                // state owned by WeRead's single page document.
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func isShelfURL(_ url: URL?) -> Bool {
        WeReadShelfPageContract.isExactShelfURL(url)
    }

    private func isTrustedShelfResult(_ result: WeReadScanResult) -> Bool {
        result.isShelfPage
            && WeReadShelfPageContract.isExactShelfURL(result.pageURL)
            && isShelfURL(webView.url)
    }

    private func navigateToShelfIfNeeded() {
        if isShelfURL(webView.url) {
            shelfNavigationRequested = false
            return
        }
        guard !shelfNavigationRequested else { return }
        shelfNavigationRequested = true
        webView.load(
            URLRequest(
                url: WeReadNativeTheme.themedURL(
                    WeReadWebScripts.shelfURL,
                    isDark: isDarkMode
                )
            )
        )
    }

    private func clearUntrustedShelfPreview() {
        hasTrustedShelfSnapshot = false
        trustedSnapshotNavigationGeneration = nil
        trustedSnapshotSessionFingerprint = nil
        availableCount = 0
        pendingBooks = [:]
        pendingAccount = nil
    }

    private func resetUnauthenticatedPreview() {
        showsSyncBar = false
        showsLoginGuide = true
        shelfNavigationRequested = false
        clearUntrustedShelfPreview()
        errorText = nil
    }

    /// Uses WKHTTPCookieStore so HttpOnly `wr_skey` participates in the gate.
    /// Cookie values are hashed in memory and are never persisted or logged.
    private func currentAuthenticatedWeReadSessionFingerprint() async -> String? {
        guard let cookieHeader = await currentWeReadCookieHeader() else { return nil }
        var values: [String: String] = [:]
        for item in cookieHeader.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            values[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] = pair[1]
        }
        // wr_skey must exist (HttpOnly session evidence) but rotates during
        // long scans; the fingerprint compares only the stable account vid so
        // a mid-scan skey refresh cannot fail an unchanged account.
        guard let vid = values["wr_vid"] ?? values["wr_localvid"],
              !vid.isEmpty,
              values["wr_skey"]?.isEmpty == false else { return nil }
        let digest = SHA256.hash(data: Data("vid:\(vid)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func evaluate(_ js: String) async throws -> WeReadScanResult {
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in if let error { continuation.resume(throwing:error) } else { continuation.resume(returning:value as Any) } }
        }
        guard let raw = value as? [String:Any] else { throw NSError(domain:"WeRead",code:1) }
        return WeReadScanResult(raw)
    }
}
