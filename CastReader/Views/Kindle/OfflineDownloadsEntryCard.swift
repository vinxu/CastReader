import SwiftUI

/// Always reachable independently of a platform's authentication or WebView.
/// Counts describe saved manifests, never the online bookshelf or reachability.
@MainActor
struct OfflineDownloadsEntryCard: View {
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var library = KindleLibraryStore.shared
    @ObservedObject private var network = NetworkReachability.shared
    @State private var books: [KindleOfflineBook] = []
    @State private var loadedScope: String?
    @State private var readFailed = false
    let store: KindleOfflineBookStore
    let scopeProvider: @MainActor () -> String?
    init(store: KindleOfflineBookStore = .shared,
         scopeProvider: @escaping @MainActor () -> String? = { KindleOfflineContext.currentScope }) {
        self.store = store; self.scopeProvider = scopeProvider
    }
    private var currentBooks: [KindleOfflineBook] { loadedScope == scopeProvider() ? books : [] }
    private var completeCount: Int { currentBooks.filter { $0.status == .complete }.count }
    private var partialCount: Int { currentBooks.count - completeCount }
    var body: some View {
        NavigationLink {
            KindleOfflineLibraryView(store: store, scopeProvider: scopeProvider)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(.teal)
                    .frame(width: 50, height: 54)
                    .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("已下载").font(.headline).foregroundStyle(AppTheme.foreground)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        if completeCount > 0 {
                            Text("\(completeCount) 本").font(.caption.weight(.medium)).foregroundStyle(.teal)
                        }
                    }
                    Text(network.isOnline ? "保存在本机，没网也能读和听" : "当前无网络，打开本机书籍")
                        .font(.caption).foregroundStyle(AppTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    if partialCount > 0 {
                        Text("\(partialCount) 本尚未下载完成").font(.caption).foregroundStyle(.secondary)
                    } else if readFailed {
                        Text("点此检查本机副本").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.teal.opacity(0.28), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain).accessibilityIdentifier("homeDownloads")
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task(id: scopeProvider()) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: KindleOfflineBookStore.didChange).receive(on: RunLoop.main)) { notification in
            guard notification.object as? KindleOfflineBookStore === store,
                  notification.userInfo?["scope"] as? String == scopeProvider() else { return }
            Task { await refresh() }
        }
    }
    private func refresh() async {
        let scope = scopeProvider()
        guard let scope else { books = []; loadedScope = nil; readFailed = false; return }
        do {
            let result = try await store.list(scope: scope)
            guard scopeProvider() == scope, !Task.isCancelled else { return }
            books = result; loadedScope = scope; readFailed = false
        } catch {
            guard scopeProvider() == scope, !Task.isCancelled else { return }
            books = []; loadedScope = scope; readFailed = true
        }
    }
}
