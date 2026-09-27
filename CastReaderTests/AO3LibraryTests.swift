import XCTest
import WebKit
@testable import CastReader

@MainActor
final class AO3LibraryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!
    private var history: HistoryStore!
    override func setUp() async throws {
        suite = "ao3-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        history = HistoryStore(directory: directory)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func book(_ id: String, account: String = "Reader") -> AO3Book {
        AO3Book(workID: id, title: "Work \(id)", author: "Author", account: account, chapterCount: "3/5", readerURL: "https://archiveofourown.org/works/\(id)")
    }
    func testPartialSyncPreservesMembershipAndCompleteSyncKeepsListeningPosition() {
        let store = AO3LibraryStore(defaults: defaults, history: history, storageID: "account-A")
        XCTAssertTrue(store.merge(AO3ShelfSnapshot(account: "Reader", isHistory: true, books: [book("1"), book("2")]), complete: true, expectedRevision: store.revision))
        let id = book("1").id
        store.updatePosition(id: id, url: "https://archiveofourown.org/works/1/chapters/10", paragraph: 4, text: "Continue here.")
        XCTAssertTrue(store.merge(AO3ShelfSnapshot(account: "Reader", isHistory: true, books: [book("3")]), complete: false, expectedRevision: store.revision))
        XCTAssertEqual(store.books.count, 3)
        XCTAssertTrue(store.merge(AO3ShelfSnapshot(account: "Reader", isHistory: true, books: [book("1")]), complete: true, expectedRevision: store.revision))
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.books.first?.position?.paragraph, 4)
        let reopened = AO3LibraryStore(defaults: defaults, history: history, storageID: "account-A")
        XCTAssertEqual(reopened.books, store.books)
        XCTAssertTrue(AO3LibraryStore(defaults: defaults, history: history, storageID: "account-B").books.isEmpty)
    }
    func testDisconnectRejectsLateResponseAndDifferentAO3IdentityHasSeparateIDs() {
        let store = AO3LibraryStore(defaults: defaults, history: history, storageID: "account-A")
        let old = store.revision
        XCTAssertTrue(store.merge(AO3ShelfSnapshot(account: "Reader", isHistory: true, books: [book("1")]), complete: true, expectedRevision: old))
        store.disconnect()
        XCTAssertFalse(store.merge(AO3ShelfSnapshot(account: "Reader", isHistory: true, books: [book("1")]), complete: true, expectedRevision: old))
        XCTAssertTrue(store.needsConnection)
        XCTAssertTrue(store.merge(AO3ShelfSnapshot(account: "Other", isHistory: true, books: [book("1", account: "Other")]), complete: true, expectedRevision: store.revision))
        XCTAssertNotEqual(store.books[0].id, book("1").id)
        XCTAssertNil(store.books[0].position)
    }
    func testUntrustedOrForeignWorkCannotPolluteShelf() {
        let store = AO3LibraryStore(defaults: defaults, history: history, storageID: "account-A")
        var foreign = book("1"); foreign.readerURL = "https://archiveofourown.org.evil.test/works/1"
        XCTAssertFalse(store.merge(AO3ShelfSnapshot(account: "Reader", isHistory: true, books: [foreign]), complete: true, expectedRevision: store.revision))
        XCTAssertFalse(store.merge(AO3ShelfSnapshot(account: "Reader", isHistory: false, books: [book("1")]), complete: true, expectedRevision: store.revision))
        XCTAssertNil(AO3URLPolicy.chapterURL("https://archiveofourown.org/works/2/chapters/1", inWork: "1"))
        XCTAssertNil(AO3URLPolicy.chapterURL("https://archiveofourown.org/works/1/chapters/1/edit", inWork: "1"))
        XCTAssertNil(AO3URLPolicy.workID("https://archiveofourown.org:8443/works/1"))
        XCTAssertFalse(AO3URLPolicy.isHistoryURL("https://archiveofourown.org/users/Other/readings", account: "Reader"))
        XCTAssertFalse(AO3URLPolicy.isHistoryURL("https://archiveofourown.org/users/Reader/readings?show=to-read", account: "Reader"))
    }
    func testShelfParserReadsOnlyAuthenticatedHistoryNotRecommendationsOrDeletedWorks() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let html = """
        <html><body><nav id='greeting'><a href='/users/Reader'>Hello Reader!</a><a href='/users/logout'>Log out</a></nav>
        <div id='main' class='readings-index region'><ol class='reading work index group'>
        <li class='reading work blurb'><h4 class='heading'><a href='/works/1'>One</a> by <a rel='author'>Writer</a></h4><dl><dd class='chapters'>2/4</dd></dl></li>
        <li class='deleted reading work'><h4 class='viewed heading'>Deleted work</h4></li></ol>
        <ol class='pagination'><li class='next'><a rel='next' href='/users/Reader/readings?page=2'>Next</a></li></ol></div>
        <h4 class='heading'><a href='/works/999'>Not on this shelf</a></h4></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://archiveofourown.org/users/Reader/readings"))
        var snapshot: AO3ShelfSnapshot?
        for _ in 0..<60 {
            if let raw = try? await web.evaluateJavaScript(AO3WebScripts.shelf), JSONSerialization.isValidJSONObject(raw),
               let data = try? JSONSerialization.data(withJSONObject: raw) { snapshot = try? JSONDecoder().decode(AO3ShelfSnapshot.self, from: data) }
            if snapshot != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = try XCTUnwrap(snapshot)
        XCTAssertEqual(result.books.map(\.workID), ["1"])
        XCTAssertEqual(result.books[0].author, "Writer")
        XCTAssertEqual(result.nextURL, "https://archiveofourown.org/users/Reader/readings?page=2")
        _ = try await web.evaluateJavaScript("document.querySelector('#greeting').remove()")
        let anonymous = try await web.evaluateJavaScript(AO3WebScripts.shelf)
        XCTAssertTrue(anonymous is NSNull)
        web.stopLoading()
    }
}


extension AO3LibraryTests {
    func testConnectionScansAuthenticatedPagesAndCommitsShelfWithoutUserCredentialsInNativeState() async throws {
        let store = AO3LibraryStore(defaults: defaults, history: history, storageID: "account-A")
        func page(_ work: String, next: Bool) -> String {
            """
            <html><body><nav id='greeting'><a href='/users/Reader'>Reader</a><a href='/users/logout'>Log out</a></nav>
            <div id='main' class='readings-index'><ol class='reading work index group'>
            <li><h4 class='heading'><a href='/works/\(work)'>Work \(work)</a></h4></li></ol>
            \(next ? "<nav class='pagy'><a href='/users/Reader/readings?page=2'>2</a></nav>" : "")
            </div></body></html>
            """
        }
        let pages = [
            "https://archiveofourown.org/users/login": page("999", next: false),
            "https://archiveofourown.org/users/Reader/readings": page("1", next: true),
            "https://archiveofourown.org/users/Reader/readings?page=2": page("2", next: false)
        ]
        let connection = AO3ConnectionModel(store: store) { AO3FixtureWebView(configuration: $0, pages: pages) }
        defer { connection.stop() }
        connection.start()
        for _ in 0..<100 {
            if !store.needsConnection { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(store.accountLabel, "Reader")
        XCTAssertEqual(store.books.map(\.workID), ["1", "2"])
        XCTAssertFalse(connection.scanning)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.books.contains { $0.workID == "999" }, "Login page content must not become a shelf")
    }
}


extension AO3LibraryTests {
    func testChapterCheckpointNeverReusesIdenticalProseFromAnotherChapter() throws {
        let id = book("1").id
        let paragraphs = [ReadingParagraph(id: 0, text: "Repeated opening."), ReadingParagraph(id: 1, text: "Repeated ending.")]
        let first = ReadingDocument(id: id, title: "One", sourceKind: .web, paragraphs: [], sourceURL: "https://archiveofourown.org/works/1/chapters/1")
        history.record(first)
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: paragraphs).checkpoint(sourceKind: .web, paragraphIndex: 1, audio: nil))
        let firstKey = "ao3-" + ReadingResumeContract.fingerprint(first.sourceURL!)
        XCTAssertTrue(history.saveReadingCheckpoint(checkpoint, for: id, boundary: history.progressBoundaryToken, variant: firstKey))
        XCTAssertTrue(history.saveReadingCheckpoint(checkpoint, for: id, boundary: history.progressBoundaryToken))
        var second = first; second.sourceURL = "https://archiveofourown.org/works/1/chapters/2"
        let vm = ReadAloudViewModel(document: second, historyStore: history)
        vm.loadWebParagraphs(paragraphs)
        XCTAssertEqual(vm.currentParagraphIndex, -1)
        XCTAssertNil(vm.resumeNotice)
        let restored = ReadAloudViewModel(document: first, historyStore: history)
        restored.loadWebParagraphs(paragraphs)
        XCTAssertEqual(restored.currentParagraphIndex, 1)
        vm.stop(); restored.stop()
    }
}


extension AO3LibraryTests {
    func testCancelledOrDisconnectedSyncCannotPublishLateNavigationFailure() {
        let store = AO3LibraryStore(defaults: defaults, history: history, storageID: "account-A")
        let connection = AO3ConnectionModel(store: store) { AO3FixtureWebView(configuration: $0, pages: [:]) }
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        connection.start()
        connection.stop()
        connection.webView(connection.webView, didFail: nil, withError: error)
        XCTAssertNil(store.lastError)
        connection.start()
        store.disconnect()
        connection.webView(connection.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.needsConnection)
        connection.stop()
    }

    func testSyncedHomeBookOpensUnifiedReadAndExplainSessionAtLatestChapter() throws {
        let store = AO3LibraryStore(defaults: defaults, history: history, storageID: "account-A")
        let imported = book("1")
        XCTAssertTrue(store.merge(AO3ShelfSnapshot(account: "Reader", isHistory: true, books: [imported]), complete: true, expectedRevision: store.revision))
        let chapter = "https://archiveofourown.org/works/1/chapters/2"
        store.updatePosition(id: imported.id, url: chapter, paragraph: 3, text: "Continue here.")
        let player = PlayerCoordinator(historyStore: history)
        defer { player.session?.readVM.stop(); player.session?.explainVM.stop() }
        AO3ReaderLauncher.open(imported, using: player, store: store)
        let session = try XCTUnwrap(player.session)
        XCTAssertEqual(session.document.id, imported.id)
        XCTAssertEqual(session.document.sourceURL, chapter)
        XCTAssertEqual(session.document.sourceKind, .web)
        XCTAssertEqual(session.readVM.document.sourceURL, chapter)
        XCTAssertEqual(session.explainVM.document.sourceURL, chapter)
        XCTAssertEqual(player.mode, .read)
        XCTAssertTrue(player.isReaderPresented)
        XCTAssertNotNil(store.homeBooks.first?.lastOpenedAt)
        XCTAssertFalse(session.readVM.isPlaying, "Opening a card waits for the user's Play action")
    }
}
