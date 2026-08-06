//
//  OReillyLibraryViews.swift
//  CastReader
//
//  O'Reilly Learning binding, History-backed shelf and reader launch UI.
//  O'Reilly has no Kindle-style owned-books shelf for institutional accounts,
//  so CastReader maps the authenticated Reading History (and book links
//  explicitly contained in Profile playlists) into the common shelf model.
//

import SwiftUI
import WebKit

extension Notification.Name {
    static let castReaderOReillyRebindRequested =
        Notification.Name("castreader.oreilly.rebindRequested")
}

// MARK: - Open

enum OReillyReaderLauncher {
    @MainActor
    static func open(
        _ book: OReillyBook,
        using coordinator: PlayerCoordinator,
        onboarding: BoundLibraryOnboardingStore,
        autoplay: Bool = false
    ) {
        let store = OReillyLibraryStore.shared
        store.markOpened(book)
        let latest = store.book(for: book.id) ?? book
        let document = ReadingDocument(
            id: latest.id,
            title: latest.title,
            sourceKind: .oreilly,
            language: Constants.TTS.defaultLanguage,
            paragraphs: [],
            sourceURL: latest.effectiveReaderURL,
            coverURL: latest.coverURL
        )
        let context = ProductAnalytics.shared.beginContentIntent(
            source: .oreilly,
            format: .oreilly,
            entryPoint:
                onboarding.analyticsEntryPoint(for: .oreilly)
                    ?? "oreilly_library",
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

struct OReillyHomeSection: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = OReillyLibraryStore.shared
    @ObservedObject private var onboarding =
        BoundLibraryOnboardingStore.shared

    var body: some View {
        Group {
            if !store.needsConnection && !store.homeBooks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("O’Reilly Learning")
                                .font(.headline)
                                .foregroundColor(AppTheme.foreground)
                            Text(AppLocalized("已同步的 O’Reilly 阅读历史"))
                                .font(.caption)
                                .foregroundColor(AppTheme.mutedForeground)
                        }
                        Spacer()
                        NavigationLink(destination: OReillyLibraryView()) {
                            Text(AppLocalized("查看全部"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(AppTheme.primary)
                        }
                        .accessibilityIdentifier("homeShelfViewAll.oreilly")
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(store.homeBooks) { book in
                                Button { open(book) } label: {
                                    OReillyRailCard(book: book)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(
                                    "homeShelfBook.oreilly.\(book.contentID)"
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                    }
                    .padding(.horizontal, -2)
                }
                .accessibilityIdentifier("homeShelfSection.oreilly")
            }
        }
    }

    private func open(_ book: OReillyBook) {
        OReillyReaderLauncher.open(
            book,
            using: coordinator,
            onboarding: onboarding
        )
    }
}

private struct OReillyRailCard: View {
    let book: OReillyBook

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            OReillyCoverView(book: book)
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

struct OReillyLibraryView: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = OReillyLibraryStore.shared
    @ObservedObject private var onboarding =
        BoundLibraryOnboardingStore.shared
    @State private var query = ""
    @State private var sort: OReillyLibrarySort = .recent
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
                let books = store.sortedBooks(sort: sort, query: query)
                if books.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppLocalized("暂无阅读历史"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.foreground)
                        Text(
                            AppLocalized(
                                "在 O’Reilly 打开过的书会在重新同步后显示在这里。"
                            )
                        )
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(books) { book in
                        Button { open(book) } label: {
                            HStack(spacing: 14) {
                                OReillyCoverView(book: book)
                                    .frame(width: 52, height: 72)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(AppTheme.foreground)
                                        .lineLimit(2)
                                    Text(book.displayAuthor)
                                        .font(.caption)
                                        .foregroundColor(
                                            AppTheme.mutedForeground
                                        )
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
            } header: {
                Text(AppLocalized("阅读历史"))
            } footer: {
                Text(
                    AppLocalized(
                        "O’Reilly 机构账户没有传统书架，CastReader 会同步你实际打开过的书。"
                    )
                )
            }
        }
        .navigationTitle("O’Reilly Learning")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: AppLocalized("搜索书名或作者"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(OReillyLibrarySort.allCases) { value in
                        Button(value.label) { sort = value }
                    }
                    Divider()
                    Button(AppLocalized("重新同步")) { showConnect = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showConnect) {
            OReillyLibraryConnectView()
        }
    }

    private func open(_ book: OReillyBook) {
        OReillyReaderLauncher.open(
            book,
            using: coordinator,
            onboarding: onboarding
        )
    }
}

struct OReillyCoverView: View {
    let book: OReillyBook

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
            Image(systemName: "text.book.closed.fill")
                .foregroundColor(AppTheme.primary)
        }
    }
}

// MARK: - Binding

struct OReillyLibraryConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: OReillyLibrarySyncViewModel
    @State private var showsInstitutionOptions = false
    @State private var institutionAccessLink = ""
    @State private var institutionAccessLinkError: String?

    init(
        analyticsSession: AnalyticsLibraryConnectionSession? = nil,
        entryTapAlreadyTracked: Bool = false
    ) {
        let session = analyticsSession ?? AnalyticsLibraryConnectionSession(
            source: .oreilly,
            entryPoint: "oreilly_connect"
        )
        _model = StateObject(
            wrappedValue: OReillyLibrarySyncViewModel(
                analyticsSession: session,
                entryTapAlreadyTracked: entryTapAlreadyTracked
            )
        )
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                if model.hasOpenedWebPage {
                    OReillyWebViewContainer(webView: model.webView)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("oreillyBindingWebView")
                } else {
                    initialBackdrop
                }

                if let popup = model.popupWebView {
                    OReillyWebViewContainer(webView: popup)
                        .background(AppTheme.background)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier(
                            "oreillyLoginPopupWebView"
                        )
                }

                if model.popupWebView == nil, model.showsBottomCard {
                    bottomCard
                }
            }
            .navigationTitle(AppLocalized("绑定 O’Reilly"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("关闭")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if model.isBrowsingCatalog {
                            Button {
                                model.returnToHistoryAndSync()
                            } label: {
                                Label(
                                    AppLocalized("同步 O’Reilly 阅读历史"),
                                    systemImage: "arrow.clockwise"
                                )
                            }
                            Divider()
                        }
                        Button {
                            model.openDirectAccount()
                        } label: {
                            Label(
                                AppLocalized("O’Reilly 个人账户"),
                                systemImage: "person.crop.circle"
                            )
                        }
                        Button {
                            showsInstitutionOptions = true
                        } label: {
                            Label(
                                AppLocalized("学校或图书馆"),
                                systemImage: "building.columns"
                            )
                        }
                    } label: {
                        Image(systemName: "person.badge.key")
                    }
                    .accessibilityIdentifier("oreillyLoginMethodMenu")
                }
            }
            .onAppear {
                model.recordConnectionPresented()
                model.loadIfNeeded()
            }
            .onDisappear { model.closeConnection() }
            .sheet(isPresented: $showsInstitutionOptions) {
                institutionOptions
            }
        }
        .navigationViewStyle(.stack)
    }

    private var initialBackdrop: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(AppTheme.primary)
            Text("O’Reilly Learning")
                .font(.title2.weight(.bold))
                .foregroundColor(AppTheme.foreground)
            Text(
                AppLocalized(
                    "支持个人订阅，也支持学校、公司和图书馆提供的机构访问。"
                )
            )
            .font(.subheadline)
            .foregroundColor(AppTheme.mutedForeground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }

    @ViewBuilder
    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                if model.isWorking {
                    ProgressView().tint(AppTheme.primary)
                } else {
                    Image(
                        systemName: model.isSignedIn
                            ? "checkmark.circle.fill"
                            : "person.badge.key"
                    )
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

            if model.needsHistorySeed {
                VStack(spacing: 9) {
                    Button {
                        model.openCatalogToChooseBook()
                    } label: {
                        Label(
                            AppLocalized("打开一本书"),
                            systemImage: "magnifyingglass"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .accessibilityIdentifier(
                        "oreillyBrowseToSeedHistoryButton"
                    )

                    Button {
                        model.returnToHistoryAndSync()
                    } label: {
                        Label(
                            AppLocalized("同步 O’Reilly 阅读历史"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.primary)
                    .accessibilityIdentifier(
                        "oreillyRescanEmptyHistoryButton"
                    )
                }
            } else if model.canSync {
                Button {
                    model.commitShelf()
                } label: {
                    Label(
                        AppLocalized("同步 O’Reilly 阅读历史"),
                        systemImage: "arrow.clockwise"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .accessibilityIdentifier("oreillySyncButton")
            } else if !model.hasChosenLoginMethod {
                VStack(spacing: 9) {
                    Button {
                        model.openDirectAccount()
                    } label: {
                        Label(
                            AppLocalized("使用 O’Reilly 个人账户"),
                            systemImage: "person.crop.circle"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primary)
                    .accessibilityIdentifier("oreillyDirectLoginButton")

                    Button {
                        showsInstitutionOptions = true
                    } label: {
                        Label(
                            AppLocalized("通过学校或图书馆访问"),
                            systemImage: "building.columns"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.primary)
                    .accessibilityIdentifier(
                        "oreillyInstitutionLoginButton"
                    )
                }
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
        .accessibilityIdentifier("oreillyBindingCard")
    }

    private var institutionOptions: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        showsInstitutionOptions = false
                        model.openPeninsulaLibrarySystem()
                    } label: {
                        Label {
                            Text(verbatim: "Peninsula Library System")
                        } icon: {
                            Image(systemName: "building.columns.fill")
                        }
                    }
                    .accessibilityIdentifier(
                        "oreillyPeninsulaLibraryLoginButton"
                    )

                    Button {
                        showsInstitutionOptions = false
                        model.openInstitutionDirectory()
                    } label: {
                        Label(
                            AppLocalized("通过学校或图书馆访问"),
                            systemImage: "magnifyingglass"
                        )
                    }
                    .accessibilityIdentifier(
                        "oreillyInstitutionDirectoryButton"
                    )
                }

                Section {
                    TextField(
                        text: $institutionAccessLink,
                        prompt: Text(verbatim: "https://…")
                    ) {
                        EmptyView()
                    }
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(
                        "oreillyInstitutionAccessLinkField"
                    )

                    Button {
                        openInstitutionAccessLink()
                    } label: {
                        Label(
                            AppLocalized("打开"),
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .disabled(
                        institutionAccessLink
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                    )
                    .accessibilityIdentifier(
                        "oreillyOpenInstitutionAccessLinkButton"
                    )

                    if let institutionAccessLinkError {
                        Text(institutionAccessLinkError)
                            .font(.caption)
                            .foregroundColor(AppTheme.destructive)
                    }
                } header: {
                    Text(AppLocalized("使用机构访问链接"))
                } footer: {
                    Text(
                        AppLocalized(
                            "粘贴图书馆提供的 O’Reilly 或 EZproxy 登录链接。"
                        )
                    )
                }
            }
            .navigationTitle(AppLocalized("学校或图书馆"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("取消")) {
                        showsInstitutionOptions = false
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .presentationDetents([.medium, .large])
    }

    private func openInstitutionAccessLink() {
        guard let url = OReillyWebScripts.institutionEntryURL(
            from: institutionAccessLink
        ) else {
            institutionAccessLinkError = AppLocalized(
                "这个链接不是有效的 O’Reilly 机构访问地址。"
            )
            return
        }
        institutionAccessLinkError = nil
        showsInstitutionOptions = false
        model.openInstitutionAccessURL(url)
    }
}

struct OReillyWebViewContainer: UIViewRepresentable {
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
final class OReillyLibrarySyncViewModel:
    NSObject,
    ObservableObject,
    WKNavigationDelegate,
    WKUIDelegate
{
    enum LoginMethod {
        case direct
        case institution
        case existingSession
    }

    @Published var statusText = AppLocalized("连接 O’Reilly Learning")
    @Published var detailText =
        AppLocalized("请选择个人账户，或学校、公司、图书馆提供的机构访问。")
    @Published var errorText: String?
    @Published var isWorking = false
    @Published var isSignedIn = false
    @Published var canSync = false
    @Published var didSync = false
    @Published var needsHistorySeed = false
    @Published var isBrowsingCatalog = false
    @Published private(set) var popupWebView: WKWebView?
    @Published private(set) var hasOpenedWebPage = false
    @Published private(set) var hasChosenLoginMethod = false

    let webView: WKWebView
    var showsBottomCard: Bool {
        !isCredentialPage || canSync || didSync
    }

    private let store = OReillyLibraryStore.shared
    private var didLoad = false
    private var isCredentialPage = false
    private var loginMethod: LoginMethod?
    private var pendingBooks: [String: OReillyBook] = [:]
    private var pendingAccount: OReillyAccountInfo?
    private var stableEndPasses = 0
    private var previousStableCount = -1
    private var workTask: Task<Void, Never>?
    private var catalogReturnTask: Task<Void, Never>?
    private var catalogMonitorTask: Task<Void, Never>?
    private var probeGeneration = 0
    private var isScanningShelf = false
    private var redirectedHistoryHosts: Set<String> = []
    private let connectionAnalytics: AnalyticsLibraryConnectionRecorder

    override convenience init() {
        self.init(
            analyticsSession: AnalyticsLibraryConnectionSession(
                source: .oreilly,
                entryPoint: "oreilly_connect"
            ),
            entryTapAlreadyTracked: false
        )
    }

    init(
        analyticsSession: AnalyticsLibraryConnectionSession,
        entryTapAlreadyTracked: Bool
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = OReillyWebSession.websiteDataStore
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

        // Re-sync an already bound proxy account on its proven host. A first
        // connection starts with native login choices instead of assuming the
        // public O'Reilly account route.
        guard let book = store.books.first,
              let readerURL = URL(string: book.readerURL),
              let historyURL = OReillyWebScripts.historyURL(for: readerURL)
        else {
            return
        }
        loginMethod = .existingSession
        hasChosenLoginMethod = true
        hasOpenedWebPage = true
        isWorking = true
        statusText = AppLocalized("正在打开 O’Reilly 阅读历史…")
        detailText = AppLocalized("正在恢复之前使用的登录会话。")
        webView.load(URLRequest(url: historyURL))
    }

    func stop() {
        probeGeneration += 1
        workTask?.cancel()
        workTask = nil
        catalogReturnTask?.cancel()
        catalogReturnTask = nil
        catalogMonitorTask?.cancel()
        catalogMonitorTask = nil
        isScanningShelf = false
        popupWebView?.stopLoading()
        popupWebView = nil
    }

    func openDirectAccount() {
        beginLogin(
            method: .direct,
            url: OReillyWebScripts.directHomeURL,
            status: AppLocalized("请登录 O’Reilly 个人账户")
        )
    }

    func openInstitutionDirectory() {
        beginLogin(
            method: .institution,
            url: OReillyWebScripts.institutionAccessURL,
            status: AppLocalized("请选择你的学校、公司或图书馆")
        )
    }

    func openPeninsulaLibrarySystem() {
        beginLogin(
            method: .institution,
            url: OReillyWebScripts.peninsulaLibrarySystemAccessURL,
            status: AppLocalized("请完成 O’Reilly 登录")
        )
    }

    func openInstitutionAccessURL(_ url: URL) {
        guard OReillyWebScripts.allowsInstitutionEntryURL(url) else {
            errorText = AppLocalized(
                "这个链接不是有效的 O’Reilly 机构访问地址。"
            )
            return
        }
        beginLogin(
            method: .institution,
            url: url,
            status: AppLocalized("请完成 O’Reilly 登录")
        )
    }

    func openCatalogToChooseBook() {
        guard let homeURL = OReillyWebScripts.homeURL(for: webView.url)
        else {
            errorText = AppLocalized("内容暂时无法打开，请重试")
            return
        }
        probeGeneration += 1
        workTask?.cancel()
        workTask = nil
        catalogReturnTask?.cancel()
        catalogReturnTask = nil
        catalogMonitorTask?.cancel()
        catalogMonitorTask = nil
        isScanningShelf = false
        needsHistorySeed = false
        isBrowsingCatalog = true
        canSync = false
        isWorking = false
        errorText = nil
        statusText = AppLocalized("O’Reilly Learning")
        detailText = AppLocalized(
            "打开书籍后会自动返回并更新阅读历史。"
        )
        popupWebView?.stopLoading()
        popupWebView = nil
        webView.load(URLRequest(url: homeURL))
        startCatalogSelectionMonitor()
    }

    func returnToHistoryAndSync() {
        guard let historyURL = OReillyWebScripts.historyURL(
            for: webView.url
        ) else {
            errorText = AppLocalized("内容暂时无法打开，请重试")
            return
        }
        catalogReturnTask?.cancel()
        catalogReturnTask = nil
        catalogMonitorTask?.cancel()
        catalogMonitorTask = nil
        isBrowsingCatalog = false
        needsHistorySeed = false
        canSync = false
        popupWebView?.stopLoading()
        popupWebView = nil
        webView.load(URLRequest(url: historyURL))
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
            didSync = true
            canSync = false
            needsHistorySeed = false
            statusText = AppLocalized("O’Reilly 阅读历史已同步")
            detailText = String(
                format: AppLocalized("已同步 %d 本书。"),
                store.books.count
            )
            connectionAnalytics.record(
                .syncCompleted,
                result: .success,
                bookCount: store.books.count
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        updateCredentialState(webView.url)
        if webView === self.webView,
           OReillyWebScripts.isShelfURL(webView.url) {
            presentShelfLoading()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateCredentialState(webView.url)
        if webView === self.webView,
           OReillyWebScripts.isShelfURL(webView.url) {
            presentShelfLoading()
            ReaderRunLog.write(
                "OREILLY history committed; session probe scheduled"
            )
            scheduleProbe(delayNanoseconds: 100_000_000)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateCredentialState(webView.url)

        if webView === popupWebView,
           isBrowsingCatalog,
           let url = webView.url,
           OReillyBookValidator.contentID(from: url) != nil {
            popupWebView = nil
            hasOpenedWebPage = true
            self.webView.load(URLRequest(url: url))
            return
        }

        if webView === popupWebView,
           let historyURL = OReillyWebScripts.historyURL(for: webView.url),
           shouldEnterHistory(from: webView.url) {
            popupWebView = nil
            hasOpenedWebPage = true
            self.webView.load(URLRequest(url: historyURL))
            return
        }

        guard webView === self.webView || popupWebView == nil else {
            refreshCredentialPageState(in: webView)
            return
        }

        if OReillyWebScripts.isShelfURL(webView.url) {
            presentShelfLoading()
            scheduleProbe(delayNanoseconds: 100_000_000)
            return
        }

        if isBrowsingCatalog {
            isCredentialPage = true
            if let url = webView.url,
               OReillyBookValidator.contentID(from: url) != nil {
                scheduleHistoryRefreshAfterOpeningBook()
            }
            return
        }

        if let historyURL = OReillyWebScripts.historyURL(for: webView.url),
           shouldEnterHistory(from: webView.url) {
            let host = historyURL.host?.lowercased() ?? ""
            if !redirectedHistoryHosts.contains(host) {
                redirectedHistoryHosts.insert(host)
                statusText = AppLocalized("登录成功，正在进入阅读历史…")
                detailText = AppLocalized("正在查找你最近阅读的书。")
                self.webView.load(URLRequest(url: historyURL))
                return
            }
        }
        refreshCredentialPageState(in: webView)
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
        guard OReillyWebScripts.allowsBindingNavigation(
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
              OReillyWebScripts.allowsBindingNavigation(url) else {
            return nil
        }
        configuration.websiteDataStore = OReillyWebSession.websiteDataStore
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
        isCredentialPage = true
        statusText = AppLocalized("正在确认 O’Reilly 登录…")
        detailText = AppLocalized("登录完成后会自动进入阅读历史。")
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
        isWorking = false
        errorText = AppLocalized("内容暂时无法打开，请重试")
    }

    private func beginLogin(
        method: LoginMethod,
        url: URL,
        status: String
    ) {
        connectionAnalytics.record(.loginStarted, result: .started)
        probeGeneration += 1
        workTask?.cancel()
        workTask = nil
        catalogReturnTask?.cancel()
        catalogReturnTask = nil
        catalogMonitorTask?.cancel()
        catalogMonitorTask = nil
        pendingBooks = [:]
        pendingAccount = nil
        canSync = false
        didSync = false
        needsHistorySeed = false
        isBrowsingCatalog = false
        errorText = nil
        loginMethod = method
        hasChosenLoginMethod = true
        hasOpenedWebPage = true
        isCredentialPage = true
        isWorking = false
        redirectedHistoryHosts = []
        statusText = status
        detailText =
            AppLocalized("登录页面会使用完整空间，CastReader 不会保存密码。")
        popupWebView?.stopLoading()
        popupWebView = nil
        webView.load(URLRequest(url: url))
    }

    private func updateCredentialState(_ url: URL?) {
        if OReillyWebScripts.isShelfURL(url) {
            isCredentialPage = false
            if !didSync {
                presentShelfLoading()
            }
            return
        }
        guard hasChosenLoginMethod else {
            isCredentialPage = false
            return
        }
        isCredentialPage = OReillyWebScripts.isLikelyCredentialURL(url)
            || loginMethod != nil
        if isCredentialPage {
            isWorking = false
            detailText =
                AppLocalized("登录页面会使用完整空间，完成后自动读取阅读历史。")
        }
    }

    private func refreshCredentialPageState(in target: WKWebView) {
        target.evaluateJavaScript(
            OReillyWebScripts.credentialPageProbe
        ) { [weak self, weak target] value, _ in
            Task { @MainActor [weak self, weak target] in
                guard let self, target != nil,
                      !OReillyWebScripts.isShelfURL(target?.url) else {
                    return
                }
                if value as? Bool == true {
                    self.isCredentialPage = true
                    self.isWorking = false
                    self.statusText =
                        AppLocalized("请完成 O’Reilly 登录")
                    self.detailText =
                        AppLocalized("登录页面会使用完整空间，完成后自动进入阅读历史。")
                }
            }
        }
    }

    private func shouldEnterHistory(from url: URL?) -> Bool {
        guard hasChosenLoginMethod,
              !isBrowsingCatalog,
              let url,
              OReillyWebAccessPolicy.isAllowedReaderHost(
                  url.host?.lowercased() ?? ""
              ),
              !OReillyWebScripts.isShelfURL(url),
              !OReillyWebScripts.isLikelyCredentialURL(url) else {
            return false
        }
        return true
    }

    private func scheduleHistoryRefreshAfterOpeningBook() {
        guard isBrowsingCatalog else { return }
        catalogMonitorTask?.cancel()
        catalogMonitorTask = nil
        catalogReturnTask?.cancel()
        statusText = AppLocalized("O’Reilly Learning")
        detailText = AppLocalized(
            "打开书籍后会自动返回并更新阅读历史。"
        )
        catalogReturnTask = Task { @MainActor [weak self] in
            var readerIsReady = false
            for _ in 0..<80 {
                guard let self,
                      !Task.isCancelled,
                      self.isBrowsingCatalog else {
                    return
                }
                if await self.openedBookReaderIsReady() {
                    readerIsReady = true
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            guard let self,
                  !Task.isCancelled,
                  self.isBrowsingCatalog else {
                return
            }
            guard readerIsReady else {
                self.isCredentialPage = false
                self.needsHistorySeed = true
                self.statusText = AppLocalized("暂无阅读历史")
                self.detailText = AppLocalized(
                    "请先在 O’Reilly 打开一本书，再返回同步阅读历史。"
                )
                self.errorText = AppLocalized("内容暂时无法打开，请重试")
                return
            }

            // The reader DOM can be ready before O'Reilly's History analytics
            // request has persisted. Keep the loaded book alive briefly
            // instead of navigating away as soon as its SPA URL changes.
            self.statusText = AppLocalized("正在同步 O’Reilly 阅读历史…")
            self.detailText = AppLocalized("正在查找你最近阅读的书。")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self.isBrowsingCatalog else { return }
            self.returnToHistoryAndSync()
        }
    }

    private func openedBookReaderIsReady() async -> Bool {
        guard let url = webView.url,
              OReillyBookValidator.contentID(from: url) != nil else {
            return false
        }
        do {
            let value = try await webView.evaluateJavaScript(
                OReillyWebScripts.readerReadyProbe
            )
            return value as? Bool == true
        } catch {
            return false
        }
    }

    private func startCatalogSelectionMonitor() {
        catalogMonitorTask?.cancel()
        catalogMonitorTask = Task { @MainActor [weak self] in
            // O'Reilly's search can use History API navigation, which does
            // not always produce a WKNavigationDelegate didFinish callback.
            // WKWebView.url still tracks that route, so watch it while the
            // user is actively choosing a book.
            for _ in 0..<1_800 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self,
                      !Task.isCancelled,
                      self.isBrowsingCatalog else {
                    return
                }
                if let url = self.webView.url,
                   OReillyBookValidator.contentID(from: url) != nil {
                    self.scheduleHistoryRefreshAfterOpeningBook()
                    return
                }
            }
        }
    }

    private func presentShelfLoading() {
        guard !didSync else { return }
        isCredentialPage = false
        isWorking = true
        needsHistorySeed = false
        errorText = nil
        statusText = AppLocalized("正在同步 O’Reilly 阅读历史…")
        detailText =
            AppLocalized("页面会异步加载，请稍候，完成前不会显示 0 本。")
    }

    private func scheduleProbe(
        delayNanoseconds: UInt64 = 140_000_000
    ) {
        guard !isScanningShelf,
              !didSync,
              OReillyWebScripts.isShelfURL(webView.url) else {
            return
        }
        probeGeneration += 1
        let generation = probeGeneration
        workTask?.cancel()
        workTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self,
                  !Task.isCancelled,
                  generation == self.probeGeneration else {
                return
            }
            await self.runSessionProbeLoop(generation: generation)
        }
    }

    private func recordNavigationError(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        isWorking = false
        errorText = AppLocalized("网络连接失败，请重试。")
    }

    private enum SessionProbeOutcome {
        case retry
        case finished
    }

    private func runSessionProbeLoop(generation: Int) async {
        for attempt in 0..<72 {
            guard !Task.isCancelled,
                  generation == probeGeneration else {
                return
            }
            if await probeSession(
                acceptSignedOutResult: attempt >= 12
            ) == .finished {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled,
              generation == probeGeneration else {
            return
        }
        isWorking = false
        errorText = AppLocalized("阅读历史仍在加载，请稍后重试。")
    }

    private func probeSession(
        acceptSignedOutResult: Bool
    ) async -> SessionProbeOutcome {
        guard OReillyWebScripts.isShelfURL(webView.url),
              let raw = await evaluate(OReillyWebScripts.sessionProbe),
              let dictionary = raw as? [String: Any] else {
            return .retry
        }
        let result = OReillyScanResult(dictionary, pageURL: webView.url)
        guard result.authenticated else {
            isSignedIn = false
            canSync = false
            if result.authRequired, acceptSignedOutResult {
                isWorking = false
                isCredentialPage = false
                hasChosenLoginMethod = false
                loginMethod = nil
                statusText = AppLocalized("O’Reilly 登录已失效")
                detailText =
                    AppLocalized("请重新选择个人账户或机构访问。")
                return .finished
            }
            presentShelfLoading()
            return .retry
        }

        isSignedIn = true
        connectionAnalytics.record(.loginSucceeded, result: .success)
        isCredentialPage = false
        statusText = AppLocalized("正在同步 O’Reilly 阅读历史…")
        detailText = AppLocalized("正在等待书目完整加载，请稍候。")
        ReaderRunLog.write("OREILLY history authenticated; scan started")
        isScanningShelf = true
        await scanShelf()
        isScanningShelf = false
        return .finished
    }

    private func scanShelf() async {
        isWorking = true
        pendingBooks = [:]
        pendingAccount = nil
        stableEndPasses = 0
        previousStableCount = -1

        for attempt in 0..<48 {
            guard !Task.isCancelled,
                  OReillyWebScripts.isShelfURL(webView.url),
                  let raw = await evaluate(OReillyWebScripts.libraryScan),
                  let dictionary = raw as? [String: Any] else {
                break
            }
            let result = OReillyScanResult(
                dictionary,
                pageURL: webView.url
            )
            guard result.authenticated,
                  let evidence = result.account else {
                break
            }
            result.books.forEach { book in
                pendingBooks[book.id] = OReillyBookMetadata.merged(
                    existing: pendingBooks[book.id],
                    incoming: book
                )
            }
            let account = OReillyAccountInfo(label: evidence)
            pendingAccount = account

            if attempt == 0 {
                ReaderRunLog.write(
                    "OREILLY history first scan books=" +
                        "\(pendingBooks.count) complete=" +
                        "\(result.isCompleteSnapshot ? "Y" : "N")"
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

            if OReillyShelfSyncContract.canCommit(
                bookCount: pendingBooks.count,
                account: account,
                reachedEnd: result.isCompleteSnapshot,
                stableEndPasses: stableEndPasses
            ) {
                if OReillyShelfSyncContract.requiresCatalogSeed(
                    scannedBookCount: pendingBooks.count,
                    existingBookCount: store.books.count,
                    isExistingAccount:
                        store.accountIdentity == account.identity
                ) {
                    canSync = false
                    isWorking = false
                    needsHistorySeed = true
                    errorText = nil
                    statusText = AppLocalized("暂无阅读历史")
                    detailText = AppLocalized(
                        "请先在 O’Reilly 打开一本书，再返回同步阅读历史。"
                    )
                    ReaderRunLog.write(
                        "OREILLY history empty; catalog seed required"
                    )
                    return
                }
                canSync = true
                isWorking = false
                needsHistorySeed = false
                statusText = AppLocalized("O’Reilly 阅读历史已加载")
                detailText = String(
                    format: AppLocalized("找到 %d 本书，可以同步。"),
                    pendingBooks.count
                )
                ReaderRunLog.write(
                    "OREILLY history ready books=\(pendingBooks.count) " +
                        "stable=\(stableEndPasses)"
                )
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        isWorking = false
        canSync = false
        errorText = AppLocalized("阅读历史仍在加载，请稍后重试。")
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
