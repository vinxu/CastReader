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
                .accessibilityElement(children: .contain)
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
    @State private var keyboardIsVisible = false

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
            VStack(spacing: 0) {
                GoogleBooksWebViewContainer(webView: model.activeWebView)
                    .id(ObjectIdentifier(model.activeWebView))
                    .accessibilityIdentifier(model.popupWebView == nil
                        ? "googleBooksBindingWebView" : "googleBooksLoginPopupWebView")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                // Recovery remains reachable even on a failed credential
                // page; the footer reserves space instead of covering fields.
                if let error = model.errorText {
                    inlineError(error).padding(12)
                        .background(.regularMaterial)
                } else if !keyboardIsVisible, model.popupWebView == nil {
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.popupWebView != nil {
                        Button { model.closePopup() } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(AppLocalized("关闭"))
                        .accessibilityIdentifier("googleBooksClosePopupButton")
                    }
                    Button { model.goBack() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel(AppLocalized("返回"))
                    .accessibilityIdentifier("googleBooksBackButton")
                    Button { model.reloadActivePage() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(AppLocalized("重新加载"))
                    .accessibilityIdentifier("googleBooksReloadButton")
                }
            }
            .onAppear {
                model.recordConnectionPresented()
                model.loadIfNeeded()
            }
            .onDisappear { model.closeConnection() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardIsVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardIsVisible = false
            }
            .onChange(of: model.liveLoginGateDidSync) { _, didSync in
                if didSync { dismiss() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var loginGuideBar: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalized("请登录你的 Google 账号"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
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
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .disabled(model.isStartingSignIn)
            .accessibilityIdentifier("googleBooksSignInButton")
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
                .accessibilityIdentifier("googleBooksBindingError")
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
        .reservesMiniPlayerSpace()
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("Google Play 图书书架"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: AppLocalized("搜索 Google Play 图书"))
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
            LibraryListeningProgressLabel(bookID: book.id, providerProgress: book.displayProgress)
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
                    LibraryListeningProgressLabel(bookID: book.id, providerProgress: book.displayProgress)
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
    @Published private(set) var canGoBack = false
    @Published private(set) var isStartingSignIn = false
    @Published private(set) var liveLoginGateDidSync = false

    let webView: WKWebView
    var activeWebView: WKWebView { popupWebView ?? webView }
    private let store: GoogleBooksLibraryStore
    private let accountBoundaryToken: AccountContentBoundaryToken?
    private let storageBoundary: UUID?
    private let fixtureKind: String?
    private var didLoad = false
    private var isClosed = false
    private var popupStack: [WKWebView] = []
    private var generation = 0
    private var navigationTokens: [ObjectIdentifier: WKNavigation] = [:]
    // Retain retired objects: a bare ObjectIdentifier can be reused after its
    // WKNavigation dies, incorrectly rejecting a later real navigation.
    private var retiredNavigations: [ObjectIdentifier: WKNavigation] = [:]
    private var committedWindows: Set<ObjectIdentifier> = []
    private var completedScan: GoogleBooksShelfScanPolicy?
    private var pendingBooks: [String: GoogleBooksBook] = [:]
    private var pendingAccount: GoogleBooksAccountInfo?
    private var observationTask: Task<Void, Never>?
    private var loginPollingTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var shelfRecoveryTask: Task<Void, Never>?
    private var signInLaunchTask: Task<Void, Never>?
    private var didEnterCredentialFlow = false
    private var backObservation: NSKeyValueObservation?
    private let requestLoader: (WKWebView, URLRequest) -> WKNavigation?
    private let signInURLResolver: (WKWebView) async -> URL?
    private let analyticsSession: AnalyticsLibraryConnectionSession
    private let connectionAnalytics: AnalyticsLibraryConnectionRecorder
    private var lastBindingBlockRescueAt: TimeInterval = -.infinity

    var showsSyncBar: Bool { GoogleBooksBindingFlowContract.showsSyncBar(for: bindingPhase) }
    var showsLoginGuide: Bool { GoogleBooksBindingFlowContract.showsLoginGuide(for: bindingPhase) }
    var showsSyncAction: Bool { GoogleBooksBindingFlowContract.showsSyncAction(for: bindingPhase) }
    var secondaryStatus: String {
        if availableCount > 0 { return String(format: AppLocalized("书架中有 %d 本书可以同步"), availableCount) }
        if completedScan?.completeTraversal == true { return AppLocalized("书架为空") }
        if store.books.isEmpty { return AppLocalized("登录成功后将自动进入书架。") }
        return String(format: AppLocalized("已在本机同步 %d 本书。"), store.books.count)
    }
    var canSyncLibrary: Bool {
        accountBoundaryToken != nil && storageBoundary != nil
            && completedScan?.completeTraversal == true && popupWebView == nil
            && committedWindows.contains(ObjectIdentifier(webView)) && isCurrent(generation)
    }

    override convenience init() {
        self.init(requestLoader: { $0.load($1) }, signInURLResolver: { await Self.currentPageSignInURL(in: $0) })
    }
    convenience init(analyticsSession: AnalyticsLibraryConnectionSession, entryTapAlreadyTracked: Bool) {
        self.init(requestLoader: { $0.load($1) }, signInURLResolver: { await Self.currentPageSignInURL(in: $0) },
                  analyticsSession: analyticsSession, entryTapAlreadyTracked: entryTapAlreadyTracked)
    }
    init(
        requestLoader: @escaping (WKWebView, URLRequest) -> WKNavigation?,
        signInURLResolver: @escaping (WKWebView) async -> URL?,
        analyticsSession: AnalyticsLibraryConnectionSession = AnalyticsLibraryConnectionSession(source: .googleBooks, entryPoint: "google_books_connect"),
        entryTapAlreadyTracked: Bool = false
    ) {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        fixtureKind = args.contains("-CastReaderGoogleBooksLoginFixture") ? "login"
            : args.contains("-CastReaderGoogleBooksBlankFixture") ? "blank"
            : args.contains("-CastReaderGoogleBooksPopupFixture") ? "popup"
            : args.contains("-CastReaderGoogleBooksHundredShelfFixture") ? "hundred" : nil
#else
        fixtureKind = nil
#endif
        if let fixtureKind, fixtureKind != "hundred" {
            store = GoogleBooksLibraryStore(defaults: UserDefaults(suiteName: "googlebooks.binding.fixture.\(UUID().uuidString)")!, historyStore: .shared)
        } else {
            store = .shared
        }
        storageBoundary = store.captureStorageBoundary()
        accountBoundaryToken = AccountContentIsolation.captureBoundaryToken()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = fixtureKind == nil ? GoogleWebSession.websiteDataStore : .nonPersistent()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
#if DEBUG
        if fixtureKind == "popup" { config.preferences.javaScriptCanOpenWindowsAutomatically = true }
#endif
        webView = WKWebView(frame: .zero, configuration: config)
        self.requestLoader = requestLoader
        self.signInURLResolver = signInURLResolver
        self.analyticsSession = analyticsSession
        connectionAnalytics = AnalyticsLibraryConnectionRecorder(session: analyticsSession, entryTapAlreadyTracked: entryTapAlreadyTracked)
        super.init()
        configure(webView)
        observeActiveWindow()
    }

    private func configure(_ view: WKWebView) {
        view.customUserAgent = GoogleBooksWebScripts.mobileSafariUserAgent
        view.navigationDelegate = self
        view.uiDelegate = self
#if DEBUG
        view.isInspectable = true
#endif
    }
    private func isCurrent(_ revision: Int) -> Bool {
        guard !isClosed, revision == generation else { return false }
        if let token = accountBoundaryToken, !AccountContentIsolation.isCurrent(token) { return false }
        if let storageBoundary, !store.isCurrentStorageBoundary(storageBoundary) { return false }
        return true
    }
    private func isActive(_ view: WKWebView) -> Bool { !isClosed && view === activeWebView }
    private func isOwned(_ view: WKWebView) -> Bool {
        !isClosed && (view === webView || popupStack.contains { $0 === view })
    }
    private func isCurrentCallback(_ view: WKWebView, _ navigation: WKNavigation?) -> Bool {
        guard isOwned(view) else { return false }
        guard let navigation else { return true }
        guard retiredNavigations[ObjectIdentifier(navigation)] == nil else { return false }
        return navigationTokens[ObjectIdentifier(view)].map { $0 === navigation } ?? true
    }
    private func observeActiveWindow() {
        backObservation = activeWebView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.canGoBack = self?.activeWebView.canGoBack ?? false }
        }
    }
    private func cancelFlowTasks() {
        observationTask?.cancel(); observationTask = nil
        loginPollingTask?.cancel(); loginPollingTask = nil
        previewTask?.cancel(); previewTask = nil
        shelfRecoveryTask?.cancel(); shelfRecoveryTask = nil
        isScanning = false
    }
    private func invalidateSnapshot() {
        generation &+= 1
        cancelFlowTasks()
        completedScan = nil
        pendingBooks = [:]; pendingAccount = nil; availableCount = 0
        errorText = nil
    }
    private func track(_ navigation: WKNavigation?, in view: WKWebView) {
        let id = ObjectIdentifier(view)
        if let old = navigationTokens[id], old !== navigation { retiredNavigations[ObjectIdentifier(old)] = old }
        navigationTokens[id] = navigation
        committedWindows.remove(id)
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
#if DEBUG
        if let fixtureKind {
            let html = fixtureKind == "login" ? GoogleBooksDebugFixtures.login
                : fixtureKind == "blank" ? GoogleBooksDebugFixtures.blank
                : fixtureKind == "popup" ? GoogleBooksDebugFixtures.popup
                : GoogleBooksWebScripts.debugHundredBookShelfFixture
            let base = fixtureKind == "login" ? GoogleBooksWebScripts.signInURL : GoogleBooksWebScripts.shelfURL
            track(webView.loadHTMLString(html, baseURL: base), in: webView)
            return
        }
        if Self.isLiveLoginGate { openSignIn(); return }
#endif
        track(requestLoader(webView, URLRequest(url: GoogleBooksWebScripts.homeURL)), in: webView)
    }
    func recordConnectionPresented() { if fixtureKind == nil { connectionAnalytics.presented() } }
    func closeConnection() { if fixtureKind == nil { connectionAnalytics.close() }; stop() }
    func stop() {
        isClosed = true
        invalidateSnapshot()
        signInLaunchTask?.cancel(); signInLaunchTask = nil
        isStartingSignIn = false
        activeWebView.stopLoading()
        popupStack.forEach { $0.stopLoading() }
        popupStack = []; popupWebView = nil
        navigationTokens = [:]; retiredNavigations = [:]; committedWindows = []
        backObservation = nil
    }

    func openSignIn() {
        guard !isClosed, bindingPhase == .needsSignIn, !isStartingSignIn else { return }
#if DEBUG
        if fixtureKind == "popup" {
            webView.evaluateJavaScript("window.openGoogleBooksFixtureLogin()", completionHandler: nil)
            return
        }
#endif
        recordConnectionStage(.loginStarted, result: .started)
        invalidateSnapshot()
        webView.stopLoading()
        store.clearError()
        statusText = AppLocalized("请先登录 Google 账号，登录后会自动进入书架。")
        isStartingSignIn = true
        let revision = generation
        signInLaunchTask = Task { [weak self] in
            guard let self else { return }
            let dynamicURL = await self.signInURLResolver(self.webView)
            guard !Task.isCancelled, self.isCurrent(revision) else { return }
            let target = dynamicURL ?? GoogleBooksWebScripts.signInURL
            guard Self.allowedTopLevelURL(target) != nil,
                  let navigation = self.requestLoader(self.webView, URLRequest(url: target)) else {
                self.isStartingSignIn = false; self.signInLaunchTask = nil
                self.bindingPhase = .needsSignIn
                self.errorText = AppLocalized("内容暂时无法打开，请重试")
                return
            }
            self.track(navigation, in: self.webView)
            self.bindingPhase = .signingIn
            self.didEnterCredentialFlow = false
            self.isStartingSignIn = false; self.signInLaunchTask = nil
        }
    }
    func retry() { reloadActivePage() }
    func reloadActivePage() {
        guard !isClosed else { return }
        invalidateSnapshot()
        signInLaunchTask?.cancel(); signInLaunchTask = nil; isStartingSignIn = false
#if DEBUG
        if fixtureKind != nil, popupWebView == nil { didLoad = false; loadIfNeeded(); return }
#endif
        let view = activeWebView
        if let url = view.url, Self.allowedTopLevelURL(url) != nil, url.absoluteString != "about:blank" {
            track(view.reload(), in: view)
        } else if popupWebView != nil {
            closePopup()
        } else {
            track(requestLoader(webView, URLRequest(url: GoogleBooksWebScripts.homeURL)), in: webView)
        }
    }
    func goBack() {
        guard activeWebView.canGoBack else { return }
        invalidateSnapshot()
        track(activeWebView.goBack(), in: activeWebView)
    }
    func closePopup() {
        guard let popup = popupStack.popLast() else { return }
        popup.stopLoading()
        navigationTokens.removeValue(forKey: ObjectIdentifier(popup))
        committedWindows.remove(ObjectIdentifier(popup))
        popupWebView = popupStack.last
        invalidateSnapshot()
        // Closing a credential window is cancellation, not authorization.
        // The opener's own DOM can still prove a completed login, but a
        // cancelled popup must not trigger a fresh shelf navigation.
        didEnterCredentialFlow = false
        observeActiveWindow()
        bindingPhase = GoogleBooksBindingFlowContract.isGoogleCredentialURL(activeWebView.url) ? .signingIn : .needsSignIn
        startDocumentObservation()
    }

    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isOwned(view), navigation.map({ retiredNavigations[ObjectIdentifier($0)] == nil }) ?? true else { return }
        if !isActive(view) { track(navigation, in: view); return }
        invalidateSnapshot()
        track(navigation, in: view)
        if GoogleBooksBindingFlowContract.isGoogleCredentialURL(view.url) { enterCredentialFlow() }
        else if bindingPhase != .signingIn { bindingPhase = .awaitingShelf }
        startDocumentObservation()
    }
    func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
        guard isCurrentCallback(view, navigation) else { return }
        committedWindows.insert(ObjectIdentifier(view))
        guard isActive(view) else { return }
        if GoogleBooksBindingFlowContract.isGoogleCredentialURL(view.url) { enterCredentialFlow() }
        startDocumentObservation()
    }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrentCallback(view, navigation) else { return }
        committedWindows.insert(ObjectIdentifier(view))
        guard isActive(view) else { return }
        startDocumentObservation()
    }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled, isActive(view), isCurrentCallback(view, navigation) { recordNavigationError() }
    }
    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled, isActive(view), isCurrentCallback(view, navigation) { recordNavigationError() }
    }
    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        if isActive(view) { recordNavigationError() }
    }

    /// Watch the active committed document, independently of ad/image loading.
    /// Never probe a covered opener or let a prior navigation change this one.
    private func startDocumentObservation() {
        guard observationTask == nil, !isScanning, completedScan == nil, !isClosed else { return }
        let revision = generation
        let surface = activeWebView
        observationTask = Task { [weak self, weak surface] in
            guard let self, let surface else { return }
            defer { if revision == self.generation { self.observationTask = nil } }
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled, self.isCurrent(revision), self.isActive(surface) {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if self.committedWindows.contains(ObjectIdentifier(surface)),
                   let result = try? await self.evaluate(GoogleBooksWebScripts.sessionProbe, in: surface) {
                    guard !Task.isCancelled, self.isCurrent(revision), self.isActive(surface) else { return }
                    if result.hasCredentialForm {
                        self.enterCredentialFlow(); self.startLoginPolling(); return
                    }
                    if result.authenticated, result.isDocumentReady, result.hasShelfSurface {
                        if surface !== self.webView { self.finishPopupAuthorization(); return }
                        self.recordConnectionStage(.loginSucceeded, result: .success)
                        self.previewTask = Task { [weak self] in await self?.refreshPreview() }
                        return
                    }
                    if result.authenticated {
                        self.bindingPhase = .awaitingShelf
                        self.statusText = AppLocalized("正在检测书架中的书籍，请稍候。")
                        self.startLoginPolling(); return
                    }
                    if self.didEnterCredentialFlow,
                       surface.url.map(Self.isShelfRecoveryDestination) == true {
                        self.recoverShelfAfterLogin(); return
                    }
                    let content = try? await surface.evaluateJavaScript("!!(document.body && (document.body.innerText.trim().length > 0 || document.querySelector('form,input,button,iframe'))) ") as? Bool
                    guard !Task.isCancelled, self.isCurrent(revision) else { return }
                    if content == true {
                        self.bindingPhase = GoogleBooksBindingFlowContract.isGoogleCredentialURL(surface.url) ? .signingIn : .needsSignIn
                        self.startLoginPolling(); return
                    }
                    if elapsed >= 4, !surface.isLoading { self.recordNavigationError(); return }
                }
                if elapsed >= 25 { self.recordNavigationError(); return }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
    private func startLoginPolling() {
        guard loginPollingTask == nil, !isClosed, !isScanning, completedScan == nil else { return }
        let revision = generation
        let surface = activeWebView
        loginPollingTask = Task { [weak self, weak surface] in
            guard let self, let surface else { return }
            defer { if revision == self.generation { self.loginPollingTask = nil } }
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.isCurrent(revision), self.isActive(surface) else { return }
                // A didFinish observer may have started traversal while this
                // earlier login task slept. Its probe rewinds the shelf, so it
                // must relinquish ownership before scanning begins.
                guard !self.isScanning, self.completedScan == nil else { return }
                guard let result = try? await self.evaluate(GoogleBooksWebScripts.sessionProbe, in: surface) else { continue }
                guard !Task.isCancelled, self.isCurrent(revision), self.isActive(surface) else { return }
                guard !self.isScanning, self.completedScan == nil else { return }
                if result.hasCredentialForm { self.enterCredentialFlow(); continue }
                if result.authenticated, result.isDocumentReady, result.hasShelfSurface {
                    if surface !== self.webView { self.finishPopupAuthorization(); return }
                    self.recordConnectionStage(.loginSucceeded, result: .success)
                    await self.refreshPreview(); return
                }
                if self.didEnterCredentialFlow, surface.url.map(Self.isShelfRecoveryDestination) == true {
                    self.recoverShelfAfterLogin(); return
                }
            }
            if self.isCurrent(revision) { self.recordNavigationError() }
        }
    }

    private func refreshPreview() async {
        guard !isScanning, popupWebView == nil,
              committedWindows.contains(ObjectIdentifier(webView)) else { return }
        let revision = generation
        isScanning = true; completedScan = nil; bindingPhase = .scanning; errorText = nil
        statusText = AppLocalized("正在扫描 Google Play 图书书架…")
        defer { if revision == generation { isScanning = false } }
        var scan = GoogleBooksShelfScanPolicy(startedAt: ProcessInfo.processInfo.systemUptime)
        // Rewind only when starting a complete traversal. Probes never consume
        // the first viewport; wait for the virtual list to render that position.
        guard let initial = try? await evaluate(GoogleBooksWebScripts.sessionProbe),
              !Task.isCancelled, isCurrent(revision), initial.authenticated else {
            if isCurrent(revision) { finishScanWithoutSnapshot(AppLocalized("网络连接失败，请重试。")) }
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        while !Task.isCancelled, isCurrent(revision) {
            let result: GoogleBooksScanResult
            do { result = try await evaluate(GoogleBooksWebScripts.libraryScan) }
            catch {
                if !Task.isCancelled, isCurrent(revision) { finishScanWithoutSnapshot(AppLocalized("网络连接失败，请重试。")) }
                return
            }
            guard !Task.isCancelled, isCurrent(revision) else { return }
            let decision = scan.observe(result, now: ProcessInfo.processInfo.systemUptime)
            pendingBooks = scan.books; availableCount = scan.books.count
            statusText = availableCount > 0
                ? String(format: AppLocalized("正在扫描 Google Play 图书书架…（%d）"), availableCount)
                : AppLocalized("正在检测书架中的书籍，请稍候。")
            switch decision {
            case .wait: break
            case .complete:
                completedScan = scan; pendingAccount = scan.account; bindingPhase = .ready
                statusText = String(format: AppLocalized("已找到 %d 本 Google Play 图书。"), availableCount)
                isScanning = false
                await autoSyncForLiveLoginGateIfRequested()
                return
            case .failed(let reason):
                ReaderRunLog.write("GBOOKS shelf scan failed reason=\(reason)")
                finishScanWithoutSnapshot(reason == "active_shelf_filter"
                    ? AppLocalized("请清除书架的搜索或进度筛选后重试。")
                    : AppLocalized("书架尚未完整加载，请重试。"))
                return
            }
            await waitForShelfUpdate()
        }
    }

    /// Wake when the shelf renders its next window. The timeout only provides
    /// a fallback; completion is still decided from traversal and DOM evidence.
    private func waitForShelfUpdate() async {
        _ = try? await webView.callAsyncJavaScript(#"""
            return await new Promise(function (resolve) {
              var root = document.querySelector('gpb-shelf-page,main,[role="main"],[role="list"],[role="grid"]') || document.body;
              if (!root) { resolve(false); return; }
              var settled = null;
              var observer = new MutationObserver(function () {
                if (settled) clearTimeout(settled);
                settled = setTimeout(finish, 100);
              });
              var deadline = setTimeout(finish, 700);
              function finish() {
                observer.disconnect();
                clearTimeout(deadline);
                if (settled) clearTimeout(settled);
                resolve(true);
              }
              observer.observe(root, { childList: true, subtree: true, characterData: true,
                attributes: true, attributeFilter: ['aria-busy', 'data-loading', 'href', 'src'] });
            });
            """#, arguments: [:], in: nil, contentWorld: .page)
    }
    func syncLibrary() async -> Bool {
        guard !isSyncing, let accountBoundaryToken,
              AccountContentIsolation.isCurrent(accountBoundaryToken),
              let storageBoundary, store.isCurrentStorageBoundary(storageBoundary),
              canSyncLibrary, let scan = completedScan else { return false }
        let revision = generation
        isSyncing = true; errorText = nil
        defer { isSyncing = false }
        recordConnectionStage(.syncStarted, result: .started)
        guard let latest = try? await evaluate(GoogleBooksWebScripts.sessionProbe),
              !Task.isCancelled, isCurrent(revision), popupWebView == nil,
              scan.matchesCurrentAccount(latest) else {
            if isCurrent(revision) { finishScanWithoutSnapshot(AppLocalized("书架信息已变化，请重新同步。")) }
            return false
        }
        guard store.mergeScrapedBooks(scan.collectedBooks, account: scan.account, expectedStorageBoundary: storageBoundary) else {
            errorText = store.lastError ?? AppLocalized("网络连接失败，请重试。")
            return false
        }
        // The successful commit may rotate the provider storage boundary.
        // It is already durable; analytics cannot turn it into a fake failure.
        recordConnectionStage(.syncCompleted, result: .success, bookCount: scan.books.count)
        statusText = String(format: AppLocalized("已同步 %d 本 Google Play 图书。"), scan.books.count)
        return true
    }
    private func finishScanWithoutSnapshot(_ message: String) {
        completedScan = nil; pendingAccount = nil
        bindingPhase = .ready; errorText = message
    }
    private func recordNavigationError() {
        invalidateSnapshot()
        errorText = AppLocalized("网络连接失败，请重试。")
        recordConnectionStage(.failed, result: .failed, errorCode: "navigation_failed")
    }
    private func enterCredentialFlow() {
        completedScan = nil
        didEnterCredentialFlow = true
        bindingPhase = .signingIn
    }
    private func finishPopupAuthorization() {
        popupStack.forEach { $0.stopLoading() }
        popupStack = []; popupWebView = nil
        observeActiveWindow()
        recoverShelfAfterLogin()
    }
    private func recoverShelfAfterLogin() {
        guard !isClosed, shelfRecoveryTask == nil else { return }
        invalidateSnapshot()
        // Consume this return once. The shelf may need time to hydrate after
        // the redirect; its own URL must not trigger another reload loop.
        didEnterCredentialFlow = false
        bindingPhase = .awaitingShelf
        statusText = AppLocalized("登录成功，正在进入书架…")
        let revision = generation
        shelfRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, self.isCurrent(revision) else { return }
            self.shelfRecoveryTask = nil
            self.track(self.requestLoader(self.webView, URLRequest(url: GoogleBooksWebScripts.shelfURL)), in: self.webView)
        }
    }
    private func autoSyncForLiveLoginGateIfRequested() async {
#if DEBUG
        if Self.isLiveLoginGate, !liveLoginGateDidSync, await syncLibrary() { liveLoginGateDidSync = true }
#endif
    }
#if DEBUG
    private static var isLiveLoginGate: Bool { ProcessInfo.processInfo.arguments.contains("-CastReaderGoogleBooksLiveLoginGate") }
#endif
    @discardableResult
    private func recordConnectionStage(_ stage: AnalyticsLibraryConnectionStage, result: AnalyticsResult, errorCode: String? = nil, bookCount: Int? = nil) -> Bool {
        if fixtureKind != nil { return true }
        return connectionAnalytics.record(stage, result: result, errorCode: errorCode, bookCount: bookCount)
    }

    func webView(_ view: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        guard isOwned(view), let url = navigationAction.request.url, Self.allowedTopLevelURL(url) != nil else {
            if isActive(view) {
                reportBlockedTopLevelNavigation(navigationAction.request.url)
                if didEnterCredentialFlow, navigationAction.targetFrame?.isMainFrame == true, consumeBindingBlockRescue() {
                    finishPopupAuthorization()
                } else { recordNavigationError() }
            }
            decisionHandler(.cancel); return
        }
        if isActive(view), GoogleBooksBindingFlowContract.isGoogleCredentialURL(url) { enterCredentialFlow() }
        decisionHandler(.allow)
    }
    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard isActive(view), navigationAction.targetFrame == nil,
              let url = navigationAction.request.url, Self.allowedTopLevelURL(url) != nil else { return nil }
        invalidateSnapshot()
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        popupStack.append(popup); popupWebView = popup
        observeActiveWindow()
        // about:blank can be the first document of a real popup form. Keep
        // the opener alive and wait for its content instead of dismissing it.
        if GoogleBooksBindingFlowContract.isGoogleCredentialURL(url) { enterCredentialFlow() }
        startDocumentObservation()
        return popup
    }
    func webViewDidClose(_ view: WKWebView) { if view === popupWebView { closePopup() } }
    func consumeBindingBlockRescue(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard now - lastBindingBlockRescueAt >= 8 else { return false }
        lastBindingBlockRescueAt = now; return true
    }
    private func reportBlockedTopLevelNavigation(_ url: URL?) {
        ProductAnalytics.shared.track(.contentFailed,
            context: AnalyticsEventContext(productArea: .reader, surface: "google_books_binding", entryPoint: analyticsSession.entryPoint),
            properties: AnalyticsProperties(contentSource: AnalyticsContentSource.googleBooks.rawValue,
                contentFormat: AnalyticsContentFormat.googleBooks.rawValue, result: AnalyticsResult.blocked.rawValue,
                errorStage: "blocked_main_navigation", errorCode: Self.blockedNavigationShape(url)))
    }
    static func blockedNavigationShape(_ url: URL?) -> String {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "unparseable" }
        let names = (c.queryItems ?? []).map(\.name).sorted().joined(separator: ",").prefix(120)
        return "\(c.host ?? "")\(c.path)?[\(names)]"
    }
    private static func currentPageSignInURL(in view: WKWebView) async -> URL? {
        guard let raw = try? await view.evaluateJavaScript(GoogleBooksWebScripts.currentPageSignInURL) as? String,
              let url = URL(string: raw), allowedTopLevelURL(url) != nil,
              GoogleBooksBindingFlowContract.isGoogleCredentialURL(url) else { return nil }
        return url
    }
    private static func allowedTopLevelURL(_ url: URL) -> URL? {
        if url.absoluteString == "about:blank" { return url }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return nil }
        return host == "google.com" || host.hasSuffix(".google.com")
            || host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com") ? url : nil
    }
    private static func isPlayBooksDestination(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "play.google.com" && url.path.hasPrefix("/books")
    }
    static func isShelfRecoveryDestination(_ url: URL) -> Bool {
        if isPlayBooksDestination(url) || isGoogleLandingDestination(url) { return true }
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "accounts.google.com",
              url.path.lowercased() == "/checkcookie",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = c.queryItems?.first(where: { $0.name == "continue" })?.value,
              let target = URL(string: raw) else { return false }
        return isPlayBooksDestination(target) || isGoogleLandingDestination(target)
    }
    private static func isGoogleLandingDestination(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "gds.google.com" && url.path.lowercased().hasPrefix("/web/landing")
    }
    private func evaluate(_ js: String, in surface: WKWebView? = nil) async throws -> GoogleBooksScanResult {
        guard let raw = try await (surface ?? webView).evaluateJavaScript(js) as? [String: Any] else {
            throw NSError(domain: "GoogleBooks", code: 1)
        }
        return GoogleBooksScanResult(raw)
    }
}
