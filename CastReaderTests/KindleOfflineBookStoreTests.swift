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

    func testDuplicateSkippedReversedAndOverlappingPagesDoNotChangeCommittedSequence() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 5))
        for page in 0..<2 {
            book = try await store.append(document: document(), position: position(page, total: 5), to: book, scope: scope)
        }
        let committed = book.pages
        let overlapping = KindleOfflineSourcePosition(start: 15, end: 29, minimum: 0, maximum: 49,
            layoutID: "layout", fingerprint: "different-image-but-overlapping-source")
        for invalid in [position(1, total: 5), position(3, total: 5), position(0, total: 5), overlapping] {
            do {
                _ = try await store.append(document: document(), position: invalid, to: book, scope: scope)
                XCTFail("Invalid page entered the committed sequence: \(invalid.start)")
            } catch KindleOfflineBookStore.Failure.discontinuousPage {} catch { XCTFail("Unexpected error: \(error)") }
            let reopened = try await store.load(id: book.id, scope: scope)
            XCTAssertEqual(reopened?.pages, committed)
            XCTAssertNotEqual(reopened?.status, .complete)
        }
        // A late duplicate cannot prevent normal continuation from page two.
        for page in 2..<5 {
            book = try await store.append(document: document(), position: position(page, total: 5), to: book, scope: scope)
        }
        book = try await store.finish(book, scope: scope)
        XCTAssertEqual(book.pages.map(\.position.start), [0, 10, 20, 30, 40])
    }

    func testExchangedImageResourcesCannotPassAsCorrectPageOrder() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 3))
        for page in 0..<3 {
            book = try await store.append(document: document(), position: position(page, total: 3), to: book, scope: scope)
        }
        book = try await store.finish(book, scope: scope)
        let url = root.appendingPathComponent(scope).appendingPathComponent(book.id + ".book")
        let originalBytes = try Data(contentsOf: url)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
        book = try JSONDecoder().decode(KindleOfflineBook.self, from: originalBytes)
        let original = book.pages
        // Correct ordinal/range and intact image hashes are insufficient when
        // a page is accidentally wired to another page's saved resource.
        book.pages[1] = .init(ordinal: 1, position: original[1].position, resource: original[2].resource,
                              requiresOCR: original[1].requiresOCR, sourceWordCount: original[1].sourceWordCount)
        book.pages[2] = .init(ordinal: 2, position: original[2].position, resource: original[1].resource,
                              requiresOCR: original[2].requiresOCR, sourceWordCount: original[2].sourceWordCount)
        XCTAssertTrue(book.coversWholeBook)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let changedBytes = try encoder.encode(book)
        XCTAssertEqual(changedBytes.count, originalBytes.count)
        try changedBytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        do { _ = try await store.load(id: book.id, scope: scope); XCTFail("Swapped resources were accepted") }
        catch KindleOfflineBookStore.Failure.corruptManifest {} catch { XCTFail("Unexpected error: \(error)") }
        try originalBytes.write(to: url, options: .atomic)
        let restored = try await store.load(id: book.id, scope: scope)
        XCTAssertEqual(restored?.pages, original)
    }

    func testWarmManifestObservesExternalCheckpointAndCannotResurrectRemovedFile() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 2))
        for page in 0..<2 { book = try await store.append(document: document(), position: position(page, total: 2), to: book, scope: scope) }
        book = try await store.finish(book, scope: scope)
        let url = root.appendingPathComponent(scope).appendingPathComponent(book.id + ".book")
        let originalBytes = try Data(contentsOf: url)
        var edited = try JSONDecoder().decode(KindleOfflineBook.self, from: originalBytes)
        edited.readingPosition.page = 1
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let changed = try encoder.encode(edited)
        XCTAssertEqual(changed.count, originalBytes.count)
        try changed.write(to: url, options: .atomic)
        let refreshed = try await store.load(id: book.id, scope: scope)
        XCTAssertEqual(refreshed?.readingPosition.page, 1)
        try FileManager.default.removeItem(at: url)
        do { try await store.saveReadingPosition(edited.readingPosition, book: book, scope: scope); XCTFail("Deleted manifest was recreated") }
        catch KindleOfflineBookStore.Failure.staleGeneration {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSharedNormalizedBoundaryIsValidButInteriorOverlapIsNot() {
        func range(_ start: Int, _ end: Int) -> KindleOfflineSourcePosition {
            .init(start: start, end: end, minimum: 0, maximum: 100, layoutID: "layout", fingerprint: "same")
        }
        XCTAssertTrue(range(3, 20).follows(range(0, 2)), "Cover boundary")
        XCTAssertTrue(range(20, 30).follows(range(3, 20)), "Shared normalized endpoint")
        XCTAssertTrue(range(21, 30).follows(range(3, 20)), "Inclusive adjacent ranges")
        XCTAssertFalse(range(19, 30).follows(range(3, 20)), "No interior overlap")
        XCTAssertFalse(range(22, 30).follows(range(3, 20)), "No missing positions")
    }

    func testDeletingOneLocalCopyRejectsLateWritesAndPreservesOtherAccounts() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 2))
        book = try await store.append(document: document(), position: position(0, total: 2), to: book, scope: scope)
        let otherScope = KindleOfflinePageStore.digest("another-account")
        let other = try await store.prepare(source: source, scope: otherScope, originalPosition: position(0, total: 2))
        XCTAssertEqual(book.sourceBook?.id, source.id)
        try await store.remove(id: book.id, scope: scope)
        let deleted = try await store.load(id: book.id, scope: scope)
        XCTAssertNil(deleted)
        let retained = try await store.load(id: other.id, scope: otherScope)
        XCTAssertNotNil(retained)
        do {
            try await store.saveReadingPosition(.init(), book: book, scope: scope)
            XCTFail("A late cursor must not recreate the deleted manifest")
        } catch KindleOfflineBookStore.Failure.staleGeneration {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(scope).appendingPathComponent(book.id).path))
    }

    func testCorruptManifestIsReportedForRepairInsteadOfLookingLikeAnEmptyLibrary() async throws {
        let store = KindleOfflineBookStore(root: root)
        let book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 2))
        let url = root.appendingPathComponent(scope).appendingPathComponent(book.id + ".book")
        try Data("broken manifest".utf8).write(to: url)
        let damaged = try await store.unreadableBookIDs(scope: scope)
        XCTAssertEqual(damaged, [book.id])
        try await store.remove(id: book.id, scope: scope)
        let repaired = try await store.unreadableBookIDs(scope: scope)
        XCTAssertTrue(repaired.isEmpty)
    }

    func testOfflineResumeEntryTargetsOnlyTheRequestedBookOnce() {
        let center = KindlePlaybackCenter.shared
        defer { center.close() }
        center.openOfflineDownload(book: source)
        XCTAssertTrue(center.isPresented)
        XCTAssertFalse(center.consumeOfflineDownloadRequest(for: "different-book"))
        XCTAssertTrue(center.consumeOfflineDownloadRequest(for: source.id))
        XCTAssertFalse(center.consumeOfflineDownloadRequest(for: source.id))
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

    func testOldWrongLanguageOCRIsDiscardedWithoutChangingImagesOrPageOrder() async throws {
        let store = KindleOfflineBookStore(root: root)
        var raw = document(); raw.paragraphs.removeAll { $0.type != .image }
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 1))
        book = try await store.append(document: raw, position: position(0, total: 1), to: book, scope: scope,
            requiresOCR: true, sourceWordCount: 12)
        book = try await store.finish(book, scope: scope)
        try await store.saveSpeechPage(document(), book: book, ordinal: 0, scope: scope)
        let sidecar = try XCTUnwrap(try FileManager.default.subpathsOfDirectory(atPath: root.path).first { $0.hasSuffix(".ocr") })
        let url = root.appendingPathComponent(sidecar)
        var old = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        old["version"] = 1
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let reopened = KindleOfflineBookStore(root: root)
        let cached = try await reopened.cachedSpeechPage(book: book, ordinal: 0, scope: scope)
        XCTAssertNil(cached)
        let imageOnly = try await reopened.openPage(book: book, ordinal: 0, scope: scope)
        XCTAssertEqual(imageOnly.paragraphs.first?.imageData, raw.paragraphs.first?.imageData)
        let fresh = try await reopened.load(id: book.id, scope: scope)
        XCTAssertEqual(fresh?.pages, book.pages)
        XCTAssertEqual(fresh?.status, .complete)
    }

    func testEnglishFrontMatterDoesNotForceChinesePagesOrInvalidateTheirCache() async throws {
        let store = KindleOfflineBookStore(root: root)
        var raw = document(); raw.paragraphs.removeAll { $0.type != .image }
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 2))
        for index in 0..<2 {
            book = try await store.append(document: raw, position: position(index, total: 2), to: book, scope: scope,
                requiresOCR: true, sourceWordCount: 12)
        }
        book = try await store.finish(book, scope: scope)
        try await store.saveSpeechPage(document(), book: book, ordinal: 0, scope: scope)
        let next = try await store.openPage(book: book, ordinal: 1, scope: scope)
        XCTAssertEqual(next.language, "und", "A new page still needs language detection")
        var chinese = document(); chinese.language = "zh-Hant"
        chinese.paragraphs[1] = ReadingParagraph(id: 1, text: "這是正文的中文內容。", pageIndex: 0)
        try await store.saveSpeechPage(chinese, book: book, ordinal: 1, scope: scope)
        let first = try await store.cachedSpeechPage(book: book, ordinal: 0, scope: scope)
        let second = try await store.cachedSpeechPage(book: book, ordinal: 1, scope: scope)
        XCTAssertEqual(first?.language, "en-US")
        XCTAssertEqual(second?.language, "zh-Hant")
        XCTAssertEqual(second?.paragraphs[1].text, chinese.paragraphs[1].text)
    }

    func testCoverPersistsAcrossReopenWithoutChangingBookPagesAndCannotLeakAcrossScopes() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 1))
        book = try await store.append(document: document(), position: position(0, total: 1), to: book, scope: scope)
        book = try await store.finish(book, scope: scope)
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600)).pngData { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }
        let saved = try await store.saveCover(cover, fromShelf: true, book: book, scope: scope)
        let cold = KindleOfflineBookStore(root: root)
        let data = try await cold.coverData(book: book, scope: scope)
        let image = try XCTUnwrap(data.flatMap(UIImage.init(data:)))
        XCTAssertEqual(image.size.width / image.size.height, 2.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(saved.pages, book.pages)
        XCTAssertEqual(saved.generation, book.generation)
        XCTAssertEqual(saved.status, .complete)
        XCTAssertEqual(saved.cover?.fromShelf, true)
        XCTAssertGreaterThan(saved.byteCount, book.byteCount)
        do { _ = try await cold.coverData(book: book, scope: KindleOfflinePageStore.digest("other-account")); XCTFail("Cross-account cover") } catch {}
        try await cold.remove(id: book.id, scope: scope)
        do { try await cold.saveCover(cover, fromShelf: true, book: book, scope: scope); XCTFail("A late cover resurrected a deleted book") } catch {}
    }

    func testLegacyCoverBackfillUsesSavedFirstPageWithoutNetworkOrOCR() async throws {
        let store = KindleOfflineBookStore(root: root)
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0, total: 1))
        var raw = document(); raw.paragraphs.removeAll { $0.type != .image }
        book = try await store.append(document: raw, position: position(0, total: 1), to: book, scope: scope, requiresOCR: true)
        book = try await store.finish(book, scope: scope)
        try await store.ensureCover(book: book, scope: scope, allowNetwork: false)
        let bytes = try await store.coverData(book: book, scope: scope)
        XCTAssertNotNil(bytes)
        let saved = try await store.load(id: book.id, scope: scope)
        XCTAssertEqual(saved?.cover?.fromShelf, false)
        XCTAssertEqual(saved?.pages, book.pages)
        XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".ocr") })
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        let file = try XCTUnwrap(files.first { $0.hasSuffix(".jpg") })
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(file))
        let corrupt = try await store.coverData(book: book, scope: scope)
        XCTAssertNil(corrupt)
        try await store.ensureCover(book: book, scope: scope, allowNetwork: false)
        let repaired = try await store.coverData(book: book, scope: scope)
        XCTAssertEqual(repaired, bytes)
        let url = "https://offline-cover-test.invalid/\(UUID().uuidString).jpg"
        let shelfCover = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        ImageCache.shared.set(url, image: shelfCover)
        let beforeUpgrade = try await store.load(id: book.id, scope: scope)
        try await store.ensureCover(book: book, scope: scope, coverURL: url, allowNetwork: false)
        let upgraded = try await store.load(id: book.id, scope: scope)
        XCTAssertEqual(upgraded?.cover?.fromShelf, true)
        XCTAssertEqual(upgraded?.updatedAt, beforeUpgrade?.updatedAt, "Backfilling covers must not reorder the library")
        _ = try await store.saveCover(try XCTUnwrap(raw.paragraphs.first?.imageData), fromShelf: false, book: book, scope: scope)
        let afterLateFallback = try await store.load(id: book.id, scope: scope)
        XCTAssertEqual(afterLateFallback?.cover, upgraded?.cover, "A late first-page fallback must not overwrite the real cover")
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
        XCTAssertEqual(download.phase, KindleOfflineDownloadCoordinator.StopReason.background.message)
    }

    func testReadinessTimeoutRetriesTheSameUncommittedPage() async throws {
        let source = OfflineSourceFixture(book: self.source, document: document())
        source.readinessFailurePage = 6; source.readinessFailuresRemaining = 1
        let download = KindleOfflineDownloadCoordinator(store: KindleOfflineBookStore(root: root))
        download.start(source: source, scope: scope, stillAuthorized: { true })
        try await waitUntilStopped(download)
        XCTAssertEqual(download.book?.status, .complete)
        XCTAssertEqual(download.book?.pages.count, 37)
        XCTAssertEqual(source.requestedPages.filter { $0 == 6 }.count, 2)
        XCTAssertEqual(source.requestedPages.filter { $0 == 0 }.count, 1)
        XCTAssertEqual(source.cleanupCount, 1)
    }

    func testReadinessRetriesAreBoundedAndRemainCancellable() async throws {
        let source = OfflineSourceFixture(book: self.source, document: document())
        source.readinessFailurePage = 3; source.readinessFailuresRemaining = 10
        let download = KindleOfflineDownloadCoordinator(store: KindleOfflineBookStore(root: root))
        download.start(source: source, scope: scope, stillAuthorized: { true })
        try await waitUntilStopped(download)
        XCTAssertEqual(source.requestedPages.filter { $0 == 3 }.count, 3)
        XCTAssertEqual(download.book?.pages.count, 3)
        XCTAssertEqual(download.book?.status, .failed)
        download.start(source: source, scope: scope, stillAuthorized: { true })
        let deadline = Date().addingTimeInterval(5)
        let retryPhase = AppLocalized("正在重试第 \(4) 页（\(1)/2）…")
        while download.phase != retryPhase, download.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(download.phase, retryPhase)
        let requestsBeforeCancel = source.requestedPages.count
        await download.stopAndWait()
        XCTAssertEqual(source.requestedPages.count, requestsBeforeCancel)
        XCTAssertEqual(download.book?.pages.count, 3)
        XCTAssertEqual(download.book?.status, .paused)
        XCTAssertEqual(download.book?.originalPositionRestored, true)
    }

    func testFirstPageSeekDoesNotInflateRemainingTime() async throws {
        let source = OfflineSourceFixture(book: self.source, document: document())
        source.firstCaptureDelay = .seconds(2)
        source.captureDelay = .milliseconds(150)
        let download = KindleOfflineDownloadCoordinator(store: KindleOfflineBookStore(root: root))
        download.start(source: source, scope: scope, stillAuthorized: { true })
        let deadline = Date().addingTimeInterval(8)
        while download.estimatedRemainingSeconds == nil, download.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pageCount = download.book?.pages.count ?? 0
        let estimate = download.estimatedRemainingSeconds
        await download.stopAndWait()
        XCTAssertGreaterThanOrEqual(pageCount, 10, "An initial seek is not evidence of steady per-page throughput")
        XCTAssertNotNil(estimate)
        XCTAssertLessThanOrEqual(estimate ?? Int.max, 15)
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
    var readinessFailurePage: Int?
    var readinessFailuresRemaining = 0
    var cleanupCount = 0
    var requestedPages: [Int] = []
    var beginDelay: Duration = .zero
    var captureDelay: Duration = .zero
    var firstCaptureDelay: Duration = .zero
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
        if requestedPages.count == 1, firstCaptureDelay != .zero { try await Task.sleep(for: firstCaptureDelay) }
        if captureDelay != .zero { try await Task.sleep(for: captureDelay) }
        if page == readinessFailurePage, readinessFailuresRemaining > 0 {
            readinessFailuresRemaining -= 1
            throw KindleOfflineCaptureFailure.pageNotReady
        }
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
        var returnEmpty = false
        var language = "en-US"
        var text = "Recognized only when listening."
        func recognize(_ page: ReadingDocument, sourceWordCount: Int?) async throws -> ReadingDocument {
            calls += 1
            try await Task.sleep(for: delay)
            if shouldFail { throw OCRError.noText }
            if returnEmpty { return page }
            var result = page
            result.language = language
            result.paragraphs.append(ReadingParagraph(id: 1, text: text, pageIndex: 0))
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

    private func orderedBook(root: URL, texts: [String?]) async throws -> (KindleOfflineBookStore, KindleOfflineBook, String) {
        let store = KindleOfflineBookStore(root: root), scope = KindleOfflinePageStore.digest("ordered-reader")
        let source = KindleBook(id: "ordered-reader", title: "Ordered chapters", author: "Test",
            readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "", lastSyncedAt: Date())
        func position(_ index: Int) -> KindleOfflineSourcePosition {
            .init(start: index * 10, end: index * 10 + 9, minimum: 0, maximum: texts.count * 10 - 1,
                layoutID: "fixture", fingerprint: "page-\(index)")
        }
        var book = try await store.prepare(source: source, scope: scope, originalPosition: position(0))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        for (index, text) in texts.enumerated() {
            var paragraphs = [ReadingParagraph(id: 0, text: "", type: .image, imageData: image)]
            if let text { paragraphs.append(ReadingParagraph(id: 1, text: text)) }
            let doc = ReadingDocument(title: "Ordered chapters", sourceKind: .kindle, language: "en-US", paragraphs: paragraphs)
            book = try await store.append(document: doc, position: position(index), to: book, scope: scope,
                requiresOCR: text == nil, sourceWordCount: 10)
        }
        return (store, try await store.finish(book, scope: scope), scope)
    }

    private func waitForSession(_ center: KindleOfflinePlaybackCenter) async throws {
        let end = Date().addingTimeInterval(4)
        while center.model?.pageImage == nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(center.model?.pageImage)
    }

    func testMiniPlayerRetainsSpeechWordAndModelAcrossRepeatedExpansion() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await orderedBook(root: root, texts: ["One two three four."])
        let center = KindleOfflinePlaybackCenter(), driver = Driver()
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true })
        center.open(book: book, scope: scope, store: store, scopeValidator: { true }, makeModel: { model })
        defer { center.stop() }
        try await waitForSession(center)
        model.play()
        while driver.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let request = try XCTUnwrap(driver.requests.first)
        driver.onEvent?(.started(request.id))
        driver.onEvent?(.range(request.id, NSRange(location: 4, length: 3)))
        let token = AudioPlayerService.shared.activePlaybackSession
        for _ in 0..<5 {
            center.minimize()
            XCTAssertTrue(center.showsMiniPlayer)
            XCTAssertEqual(model.speech.state, .speaking)
            center.open(book: book, scope: scope, store: store, scopeValidator: { true })
            XCTAssertTrue(center.model === model)
            XCTAssertTrue(center.isPresented)
        }
        XCTAssertEqual(driver.requests.count, 1, "Minimizing/expanding cannot requeue speech")
        XCTAssertEqual(model.speech.highlightRange, NSRange(location: 4, length: 3))
        XCTAssertEqual(AudioPlayerService.shared.activePlaybackSession, token)
        center.minimize(); model.pause(); center.expand()
        XCTAssertEqual(model.speech.state, .paused)
        center.stop()
        XCTAssertNil(center.model)
        driver.onEvent?(.finished(request.id))
        XCTAssertNil(center.model, "Late speech must not resurrect a stopped mini player")
    }

    func testMinimizedSessionContinuesPagesInOrderAndRejectsDuplicates() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = ["Chapter one.", "Chapter two.", "Chapter three."]
        let (store, book, scope) = try await orderedBook(root: root, texts: text.map { Optional($0) })
        let driver = Driver(), center = KindleOfflinePlaybackCenter()
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true })
        center.open(book: book, scope: scope, store: store, scopeValidator: { true }, makeModel: { model })
        defer { center.stop() }
        try await waitForSession(center); model.play(); center.minimize()
        for index in text.indices {
            let end = Date().addingTimeInterval(3)
            while driver.requests.count <= index, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
            guard driver.requests.indices.contains(index) else { return XCTFail("Missing page \(index)") }
            XCTAssertTrue(center.showsMiniPlayer)
            XCTAssertEqual(model.pageIndex, index)
            let id = driver.requests[index].id
            driver.onEvent?(.started(id)); driver.onEvent?(.finished(id)); driver.onEvent?(.finished(id))
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(driver.requests.map(\.text), text)
        center.expand()
        XCTAssertEqual(model.pageIndex, 2)
        XCTAssertEqual(model.speech.state, .finished)
    }

    func testAccountBoundaryClosesMinimizedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        var valid = true
        let center = KindleOfflinePlaybackCenter()
        center.open(book: book, scope: scope, store: store, scopeValidator: { valid })
        defer { center.stop() }
        try await waitForSession(center); center.minimize()
        valid = false
        KindleLibraryStore.shared.objectWillChange.send()
        let end = Date().addingTimeInterval(3)
        while center.model != nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(center.model)
        center.expand()
        XCTAssertFalse(center.isPresented)
    }

    func testOpeningOnlineOwnerClosesOfflineSessionWithoutStoppingNewOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        let center = KindleOfflinePlaybackCenter()
        center.open(book: book, scope: scope, store: store, scopeValidator: { true })
        try await waitForSession(center)
        center.minimize()
        let audio = AudioPlayerService.shared
        let token = audio.claimPlaybackSession(owner: .readAloud)
        defer { audio.releasePlaybackSession(token) }
        XCTAssertNil(center.model)
        XCTAssertFalse(center.showsMiniPlayer)
        XCTAssertTrue(audio.isPlaybackSessionActive(token))
        center.stop()
        XCTAssertTrue(audio.isPlaybackSessionActive(token))
    }

    func testDeletingActiveLocalCopyClosesMiniPlayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        let center = KindleOfflinePlaybackCenter()
        center.open(book: book, scope: scope, store: store, scopeValidator: { true })
        defer { center.stop() }
        try await waitForSession(center); center.minimize()
        try await store.remove(id: book.id, scope: scope)
        let end = Date().addingTimeInterval(3)
        while center.model != nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(center.model)
    }

    func testStopDuringOCRNeverRestartsHiddenSpeech() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        let center = KindleOfflinePlaybackCenter(), driver = Driver(), recognizer = Recognizer()
        recognizer.delay = .milliseconds(300)
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true }, recognizer: recognizer)
        center.open(book: book, scope: scope, store: store, scopeValidator: { true }, makeModel: { model })
        try await waitForSession(center); model.play(); center.minimize()
        try await Task.sleep(for: .milliseconds(40))
        center.stop()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(driver.requests.isEmpty)
        XCTAssertNil(center.model)
    }

    func testChangingSessionBeforeDownloadDismissalCancelsPendingReader() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        let center = KindleOfflinePlaybackCenter()
        center.prepareAfterDownload(book: book, scope: scope, store: store, scopeValidator: { true })
        center.stop(preservingSleepTimer: true)
        center.presentAfterDownload()
        await Task.yield()
        XCTAssertNil(center.model)
        XCTAssertFalse(center.isPresented)
    }

    func testStoppingBeforeOpenTaskCannotClaimPlaybackLater() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        let center = KindleOfflinePlaybackCenter()
        center.open(book: book, scope: scope, store: store, scopeValidator: { true })
        center.stop()
        let token = AudioPlayerService.shared.claimPlaybackSession(owner: .readAloud)
        defer { AudioPlayerService.shared.releasePlaybackSession(token) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(center.model)
        XCTAssertTrue(AudioPlayerService.shared.isPlaybackSessionActive(token))
    }

    func testChapterSequenceRejectsDuplicateAndLateSpeechCallbacks() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let texts = ["Chapter one first page.", "Chapter one second page.", "Chapter two first page.",
                     "Chapter two second page.", "Chapter three first page.", "Chapter three last page."]
        let (store, book, scope) = try await orderedBook(root: root, texts: texts.map { Optional($0) })
        let driver = Driver()
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true })
        defer { model.close() }
        await model.open(); model.play()
        for index in texts.indices {
            let deadline = Date().addingTimeInterval(3)
            while driver.requests.count <= index, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard driver.requests.indices.contains(index) else { return XCTFail("Stopped before page \(index)") }
            XCTAssertEqual(model.pageIndex, index)
            XCTAssertEqual(driver.requests[index].text, texts[index])
            for prior in driver.requests.prefix(index) {
                driver.onEvent?(.started(prior.id)); driver.onEvent?(.finished(prior.id))
            }
            XCTAssertEqual(model.pageIndex, index, "Late callbacks cannot return to another chapter")
            let request = driver.requests[index]
            driver.onEvent?(.started(request.id)); driver.onEvent?(.finished(request.id)); driver.onEvent?(.finished(request.id))
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(driver.requests.map(\.text), texts, "Every page is enqueued once in source order")
    }

    func testEmptyOCRDoesNotSilentlySkipToNextChapter() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await orderedBook(root: root, texts: [nil, "The next chapter."])
        let recognizer = Recognizer(), driver = Driver(); recognizer.returnEmpty = true
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true }, recognizer: recognizer)
        defer { model.close() }
        await model.open(); model.play()
        let deadline = Date().addingTimeInterval(3)
        while model.preparingSpeech, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.error); XCTAssertEqual(model.pageIndex, 0); XCTAssertTrue(driver.requests.isEmpty)
        recognizer.returnEmpty = false; model.play()
        let retryDeadline = Date().addingTimeInterval(3)
        while driver.requests.isEmpty, Date() < retryDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recognizer.calls, 2, "An empty OCR result cannot poison the retry cache")
        XCTAssertEqual(driver.requests.first?.text, "Recognized only when listening.")
        XCTAssertEqual(model.pageIndex, 0)
    }

    private final class DeferredRecognizer: KindleOfflineRecognizing {
        var continuation: CheckedContinuation<ReadingDocument, Error>?
        var page: ReadingDocument?
        func recognize(_ page: ReadingDocument, sourceWordCount: Int?) async throws -> ReadingDocument {
            self.page = page
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func complete() {
            guard var page, let continuation else { return }
            self.continuation = nil
            page.language = "en-US"
            page.paragraphs.append(ReadingParagraph(id: 1, text: "An old chapter returned late."))
            continuation.resume(returning: page)
        }
    }

    func testLateOCRCannotReplaceTheSelectedChapter() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await orderedBook(root: root, texts: [nil, "The selected chapter."])
        let recognizer = DeferredRecognizer(), driver = Driver()
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true }, recognizer: recognizer)
        defer { recognizer.complete(); model.close() }
        await model.open(); model.play()
        let deadline = Date().addingTimeInterval(3)
        while recognizer.continuation == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(recognizer.continuation)
        model.selectPage(1)
        while model.pageIndex != 1 || model.loading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.play(); recognizer.complete()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertEqual(driver.requests.map(\.text), ["The selected chapter."])
    }

    func testPauseRevokesAlreadyQueuedAutomaticPageAdvance() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await orderedBook(root: root, texts: ["First page.", "Second page.", "Third page."])
        let driver = Driver()
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true })
        defer { model.close() }
        await model.open(); model.play()
        let first = try XCTUnwrap(driver.requests.first)
        driver.onEvent?(.started(first.id)); driver.onEvent?(.finished(first.id))
        XCTAssertEqual(model.speech.state, .finished)
        XCTAssertTrue(model.canPausePlayback, "The reader and mini player must still offer Pause between pages")
        model.pause() // The page continuation Task has been queued but has not run.
        XCTAssertFalse(model.canPausePlayback, "The user's pause must immediately revoke the queued continuation")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.pageIndex, 0)
        XCTAssertEqual(driver.requests.map(\.text), ["First page."])
        model.play()
        let deadline = Date().addingTimeInterval(3)
        while driver.requests.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(driver.requests.map(\.text), ["First page.", "Second page."])
    }

    func testCloseAndReopenRestoresPageVoiceAndRateWithoutStartingSpeech() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await orderedBook(root: root, texts: ["First page.", "Second page."])
        let driver = Driver()
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true })
        defer { model.close() }
        await model.open(); model.selectPage(1)
        let deadline = Date().addingTimeInterval(3)
        while model.pageIndex != 1 || model.loading, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let voice = try XCTUnwrap(model.voices.last)
        model.changeVoice(voice.id); model.changeRate(0.6); model.close()
        await model.open()
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertEqual(model.voiceID, voice.id)
        XCTAssertEqual(model.speechRate, 0.6)
        XCTAssertTrue(driver.requests.isEmpty)
        model.play()
        XCTAssertEqual(driver.requests.first?.text, "Second page.")
        XCTAssertEqual(driver.requests.first?.rate, 0.6)
    }

    func testMissingNextPageNeverReplaysPreviousPageUnderItsNewPageNumber() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await orderedBook(root: root, texts: ["First page.", "Second page."])
        let file = root.appendingPathComponent(scope).appendingPathComponent(book.id)
            .appendingPathComponent(book.generation.uuidString).appendingPathComponent(book.id)
            .appendingPathComponent(book.pages[1].resource.snapshotHash + ".page")
        try FileManager.default.removeItem(at: file)
        let driver = Driver()
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true })
        defer { model.close() }
        await model.open(); model.selectPage(1)
        let deadline = Date().addingTimeInterval(3)
        while model.error == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.pageIndex, 1); XCTAssertNil(model.document)
        XCTAssertTrue(model.speech.units.isEmpty)
        model.play(); try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(driver.requests.isEmpty)
    }

    func testReopeningDeletedCopyClearsOldDocumentAndPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await orderedBook(root: root, texts: ["First page.", "Second page."])
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: Driver()), scopeValidator: { true })
        defer { model.close() }
        await model.open(); XCTAssertNotNil(model.document)
        model.close(); try await store.remove(id: book.id, scope: scope)
        await model.open()
        XCTAssertNil(model.document); XCTAssertTrue(model.speech.units.isEmpty)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.loading)
    }

    func testRealLocalOCRRecognizesSavedImageWithoutOnlineReader() async throws {
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 1100, height: 500)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1100, height: 500))
            ("A journey begins today.\nWe can read this page offline." as NSString).draw(
                in: CGRect(x: 60, y: 70, width: 980, height: 360),
                withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
        }
        let page = ReadingDocument(title: "Local OCR fixture", sourceKind: .kindle, language: "und",
            paragraphs: [ReadingParagraph(id: 0, text: "", type: .image, imageData: bytes)])
        let recognized = try await KindleOfflineOCRService().recognize(page, sourceWordCount: 11)
        let text = recognized.paragraphs.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("journey")); XCTAssertTrue(text.contains("offline"))
        XCTAssertEqual(recognized.paragraphs.first?.imageData, bytes)
        XCTAssertEqual(recognized.paragraphs.map(\.id), Array(recognized.paragraphs.indices))
        XCTAssertTrue(recognized.paragraphs.dropFirst().contains { !$0.words.isEmpty })
    }

    func testLocalOCRDetectsSimplifiedAndTraditionalChineseWithoutShelfLanguage() async throws {
        for (language, text, expected) in [
            ("zh-Hans", "我们一起读书，听见中文的声音。\n离线阅读不需要网络。", "离线阅读"),
            ("zh-Hant", "我們一起讀書，聽見中文的聲音。\n離線閱讀不需要網路。", "離線閱讀")
        ] {
            let bytes = UIGraphicsImageRenderer(size: CGSize(width: 1100, height: 500)).pngData { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1100, height: 500))
                (text as NSString).draw(in: CGRect(x: 60, y: 70, width: 980, height: 360),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
            }
            let raw = ReadingDocument(title: "Offline fixture", sourceKind: .kindle, language: "und",
                paragraphs: [ReadingParagraph(id: 0, text: "", type: .image, imageData: bytes)])
            let doc = try await KindleOfflineOCRService().recognize(raw, sourceWordCount: 28)
            XCTAssertEqual(doc.language, language)
            XCTAssertTrue(doc.fullText.contains(expected), "The original Chinese script must survive OCR")
            XCTAssertEqual(doc.paragraphs.first?.imageData, bytes)
            XCTAssertTrue(doc.paragraphs.dropFirst().allSatisfy { !$0.words.isEmpty })
        }
    }

    func testChineseDetectionReplacesEnglishVoiceAndSurvivesColdReopen() async throws {
        let voices = await SystemSpeechPlaybackService.availableVoices(language: "zh-Hant")
        guard !voices.isEmpty else { throw XCTSkip("Chinese voice unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, book, scope) = try await imageBook(root: root)
        var cursor = book.readingPosition; cursor.voiceID = "com.apple.voice.super-compact.en-US.Samantha"
        try await store.saveReadingPosition(cursor, book: book, scope: scope)
        let recognizer = Recognizer(), driver = Driver()
        recognizer.language = "zh-Hant"; recognizer.text = "離線閱讀中文書籍。"
        let model = KindleOfflineBookReaderModel(book: book, scope: scope, store: store,
            speech: SystemSpeechPlaybackService(driver: driver), scopeValidator: { true }, recognizer: recognizer)
        await model.open()
        XCTAssertEqual(recognizer.calls, 0)
        XCTAssertTrue(model.speech.units.isEmpty)
        model.play()
        let deadline = Date().addingTimeInterval(5)
        while driver.requests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(driver.requests.first?.text, recognizer.text)
        XCTAssertTrue(voices.contains { $0.id == driver.requests.first?.voiceID })
        model.close()
        let saved = try await store.load(id: book.id, scope: scope)
        let fresh = try XCTUnwrap(saved)
        XCTAssertEqual(fresh.recognizedLanguage, "zh-Hant")
        XCTAssertEqual(fresh.pages, book.pages, "Language repair must not replace or reorder downloaded images")
        let coldRecognizer = Recognizer(), coldDriver = Driver()
        let cold = KindleOfflineBookReaderModel(book: fresh, scope: scope, store: KindleOfflineBookStore(root: root),
            speech: SystemSpeechPlaybackService(driver: coldDriver), scopeValidator: { true }, recognizer: coldRecognizer)
        defer { cold.close() }
        await cold.open(); cold.play()
        XCTAssertEqual(coldRecognizer.calls, 0)
        XCTAssertEqual(coldDriver.requests.first?.text, recognizer.text)
        XCTAssertTrue(cold.voices.allSatisfy { $0.language.hasPrefix("zh-") })
    }

    func testOpeningAnImageBookDoesNotOCRAndPlaybackRecognitionSurvivesColdReopen() async throws {
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
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
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English voice unavailable") }
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
        guard (await SystemSpeechPlaybackService.availableVoices(language: "en-US")).isEmpty == false else { throw XCTSkip("English system voice unavailable") }
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
