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

    func testImagesCompleteWithoutOCRAndRecognitionIsAnIndependentReusableCache() async throws {
        let store = KindleOfflineBookStore(root: root)
        var raw = document(); raw.paragraphs.removeAll { $0.type != .image }
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 1))
        book = try await store.append(document: raw, position: position(0, total: 1), to: book, scope: scope,
            requiresOCR: true, sourceWordCount: 12)
        book = try await store.finish(book, scope: scope)
        XCTAssertEqual(book.status, .complete)
        let notRecognized = try await store.cachedSpeechPage(book: book, ordinal: 0, scope: scope)
        XCTAssertNil(notRecognized)
        let imageOnly = try await store.openPage(book: book, ordinal: 0, scope: scope)
        XCTAssertFalse(imageOnly.paragraphs.contains { $0.type.isReadable })
        let originalResource = book.pages[0].resource
        try await store.saveSpeechPage(document(), book: book, ordinal: 0, scope: scope)
        let reopened = KindleOfflineBookStore(root: root)
        let cached = try await reopened.cachedSpeechPage(book: book, ordinal: 0, scope: scope)
        XCTAssertTrue(cached?.paragraphs.contains { !$0.text.isEmpty } == true)
        let fresh = try await reopened.load(id: book.id, scope: scope)
        XCTAssertEqual(fresh?.pages[0].resource, originalResource)
        XCTAssertEqual(fresh?.status, .complete)
        let resources = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        let sidecar = try XCTUnwrap(resources.first { $0.hasSuffix(".ocr") })
        try Data("damaged".utf8).write(to: root.appendingPathComponent(sidecar))
        let damagedCache = try await reopened.cachedSpeechPage(book: book, ordinal: 0, scope: scope)
        XCTAssertNil(damagedCache)
        _ = try await reopened.openPage(book: book, ordinal: 0, scope: scope)
    }

    func testCancelWaitsForRestorationKeepsCommittedPagesAndCanResume() async throws {
        let source = OfflineSourceFixture(book: self.source, document: document())
        source.captureDelay = .milliseconds(60)
        source.cleanupDelay = .milliseconds(150)
        let download = KindleOfflineDownloadCoordinator(store: KindleOfflineBookStore(root: root))
        let originalIdleSetting = UIApplication.shared.isIdleTimerDisabled
        download.start(source: source, scope: scope, stillAuthorized: { true })
        let deadline = Date().addingTimeInterval(5)
        while source.requestedPages.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(source.requestedPages, [0, 1, 2])
        let stop = Task { await download.stopAndWait(reason: .closing) }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(download.isRunning, "Reader must stay locked while restoring the original page")
        XCTAssertTrue(download.isStopping)
        XCTAssertEqual(download.activity, .restoring)
        // Repeated stop/start taps must not create another capture or cleanup.
        download.pause()
        download.start(source: source, scope: scope, stillAuthorized: { true })
        await stop.value
        XCTAssertFalse(download.isRunning)
        XCTAssertEqual(source.cleanupCount, 1)
        XCTAssertEqual(download.book?.pages.count, 2)
        XCTAssertEqual(download.book?.status, .paused)
        XCTAssertEqual(download.book?.originalPositionRestored, true)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, originalIdleSetting)
        source.captureDelay = .zero; source.cleanupDelay = .zero
        download.start(source: source, scope: scope, stillAuthorized: { true })
        try await waitUntilStopped(download)
        XCTAssertEqual(download.book?.status, .complete)
        XCTAssertEqual(download.book?.pages.count, 37)
        XCTAssertEqual(source.requestedPages.filter { $0 == 0 }.count, 1)
    }

    func testCancelDuringPreparationAndFailedRestoreRemainSafeToClose() async throws {
        let source = OfflineSourceFixture(book: self.source, document: document())
        source.beginDelay = .milliseconds(150)
        source.restoreSucceeds = false
        let download = KindleOfflineDownloadCoordinator(store: KindleOfflineBookStore(root: root))
        download.start(source: source, scope: scope, stillAuthorized: { true })
        try await Task.sleep(for: .milliseconds(20))
        await download.stopAndWait(reason: .background)
        XCTAssertFalse(download.isRunning)
        XCTAssertTrue(source.requestedPages.isEmpty)
        XCTAssertEqual(source.cleanupCount, 1)
        XCTAssertNotNil(download.error, "Failed restoration must stay visible instead of silently dismissing")
        XCTAssertTrue(download.phase.contains("已暂停"))
    }

    func testRemainingTimeUsesOnlyNewProgressAfterResume() {
        var estimate = KindleOfflineDownloadEstimate()
        estimate.record(fraction: 0.6, at: 100)
        estimate.record(fraction: 0.62, at: 101)
        XCTAssertNil(estimate.remainingSeconds)
        estimate.record(fraction: 0.64, at: 102)
        estimate.record(fraction: 0.66, at: 103)
        XCTAssertEqual(estimate.remainingSeconds, 25)
        estimate.record(fraction: .nan, at: 104)
        estimate.record(fraction: 0.5, at: 105)
        XCTAssertEqual(estimate.remainingSeconds, 25)
        estimate.record(fraction: 0.68, at: 120)
        XCTAssertGreaterThan(estimate.remainingSeconds ?? 0, 25, "A stall must increase the remaining-time estimate")
    }
}

@MainActor
private final class OfflineSourceFixture: KindleOfflineBookSource {
    let offlineSourceBook: KindleBook
    let document: ReadingDocument
    var failAtPage: Int?
    var cleanupCount = 0
    var requestedPages: [Int] = []
    var beginDelay: Duration = .zero
    var captureDelay: Duration = .zero
    var cleanupDelay: Duration = .zero
    var restoreSucceeds = true
    init(book: KindleBook, document: ReadingDocument) { offlineSourceBook = book; self.document = document }
    private func position(_ page: Int) -> KindleOfflineSourcePosition {
        .init(start: page * 10, end: page * 10 + 9, minimum: 0, maximum: 369, layoutID: "fixture", fingerprint: "page-\(page)")
    }
    func beginOfflineBookCapture(restoring interruptedPosition: KindleOfflineSourcePosition?) async throws -> KindleOfflineSourcePosition {
        if beginDelay != .zero { try await Task.sleep(for: beginDelay) }
        return interruptedPosition ?? position(20)
    }
    func captureOfflineBookPage(after: KindleOfflineSourcePosition?) async throws -> KindleOfflineCapturedPage {
        let page = after.map { ($0.end + 1) / 10 } ?? 0
        requestedPages.append(page)
        if captureDelay != .zero { try await Task.sleep(for: captureDelay) }
        if page == failAtPage { throw URLError(.networkConnectionLost) }
        return .init(position: position(page), document: document)
    }
    func endOfflineBookCapture() async -> Bool {
        cleanupCount += 1
        if cleanupDelay != .zero { try? await Task.sleep(for: cleanupDelay) }
        return restoreSucceeds
    }
}

@MainActor
final class KindleOfflineBookReaderTests: XCTestCase {
    private final class Recognizer: KindleOfflineRecognizing {
        var calls = 0
        var delay: Duration = .milliseconds(1)
        var shouldFail = false
        func recognize(_ page: ReadingDocument, sourceWordCount: Int?) async throws -> ReadingDocument {
            calls += 1
            try await Task.sleep(for: delay)
            if shouldFail { throw OCRError.noText }
            var result = page
            result.paragraphs.append(ReadingParagraph(id: 1, text: "Recognized only when listening.", pageIndex: 0))
            return result
        }
    }
    private final class Driver: SystemSpeechDriving {
        var onEvent: ((SystemSpeechDriverEvent) -> Void)?
        var requests: [SystemSpeechRequest] = []
        func prepare() throws {}
        func speak(_ request: SystemSpeechRequest) throws { requests.append(request) }
        func pause() -> Bool { true }
        func resume() -> Bool { true }
        func stop() {}
    }

    private func imageBook(root: URL) async throws -> (KindleOfflineBookStore, KindleOfflineBook, String) {
        let store = KindleOfflineBookStore(root: root), scope = KindleOfflinePageStore.digest("lazy-reader")
        let source = KindleBook(id: "lazy-reader", title: "Lazy reader", author: "Test",
            readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "", lastSyncedAt: Date())
        let position = KindleOfflineSourcePosition(start: 0, end: 99, minimum: 0, maximum: 99, layoutID: "fixture", fingerprint: "first")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let doc = ReadingDocument(title: "Lazy reader", sourceKind: .kindle, language: "en-US",
            paragraphs: [ReadingParagraph(id: 0, text: "", type: .image, imageData: image)])
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position)
        book = try await store.append(document: doc, position: position, to: book, scope: scope, requiresOCR: true, sourceWordCount: 10)
        book = try await store.finish(book, scope: scope)
        return (store, book, scope)
    }

    func testRealLocalOCRRecognizesSavedImageWithoutOnlineReader() async throws {
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 1100, height: 500)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1100, height: 500))
            ("A journey begins today.\nWe can read this page offline." as NSString).draw(
                in: CGRect(x: 60, y: 70, width: 980, height: 360),
                withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
        }
        let page = ReadingDocument(title: "Local OCR fixture", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "", type: .image, imageData: bytes)])
        let recognized = try await KindleOfflineOCRService().recognize(page, sourceWordCount: 11)
        let text = recognized.paragraphs.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("journey")); XCTAssertTrue(text.contains("offline"))
        XCTAssertEqual(recognized.paragraphs.first?.imageData, bytes)
        XCTAssertEqual(recognized.paragraphs.map(\.id), Array(recognized.paragraphs.indices))
        XCTAssertTrue(recognized.paragraphs.dropFirst().contains { !$0.words.isEmpty })
    }

    func testOpeningAnImageBookDoesNotOCRAndPlaybackRecognitionSurvivesColdReopen() async throws {
        guard !SystemSpeechPlaybackService.voices(language: "en-US").isEmpty else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        let recognizer = Recognizer(), driver = Driver()
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true }, recognizer: recognizer)
        await model.open()
        XCTAssertEqual(recognizer.calls, 0)
        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertTrue(model.speech.units.isEmpty)
        model.play()
        let deadline = Date().addingTimeInterval(3)
        while driver.requests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recognizer.calls, 1)
        XCTAssertEqual(driver.requests.first?.text, "Recognized only when listening.")
        model.pause(); model.close()
        let coldRecognizer = Recognizer(), coldDriver = Driver()
        let cold = KindleOfflineBookReaderModel(book: book, scope: scope, store: KindleOfflineBookStore(root: root),
            speech: SystemSpeechPlaybackService(driver: coldDriver), scopeValidator: { true }, recognizer: coldRecognizer)
        await cold.open(); cold.play()
        XCTAssertEqual(coldRecognizer.calls, 0)
        XCTAssertEqual(coldDriver.requests.first?.text, "Recognized only when listening.")
        cold.close()
    }

    func testFailedRecognitionKeepsImageAndPauseDuringRetryCannotStartAudio() async throws {
        guard !SystemSpeechPlaybackService.voices(language: "en-US").isEmpty else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        let recognizer = Recognizer(), driver = Driver(); recognizer.shouldFail = true
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true }, recognizer: recognizer)
        await model.open(); model.play()
        while model.preparingSpeech { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.error); XCTAssertTrue(driver.requests.isEmpty)
        _ = try await store.openPage(book: book, ordinal: 0, scope: scope)
        recognizer.shouldFail = false; recognizer.delay = .milliseconds(150)
        model.play()
        while recognizer.calls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        model.pause()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertFalse(model.preparingSpeech)
        model.play()
        let retryDeadline = Date().addingTimeInterval(2)
        while recognizer.calls < 3, Date() < retryDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recognizer.calls, 3)
        AudioPlayerService.shared.stopSystemSpeechForLibraryBoundary()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertFalse(model.preparingSpeech)
        model.close()
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
