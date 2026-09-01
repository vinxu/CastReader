//
//  GoogleBooksLibraryViews.swift
//  CastReader
//
//  Google Play 图书绑定书库的三块 UI：首页书架条、绑定（登录+同步）页、完整书架页。
//  交互与 Kindle / 微信读书完全一致，只有登录方式不同：Play 图书直接用它自己的
//  手机端网页登录，登录态留在 WKWebView 的 website data store，CastReader 不碰凭据。
//

import SwiftUI
import WebKit

extension Notification.Name {
    /// 复用已存在的绑定流程，不再另建第二个登录 WebView。
    static let castReaderGoogleBooksRebindRequested =
        Notification.Name("castreader.googlebooks.rebindRequested")
}

// MARK: - 首页书架条

struct GoogleBooksHomeSection: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = GoogleBooksLibraryStore.shared
    @ObservedObject private var onboarding = BoundLibraryOnboardingStore.shared

    var body: some View {
        Group {
            if !store.needsConnection && !store.homeBooks.isEmpty {
                VStack(alignment: .leading, spacing: HomeLayout.headerToContent) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: HomeLayout.titleToSubtitle) {
                            Text(AppLocalized("Google Play 图书"))
                                .font(.headline)
                                .foregroundColor(AppTheme.foreground)
                            Text(AppLocalized("已同步的 Google Play 图书书架"))
                                .font(.caption)
                                .foregroundColor(AppTheme.mutedForeground)
                        }
                        Spacer()
                        NavigationLink(destination: GoogleBooksLibraryView()) {
                            Text(AppLocalized("查看全部"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(AppTheme.primary)
                        }
                        .accessibilityIdentifier("homeShelfViewAll.google_books")
                    }

                    HomeHorizontalRail(alignment: .top) {
                        ForEach(store.homeBooks) { book in
                            Button { open(book) } label: { GoogleBooksRailCard(book: book) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(
                                    "homeShelfBook.google_books.\(book.volumeID ?? book.id)"
                                )
                        }
                    }
                }
                .accessibilityIdentifier("homeShelfSection.google_books")
            }
        }
    }

    private var connectCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "book.pages")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(AppTheme.primary)
                .frame(width: 48, height: 48)
                .background(AppTheme.primary.opacity(0.12))
                .cornerRadius(12)
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("绑定 Google Play 图书"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.foreground)
                Text(AppLocalized("登录后同步书架与阅读进度"))
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.mutedForeground)
        }
        .padding(14)
        .background(AppTheme.surface)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border.opacity(0.7), lineWidth: 1))
    }

    private func open(_ book: GoogleBooksBook) {
        GoogleBooksReaderLauncher.open(book, using: coordinator, onboarding: onboarding)
    }
}

/// 打开一本 Play 图书 = 打开它的网页阅读器。所有入口共用这一条路径，
/// 保证埋点上下文、进度标记和 sourceKind 都一致。
enum GoogleBooksReaderLauncher {
    @MainActor
    static func open(
        _ book: GoogleBooksBook,
        using coordinator: PlayerCoordinator,
        onboarding: BoundLibraryOnboardingStore,
        autoplay: Bool = false
    ) {
        let store = GoogleBooksLibraryStore.shared
        store.markOpened(book)
        // Cards passed from SwiftUI are value snapshots. Resolve the store
        // again after markOpened so every entry point uses the newest `pg`
        // anchor instead of a stale copy retained by the view.
        let latestBook = store.book(for: book.id) ?? book
        var sourceURL = latestBook.effectiveReaderURL
#if DEBUG
        // Opt-in live-account UI tests can pin the exact `pg` URL supplied by
        // the product acceptance case without changing production navigation.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-CastReaderGoogleBooksLiveTestURL"),
           arguments.indices.contains(flag + 1),
           let expectedVolumeID = latestBook.volumeID,
           let override = GoogleBooksBookValidator.usableResumeURL(
               arguments[flag + 1],
               expecting: expectedVolumeID
           ) {
            sourceURL = override
        }
#endif
        let document = ReadingDocument(
            id: latestBook.id,
            title: latestBook.title,
            sourceKind: .googleBooks,
            language: Constants.TTS.defaultLanguage,
            paragraphs: [],
            sourceURL: sourceURL,
            coverURL: latestBook.coverURL
        )
        let context = ProductAnalytics.shared.beginContentIntent(
            source: .googleBooks,
            format: .googleBooks,
            entryPoint: onboarding.analyticsEntryPoint(for: .googleBooks) ?? "google_books_library",
            intendedMode: "read"
        )
        coordinator.open(document, mode: .read, autoplay: autoplay, analyticsContext: context)
    }
}

// MARK: - 绑定（登录 + 同步）

struct GoogleBooksLibraryConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GoogleBooksLibrarySyncViewModel

    init(
        analyticsSession: AnalyticsLibraryConnectionSession? = nil,
        entryTapAlreadyTracked: Bool = false
    ) {
        let session = analyticsSession ?? AnalyticsLibraryConnectionSession(
            source: .googleBooks,
            entryPoint: "google_books_connect"
        )
        _model = StateObject(
            wrappedValue: GoogleBooksLibrarySyncViewModel(
                analyticsSession: session,
                entryTapAlreadyTracked: entryTapAlreadyTracked
            )
        )
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                GoogleBooksWebViewContainer(webView: model.webView)
                    .accessibilityIdentifier("googleBooksBindingWebView")
                    .ignoresSafeArea(edges: .bottom)
                if let popupWebView = model.popupWebView {
                    GoogleBooksWebViewContainer(webView: popupWebView)
                        .accessibilityIdentifier("googleBooksLoginPopupWebView")
                        .background(AppTheme.background)
                        .ignoresSafeArea(edges: .bottom)
                }
                // A Google-owned popup must have the full viewport. Native
                // bottom chrome would otherwise cover password/passkey fields.
                if model.popupWebView == nil {
                    if model.showsSyncBar {
                        syncBar
                    } else if model.showsLoginGuide {
                        loginGuideBar
                    }
                }
            }
            .navigationTitle(AppLocalized("绑定 Google Play 图书"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("关闭")) { dismiss() }
                }
            }
            .onAppear {
                model.recordConnectionPresented()
                model.loadIfNeeded()
            }
            .onDisappear { model.closeConnection() }
            .onChange(of: model.liveLoginGateDidSync) { _, didSync in
                if didSync { dismiss() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var loginGuideBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalized("请登录你的 Google 账号"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                    Text(AppLocalized("登录后会自动打开「我的图书」，供你同步到 CastReader。CastReader 不会保存你的密码。"))
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Button {
                model.openSignIn()
            } label: {
                HStack(spacing: 8) {
                    if model.isStartingSignIn {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    Text(AppLocalized("登录"))
                }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .disabled(model.isStartingSignIn)
            .accessibilityIdentifier("googleBooksSignInButton")
            if let error = model.errorText {
                inlineError(error)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("googleBooksLoginGuide")
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
                    Text(model.isScanning
                         ? model.statusText
                         : (model.availableCount > 0
                            ? String(format: AppLocalized("检测到 %d 本书"), model.availableCount)
                            : model.statusText))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                        .lineLimit(2)
                    Text(model.isScanning
                         ? AppLocalized("正在等待书架内容完整加载，请勿关闭此页面。")
                         : (model.availableCount > 0
                            ? AppLocalized("同步后即可在 CastReader 中朗读和解读。")
                            : model.secondaryStatus))
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(2)
                }
                Spacer()
            }
            if let error = model.errorText {
                inlineError(error)
            }
            if model.showsSyncAction && model.canSyncLibrary {
                Button {
                    Task { if await model.syncLibrary() { dismiss() } }
                } label: {
                    HStack(spacing: 8) {
                        if model.isSyncing { ProgressView().tint(.white) }
                        Text(
                            model.availableCount > 0
                                ? String(
                                    format: AppLocalized("同步 %d 本书"),
                                    model.availableCount
                                )
                                : AppLocalized("完成绑定")
                        )
                        .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(model.isScanning || model.isSyncing)
                .accessibilityIdentifier("syncGoogleBooksLibraryButton")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("googleBooksSyncBar")
    }

    @ViewBuilder
    private func inlineError(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.destructive)
            Text(message)
                .font(.caption)
                .foregroundColor(AppTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(AppLocalized("重试")) { model.retry() }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("retryGoogleBooksBindingButton")
        }
    }
}

// MARK: - 完整书架

struct GoogleBooksLibraryView: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = GoogleBooksLibraryStore.shared
    @ObservedObject private var onboarding = BoundLibraryOnboardingStore.shared
    @State private var query = ""
    @State private var sort: GoogleBooksLibrarySort = .recent
    @State private var page = 1
    @State private var showConnect = false

    private var visible: [GoogleBooksBook] {
        Array(store.sortedBooks(sort: sort, query: query).prefix(page * 24))
    }
    private var all: [GoogleBooksBook] { store.sortedBooks(sort: sort, query: query) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker(AppLocalized("排序"), selection: $sort) {
                        ForEach(GoogleBooksLibrarySort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button { showConnect = true } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 36, height: 36)
                            .background(AppTheme.primary.opacity(0.12), in: Circle())
                    }
                    .foregroundColor(AppTheme.primary)
                    .accessibilityLabel(AppLocalized("刷新"))
                    .accessibilityIdentifier("refreshGoogleBooksLibraryButton")
                }
                if visible.isEmpty {
                    empty
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(visible) { book in
                            GoogleBooksLibraryRow(book: book, open: { open(book) })
                        }
                    }
                    if visible.count < all.count {
                        Button(AppLocalized("加载更多")) { page += 1 }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundColor(AppTheme.primary)
                    }
                }
            }
            .padding(18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("Google Play 图书书架"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: AppLocalized("搜索 Google Play 图书"))
        .onChange(of: query) { _, _ in page = 1 }
        .onChange(of: sort) { _, _ in page = 1 }
        .sheet(isPresented: $showConnect) { GoogleBooksLibraryConnectView() }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: store.needsConnection ? "book.pages" : "magnifyingglass")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(AppTheme.primary)
            Text(store.needsConnection
                 ? AppLocalized("绑定 Google Play 图书")
                 : AppLocalized("没有匹配的书籍"))
                .font(.headline)
            Button(store.needsConnection ? AppLocalized("登录") : AppLocalized("刷新")) {
                showConnect = true
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func open(_ book: GoogleBooksBook) {
        GoogleBooksReaderLauncher.open(book, using: coordinator, onboarding: onboarding)
    }
}

// MARK: - 卡片

private struct GoogleBooksRailCard: View {
    let book: GoogleBooksBook
    var body: some View {
        VStack(alignment: .leading, spacing: HomeLayout.mediaToTextGap) {
            GoogleBooksCoverView(urlString: book.coverURL)
                .frame(width: 96, height: 144)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border.opacity(0.65), lineWidth: 1))
            Text(book.title)
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.foreground)
                .lineLimit(2)
                .frame(width: 104, height: 34, alignment: .topLeading)
            Text(book.displayProgress)
                .font(.caption2)
                .foregroundColor(AppTheme.mutedForeground)
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
        }
        .frame(width: 108, alignment: .topLeading)
    }
}

private struct GoogleBooksLibraryRow: View {
    let book: GoogleBooksBook
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                GoogleBooksCoverView(urlString: book.coverURL)
                    .frame(width: 64, height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppTheme.border.opacity(0.65), lineWidth: 1))
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                        .lineLimit(2)
                    Text(book.displayAuthor)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)
                    Text(book.displayProgress)
                        .font(.caption2)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.mutedForeground.opacity(0.8))
                    .frame(width: 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("googleBooksBook.\(book.volumeID ?? book.id)")
        .padding(12)
        .background(AppTheme.surface)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border.opacity(0.65), lineWidth: 1))
    }
}

struct GoogleBooksCoverView: View {
    let urlString: String?
    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            CachedAsyncImage(url: url, contentMode: .fill) {
                placeholder.overlay { ProgressView().scaleEffect(0.75) }
            }
        } else {
            placeholder
        }
    }
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.primary.opacity(0.18), AppTheme.surfaceVariant],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "book.pages")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(AppTheme.primary)
        }
    }
}

struct GoogleBooksWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        configureAppearance(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        configureAppearance(uiView)
    }

    private func configureAppearance(_ webView: WKWebView) {
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
    }
}

// MARK: - 登录 / 扫描

@MainActor
final class GoogleBooksLibrarySyncViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var isScanning = false
    @Published var isSyncing = false
    @Published private(set) var bindingPhase: GoogleBooksBindingPhase = .needsSignIn
    @Published var availableCount = 0
    @Published var statusText = AppLocalized("正在打开 Google Play 图书…")
    @Published var errorText: String?
    @Published private(set) var popupWebView: WKWebView?
    @Published private(set) var isStartingSignIn = false
    /// DEBUG-only live-account UI tests use this signal to close the sheet
    /// after the real shelf has been scanned and persisted. Production builds
    /// never set it.
    @Published private(set) var liveLoginGateDidSync = false

    let webView: WKWebView
    private let store = GoogleBooksLibraryStore.shared
    private let accountBoundaryToken = AccountContentIsolation.captureBoundaryToken()
    private var didLoad = false
    private var pendingBooks: [String: GoogleBooksBook] = [:]
    private var pendingAccount: GoogleBooksAccountInfo?
    private var loginPollingTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var shelfRecoveryTask: Task<Void, Never>?
    private var signInLaunchTask: Task<Void, Never>?
    private var signInRequestGeneration = 0
    private var activeSignInNavigation: WKNavigation?
    private var didEnterCredentialFlow = false
    private let requestLoader: (WKWebView, URLRequest) -> WKNavigation?
    private let signInURLResolver: (WKWebView) async -> URL?
    /// Only a settled scan can be committed. `pendingAccount` becomes complete
    /// on early virtual-list passes too, so it is not sufficient on its own.
    private var hasStableShelfSnapshot = false
    private let analyticsSession: AnalyticsLibraryConnectionSession
    private let connectionAnalytics: AnalyticsLibraryConnectionRecorder

    var showsSyncBar: Bool {
        GoogleBooksBindingFlowContract.showsSyncBar(for: bindingPhase)
    }

    var showsLoginGuide: Bool {
        GoogleBooksBindingFlowContract.showsLoginGuide(for: bindingPhase)
    }

    var showsSyncAction: Bool {
        GoogleBooksBindingFlowContract.showsSyncAction(for: bindingPhase)
    }

    var secondaryStatus: String {
        if availableCount > 0 {
            return String(format: AppLocalized("书架中有 %d 本书可以同步"), availableCount)
        }
        if store.books.isEmpty { return AppLocalized("登录成功后将自动进入书架。") }
        return String(format: AppLocalized("已在本机同步 %d 本书。"), store.books.count)
    }

    var canSyncLibrary: Bool {
        hasStableShelfSnapshot && (
            !pendingBooks.isEmpty
            || pendingAccount?.hasAccountEvidence == true
                && pendingAccount?.isShelfContext == true
                && pendingAccount?.isCompleteSnapshot == true
        )
    }

    override convenience init() {
        self.init(
            requestLoader: { webView, request in webView.load(request) },
            signInURLResolver: { webView in
                await Self.currentPageSignInURL(in: webView)
            },
            analyticsSession: AnalyticsLibraryConnectionSession(
                source: .googleBooks,
                entryPoint: "google_books_connect"
            ),
            entryTapAlreadyTracked: false
        )
    }

    convenience init(
        analyticsSession: AnalyticsLibraryConnectionSession,
        entryTapAlreadyTracked: Bool
    ) {
        self.init(
            requestLoader: { webView, request in webView.load(request) },
            signInURLResolver: { webView in
                await Self.currentPageSignInURL(in: webView)
            },
            analyticsSession: analyticsSession,
            entryTapAlreadyTracked: entryTapAlreadyTracked
        )
    }

    /// Internal injection points keep the native login button contract
    /// testable without requiring a live Google account.
    init(
        requestLoader: @escaping (WKWebView, URLRequest) -> WKNavigation?,
        signInURLResolver: @escaping (WKWebView) async -> URL?,
        analyticsSession: AnalyticsLibraryConnectionSession = AnalyticsLibraryConnectionSession(
            source: .googleBooks,
            entryPoint: "google_books_connect"
        ),
        entryTapAlreadyTracked: Bool = false
    ) {
        let config = WKWebViewConfiguration()
        // 与阅读器共用同一个 data store：这里登录一次，阅读器就是已登录状态。
        config.websiteDataStore = GoogleWebSession.websiteDataStore
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: .zero, configuration: config)
        self.requestLoader = requestLoader
        self.signInURLResolver = signInURLResolver
        self.analyticsSession = analyticsSession
        self.connectionAnalytics = AnalyticsLibraryConnectionRecorder(
            session: analyticsSession,
            entryTapAlreadyTracked: entryTapAlreadyTracked
        )
        super.init()
        // Google 会用 UA 判定「不安全的浏览器」并拒绝登录 —— 必须是完整 Mobile Safari UA。
        webView.customUserAgent = GoogleBooksWebScripts.mobileSafariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
#if DEBUG
        webView.isInspectable = true
#endif
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
#if DEBUG
        // XCUI can intermittently omit SwiftUI controls layered above a
        // WKWebView from its accessibility tree. The opt-in live gate should
        // test Google's real sign-in and shelf, not the reliability of tapping
        // that overlay, so enter the same production sign-in route directly.
        if Self.isLiveLoginGate {
            openSignIn()
            return
        }
#endif
        webView.load(URLRequest(url: GoogleBooksWebScripts.homeURL))
    }

    func recordConnectionPresented() {
        connectionAnalytics.presented()
    }

    func closeConnection() {
        connectionAnalytics.close()
        stop()
    }

    func openSignIn() {
        guard bindingPhase == .needsSignIn, !isStartingSignIn else { return }
        recordConnectionStage(.loginStarted, result: .started)
        stop()
        webView.stopLoading()
        store.clearError()
        errorText = nil
        hasStableShelfSnapshot = false
        statusText = AppLocalized("请先登录 Google 账号，登录后会自动进入书架。")
        isStartingSignIn = true
        signInRequestGeneration &+= 1
        let generation = signInRequestGeneration
        signInLaunchTask = Task { [weak self] in
            guard let self else { return }
            let dynamicURL = await self.signInURLResolver(self.webView)
            guard !Task.isCancelled,
                  generation == self.signInRequestGeneration else {
                return
            }

            // A stale home-page didFinish can start preview/polling again
            // between the tap and this asynchronous DOM lookup.
            self.cancelFlowTasks()
            self.webView.stopLoading()
            let target = dynamicURL ?? GoogleBooksWebScripts.signInURL
            guard Self.allowedTopLevelURL(target) != nil,
                  let navigation = self.requestLoader(
                      self.webView,
                      URLRequest(url: target)
                  ) else {
                self.signInLaunchTask = nil
                self.isStartingSignIn = false
                self.bindingPhase = .needsSignIn
                self.errorText = AppLocalized("内容暂时无法打开，请重试")
                return
            }

            // Only hide the native card after WebKit accepts a real
            // credential navigation. didStart keeps this token current across
            // later password/2FA form submissions.
            self.activeSignInNavigation = navigation
            self.didEnterCredentialFlow = false
            self.bindingPhase = .signingIn
            self.signInLaunchTask = nil
            self.isStartingSignIn = false
        }
    }

    func retry() {
        stop()
        errorText = nil
        hasStableShelfSnapshot = false
        let isCredentialPage =
            GoogleBooksBindingFlowContract.isGoogleCredentialURL(webView.url)
        statusText = isCredentialPage
            ? AppLocalized("请先登录 Google 账号，登录后会自动进入书架。")
            : AppLocalized("正在打开 Google Play 图书…")
        let target = isCredentialPage
            ? GoogleBooksWebScripts.signInURL
            : GoogleBooksWebScripts.homeURL
        guard let navigation = requestLoader(webView, URLRequest(url: target)) else {
            bindingPhase = .needsSignIn
            errorText = AppLocalized("内容暂时无法打开，请重试")
            return
        }
        bindingPhase = isCredentialPage ? .signingIn : .needsSignIn
        activeSignInNavigation = isCredentialPage ? navigation : nil
        didEnterCredentialFlow = isCredentialPage
    }

    func stop() {
        signInRequestGeneration &+= 1
        signInLaunchTask?.cancel()
        signInLaunchTask = nil
        isStartingSignIn = false
        activeSignInNavigation = nil
        didEnterCredentialFlow = false
        cancelFlowTasks()
        popupWebView?.stopLoading()
        popupWebView = nil
    }

    private func cancelFlowTasks() {
        loginPollingTask?.cancel()
        loginPollingTask = nil
        previewTask?.cancel()
        previewTask = nil
        shelfRecoveryTask?.cancel()
        shelfRecoveryTask = nil
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        guard webView === self.webView || webView === popupWebView else { return }
        if bindingPhase == .signingIn, webView === self.webView {
            activeSignInNavigation = navigation
        }
        synchronizeCredentialState(for: webView.url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView || webView === popupWebView else { return }
        if bindingPhase == .signingIn, webView === self.webView {
            activeSignInNavigation = navigation
        }
        synchronizeCredentialState(for: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        synchronizeCredentialState(for: webView.url)
        if webView === popupWebView,
           let url = webView.url,
           didEnterCredentialFlow,
           Self.isShelfRecoveryDestination(url) {
            popupWebView = nil
            recoverShelfAfterLogin()
            return
        }
        guard webView === self.webView else { return }
        if bindingPhase == .signingIn, popupWebView != nil {
            return
        }
        if bindingPhase == .signingIn,
           let activeSignInNavigation,
           let navigation,
           navigation !== activeSignInNavigation {
            // This is the late completion of the Play Books page that was
            // visible before the native Sign In tap.
            return
        }
        if GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
            phase: bindingPhase,
            didEnterCredentialFlow: didEnterCredentialFlow,
            isBlankDocument: Self.isBlankDocument(webView.url),
            isPlayBooksDestination:
                webView.url.map(Self.isShelfRecoveryDestination) ?? false,
            hasAccountEvidence: false,
            isShelfContext: false
        ) {
            recoverShelfAfterLogin()
            return
        }
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.handleFinishedPage() }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        if shouldIgnoreStaleSignInCallback(from: webView, navigation: navigation) {
            return
        }
        recordNavigationError()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        if shouldIgnoreStaleSignInCallback(from: webView, navigation: navigation) {
            return
        }
        recordNavigationError()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === popupWebView {
            popupWebView = nil
        }
        recordNavigationError()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame != false,
           GoogleBooksBindingFlowContract.isGoogleCredentialURL(
               navigationAction.request.url
           ) {
            enterCredentialFlow()
        }
        if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url,
              Self.allowedTopLevelURL(url) != nil else {
            reportBlockedTopLevelNavigation(navigationAction.request.url)
            // Google may finish 2FA on a short-lived hop outside our allowlist.
            // By this point its session cookies are already stored, so returning
            // to the shelf is safer than leaving the user on a dead continuation.
            if navigationAction.targetFrame?.isMainFrame == true,
               consumeBindingBlockRescue() {
                errorText = nil
                Task { [weak webView] in
                    webView?.load(URLRequest(url: GoogleBooksWebScripts.shelfURL))
                }
            } else {
                errorText = AppLocalized("内容暂时无法打开，请重试")
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Only one recovery navigation may be issued per eight-second window.
    private var lastBindingBlockRescueAt: TimeInterval = -.infinity

    func consumeBindingBlockRescue(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard now - lastBindingBlockRescueAt >= 8 else { return false }
        lastBindingBlockRescueAt = now
        return true
    }

    /// Report URL shape only. Query values can contain account data and must
    /// never enter analytics.
    private func reportBlockedTopLevelNavigation(_ url: URL?) {
        ProductAnalytics.shared.track(
            .contentFailed,
            context: AnalyticsEventContext(
                productArea: .reader,
                surface: "google_books_binding",
                entryPoint: analyticsSession.entryPoint
            ),
            properties: AnalyticsProperties(
                contentSource: AnalyticsContentSource.googleBooks.rawValue,
                contentFormat: AnalyticsContentFormat.googleBooks.rawValue,
                result: AnalyticsResult.blocked.rawValue,
                errorStage: "blocked_main_navigation",
                errorCode: Self.blockedNavigationShape(url)
            )
        )
    }

    static func blockedNavigationShape(_ url: URL?) -> String {
        guard let url,
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ) else {
            return "unparseable"
        }
        let names = (components.queryItems ?? [])
            .map(\.name)
            .sorted()
            .joined(separator: ",")
            .prefix(120)
        return "\(components.host ?? "")\(components.path)?[\(names)]"
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url,
              Self.allowedTopLevelURL(url) != nil else { return nil }
        if GoogleBooksBindingFlowContract.isGoogleCredentialURL(url) {
            enterCredentialFlow()
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = GoogleBooksWebScripts.mobileSafariUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self
#if DEBUG
        popup.isInspectable = true
#endif
        popupWebView = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        popupWebView = nil
        if bindingPhase == .signingIn, didEnterCredentialFlow {
            recoverShelfAfterLogin()
        } else {
            self.webView.load(URLRequest(url: GoogleBooksWebScripts.homeURL))
        }
    }

    func syncLibrary() async -> Bool {
        guard let accountBoundaryToken,
              AccountContentIsolation.isCurrent(accountBoundaryToken) else {
            return false
        }
        guard !isSyncing else { return false }
        recordConnectionStage(.syncStarted, result: .started)
        if !canSyncLibrary { await refreshPreview() }
        guard AccountContentIsolation.isCurrent(accountBoundaryToken) else {
            return false
        }
        guard canSyncLibrary else {
            recordConnectionStage(
                .failed,
                result: .failed,
                errorCode: "sync_snapshot_unavailable"
            )
            return false
        }
        isSyncing = true
        errorText = nil
        defer { isSyncing = false }
        store.mergeScrapedBooks(Array(pendingBooks.values), account: pendingAccount)
        if let commitError = store.lastError {
            errorText = commitError
            recordConnectionStage(
                .failed,
                result: .failed,
                errorCode: "local_commit_failed"
            )
            return false
        }
        let verifiedBookCount = pendingBooks.count
        guard recordConnectionStage(
            .syncCompleted,
            result: .success,
            bookCount: verifiedBookCount
        ) else {
            errorText = AppLocalized("书架已保存，但同步确认未完成，请重试。")
            return false
        }
        statusText = String(
            format: AppLocalized("已同步 %d 本 Google Play 图书。"),
            verifiedBookCount
        )
        return true
    }

    private func handleFinishedPage() async {
        let result: GoogleBooksScanResult
        do {
            result = try await evaluate(GoogleBooksWebScripts.sessionProbe)
        } catch {
            guard !Task.isCancelled else { return }
            recordNavigationError()
            return
        }
        guard !Task.isCancelled else { return }
        if !result.authRequired,
           GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
            phase: bindingPhase,
            didEnterCredentialFlow: didEnterCredentialFlow,
            isBlankDocument: Self.isBlankDocument(webView.url),
            isPlayBooksDestination:
                webView.url.map(Self.isShelfRecoveryDestination) ?? false,
            hasAccountEvidence: result.hasAccountEvidence,
            isShelfContext: result.isShelfContext
        ) {
            recoverShelfAfterLogin()
            return
        }
        if result.authRequired || !result.authenticated {
            // While Google is showing its own credential/account-picker page,
            // keep our bottom card hidden. It is not a failed login yet.
            if isCredentialFlowVisible {
                enterCredentialFlow()
                startLoginPolling()
                return
            }
            if bindingPhase == .signingIn || bindingPhase == .awaitingShelf {
                startLoginPolling()
                return
            }
            resetUnauthenticatedPreview()
            statusText = AppLocalized("请先登录 Google 账号，登录后会自动进入书架。")
            startLoginPolling()
            return
        }
        recordConnectionStage(.loginSucceeded, result: .success)
        loginPollingTask?.cancel()
        loginPollingTask = nil
        activeSignInNavigation = nil
        didEnterCredentialFlow = false
        bindingPhase = .scanning
        await refreshPreview()
    }

    private func refreshPreview() async {
        guard !isScanning else { return }
        isScanning = true
        hasStableShelfSnapshot = false
        bindingPhase = .scanning
        errorText = nil
        defer { isScanning = false }
        pendingBooks = [:]
        pendingAccount = nil
        availableCount = 0
        var all: [String: GoogleBooksBook] = [:]
        var stableAtEndPasses = 0
        var account: GoogleBooksAccountInfo?
        var reachedEnd = false
        // `sessionProbe` rewinds the actual scroll owner to the beginning.
        // Give Google's virtual list one render frame before reading cards.
        try? await Task.sleep(for: .milliseconds(250))
        for pass in 0..<24 {
            guard !Task.isCancelled else { return }
            statusText = AppLocalized("正在扫描 Google Play 图书书架…")
            let result: GoogleBooksScanResult
            do {
                result = try await evaluate(GoogleBooksWebScripts.libraryScan)
            } catch {
                guard !Task.isCancelled else { return }
                if pass >= 2 {
                    finishScanWithoutSnapshot(
                        AppLocalized("网络连接失败，请重试。")
                    )
                    return
                }
                continue
            }
            guard !Task.isCancelled else { return }
            if result.authRequired || !result.authenticated, all.isEmpty {
                resetUnauthenticatedPreview()
                statusText = AppLocalized("请先登录 Google 账号，登录后会自动进入书架。")
                startLoginPolling()
                return
            }
            if let label = result.account { account = GoogleBooksAccountInfo(label: label) }
            let before = all.count
            result.books.forEach { all[$0.id] = $0 }
            pendingBooks = all
            pendingAccount = account
            availableCount = all.count
            // `libraryScan` advances the actual document/virtual-list scroll
            // owner after observing the current viewport. Do not scroll again
            // here or a virtualized shelf can skip an entire viewport.
            reachedEnd = result.isCompleteSnapshot
            stableAtEndPasses =
                reachedEnd && all.count == before ? stableAtEndPasses + 1 : 0
            if GoogleBooksShelfSyncContract.isStableSnapshot(
                bookCount: all.count,
                reachedEnd: reachedEnd,
                stableEndPasses: stableAtEndPasses
            ) { break }
            try? await Task.sleep(for: .milliseconds(700))
        }
        guard GoogleBooksShelfSyncContract.canCommit(
            bookCount: all.count,
            account: account,
            reachedEnd: reachedEnd,
            stableEndPasses: stableAtEndPasses
        ) else {
            finishScanWithoutSnapshot(
                AppLocalized("没有找到书架书籍。请在 Google Play 图书的「我的图书」页登录后重试。")
            )
            return
        }
        hasStableShelfSnapshot = true
        bindingPhase = .ready
        statusText = String(format: AppLocalized("已找到 %d 本 Google Play 图书。"), all.count)
        await autoSyncForLiveLoginGateIfRequested()
    }

    private func startLoginPolling() {
        guard loginPollingTask == nil else { return }
        loginPollingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loginPollingTask = nil }
            for _ in 0..<180 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard let result = try? await self.evaluate(GoogleBooksWebScripts.sessionProbe),
                      !Task.isCancelled else { continue }
                if !result.authRequired,
                   GoogleBooksBindingFlowContract.shouldRecoverShelfAfterLogin(
                    phase: self.bindingPhase,
                    didEnterCredentialFlow: self.didEnterCredentialFlow,
                    isBlankDocument: Self.isBlankDocument(self.webView.url),
                    isPlayBooksDestination:
                        self.webView.url.map(Self.isShelfRecoveryDestination) ?? false,
                    hasAccountEvidence: result.hasAccountEvidence,
                    isShelfContext: result.isShelfContext
                ) {
                    self.recoverShelfAfterLogin()
                    return
                }
                guard !result.authRequired, result.authenticated else { continue }
                self.recordConnectionStage(.loginSucceeded, result: .success)
                self.statusText = AppLocalized("登录成功，正在进入书架…")
                self.bindingPhase = .scanning
                await self.refreshPreview()
                return
            }
            guard !Task.isCancelled else { return }
            if self.isCredentialFlowVisible {
                self.bindingPhase = .signingIn
            } else {
                self.bindingPhase = .needsSignIn
                self.errorText = AppLocalized("网络连接失败，请重试。")
            }
        }
    }

    private func resetUnauthenticatedPreview() {
        bindingPhase = .needsSignIn
        activeSignInNavigation = nil
        didEnterCredentialFlow = false
        availableCount = 0
        pendingBooks = [:]
        pendingAccount = nil
        hasStableShelfSnapshot = false
        errorText = nil
    }

    private func recordNavigationError() {
        recordConnectionStage(
            .failed,
            result: .failed,
            errorCode: "navigation_failed"
        )
        cancelFlowTasks()
        errorText = AppLocalized("网络连接失败，请重试。")
        if isCredentialFlowVisible {
            bindingPhase = .signingIn
        } else if !showsSyncBar {
            bindingPhase = .needsSignIn
            activeSignInNavigation = nil
            didEnterCredentialFlow = false
        }
    }

    private func finishScanWithoutSnapshot(_ message: String) {
        hasStableShelfSnapshot = false
        bindingPhase = .ready
        errorText = message
    }

    private func recoverShelfAfterLogin() {
        guard bindingPhase == .signingIn,
              didEnterCredentialFlow,
              shelfRecoveryTask == nil else {
            return
        }
        // Do not let the old credential-page poll race the redirected shelf
        // and commit its transient empty DOM.
        loginPollingTask?.cancel()
        loginPollingTask = nil
        activeSignInNavigation = nil
        hasStableShelfSnapshot = false
        bindingPhase = .awaitingShelf
        statusText = AppLocalized("登录成功，正在进入书架…")
        recordConnectionStage(.loginSucceeded, result: .success)
        shelfRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            self.shelfRecoveryTask = nil
            guard self.bindingPhase == .awaitingShelf else { return }
            self.webView.load(URLRequest(url: GoogleBooksWebScripts.shelfURL))
        }
    }

    private func autoSyncForLiveLoginGateIfRequested() async {
#if DEBUG
        guard Self.isLiveLoginGate, !liveLoginGateDidSync else { return }
        if await syncLibrary() {
            liveLoginGateDidSync = true
        }
#endif
    }

#if DEBUG
    private static var isLiveLoginGate: Bool {
        ProcessInfo.processInfo.arguments.contains("-CastReaderGoogleBooksLiveLoginGate")
    }
#endif

    private var isCredentialFlowVisible: Bool {
        GoogleBooksBindingFlowContract.isGoogleCredentialURL(webView.url)
            || GoogleBooksBindingFlowContract.isGoogleCredentialURL(
                popupWebView?.url
            )
    }

    private func enterCredentialFlow() {
        previewTask?.cancel()
        previewTask = nil
        shelfRecoveryTask?.cancel()
        shelfRecoveryTask = nil
        hasStableShelfSnapshot = false
        didEnterCredentialFlow = true
        errorText = nil
        bindingPhase = .signingIn
    }

    @discardableResult
    private func recordConnectionStage(
        _ stage: AnalyticsLibraryConnectionStage,
        result: AnalyticsResult,
        errorCode: String? = nil,
        bookCount: Int? = nil
    ) -> Bool {
        connectionAnalytics.record(
            stage,
            result: result,
            errorCode: errorCode,
            bookCount: bookCount
        )
    }

    private func synchronizeCredentialState(for url: URL?) {
        if GoogleBooksBindingFlowContract.isGoogleCredentialURL(url) {
            enterCredentialFlow()
        }
    }

    private func shouldIgnoreStaleSignInCallback(
        from webView: WKWebView,
        navigation: WKNavigation?
    ) -> Bool {
        guard webView === self.webView,
              bindingPhase == .signingIn,
              let activeSignInNavigation,
              let navigation else {
            return false
        }
        return navigation !== activeSignInNavigation
    }

    private static func currentPageSignInURL(in webView: WKWebView) async -> URL? {
        let value: Any?
        do {
            value = try await webView.evaluateJavaScript(
                GoogleBooksWebScripts.currentPageSignInURL
            )
        } catch {
            return nil
        }
        guard let raw = value as? String,
              let url = URL(string: raw),
              allowedTopLevelURL(url) != nil,
              GoogleBooksBindingFlowContract.isGoogleCredentialURL(url) else {
            return nil
        }
        return url
    }

    private static func allowedTopLevelURL(_ url: URL) -> URL? {
        if url.absoluteString == "about:blank" { return url }
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased() else { return nil }
        let allowed =
            host == "google.com"
                || host.hasSuffix(".google.com")
                || host == "googleusercontent.com"
                || host.hasSuffix(".googleusercontent.com")
        return allowed ? url : nil
    }

    private static func isPlayBooksDestination(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "play.google.com" else { return false }
        return url.path.hasPrefix("/books")
    }

    /// Google commonly finishes a password/passkey challenge on CheckCookie
    /// before following the `continue` URL. In WKWebView that final redirect
    /// can stall on a visually blank document, so treat the trusted
    /// Play-Books continuation itself as success evidence and reload the shelf
    /// from the shared authenticated data store.
    static func isShelfRecoveryDestination(_ url: URL) -> Bool {
        if isPlayBooksDestination(url) { return true }
        if isGoogleLandingDestination(url) { return true }
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "accounts.google.com",
              url.path.lowercased() == "/checkcookie",
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ),
              let rawContinue = components.queryItems?
                .first(where: { $0.name == "continue" })?.value,
              let continueURL = URL(string: rawContinue) else {
            return false
        }
        return isPlayBooksDestination(continueURL)
            || isGoogleLandingDestination(continueURL)
    }

    /// Google can route the post-2FA continuation through this landing page
    /// before returning to Play Books. Treat it as authenticated shelf evidence.
    private static func isGoogleLandingDestination(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "gds.google.com" else { return false }
        return url.path.lowercased().hasPrefix("/web/landing")
    }

    private static func isBlankDocument(_ url: URL?) -> Bool {
        url?.absoluteString.lowercased() == "about:blank"
    }

    private func evaluate(_ js: String) async throws -> GoogleBooksScanResult {
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as Any) }
            }
        }
        guard let raw = value as? [String: Any] else {
            throw NSError(domain: "GoogleBooks", code: 1)
        }
        return GoogleBooksScanResult(raw)
    }
}
