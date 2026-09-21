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
    @ObservedObject private var playback = KindleOfflinePlaybackCenter.shared
    let store: KindleOfflineBookStore
    private let scopeProvider: @MainActor () -> String?
    private let continueDownload: ((KindleOfflineBook) -> Void)?
    private let onReaderPresented: (() -> Void)?
    private var scope: String? { scopeProvider() }
    private struct Deletion: Identifiable { let id: String; let title: String; let scope: String }

    init(store: KindleOfflineBookStore = .shared,
         scopeProvider: @escaping @MainActor () -> String? = { KindleOfflineContext.currentScope },
         onReaderPresented: (() -> Void)? = nil,
         continueDownload: ((KindleOfflineBook) -> Void)? = nil) {
        self.store = store; self.scopeProvider = scopeProvider; self.continueDownload = continueDownload
        self.onReaderPresented = onReaderPresented
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
                        .font(.footnote).foregroundStyle(.blue)
                    Text("\(books.count) 本 · \(ByteCountFormatter.string(fromByteCount: Int64(books.reduce(0) { $0 + $1.byteCount }), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(filtered) { book in
                    Section {
                        Button {
                            playback.open(book: book, scope: scope, store: store,
                                scopeValidator: { scope == scopeProvider() },
                                continueDownload: { resume(book, expectedScope: scope) })
                            onReaderPresented?()
                        } label: { bookLabel(book) }
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
                        Button("删除损坏副本", role: .destructive) { deletion = .init(id: id, title: AppLocalized("无法读取的书籍"), scope: scope) }
                    }
                }
            }
        }
        .reservesMiniPlayerSpace()
        .navigationTitle("已下载").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索离线书名或作者")
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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
                    catch { self.error = AppLocalized("未能完全删除本机副本，请检查设备存储后重试。") }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("将移除《\(item.title)》的本机页面和离线阅读进度。Kindle 账号中的原书不受影响；再次离线阅读需要重新下载。")
        }
    }

    private func bookLabel(_ book: KindleOfflineBook) -> some View {
        HStack(spacing: 14) {
            KindleOfflineCoverImage(book: book, width: 64, height: 94, prepare: { await prepareCover(book) }) {
                await loadCover(book)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Label(book.status == .complete ? AppLocalized("整本已保存 · \(book.pages.count) 页") : AppLocalized("未完成 · 已保存 \(book.pages.count) 页"),
                      systemImage: book.status == .complete ? "checkmark.circle.fill" : "pause.circle")
                    .font(.caption).foregroundStyle(book.status == .complete ? Color.blue : Color.orange)
                if book.hasLocalReadingPosition == true {
                    Text("上次读到第 \(book.readingPosition.page + 1) 页").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }.padding(.vertical, 4)
            .contentShape(Rectangle())
    }

    private func loadCover(_ book: KindleOfflineBook) async -> Data? {
        guard let expected = scope, loadedScope == expected else { return nil }
        let cached = try? await store.coverData(book: book, scope: expected)
        guard scope == expected, !Task.isCancelled else { return nil }
        return cached
    }

    private func prepareCover(_ book: KindleOfflineBook) async {
        guard let expected = scope, loadedScope == expected else { return }
        let source = library.boundBooks.first { $0.id == book.sourceBookID }
        try? await store.ensureCover(book: book, scope: expected, coverURL: source?.coverURL,
            allowNetwork: NetworkReachability.shared.isOnline)
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
            self.error = AppLocalized("本机书籍列表读取失败，已保存的文件仍保留。")
        }
    }

    private func resume(_ book: KindleOfflineBook, expectedScope: String) {
        guard expectedScope == scopeProvider() else { return }
        KindleRunLog.write("KINDLE_OFFLINE_ROUTE resume fixture=\(continueDownload != nil)")
        if let continueDownload { continueDownload(book); return }
        guard let source = library.boundBooks.first(where: { $0.id == book.sourceBookID }) ?? book.sourceBook else {
            error = AppLocalized("请先在 Kindle 书架同步这本书，再从“更多”继续离线保存。"); return
        }
        KindlePlaybackCenter.shared.openOfflineDownload(book: source)
        onReaderPresented?()
    }
}

/// Reads durable local bytes, never an AsyncImage URL that can disappear offline.
struct KindleOfflineCoverImage: View {
    let book: KindleOfflineBook
    let width: CGFloat
    let height: CGFloat
    var prepare: (@MainActor () async -> Void)? = nil
    let load: @MainActor () async -> Data?
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityIdentifier("offlineCover.\(book.sourceBookID)")
            } else {
                Image(systemName: "book.closed.fill").font(.title2).foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.blue.opacity(0.08))
            }
        }.frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityLabel(Text(book.title))
            .task(id: "\(book.id):\(book.generation):\(book.cover?.hash ?? "")") {
                let bytes = await load()
                guard !Task.isCancelled else { return }
                image = bytes.flatMap(UIImage.init(data:))
                // Show an existing fallback immediately, then upgrade it when
                // the real shelf cover becomes available again.
                if let prepare {
                    await prepare()
                    let fresh = await load()
                    guard !Task.isCancelled else { return }
                    image = fresh.flatMap(UIImage.init(data:))
                }
            }
    }
}
