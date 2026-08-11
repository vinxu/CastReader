//
//  CloudHistoryReopenServiceTests.swift
//  CastReaderTests
//

import Foundation
import XCTest
@testable import CastReader

final class CloudHistoryReopenServiceTests: XCTestCase {
    func testReopenRebuildsMinimalItemRefreshesRevisionAndCleansTemporaryFile() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let attemptID = UUID()
        let account = CloudAccount(
            provider: .googleDrive,
            stableAccountKey: "account-a",
            displayName: "Reader"
        )
        let gateway = CloudHistoryFakeProvider(
            state: .connected(account),
            restoredAccount: account,
            behavior: .success(
                finalRevision: "server-revision",
                format: .docx,
                exportFormat: .docx,
                data: Data("device-only-docx".utf8)
            )
        )
        let importer = CloudHistoryCapturingImporter()
        let service = CloudHistoryReopenService(
            provider: gateway,
            importer: importer,
            coordinator: CloudImportCoordinator(),
            temporaryRoot: root,
            makeAttemptID: { attemptID }
        )
        let record = makeRecord(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            originalName: "Meeting Notes",
            mimeType: "application/vnd.google-apps.document",
            originRevision: "origin-revision",
            contentRevision: "history-revision",
            effectiveFormat: .docx,
            exportFormat: .docx
        )

        let result = try await service.reopen(record, mode: .explain)

        let downloadedItem = await gateway.lastDownloadedItem()
        let item = try XCTUnwrap(downloadedItem)
        XCTAssertEqual(item.provider, .googleDrive)
        XCTAssertEqual(item.accountKey, "account-a")
        XCTAssertEqual(item.driveID, "drive-1")
        XCTAssertEqual(item.id, "remote-item")
        XCTAssertEqual(item.name, "Meeting Notes.docx")
        XCTAssertEqual(item.mimeType, "application/vnd.google-apps.document")
        XCTAssertEqual(item.revision, "history-revision")
        XCTAssertEqual(item.resourceKey, "resource-key")
        XCTAssertEqual(item.kind, .exportableDocument)
        XCTAssertEqual(item.exportOptions, [.docx])
        let downloadedExportFormat = await gateway.lastExportFormat()
        let restoreCalls = await gateway.restoreCallCount()
        XCTAssertEqual(downloadedExportFormat, .docx)
        XCTAssertEqual(restoreCalls, 0)

        let capturedRequest = await importer.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.transportPolicy, .deviceOnly)
        XCTAssertEqual(request.persistencePolicy, .remoteReference)
        XCTAssertEqual(request.finalRevision, "server-revision")
        XCTAssertEqual(request.exportFormat, .docx)
        XCTAssertEqual(request.origin?.revision, "origin-revision")
        XCTAssertEqual(result.finalRevision, "server-revision")
        XCTAssertEqual(result.origin?.revision, "server-revision")
        XCTAssertNotEqual(result.contentSessionKey, record.resolvedContentSessionKey)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(attemptID.uuidString).path
            )
        )
        XCTAssertTrue(children(of: root).isEmpty)
    }

    func testConnectedDifferentAccountFailsWithAccountMismatchBeforeDownload() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = CloudAccount(provider: .dropbox, stableAccountKey: "other-account")
        let gateway = CloudHistoryFakeProvider(
            state: .connected(active),
            restoredAccount: active,
            behavior: .success(
                finalRevision: "2",
                format: .pdf,
                exportFormat: nil,
                data: Data("pdf".utf8)
            )
        )
        let service = CloudHistoryReopenService(
            provider: gateway,
            importer: CloudHistoryCapturingImporter(),
            coordinator: CloudImportCoordinator(),
            temporaryRoot: root
        )
        let record = makeRecord(
            provider: .dropbox,
            accountKey: "original-account",
            originalName: "Report.pdf",
            mimeType: "application/pdf",
            effectiveFormat: .pdf
        )

        await assertCloudError(.accountMismatch) {
            _ = try await service.reopen(record, mode: .read)
        }
        let downloadCalls = await gateway.downloadCallCount()
        let restoreCalls = await gateway.restoreCallCount()
        XCTAssertEqual(downloadCalls, 0)
        XCTAssertEqual(restoreCalls, 0)
        XCTAssertTrue(children(of: root).isEmpty)
    }

    func testDisconnectedGoogleReturnsNeedsReauthorizationWithoutImplicitRestore() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = CloudAccount(provider: .googleDrive, stableAccountKey: "google-account")
        let gateway = CloudHistoryFakeProvider(
            state: .disconnected,
            restoredAccount: account,
            behavior: .success(
                finalRevision: "2",
                format: .pdf,
                exportFormat: nil,
                data: Data("pdf".utf8)
            )
        )
        let service = CloudHistoryReopenService(
            provider: gateway,
            importer: CloudHistoryCapturingImporter(),
            coordinator: CloudImportCoordinator(),
            temporaryRoot: root
        )
        let record = makeRecord(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            originalName: "Report.pdf",
            mimeType: "application/pdf",
            effectiveFormat: .pdf
        )

        await assertCloudError(.needsReauthorization) {
            _ = try await service.reopen(record, mode: .read)
        }
        let restoreCalls = await gateway.restoreCallCount()
        let downloadCalls = await gateway.downloadCallCount()
        XCTAssertEqual(restoreCalls, 0)
        XCTAssertEqual(downloadCalls, 0)
        XCTAssertTrue(children(of: root).isEmpty)
    }

    func testProviderNotConnectedDuringDownloadMapsToNeedsReauthorizationAndCleansUp() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = CloudAccount(provider: .oneDrive, stableAccountKey: "microsoft-account")
        let gateway = CloudHistoryFakeProvider(
            state: .connected(account),
            restoredAccount: account,
            behavior: .failure(.notConnected)
        )
        let service = CloudHistoryReopenService(
            provider: gateway,
            importer: CloudHistoryCapturingImporter(),
            coordinator: CloudImportCoordinator(),
            temporaryRoot: root
        )
        let record = makeRecord(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            originalName: "Book.epub",
            mimeType: "application/epub+zip",
            effectiveFormat: .epub
        )

        await assertCloudError(.needsReauthorization) {
            _ = try await service.reopen(record, mode: .read)
        }
        let downloadCalls = await gateway.downloadCallCount()
        XCTAssertEqual(downloadCalls, 1)
        XCTAssertTrue(children(of: root).isEmpty)
    }

    func testCallerCancellationCancelsTransferAndRemovesPartialFile() async throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = CloudAccount(provider: .dropbox, stableAccountKey: "dropbox-account")
        let gateway = CloudHistoryFakeProvider(
            state: .connected(account),
            restoredAccount: account,
            behavior: .waitForCancellation
        )
        let coordinator = CloudImportCoordinator()
        let service = CloudHistoryReopenService(
            provider: gateway,
            importer: CloudHistoryCapturingImporter(),
            coordinator: coordinator,
            temporaryRoot: root
        )
        let record = makeRecord(
            provider: .dropbox,
            accountKey: account.stableAccountKey,
            originalName: "Report.pdf",
            mimeType: "application/pdf",
            effectiveFormat: .pdf
        )

        let task = Task {
            try await service.reopen(record, mode: .read)
        }
        for _ in 0..<1_000 {
            if await gateway.hasStartedDownload() { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let didStart = await gateway.hasStartedDownload()
        XCTAssertTrue(didStart)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled history reopen must not return a document")
        } catch let error as CloudStorageError {
            XCTAssertEqual(error, .userCancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(children(of: root).isEmpty)
        let currentSession = await coordinator.currentSession()
        XCTAssertNil(currentSession)
    }

    private func makeRecord(
        provider: CloudProviderID,
        accountKey: String,
        originalName: String,
        mimeType: String?,
        originRevision: String? = "1",
        contentRevision: String? = nil,
        effectiveFormat: SupportedDocumentFormat,
        exportFormat: CloudExportFormat? = nil
    ) -> HistoryRecord {
        let origin = CloudDocumentOrigin(
            provider: provider,
            accountKey: accountKey,
            driveID: "drive-1",
            remoteItemID: "remote-item",
            revision: originRevision,
            resourceKey: "resource-key",
            originalName: originalName,
            mimeType: mimeType
        )
        return HistoryRecord(
            id: origin.stableDocumentID,
            title: "Remote document",
            sourceKindRaw: effectiveFormat.sourceKind.rawValue,
            sourceURL: nil,
            language: "en",
            createdAt: Date(timeIntervalSince1970: 1),
            lastOpenedAt: Date(timeIntervalSince1970: 2),
            coverPath: nil,
            origin: origin,
            persistencePolicy: .remoteReference,
            effectiveFormat: effectiveFormat,
            contentRevision: contentRevision,
            exportFormat: exportFormat,
            contentSessionKey: "old-session-key"
        )
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudHistoryReopenTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private func assertCloudError(
        _ expected: CloudStorageError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch let error as CloudStorageError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private actor CloudHistoryFakeProvider: CloudHistoryReopenProviding {
    enum Behavior: Sendable {
        case success(
            finalRevision: String?,
            format: SupportedDocumentFormat,
            exportFormat: CloudExportFormat?,
            data: Data
        )
        case failure(CloudStorageError)
        case waitForCancellation
    }

    private let state: CloudConnectionState
    private let restoredAccount: CloudAccount
    private let behavior: Behavior
    private var restoreCalls = 0
    private var downloadCalls = 0
    private var downloadedItem: CloudItem?
    private var downloadedExportFormat: CloudExportFormat?
    private var downloadStarted = false

    init(
        state: CloudConnectionState,
        restoredAccount: CloudAccount,
        behavior: Behavior
    ) {
        self.state = state
        self.restoredAccount = restoredAccount
        self.behavior = behavior
    }

    func historyConnectionState(for provider: CloudProviderID) -> CloudConnectionState {
        state
    }

    func restoreHistoryAccount(
        for provider: CloudProviderID,
        expectedAccountKey: String
    ) throws -> CloudAccount {
        restoreCalls += 1
        return restoredAccount
    }

    func downloadHistoryItem(
        provider: CloudProviderID,
        item: CloudItem,
        exportFormat: CloudExportFormat?,
        destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt {
        downloadCalls += 1
        downloadStarted = true
        downloadedItem = item
        downloadedExportFormat = exportFormat

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        switch behavior {
        case .success(let revision, let format, let receiptExport, let data):
            try data.write(to: destination, options: .atomic)
            progress(CloudDownloadProgress(completedBytes: Int64(data.count), totalBytes: Int64(data.count)))
            return CloudDownloadReceipt(
                localURL: destination,
                effectiveFilename: destination.lastPathComponent,
                effectiveMIMEType: format.preferredMIMEType,
                effectiveFormat: format,
                exportFormat: receiptExport,
                finalRevision: revision,
                byteCount: Int64(data.count)
            )
        case .failure(let error):
            throw error
        case .waitForCancellation:
            try Data("partial".utf8).write(to: destination, options: .atomic)
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CloudStorageError.provider(code: "uncancelled_test_transfer", retryable: false)
        }
    }

    func restoreCallCount() -> Int { restoreCalls }
    func downloadCallCount() -> Int { downloadCalls }
    func lastDownloadedItem() -> CloudItem? { downloadedItem }
    func lastExportFormat() -> CloudExportFormat? { downloadedExportFormat }
    func hasStartedDownload() -> Bool { downloadStarted }
}

private actor CloudHistoryCapturingImporter: CloudHistoryDocumentImporting {
    private var requests: [DocumentImportRequest] = []

    func importHistoryDocument(
        _ request: DocumentImportRequest,
        progress: @escaping DocumentImportProgressHandler
    ) throws -> DocumentImportResult {
        requests.append(request)
        guard FileManager.default.fileExists(atPath: request.localURL.path),
              let data = try? Data(contentsOf: request.localURL) else {
            throw DocumentImportError.fileReadFailed
        }
        guard let format = request.expectedFormat,
              let sourceKind = format.optionalSourceKind else {
            throw DocumentImportError.unsupportedExtension(
                request.localURL.pathExtension
            )
        }

        progress(DocumentImportProgress(stage: .checkingFile))
        progress(DocumentImportProgress(stage: .parsing(format)))
        let revision = request.finalRevision ?? request.origin?.revision
        let origin = request.origin?.replacingRevision(revision)
        let documentID = origin?.stableDocumentID ?? UUID().uuidString
        let contentSessionKey = CloudStableIdentifier.contentSessionKey(
            documentID: documentID,
            revision: revision,
            format: format
        )
        let document = ReadingDocument(
            id: documentID,
            title: "Remote document",
            sourceKind: sourceKind,
            paragraphs: [ReadingParagraph(id: 0, text: "Parsed")],
            fileData: data,
            origin: origin,
            persistencePolicy: .remoteReference,
            effectiveFormat: format,
            exportFormat: request.exportFormat,
            contentRevision: revision,
            contentSessionKey: contentSessionKey
        )
        progress(DocumentImportProgress(stage: .preparingReader))
        return DocumentImportResult(
            document: document,
            format: format,
            origin: origin,
            persistencePolicy: .remoteReference,
            contentSessionKey: contentSessionKey,
            effectiveFilename: request.effectiveFilename,
            finalRevision: revision,
            exportFormat: request.exportFormat,
            byteCount: Int64(data.count),
            session: request.session
        )
    }

    func lastRequest() -> DocumentImportRequest? { requests.last }
}

private extension SupportedDocumentFormat {
    var optionalSourceKind: ReadingSourceKind? { sourceKind }

    var sourceKind: ReadingSourceKind {
        switch self {
        case .pdf: return .pdf
        case .docx: return .docx
        case .epub: return .epub
        case .text: return .text
        }
    }
}
