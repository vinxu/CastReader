//
//  CloudStorageProvider.swift
//  CastReader
//
//  Capability-oriented provider contracts. All three providers expose a
//  durable connection and CastReader's native file browser. The atomic picker
//  protocol remains only as a source-compatibility bridge for older builds.
//

import Foundation

typealias CloudDownloadCapacityPreflight = @Sendable (
    _ expectedBytes: Int64,
    _ destination: URL
) throws -> Void

enum CloudDownloadCapacityPolicy {
    static let live: CloudDownloadCapacityPreflight = { expectedBytes, destination in
        try CloudTemporaryFileSecurity.preflightDiskCapacity(
            expectedBytes: expectedBytes,
            near: destination
        )
    }
}

enum CloudDownloadDestinationPolicy {
    /// Cloud payloads may only be written beneath the process temporary root.
    /// Resolve the already-created parent directory rather than the not-yet-
    /// created file leaf. On iOS, resolving a nonexistent full path can leave
    /// `/var` unresolved while the existing temporary root resolves to
    /// `/private/var`, incorrectly rejecting every legitimate import.
    /// Comparing canonical path components still prevents a symlinked parent
    /// from redirecting a provider download outside the temporary container.
    static func allows(_ destination: URL) -> Bool {
        guard destination.isFileURL else { return false }
        let leaf = destination.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else { return false }
        let root = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let parent = destination
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let parentComponents = parent.pathComponents
        guard parentComponents.count >= rootComponents.count else { return false }
        return Array(parentComponents.prefix(rootComponents.count)) == rootComponents
    }
}

enum CloudStorageError: Error, Equatable, Sendable {
    case userCancelled
    case notConnected
    case needsReauthorization
    case staleSession
    case invalidConfiguration(code: String)
    case accountMismatch
    case itemUnavailable
    case downloadNotAllowed
    case unsupportedItem
    case unsupportedExportFormat(CloudExportFormat?)
    case invalidResponse(code: String)
    case rateLimited(retryAfterSeconds: Int?)
    case network(code: String)
    case provider(code: String, retryable: Bool)
}

protocol CloudStorageProvider: Actor {
    nonisolated var id: CloudProviderID { get }
    nonisolated var selectionCapability: CloudSelectionCapability { get }

    func connectionState() async -> CloudConnectionState

    /// The provider removes its device-local active association regardless of
    /// whether remote revocation succeeds, and reports both outcomes.
    func disconnect() async -> CloudDisconnectResult

    /// Downloads directly to `destination`. Implementations must not load the
    /// complete response with `data(for:)` and must honor task cancellation.
    /// For an exportable item, callers resolve one of `item.exportOptions` and
    /// pass it explicitly so reopen behavior is deterministic.
    func download(
        _ item: CloudItem,
        exportFormat: CloudExportFormat?,
        to destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt
}

extension CloudStorageProvider {
    func download(
        _ item: CloudItem,
        exportFormat: CloudExportFormat? = nil,
        to destination: URL
    ) async throws -> CloudDownloadReceipt {
        try await download(
            item,
            exportFormat: exportFormat,
            to: destination,
            progress: { _ in }
        )
    }
}

protocol CloudAtomicPickerProvider: CloudStorageProvider {
    /// Legacy compatibility surface. New Google Drive flows authorize first
    /// and then browse through `CloudBrowsableProvider`.
    func authorizeAndPick() async throws -> (account: CloudAccount, item: CloudItem)
}

protocol CloudBrowsableProvider: CloudStorageProvider {
    /// Establishes or silently restores a durable connection before the native
    /// browser loads.
    func ensureConnected() async throws -> CloudAccount

    func list(folder: CloudFolder?, cursor: CloudCursor?) async throws -> CloudPage
    func search(_ query: String, cursor: CloudCursor?) async throws -> CloudPage
}

/// Optional capability used by OneDrive accounts with multiple user-owned
/// drives and by Google accounts that are members of Shared Drives. OneDrive
/// implementations must not discover SharePoint sites or Teams libraries.
protocol CloudDriveListingProvider: CloudBrowsableProvider {
    func listDrives() async throws -> [CloudDrive]
    func search(
        _ query: String,
        driveID: String?,
        cursor: CloudCursor?
    ) async throws -> CloudPage
}
