//
//  KoboLibraryViews.swift
//  CastReader
//
//  Kobo home shelf, binding flow and complete library. Presentation mirrors
//  Google Play Books; platform-specific work stays in KoboWebScripts/store.
//

import SwiftUI
import WebKit

extension Notification.Name {
    static let castReaderKoboRebindRequested =
        Notification.Name("castreader.kobo.rebindRequested")
}

// MARK: - Open

enum KoboReaderLauncher {
    @MainActor
    static func open(
        _ book: KoboBook,
        using coordinator: PlayerCoordinator,
        onboarding: BoundLibraryOnboardingStore,
        autoplay: Bool = false
    ) {
        let store = KoboLibraryStore.shared
        store.markOpened(book)
        let latest = store.book(for: book.id) ?? book
        let document = ReadingDocument(
            id: latest.id,
            title: latest.title,
            sourceKind: .kobo,
            language: Constants.TTS.defaultLanguage,
            paragraphs: [],
            sourceURL: latest.effectiveReaderURL,
            coverURL: latest.coverURL
        )
        let context = ProductAnalytics.shared.beginContentIntent(
            source: .kobo,
            format: .kobo,
            entryPoint:
                onboarding.analyticsEntryPoint(for: .kobo)
                    ?? "kobo_library",
            intendedMode: "read"
        )
        coordinator.open(
            document,
            mode: .read,
            autoplay: autoplay,
            analyticsContext: context
        )
    }
}

// MARK: - Home

struct KoboHomeSection: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = KoboLibraryStore.shared
    @ObservedObject private var onboarding = BoundLibraryOnboardingStore.shared

    var body: some View {
        Group {
            if !store.needsConnection && !store.homeBooks.isEmpty {
                VStack(alignment: .leading, spacing: HomeLayout.headerToContent) {
                    HStack {
                        VStack(alignment: .leading, spacing: HomeLayout.titleToSubtitle) {
                            Text("Kobo")
                                .font(.headline)
                                .foregroundColor(AppTheme.foreground)
                            Text(AppLocalized("已同步的 Kobo 书架"))
                                .font(.caption)
                                .foregroundColor(AppTheme.mutedForeground)
                        }
                        Spacer()
                        NavigationLink(destination: KoboLibraryView()) {
                            Text(AppLocalized("查看全部"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(AppTheme.primary)
                        }
                        .accessibilityIdentifier("homeShelfViewAll.kobo")
                    }

                    HomeHorizontalRail(alignment: .top) {
                        ForEach(store.homeBooks) { book in
                            Button { open(book) } label: {
                                KoboRailCard(book: book)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(
                                "homeShelfBook.kobo.\(book.bookUUID)"
                            )
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("homeShelfSection.kobo")
            }
        }
    }

    private var sourceIcon: some View {
        Image(systemName: "book.closed.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(AppTheme.primary)
            .frame(width: 48, height: 48)
            .background(AppTheme.primary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func open(_ book: KoboBook) {
        KoboReaderLauncher.open(
            book,
            using: coordinator,
            onboarding: onboarding
        )
    }
}

private struct KoboRailCard: View {
    let book: KoboBook

    var body: some View {
        VStack(alignment: .leading, spacing: HomeLayout.mediaToTextGap) {
            KoboCoverView(book: book)
                .frame(width: 92, height: 132)
            Text(book.title)
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.foreground)
                .lineLimit(2)
                .frame(width: 92, height: 34, alignment: .topLeading)
        }
    }
}

// MARK: - Library

struct KoboLibraryView: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = KoboLibraryStore.shared
    @ObservedObject private var onboarding = BoundLibraryOnboardingStore.shared
    @State private var query = ""
    @State private var sort: KoboLibrarySort = .recent
    @State private var showConnect = false

    var body: some View {
        List {
            if let label = store.accountLabel {
                Section {
                    Label(label, systemImage: "person.crop.circle")
                        .foregroundColor(AppTheme.mutedForeground)
                }
            }
            Section {
                ForEach(store.sortedBooks(sort: sort, query: query)) { book in
                    Button { open(book) } label: {
                        HStack(spacing: 14) {
                            KoboCoverView(book: book)
                                .frame(width: 52, height: 72)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(AppTheme.foreground)
                                    .lineLimit(2)
                                Text(book.displayAuthor)
                                    .font(.caption)
                                    .foregroundColor(AppTheme.mutedForeground)
                                    .lineLimit(1)
                                if !book.progressLabel.isEmpty {
                                    Text(book.progressLabel)
                                        .font(.caption2)
                                        .foregroundColor(AppTheme.primary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(
                                    AppTheme.mutedForeground.opacity(0.6)
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("koboLibraryBook.\(book.bookUUID)")
                }
            }
        }
        .reservesMiniPlayerSpace()
        .navigationTitle("Kobo")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: AppLocalized("搜索书名或作者"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(KoboLibrarySort.allCases) { value in
                        Button(value.label) { sort = value }
                    }
                    Divider()
                    Button(AppLocalized("重新同步")) { showConnect = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showConnect) { KoboLibraryConnectView() }
    }

    private func open(_ book: KoboBook) {
        KoboReaderLauncher.open(
            book,
            using: coordinator,
            onboarding: onboarding
        )
    }
}

struct KoboCoverView: View {
    let book: KoboBook

    var body: some View {
        Group {
            if let raw = book.coverURL, let url = URL(string: raw) {
                CachedAsyncImage(url: url, contentMode: .fill) {
                    placeholder.overlay {
                        ProgressView().scaleEffect(0.75)
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppTheme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        ZStack {
            AppTheme.primary.opacity(0.11)
            Image(systemName: "book.closed.fill")
                .foregroundColor(AppTheme.primary)
        }
    }
}

// MARK: - Binding

struct KoboLibraryConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: KoboLibrarySyncViewModel

    init(
        analyticsSession: AnalyticsLibraryConnectionSession? = nil,
        entryTapAlreadyTracked: Bool = false
    ) {
        let session = analyticsSession ?? AnalyticsLibraryConnectionSession(
            source: .kobo,
            entryPoint: "kobo_connect"
        )
        _model = StateObject(
            wrappedValue: KoboLibrarySyncViewModel(
                analyticsSession: session,
                entryTapAlreadyTracked: entryTapAlreadyTracked
            )
        )
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                KoboWebViewContainer(
                    webView: model.popupWebView ?? model.webView,
                    identifier: model.popupWebView == nil
                        ? "koboBindingWebView" : "koboLoginPopupWebView"
                )
                if model.showsBottomCard {
                    bottomCard
                }
            }
            .navigationTitle(AppLocalized("绑定 Kobo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("关闭")) { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.goBack() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel(AppLocalized("返回"))
                    .accessibilityIdentifier("koboBackButton")
                    Button { model.reloadPage() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(AppLocalized("重新加载"))
                    .accessibilityIdentifier("koboReloadButton")
                    if model.popupWebView != nil {
                        Button { model.closePopup() } label: {
                            Image(systemName: "xmark.rectangle")
                        }
                        .accessibilityLabel(AppLocalized("关闭"))
                        .accessibilityIdentifier("koboClosePopupButton")
                    }
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

    @ViewBuilder
    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if model.isWorking {
                    ProgressView().tint(AppTheme.primary)
                } else {
                    Image(systemName: model.isSignedIn
                        ? "checkmark.circle.fill"
                        : "person.badge.key")
                        .foregroundColor(AppTheme.primary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.foreground)
                        .lineLimit(2)
                    Text(model.detailText)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(2)
                        .accessibilityIdentifier("koboBindingDetail")
                }
                Spacer(minLength: 0)
                if model.canSync {
                    Button(AppLocalized("同步")) { model.commitShelf() }
                        .accessibilityIdentifier("koboSyncButton")
                } else if model.bindingPhase == .awaitingLogin {
                    Button(AppLocalized("登录")) { model.openSignIn() }
                        .accessibilityIdentifier("koboSignInButton")
                } else if model.didSync {
                    Button(AppLocalized("完成")) { dismiss() }
                } else if model.bindingPhase == .failed {
                    Button(AppLocalized("重新加载")) { model.reloadPage() }
                        .accessibilityIdentifier("koboRetryButton")
                }
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.primary)

            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundColor(AppTheme.destructive)
                    .lineLimit(3)
                    .accessibilityIdentifier("koboBindingError")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("koboBindingCard")
    }
}

struct KoboWebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    let identifier: String

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        installWebView(in: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        installWebView(in: uiView)
    }

    private func installWebView(in container: UIView) {
        configureAppearance(webView)
        webView.accessibilityIdentifier = identifier
        guard webView.superview !== container else { return }
        // Keep opener WebViews alive in the model, but attach only the active
        // window. Stacked WebViews can expose the covered page to hit testing
        // and VoiceOver even when SwiftUI marks it accessibilityHidden.
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func configureAppearance(_ webView: WKWebView) {
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
    }
}

@MainActor
final class KoboLibrarySyncViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var bindingPhase: KoboBindingPhase = .opening
    @Published private(set) var statusText = AppLocalized("正在打开 Kobo…")
    @Published private(set) var detailText = AppLocalized("登录成功后将自动进入书架。")
    @Published private(set) var errorText: String?
    @Published private(set) var popupWebView: WKWebView?
    @Published private(set) var canGoBack = false

    let webView: WKWebView
    var isWorking: Bool { bindingPhase == .opening || bindingPhase == .scanning }
    var isSignedIn: Bool { bindingPhase == .scanning || bindingPhase == .ready || bindingPhase == .synced }
    var canSync: Bool { bindingPhase == .ready && completedScan?.completeTraversal == true }
    var didSync: Bool { bindingPhase == .synced }
    var showsBottomCard: Bool { bindingPhase != .authenticating }

    private var activeWebView: WKWebView { popupWebView ?? webView }
    private let store: KoboLibraryStore
    private let storageBoundary: UUID?
    private let connectionAnalytics: AnalyticsLibraryConnectionRecorder
    private let fixtureKind: String?
    private var didLoad = false
    private var isClosed = false
    private var flowGeneration = 0
    private var workTask: Task<Void, Never>?
    private var isScanningShelf = false
    private var awaitingAutomaticPageChange = false
    private var navigations: [ObjectIdentifier: WKNavigation] = [:]
    private var committedDocuments: Set<ObjectIdentifier> = []
    private var suspendedPopups: [WKWebView] = []
    private var navigationHasFailed = false
    private var pendingFailureCode: String?
    private var mainHistoryObservation: NSKeyValueObservation?
    private var popupHistoryObservation: NSKeyValueObservation?
    private var didRecoverContinuation = false
    private var latestShelfURL = KoboWebScripts.shelfURL
    private var completedScan: KoboShelfScanPolicy?
    private var completedPageKey: String?
    private var completedFingerprint: String?
    private var resolvedShelfAccount: (identity: String, label: String)?

    override convenience init() {
        self.init(analyticsSession: AnalyticsLibraryConnectionSession(source: .kobo, entryPoint: "kobo_connect"), entryTapAlreadyTracked: false)
    }

    init(analyticsSession: AnalyticsLibraryConnectionSession, entryTapAlreadyTracked: Bool) {
        let configuration = WKWebViewConfiguration()
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        fixtureKind = arguments.contains("-CastReaderKoboLoginFixture") ? "login"
            : arguments.contains("-CastReaderKoboBlankFixture") ? "blank"
            : arguments.contains("-CastReaderKoboPopupFixture") ? "popup"
            : arguments.contains("-CastReaderKoboHundredShelfFixture") ? "hundred"
            : arguments.contains("-CastReaderKoboShelfFixture") ? "shelf" : nil
#else
        fixtureKind = nil
#endif
        if fixtureKind != nil {
            let profile = WKWebsiteDataStore.nonPersistent()
            configuration.websiteDataStore = profile
            let suite = "castreader.kobo.shelf-fixture.v1"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let history = HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("KoboFixture-" + UUID().uuidString))
            store = fixtureKind == "hundred" ? .shared
                : KoboLibraryStore(defaults: defaults, historyStore: history, websiteDataStore: profile)
        } else {
            configuration.websiteDataStore = KoboWebSession.websiteDataStore
            store = .shared
        }
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: .zero, configuration: configuration)
        connectionAnalytics = AnalyticsLibraryConnectionRecorder(session: analyticsSession, entryTapAlreadyTracked: entryTapAlreadyTracked)
        storageBoundary = store.captureStorageBoundary()
        super.init()
        configure(webView)
        mainHistoryObservation = observeHistory(webView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(shelfTouched))
        tap.cancelsTouchesInView = false
        webView.addGestureRecognizer(tap)
        webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(shelfTouched))
    }

    private func configure(_ view: WKWebView) {
        view.customUserAgent = GoogleBooksWebScripts.mobileSafariUserAgent
        view.navigationDelegate = self
        view.uiDelegate = self
#if DEBUG
        view.isInspectable = true
#endif
    }

    private func observeHistory(_ view: WKWebView) -> NSKeyValueObservation {
        view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateHistory() }
        }
    }

    private func updateHistory() {
        canGoBack = popupWebView != nil || activeWebView.canGoBack
    }

    func recordConnectionPresented() { if fixtureKind == nil { connectionAnalytics.presented() } }

    @discardableResult
    private func recordConnection(_ stage: AnalyticsLibraryConnectionStage, result: AnalyticsResult, errorCode: String? = nil, bookCount: Int? = nil) -> Bool {
        if fixtureKind != nil { return true }
        return connectionAnalytics.record(stage, result: result, errorCode: errorCode, bookCount: bookCount)
    }

    func closeConnection() {
        if bindingPhase == .failed, let pendingFailureCode {
            recordConnection(.failed, result: .failed, errorCode: pendingFailureCode)
        }
        if fixtureKind == nil { connectionAnalytics.close() }
        stop()
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        isClosed = false
        loadShelf()
    }

    private func loadShelf() {
        cancelWork()
        committedDocuments.remove(ObjectIdentifier(webView))
        navigationHasFailed = false
        setPhase(.opening)
#if DEBUG
        if let fixtureKind {
            let html = fixtureKind == "login" ? Self.loginFixture
                : fixtureKind == "blank" ? "<!doctype html><html><body></body></html>"
                : fixtureKind == "popup" ? Self.popupFixture
                : fixtureKind == "hundred" ? KoboWebScripts.debugHundredBookShelfFixture
                : KoboWebScripts.debugShelfFixture
            navigations[ObjectIdentifier(webView)] = webView.loadHTMLString(html, baseURL: KoboWebScripts.shelfURL)
            return
        }
#endif
        navigations[ObjectIdentifier(webView)] = webView.load(URLRequest(url: latestShelfURL))
        scheduleObservation()
    }

    func stop() {
        isClosed = true
        cancelWork()
        webView.stopLoading()
        discardPopup()
    }

    private func cancelWork() {
        flowGeneration += 1
        workTask?.cancel()
        workTask = nil
        isScanningShelf = false
        awaitingAutomaticPageChange = false
        webView.isUserInteractionEnabled = true
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        popupWebView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        completedScan = nil
        completedPageKey = nil
        completedFingerprint = nil
        resolvedShelfAccount = nil
    }

    private func setPhase(_ phase: KoboBindingPhase) {
        if bindingPhase != phase {
            ReaderRunLog.write("KOBO binding phase=\(phase) surface=\(popupWebView == nil ? "main" : "popup")")
        }
        bindingPhase = phase
        if phase != .failed { errorText = nil; pendingFailureCode = nil }
        switch phase {
        case .opening:
            statusText = AppLocalized("正在打开 Kobo…")
            detailText = AppLocalized("登录成功后将自动进入书架。")
        case .awaitingLogin:
            statusText = AppLocalized("请登录你的 Kobo 账号")
            detailText = AppLocalized("登录成功后会自动继续，无需再点按钮。")
        case .authenticating:
            statusText = AppLocalized("请完成 Kobo 登录")
            detailText = AppLocalized("登录页面会使用完整空间，完成后自动返回书架。")
        case .scanning:
            statusText = AppLocalized("正在同步 Kobo 书架…")
            detailText = AppLocalized("正在等待书架完整加载，请稍候。")
        case .ready:
            statusText = AppLocalized("Kobo 书架已加载")
        case .synced:
            statusText = AppLocalized("Kobo 书架已同步")
        case .failed:
            statusText = AppLocalized("Kobo 内容暂时无法打开，请重试。")
            detailText = AppLocalized("重新加载")
        }
        if phase == .authenticating || phase == .failed {
            webView.isUserInteractionEnabled = true
            popupWebView?.isUserInteractionEnabled = true
        }
        updateHistory()
    }

    private func fail(_ code: String, message: String? = nil) {
        cancelWork()
        navigationHasFailed = true
        setPhase(.failed)
        errorText = message ?? AppLocalized("内容暂时无法打开，请重试")
        pendingFailureCode = code
        log("failed reason=\(code)", view: activeWebView)
        // A visible retry is still the same connection attempt. The recorder's
        // failed stage is terminal, so emit it only if the user closes here.
    }

    func openSignIn() {
        guard bindingPhase == .awaitingLogin else { return }
        cancelWork()
        didRecoverContinuation = false
        recordConnection(.loginStarted, result: .started)
        setPhase(.authenticating)
        let generation = flowGeneration
        let view = activeWebView
        // A native tap is not a WebKit user gesture. Permit the site's actual
        // click handler to create its validated popup only during this action.
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false }
            let raw = await self.evaluate(KoboWebScripts.activateSignIn, in: view, purpose: "sign_in_action")
            guard self.isCurrent(generation), view === self.activeWebView else { return }
            if raw as? String == "form" || raw as? String == "clicked" {
                self.scheduleObservation()
            } else {
                self.fail("sign_in_control_unavailable", message: AppLocalized("请点击页面中的登录入口后继续。"))
            }
        }
    }

    func reloadPage() {
        guard !isClosed else { return }
        cancelWork()
        didRecoverContinuation = false
        navigationHasFailed = false
        let view = activeWebView
        setPhase(KoboBindingFlowContract.isCredentialURL(view.url) ? .authenticating : .opening)
#if DEBUG
        if fixtureKind != nil, popupWebView == nil { loadShelf(); return }
#endif
        if KoboWebScripts.allowsBindingNavigation(view.url) {
            let navigation = view.reload()
            navigations[ObjectIdentifier(view)] = navigation
            scheduleObservation()
        } else {
            discardPopup()
            loadShelf()
        }
    }

    func goBack() {
        cancelWork()
        navigationHasFailed = false
        if activeWebView.canGoBack {
            setPhase(.opening)
            let navigation = activeWebView.goBack()
            navigations[ObjectIdentifier(activeWebView)] = navigation
            scheduleObservation()
        } else if popupWebView != nil {
            closePopup()
        }
    }

    func closePopup() {
        guard popupWebView != nil else { return }
        cancelWork()
        navigationHasFailed = false
        if let opener = suspendedPopups.popLast() {
            if let popupWebView {
                navigations.removeValue(forKey: ObjectIdentifier(popupWebView))
                committedDocuments.remove(ObjectIdentifier(popupWebView))
            }
            popupWebView?.stopLoading()
            popupWebView?.navigationDelegate = nil
            popupWebView?.uiDelegate = nil
            popupWebView = opener
            popupHistoryObservation = observeHistory(opener)
            setPhase(.authenticating)
            scheduleObservation()
            return
        }
        discardPopup()
        // Closing a window proves neither success nor cancellation. Recheck
        // the same persistent session through the actual Kobo shelf.
        loadShelf()
    }

    private func discardPopup() {
        if let popupWebView {
            navigations.removeValue(forKey: ObjectIdentifier(popupWebView))
            committedDocuments.remove(ObjectIdentifier(popupWebView))
        }
        popupWebView?.stopLoading()
        popupWebView?.navigationDelegate = nil
        popupWebView?.uiDelegate = nil
        popupWebView = nil
        popupHistoryObservation = nil
        suspendedPopups.forEach {
            navigations.removeValue(forKey: ObjectIdentifier($0))
            committedDocuments.remove(ObjectIdentifier($0))
            $0.stopLoading()
            $0.navigationDelegate = nil
            $0.uiDelegate = nil
        }
        suspendedPopups = []
        updateHistory()
    }

    @objc private func shelfTouched(_ gesture: UIGestureRecognizer) {
        guard canSync, gesture.state == .began || gesture.state == .ended else { return }
        cancelWork()
        setPhase(.opening)
        scheduleObservation(delay: 500_000_000)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && !isClosed && generation == flowGeneration
            && storageBoundary.map(store.isCurrentStorageBoundary) == true
    }

    private func isKnown(_ view: WKWebView) -> Bool {
        view === webView || view === popupWebView || suspendedPopups.contains { $0 === view }
    }

    private func isStale(_ navigation: WKNavigation?, in view: WKWebView) -> Bool {
        guard let navigation,
              let current = navigations[ObjectIdentifier(view)] else { return false }
        return navigation !== current
    }

    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isKnown(view), !isClosed else { return }
        committedDocuments.remove(ObjectIdentifier(view))
        navigations[ObjectIdentifier(view)] = navigation
        log("navigation_start", view: view)
        if view === activeWebView, !(isScanningShelf && awaitingAutomaticPageChange && view === webView) {
            navigationHasFailed = false
            cancelWork()
            setPhase(KoboBindingFlowContract.isCredentialURL(view.url) ? .authenticating : .opening)
            scheduleObservation()
        }
    }

    func webView(_ view: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard isKnown(view) else { return }
        log("navigation_redirect", view: view)
        if view === activeWebView, KoboBindingFlowContract.isCredentialURL(view.url) {
            setPhase(.authenticating)
        }
    }

    func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
        guard isKnown(view), !isStale(navigation, in: view), !isClosed else { return }
        committedDocuments.insert(ObjectIdentifier(view))
        log("navigation_commit", view: view)
        guard view === activeWebView, !navigationHasFailed else { return }
        if KoboBindingFlowContract.isCredentialURL(view.url) { setPhase(.authenticating) }
        scheduleObservation()
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        guard isKnown(view), !isStale(navigation, in: view), !isClosed else { return }
        log("navigation_finish", view: view)
        updateHistory()
        guard view === activeWebView, !navigationHasFailed else { return }
        scheduleObservation()
    }

    private func permits(_ url: URL?, in view: WKWebView) -> Bool {
        if KoboWebScripts.allowsBindingNavigation(url) { return true }
        return (view === popupWebView || suspendedPopups.contains { $0 === view })
            && (url == nil || url?.absoluteString == "about:blank")
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard isKnown(view), !isClosed else { decisionHandler(.cancel); return }
        guard action.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        let blankPopup = action.targetFrame == nil && KoboBindingFlowContract.allowsPopupBootstrap(action.request.url, openerURL: action.sourceFrame.request.url)
        guard permits(action.request.url, in: view) || blankPopup else {
            decisionHandler(.cancel)
            log("navigation_blocked destination=\(KoboBindingFlowContract.safeRouteLabel(action.request.url))", view: view)
            if view === activeWebView {
                fail("navigation_blocked", message: AppLocalized("Kobo 内容暂时无法打开，请重试。"))
            }
            return
        }
        log("navigation_allowed destination=\(KoboBindingFlowContract.safeRouteLabel(action.request.url))", view: view)
        if view === activeWebView, action.targetFrame?.isMainFrame == true,
           !(isScanningShelf && awaitingAutomaticPageChange && KoboWebScripts.isShelfURL(action.request.url)) {
            committedDocuments.remove(ObjectIdentifier(view))
            navigationHasFailed = false
            cancelWork()
            setPhase(KoboBindingFlowContract.isCredentialURL(action.request.url) ? .authenticating : .opening)
        }
        decisionHandler(.allow)
    }

    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard response.isForMainFrame else { decisionHandler(.allow); return }
        guard isKnown(view), permits(response.response.url, in: view) else {
            decisionHandler(.cancel)
            if isKnown(view), view === activeWebView { fail("response_destination_blocked") }
            return
        }
        if let http = response.response as? HTTPURLResponse {
            log("response status=\(http.statusCode)", view: view)
            if http.statusCode >= 400, view === activeWebView {
                fail("http_\(http.statusCode)", message: AppLocalized("网络连接失败，请重试。"))
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard isKnown(view), !isClosed,
              suspendedPopups.count < 3,
              KoboWebScripts.allowsBindingNavigation(action.request.url)
                || KoboBindingFlowContract.allowsPopupBootstrap(action.request.url, openerURL: action.sourceFrame.request.url) else {
            log("popup_blocked", view: view)
            return nil
        }
        cancelWork()
        // Keep the opener's profile and WebKit-supplied configuration: this
        // preserves popup/opener relationships without exposing credentials.
        configuration.websiteDataStore = view.configuration.websiteDataStore
        if let existing = popupWebView { suspendedPopups.append(existing) }
        navigationHasFailed = false
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        popupWebView = popup
        popupHistoryObservation = observeHistory(popup)
        setPhase(.authenticating)
        recordConnection(.loginStarted, result: .started)
        log("popup_created", view: popup)
        scheduleObservation()
        return popup
    }

    func webViewDidClose(_ view: WKWebView) {
        if view === popupWebView { closePopup() }
        else { removeSuspendedPopup(view) }
    }

    private func removeSuspendedPopup(_ view: WKWebView) {
        guard suspendedPopups.contains(where: { $0 === view }) else { return }
        suspendedPopups.removeAll { $0 === view }
        navigations.removeValue(forKey: ObjectIdentifier(view))
        committedDocuments.remove(ObjectIdentifier(view))
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(view, navigation: navigation, error: error)
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(view, navigation: navigation, error: error)
    }

    private func navigationFailed(_ view: WKWebView, navigation: WKNavigation?, error: Error) {
        guard isKnown(view), view === activeWebView, !isStale(navigation, in: view) else { return }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        log("navigation_failed domain=\(nsError.domain) code=\(nsError.code)", view: view)
        fail("navigation_failed", message: AppLocalized("网络连接失败，请重试。"))
    }

    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        guard isKnown(view) else { return }
        guard view === activeWebView else { removeSuspendedPopup(view); return }
        log("web_process_terminated", view: view)
        fail("web_process_terminated")
    }

    private func scheduleObservation(delay: UInt64 = 80_000_000) {
        guard !isClosed, !navigationHasFailed, !isScanningShelf, !didSync, !canSync else { return }
        flowGeneration += 1
        let generation = flowGeneration
        workTask?.cancel()
        workTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, self.isCurrent(generation) else { return }
            await self.observePage(generation: generation)
        }
    }

    private func observePage(generation: Int) async {
        var blankSince: TimeInterval?
        var unavailableSince: TimeInterval?
        var loadingSince: TimeInterval?
        var lastDiagnostic = ""
        while isCurrent(generation) {
            let view = activeWebView
            let raw = await evaluate(KoboWebScripts.bindingPageProbe, in: view, purpose: "binding_probe")
            guard isCurrent(generation), view === activeWebView else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard let dictionary = raw as? [String: Any] else {
                unavailableSince = unavailableSince ?? now
                if now - (unavailableSince ?? now) > 25 {
                    fail("page_probe_unavailable")
                    return
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                continue
            }
            unavailableSince = nil
            let probe = KoboBindingPageProbe(dictionary)
            let diagnostic = "form=\(probe.hasCredentialForm) shelf=\(probe.isShelfContext) account=\(probe.hasAccountEvidence) blank=\(probe.isBlank) loading=\(probe.isLoading)"
            if diagnostic != lastDiagnostic { log("probe " + diagnostic, view: view); lastDiagnostic = diagnostic }

            // Visible forms always win over URL/account-menu hints, including
            // login forms rendered in-place at /library/books.
            if probe.hasCredentialForm {
                blankSince = nil
                loadingSince = nil
                setPhase(.authenticating)
            } else if probe.canStartShelfScan(at: view.url, hasCommittedDocument: committedDocuments.contains(ObjectIdentifier(view))) {
                blankSince = nil
                if let url = view.url, KoboWebScripts.isShelfURL(url) { latestShelfURL = url }
                if view === popupWebView {
                    discardPopup()
                    loadShelf()
                    return
                }
                recordConnection(.loginSucceeded, result: .success)
                await scanShelf(generation: generation)
                return
            } else if probe.isBlank {
                blankSince = blankSince ?? now
                let duration = now - (blankSince ?? now)
                if !view.isLoading, !probe.isLoading, !didRecoverContinuation,
                   let target = KoboBindingFlowContract.trustedShelfContinuation(view.url),
                   target != view.url {
                    didRecoverContinuation = true
                    latestShelfURL = target
                    discardPopup()
                    loadShelf()
                    return
                }
                if duration > (view.isLoading || probe.isLoading ? 25 : 4) {
                    fail("blank_page", message: AppLocalized("Kobo 内容暂时无法打开，请重试。"))
                    return
                }
            } else {
                blankSince = nil
                if view.isLoading || probe.isLoading {
                    loadingSince = loadingSince ?? now
                    if now - (loadingSince ?? now) > 25 {
                        fail("page_loading_stalled", message: AppLocalized("网络连接失败，请重试。"))
                        return
                    }
                } else { loadingSince = nil }
                if KoboBindingFlowContract.isCredentialURL(view.url) || view === popupWebView {
                    setPhase(.authenticating)
                } else if probe.hasSignInControl {
                    setPhase(.awaitingLogin)
                } else {
                    // An unrecognized nonempty page must stay navigable. Do
                    // not turn a polling failure into a second login screen.
                    setPhase(.authenticating)
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    private func scanShelf(generation: Int) async {
        guard isCurrent(generation), popupWebView == nil else { return }
        setPhase(.scanning)
        isScanningShelf = true
        var policy = KoboShelfScanPolicy(startedAt: ProcessInfo.processInfo.systemUptime)
        defer {
            if generation == flowGeneration {
                isScanningShelf = false
                awaitingAutomaticPageChange = false
                webView.isUserInteractionEnabled = true
            }
        }
        while isCurrent(generation) {
            let raw = await evaluate(KoboWebScripts.libraryScan, in: webView, purpose: "shelf_scan")
            guard isCurrent(generation) else { return }
            var snapshot = (raw as? [String: Any]).map(KoboScanResult.init)
            // Losing authentication releases input immediately. Page changes
            // may briefly lose the JS context; the policy can retry that case.
            let credentialForm = (raw as? [String: Any])?["hasCredentialForm"] as? Bool == true
            if credentialForm || KoboBindingFlowContract.isCredentialURL(webView.url)
                || (snapshot?.authenticated == false && !webView.isLoading && !awaitingAutomaticPageChange) {
                isScanningShelf = false
                awaitingAutomaticPageChange = false
                webView.isUserInteractionEnabled = true
                setPhase(.authenticating)
                scheduleObservation()
                return
            }
            if snapshot?.authenticated == true, snapshot?.account?.identity == nil {
                if resolvedShelfAccount == nil {
                    let account = await resolveShelfAccount()
                    guard isCurrent(generation) else { return }
                    guard let account else {
                        fail("account_identity_unavailable", message: AppLocalized("请先登录 Kobo 并进入你的书架。"))
                        return
                    }
                    resolvedShelfAccount = account
                }
                snapshot = snapshot.map(applyingResolvedAccount)
            }
            let decision = policy.observe(snapshot, now: ProcessInfo.processInfo.systemUptime)
            awaitingAutomaticPageChange = policy.isAwaitingPageChange
            // Only proven shelf pages can be locked while collecting. Never
            // lock an authentication form based on a prior snapshot.
            webView.isUserInteractionEnabled = snapshot?.authenticated != true
            switch decision {
            case .wait: break
            case .resetToFirstPage, .advancePage:
                awaitingAutomaticPageChange = true
                let script = decision == .resetToFirstPage ? KoboWebScripts.resetShelfToFirstPage : KoboWebScripts.advanceShelfPage
                let clicked = await evaluate(script, in: webView, purpose: "shelf_page_action")
                guard isCurrent(generation) else { return }
                if let clicked = clicked as? Bool, !clicked { fail("page_action_unavailable"); return }
                log("shelf page action=\(decision == .advancePage ? "next" : "first") completedPages=\(policy.completedPageCount) books=\(policy.collectedBookCount)", view: webView)
            case .complete:
                guard KoboShelfSyncContract.canCommit(bookCount: policy.books.count, account: policy.account, reachedEnd: policy.completeTraversal, stableEndPasses: policy.stableEndPasses, completeTraversal: policy.completeTraversal) else {
                    fail("whole_shelf_unverified"); return
                }
                completedScan = policy
                completedPageKey = snapshot?.pagination.pageKey
                completedFingerprint = snapshot?.pageFingerprint
                setPhase(.ready)
                detailText = String(format: AppLocalized("找到 %d 本书，可以同步。"), policy.books.count)
                log("shelf ready books=\(policy.books.count) pages=\(policy.completedPageCount)", view: webView)
                return
            case .failed(let code):
                fail(code, message: AppLocalized("书架仍在加载，请稍后重试。"))
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    func commitShelf() {
        guard canSync, let scan = completedScan, let account = scan.account else { return }
        let generation = flowGeneration
        setPhase(.scanning)
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-read the profile before writing, so an account change during
            // a multi-page traversal cannot inherit the previous user's books.
            if self.resolvedShelfAccount != nil {
                let verified = await self.resolveShelfAccount()
                guard self.isCurrent(generation) else { return }
                guard verified?.identity == account.identity else {
                    self.fail("account_changed"); return
                }
            }
            let raw = await self.evaluate(KoboWebScripts.shelfSnapshot, in: self.webView, purpose: "commit_snapshot")
            guard self.isCurrent(generation) else { return }
            guard let dictionary = raw as? [String: Any] else { self.fail("commit_snapshot_unavailable"); return }
            let current = self.applyingResolvedAccount(KoboScanResult(dictionary))
            guard current.authenticated, current.account?.identity == account.identity,
                  !current.hasPendingWork, current.isCompleteSnapshot, !current.pagination.blocked,
                  current.pagination.isLastPage, !current.pagination.hasNextPage,
                  current.pagination.totalPages == nil || current.pagination.totalPages == scan.completedPageCount,
                  current.pagination.pageKey == self.completedPageKey,
                  current.pageFingerprint == self.completedFingerprint else {
                self.fail("commit_snapshot_changed"); return
            }
            self.recordConnection(.syncStarted, result: .started)
            self.store.mergeScrapedBooks(Array(scan.books.values), account: account,
                                        expectedStorageBoundary: self.storageBoundary)
            if let error = self.store.lastError { self.fail("local_commit_failed", message: error); return }
            guard self.recordConnection(.syncCompleted, result: .success, bookCount: scan.books.count) else {
                self.fail("sync_confirmation_failed", message: AppLocalized("书架已保存，但同步确认未完成，请重试。")); return
            }
            self.setPhase(.synced)
            self.detailText = String(format: AppLocalized("已同步 %d 本书。"), scan.books.count)
        }
    }

    private func resolveShelfAccount() async -> (identity: String, label: String)? {
        do {
            let raw = try await webView.callAsyncJavaScript(
                KoboWebScripts.accountSettingsIdentity, arguments: [:], in: nil, contentWorld: .page
            )
            guard let value = raw as? [String: Any],
                  let identity = value["identity"] as? String,
                  KoboAccountIdentity.isValidStoredIdentity(identity) else { return nil }
            return (identity, value["label"] as? String ?? "Kobo")
        } catch {
            let error = error as NSError
            log("account_lookup_failed domain=\(error.domain) code=\(error.code)", view: webView)
            return nil
        }
    }

    private func applyingResolvedAccount(_ result: KoboScanResult) -> KoboScanResult {
        guard result.authenticated, result.account?.identity == nil,
              let resolvedShelfAccount else { return result }
        var copy = result
        copy.account = KoboScanAccountEvidence(
            displayLabel: resolvedShelfAccount.label, identity: resolvedShelfAccount.identity,
            hasAccountEvidence: result.hasAccountEvidence, isShelfContext: result.isShelfContext,
            isCompleteSnapshot: result.isCompleteSnapshot
        )
        return copy
    }

    private func evaluate(_ script: String, in view: WKWebView, purpose: String) async -> Any? {
        do { return try await view.evaluateJavaScript(script) }
        catch {
            let error = error as NSError
            log("js_failed purpose=\(purpose) domain=\(error.domain) code=\(error.code)", view: view)
            return nil
        }
    }

    private func log(_ message: String, view: WKWebView) {
        ReaderRunLog.write("KOBO \(message) surface=\(view === webView ? "main" : "popup") route=\(KoboBindingFlowContract.safeRouteLabel(view.url))")
    }

#if DEBUG
    private static let popupFixture = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body><h1>Local Kobo popup fixture</h1>
    <a href="#signin" onclick="event.preventDefault();var w=window.open('about:blank','kobo-local-auth');if(w){w.document.write('<!doctype html><html><head><meta name=viewport content=width=device-width,initial-scale=1><style>body{font:17px -apple-system;padding:20px}label{display:block;margin:20px 0}input{display:block;font:inherit;padding:12px;width:85%}</style></head><body><h1>Local authorization</h1><form><label>Email<input type=email autocomplete=username aria-label=Email></label><label>Password<input type=password aria-label=Password></label></form></body></html>');w.document.close();}">Sign in</a>
    </body></html>
    """#

    private static let loginFixture = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:17px -apple-system;padding:20px}label{display:block;margin:20px 0}input{display:block;font:inherit;padding:12px;width:85%}button{font:inherit;padding:14px}header{background:#fff1d8;padding:12px}</style></head>
    <body><header>Local Kobo login fixture · no network</header><h1>Sign in to Kobo</h1>
    <form onsubmit="event.preventDefault();this.outerHTML='<p>Form submitted locally</p>'">
    <label>Email<input aria-label="Email" type="email" autocomplete="username"></label>
    <label>Password<input aria-label="Password" type="password" autocomplete="current-password"></label>
    <button type="submit">Continue</button></form></body></html>
    """#
#endif
}
