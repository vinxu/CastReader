import XCTest
import PDFKit
@testable import CastReader

@MainActor
final class LocalDocumentCacheTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func epub() throws -> ReadingDocument {
        try XCTUnwrap(DocumentBuilder.fromEPUB(data: ReadingResumeFixtureSpeech.epub(), title: "Cache fixture"))
    }

    func testEPUBImportSeedsPersistentCacheAndColdHistoryPreservesAllParagraphs() async throws {
        let root = try directory()
        let history = HistoryStore(directory: root)
        let document = try epub()
        history.record(document)
        let record = try XCTUnwrap(history.records.first)
        let reopened = try await history.reopen(record)
        XCTAssertEqual(reopened?.paragraphs, document.paragraphs)
        let snapshot = LocalDocumentCache.url(id: record.id, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        let cold = HistoryStore(directory: root)
        let loaded = try await cold.reopen(try XCTUnwrap(cold.records.first))
        XCTAssertEqual(loaded?.id, document.id)
        XCTAssertEqual(loaded?.paragraphs, document.paragraphs)
        XCTAssertEqual(loaded?.precomputedResumeIndex, ReadingResumeDocumentIndex(paragraphs: document.paragraphs))
        let bytes = try Data(contentsOf: snapshot)
        let cached = try PropertyListDecoder().decode(LocalDocumentCache.Snapshot.self, from: bytes)
        XCTAssertEqual(cached.payloadFingerprint, ReadingResumeContract.fingerprint(document.fileData!))
        XCTAssertEqual(cached.paragraphs.count, 200)
    }

    func testSnapshotPreservesEPUBStylesImagesAndPDFRanges() async throws {
        let root = try directory()
        let history = HistoryStore(directory: root)
        let image = Data([1, 2, 3, 4])
        let paragraphs = [
            ReadingParagraph(id: 0, text: "Title", type: .heading(2)),
            ReadingParagraph(id: 1, text: "", type: .image, imageData: image),
            ReadingParagraph(id: 2, text: "", type: .image, imageData: image),
            ReadingParagraph(id: 3, text: "Quotation", type: .blockquote),
            ReadingParagraph(id: 4, text: "List item", type: .list),
            ReadingParagraph(id: 5, text: "Code", type: .code),
            ReadingParagraph(id: 6, text: "Caption", type: .caption)
        ]
        let document = ReadingDocument(title: "Types", sourceKind: .epub, language: "en",
                                       paragraphs: paragraphs, fileData: Data("payload".utf8))
        history.record(document)
        let loaded = try await history.reopen(try XCTUnwrap(history.records.first))
        XCTAssertEqual(loaded?.paragraphs, paragraphs)
        let data = try Data(contentsOf: LocalDocumentCache.url(id: document.id, in: root))
        let snapshot = try PropertyListDecoder().decode(LocalDocumentCache.Snapshot.self, from: data)
        XCTAssertEqual(snapshot.images.count, 1, "Repeated EPUB images should share bytes")

        let pdfParagraphs = [ReadingParagraph(id: 0, text: "PDF text", pdfPageIndex: 81,
                                             pdfRange: NSRange(location: 352, length: 8))]
        let pdf = ReadingDocument(title: "PDF", sourceKind: .pdf, language: "en",
                                  paragraphs: pdfParagraphs, fileData: Data("pdf payload".utf8))
        history.record(pdf)
        let restored = try await history.reopen(try XCTUnwrap(history.records.first))
        XCTAssertEqual(restored?.paragraphs, pdfParagraphs)
        XCTAssertEqual(restored?.usesNativePDFRendering, pdf.usesNativePDFRendering)
    }

    func testCorruptAndOldParserCacheRebuildWithoutChangingSavedPosition() async throws {
        let root = try directory()
        let history = HistoryStore(directory: root)
        let document = try epub()
        history.record(document)
        let record = try XCTUnwrap(history.records.first)
        _ = try await history.reopen(record)
        let cache = LocalDocumentCache.url(id: record.id, in: root)
        history.updateReadingPosition(documentID: record.id, paragraphIndex: 199)
        try Data("corrupt".utf8).write(to: cache)
        let rebuilt = try await history.reopen(try XCTUnwrap(history.records.first))
        XCTAssertEqual(rebuilt?.paragraphs, document.paragraphs)
        XCTAssertEqual(history.records.first?.lastParagraphIndex, 199)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: cache), format: nil) as? [String: Any])
        plist["version"] = -1
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: cache)
        let rebuiltAgain = try await history.reopen(try XCTUnwrap(history.records.first))
        XCTAssertEqual(rebuiltAgain?.paragraphs, document.paragraphs)
        XCTAssertEqual(history.records.first?.lastParagraphIndex, 199)
    }

    func testSameSizeChangedPayloadCannotUseStaleCacheAndMissingFileCannotOpen() async throws {
        let root = try directory()
        let history = HistoryStore(directory: root)
        let document = try epub()
        history.record(document)
        let record = try XCTUnwrap(history.records.first)
        _ = try await history.reopen(record)
        let payload = root.appendingPathComponent(record.id + ".payload")
        var different = document.fileData!
        different.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        try different.write(to: payload, options: .atomic)
        let cache = LocalDocumentCache.url(id: record.id, in: root)
        let worker = Task.detached { try await LocalDocumentCache.load(record: record, payloadURL: payload, cacheURL: cache) }
        let result = try await worker.value
        if let temporary = result?.preparedSnapshot { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertNotEqual(result?.cacheHit, true, "Same byte count must never establish content identity")
        try FileManager.default.removeItem(at: payload)
        let missing = try await history.reopen(record)
        XCTAssertNil(missing, "A derived cache cannot revive a missing original")
    }

    func testReopenDoesNotRewritePayloadAndDeleteRemovesDerivedContent() async throws {
        let root = try directory()
        let history = HistoryStore(directory: root)
        let document = try epub()
        history.record(document)
        let payload = root.appendingPathComponent(document.id + ".payload")
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: payload.path)
        let loaded = try await history.reopen(try XCTUnwrap(history.records.first))
        history.recordReopenedLocalDocument(try XCTUnwrap(loaded))
        let modified = try payload.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(modified, old)
        history.delete(document.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalDocumentCache.url(id: document.id, in: root).path))
    }

    func testRemoteContentCannotProduceOrReadLocalParsedCache() throws {
        var document = try epub()
        document.persistencePolicy = .remoteReference
        XCTAssertNil(try LocalDocumentCache.Snapshot(document: document, fingerprint: "any"))
    }

    func testEditingCachedParagraphsInvalidatesDerivedIndex() throws {
        var document = try epub()
        document.precomputedResumeIndex = ReadingResumeDocumentIndex(paragraphs: document.paragraphs)
        document.paragraphs[0] = ReadingParagraph(id: 0, text: "Edited paragraph")
        XCTAssertNil(document.precomputedResumeIndex)
    }

    /// Optional private reproduction file copied locally from the user's phone;
    /// it is never bundled, printed or committed. Compares the same real parser
    /// with cold disk-cache loads and verifies every paragraph/geometry field.
    func testUserPDFReopenPerformanceSample() async throws {
        let input = URL(fileURLWithPath: "/tmp/castreader-document-reopen-fixture.pdf")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("No local reproduction PDF") }
        let root = try directory()
        let data = try Data(contentsOf: input)
        let start = Date()
        let worker = Task.detached {
            try await DocumentBuilder.fromPDFWithOCR(data: data, title: "Performance sample")
        }
        let parsed = try await worker.value
        let document = try XCTUnwrap(parsed)
        let parseSeconds = Date().timeIntervalSince(start)
        let history = HistoryStore(directory: root)
        history.record(document)
        _ = try await history.reopen(try XCTUnwrap(history.records.first))
        var timings: [Double] = []
        for _ in 0..<3 {
            let cold = HistoryStore(directory: root)
            let start = Date()
            let restored = try await cold.reopen(try XCTUnwrap(cold.records.first))
            timings.append(Date().timeIntervalSince(start))
            XCTAssertEqual(restored?.paragraphs, document.paragraphs)
        }
        print("LOCAL PERF PDF bytes=\(data.count) paragraphs=\(document.paragraphs.count) parseSeconds=\(parseSeconds) coldCacheSeconds=\(timings)")
        XCTAssertLessThan(timings.max() ?? .infinity, parseSeconds / 3)
    }
}
