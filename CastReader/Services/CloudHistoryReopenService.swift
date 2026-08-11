//
//  CloudHistoryReopenService.swift
//  CastReader
//
//  Reopens a cloud-backed HistoryRecord without persisting or uploading the
//  provider payload. Every attempt gets an isolated temporary directory that
//  is removed on success, failure and cancellation.
//

import Foundation

enum CloudHistoryReopenProgress: Equatable, Sendable {
    case validatingAccount
    case downloading(CloudDownloadProgress)
    case importing(DocumentImportProgress)
}

typealias CloudHistoryReopenProgressHandler = @Sendable (CloudHistoryReopenProgress) -> Void

/// Narrow provider boundary used by history reopen. Deliberately omits list,
/// search, upload and authorization-picker APIs.
protocol CloudHistoryReopenProviding: Sendable {
    func historyConnectionState(for provider: CloudProviderID) async -> CloudConnectionState

    /// Restores the provider's previously selected account. Google history
    /// reopen never calls this: a missing Google credential must go through
    /// the explicit Picker flow in the plus menu again.
    func restoreHistoryAccount(
        for provider: CloudProviderID,
        expectedAccountKey: String
    ) async throws -> CloudAccount

    func downloadHistoryItem(
        provider: CloudProviderID,
        item: CloudItem,
        exportFormat: CloudExportFormat?,
        destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt
}

/// Production adapter kept separate from CloudStorageCenter so tests can
/// prove account and cleanup behavior without real SDK state.
struct LiveCloudHistoryReopenProvider: CloudHistoryReopenProviding {
    func historyConnectionState(for provider: CloudProviderID) async -> CloudConnectionState {
        await CloudStorageCenter.shared.refreshConnectionStates()
        return await CloudStorageCenter.shared.state(for: provider)
    }

    func restoreHistoryAccount(
        for provider: CloudProviderID,
        expectedAccountKey: String
    ) async throws -> CloudAccount {
        guard provider != .googleDrive else {
            throw CloudStorageError.needsReauthorization
        }
        return try await CloudStorageCenter.shared.restorePersistedAccount(
            provider,
            expectedAccountKey: expectedAccountKey
        )
    }

    func downloadHistoryItem(
        provider: CloudProviderID,
        item: CloudItem,
        exportFormat: CloudExportFormat?,
        destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt {
        try await CloudStorageCenter.shared.download(
            provider: provider,
            item: item,
            exportFormat: exportFormat,
            destination: destination,
            progress: progress
        )
    }
}

/// Parser boundary is device-local by construction: DocumentImportRequest has
/// `transportPolicy == .deviceOnly` and no upload fallback exists here.
protocol CloudHistoryDocumentImporting: Sendable {
    func importHistoryDocument(
        _ request: DocumentImportRequest,
        progress: @escaping DocumentImportProgressHandler
    ) async throws -> DocumentImportResult
}

extension DocumentImportPipeline: CloudHistoryDocumentImporting {
    func importHistoryDocument(
        _ request: DocumentImportRequest,
        progress: @escaping DocumentImportProgressHandler
    ) async throws -> DocumentImportResult {
        try await importDocument(request, progress: progress)
    }
}

struct CloudHistoryReopenService: Sendable {
    private let provider: any CloudHistoryReopenProviding
    private let importer: any CloudHistoryDocumentImporting
    private let coordinator: CloudImportCoordinator
    private let temporaryRoot: URL
    private let makeAttemptID: @Sendable () -> UUID

    init(
        provider: any CloudHistoryReopenProviding = LiveCloudHistoryReopenProvider(),
        importer: any CloudHistoryDocumentImporting = DocumentImportPipeline(),
        coordinator: CloudImportCoordinator = .shared,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastReaderCloudHistoryReopen", isDirectory: true),
        makeAttemptID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.provider = provider
        self.importer = importer
        self.coordinator = coordinator
        self.temporaryRoot = temporaryRoot
        self.makeAttemptID = makeAttemptID
    }

    /// Reopens a remote-reference History record using the exact provider,
    /// account, item ID and export format captured at the original import.
    func reopen(
        _ record: HistoryRecord,
        mode: ReaderMode,
        scenario: ExplainContentType? = nil,
        analyticsContext: AnalyticsContentContext? = nil,
        progress: @escaping CloudHistoryReopenProgressHandler = { _ in }
    ) async throws -> DocumentImportResult {
        guard let reference = record.remoteReference else {
            throw CloudStorageError.unsupportedItem
        }

        let item = try Self.makeItem(from: reference)
        let session = await coordinator.begin(
            provider: reference.origin.provider,
            scenario: scenario,
            mode: mode,
            analyticsContext: analyticsContext
        )
        let attemptDirectory = temporaryRoot
            .appendingPathComponent(makeAttemptID().uuidString, isDirectory: true)

        // Synchronous defer is intentional: it runs for every exit path,
        // including a caller cancellation while an SDK transfer is active.
        defer { try? FileManager.default.removeItem(at: attemptDirectory) }

        do {
            try CloudTemporaryFileSecurity.prepareDirectory(attemptDirectory)
            let destination = attemptDirectory.appendingPathComponent(
                Self.safeFilename(for: reference)
            )
            let providerGateway = provider
            let documentImporter = importer
            let coordinator = coordinator
            let downloadProgress = coordinator.progressHandler(for: session) { value in
                progress(.downloading(value))
            }

            let result = try await coordinator.run(for: session) {
                progress(.validatingAccount)
                _ = try await Self.validateOriginalAccount(
                    reference.origin,
                    using: providerGateway
                )
                try Task.checkCancellation()

                let receipt = try await providerGateway.downloadHistoryItem(
                    provider: reference.origin.provider,
                    item: item,
                    exportFormat: reference.exportFormat,
                    destination: destination,
                    progress: downloadProgress
                )
                try Task.checkCancellation()

                // The receipt's final revision is authoritative. The pipeline
                // replaces the stored origin revision and derives a fresh
                // contentSessionKey from it.
                let request = DocumentImportRequest(
                    receipt: receipt,
                    origin: reference.origin,
                    session: session
                )
                return try await documentImporter.importHistoryDocument(request) { value in
                    progress(.importing(value))
                }
            }

            try Task.checkCancellation()
            guard await coordinator.finish(session) else {
                throw CloudStorageError.staleSession
            }
            return result
        } catch {
            _ = await coordinator.finish(session)
            throw Self.normalized(error)
        }
    }

    private static func validateOriginalAccount(
        _ origin: CloudDocumentOrigin,
        using provider: any CloudHistoryReopenProviding
    ) async throws -> CloudAccount {
        let state = await provider.historyConnectionState(for: origin.provider)
        switch state {
        case .connected(let account):
            return try requireMatch(account, origin: origin)

        case .needsReauthorization(let knownAccount):
            if let knownAccount,
               knownAccount.stableAccountKey != origin.accountKey {
                throw CloudStorageError.accountMismatch
            }
            guard origin.provider != .googleDrive else {
                throw CloudStorageError.needsReauthorization
            }
            return try await restoreAndValidate(origin, using: provider)

        case .disconnected, .connecting:
            // Google Picker grants drive.file access to explicitly selected
            // files. Reopen may silently use an existing valid credential, but
            // must never launch a broad or implicit reauthorization flow.
            guard origin.provider != .googleDrive else {
                throw CloudStorageError.needsReauthorization
            }
            return try await restoreAndValidate(origin, using: provider)
        }
    }

    private static func restoreAndValidate(
        _ origin: CloudDocumentOrigin,
        using provider: any CloudHistoryReopenProviding
    ) async throws -> CloudAccount {
        do {
            let restored = try await provider.restoreHistoryAccount(
                for: origin.provider,
                expectedAccountKey: origin.accountKey
            )
            return try requireMatch(restored, origin: origin)
        } catch let error as CloudStorageError {
            switch error {
            case .notConnected, .needsReauthorization:
                throw CloudStorageError.needsReauthorization
            default:
                throw error
            }
        }
    }

    private static func requireMatch(
        _ account: CloudAccount,
        origin: CloudDocumentOrigin
    ) throws -> CloudAccount {
        guard account.provider == origin.provider,
              account.stableAccountKey == origin.accountKey else {
            throw CloudStorageError.accountMismatch
        }
        return account
    }

    private static func makeItem(from reference: CloudHistoryReference) throws -> CloudItem {
        let origin = reference.origin
        let format = reference.exportFormat?.documentFormat
            ?? reference.effectiveFormat
            ?? SupportedDocumentFormat(
                fileExtension: URL(fileURLWithPath: origin.originalName).pathExtension
            )
        guard let format else { throw CloudStorageError.unsupportedItem }

        if origin.provider == .oneDrive, reference.exportFormat != nil {
            throw CloudStorageError.unsupportedExportFormat(reference.exportFormat)
        }

        let itemName = normalizedFilename(origin.originalName, format: format)
        let kind: CloudItemKind = reference.exportFormat == nil ? .file : .exportableDocument
        return CloudItem(
            provider: origin.provider,
            accountKey: origin.accountKey,
            driveID: origin.driveID,
            id: origin.remoteItemID,
            name: itemName,
            mimeType: origin.mimeType ?? format.preferredMIMEType,
            modifiedAt: origin.modifiedAt,
            revision: reference.contentRevision ?? origin.revision,
            resourceKey: origin.resourceKey,
            kind: kind,
            exportOptions: reference.exportFormat.map { [$0] } ?? []
        )
    }

    private static func safeFilename(for reference: CloudHistoryReference) -> String {
        let format = reference.exportFormat?.documentFormat
            ?? reference.effectiveFormat
            ?? SupportedDocumentFormat(
                fileExtension: URL(fileURLWithPath: reference.origin.originalName).pathExtension
            )
            ?? .pdf
        let rawName = normalizedFilename(reference.origin.originalName, format: format)
        let leaf = URL(fileURLWithPath: rawName).lastPathComponent
            .replacingOccurrences(of: ":", with: "_")
        return leaf.isEmpty ? "document.\(format.rawValue)" : leaf
    }

    private static func normalizedFilename(
        _ rawName: String,
        format: SupportedDocumentFormat
    ) -> String {
        let leaf = URL(fileURLWithPath: rawName).lastPathComponent
        guard SupportedDocumentFormat(fileExtension: URL(fileURLWithPath: leaf).pathExtension) == nil else {
            return leaf
        }
        let base = leaf.isEmpty ? "document" : leaf
        return base + "." + format.rawValue
    }

    private static func normalized(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError {
            return CloudStorageError.userCancelled
        }
        if let coordinationError = error as? CloudImportCoordinationError {
            switch coordinationError {
            case .cancelled: return CloudStorageError.userCancelled
            case .staleSession: return CloudStorageError.staleSession
            }
        }
        if let importError = error as? DocumentImportError,
           importError == .cancelled {
            return CloudStorageError.userCancelled
        }
        if let cloudError = error as? CloudStorageError {
            switch cloudError {
            case .notConnected:
                return CloudStorageError.needsReauthorization
            default:
                return cloudError
            }
        }
        return error
    }
}
