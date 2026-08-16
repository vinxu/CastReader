//
//  DropboxProvider.swift
//  CastReader
//
//  Device-only Dropbox browsing and downloads. OAuth credentials stay in the
//  SwiftyDropbox keychain store; CastReader persists only the SDK token UID.
//

import Foundation
import UIKit

#if canImport(SwiftyDropbox)
@preconcurrency import SwiftyDropbox
#endif

// MARK: - Injectable boundary

struct DropboxAccountRecord: Equatable, Sendable {
    let rawAccountID: String
    let tokenUID: String
    let displayName: String?
    let email: String?
    let rootNamespaceID: String
}

struct DropboxFileRecord: Equatable, Sendable {
    let id: String
    let name: String
    let size: Int64?
    let modifiedAt: Date?
    let revision: String?
    let isDownloadable: Bool
    let exportFormats: [String]
}

enum DropboxEntryRecord: Equatable, Sendable {
    case folder(id: String, name: String)
    case file(DropboxFileRecord)
}

struct DropboxPageRecord: Equatable, Sendable {
    let entries: [DropboxEntryRecord]
    let cursor: String?
    let hasMore: Bool
}

struct DropboxTransferRecord: Equatable, Sendable {
    let localURL: URL
    let filename: String
    let mimeType: String?
    let byteCount: Int64
    let revision: String?

    init(
        localURL: URL,
        filename: String,
        mimeType: String? = nil,
        byteCount: Int64,
        revision: String?
    ) {
        self.localURL = localURL
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.revision = revision
    }
}

enum DropboxAdapterError: Error, Equatable, Sendable {
    case userCancelled
    case notConnected
    case needsReauthorization
    case itemUnavailable
    case downloadNotAllowed
    case unsupportedItem
    case unsupportedExportFormat
    case invalidRoot
    case rateLimited(Int?)
    case network(String)
    case provider(code: String, retryable: Bool)
}

protocol DropboxProviderAdapter: Actor {
    func restoreAccount(tokenUID: String?) async throws -> DropboxAccountRecord?
    func authorize() async throws -> DropboxAccountRecord
    func refreshCurrentAccount() async throws -> DropboxAccountRecord
    func activate(tokenUID: String) async throws
    func metadata(id: String, rootNamespaceID: String) async throws -> DropboxFileRecord

    func list(
        path: String,
        cursor: String?,
        rootNamespaceID: String
    ) async throws -> DropboxPageRecord

    func search(
        query: String,
        cursor: String?,
        rootNamespaceID: String
    ) async throws -> DropboxPageRecord

    func download(
        id: String,
        rootNamespaceID: String,
        exportFormat: String?,
        destination: URL,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> DropboxTransferRecord

    func revoke(tokenUID: String) async throws
    func clearLocalToken(tokenUID: String) async
}

enum DropboxOAuthOrphanTokenCleanup: Equatable, Sendable {
    case preserve
    case deferUntilPendingAuthorizationFinishes
    case clearNow
}

/// A Dropbox token UID is the stable provider user UID. A late callback can
/// therefore refer to the same Keychain item as the account that is already
/// active, or as the account a newer OAuth attempt is about to accept.
enum DropboxOAuthOrphanTokenPolicy {
    static func cleanup(
        tokenUID: String,
        acceptedTokenUIDs: Set<String>,
        lastKnownActiveTokenUID: String?,
        hasPendingAuthorization: Bool
    ) -> DropboxOAuthOrphanTokenCleanup {
        if acceptedTokenUIDs.contains(tokenUID)
            || tokenUID == lastKnownActiveTokenUID {
            return .preserve
        }
        return hasPendingAuthorization
            ? .deferUntilPendingAuthorizationFinishes
            : .clearNow
    }
}

// MARK: - Provider

actor DropboxProvider: CloudBrowsableProvider {
    nonisolated let id: CloudProviderID = .dropbox
    nonisolated let selectionCapability: CloudSelectionCapability = .persistentConnectionAndNativeBrowser

    private let adapter: any DropboxProviderAdapter
    private let defaults: UserDefaults
    private let tokenUIDKey: String
    private let candidateTokenUIDKey: String
    private let retiredTokenUIDKey: String
    private let capacityPreflight: CloudDownloadCapacityPreflight

    private var state: CloudConnectionState = .disconnected
    private var activeRecord: DropboxAccountRecord?
    private var candidateRecord: DropboxAccountRecord?
    private var generation: UInt64 = 0
    private var sdkAccountTransitionInProgress = false

    init(
        adapter: any DropboxProviderAdapter,
        defaults: UserDefaults = .standard,
        tokenUIDKey: String = "cloud.dropbox.activeTokenUID",
        candidateTokenUIDKey: String = "cloud.dropbox.pendingCandidateTokenUID",
        retiredTokenUIDKey: String = "cloud.dropbox.pendingRetiredTokenUID",
        capacityPreflight: @escaping CloudDownloadCapacityPreflight =
            CloudDownloadCapacityPolicy.live
    ) {
        self.adapter = adapter
        self.defaults = defaults
        self.tokenUIDKey = tokenUIDKey
        self.candidateTokenUIDKey = candidateTokenUIDKey
        self.retiredTokenUIDKey = retiredTokenUIDKey
        self.capacityPreflight = capacityPreflight
    }

#if canImport(SwiftyDropbox)
    init(
        appKey: String,
        presenter: @escaping @MainActor @Sendable () -> UIViewController?,
        defaults: UserDefaults = .standard,
        tokenUIDKey: String = "cloud.dropbox.activeTokenUID",
        candidateTokenUIDKey: String = "cloud.dropbox.pendingCandidateTokenUID",
        retiredTokenUIDKey: String = "cloud.dropbox.pendingRetiredTokenUID",
        capacityPreflight: @escaping CloudDownloadCapacityPreflight =
            CloudDownloadCapacityPolicy.live
    ) {
        self.adapter = SwiftyDropboxAdapter(
            appKey: appKey,
            presenter: presenter
        )
        self.defaults = defaults
        self.tokenUIDKey = tokenUIDKey
        self.candidateTokenUIDKey = candidateTokenUIDKey
        self.retiredTokenUIDKey = retiredTokenUIDKey
        self.capacityPreflight = capacityPreflight
    }

    /// Route the Dropbox callback URL here from the app/scene URL handler.
    @MainActor
    static func handleRedirectURL(_ url: URL) -> Bool {
        DropboxOAuthBroker.handleRedirectURL(url)
    }
#endif

    func connectionState() async -> CloudConnectionState {
        state
    }

    /// Restores only the persisted SDK account. History reopen uses this path
    /// so validating an old reference can never present OAuth or mutate the
    /// active association through a newly selected account.
    func restorePersistedAccount(expectedAccountKey: String? = nil) async throws -> CloudAccount {
        guard !sdkAccountTransitionInProgress else { throw CloudStorageError.staleSession }
        if candidateRecord == nil {
            do {
                try await reconcilePersistedCredentialCleanup()
            } catch {
                throw map(error)
            }
        }
        if let activeRecord {
            let account = cloudAccount(from: activeRecord)
            guard expectedAccountKey == nil || account.stableAccountKey == expectedAccountKey else {
                throw CloudStorageError.accountMismatch
            }
            return account
        }

        state = .connecting
        let operationGeneration = generation
        let storedTokenUID = defaults.string(forKey: tokenUIDKey)
        guard let storedTokenUID else {
            state = .needsReauthorization(expectedAccountKey.map(Self.placeholderAccount))
            throw CloudStorageError.needsReauthorization
        }

        do {
            guard let restored = try await adapter.restoreAccount(tokenUID: storedTokenUID) else {
                state = .needsReauthorization(expectedAccountKey.map(Self.placeholderAccount))
                throw CloudStorageError.needsReauthorization
            }
            try ensureCurrent(operationGeneration)
            let account = cloudAccount(from: restored)
            guard expectedAccountKey == nil || account.stableAccountKey == expectedAccountKey else {
                state = .needsReauthorization(expectedAccountKey.map(Self.placeholderAccount))
                throw CloudStorageError.accountMismatch
            }
            return commit(restored)
        } catch {
            let mapped = map(error)
            if mapped == .staleSession { throw mapped }
            state = .needsReauthorization(expectedAccountKey.map(Self.placeholderAccount))
            throw mapped
        }
    }

    func ensureConnected() async throws -> CloudAccount {
        try await ensureConnected(
            expectedAccountKey: nil,
            forceAccountSelection: false
        )
    }

    func ensureConnected(
        expectedAccountKey: String? = nil,
        forceAccountSelection: Bool = false
    ) async throws -> CloudAccount {
        guard !sdkAccountTransitionInProgress else { throw CloudStorageError.staleSession }
        if candidateRecord != nil { throw CloudStorageError.accountMismatch }
        if !forceAccountSelection {
            do {
                return try await restorePersistedAccount(expectedAccountKey: expectedAccountKey)
            } catch let error as CloudStorageError where error == .needsReauthorization {
                // This is the explicit connect path; interaction is allowed.
            }
        }

        state = .connecting
        let operationGeneration = generation
        let storedTokenUID = defaults.string(forKey: tokenUIDKey)
        var newlyAuthorizedRecord: DropboxAccountRecord?

        do {
            let authorized = try await adapter.authorize()
            newlyAuthorizedRecord = authorized
            try ensureCurrent(operationGeneration)
            let account = cloudAccount(from: authorized)
            if let expectedAccountKey,
               account.stableAccountKey != expectedAccountKey {
                persist(authorized.tokenUID, forKey: candidateTokenUIDKey)
                candidateRecord = authorized
                newlyAuthorizedRecord = nil
                if let storedTokenUID, storedTokenUID != authorized.tokenUID {
                    try? await adapter.activate(tokenUID: storedTokenUID)
                }
                state = .needsReauthorization(Self.placeholderAccount(expectedAccountKey))
                throw CloudStorageError.accountMismatch
            }

            let committedAccount = commit(authorized)
            newlyAuthorizedRecord = nil
            return committedAccount
        } catch {
            if map(error) == .accountMismatch, candidateRecord != nil {
                throw CloudStorageError.accountMismatch
            }
            if let newlyAuthorizedRecord {
                await adapter.clearLocalToken(tokenUID: newlyAuthorizedRecord.tokenUID)
            }
            let mapped = map(error)
            if mapped == .staleSession { throw mapped }
            if mapped == .needsReauthorization {
                let prior = activeRecord.map(cloudAccount(from:))
                state = .needsReauthorization(prior)
            } else {
                state = .disconnected
            }
            throw mapped
        }
    }

    /// Starts Dropbox OAuth for another account without replacing the active
    /// account. The SDK client is switched back to the old token before this
    /// method returns; UI must call `commitCandidate()` after confirmation.
    func stageAnotherAccount() async throws -> CloudAccount {
        let prior = try await requireConnection()
        if candidateRecord != nil { await discardCandidate() }
        guard !sdkAccountTransitionInProgress else { throw CloudStorageError.staleSession }
        sdkAccountTransitionInProgress = true
        defer { sdkAccountTransitionInProgress = false }
        let priorState = state
        let operationGeneration = generation
        var selectedRecord: DropboxAccountRecord?
        do {
            let selected = try await adapter.authorize()
            selectedRecord = selected
            persist(selected.tokenUID, forKey: candidateTokenUIDKey)
            try ensureCurrent(operationGeneration)
            try await adapter.activate(tokenUID: prior.tokenUID)
            try ensureCurrent(operationGeneration)
            candidateRecord = selected
            state = priorState
            return cloudAccount(from: selected)
        } catch {
            if let selectedRecord,
               selectedRecord.tokenUID != prior.tokenUID {
                await adapter.clearLocalToken(tokenUID: selectedRecord.tokenUID)
            }
            clearPersistedValue(forKey: candidateTokenUIDKey)
            if operationGeneration == generation {
                try? await adapter.activate(tokenUID: prior.tokenUID)
                state = priorState
            }
            throw map(error)
        }
    }

    /// Activates the staged token only after the user confirms A → B.
    func commitCandidate() async throws -> CloudAccount {
        guard let candidateRecord else {
            throw CloudStorageError.invalidResponse(code: "dropbox_candidate_missing")
        }
        guard !sdkAccountTransitionInProgress else { throw CloudStorageError.staleSession }
        sdkAccountTransitionInProgress = true
        defer { sdkAccountTransitionInProgress = false }
        let prior = activeRecord
        let priorTokenUID = prior?.tokenUID ?? defaults.string(forKey: tokenUIDKey)
        let operationGeneration = generation
        do {
            try await adapter.activate(tokenUID: candidateRecord.tokenUID)
            try ensureCurrent(operationGeneration)
            generation &+= 1

            if let priorTokenUID, priorTokenUID != candidateRecord.tokenUID {
                persist(priorTokenUID, forKey: retiredTokenUIDKey)
            }
            self.candidateRecord = nil
            let account = commit(candidateRecord)
            clearPersistedValue(forKey: candidateTokenUIDKey)

            if let priorTokenUID, priorTokenUID != candidateRecord.tokenUID {
                do {
                    try await adapter.revoke(tokenUID: priorTokenUID)
                    await adapter.clearLocalToken(tokenUID: priorTokenUID)
                    clearPersistedValue(forKey: retiredTokenUIDKey)
                } catch {
                    // B is already committed. Keep A's SDK token plus the
                    // retired marker so a later launch can retry remote
                    // revocation without rolling the confirmed switch back.
                }
            }
            return account
        } catch {
            if candidateRecord.tokenUID != priorTokenUID {
                await adapter.clearLocalToken(tokenUID: candidateRecord.tokenUID)
            }
            self.candidateRecord = nil
            clearPersistedValue(forKey: candidateTokenUIDKey)
            if operationGeneration == generation, let priorTokenUID {
                try? await adapter.activate(tokenUID: priorTokenUID)
            }
            throw map(error)
        }
    }

    /// Cancels a staged switch, removes only the candidate token locally, and
    /// guarantees that the prior account remains the SDK's active client.
    func discardCandidate() async {
        guard !sdkAccountTransitionInProgress else { return }
        let persistedCandidate = defaults.string(forKey: candidateTokenUIDKey)
        guard candidateRecord != nil || persistedCandidate != nil else { return }
        sdkAccountTransitionInProgress = true
        defer { sdkAccountTransitionInProgress = false }
        let candidateTokenUID = candidateRecord?.tokenUID ?? persistedCandidate
        candidateRecord = nil
        let prior = activeRecord
        let priorTokenUID = prior?.tokenUID ?? defaults.string(forKey: tokenUIDKey)
        if let candidateTokenUID, candidateTokenUID != priorTokenUID {
            await adapter.clearLocalToken(tokenUID: candidateTokenUID)
        }
        clearPersistedValue(forKey: candidateTokenUIDKey)
        if let priorTokenUID { try? await adapter.activate(tokenUID: priorTokenUID) }
    }

    func stagedCandidate() async -> CloudAccount? {
        candidateRecord.map(cloudAccount(from:))
    }

    /// Compatibility name; this now stages and never commits implicitly.
    func selectAnotherAccount() async throws -> CloudAccount {
        try await stageAnotherAccount()
    }

    func list(folder: CloudFolder?, cursor: CloudCursor?) async throws -> CloudPage {
        let record = try await requireConnection()
        try validate(folder: folder, account: record)
        let operationGeneration = generation
        let path = folder?.id ?? ""

        do {
            let page = try await adapter.list(
                path: path,
                cursor: cursor?.rawValue,
                rootNamespaceID: record.rootNamespaceID
            )
            try ensureCurrent(operationGeneration)
            return makePage(page, account: record)
        } catch DropboxAdapterError.invalidRoot {
            // Team membership can change the account root. Refresh once and
            // restart the requested page because old cursors bind to old root.
            let refreshed = try await refreshRoot(for: record, generation: operationGeneration)
            let page = try await adapter.list(
                path: path,
                cursor: nil,
                rootNamespaceID: refreshed.rootNamespaceID
            )
            try ensureCurrent(operationGeneration)
            return makePage(page, account: refreshed)
        } catch {
            throw map(error)
        }
    }

    func search(_ query: String, cursor: CloudCursor?) async throws -> CloudPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CloudPage() }

        let record = try await requireConnection()
        let operationGeneration = generation
        do {
            let page = try await adapter.search(
                query: trimmed,
                cursor: cursor?.rawValue,
                rootNamespaceID: record.rootNamespaceID
            )
            try ensureCurrent(operationGeneration)
            return makePage(page, account: record, deduplicating: true)
        } catch DropboxAdapterError.invalidRoot {
            let refreshed = try await refreshRoot(for: record, generation: operationGeneration)
            let page = try await adapter.search(
                query: trimmed,
                cursor: nil,
                rootNamespaceID: refreshed.rootNamespaceID
            )
            try ensureCurrent(operationGeneration)
            return makePage(page, account: refreshed, deduplicating: true)
        } catch {
            throw map(error)
        }
    }

    func download(
        _ item: CloudItem,
        exportFormat: CloudExportFormat?,
        to destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt {
        guard destination.isFileURL else { throw CloudStorageError.downloadNotAllowed }
        let record = try await requireConnection()
        try validate(item: item, account: record)
        let operationGeneration = generation
        let freshRecord: DropboxFileRecord
        do {
            freshRecord = try await adapter.metadata(
                id: item.id,
                rootNamespaceID: record.rootNamespaceID
            )
        } catch {
            throw map(error)
        }
        try ensureCurrent(operationGeneration)
        guard freshRecord.id == item.id else {
            throw CloudStorageError.invalidResponse(code: "dropbox_metadata_id_mismatch")
        }
        let freshItem = makeItem(
            freshRecord,
            accountKey: cloudAccount(from: record).stableAccountKey
        )
        let effectiveExportFormat: CloudExportFormat?
        switch freshItem.kind {
        case .file:
            // A stable Dropbox ID can be renamed from DOCX to PDF (or vice
            // versa). The latest direct file format is authoritative, so a
            // historical export choice must not force the stale route.
            effectiveExportFormat = nil
        case .exportableDocument:
            if let exportFormat, freshItem.exportOptions.contains(exportFormat) {
                effectiveExportFormat = exportFormat
            } else {
                effectiveExportFormat = freshItem.exportOptions.first
            }
        case .folder, .unsupported:
            throw CloudStorageError.unsupportedItem
        }
        let resolvedFormat = try resolveDownloadFormat(
            item: freshItem,
            exportFormat: effectiveExportFormat
        )
        let maximumBytes = resolvedFormat.maximumInputBytes
        if freshItem.kind == .file,
           let size = freshItem.size,
           size > maximumBytes {
            // The destination belongs to this import attempt. Clear any
            // pre-created/partial staging bytes even when fresh metadata lets
            // us reject before the transfer begins.
            Self.removeDownloadedBytes(at: nil, destination: destination)
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }
        do {
            try capacityPreflight(freshItem.size ?? maximumBytes, destination)
        } catch {
            Self.removeDownloadedBytes(at: nil, destination: destination)
            throw error
        }
        var downloadedURL: URL?

        do {
            let transfer = try await adapter.download(
                id: item.id,
                rootNamespaceID: record.rootNamespaceID,
                exportFormat: effectiveExportFormat?.rawValue,
                destination: destination,
                maximumBytes: maximumBytes,
                progress: progress
            )
            downloadedURL = transfer.localURL
            try ensureCurrent(operationGeneration)
            try Self.validateFinalTransferSize(
                transfer.byteCount,
                maximumBytes: maximumBytes
            )

            let descriptor = try Self.transferDescriptor(
                transfer,
                requestedFormat: resolvedFormat,
                isExport: effectiveExportFormat != nil
            )
            return CloudDownloadReceipt(
                localURL: transfer.localURL,
                effectiveFilename: descriptor.filename,
                effectiveMIMEType: descriptor.mimeType,
                effectiveFormat: descriptor.format,
                exportFormat: effectiveExportFormat,
                finalRevision: transfer.revision,
                byteCount: transfer.byteCount
            )
        } catch {
            if downloadedURL != nil || error is DocumentImportError {
                Self.removeDownloadedBytes(at: downloadedURL, destination: destination)
            }
            if let error = error as? DocumentImportError { throw error }
            throw map(error)
        }
    }

    /// Clears the SDK's local token cache and CastReader's token identifiers
    /// when the owning CastReader account/route changes. This must not call
    /// Dropbox's revoke endpoint: an account-isolation boundary is a local
    /// logout, not a destructive change to the user's remote authorization.
    func clearLocalAuthorizationForAccountBoundary() async {
        generation &+= 1
        let tokenUIDs = Set([
            activeRecord?.tokenUID,
            candidateRecord?.tokenUID,
            defaults.string(forKey: tokenUIDKey),
            defaults.string(forKey: candidateTokenUIDKey),
            defaults.string(forKey: retiredTokenUIDKey),
        ].compactMap { $0 })
        activeRecord = nil
        candidateRecord = nil
        state = .disconnected
        sdkAccountTransitionInProgress = false
        clearPersistedValue(forKey: tokenUIDKey)
        clearPersistedValue(forKey: candidateTokenUIDKey)
        clearPersistedValue(forKey: retiredTokenUIDKey)
        for tokenUID in tokenUIDs {
            await adapter.clearLocalToken(tokenUID: tokenUID)
        }
    }

    func disconnect() async -> CloudDisconnectResult {
        generation &+= 1
        let activeTokenUID = activeRecord?.tokenUID ?? defaults.string(forKey: tokenUIDKey)
        let candidateTokenUID = candidateRecord?.tokenUID
            ?? defaults.string(forKey: candidateTokenUIDKey)
        let retiredTokenUID = defaults.string(forKey: retiredTokenUIDKey)
        activeRecord = nil
        candidateRecord = nil
        state = .disconnected
        if let activeTokenUID {
            // If the process dies during disconnect, the next launch sees no
            // active account but still has an identifier with which to finish
            // device-local cleanup.
            persist(activeTokenUID, forKey: retiredTokenUIDKey)
        }
        clearPersistedValue(forKey: tokenUIDKey)

        var localOnlyTokenUIDs = Set([candidateTokenUID, retiredTokenUID].compactMap { $0 })
        localOnlyTokenUIDs.remove(activeTokenUID ?? "")
        for tokenUID in localOnlyTokenUIDs {
            await adapter.clearLocalToken(tokenUID: tokenUID)
        }
        clearPersistedValue(forKey: candidateTokenUIDKey)

        guard let activeTokenUID else {
            clearPersistedValue(forKey: retiredTokenUIDKey)
            return CloudDisconnectResult(provider: .dropbox, remoteRevocationStatus: .unsupported)
        }

        do {
            try await adapter.activate(tokenUID: activeTokenUID)
            try await adapter.revoke(tokenUID: activeTokenUID)
            await adapter.clearLocalToken(tokenUID: activeTokenUID)
            clearPersistedValue(forKey: retiredTokenUIDKey)
            return CloudDisconnectResult(provider: .dropbox, remoteRevocationStatus: .confirmed)
        } catch {
            // Local removal is unconditional even when Dropbox is offline.
            await adapter.clearLocalToken(tokenUID: activeTokenUID)
            clearPersistedValue(forKey: retiredTokenUIDKey)
            let mapped = map(error)
            return CloudDisconnectResult(
                provider: .dropbox,
                remoteRevocationStatus: .unconfirmed,
                retryable: isRetryable(mapped),
                diagnosticCode: diagnosticCode(mapped)
            )
        }
    }

    // MARK: Provider policy

    private func requireConnection() async throws -> DropboxAccountRecord {
        guard !sdkAccountTransitionInProgress else { throw CloudStorageError.staleSession }
        if let activeRecord { return activeRecord }
        _ = try await ensureConnected()
        guard let activeRecord else { throw CloudStorageError.notConnected }
        return activeRecord
    }

    /// Reconciles crash markers before any account is restored. A retired UID
    /// is an old confirmed account: revoke it remotely before clearing its SDK
    /// token. Network failure leaves that marker/token for a later best-effort
    /// retry but never prevents the newly confirmed account from restoring.
    private func reconcilePersistedCredentialCleanup() async throws {
        let activeTokenUID = activeRecord?.tokenUID ?? defaults.string(forKey: tokenUIDKey)
        var removedCurrentSDKClient = false

        if let retiredTokenUID = defaults.string(forKey: retiredTokenUIDKey) {
            if retiredTokenUID != activeTokenUID {
                do {
                    try await adapter.revoke(tokenUID: retiredTokenUID)
                    await adapter.clearLocalToken(tokenUID: retiredTokenUID)
                    clearPersistedValue(forKey: retiredTokenUIDKey)
                    removedCurrentSDKClient = true
                } catch {
                    // Keep the secure SDK token and marker so revocation can
                    // be retried. Active B is restored below and remains usable.
                }
            } else {
                clearPersistedValue(forKey: retiredTokenUIDKey)
            }
        }

        if let candidateTokenUID = defaults.string(forKey: candidateTokenUIDKey) {
            if candidateTokenUID != activeTokenUID {
                await adapter.clearLocalToken(tokenUID: candidateTokenUID)
                removedCurrentSDKClient = true
            }
            clearPersistedValue(forKey: candidateTokenUIDKey)
        }

        if removedCurrentSDKClient, let activeTokenUID {
            try await adapter.activate(tokenUID: activeTokenUID)
        }
    }

    private func commit(_ record: DropboxAccountRecord) -> CloudAccount {
        activeRecord = record
        persist(record.tokenUID, forKey: tokenUIDKey)
        let account = cloudAccount(from: record)
        state = .connected(account)
        return account
    }

    private func persist(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
        _ = defaults.synchronize()
    }

    private func clearPersistedValue(forKey key: String) {
        defaults.removeObject(forKey: key)
        _ = defaults.synchronize()
    }

    private func refreshRoot(
        for prior: DropboxAccountRecord,
        generation operationGeneration: UInt64
    ) async throws -> DropboxAccountRecord {
        let refreshed: DropboxAccountRecord
        do {
            refreshed = try await adapter.refreshCurrentAccount()
        } catch {
            throw map(error)
        }
        try ensureCurrent(operationGeneration)
        guard refreshed.rawAccountID == prior.rawAccountID,
              refreshed.tokenUID == prior.tokenUID else {
            throw CloudStorageError.accountMismatch
        }
        _ = commit(refreshed)
        return refreshed
    }

    private func cloudAccount(from record: DropboxAccountRecord) -> CloudAccount {
        CloudAccount(
            provider: .dropbox,
            stableAccountKey: CloudStableIdentifier.accountKey(
                provider: .dropbox,
                rawAccountID: record.rawAccountID
            ),
            displayName: record.displayName,
            maskedEmail: Self.maskEmail(record.email)
        )
    }

    private static func placeholderAccount(_ stableAccountKey: String) -> CloudAccount {
        CloudAccount(
            provider: .dropbox,
            stableAccountKey: stableAccountKey
        )
    }

    private func validate(folder: CloudFolder?, account: DropboxAccountRecord) throws {
        guard let folder else { return }
        guard folder.provider == .dropbox else { throw CloudStorageError.accountMismatch }
        guard folder.accountKey == cloudAccount(from: account).stableAccountKey else {
            throw CloudStorageError.accountMismatch
        }
    }

    private func validate(item: CloudItem, account: DropboxAccountRecord) throws {
        guard item.provider == .dropbox,
              item.accountKey == cloudAccount(from: account).stableAccountKey else {
            throw CloudStorageError.accountMismatch
        }
    }

    private func makePage(
        _ page: DropboxPageRecord,
        account: DropboxAccountRecord,
        deduplicating: Bool = false
    ) -> CloudPage {
        let accountKey = cloudAccount(from: account).stableAccountKey
        var folders: [CloudFolder] = []
        var items: [CloudItem] = []
        var seen = Set<String>()

        for entry in page.entries {
            switch entry {
            case .folder(let id, let name):
                guard !deduplicating || seen.insert("folder:\(id)").inserted else { continue }
                folders.append(CloudFolder(
                    provider: .dropbox,
                    accountKey: accountKey,
                    id: id,
                    name: name
                ))
            case .file(let file):
                guard !deduplicating || seen.insert("file:\(file.id)").inserted else { continue }
                items.append(makeItem(file, accountKey: accountKey))
            }
        }

        let next = page.hasMore ? page.cursor.map(CloudCursor.init(rawValue:)) : nil
        return CloudPage(folders: folders, items: items, nextCursor: next)
    }

    private func makeItem(_ file: DropboxFileRecord, accountKey: String) -> CloudItem {
        let fileFormat = SupportedDocumentFormat(
            fileExtension: URL(fileURLWithPath: file.name).pathExtension
        )
        let exports = Self.exportOptions(from: file.exportFormats)

        let kind: CloudItemKind
        if file.isDownloadable, fileFormat != nil {
            kind = .file
        } else if !file.isDownloadable, !exports.isEmpty {
            kind = .exportableDocument
        } else {
            kind = .unsupported
        }

        return CloudItem(
            provider: .dropbox,
            accountKey: accountKey,
            id: file.id,
            name: file.name,
            mimeType: fileFormat?.preferredMIMEType,
            size: file.size,
            modifiedAt: file.modifiedAt,
            revision: file.revision,
            kind: kind,
            exportOptions: exports
        )
    }

    private func resolveDownloadFormat(
        item: CloudItem,
        exportFormat: CloudExportFormat?
    ) throws -> SupportedDocumentFormat {
        switch item.kind {
        case .file:
            guard exportFormat == nil else {
                throw CloudStorageError.unsupportedExportFormat(exportFormat)
            }
            guard let format = SupportedDocumentFormat(
                fileExtension: URL(fileURLWithPath: item.name).pathExtension
            ) else {
                throw CloudStorageError.unsupportedItem
            }
            return format
        case .exportableDocument:
            guard let exportFormat, item.exportOptions.contains(exportFormat) else {
                throw CloudStorageError.unsupportedExportFormat(exportFormat)
            }
            return exportFormat.documentFormat
        case .folder, .unsupported:
            throw CloudStorageError.unsupportedItem
        }
    }

    private struct TransferDescriptor {
        let filename: String
        let mimeType: String
        let format: SupportedDocumentFormat
    }

    private static func transferDescriptor(
        _ transfer: DropboxTransferRecord,
        requestedFormat: SupportedDocumentFormat,
        isExport: Bool
    ) throws -> TransferDescriptor {
        let filename = transfer.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else {
            throw CloudStorageError.invalidResponse(code: "dropbox_transfer_filename_missing")
        }

        let pathExtension = URL(fileURLWithPath: filename).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let extensionFormat = SupportedDocumentFormat(fileExtension: pathExtension)
        if !pathExtension.isEmpty, extensionFormat == nil {
            throw CloudStorageError.invalidResponse(code: "dropbox_transfer_extension_unsupported")
        }

        let normalizedMIME = normalizedMIMEType(transfer.mimeType)
        let mimeFormat = try formatForTransferMIME(normalizedMIME)
        if let extensionFormat, let mimeFormat, extensionFormat != mimeFormat {
            throw CloudStorageError.invalidResponse(code: "dropbox_transfer_format_mismatch")
        }

        let responseFormat = extensionFormat ?? mimeFormat
        if isExport, let responseFormat, responseFormat != requestedFormat {
            throw CloudStorageError.invalidResponse(code: "dropbox_export_format_mismatch")
        }
        guard let finalFormat = responseFormat ?? (isExport ? requestedFormat : nil) else {
            throw CloudStorageError.invalidResponse(code: "dropbox_transfer_format_missing")
        }

        let effectiveFilename = SupportedDocumentFormat.normalizedFilename(
            filename,
            format: finalFormat,
            mimeType: normalizedMIME
        )
        return TransferDescriptor(
            filename: effectiveFilename,
            mimeType: normalizedMIME ?? finalFormat.preferredMIMEType,
            format: finalFormat
        )
    }

    private static func normalizedMIMEType(_ value: String?) -> String? {
        guard let normalized = value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func formatForTransferMIME(
        _ mimeType: String?
    ) throws -> SupportedDocumentFormat? {
        guard let mimeType else { return nil }
        if let format = SupportedDocumentFormat.resolve(
            filename: "document",
            mimeType: mimeType
        ) {
            return format
        }
        switch mimeType {
        case "application/octet-stream", "binary/octet-stream",
             "application/zip", "application/x-zip-compressed":
            return nil
        default:
            throw CloudStorageError.invalidResponse(code: "dropbox_transfer_mime_unsupported")
        }
    }

    private static func validateFinalTransferSize(
        _ size: Int64,
        maximumBytes: Int64
    ) throws {
        guard size >= 0 else {
            throw CloudStorageError.invalidResponse(code: "dropbox_invalid_transfer_size")
        }
        guard size <= maximumBytes else {
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }
    }

    private static func removeDownloadedBytes(at localURL: URL?, destination: URL) {
        var paths = Set([destination.standardizedFileURL])
        if let localURL, localURL.isFileURL {
            paths.insert(localURL.standardizedFileURL)
        }
        for path in paths {
            try? FileManager.default.removeItem(at: path)
        }
    }

    private func ensureCurrent(_ operationGeneration: UInt64) throws {
        guard !Task.isCancelled else { throw CloudStorageError.userCancelled }
        guard operationGeneration == generation else { throw CloudStorageError.staleSession }
    }

    private func map(_ error: Error) -> CloudStorageError {
        if let error = error as? CloudStorageError { return error }
        if error is CancellationError { return .userCancelled }
        guard let error = error as? DropboxAdapterError else {
            return .provider(code: "dropbox_unknown", retryable: false)
        }
        switch error {
        case .userCancelled: return .userCancelled
        case .notConnected: return .notConnected
        case .needsReauthorization: return .needsReauthorization
        case .itemUnavailable: return .itemUnavailable
        case .downloadNotAllowed: return .downloadNotAllowed
        case .unsupportedItem: return .unsupportedItem
        case .unsupportedExportFormat: return .unsupportedExportFormat(nil)
        case .invalidRoot: return .provider(code: "dropbox_invalid_root", retryable: true)
        case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
        case .network(let code): return .network(code: code)
        case .provider(let code, let retryable): return .provider(code: code, retryable: retryable)
        }
    }

    private func isRetryable(_ error: CloudStorageError) -> Bool {
        switch error {
        case .network, .rateLimited: return true
        case .provider(_, let retryable): return retryable
        default: return false
        }
    }

    private func diagnosticCode(_ error: CloudStorageError) -> String {
        switch error {
        case .network(let code): return code
        case .rateLimited: return "dropbox_rate_limited"
        case .needsReauthorization: return "dropbox_reauthorization_required"
        case .provider(let code, _): return code
        default: return "dropbox_disconnect_failed"
        }
    }

    static func exportOptions(from rawFormats: [String]) -> [CloudExportFormat] {
        var result: [CloudExportFormat] = []
        for raw in rawFormats.map({ $0.lowercased() }) {
            let value: CloudExportFormat?
            switch raw {
            case "pdf": value = .pdf
            case "docx": value = .docx
            default: value = nil
            }
            if let value, !result.contains(value) { result.append(value) }
        }
        return result
    }

    static func maskEmail(_ email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        let local = String(email[..<at])
        let domain = String(email[at...])
        guard !local.isEmpty else { return "***" + domain }
        return String(local.prefix(1)) + "***" + domain
    }
}

// MARK: - SwiftyDropbox production adapter

#if canImport(SwiftyDropbox)

private protocol CancellableDropboxRequest: HasRequestResponse {
    func cancel()
}

extension RpcRequest: CancellableDropboxRequest {}
extension DownloadRequestFile: CancellableDropboxRequest {}

private final class DropboxTransferLimitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int64
    private var cancellation: (() -> Void)?
    private var exceeded = false

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
    }

    func registerCancellation(_ cancellation: @escaping () -> Void) {
        lock.lock()
        self.cancellation = cancellation
        let shouldCancel = exceeded
        lock.unlock()
        if shouldCancel { cancellation() }
    }

    /// Returns false once the transfer has crossed the hard input boundary.
    func accepts(completedBytes: Int64, totalBytes: Int64) -> Bool {
        lock.lock()
        if completedBytes > maximumBytes
            || totalBytes > maximumBytes {
            exceeded = true
        }
        let shouldCancel = exceeded
        let cancellation = self.cancellation
        lock.unlock()
        if shouldCancel { cancellation?() }
        return !shouldCancel
    }

    var didExceedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceeded
    }

    func clearCancellation() {
        lock.lock()
        cancellation = nil
        lock.unlock()
    }
}

private func cancellableDropboxResponse<Request: CancellableDropboxRequest>(
    _ request: Request
) async throws -> Request.ValueType {
    let value = try await withTaskCancellationHandler {
        try await request.response()
    } onCancel: {
        request.cancel()
    }
    try Task.checkCancellation()
    return value
}

@MainActor
private enum DropboxOAuthBroker {
    private struct PendingAuthorization {
        let id: UUID
        let continuation: CheckedContinuation<String, Error>
        let fallbackTokenUID: String?
        var expectedOAuthState: String?
    }

    private struct CancelledAuthorization {
        let fallbackTokenUID: String?
    }

    private static var configuredAppKey: String?
    private static var pendingAuthorization: PendingAuthorization?
    private static var cancelledAuthorizations: [String: CancelledAuthorization] = [:]
    private static var lastKnownActiveTokenUID: String?
    private static var acceptedTokenUIDs = Set<String>()
    private static var deferredCancelledTokens: [(tokenUID: String, fallback: String?)] = []

    static func ensureConfigured(appKey: String, tokenUID: String?) throws {
        guard !appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DropboxAdapterError.provider(code: "dropbox_app_key_missing", retryable: false)
        }
        if let configuredAppKey {
            guard configuredAppKey == appKey else {
                throw DropboxAdapterError.provider(code: "dropbox_app_key_changed", retryable: false)
            }
            if let tokenUID {
                DropboxClientsManager.reauthorizeClient(tokenUID)
            }
            return
        }

        DropboxClientsManager.setupWithAppKeyMultiUser(
            appKey,
            transportClient: nil,
            backgroundTransportClient: nil,
            tokenUid: tokenUID,
            includeBackgroundClient: false
        )
        configuredAppKey = appKey
    }

    static func authorize(
        appKey: String,
        fallbackTokenUID: String?,
        presenter: @escaping @MainActor @Sendable () -> UIViewController?
    ) async throws -> String {
        try ensureConfigured(appKey: appKey, tokenUID: nil)
        guard pendingAuthorization == nil else {
            throw DropboxAdapterError.provider(code: "dropbox_authorization_in_progress", retryable: true)
        }
        guard let controller = presenter() else {
            throw DropboxAdapterError.provider(code: "dropbox_presenter_missing", retryable: true)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { newContinuation in
                let authorizationID = UUID()
                pendingAuthorization = PendingAuthorization(
                    id: authorizationID,
                    continuation: newContinuation,
                    fallbackTokenUID: fallbackTokenUID,
                    expectedOAuthState: nil
                )
                let scopes = ScopeRequest(
                    scopeType: .user,
                    scopes: ["account_info.read", "files.metadata.read", "files.content.read"],
                    includeGrantedScopes: false
                )
                DropboxClientsManager.authorizeFromControllerV2(
                    UIApplication.shared,
                    controller: controller,
                    loadingStatusDelegate: nil,
                    openURL: { url in
                        openAuthorizationURL(url, authorizationID: authorizationID)
                    },
                    scopeRequest: scopes
                )
            }
        } onCancel: {
            Task { @MainActor in cancelAuthorization() }
        }
    }

    private static func cancelAuthorization() {
        guard let pending = pendingAuthorization else { return }
        pendingAuthorization = nil
        if let state = pending.expectedOAuthState {
            cancelledAuthorizations[state] = CancelledAuthorization(
                fallbackTokenUID: pending.fallbackTokenUID
            )
            // A cancelled browser that never calls back must not grow this
            // process-local tombstone set without bound.
            if cancelledAuthorizations.count > 12,
               let oldestKey = cancelledAuthorizations.keys.first {
                cancelledAuthorizations.removeValue(forKey: oldestKey)
            }
        }
        pending.continuation.resume(throwing: CancellationError())
    }

    static func handleRedirectURL(_ url: URL) -> Bool {
        let callbackState = oauthState(in: url)
        return DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { result in
            if let callbackState,
               let cancelled = cancelledAuthorizations.removeValue(forKey: callbackState) {
                // Consume exactly the cancelled attempt that owns this state.
                // Multiple late callbacks can no longer erase one another's
                // fallback account.
                if case .success(let token) = result {
                    handleOrphanedSuccessfulToken(
                        token.uid,
                        fallbackTokenUID: cancelled.fallbackTokenUID,
                        deferIfAuthorizationPending: true
                    )
                }
                restoreAuthorizedClient(
                    lastKnownActiveTokenUID ?? cancelled.fallbackTokenUID
                )
                return
            }

            guard let pending = pendingAuthorization else {
                // The task may have been cancelled while Safari/Dropbox was
                // still finishing. The SDK stores a successful token before
                // invoking this callback, so remove that orphan explicitly.
                if case .success(let token) = result {
                    handleOrphanedSuccessfulToken(
                        token.uid,
                        fallbackTokenUID: lastKnownActiveTokenUID,
                        deferIfAuthorizationPending: false
                    )
                }
                restoreAuthorizedClient(lastKnownActiveTokenUID)
                return
            }
            // SwiftyDropbox owns PKCE and generates the OAuth state. Capture
            // that state from the URL it asks us to open, then bind the
            // callback to the same authorization attempt. A late callback
            // from a cancelled attempt may clean up only its own token; it
            // must never resume the continuation of a newer attempt.
            guard let expectedState = pending.expectedOAuthState,
                  let callbackState,
                  expectedState == callbackState else {
                if case .success(let token) = result {
                    handleOrphanedSuccessfulToken(
                        token.uid,
                        fallbackTokenUID: pending.fallbackTokenUID,
                        deferIfAuthorizationPending: true
                    )
                }
                restoreAuthorizedClient(
                    pending.fallbackTokenUID ?? lastKnownActiveTokenUID
                )
                return
            }
            pendingAuthorization = nil
            switch result {
            case .success(let token):
                acceptedTokenUIDs.insert(token.uid)
                cleanupDeferredCancelledTokens()
                DropboxClientsManager.reauthorizeClient(token.uid)
                pending.continuation.resume(returning: token.uid)
            case .cancel:
                cleanupDeferredCancelledTokens()
                restoreAuthorizedClient(lastKnownActiveTokenUID ?? pending.fallbackTokenUID)
                pending.continuation.resume(throwing: DropboxAdapterError.userCancelled)
            case .error(let error, _):
                cleanupDeferredCancelledTokens()
                restoreAuthorizedClient(lastKnownActiveTokenUID ?? pending.fallbackTokenUID)
                pending.continuation.resume(throwing: DropboxAdapterError.provider(
                    code: "dropbox_oauth_\(error.rawValue)",
                    retryable: error == .temporarilyUnavailable
                ))
            case nil:
                cleanupDeferredCancelledTokens()
                restoreAuthorizedClient(lastKnownActiveTokenUID ?? pending.fallbackTokenUID)
                pending.continuation.resume(throwing: DropboxAdapterError.provider(
                    code: "dropbox_oauth_empty_result",
                    retryable: false
                ))
            }
        }
    }

    private static func handleOrphanedSuccessfulToken(
        _ tokenUID: String,
        fallbackTokenUID: String?,
        deferIfAuthorizationPending: Bool
    ) {
        let cleanup = DropboxOAuthOrphanTokenPolicy.cleanup(
            tokenUID: tokenUID,
            acceptedTokenUIDs: acceptedTokenUIDs,
            lastKnownActiveTokenUID: lastKnownActiveTokenUID,
            hasPendingAuthorization: deferIfAuthorizationPending
                && pendingAuthorization != nil
        )
        switch cleanup {
        case .preserve:
            // A newer authorization/provider generation owns this exact SDK
            // token. Since token UID is stable per user, deleting it would also
            // delete the active credential.
            break
        case .deferUntilPendingAuthorizationFinishes:
            guard !deferredCancelledTokens.contains(where: {
                $0.tokenUID == tokenUID
            }) else { return }
            deferredCancelledTokens.append((
                tokenUID: tokenUID,
                fallback: fallbackTokenUID
            ))
        case .clearNow:
            clear(tokenUID: tokenUID, resetClients: false)
        }
    }

    private static func openAuthorizationURL(_ url: URL, authorizationID: UUID) {
        guard var pending = pendingAuthorization,
              pending.id == authorizationID else { return }
        guard let state = oauthState(in: url) else {
            pendingAuthorization = nil
            pending.continuation.resume(throwing: DropboxAdapterError.provider(
                code: "dropbox_oauth_state_missing",
                retryable: false
            ))
            return
        }
        pending.expectedOAuthState = state
        pendingAuthorization = pending
        UIApplication.shared.open(url)
    }

    private static func oauthState(in url: URL) -> String? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "state" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func client(appKey: String, tokenUID: String? = nil) throws -> DropboxClient {
        try ensureConfigured(appKey: appKey, tokenUID: tokenUID)
        guard let client = DropboxClientsManager.authorizedClient else {
            throw DropboxAdapterError.notConnected
        }
        return client
    }

    static func rememberActive(tokenUID: String?) {
        lastKnownActiveTokenUID = tokenUID
    }

    private static func restoreAuthorizedClient(_ tokenUID: String?) {
        guard let tokenUID else {
            DropboxClientsManager.resetClients()
            return
        }
        DropboxClientsManager.reauthorizeClient(tokenUID)
        lastKnownActiveTokenUID = tokenUID
    }

    private static func cleanupDeferredCancelledTokens() {
        let deferred = deferredCancelledTokens
        deferredCancelledTokens.removeAll(keepingCapacity: true)
        for value in deferred
        where !acceptedTokenUIDs.contains(value.tokenUID)
            && value.tokenUID != lastKnownActiveTokenUID {
            clear(tokenUID: value.tokenUID, resetClients: false)
        }
    }

    static func clear(tokenUID: String, resetClients: Bool) {
        acceptedTokenUIDs.remove(tokenUID)
        if lastKnownActiveTokenUID == tokenUID {
            lastKnownActiveTokenUID = nil
        }
        if let manager = DropboxOAuthManager.sharedOAuthManager,
           let token = manager.getAccessToken(tokenUID) {
            _ = manager.clearStoredAccessToken(token)
        }
        if resetClients { DropboxClientsManager.resetClients() }
    }
}

actor SwiftyDropboxAdapter: DropboxProviderAdapter {
    private let appKey: String
    private let presenter: @MainActor @Sendable () -> UIViewController?
    private var activeTokenUID: String?

    init(
        appKey: String,
        presenter: @escaping @MainActor @Sendable () -> UIViewController?
    ) {
        self.appKey = appKey
        self.presenter = presenter
    }

    func restoreAccount(tokenUID: String?) async throws -> DropboxAccountRecord? {
        guard let tokenUID else {
            try await DropboxOAuthBroker.ensureConfigured(appKey: appKey, tokenUID: nil)
            return nil
        }
        do {
            _ = try await DropboxOAuthBroker.client(appKey: appKey, tokenUID: tokenUID)
            activeTokenUID = tokenUID
            let account = try await fetchAccount(tokenUID: tokenUID)
            await DropboxOAuthBroker.rememberActive(tokenUID: tokenUID)
            return account
        } catch DropboxAdapterError.notConnected {
            return nil
        } catch {
            throw mapSDKError(error)
        }
    }

    func authorize() async throws -> DropboxAccountRecord {
        let fallbackTokenUID = activeTokenUID
        let tokenUID = try await DropboxOAuthBroker.authorize(
            appKey: appKey,
            fallbackTokenUID: fallbackTokenUID,
            presenter: presenter
        )
        activeTokenUID = tokenUID
        do {
            let account = try await fetchAccount(tokenUID: tokenUID)
            await DropboxOAuthBroker.rememberActive(tokenUID: tokenUID)
            return account
        } catch {
            await DropboxOAuthBroker.clear(tokenUID: tokenUID, resetClients: true)
            if let fallbackTokenUID {
                try? await DropboxOAuthBroker.ensureConfigured(
                    appKey: appKey,
                    tokenUID: fallbackTokenUID
                )
                activeTokenUID = fallbackTokenUID
            } else {
                activeTokenUID = nil
            }
            throw error
        }
    }

    func refreshCurrentAccount() async throws -> DropboxAccountRecord {
        guard let activeTokenUID else { throw DropboxAdapterError.notConnected }
        return try await fetchAccount(tokenUID: activeTokenUID)
    }

    func activate(tokenUID: String) async throws {
        _ = try await DropboxOAuthBroker.client(appKey: appKey, tokenUID: tokenUID)
        activeTokenUID = tokenUID
        await DropboxOAuthBroker.rememberActive(tokenUID: tokenUID)
    }

    func metadata(
        id: String,
        rootNamespaceID: String
    ) async throws -> DropboxFileRecord {
        do {
            let client = try await rootedClient(rootNamespaceID: rootNamespaceID)
            let request = client.files.getMetadata(
                path: id,
                includeMediaInfo: false,
                includeDeleted: false,
                includeHasExplicitSharedMembers: false
            )
            let metadata = try await cancellableDropboxResponse(request)
            guard let file = metadata as? Files.FileMetadata else {
                throw DropboxAdapterError.itemUnavailable
            }
            return Self.fileRecord(from: file)
        } catch let error as DropboxAdapterError {
            throw error
        } catch {
            throw mapSDKError(error)
        }
    }

    func list(
        path: String,
        cursor: String?,
        rootNamespaceID: String
    ) async throws -> DropboxPageRecord {
        do {
            let client = try await rootedClient(rootNamespaceID: rootNamespaceID)
            let result: Files.ListFolderResult
            if let cursor {
                let request = client.files.listFolderContinue(cursor: cursor)
                result = try await cancellableDropboxResponse(request)
            } else {
                let request = client.files.listFolder(
                    path: path,
                    recursive: false,
                    includeMountedFolders: true,
                    includeNonDownloadableFiles: true
                )
                result = try await cancellableDropboxResponse(request)
            }
            return DropboxPageRecord(
                entries: result.entries.compactMap(Self.record(from:)),
                cursor: result.cursor,
                hasMore: result.hasMore
            )
        } catch {
            throw mapSDKError(error)
        }
    }

    func search(
        query: String,
        cursor: String?,
        rootNamespaceID: String
    ) async throws -> DropboxPageRecord {
        do {
            let client = try await rootedClient(rootNamespaceID: rootNamespaceID)
            let result: Files.SearchV2Result
            if let cursor {
                let request = client.files.searchContinueV2(cursor: cursor)
                result = try await cancellableDropboxResponse(request)
            } else {
                let request = client.files.searchV2(query: query)
                result = try await cancellableDropboxResponse(request)
            }
            let entries = result.matches.compactMap { match -> DropboxEntryRecord? in
                guard case .metadata(let metadata) = match.metadata else { return nil }
                return Self.record(from: metadata)
            }
            return DropboxPageRecord(entries: entries, cursor: result.cursor, hasMore: result.hasMore)
        } catch {
            throw mapSDKError(error)
        }
    }

    func download(
        id: String,
        rootNamespaceID: String,
        exportFormat: String?,
        destination: URL,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> DropboxTransferRecord {
        do {
            let client = try await rootedClient(rootNamespaceID: rootNamespaceID)
            if let exportFormat {
                let limitGate = DropboxTransferLimitGate(maximumBytes: maximumBytes)
                let request = client.files.export(
                    path: id,
                    exportFormat: exportFormat,
                    overwrite: true,
                    destination: destination
                ).progress { value in
                    guard limitGate.accepts(
                        completedBytes: value.completedUnitCount,
                        totalBytes: value.totalUnitCount
                    ) else { return }
                    progress(CloudDownloadProgress(
                        completedBytes: value.completedUnitCount,
                        totalBytes: value.totalUnitCount
                    ))
                }
                limitGate.registerCancellation { request.cancel() }
                defer { limitGate.clearCancellation() }
                let resultAndURL: (Files.ExportResult, URL)
                do {
                    resultAndURL = try await cancellableDropboxResponse(request)
                } catch {
                    if limitGate.didExceedLimit {
                        throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
                    }
                    throw error
                }
                let (result, localURL) = resultAndURL
                return DropboxTransferRecord(
                    localURL: localURL,
                    filename: result.exportMetadata.name,
                    mimeType: Self.inferredMIMEType(filename: result.exportMetadata.name),
                    byteCount: try Self.fileByteCount(localURL),
                    revision: result.fileMetadata.rev
                )
            }

            let limitGate = DropboxTransferLimitGate(maximumBytes: maximumBytes)
            let request = client.files.download(
                path: id,
                overwrite: true,
                destination: destination
            ).progress { value in
                guard limitGate.accepts(
                    completedBytes: value.completedUnitCount,
                    totalBytes: value.totalUnitCount
                ) else { return }
                progress(CloudDownloadProgress(
                    completedBytes: value.completedUnitCount,
                    totalBytes: value.totalUnitCount
                ))
            }
            limitGate.registerCancellation { request.cancel() }
            defer { limitGate.clearCancellation() }
            let metadataAndURL: (Files.FileMetadata, URL)
            do {
                metadataAndURL = try await cancellableDropboxResponse(request)
            } catch {
                if limitGate.didExceedLimit {
                    throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
                }
                throw error
            }
            let (metadata, localURL) = metadataAndURL
            return DropboxTransferRecord(
                localURL: localURL,
                filename: metadata.name,
                mimeType: Self.inferredMIMEType(filename: metadata.name),
                byteCount: try Self.fileByteCount(localURL),
                revision: metadata.rev
            )
        } catch let error as DocumentImportError {
            throw error
        } catch {
            throw mapSDKError(error)
        }
    }

    func revoke(tokenUID: String) async throws {
        let tokenToRestore = activeTokenUID == tokenUID ? nil : activeTokenUID
        do {
            let client = try await DropboxOAuthBroker.client(appKey: appKey, tokenUID: tokenUID)
            let request = client.auth.tokenRevoke()
            _ = try await cancellableDropboxResponse(request)
            if let tokenToRestore {
                try await DropboxOAuthBroker.ensureConfigured(
                    appKey: appKey,
                    tokenUID: tokenToRestore
                )
            }
        } catch {
            if let tokenToRestore {
                try? await DropboxOAuthBroker.ensureConfigured(
                    appKey: appKey,
                    tokenUID: tokenToRestore
                )
            }
            throw mapSDKError(error)
        }
    }

    func clearLocalToken(tokenUID: String) async {
        let wasActive = activeTokenUID == tokenUID
        await DropboxOAuthBroker.clear(tokenUID: tokenUID, resetClients: wasActive)
        if wasActive { activeTokenUID = nil }
    }

    private func fetchAccount(tokenUID: String) async throws -> DropboxAccountRecord {
        do {
            let client = try await DropboxOAuthBroker.client(appKey: appKey, tokenUID: tokenUID)
            let request = client.users.getCurrentAccount()
            let account = try await cancellableDropboxResponse(request)
            return DropboxAccountRecord(
                rawAccountID: account.accountId,
                tokenUID: tokenUID,
                displayName: account.name.displayName,
                email: account.email,
                rootNamespaceID: account.rootInfo.rootNamespaceId
            )
        } catch {
            throw mapSDKError(error)
        }
    }

    private func rootedClient(rootNamespaceID: String) async throws -> DropboxClient {
        let client = try await DropboxOAuthBroker.client(appKey: appKey)
        return client.withPathRoot(.root(rootNamespaceID))
    }

    private static func record(from metadata: Files.Metadata) -> DropboxEntryRecord? {
        if let folder = metadata as? Files.FolderMetadata {
            return .folder(id: folder.id, name: folder.name)
        }
        guard let file = metadata as? Files.FileMetadata else { return nil }
        return .file(fileRecord(from: file))
    }

    private static func fileRecord(from file: Files.FileMetadata) -> DropboxFileRecord {
        let rawExports = ([file.exportInfo?.exportAs].compactMap { $0 })
            + (file.exportInfo?.exportOptions ?? [])
        return DropboxFileRecord(
            id: file.id,
            name: file.name,
            size: int64(file.size),
            modifiedAt: file.serverModified,
            revision: file.rev,
            isDownloadable: file.isDownloadable,
            exportFormats: rawExports
        )
    }

    private static func int64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private static func fileByteCount(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw DropboxAdapterError.provider(
                code: "dropbox_download_file_size",
                retryable: false
            )
        }
        return Int64(fileSize)
    }

    private static func inferredMIMEType(filename: String) -> String? {
        SupportedDocumentFormat(
            fileExtension: URL(fileURLWithPath: filename).pathExtension
        )?.preferredMIMEType
    }

    private func mapSDKError(_ error: Error) -> DropboxAdapterError {
        if let error = error as? DropboxAdapterError { return error }
        if error is CancellationError { return .userCancelled }

        #if canImport(SwiftyDropbox)
        if let error = error as? CallError<Files.DownloadError> {
            return Self.mapCallError(error, route: Self.mapDownloadRouteError)
        }
        if let error = error as? CallError<Files.ExportError> {
            return Self.mapCallError(error, route: Self.mapExportRouteError)
        }
        if let error = error as? CallError<Files.GetMetadataError> {
            return Self.mapCallError(error) { route in
                switch route {
                case .path(let lookup): return Self.mapLookupError(lookup)
                }
            }
        }
        if let error = error as? CallError<Files.ListFolderError> {
            return Self.mapCallError(error) { route in
                switch route {
                case .path(let lookup): return Self.mapLookupError(lookup)
                case .templateError, .other:
                    return .provider(code: "dropbox_list_folder_route", retryable: false)
                }
            }
        }
        if let error = error as? CallError<Files.ListFolderContinueError> {
            return Self.mapCallError(error) { route in
                switch route {
                case .path(let lookup): return Self.mapLookupError(lookup)
                case .reset:
                    return .provider(code: "dropbox_cursor_reset", retryable: true)
                case .other:
                    return .provider(code: "dropbox_list_continue_route", retryable: false)
                }
            }
        }
        if let error = error as? CallError<Files.SearchError> {
            return Self.mapCallError(error) { route in
                switch route {
                case .path(let lookup): return Self.mapLookupError(lookup)
                case .internalError:
                    return .provider(code: "dropbox_search_internal", retryable: true)
                case .invalidArgument, .other:
                    return .provider(code: "dropbox_search_route", retryable: false)
                }
            }
        }
        if let error = error as? CallError<Void> {
            return Self.mapCallError(error) { _ in
                .provider(code: "dropbox_void_route", retryable: false)
            }
        }
        #endif

        let nsError = error as NSError
        let description = String(describing: error).lowercased()
        if description.contains("invalid_root") || description.contains("invalidroot") {
            return .invalidRoot
        }
        if description.contains("expired_access_token")
            || description.contains("invalid_access_token")
            || description.contains("auth error") {
            return .needsReauthorization
        }
        if description.contains("not_found")
            || description.contains("notfound")
            || description.contains("path_lookup") {
            return .itemUnavailable
        }
        if description.contains("not_downloadable")
            || description.contains("notdownloadable")
            || description.contains("insufficient_permission")
            || description.contains("no_permission") {
            return .downloadNotAllowed
        }
        if description.contains("rate limit") || nsError.code == 429 {
            return .rateLimited(nil)
        }
        if nsError.domain == NSURLErrorDomain {
            return .network("dropbox_url_\(nsError.code)")
        }
        return .provider(code: "dropbox_sdk_\(nsError.code)", retryable: false)
    }

    #if canImport(SwiftyDropbox)
    static func mapDownloadRouteError(_ error: Files.DownloadError) -> DropboxAdapterError {
        switch error {
        case .path(let lookup): return mapLookupError(lookup)
        case .unsupportedFile: return .unsupportedItem
        case .other:
            return .provider(code: "dropbox_download_route", retryable: false)
        }
    }

    static func mapExportRouteError(_ error: Files.ExportError) -> DropboxAdapterError {
        switch error {
        case .path(let lookup): return mapLookupError(lookup)
        case .nonExportable: return .unsupportedItem
        case .invalidExportFormat: return .unsupportedExportFormat
        case .retryError:
            return .provider(code: "dropbox_export_not_ready", retryable: true)
        case .other:
            return .provider(code: "dropbox_export_route", retryable: false)
        }
    }

    static func mapLookupError(_ error: Files.LookupError) -> DropboxAdapterError {
        switch error {
        case .notFound, .notFile, .notFolder:
            return .itemUnavailable
        case .restrictedContent:
            return .downloadNotAllowed
        case .unsupportedContentType:
            return .unsupportedItem
        case .locked:
            return .provider(code: "dropbox_content_locked", retryable: true)
        case .malformedPath, .other:
            return .provider(code: "dropbox_lookup", retryable: false)
        }
    }

    static func mapCallError<Route>(
        _ error: CallError<Route>,
        route: (Route) -> DropboxAdapterError
    ) -> DropboxAdapterError {
        switch error {
        case .routeError(let boxed, _, _, _):
            return route(boxed.unboxed)
        case .authError(let authError, _, _, _):
            return mapAuthError(authError)
        case .accessError:
            return .provider(code: "dropbox_access_policy", retryable: false)
        case .rateLimitError(let rateLimit, _, _, _):
            return mapRateLimitError(rateLimit)
        case .internalServerError:
            return .provider(code: "dropbox_server", retryable: true)
        case .httpError(let code, let message, _):
            if isInvalidRootMessage(message) { return .invalidRoot }
            if code == 401 { return .needsReauthorization }
            if code == 429 { return .rateLimited(nil) }
            return .provider(
                code: "dropbox_http_\(code ?? 0)",
                retryable: code.map { (500..<600).contains($0) } ?? true
            )
        case .clientError(let clientError):
            return mapClientError(clientError)
        case .reconnectionError(let underlying):
            return mapNSError(underlying as NSError, fallback: "dropbox_reconnection")
        case .badInputError(let message, _):
            if isInvalidRootMessage(message) { return .invalidRoot }
            return .provider(code: "dropbox_sdk_response", retryable: false)
        case .serializationError:
            return .provider(code: "dropbox_sdk_response", retryable: false)
        }
    }

    private static func isInvalidRootMessage(_ message: String?) -> Bool {
        let normalized = message?.lowercased() ?? ""
        return normalized.contains("invalid_root")
            || normalized.contains("invalidroot")
    }

    static func mapAuthError(_ error: Auth.AuthError) -> DropboxAdapterError {
        switch error {
        case .invalidAccessToken, .expiredAccessToken:
            return .needsReauthorization
        case .invalidSelectUser, .invalidSelectAdmin, .userSuspended,
             .missingScope, .routeAccessDenied, .other:
            return .provider(code: "dropbox_auth_policy", retryable: false)
        }
    }

    static func mapRateLimitError(_ error: Auth.RateLimitError) -> DropboxAdapterError {
        let retryAfter = error.retryAfter > UInt64(Int.max)
            ? nil
            : Int(error.retryAfter)
        return .rateLimited(retryAfter)
    }

    static func mapClientError(_ error: ClientError) -> DropboxAdapterError {
        switch error {
        case .oauthError:
            return .needsReauthorization
        case .urlSessionError(let underlying):
            return mapNSError(underlying as NSError, fallback: "dropbox_url_session")
        case .fileAccessError:
            return .provider(code: "dropbox_file_access", retryable: false)
        case .requestObjectDeallocated:
            return .userCancelled
        case .unexpectedState:
            return .provider(code: "dropbox_sdk_state", retryable: true)
        case .other(let underlying):
            return mapNSError(underlying as NSError, fallback: "dropbox_client")
        }
    }

    private static func mapNSError(
        _ error: NSError,
        fallback: String
    ) -> DropboxAdapterError {
        if error.domain == NSURLErrorDomain {
            return .network("dropbox_url_\(error.code)")
        }
        return .provider(code: fallback, retryable: false)
    }
    #endif
}

#endif
