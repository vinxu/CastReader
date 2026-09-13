import XCTest
import UIKit
@testable import CastReader

@MainActor
final class KindleOfflinePageStoreTests: XCTestCase {
    private var root: URL!
    private let scope = KindleOfflinePageStore.digest("test-account-a")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflinePageTests-" + UUID().uuidString)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func document() -> ReadingDocument {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        let word = OCRWord(id: 6, text: "Hello", bboxNorm: CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.1),
            bboxSource: .visionTextRange, sourceLineID: 8, recognitionConfidence: 0.95,
            inkBoundsNorm: CGRect(x: 0.11, y: 0.61, width: 0.28, height: 0.08), inkBoundsChecked: true)
        return ReadingDocument(title: "Local test", sourceKind: .kindle, language: "en-US", paragraphs: [
            ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: data),
            ReadingParagraph(id: 1, text: "Hello world. A second sentence.", words: [word], bboxNorm: word.bboxNorm,
                visualFragments: [.init(column: .left, bboxNorm: word.bboxNorm, wordIDs: [6])], pageIndex: 0)
        ])
    }

    func testColdReopenPreservesPixelsTextAndGeometryWithoutOCR() async throws {
        let original = document()
        let saved = try await KindleOfflinePageStore(root: root).save(document: original, pageKey: "book-a:page-1", scope: scope)
        let storeAfterRestart = KindleOfflinePageStore(root: root)
        let (_, opened) = try await storeAfterRestart.open(saved.id, scope: scope)
        XCTAssertEqual(opened.paragraphs, original.paragraphs)
        XCTAssertEqual(opened.language, original.language)
        XCTAssertNil(opened.sourceURL)
        let values = try root.appendingPathComponent(scope).resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testDuplicateSaveIsIdempotentButIdenticalBlankPageOccurrencesStaySeparate() async throws {
        let store = KindleOfflinePageStore(root: root), doc = document()
        let first = try await store.save(document: doc, pageKey: "book-a:page-1", scope: scope)
        let repeated = try await store.save(document: doc, pageKey: "book-a:page-1", scope: scope)
        let next = try await store.save(document: doc, pageKey: "book-a:page-2", scope: scope)
        XCTAssertEqual(first.id, repeated.id)
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertEqual(first.imageHash, next.imageHash)
        let pages = try await store.list(scope: scope)
        XCTAssertEqual(pages.count, 2)
    }

    func testAccountsCannotListOrReadEachOthersContentAndPathsAreValidated() async throws {
        let store = KindleOfflinePageStore(root: root)
        let page = try await store.save(document: document(), pageKey: "book:1", scope: scope)
        let other = KindleOfflinePageStore.digest("test-account-b")
        let otherPages = try await store.list(scope: other)
        XCTAssertTrue(otherPages.isEmpty)
        do { _ = try await store.open(page.id, scope: other); XCTFail("cross-account open") } catch {}
        do { _ = try await store.list(scope: "../other"); XCTFail("invalid namespace") } catch {}
    }

    func testSentenceCheckpointIsIndependentFromCapturesAndSurvivesRestart() async throws {
        let store = KindleOfflinePageStore(root: root), doc = document()
        let page = try await store.save(document: doc, pageKey: "book:1", scope: scope)
        let checkpoint = KindleOfflinePageStore.Checkpoint(snapshotHash: page.snapshotHash, paragraphID: 1, sentenceStart: 13, voiceID: "test-local")
        try await store.saveCheckpoint(checkpoint, pageID: page.id, scope: scope)
        _ = try await store.save(document: doc, pageKey: "book:2", scope: scope)
        let reopened = try await KindleOfflinePageStore(root: root).checkpoint(pageID: page.id, scope: scope)
        XCTAssertEqual(reopened, checkpoint)
        do {
            try await store.saveCheckpoint(.init(snapshotHash: "wrong", paragraphID: 1, sentenceStart: 0, voiceID: "test"), pageID: page.id, scope: scope)
            XCTFail("stale content position")
        } catch {}
    }

    func testCorruptPageFailsClosedAndExplicitRecaptureRepairsIt() async throws {
        let store = KindleOfflinePageStore(root: root), doc = document()
        let page = try await store.save(document: doc, pageKey: "book:1", scope: scope)
        let image = root.appendingPathComponent(scope).appendingPathComponent(page.imageHash + ".image")
        try Data("corrupt".utf8).write(to: image)
        do { _ = try await store.open(page.id, scope: scope); XCTFail("corrupt image opened") } catch {}
        do { try await store.verify([page], scope: scope); XCTFail("corrupt image verified") } catch {}
        let repaired = try await store.save(document: doc, pageKey: "book:1", scope: scope)
        XCTAssertEqual(repaired.id, page.id)
        let (_, opened) = try await store.open(page.id, scope: scope)
        XCTAssertEqual(opened.paragraphs, doc.paragraphs)
        try await store.verify([page], scope: scope)
        do {
            try await store.verify([page], scope: KindleOfflinePageStore.digest("missing-book"))
            XCTFail("missing page verified")
        } catch {}
    }

    func testOrphanFilesNeverCountAsSavedPagesAndExplicitSavesAreNotEvicted() async throws {
        let store = KindleOfflinePageStore(root: root), doc = document()
        for index in 0..<30 { _ = try await store.save(document: doc, pageKey: "book:\(index)", scope: scope) }
        try Data("interrupted-stage".utf8).write(to: root.appendingPathComponent(scope).appendingPathComponent("uncommitted.page"))
        let pages = try await KindleOfflinePageStore(root: root).list(scope: scope)
        XCTAssertEqual(pages.count, 30)
        for page in pages { _ = try await store.open(page.id, scope: scope) }
    }
}
