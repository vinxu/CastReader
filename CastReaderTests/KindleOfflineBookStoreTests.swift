import XCTest
import UIKit
@testable import CastReader

@MainActor
final class KindleOfflineBookStoreTests: XCTestCase {
    private var root: URL!
    private let scope = KindleOfflinePageStore.digest("book-store-account")
    private let source = KindleBook(id: "test-full-book", title: "A complete local book", author: "Test",
        readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "", lastSyncedAt: Date())

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineBookTests-" + UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func position(_ page: Int, total: Int, layout: String = "layout") -> KindleOfflineSourcePosition {
        .init(start: page * 10, end: page * 10 + 9, minimum: 0, maximum: total * 10 - 1,
              layoutID: layout, fingerprint: "same-image-is-not-a-page-identity")
    }
    private func document() -> ReadingDocument {
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        return ReadingDocument(title: source.title, sourceKind: .kindle, language: "en-US", paragraphs: [
            ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: bytes),
            ReadingParagraph(id: 1, text: "The same printed text can occur on different pages.", pageIndex: 0)
        ])
    }

    func testThreeHundredPagesResumeAndCompleteWithoutPrefetchLimitOrImageDeduplication() async throws {
        var store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(140, total: 300))
        let doc = document()
        for index in 0..<143 {
            book = try await store.append(document: doc, position: position(index, total: 300), to: book, scope: scope)
        }
        book = try await store.setStatus(.paused, error: nil, book: book, scope: scope)
        store = KindleOfflineBookStore(root: root)
        book = try await store.prepare(source: source, scope: scope, originalPosition: position(140, total: 300))
        XCTAssertEqual(book.pages.count, 143)
        XCTAssertFalse(book.coversWholeBook)
        for index in 143..<300 {
            book = try await store.append(document: doc, position: position(index, total: 300), to: book, scope: scope)
        }
        book = try await store.finish(book, scope: scope)
        XCTAssertEqual(book.status, .complete)
        XCTAssertEqual(book.pages.count, 300)
        XCTAssertEqual(book.readingPosition.page, 140)
        XCTAssertEqual(Set(book.pages.map { $0.resource.id }).count, 300)
        XCTAssertEqual(Set(book.pages.map { $0.resource.imageHash }).count, 1)
        let reopened = try await KindleOfflineBookStore(root: root).load(id: book.id, scope: scope)
        XCTAssertEqual(reopened?.pages, book.pages)
        let last = try await store.openPage(book: book, ordinal: 299, scope: scope)
        XCTAssertEqual(last.paragraphs[1].text, doc.paragraphs[1].text)
    }

    func testCannotCallPartialOrSkippedRangeACompleteBook() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(1, total: 5))
        do { _ = try await store.append(document: document(), position: position(1, total: 5), to: book, scope: scope); XCTFail("missing beginning") } catch {}
        book = try await store.append(document: document(), position: position(0, total: 5), to: book, scope: scope)
        do { _ = try await store.append(document: document(), position: position(2, total: 5), to: book, scope: scope); XCTFail("missing page") } catch {}
        do { _ = try await store.finish(book, scope: scope); XCTFail("partial marked complete") } catch {}
        do { _ = try await store.setStatus(.complete, error: nil, book: book, scope: scope); XCTFail("completion bypass") } catch {}
        let reopened = try await store.load(id: book.id, scope: scope)
        XCTAssertEqual(reopened?.pages.count, 1)
        XCTAssertNotEqual(reopened?.status, .complete)
    }

    func testDifferentLayoutAndAccountCannotAdoptSavedPages() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 3))
        book = try await store.append(document: document(), position: position(0, total: 3), to: book, scope: scope)
        do { _ = try await store.append(document: document(), position: position(1, total: 3, layout: "changed"), to: book, scope: scope); XCTFail("mixed layout") } catch {}
        let otherScope = KindleOfflinePageStore.digest("different-account")
        let other = try await store.list(scope: otherScope)
        XCTAssertTrue(other.isEmpty)
        do { _ = try await store.openPage(book: book, ordinal: 0, scope: otherScope); XCTFail("cross-account page") } catch {}
    }

    func testExpiredNetworkSessionKeepsLocalBindingUntilConfirmedRebind() throws {
        let suite = "OfflineBindingTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = KindleLibraryStore(defaults: defaults)
        library.markConnectedWithEmptyShelf()
        let original = try XCTUnwrap(library.offlineContentBindingID)
        // Recreate the persisted state of an expired network session. No
        // WebKit website data is removed by this isolated storage test.
        defaults.set(false, forKey: "kindle.library.connected.v1")
        defaults.set(true, forKey: "kindle.offline.rebind-pending.v1.\(library.boundStorefrontID)")
        library = KindleLibraryStore(defaults: defaults)
        XCTAssertEqual(library.offlineContentBindingID, original)
        library.markConnectedWithEmptyShelf()
        XCTAssertNotEqual(library.offlineContentBindingID, original)
    }

    func testRelaunchRetainsOriginalReadingPositionFromInterruptedDownload() async throws {
        let store = KindleOfflineBookStore(root: root)
        let original = KindleOfflineSourcePosition(start: 50, end: 59, minimum: 0, maximum: 369, layoutID: "fixture", fingerprint: "original")
        var book = try await store.prepare(source: source, scope: scope, originalPosition: original)
        book = try await store.append(document: document(), position: .init(start: 0, end: 9, minimum: 0,
            maximum: 369, layoutID: "fixture", fingerprint: "first"), to: book, scope: scope)
        XCTAssertFalse(book.originalPositionRestored)
        let reopened = KindleOfflineDownloadCoordinator(store: KindleOfflineBookStore(root: root))
        let source = OfflineSourceFixture(book: self.source, document: document())
        source.failAtPage = 1
        reopened.start(source: source, scope: scope, stillAuthorized: { true })
        try await waitUntilStopped(reopened)
        XCTAssertEqual(reopened.book?.originalPosition, original)
        XCTAssertEqual(source.requestedPages, [1])
        XCTAssertEqual(reopened.book?.originalPositionRestored, true)
    }

    func testCoordinatorContinuesPastThirteenPagesAndResumesAfterSourceFailure() async throws {
        let store = KindleOfflineBookStore(root: root)
        let source = OfflineSourceFixture(book: self.source, document: document())
        let download = KindleOfflineDownloadCoordinator(store: store)
        source.failAtPage = 17
        download.start(source: source, scope: scope, stillAuthorized: { true })
        try await waitUntilStopped(download)
        XCTAssertEqual(download.book?.pages.count, 17)
        XCTAssertEqual(download.book?.status, .failed)
        XCTAssertEqual(source.cleanupCount, 1)
        source.failAtPage = nil
        download.start(source: source, scope: scope, stillAuthorized: { true })
        try await waitUntilStopped(download)
        XCTAssertEqual(download.book?.pages.count, 37)
        XCTAssertEqual(download.book?.status, .complete)
        XCTAssertEqual(source.cleanupCount, 2)
        XCTAssertEqual(source.requestedPages.filter { $0 == 0 }.count, 1)
        XCTAssertEqual(download.book?.originalPositionRestored, true)
    }

    private func waitUntilStopped(_ download: KindleOfflineDownloadCoordinator) async throws {
        let deadline = Date().addingTimeInterval(15)
        while download.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(download.isRunning)
    }

    func testReadingPositionDoesNotOverwriteDownloadProgress() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 4))
        for index in 0..<3 { book = try await store.append(document: document(), position: position(index, total: 4), to: book, scope: scope) }
        var cursor = KindleOfflineBook.ReadingPosition()
        cursor.page = 1; cursor.paragraphID = 1; cursor.sentenceStart = 5; cursor.voiceID = "Samantha"
        try await store.saveReadingPosition(cursor, book: book, scope: scope)
        book = try await store.append(document: document(), position: position(3, total: 4), to: book, scope: scope)
        XCTAssertEqual(book.readingPosition, cursor)
        XCTAssertEqual(book.pages.count, 4)
    }
}

@MainActor
private final class OfflineSourceFixture: KindleOfflineBookSource {
    let offlineSourceBook: KindleBook
    let document: ReadingDocument
    var failAtPage: Int?
    var cleanupCount = 0
    var requestedPages: [Int] = []
    init(book: KindleBook, document: ReadingDocument) { offlineSourceBook = book; self.document = document }
    private func position(_ page: Int) -> KindleOfflineSourcePosition {
        .init(start: page * 10, end: page * 10 + 9, minimum: 0, maximum: 369, layoutID: "fixture", fingerprint: "page-\(page)")
    }
    func beginOfflineBookCapture(restoring interruptedPosition: KindleOfflineSourcePosition?) async throws -> KindleOfflineSourcePosition { interruptedPosition ?? position(20) }
    func captureOfflineBookPage(after: KindleOfflineSourcePosition?) async throws -> KindleOfflineCapturedPage {
        let page = after.map { ($0.end + 1) / 10 } ?? 0
        requestedPages.append(page)
        if page == failAtPage { throw URLError(.networkConnectionLost) }
        return .init(position: position(page), document: document)
    }
    func endOfflineBookCapture() async -> Bool { cleanupCount += 1; return true }
}

@MainActor
final class KindleOfflineBookReaderTests: XCTestCase {
    private final class Driver: SystemSpeechDriving {
        var onEvent: ((SystemSpeechDriverEvent) -> Void)?
        var requests: [SystemSpeechRequest] = []
        func prepare() throws {}
        func speak(_ request: SystemSpeechRequest) throws { requests.append(request) }
        func pause() -> Bool { true }
        func resume() -> Bool { true }
        func stop() {}
    }

    func testSystemSpeechContinuesAcrossSavedImageOnlyPagesAndRestoresCheckpoint() async throws {
        guard !SystemSpeechPlaybackService.voices(language: "en-US").isEmpty else { throw XCTSkip("English system voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KindleOfflineBookStore(root: root), scope = KindleOfflinePageStore.digest("reader-fixture")
        let source = KindleBook(id: "reader-fixture", title: "Reader fixture", author: "Test",
            readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "", lastSyncedAt: Date())
        func position(_ index: Int) -> KindleOfflineSourcePosition {
            .init(start: index * 10, end: index * 10 + 9, minimum: 0, maximum: 39, layoutID: "fixture", fingerprint: "page-\(index)")
        }
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        for index in 0..<4 {
            var paragraphs = [ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: image)]
            if index == 0 || index == 3 { paragraphs.append(ReadingParagraph(id: 1, text: index == 0 ? "First page." : "Last page.", pageIndex: 0)) }
            let doc = ReadingDocument(title: "Reader fixture", sourceKind: .kindle, language: "en-US", paragraphs: paragraphs)
            book = try await store.append(document: doc, position: position(index), to: book, scope: scope)
        }
        book = try await store.finish(book, scope: scope)
        let driver = Driver(), speech = SystemSpeechPlaybackService(driver: Driver())
        let actualSpeech = SystemSpeechPlaybackService(driver: driver)
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store, speech: actualSpeech, scopeValidator: { true })
        await model.open()
        model.play()
        let first = try XCTUnwrap(driver.requests.first)
        driver.onEvent?(.started(first.id)); driver.onEvent?(.finished(first.id))
        let deadline = Date().addingTimeInterval(5)
        while driver.requests.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.pageIndex, 3)
        XCTAssertEqual(driver.requests.count, 2)
        XCTAssertEqual(driver.requests.last?.text, "Last page.")
        model.speech.pause()
        model.close()
        try await Task.sleep(for: .milliseconds(50))
        let restored = KindleOfflineBookReaderModel(book: book, scope: scope, store: store, speech: speech, scopeValidator: { true })
        await restored.open()
        XCTAssertEqual(restored.pageIndex, 3)
        XCTAssertEqual(restored.speech.state, .paused)
        restored.close()
    }
}
