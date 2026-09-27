import Foundation

@MainActor
final class AO3LibraryStore: ObservableObject {
    static let shared = AO3LibraryStore()
    @Published private(set) var books: [AO3Book] = []
    @Published private(set) var accountLabel: String?
    @Published var lastError: String?
    @Published var isRefreshing = false
    @Published private(set) var revision = UUID()
    private var storageID: String?
    private let defaults: UserDefaults
    private let history: HistoryStore
    private struct Saved: Codable { var account: String; var books: [AO3Book] }

    init(defaults: UserDefaults = .standard, history: HistoryStore = .shared, storageID: String? = nil) {
        self.defaults = defaults; self.history = history; self.storageID = storageID
        load()
    }
    var needsConnection: Bool { accountLabel == nil }
    var homeBooks: [AO3Book] {
        Array(books.enumerated().sorted {
            let lhs = $0.element.lastOpenedAt ?? .distantPast
            let rhs = $1.element.lastOpenedAt ?? .distantPast
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element).prefix(8))
    }
    private var key: String? { storageID.map { "ao3.library.v1.\($0)" } }
    func activateAccountScope(_ scope: AccountContentScope) { activate(storageID: scope.storageID) }
    func deactivateAccountScope() { activate(storageID: nil) }
    #if DEBUG
    func activateLegacyTestingScope() { activate(storageID: "debug-legacy") }
    #endif
    private func activate(storageID: String?) {
        guard self.storageID != storageID else { return }
        self.storageID = storageID; revision = UUID(); load()
    }
    private func load() {
        books = []; accountLabel = nil; lastError = nil; isRefreshing = false
        guard let key, let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), AO3URLPolicy.validAccount(saved.account) else { return }
        accountLabel = saved.account
        books = saved.books.filter { $0.account == saved.account && AO3URLPolicy.workID($0.readerURL) == $0.workID }
    }
    private func save() {
        guard let key, let accountLabel, let data = try? JSONEncoder().encode(Saved(account: accountLabel, books: books)) else { return }
        defaults.set(data, forKey: key)
    }
    /// A failed/partial scan must never erase a previously synced library.
    /// A complete scan replaces membership, retaining local listening anchors.
    @discardableResult
    func merge(_ snapshot: AO3ShelfSnapshot, complete: Bool, expectedRevision: UUID) -> Bool {
        guard revision == expectedRevision, key != nil, snapshot.isHistory,
              AO3URLPolicy.validAccount(snapshot.account),
              snapshot.books.allSatisfy({ $0.account == snapshot.account && AO3URLPolicy.workID($0.readerURL) == $0.workID && !$0.title.isEmpty }) else { return false }
        if let current = accountLabel, current.lowercased() != snapshot.account.lowercased() {
            // A new AO3 identity starts a new local shelf; never combine accounts.
            revision = UUID()
            books.forEach { history.delete($0.id) }
            books = []
        }
        accountLabel = snapshot.account
        let old = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var incoming = snapshot.books.filter { seen.insert($0.id).inserted }.map { value -> AO3Book in
            var book = value
            book.lastOpenedAt = old[book.id]?.lastOpenedAt
            book.position = old[book.id]?.position
            return book
        }
        if !complete { incoming += books.filter { !seen.contains($0.id) } }
        books = incoming; lastError = nil; save(); return true
    }
    func markOpened(_ book: AO3Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index].lastOpenedAt = Date(); save()
    }
    func book(for id: String) -> AO3Book? { books.first { $0.id == id } }
    func updatePosition(id: String, url: String, paragraph: Int, text: String) {
        guard let index = books.firstIndex(where: { $0.id == id }),
              AO3URLPolicy.workID(url) == books[index].workID else { return }
        let value = AO3Position(url: url, paragraph: max(0, paragraph), text: text)
        guard books[index].position != value else { return }
        books[index].position = value; save()
        history.updateSourceURL(documentID: id, sourceURL: url)
    }
    func disconnect() {
        books.forEach { history.delete($0.id) }
        if let key { defaults.removeObject(forKey: key) }
        revision = UUID(); books = []; accountLabel = nil; lastError = nil; isRefreshing = false
    }
}
