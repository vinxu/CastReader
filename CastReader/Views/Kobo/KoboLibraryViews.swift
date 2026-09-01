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
                }
            }
        }
        .navigationTitle("Kobo")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: AppLocalized("搜索书名或作者"))
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
            ZStack(alignment: .bottom) {
                KoboWebViewContainer(webView: model.webView)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("koboBindingWebView")
                if let popup = model.popupWebView {
                    KoboWebViewContainer(webView: popup)
                        .background(AppTheme.background)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("koboLoginPopupWebView")
                }
                if model.popupWebView == nil, model.showsBottomCard {
                    bottomCard
                }
            }
            .navigationTitle(AppLocalized("绑定 Kobo"))
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
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
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
                    Text(model.detailText)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if model.canSync {
                Button {
                    model.commitShelf()
                } label: {
                    Label(AppLocalized("同步 Kobo 书架"), systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .accessibilityIdentifier("koboSyncButton")
            } else if !model.isSignedIn {
                Button {
                    model.openSignIn()
                } label: {
                    Label(AppLocalized("登录"), systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(model.isWorking)
                .accessibilityIdentifier("koboSignInButton")
            } else if model.didSync {
                Button(AppLocalized("完成")) { dismiss() }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
            }

            if let error = model.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundColor(AppTheme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .accessibilityIdentifier("koboBindingCard")
    }
}

struct KoboWebViewContainer: UIViewRepresentable {
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

@MainActor
final class KoboLibrarySyncViewModel:
    NSObject,
    ObservableObject,
    WKNavigationDelegate,
    WKUIDelegate
{
    @Published var statusText = AppLocalized("正在打开 Kobo…")
    @Published var detailText =
        AppLocalized("登录后会自动打开你的书架，CastReader 不会保存密码。")
    @Published var errorText: String?
    @Published var isWorking = false
    @Published var isSignedIn = false
    @Published var canSync = false
    @Published var didSync = false
    @Published private(set) var popupWebView: WKWebView?

    let webView: WKWebView
    var showsBottomCard: Bool { !isCredentialPage || canSync || didSync }

    private let store = KoboLibraryStore.shared
    private var didLoad = false
    private var isCredentialPage = false
    private var pendingBooks: [String: KoboBook] = [:]
    private var pendingAccount: KoboAccountInfo?
    private var stableEndPasses = 0
    private var previousStableCount = -1
    private var workTask: Task<Void, Never>?
    private var probeGeneration = 0
    private var isScanningShelf = false
    private let connectionAnalytics: AnalyticsLibraryConnectionRecorder

    override convenience init() {
        self.init(
            analyticsSession: AnalyticsLibraryConnectionSession(
                source: .kobo,
                entryPoint: "kobo_connect"
            ),
            entryTapAlreadyTracked: false
        )
    }

    init(
        analyticsSession: AnalyticsLibraryConnectionSession,
        entryTapAlreadyTracked: Bool
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = KoboWebSession.websiteDataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: .zero, configuration: configuration)
        connectionAnalytics = AnalyticsLibraryConnectionRecorder(
            session: analyticsSession,
            entryTapAlreadyTracked: entryTapAlreadyTracked
        )
        super.init()
        webView.customUserAgent = GoogleBooksWebScripts.mobileSafariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
#if DEBUG
        webView.isInspectable = true
#endif
    }

    func recordConnectionPresented() { connectionAnalytics.presented() }

    func closeConnection() {
        connectionAnalytics.close()
        stop()
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        webView.load(URLRequest(url: KoboWebScripts.shelfURL))
    }

    func stop() {
        probeGeneration += 1
        workTask?.cancel()
        workTask = nil
        isScanningShelf = false
        popupWebView?.stopLoading()
        popupWebView = nil
    }

    func openSignIn() {
        guard !isWorking else { return }
        connectionAnalytics.record(.loginStarted, result: .started)
        errorText = nil
        isWorking = true
        webView.evaluateJavaScript(
            KoboWebScripts.currentPageSignInURL
        ) { [weak self] value, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let raw = value as? String,
                   let url = URL(string: raw),
                   KoboWebScripts.allowsBindingNavigation(url) {
                    self.isCredentialPage = true
                    self.webView.load(URLRequest(url: url))
                    self.isWorking = false
                    return
                }
                let click = #"""
                (function () {
                  var node = document.querySelector(
                    'a[data-testid*="sign-in" i], a[href*="/signin" i], a[href*="/login" i], button[data-testid*="sign-in" i]'
                  );
                  if (!node) return false;
                  node.click();
                  return true;
                })();
                """#
                self.webView.evaluateJavaScript(click) { [weak self] value, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isWorking = false
                        if value as? Bool == true {
                            self.isCredentialPage = true
                        } else {
                            self.errorText =
                                AppLocalized("请点击页面中的登录入口后继续。")
                        }
                    }
                }
            }
        }
    }

    func commitShelf() {
        guard canSync, let account = pendingAccount else { return }
        connectionAnalytics.record(.syncStarted, result: .started)
        isWorking = true
        store.mergeScrapedBooks(
            Array(pendingBooks.values),
            account: account
        )
        isWorking = false
        if let error = store.lastError {
            errorText = error
            connectionAnalytics.record(
                .failed,
                result: .failed,
                errorCode: "local_commit_failed"
            )
        } else {
            let verifiedBookCount = pendingBooks.count
            guard connectionAnalytics.record(
                .syncCompleted,
                result: .success,
                bookCount: verifiedBookCount
            ) else {
                errorText = AppLocalized("书架已保存，但同步确认未完成，请重试。")
                canSync = true
                return
            }
            didSync = true
            canSync = false
            statusText = AppLocalized("Kobo 书架已同步")
            detailText = String(
                format: AppLocalized("已同步 %d 本书。"),
                verifiedBookCount
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        updateCredentialState(webView.url)
        if webView === self.webView,
           KoboWebScripts.isShelfURL(webView.url) {
            presentShelfLoading()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateCredentialState(webView.url)
        if webView === self.webView, KoboWebScripts.isShelfURL(webView.url) {
            presentShelfLoading()
            ReaderRunLog.write(
                "KOBO shelf committed; session probe scheduled immediately"
            )
            scheduleProbe(delayNanoseconds: 80_000_000)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateCredentialState(webView.url)
        if webView === popupWebView,
           KoboWebScripts.isShelfURL(webView.url) {
            popupWebView = nil
            self.webView.load(URLRequest(url: KoboWebScripts.shelfURL))
            return
        }
        guard webView === self.webView || popupWebView == nil else { return }
        scheduleProbe(delayNanoseconds: 80_000_000)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        guard KoboWebScripts.allowsBindingNavigation(
            navigationAction.request.url
        ) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url,
              KoboWebScripts.allowsBindingNavigation(url) else {
            return nil
        }
        // Reuse the exact configuration supplied by WebKit, then force the
        // app-wide persistent profile so OAuth/popup state returns to shelf.
        configuration.websiteDataStore = KoboWebSession.websiteDataStore
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = GoogleBooksWebScripts.mobileSafariUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self
#if DEBUG
        popup.isInspectable = true
#endif
        popupWebView = popup
        isCredentialPage = true
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        popupWebView = nil
        isCredentialPage = false
        statusText = AppLocalized("登录成功，正在进入书架…")
        self.webView.load(URLRequest(url: KoboWebScripts.shelfURL))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        recordNavigationError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        recordNavigationError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === popupWebView {
            popupWebView = nil
        }
        isCredentialPage = false
        errorText = AppLocalized("内容暂时无法打开，请重试")
    }

    private func updateCredentialState(_ url: URL?) {
        guard let host = url?.host?.lowercased() else { return }
        isCredentialPage =
            !KoboWebScripts.isShelfURL(url)
                && (
                    host.contains("rakuten")
                        || host == "accounts.google.com"
                        || host == "appleid.apple.com"
                        || url?.path.lowercased().contains("signin") == true
                        || url?.path.lowercased().contains("login") == true
                )
        if KoboWebScripts.isShelfURL(url), !didSync {
            presentShelfLoading()
        }
        if isCredentialPage {
            statusText = AppLocalized("请完成 Kobo 登录")
            detailText =
                AppLocalized("登录页面会使用完整空间，完成后自动返回书架。")
        }
    }

    private func presentShelfLoading() {
        guard !didSync else { return }
        isCredentialPage = false
        isWorking = true
        errorText = nil
        statusText = AppLocalized("正在同步 Kobo 书架…")
        detailText = AppLocalized("正在检测书架中的书籍，请稍候。")
    }

    private func scheduleProbe(
        delayNanoseconds: UInt64 = 120_000_000
    ) {
        guard !isScanningShelf, !didSync else { return }
        probeGeneration += 1
        let generation = probeGeneration
        workTask?.cancel()
        workTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self,
                  !Task.isCancelled,
                  generation == self.probeGeneration else { return }
            await self.runSessionProbeLoop(generation: generation)
        }
    }

    private func recordNavigationError(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        if webView.url == nil, popupWebView == nil {
            isCredentialPage = false
        }
        isWorking = false
        errorText = AppLocalized("网络连接失败，请重试。")
    }

    private enum SessionProbeOutcome {
        case retry
        case finished
    }

    private func runSessionProbeLoop(generation: Int) async {
        for attempt in 0..<60 {
            guard !Task.isCancelled,
                  generation == probeGeneration else { return }
            if await probeSession(
                acceptSignedOutResult: attempt >= 4
            ) == .finished { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled,
              generation == probeGeneration else { return }
        isWorking = false
        errorText = AppLocalized("书架仍在加载，请稍后重试。")
    }

    private func probeSession(
        acceptSignedOutResult: Bool
    ) async -> SessionProbeOutcome {
        guard let raw = await evaluate(KoboWebScripts.sessionProbe),
              let dictionary = raw as? [String: Any] else {
            if KoboWebScripts.isShelfURL(webView.url) {
                presentShelfLoading()
                return .retry
            }
            if !isCredentialPage {
                isWorking = false
                errorText = AppLocalized("内容暂时无法打开，请重试")
            }
            return .finished
        }
        let result = KoboScanResult(dictionary)
        guard result.authenticated else {
            isSignedIn = false
            canSync = false
            if result.authRequired, acceptSignedOutResult {
                isWorking = false
                statusText = AppLocalized("请登录你的 Kobo 账号")
                detailText =
                    AppLocalized("可选择 Kobo 支持的 Google、Rakuten 或邮箱登录。")
                return .finished
            }
            presentShelfLoading()
            return .retry
        }

        isSignedIn = true
        connectionAnalytics.record(.loginSucceeded, result: .success)
        isCredentialPage = false
        statusText = AppLocalized("正在同步 Kobo 书架…")
        detailText = AppLocalized("正在等待书架完整加载，请稍候。")
        ReaderRunLog.write("KOBO shelf authenticated; scan started")
        isScanningShelf = true
        await scanShelf()
        isScanningShelf = false
        return .finished
    }

    private func scanShelf() async {
        guard workTask == nil || !Task.isCancelled else { return }
        isWorking = true
        pendingBooks = [:]
        pendingAccount = nil
        stableEndPasses = 0
        previousStableCount = -1

        for attempt in 0..<36 {
            guard !Task.isCancelled,
                  let raw = await evaluate(KoboWebScripts.libraryScan),
                  let dictionary = raw as? [String: Any] else {
                break
            }
            let result = KoboScanResult(dictionary)
            guard result.authenticated,
                  let evidence = result.account else {
                break
            }
            result.books.forEach { book in
                pendingBooks[book.id] = KoboBookMetadata.merged(
                    existing: pendingBooks[book.id],
                    incoming: book
                )
            }
            let account = KoboAccountInfo(label: evidence)
            pendingAccount = account
            if attempt == 0 {
                ReaderRunLog.write(
                    "KOBO shelf first scan books=\(pendingBooks.count) " +
                    "complete=\(result.isCompleteSnapshot ? "Y" : "N")"
                )
            }

            if result.isCompleteSnapshot {
                if previousStableCount == pendingBooks.count {
                    stableEndPasses += 1
                } else {
                    previousStableCount = pendingBooks.count
                    stableEndPasses = 1
                }
            } else {
                stableEndPasses = 0
                previousStableCount = -1
            }

            if KoboShelfSyncContract.canCommit(
                bookCount: pendingBooks.count,
                account: account,
                reachedEnd: result.isCompleteSnapshot,
                stableEndPasses: stableEndPasses
            ) {
                canSync = true
                isWorking = false
                statusText = AppLocalized("Kobo 书架已加载")
                detailText = String(
                    format: AppLocalized("找到 %d 本书，可以同步。"),
                    pendingBooks.count
                )
                ReaderRunLog.write(
                    "KOBO shelf ready books=\(pendingBooks.count) " +
                    "stable=\(stableEndPasses)"
                )
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        isWorking = false
        canSync = false
        errorText = AppLocalized("书架仍在加载，请稍后重试。")
        connectionAnalytics.record(
            .failed,
            result: .failed,
            errorCode: "sync_snapshot_unavailable"
        )
    }

    private func evaluate(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }
}
