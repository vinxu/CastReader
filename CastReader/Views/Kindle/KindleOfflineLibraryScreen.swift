import SwiftUI

@MainActor
struct KindleOfflineLibraryView: View {
    @ObservedObject private var library = KindleLibraryStore.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var books: [KindleOfflineBook] = []
    @State private var unreadableIDs: [String] = []
    @State private var loading = true
    @State private var loadedScope: String?
    @State private var refreshID = UUID()
    @State private var error: String?
    @State private var query = ""
    @State private var deletion: Deletion?
    @State private var reading: ReadingSession?
    @State private var pendingResume: ReadingSession?
    let store: KindleOfflineBookStore
    private let scopeProvider: @MainActor () -> String?
    private let continueDownload: ((KindleOfflineBook) -> Void)?
    private var scope: String? { scopeProvider() }
    private struct Deletion: Identifiable { let id: String; let title: String; let scope: String }
    private struct ReadingSession: Identifiable {
        let id = UUID()
        let book: KindleOfflineBook
        let scope: String
    }

    init(store: KindleOfflineBookStore = .shared,
         scopeProvider: @escaping @MainActor () -> String? = { KindleOfflineContext.currentScope },
         continueDownload: ((KindleOfflineBook) -> Void)? = nil) {
        self.store = store; self.scopeProvider = scopeProvider; self.continueDownload = continueDownload
    }

    private var filtered: [KindleOfflineBook] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return books.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) || $0.author.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        List {
            if loading || scope != loadedScope { ProgressView("正在读取本机书籍…") }
            if let error {
                Section { Text(error).foregroundStyle(.red); Button("重新加载") { Task { await refresh() } } }
            }
            if !loading, scope == nil {
                ContentUnavailableView("请先连接 Kindle", systemImage: "person.crop.circle",
                    description: Text("连接后可查看此账号在本机保存的书籍。"))
            } else if !loading, books.isEmpty, unreadableIDs.isEmpty, error == nil {
                ContentUnavailableView("还没有离线书籍", systemImage: "arrow.down.circle",
                    description: Text("打开正在读的 Kindle 书，在“更多”中选择“离线保存整本书”。保存完成后，可从这里阅读和朗读。"))
                    .accessibilityIdentifier("offlineLibraryEmpty")
            } else if let scope, loadedScope == scope {
                Section {
                    Label("保存在这台设备，无需联网即可打开", systemImage: "iphone")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("\(books.count) 本 · \(ByteCountFormatter.string(fromByteCount: Int64(books.reduce(0) { $0 + $1.byteCount }), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(filtered) { book in
                    Section {
                        Button { reading = .init(book: book, scope: scope) } label: { bookLabel(book) }
                        .buttonStyle(.plain)
                        .disabled(book.pages.isEmpty)
                        .accessibilityIdentifier("offlineLibraryBook.\(book.sourceBookID)")
                        if book.status != .complete {
                            Button { resume(book, expectedScope: scope) } label: { Label("继续下载整本书", systemImage: "arrow.down.circle") }
                                .accessibilityIdentifier("offlineLibraryResume.\(book.sourceBookID)")
                        }
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { deletion = .init(id: book.id, title: book.title, scope: scope) }
                    }
                    .contextMenu {
                        if book.status != .complete { Button("继续下载整本书") { resume(book, expectedScope: scope) } }
                        Button("删除本机副本", role: .destructive) { deletion = .init(id: book.id, title: book.title, scope: scope) }
                    }
                }
                if !query.isEmpty, filtered.isEmpty { Text("没有找到匹配的离线书籍").foregroundStyle(.secondary) }
                ForEach(unreadableIDs, id: \.self) { id in
                    Section {
                        Label("有一份本机副本无法读取", systemImage: "exclamationmark.triangle")
                        Text("可以删除损坏的副本，再从 Kindle 重新保存。").font(.footnote).foregroundStyle(.secondary)
                        Button("删除损坏副本", role: .destructive) { deletion = .init(id: id, title: "无法读取的书籍", scope: scope) }
                    }
                }
            }
        }
        .navigationTitle("离线书籍").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索离线书名或作者")
        // Match the download screen's reader presentation so the root online
        // mini player and tab controls cannot cover local playback controls.
        .fullScreenCover(item: $reading, onDismiss: {
            guard let request = pendingResume else { return }
            pendingResume = nil
            resume(request.book, expectedScope: request.scope)
        }) { session in
            NavigationStack {
                KindleOfflineBookReaderView(book: session.book, scope: session.scope, store: store,
                    scopeValidator: { session.scope == scopeProvider() },
                    continueDownload: { pendingResume = session; reading = nil })
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { reading = nil }.accessibilityIdentifier("offlineBookClose")
                    } }
            }
        }
        .onChange(of: scope) { _, _ in pendingResume = nil; reading = nil }
        .task(id: scope) { await refresh() }
        .refreshable { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: KindleOfflineBookStore.didChange).receive(on: RunLoop.main)) { notification in
            guard notification.object as? KindleOfflineBookStore === store,
                  notification.userInfo?["scope"] as? String == scope else { return }
            Task { await refresh() }
        }
        .alert("删除本机副本？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
               presenting: deletion) { item in
            Button("删除本机副本", role: .destructive) {
                Task {
                    guard scope == item.scope else { return }
                    do { try await store.remove(id: item.id, scope: item.scope); await refresh() }
                    catch { self.error = "未能完全删除本机副本，请检查设备存储后重试。" }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("将移除《\(item.title)》的本机页面和离线阅读进度。Kindle 账号中的原书不受影响；再次离线阅读需要重新下载。")
        }
    }

    private func bookLabel(_ book: KindleOfflineBook) -> some View {
        HStack(spacing: 14) {
            Image(systemName: book.status == .complete ? "book.closed.fill" : "arrow.down.book.fill")
                .font(.title2).foregroundStyle(AppTheme.primary)
                .frame(width: 52, height: 72).background(AppTheme.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Label(book.status == .complete ? "整本已保存 · \(book.pages.count) 页" : "未完成 · 已保存 \(book.pages.count) 页",
                      systemImage: book.status == .complete ? "checkmark.circle.fill" : "pause.circle")
                    .font(.caption).foregroundStyle(book.status == .complete ? AppTheme.primary : .secondary)
                if book.hasLocalReadingPosition == true {
                    Text("上次读到第 \(book.readingPosition.page + 1) 页").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 4)
    }

    private func refresh() async {
        let expected = scope, request = UUID()
        refreshID = request
        loading = books.isEmpty; error = nil
        if loadedScope != expected { books = []; unreadableIDs = [] }
        guard let expected else { books = []; unreadableIDs = []; loadedScope = nil; loading = false; return }
        do {
            let saved = try await store.list(scope: expected)
            let unreadable = try await store.unreadableBookIDs(scope: expected)
            guard expected == scope, refreshID == request, !Task.isCancelled else { return }
            books = saved; unreadableIDs = unreadable; loadedScope = expected; loading = false
        } catch {
            guard expected == scope, refreshID == request, !Task.isCancelled else { return }
            books = []; unreadableIDs = []; loadedScope = expected; loading = false
            self.error = "本机书籍列表读取失败，已保存的文件仍保留。"
        }
    }

    private func resume(_ book: KindleOfflineBook, expectedScope: String) {
        guard expectedScope == scopeProvider() else { return }
        KindleRunLog.write("KINDLE_OFFLINE_ROUTE resume fixture=\(continueDownload != nil)")
        if let continueDownload { continueDownload(book); return }
        guard let source = library.boundBooks.first(where: { $0.id == book.sourceBookID }) ?? book.sourceBook else {
            error = "请先在 Kindle 书架同步这本书，再从“更多”继续离线保存。"; return
        }
        KindlePlaybackCenter.shared.openOfflineDownload(book: source)
    }
}
