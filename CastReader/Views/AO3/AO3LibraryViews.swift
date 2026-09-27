import SwiftUI
import WebKit

@MainActor
enum AO3ReaderLauncher {
    static func open(_ book: AO3Book, using coordinator: PlayerCoordinator, autoplay: Bool = false, store: AO3LibraryStore = .shared) {
        guard let latest = store.book(for: book.id) else { return }
        store.markOpened(latest)
        coordinator.open(ReadingDocument(id: latest.id, title: latest.title, sourceKind: .web,
                                         paragraphs: [], sourceURL: latest.effectiveReaderURL),
                         mode: .read, autoplay: autoplay)
    }
}

struct AO3HomeSection: View {
    @EnvironmentObject private var player: PlayerCoordinator
    @ObservedObject private var store = AO3LibraryStore.shared
    var body: some View {
        if !store.needsConnection {
            VStack(alignment: .leading, spacing: HomeLayout.headerToContent) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AO3").font(.headline)
                        Text(AppLocalized("最近阅读 · 继续收听")).font(.caption).foregroundColor(AppTheme.mutedForeground)
                    }
                    Spacer()
                    NavigationLink(AppLocalized("查看全部")) { AO3LibraryView() }
                        .accessibilityIdentifier("homeShelfViewAll.ao3")
                }
                if store.homeBooks.isEmpty {
                    Text(AppLocalized("阅读历史为空。到 AO3 打开一部作品后，重新同步。"))
                        .font(.caption).foregroundColor(AppTheme.mutedForeground)
                } else {
                    HomeHorizontalRail(alignment: .top) {
                        ForEach(store.homeBooks) { book in
                            Button { AO3ReaderLauncher.open(book, using: player) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12).fill(AppTheme.primary.opacity(0.10))
                                        VStack(spacing: 12) {
                                            Image(systemName: "book.pages").font(.largeTitle)
                                            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(4)
                                        }.padding(12).foregroundColor(AppTheme.primary)
                                    }.frame(width: 132, height: 170)
                                    Text(book.author).font(.caption).lineLimit(1)
                                    Text(book.position == nil ? book.chapterCount : AppLocalized("继续听"))
                                        .font(.caption2).foregroundColor(AppTheme.mutedForeground)
                                }.frame(width: 132, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("homeShelfBook.ao3.\(book.workID)")
                        }
                    }
                }
            }.accessibilityIdentifier("homeShelfSection.ao3")
        }
    }
}

struct AO3LibraryView: View {
    @EnvironmentObject private var player: PlayerCoordinator
    @ObservedObject private var store = AO3LibraryStore.shared
    @State private var query = ""
    @State private var connecting = false
    var body: some View {
        List {
            Section {
                Text(AppLocalized("同步 AO3 阅读历史；章节与收听位置保存在 CastReader。"))
                    .font(.caption).foregroundColor(AppTheme.mutedForeground)
                if let error = store.lastError { Text(error).font(.caption).foregroundColor(.red) }
            }
            ForEach(store.books.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }) { book in
                Button { AO3ReaderLauncher.open(book, using: player) } label: {
                    HStack {
                        Image(systemName: "book.pages").foregroundColor(AppTheme.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).foregroundColor(AppTheme.foreground)
                            Text(book.author).font(.caption).foregroundColor(AppTheme.mutedForeground)
                            Text(book.position == nil ? book.chapterCount : AppLocalized("继续听"))
                                .font(.caption2).foregroundColor(AppTheme.primary)
                        }
                        Spacer()
                        Image(systemName: "play.circle").foregroundColor(AppTheme.primary)
                    }
                }.accessibilityIdentifier("ao3LibraryBook.\(book.workID)")
            }
            if store.books.isEmpty { Text(AppLocalized("阅读历史为空。到 AO3 打开一部作品后，重新同步。")) }
        }
        .searchable(text: $query)
        .navigationTitle("AO3")
        .toolbar { Button { connecting = true } label: { Image(systemName: "arrow.clockwise") }.accessibilityIdentifier("ao3Sync") }
        .sheet(isPresented: $connecting) { AO3LibraryConnectView() }
    }
}

struct AO3LibraryConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AO3ConnectionModel()
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if model.scanning { ProgressView() }
                    Text(model.status).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    Button(AppLocalized("重新同步")) { model.start() }.disabled(model.scanning)
                }.padding(12).background(AppTheme.background)
                AO3Browser(webView: model.webView)
            }
            .navigationTitle("AO3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("完成")) { dismiss() } } }
        }
        .navigationViewStyle(.stack)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .accessibilityIdentifier("ao3Connection")
    }
}

private struct AO3Browser: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class AO3ConnectionModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var status = AppLocalized("请在 AO3 官网登录，随后自动同步阅读历史。")
    @Published var scanning = false
    private let store: AO3LibraryStore
    private var token = UUID()
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var account: String?
    private var collected: [AO3Book] = []
    private var visited = Set<String>()
    private var completed = false
    private var active = false

    init(store: AO3LibraryStore = .shared, makeWebView: (WKWebViewConfiguration) -> WKWebView = {
        WKWebView(frame: .zero, configuration: $0)
    }) {
        self.store = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = CommercialWebSession.websiteDataStore
        webView = makeWebView(config)
        super.init()
        webView.navigationDelegate = self
        webView.accessibilityIdentifier = "ao3LoginWebView"
    }
    func start() {
        stop(); revision = store.revision; token = UUID(); completed = false; active = true
        account = nil; collected = []; visited = []
        status = AppLocalized("请在 AO3 官网登录，随后自动同步阅读历史。")
        let url = store.accountLabel.flatMap { AO3URLPolicy.historyURL(account: $0) }
            ?? URL(string: "https://archiveofourown.org/users/login")!
        webView.load(URLRequest(url: url))
        let current = token
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.token == current, self.store.revision == self.revision, !self.completed else { return }
                if !self.webView.isLoading { await self.inspect(current) }
            }
        }
    }
    func stop() {
        active = false
        token = UUID(); task?.cancel(); task = nil; webView.stopLoading()
        scanning = false
        if store.revision == revision { store.isRefreshing = false }
    }
    private func inspect(_ current: UUID) async {
        guard let raw = try? await webView.evaluateJavaScript(AO3WebScripts.shelf),
              token == current, store.revision == revision,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let snapshot = try? JSONDecoder().decode(AO3ShelfSnapshot.self, from: data),
              AO3URLPolicy.validAccount(snapshot.account) else { return }
        if let account, account.lowercased() != snapshot.account.lowercased() {
            fail(AppLocalized("AO3 账号已改变，请重新同步。")); return
        }
        account = snapshot.account
        if !snapshot.isHistory {
            guard let url = AO3URLPolicy.historyURL(account: snapshot.account) else { return }
            status = AppLocalized("正在打开阅读历史…")
            webView.load(URLRequest(url: url)); return
        }
        guard let page = webView.url?.absoluteString,
              AO3URLPolicy.isHistoryURL(page, account: snapshot.account), visited.insert(page).inserted else { return }
        scanning = true; store.isRefreshing = true
        collected += snapshot.books
        status = String(format: AppLocalized("已找到 %d 部作品，正在同步…"), Set(collected.map(\.id)).count)
        if let next = snapshot.nextURL {
            guard AO3URLPolicy.isHistoryURL(next, account: snapshot.account), !visited.contains(next) else {
                fail(AppLocalized("阅读历史分页暂不可用，请重新同步。")); return
            }
            if visited.count < 25 {
                webView.load(URLRequest(url: URL(string: next)!)); return
            }
        }
        finish(complete: snapshot.nextURL == nil)
    }
    private func finish(complete: Bool) {
        guard let account, store.revision == revision else { return }
        let snapshot = AO3ShelfSnapshot(account: account, isHistory: true, books: collected)
        guard store.merge(snapshot, complete: complete, expectedRevision: revision) else { return }
        completed = true; scanning = false; store.isRefreshing = false
        status = complete ? String(format: AppLocalized("已同步 %d 部作品，可以从首页打开。"), store.books.count)
            : AppLocalized("已同步最近 25 页阅读历史，较早的本地作品已保留。")
    }
    private func fail(_ message: String) {
        guard active, !completed, store.revision == revision else { return }
        if !collected.isEmpty { finish(complete: false) }
        completed = true; scanning = false; store.isRefreshing = false
        status = message; store.lastError = message
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        decisionHandler(AO3URLPolicy.siteURL(action.request.url?.absoluteString) == nil ? .cancel : .allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail(AppLocalized("AO3 暂时无法连接，请重新同步。")) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail(AppLocalized("AO3 暂时无法连接，请重新同步。")) }
    }
}
