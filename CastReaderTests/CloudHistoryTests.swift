//
//  CloudHistoryTests.swift
//  CastReaderTests
//

import XCTest
import ZIPFoundation
@testable import CastReader

@MainActor
final class CloudHistoryTests: XCTestCase {
    func testLegacyIndexDecodesWithLocalDefaultsAndStillReopens() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let openedAt = Date(timeIntervalSinceReferenceDate: 765_432_100)
        let legacy = LegacyHistoryRecord(
            id: "legacy-text",
            title: "Legacy",
            sourceKindRaw: ReadingSourceKind.text.rawValue,
            sourceURL: nil,
            language: "en",
            createdAt: openedAt.addingTimeInterval(-60),
            lastOpenedAt: openedAt,
            coverPath: nil
        )
        try JSONEncoder().encode([legacy]).write(
            to: directory.appendingPathComponent("index.json"),
            options: .atomic
        )
        try Data("Legacy payload".utf8).write(
            to: directory.appendingPathComponent("legacy-text.payload"),
            options: .atomic
        )

        let store = HistoryStore(directory: directory)
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.id, legacy.id)
        XCTAssertEqual(record.persistencePolicy, .localPayload)
        XCTAssertFalse(record.isRemoteReference)
        XCTAssertFalse(record.requiresRemoteReopen)
        XCTAssertNil(record.origin)
        XCTAssertNil(record.effectiveFormat)
        XCTAssertEqual(record.resolvedContentSessionKey, legacy.id)

        let reopenedDocument = try await store.reopen(record)
        let reopened = try XCTUnwrap(reopenedDocument)
        XCTAssertEqual(reopened.id, legacy.id)
        XCTAssertEqual(reopened.fullText, "Legacy payload")
        XCTAssertEqual(reopened.persistencePolicy, .localPayload)
        XCTAssertEqual(reopened.contentSessionKey, legacy.id)
    }

    func testRemoteReferencePersistsMetadataWithoutPayloadOrCover() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let origin = makeOrigin(revision: "rev-7")
        let sessionKey = CloudStableIdentifier.contentSessionKey(
            documentID: origin.stableDocumentID,
            revision: "rev-7",
            format: .docx
        )
        let document = ReadingDocument(
            id: origin.stableDocumentID,
            title: "Remote document",
            sourceKind: .docx,
            language: "en",
            paragraphs: [],
            coverURL: "https://example.invalid/cover.jpg",
            fileData: Data("ephemeral cloud bytes".utf8),
            origin: origin,
            // Even an erroneous caller request for local persistence must not
            // weaken the privacy boundary established by a cloud origin.
            persistencePolicy: .localPayload,
            effectiveFormat: .docx,
            exportFormat: .docx,
            contentRevision: "rev-7",
            contentSessionKey: sessionKey
        )
        XCTAssertEqual(document.persistencePolicy, .remoteReference)

        // A retry or legacy collision must not leave bytes behind either.
        let payloadURL = directory.appendingPathComponent("\(document.id).payload")
        let coverURL = directory.appendingPathComponent("\(document.id).cover.jpg")
        try Data("stale".utf8).write(to: payloadURL)
        try Data("stale-cover".utf8).write(to: coverURL)

        let store = HistoryStore(directory: directory)
        store.record(document)

        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverURL.path))
        let record = try XCTUnwrap(store.records.first)
        XCTAssertTrue(record.isRemoteReference)
        XCTAssertTrue(record.requiresRemoteReopen)
        XCTAssertNil(record.coverPath)
        XCTAssertNil(store.coverURL(for: record))
        XCTAssertEqual(record.origin, origin)
        XCTAssertEqual(record.effectiveFormat, .docx)
        XCTAssertEqual(record.exportFormat, .docx)
        XCTAssertEqual(record.contentRevision, "rev-7")
        XCTAssertEqual(record.contentSessionKey, sessionKey)
        XCTAssertEqual(record.remoteReference?.origin, origin)
        XCTAssertEqual(record.remoteReference?.contentSessionKey, sessionKey)
        XCTAssertEqual(record.origin?.maskedAccountHint, "c***@example.com")
        XCTAssertEqual(
            record.origin?.modifiedAt,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let locallyReopened = try await store.reopen(record)
        XCTAssertNil(locallyReopened)

        let reloaded = HistoryStore(directory: directory)
        let persisted = try XCTUnwrap(reloaded.records.first)
        XCTAssertEqual(persisted, record)
        XCTAssertTrue(persisted.requiresRemoteReopen)
        XCTAssertEqual(persisted.remoteReference?.exportFormat, .docx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
    }

    func testPipelineAttachesCloudMetadataAndRevisionChangesOnlyContentSession() async throws {
        let data = try makeDOCXData()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudHistoryTests-\(UUID().uuidString).docx")
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let initialOrigin = makeOrigin(revision: "picker-revision")
        let session = ImportSession(epoch: 1, scenario: .study, mode: .read)

        func importRevision(_ revision: String) async throws -> DocumentImportResult {
            let receipt = CloudDownloadReceipt(
                localURL: fileURL,
                effectiveFilename: "Remote.docx",
                effectiveMIMEType: SupportedDocumentFormat.docx.preferredMIMEType,
                effectiveFormat: .docx,
                exportFormat: .docx,
                finalRevision: revision,
                byteCount: Int64(data.count)
            )
            return try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(
                    receipt: receipt,
                    origin: initialOrigin,
                    session: session
                )
            )
        }

        let first = try await importRevision("rev-1")
        let second = try await importRevision("rev-2")

        XCTAssertEqual(first.document.id, initialOrigin.stableDocumentID)
        XCTAssertEqual(second.document.id, initialOrigin.stableDocumentID)
        XCTAssertNotEqual(first.document.contentSessionKey, second.document.contentSessionKey)
        XCTAssertEqual(first.document.contentSessionKey, first.contentSessionKey)
        XCTAssertEqual(first.document.origin, first.origin)
        XCTAssertEqual(first.document.persistencePolicy, .remoteReference)
        XCTAssertEqual(first.document.effectiveFormat, .docx)
        XCTAssertEqual(first.document.exportFormat, .docx)
        XCTAssertEqual(first.document.contentRevision, "rev-1")
        XCTAssertEqual(first.document.fileData, data)
        XCTAssertEqual(second.document.contentRevision, "rev-2")
        XCTAssertEqual(second.document.origin?.revision, "rev-2")

        let historyDirectory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let history = HistoryStore(directory: historyDirectory)
        history.record(first.document)
        let originalCreatedAt = try XCTUnwrap(history.records.first?.createdAt)
        history.record(second.document)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.id, initialOrigin.stableDocumentID)
        XCTAssertEqual(history.records.first?.createdAt, originalCreatedAt)
        XCTAssertEqual(history.records.first?.contentRevision, "rev-2")
        XCTAssertEqual(
            history.records.first?.contentSessionKey,
            second.document.contentSessionKey
        )
    }

    func testLocalDocumentRetainsPayloadBehaviorAndRemoteDeleteIsIsolated() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)

        let local = ReadingDocument(
            id: "local-document",
            title: "Local",
            sourceKind: .text,
            language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "Saved locally")]
        )
        store.record(local)
        let localPayload = directory.appendingPathComponent("local-document.payload")
        XCTAssertEqual(try Data(contentsOf: localPayload), Data("Saved locally".utf8))

        let origin = makeOrigin(revision: "remote")
        let remote = ReadingDocument(
            id: origin.stableDocumentID,
            title: "Remote",
            sourceKind: .pdf,
            paragraphs: [ReadingParagraph(id: 0, text: "Temporary")],
            fileData: Data("temporary".utf8),
            origin: origin,
            persistencePolicy: .remoteReference,
            effectiveFormat: .pdf,
            contentRevision: "remote",
            contentSessionKey: CloudStableIdentifier.contentSessionKey(
                documentID: origin.stableDocumentID,
                revision: "remote",
                format: .pdf
            )
        )
        store.record(remote)
        store.delete(remote.id)

        XCTAssertEqual(store.records.map(\.id), [local.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: localPayload.path))
        let localRecord = try XCTUnwrap(store.records.first)
        let reopenedLocal = try await store.reopen(localRecord)
        XCTAssertNotNil(reopenedLocal)
    }

    func testOversizedLegacyDocumentPayloadsAreRejectedBeforeReading() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 777_000_000)
        let formats: [(String, ReadingSourceKind)] = [
            ("oversized-pdf", .pdf),
            ("oversized-docx", .docx),
            ("oversized-epub", .epub)
        ]
        let records = formats.enumerated().map { offset, value in
            HistoryRecord(
                id: value.0,
                title: value.0,
                sourceKindRaw: value.1.rawValue,
                sourceURL: nil,
                language: "en",
                createdAt: now,
                lastOpenedAt: now.addingTimeInterval(TimeInterval(offset)),
                coverPath: nil
            )
        }
        try JSONEncoder().encode(records).write(
            to: directory.appendingPathComponent("index.json"),
            options: .atomic
        )

        let oversizedLogicalSize = UInt64(DocumentResourceLimits.maximumInputBytes + 1)
        for (id, _) in formats {
            let payloadURL = directory.appendingPathComponent("\(id).payload")
            try writeSparseFile(at: payloadURL, logicalSize: oversizedLogicalSize)
            let attributes = try FileManager.default.attributesOfItem(atPath: payloadURL.path)
            XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, oversizedLogicalSize)
        }

        let store = HistoryStore(directory: directory)
        XCTAssertEqual(Set(store.records.map(\.id)), Set(formats.map(\.0)))
        for record in store.records {
            // Reaching the PDF/EPUB parsers would require materializing the
            // sparse 250 MiB payload. A nil result proves the logical-size
            // preflight ran before Data(contentsOf:).
            let reopened = try await store.reopen(record)
            XCTAssertNil(reopened, record.id)
        }
    }

    func testMixedIndexRecoversGoodRecordsAndKeepsUnknownProviderRemote() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSinceReferenceDate: 778_000_000)
        let local = HistoryRecord(
            id: "known-local",
            title: "Known local",
            sourceKindRaw: ReadingSourceKind.text.rawValue,
            sourceURL: nil,
            language: "en",
            createdAt: now,
            lastOpenedAt: now,
            coverPath: nil
        )
        let origin = makeOrigin(revision: "mixed-revision")
        let cloud = HistoryRecord(
            id: origin.stableDocumentID,
            title: "Known cloud",
            sourceKindRaw: ReadingSourceKind.docx.rawValue,
            sourceURL: nil,
            language: "en",
            createdAt: now,
            lastOpenedAt: now.addingTimeInterval(1),
            coverPath: nil,
            origin: origin,
            persistencePolicy: .remoteReference,
            effectiveFormat: .docx,
            contentRevision: origin.revision,
            exportFormat: .docx,
            contentSessionKey: "known-cloud-session"
        )

        var localObject = try encodedObject(local)
        localObject["persistencePolicy"] = "future_local_policy"
        localObject["effectiveFormat"] = "pages"
        localObject["exportFormat"] = "rtf"
        localObject["futureMetadata"] = ["version": 99, "safeToIgnore": true]

        let cloudObject = try encodedObject(cloud)
        var futureProviderObject = cloudObject
        futureProviderObject["id"] = "future-provider-record"
        futureProviderObject["title"] = "Future provider"
        futureProviderObject["contentSessionKey"] = "future-provider-session"
        var futureOrigin = try XCTUnwrap(futureProviderObject["origin"] as? [String: Any])
        futureOrigin["provider"] = "provider_added_by_future_app"
        futureOrigin["remoteItemID"] = "future-item"
        futureProviderObject["origin"] = futureOrigin

        var malformedObject = localObject
        malformedObject["id"] = 42 // Required field has the wrong type.
        malformedObject["title"] = ["not": "a string"]

        let index = [localObject, cloudObject, futureProviderObject, malformedObject]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(
            to: directory.appendingPathComponent("index.json"),
            options: .atomic
        )
        try Data("Local payload".utf8).write(
            to: directory.appendingPathComponent("known-local.payload"),
            options: .atomic
        )
        // If an unknown provider were downgraded to localPayload, this stale
        // collision would be opened as document bytes. It must remain inert.
        try Data("must never open".utf8).write(
            to: directory.appendingPathComponent("future-provider-record.payload"),
            options: .atomic
        )

        let store = HistoryStore(directory: directory)
        XCTAssertEqual(
            Set(store.records.map(\.id)),
            Set([local.id, cloud.id, "future-provider-record"])
        )

        let recoveredLocal = try XCTUnwrap(store.records.first { $0.id == local.id })
        XCTAssertEqual(recoveredLocal.persistencePolicy, .localPayload)
        XCTAssertNil(recoveredLocal.effectiveFormat)
        XCTAssertNil(recoveredLocal.exportFormat)
        let reopenedLocal = try await store.reopen(recoveredLocal)
        XCTAssertEqual(reopenedLocal?.fullText, "Local payload")

        let recoveredCloud = try XCTUnwrap(store.records.first { $0.id == cloud.id })
        XCTAssertEqual(recoveredCloud.origin, origin)
        XCTAssertTrue(recoveredCloud.requiresRemoteReopen)
        let reopenedCloud = try await store.reopen(recoveredCloud)
        XCTAssertNil(reopenedCloud)

        let futureProvider = try XCTUnwrap(
            store.records.first { $0.id == "future-provider-record" }
        )
        XCTAssertNil(futureProvider.origin)
        XCTAssertEqual(futureProvider.persistencePolicy, .remoteReference)
        XCTAssertTrue(futureProvider.requiresRemoteReopen)
        XCTAssertNil(futureProvider.remoteReference)
        let reopenedFutureProvider = try await store.reopen(futureProvider)
        XCTAssertNil(reopenedFutureProvider)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("future-provider-record.payload")
                    .path
            )
        )

        // A subsequent save migrates the recoverable records without bringing
        // the malformed entry back or weakening the cloud privacy boundary.
        store.updateSourceURL(documentID: local.id, sourceURL: "https://example.invalid/local")
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(Set(reloaded.records.map(\.id)), Set(store.records.map(\.id)))
        XCTAssertEqual(
            reloaded.records.first { $0.id == "future-provider-record" }?.persistencePolicy,
            .remoteReference
        )
        XCTAssertTrue(
            reloaded.records.first { $0.id == cloud.id }?.requiresRemoteReopen == true
        )
    }

    private func makeOrigin(revision: String) -> CloudDocumentOrigin {
        CloudDocumentOrigin(
            provider: .googleDrive,
            accountKey: CloudStableIdentifier.accountKey(
                provider: .googleDrive,
                rawAccountID: "cloud-history-account"
            ),
            maskedAccountHint: "c***@example.com",
            driveID: "drive",
            remoteItemID: "remote-item",
            revision: revision,
            resourceKey: "resource-key",
            originalName: "Remote.docx",
            mimeType: SupportedDocumentFormat.docx.preferredMIMEType,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func encodedObject(_ record: HistoryRecord) throws -> [String: Any] {
        let data = try JSONEncoder().encode(record)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func writeSparseFile(at url: URL, logicalSize: UInt64) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: logicalSize)
    }

    private func makeDOCXData() throws -> Data {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudHistoryDOCX-\(UUID().uuidString)", isDirectory: true)
        let zipURL = root.appendingPathExtension("zip")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("word", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: zipURL)
        }

        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """.utf8).write(to: root.appendingPathComponent("[Content_Types].xml"))
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body><w:p><w:r><w:t>Remote title</w:t></w:r></w:p></w:body>
            </w:document>
            """.utf8).write(to: root.appendingPathComponent("word/document.xml"))

        let archive = try Archive(url: zipURL, accessMode: .create)
        try archive.addEntry(with: "[Content_Types].xml", relativeTo: root)
        try archive.addEntry(with: "word/document.xml", relativeTo: root)
        return try Data(contentsOf: zipURL)
    }
}

private struct LegacyHistoryRecord: Codable {
    let id: String
    let title: String
    let sourceKindRaw: String
    let sourceURL: String?
    let language: String
    let createdAt: Date
    let lastOpenedAt: Date
    let coverPath: String?
}
