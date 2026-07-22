//
//  WeReadLibraryViews.swift
//  CastReader
//

import SwiftUI
import WebKit

struct WeReadHomeSection: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var store = WeReadLibraryStore.shared
    @State private var showConnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalized("微信读书")).font(.headline).foregroundColor(AppTheme.foreground)
                    Text(AppLocalized("已同步的微信读书书架")).font(.caption).foregroundColor(AppTheme.mutedForeground)
                }
                Spacer()
                if !store.needsConnection {
                    NavigationLink(destination: WeReadLibraryView()) {
                        Text(AppLocalized("查看全部")).font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.primary)
                    }
                }
            }

            if store.needsConnection {
                Button { showConnect = true } label: { connectCard }.buttonStyle(.plain)
                    .accessibilityIdentifier("connectWeReadButton")
            } else if store.homeBooks.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise").foregroundColor(AppTheme.primary)
                    Text(AppLocalized("还没有同步书籍")).font(.subheadline).foregroundColor(AppTheme.foreground)
                    Spacer()
                    Button(AppLocalized("同步")) { showConnect = true }.font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.primary)
                }
                .padding(14).background(AppTheme.surface).cornerRadius(16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(store.homeBooks) { book in
                            Button { open(book) } label: { WeReadBookRailCard(book: book) }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4).padding(.horizontal, 2)
                }.padding(.horizontal, -2)
            }
        }
        .sheet(isPresented: $showConnect) { WeReadLibraryConnectView() }
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
        let document = ReadingDocument(id: book.id, title: book.title, sourceKind: .weread,
                                       language: Constants.TTS.defaultLanguage, paragraphs: [], sourceURL: book.effectiveReaderURL)
        coordinator.open(document, mode: .read, autoplay: false)
    }
}

struct WeReadLibraryConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = WeReadLibrarySyncViewModel()

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                WeReadWebView(webView: model.webView).ignoresSafeArea(edges: .bottom)
                if model.showsSyncBar {
                    syncBar
                }
            }
            .navigationTitle(AppLocalized("绑定微信读书")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("关闭")) { dismiss() } }
            }
            .onAppear {
                model.updateTheme(isDark: colorScheme == .dark)
                model.loadIfNeeded()
            }
            .onChange(of: colorScheme) { _, scheme in
                model.updateTheme(isDark: scheme == .dark)
            }
            .onDisappear { model.stop() }
        }.navigationViewStyle(.stack)
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
                            Text(model.statusText).font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.foreground).lineLimit(2)
                            Text(model.secondaryStatus).font(.caption).foregroundColor(AppTheme.mutedForeground).lineLimit(1)
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
        coordinator.open(ReadingDocument(id: book.id, title: book.title, sourceKind: .weread, language: Constants.TTS.defaultLanguage, paragraphs: [], sourceURL: book.effectiveReaderURL))
    }
}

private struct WeReadBookRailCard: View {
    let book: WeReadBook
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
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
        if let urlString, let url = URL(string:urlString) {
            AsyncImage(url:url) { phase in
                switch phase { case .success(let image): image.resizable().scaledToFill(); case .empty: placeholder.overlay { ProgressView().scaleEffect(0.75) }; default: placeholder }
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
final class WeReadLibrarySyncViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isScanning = false
    @Published var isSyncing = false
    @Published var showsSyncBar = false
    @Published var availableCount = 0
    @Published var statusText = AppLocalized("打开微信读书并登录。")
    @Published var errorText: String?
    let webView: WKWebView
    private let store = WeReadLibraryStore.shared
    private var didLoad = false
    private var pendingBooks: [String: WeReadBook] = [:]
    private var pendingAccount: WeReadAccountInfo?
    private var loginPollingTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var isDarkMode = false

    var secondaryStatus: String {
        if availableCount > 0 {
            return String(format: AppLocalized("书架中有 %d 本书可以同步"), availableCount)
        }
        if store.books.isEmpty { return AppLocalized("登录成功后将自动进入书架。") }
        return String(format: AppLocalized("已在本机同步 %d 本书。"), store.books.count)
    }

    override init() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .default(); config.defaultWebpagePreferences.preferredContentMode = .desktop
        webView = WKWebView(frame:.zero, configuration:config); super.init()
        webView.customUserAgent = WeReadWebScripts.desktopUserAgent; webView.navigationDelegate = self
    }

    func updateTheme(isDark: Bool) {
        let changed = isDarkMode != isDark
        isDarkMode = isDark
        webView.overrideUserInterfaceStyle = isDark ? .dark : .light
        guard changed, didLoad, let currentURL = webView.url else { return }
        previewTask?.cancel()
        loginPollingTask?.cancel()
        loginPollingTask = nil
        WeReadNativeTheme.prepare(webView, isDark: isDark) { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.statusText = AppLocalized("正在打开微信读书书架…")
            webView.load(URLRequest(url: WeReadNativeTheme.themedURL(currentURL, isDark: isDark)))
        }
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
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

    func stop() {
        loginPollingTask?.cancel()
        loginPollingTask = nil
        previewTask?.cancel()
        previewTask = nil
    }

    func syncLibrary() async -> Bool {
        guard !isSyncing else { return false }
        if pendingBooks.isEmpty { await refreshPreview() }
        guard !pendingBooks.isEmpty else { return false }
        isSyncing = true
        errorText = nil
        defer { isSyncing = false }
        store.mergeScrapedBooks(Array(pendingBooks.values), account: pendingAccount)
        statusText = String(format: AppLocalized("已同步 %d 本微信读书书籍。"), pendingBooks.count)
        return true
    }

    private func handleFinishedPage() async {
        guard let result = try? await evaluate(WeReadWebScripts.libraryScan) else {
            startLoginPolling()
            return
        }
        if result.authRequired || !result.authenticated {
            resetUnauthenticatedPreview()
            statusText = AppLocalized("请先登录微信读书，登录后会自动进入书架。")
            startLoginPolling()
            return
        }
        loginPollingTask?.cancel()
        if !isShelfURL(webView.url) {
            showsSyncBar = false
            statusText = AppLocalized("正在打开微信读书书架…")
            webView.load(URLRequest(url: WeReadNativeTheme.themedURL(WeReadWebScripts.shelfURL, isDark: isDarkMode)))
            return
        }
        showsSyncBar = true
        await refreshPreview()
    }

    private func refreshPreview() async {
        guard !isScanning else { return }
        isScanning = true
        errorText = nil
        defer { isScanning = false }
        var all: [String: WeReadBook] = [:]
        var idle = 0
        var account: WeReadAccountInfo?
        for pass in 0..<9 {
            guard !Task.isCancelled else { return }
            statusText = String(format: AppLocalized("正在扫描微信读书书架…（%d）"), all.count)
            guard let result = try? await evaluate(WeReadWebScripts.libraryScan) else { continue }
            if result.authRequired || !result.authenticated {
                resetUnauthenticatedPreview()
                statusText = AppLocalized("请先登录微信读书，登录后会自动进入书架。")
                startLoginPolling()
                return
            }
            if let label = result.account { account = WeReadAccountInfo(label: label) }
            let before = all.count
            result.books.forEach { all[$0.id] = $0 }
            pendingBooks = all
            pendingAccount = account
            availableCount = all.count
            idle = all.count == before ? idle + 1 : 0
            if pass >= 2 && idle >= 2 { break }
            _ = try? await webView.evaluateJavaScript("window.scrollBy({top:Math.max(window.innerHeight*.82,520),behavior:'auto'})")
            try? await Task.sleep(for: .milliseconds(650))
        }
        guard !all.isEmpty else {
            errorText = AppLocalized("没有找到书架书籍。请在微信读书网页的书架页登录后重试。")
            return
        }
        statusText = String(format: AppLocalized("已找到 %d 本微信读书书籍。"), all.count)
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
                if self.isShelfURL(self.webView.url) {
                    self.showsSyncBar = true
                    await self.refreshPreview()
                } else {
                    self.showsSyncBar = false
                    self.webView.load(URLRequest(url: WeReadNativeTheme.themedURL(WeReadWebScripts.shelfURL, isDark: self.isDarkMode)))
                }
                return
            }
        }
    }

    private func isShelfURL(_ url: URL?) -> Bool {
        guard let url, url.host?.lowercased().hasSuffix("weread.qq.com") == true else { return false }
        return url.path.lowercased().contains("shelf")
    }

    private func resetUnauthenticatedPreview() {
        showsSyncBar = false
        availableCount = 0
        pendingBooks = [:]
        pendingAccount = nil
        errorText = nil
    }

    private func evaluate(_ js: String) async throws -> WeReadScanResult {
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in if let error { continuation.resume(throwing:error) } else { continuation.resume(returning:value as Any) } }
        }
        guard let raw = value as? [String:Any] else { throw NSError(domain:"WeRead",code:1) }
        return WeReadScanResult(raw)
    }
}
