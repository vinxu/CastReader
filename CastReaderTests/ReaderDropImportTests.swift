import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import CastReader

@MainActor
final class ReaderDropImportTests: XCTestCase {
    private func model(historyStore: HistoryStore? = nil) -> ReaderDropImportModel {
        // Provider/queue contracts must not depend on a real account or on
        // whichever route a preceding routing test froze in this process.
        let token = AccountContentBoundaryToken(storageID: "drop-unit-scope", revision: 1)
        return ReaderDropImportModel(historyStore: historyStore,
            captureBoundary: { token }, validateBoundary: { $0 == token })
    }
    func testMissingAccountBoundaryRejectsDropWithoutOpeningReview() {
        let model = ReaderDropImportModel(captureBoundary: { nil }, validateBoundary: { _ in false })
        XCTAssertFalse(model.receive([NSItemProvider(object: "Unassigned text" as NSString)]))
        XCTAssertNil(model.review)
        XCTAssertFalse(model.busy)
    }

    func testAccountChangeDiscardsLateProviderPayload() async throws {
        let token = AccountContentBoundaryToken(storageID: "old-account", revision: 1)
        var valid = true
        var complete: ((Data?, Error?) -> Void)?
        let registered = expectation(description: "Provider requested")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { callback in
            Task { @MainActor in complete = callback; registered.fulfill() }
            return nil
        }
        let model = ReaderDropImportModel(captureBoundary: { token }, validateBoundary: { valid && $0 == token })
        defer { model.cancel() }
        XCTAssertTrue(model.receive([provider]))
        await fulfillment(of: [registered], timeout: 3)
        valid = false
        complete?(Data("Previous account text".utf8), nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.review?.payload, "Late content cannot cross the account boundary")
        XCTAssertTrue(model.queued.isEmpty)
    }

    private func settled(_ model: ReaderDropImportModel) async throws {
        for _ in 0..<100 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Item provider did not complete")
    }
    func testFileURLStagesOwnedCopyAndCancellationKeepsOriginal() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID()).txt")
        try Data("A retained original".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = model()
        defer { model.cancel() }
        XCTAssertTrue(model.receive([NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)]))
        try await settled(model)
        guard case .file(let staged) = model.review?.payload else { return XCTFail("Missing file") }
        XCTAssertNotEqual(source, staged)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: staged))
        model.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testImageFileRepresentationCanBeLoadedWithoutAFileURL() async throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let provider = NSItemProvider()
        provider.suggestedName = "Public image"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { callback in
            callback(data, nil); return nil
        }
        let model = model(); defer { model.cancel() }
        XCTAssertTrue(model.receive([provider])); try await settled(model)
        guard case .file(let staged) = model.review?.payload else { return XCTFail("Missing image") }
        XCTAssertEqual(staged.pathExtension, "png")
        XCTAssertNotNil(UIImage(contentsOfFile: staged.path))
    }
    func testWebLinkIsReviewedAndNonWebSchemeRejected() async throws {
        let model = model(); defer { model.cancel() }
        let url = URL(string: "https://example.com/public-article")!
        XCTAssertTrue(model.receive([NSItemProvider(object: url as NSURL)])); try await settled(model)
        guard case .link(let received) = model.review?.payload else { return XCTFail("Missing link") }
        XCTAssertEqual(received, url)
        model.cancel()
        XCTAssertTrue(model.receive([NSItemProvider(object: URL(string: "javascript:alert(1)")! as NSURL)]))
        try await settled(model)
        XCTAssertNil(model.review?.payload)
        XCTAssertNotNil(model.review?.error)
    }
    func testOverLimitAndUnsupportedDropsHaveAnExplicitError() async throws {
        let model = model(); defer { model.cancel() }
        XCTAssertTrue(model.receive((0..<9).map { NSItemProvider(object: "item \($0)" as NSString) }))
        XCTAssertNotNil(model.review?.error); XCTAssertNil(model.review?.payload)
        model.cancel()
        let provider = NSItemProvider(item: Data([1, 2, 3]) as NSData, typeIdentifier: "public.zip-archive")
        XCTAssertTrue(model.receive([provider])); try await settled(model)
        XCTAssertNotNil(model.review?.error); XCTAssertNil(model.review?.payload)
    }
    func testBoundedQueueImportsSequentiallyAndRetainsIndividualFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = HistoryStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(historyStore: history); defer { model.cancel() }
        let invalid = NSItemProvider(item: Data([1, 2, 3]) as NSData, typeIdentifier: "public.zip-archive")
        XCTAssertTrue(model.receive([NSItemProvider(object: "First public text." as NSString), invalid,
                                     NSItemProvider(object: "Second public text." as NSString)]))
        guard model.queued.count == 3 else { return XCTFail("Missing bounded import queue") }
        model.importQueue()
        try await settled(model)
        XCTAssertEqual(model.queued.compactMap(\.documentID).count, 2)
        XCTAssertNil(model.queued[1].documentID)
        XCTAssertNotNil(model.queued[1].loader.review?.error)
        XCTAssertEqual(history.records.count, 2)
        for record in history.records {
            let document = try await history.reopen(record)
            XCTAssertFalse(try XCTUnwrap(document).isEmpty)
        }
        model.importQueue(); try await settled(model)
        XCTAssertEqual(history.records.count, 2, "Retry must not duplicate completed items")
        model.cancel()
        XCTAssertEqual(history.records.count, 2, "Closing the queue preserves explicit imports")
    }

    func testDuplicateQueueItemsShareTheExistingLibraryIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = HistoryStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(historyStore: history); defer { model.cancel() }
        XCTAssertTrue(model.receive((0..<2).map { _ in NSItemProvider(object: "The same public document." as NSString) }))
        model.importQueue(); try await settled(model)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(Set(model.queued.compactMap(\.documentID)).count, 1)
    }

    func testYouTubeQueueRequiresOpeningAndNeverClaimsItWasSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = HistoryStore(directory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(historyStore: history); defer { model.cancel() }
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        XCTAssertTrue(model.receive([NSItemProvider(object: url as NSURL), NSItemProvider(object: "A public text." as NSString)]))
        model.importQueue(); try await settled(model)
        guard model.queued.count == 2 else { return XCTFail("Missing queue") }
        XCTAssertTrue(ReaderDropImportModel.isYouTube(model.queued[0].loader.review?.payload))
        XCTAssertNil(model.queued[0].documentID)
        XCTAssertEqual(model.queued[0].webLink, url)
        XCTAssertEqual(model.queued[0].status, AppLocalized("等待打开读取字幕"))
        XCTAssertEqual(history.records.count, 1)
        let scene = ReaderSceneContext()
        model.openQueued(model.queued[0].id, mode: .read, scene: scene)
        XCTAssertEqual(scene.youtubeRoutes.request?.autoplay, false)
        XCTAssertNil(model.review)
    }

    func testCancelledLateProviderCannotReopenReviewOrReplaceAnotherDrop() async throws {
        let provider = NSItemProvider()
        let delivered = expectation(description: "Late data delivered")
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { callback in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                callback(Data("Old text".utf8), nil); delivered.fulfill()
            }
            return nil
        }
        let model = model(); defer { model.cancel() }
        XCTAssertTrue(model.receive([provider])); model.cancel()
        XCTAssertTrue(model.receive([NSItemProvider(object: "New text" as NSString)])); try await settled(model)
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        guard case .text(let text) = model.review?.payload else { return XCTFail("Missing current text") }
        XCTAssertEqual(text, "New text")
        XCTAssertFalse(model.busy)
    }
}

@MainActor
final class IPadTextGeometryTests: XCTestCase {
    func testSemanticWordBoxesRemainInsideEverySupportedContainerWidth() {
        let view = ReaderUITextView.make()
        let text = String(repeating: "Reading 原文 with matching word boxes. ", count: 20) + "Final anchor"
        view.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 24)])
        let range = (text as NSString).range(of: "Final anchor")
        var initial: CGRect?
        for available in [320.0, 375, 600, 744, 834, 1024, 1194, 1366, 834, 375, 320] {
            let width = min(800, available - 32)
            view.frame = CGRect(x: 0, y: 0, width: width, height: 3000)
            view.layoutIfNeeded(); view.layoutManager.ensureLayout(for: view.textContainer)
            let rects = view.rects(forCharRange: range)
            XCTAssertFalse(rects.isEmpty)
            for rect in rects {
                XCTAssertGreaterThanOrEqual(rect.minX, -2)
                XCTAssertLessThanOrEqual(rect.maxX, width + 2)
                XCTAssertGreaterThan(rect.height, 0)
            }
            if initial == nil { initial = rects.first }
        }
        XCTAssertEqual(view.rects(forCharRange: range).first, initial)
        XCTAssertEqual(view.text, text)
    }
}
