//
//  OneDriveProvider.swift
//  CastReader
//
//  MSAL (Files.Read only) + Microsoft Graph. Files are streamed to a local
//  destination and never uploaded to CastReader's backend.
//

import Foundation
import UIKit

#if canImport(MSAL)
@preconcurrency import MSAL
#endif

// MARK: - Injectable boundary

struct OneDriveAccountRecord: Equatable, Sendable {
    let rawAccountID: String
    let cacheAccountIdentifier: String
    let displayName: String?
    let email: String?
}

struct OneDriveItemRecord: Equatable, Sendable {
    let id: String
    let driveID: String?
    let name: String
    let size: Int64?
    let modifiedAt: Date?
    let eTag: String?
    let cTag: String?
    let mimeType: String?
    let isFolder: Bool
    let isPackage: Bool

    var revision: String? { cTag ?? eTag }
}

struct OneDrivePageRecord: Equatable, Sendable {
    let entries: [OneDriveItemRecord]
    let nextLink: String?
}

struct OneDriveDriveRecord: Equatable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

struct OneDriveTransferRecord: Equatable, Sendable {
    let localURL: URL
    let byteCount: Int64
}

enum OneDriveAdapterError: Error, Equatable, Sendable {
    case userCancelled
    case notConnected
    case needsReauthorization
    case itemUnavailable
    case downloadNotAllowed
    case rateLimited(Int?)
    case invalidResponse(String)
    case network(String)
    case provider(code: String, retryable: Bool)
}

protocol OneDriveProviderAdapter: Actor {
    func restoreAccount(accountIdentifier: String?) async throws -> OneDriveAccountRecord?
    func authorize(selectAccount: Bool) async throws -> OneDriveAccountRecord

    func metadata(itemID: String, driveID: String?) async throws -> OneDriveItemRecord

    func listDrives() async throws -> [OneDriveDriveRecord]

    func list(
        folderID: String?,
        driveID: String?,
        nextLink: String?
    ) async throws -> OneDrivePageRecord

    func search(
        query: String,
        driveID: String?,
        nextLink: String?
    ) async throws -> OneDrivePageRecord

    func download(
        itemID: String,
        driveID: String?,
        destination: URL,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> OneDriveTransferRecord

    /// Removes this app's account and tokens from the MSAL cache. It does not
    /// claim to revoke the Microsoft account's consent remotely.
    func signOut(accountIdentifier: String) async throws
}

// MARK: - Provider

actor OneDriveProvider: CloudDriveListingProvider {
    nonisolated let id: CloudProviderID = .oneDrive
    nonisolated let selectionCapability: CloudSelectionCapability = .persistentConnectionAndNativeBrowser

    private let adapter: any OneDriveProviderAdapter
    private let defaults: UserDefaults
    private let accountIdentifierKey: String
    private let candidateAccountIdentifierKey: String
    private let retiredAccountIdentifierKey: String
    private let pendingCleanupAccountIdentifiersKey: String
    private let capacityPreflight: CloudDownloadCapacityPreflight

    private var state: CloudConnectionState = .disconnected
    private var activeRecord: OneDriveAccountRecord?
    private var candidateRecord: OneDriveAccountRecord?
    private var generation: UInt64 = 0
    private var sdkAccountTransitionInProgress = false

    init(
        adapter: any OneDriveProviderAdapter,
        defaults: UserDefaults = .standard,
        accountIdentifierKey: String = "cloud.onedrive.activeMSALAccountIdentifier",
        candidateAccountIdentifierKey: String = "cloud.onedrive.pendingCandidateMSALAccountIdentifier",
        retiredAccountIdentifierKey: String = "cloud.onedrive.pendingRetiredMSALAccountIdentifier",
        pendingCleanupAccountIdentifiersKey: String =
            "cloud.onedrive.pendingCleanupMSALAccountIdentifiers",
        capacityPreflight: @escaping CloudDownloadCapacityPreflight =
            CloudDownloadCapacityPolicy.live
    ) {
        self.adapter = adapter
        self.defaults = defaults
        self.accountIdentifierKey = accountIdentifierKey
        self.candidateAccountIdentifierKey = candidateAccountIdentifierKey
        self.retiredAccountIdentifierKey = retiredAccountIdentifierKey
        self.pendingCleanupAccountIdentifiersKey = pendingCleanupAccountIdentifiersKey
        self.capacityPreflight = capacityPreflight
    }

#if canImport(MSAL)
    init(
        clientID: String,
        authority: String = "https://login.microsoftonline.com/common",
        redirectURI: String? = nil,
        presenter: @escaping @MainActor @Sendable () -> UIViewController?,
        defaults: UserDefaults = .standard,
        accountIdentifierKey: String = "cloud.onedrive.activeMSALAccountIdentifier",
        candidateAccountIdentifierKey: String = "cloud.onedrive.pendingCandidateMSALAccountIdentifier",
        retiredAccountIdentifierKey: String = "cloud.onedrive.pendingRetiredMSALAccountIdentifier",
        pendingCleanupAccountIdentifiersKey: String =
            "cloud.onedrive.pendingCleanupMSALAccountIdentifiers",
        urlSession: URLSession = .shared,
        capacityPreflight: @escaping CloudDownloadCapacityPreflight =
            CloudDownloadCapacityPolicy.live
    ) throws {
        let auth = try MSALOneDriveAuthSession(
            clientID: clientID,
            authority: authority,
            redirectURI: redirectURI,
            presenter: presenter
        )
        let graph = OneDriveGraphAPI(session: urlSession)
        self.adapter = MSALOneDriveAdapter(auth: auth, graph: graph)
        self.defaults = defaults
        self.accountIdentifierKey = accountIdentifierKey
        self.candidateAccountIdentifierKey = candidateAccountIdentifierKey
        self.retiredAccountIdentifierKey = retiredAccountIdentifierKey
        self.pendingCleanupAccountIdentifiersKey = pendingCleanupAccountIdentifiersKey
        self.capacityPreflight = capacityPreflight
    }

    /// Route MSAL callback URLs here from the app/scene URL handler.
    @MainActor
    static func handleRedirectURL(_ url: URL, sourceApplication: String? = nil) -> Bool {
        MSALPublicClientApplication.handleMSALResponse(
            url,
            sourceApplication: sourceApplication
        )
    }
#endif

    func connectionState() async -> CloudConnectionState {
        state
    }

    /// Silent-only restore used by cloud History validation. It never opens
    /// MSAL UI and never accepts an account other than the recorded owner.
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
        let accountIdentifier = defaults.string(forKey: accountIdentifierKey)
        guard let accountIdentifier else {
            state = .needsReauthorization(expectedAccountKey.map(Self.placeholderAccount))
            throw CloudStorageError.needsReauthorization
        }
        do {
            guard let restored = try await adapter.restoreAccount(
                accountIdentifier: accountIdentifier
            ) else {
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
                // Explicit connect is the sole path allowed to present MSAL.
            }
        }

        state = .connecting
        let operationGeneration = generation
        let priorIdentifier = defaults.string(forKey: accountIdentifierKey)
        var newlyAuthorizedRecord: OneDriveAccountRecord?
        do {
            let selected = try await adapter.authorize(selectAccount: true)
            newlyAuthorizedRecord = selected
            try ensureCurrent(operationGeneration)
            guard let authorized = try await adapter.restoreAccount(
                accountIdentifier: selected.cacheAccountIdentifier
            ), authorized.rawAccountID == selected.rawAccountID else {
                throw CloudStorageError.accountMismatch
            }
            try ensureCurrent(operationGeneration)
            let account = cloudAccount(from: authorized)
            if let expectedAccountKey,
               account.stableAccountKey != expectedAccountKey {
                persist(authorized.cacheAccountIdentifier, forKey: candidateAccountIdentifierKey)
                candidateRecord = authorized
                newlyAuthorizedRecord = nil
                if let priorIdentifier,
                   priorIdentifier != authorized.cacheAccountIdentifier {
                    _ = try? await adapter.restoreAccount(accountIdentifier: priorIdentifier)
                }
                state = .needsReauthorization(Self.placeholderAccount(expectedAccountKey))
                throw CloudStorageError.accountMismatch
            }

            let committed = commit(authorized)
            newlyAuthorizedRecord = nil
            return committed
        } catch {
            if map(error) == .accountMismatch, candidateRecord != nil {
                throw CloudStorageError.accountMismatch
            }
            if let newlyAuthorizedRecord {
                try? await adapter.signOut(
                    accountIdentifier: newlyAuthorizedRecord.cacheAccountIdentifier
                )
            }
            let mapped = map(error)
            if mapped == .staleSession { throw mapped }
            state = .needsReauthorization(expectedAccountKey.map(Self.placeholderAccount))
            throw mapped
        }
    }

    /// MSAL prompt=.selectAccount is used, but the returned account is only a
    /// candidate. The adapter silently reactivates A before returning so A
    /// remains usable throughout the A → B confirmation sheet.
    func stageAnotherAccount() async throws -> CloudAccount {
        let prior = try await requireConnection()
        if candidateRecord != nil { await discardCandidate() }
        guard !sdkAccountTransitionInProgress else { throw CloudStorageError.staleSession }
        sdkAccountTransitionInProgress = true
        defer { sdkAccountTransitionInProgress = false }
        let priorState = state
        let operationGeneration = generation
        var selectedRecord: OneDriveAccountRecord?
        do {
            let selected = try await adapter.authorize(selectAccount: true)
            selectedRecord = selected
            persist(selected.cacheAccountIdentifier, forKey: candidateAccountIdentifierKey)
            try ensureCurrent(operationGeneration)
            guard let restored = try await adapter.restoreAccount(
                accountIdentifier: prior.cacheAccountIdentifier
            ), restored.rawAccountID == prior.rawAccountID else {
                throw CloudStorageError.accountMismatch
            }
            try ensureCurrent(operationGeneration)
            candidateRecord = selected
            state = priorState
            return cloudAccount(from: selected)
        } catch {
            if let selectedRecord,
               selectedRecord.cacheAccountIdentifier != prior.cacheAccountIdentifier {
                do {
                    try await adapter.signOut(
                        accountIdentifier: selectedRecord.cacheAccountIdentifier
                    )
                    clearPersistedValue(forKey: candidateAccountIdentifierKey)
                } catch {
                    // Keep the marker so cold-start reconciliation retries.
                }
            } else {
                clearPersistedValue(forKey: candidateAccountIdentifierKey)
            }
            if operationGeneration == generation {
                _ = try? await adapter.restoreAccount(
                    accountIdentifier: prior.cacheAccountIdentifier
                )
                state = priorState
            }
            throw map(error)
        }
    }

    /// Commits the staged MSAL account only after explicit UI confirmation.
    func commitCandidate() async throws -> CloudAccount {
        guard let candidateRecord else {
            throw CloudStorageError.invalidResponse(code: "onedrive_candidate_missing")
        }
        guard !sdkAccountTransitionInProgress else { throw CloudStorageError.staleSession }
        sdkAccountTransitionInProgress = true
        defer { sdkAccountTransitionInProgress = false }
        let prior = activeRecord
        let priorIdentifier = prior?.cacheAccountIdentifier
            ?? defaults.string(forKey: accountIdentifierKey)
        let operationGeneration = generation
        do {
            guard let activated = try await adapter.restoreAccount(
                accountIdentifier: candidateRecord.cacheAccountIdentifier
            ), activated.rawAccountID == candidateRecord.rawAccountID else {
                throw CloudStorageError.accountMismatch
            }
            try ensureCurrent(operationGeneration)
            generation &+= 1

            if let priorIdentifier,
               priorIdentifier != candidateRecord.cacheAccountIdentifier {
                persist(
                    priorIdentifier,
                    forKey: retiredAccountIdentifierKey
                )
            }
            self.candidateRecord = nil
            let account = commit(activated)

            if let priorIdentifier,
               priorIdentifier != candidateRecord.cacheAccountIdentifier {
                do {
                    try await adapter.signOut(
                        accountIdentifier: priorIdentifier
                    )
                    clearPersistedValue(forKey: retiredAccountIdentifierKey)
                } catch {
                    // Keep the retired marker; next launch retries local cache
                    // removal before restoring the committed B account.
                }
            }
            clearPersistedValue(forKey: candidateAccountIdentifierKey)
            return account
        } catch {
            if candidateRecord.cacheAccountIdentifier != priorIdentifier {
                do {
                    try await adapter.signOut(
                        accountIdentifier: candidateRecord.cacheAccountIdentifier
                    )
                    clearPersistedValue(forKey: candidateAccountIdentifierKey)
                } catch {
                    // Persisted candidate marker intentionally remains.
                }
            } else {
                clearPersistedValue(forKey: candidateAccountIdentifierKey)
            }
            self.candidateRecord = nil
            if operationGeneration == generation, let priorIdentifier {
                _ = try? await adapter.restoreAccount(
                    accountIdentifier: priorIdentifier
                )
            }
            throw map(error)
        }
    }

    /// Removes the candidate from MSAL's local cache and restores A. It does
    /// not perform a remote Microsoft sign-out or consent revocation.
    func discardCandidate() async {
        guard !sdkAccountTransitionInProgress else { return }
        let persistedCandidate = defaults.string(forKey: candidateAccountIdentifierKey)
        guard candidateRecord != nil || persistedCandidate != nil else { return }
        sdkAccountTransitionInProgress = true
        defer { sdkAccountTransitionInProgress = false }
        let candidateIdentifier = candidateRecord?.cacheAccountIdentifier ?? persistedCandidate
        candidateRecord = nil
        let prior = activeRecord
        let priorIdentifier = prior?.cacheAccountIdentifier
            ?? defaults.string(forKey: accountIdentifierKey)
        if let candidateIdentifier, candidateIdentifier != priorIdentifier {
            do {
                try await adapter.signOut(accountIdentifier: candidateIdentifier)
                clearPersistedValue(forKey: candidateAccountIdentifierKey)
            } catch {
                // Keep the marker for cold-start retry.
            }
        } else {
            clearPersistedValue(forKey: candidateAccountIdentifierKey)
        }
        if let priorIdentifier {
            _ = try? await adapter.restoreAccount(
                accountIdentifier: priorIdentifier
            )
        }
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
        do {
            let result = try await adapter.list(
                folderID: folder?.id,
                driveID: folder?.driveID,
                nextLink: cursor?.rawValue
            )
            try ensureCurrent(operationGeneration)
            return makePage(result, account: record)
        } catch {
            throw map(error)
        }
    }

    func listDrives() async throws -> [CloudDrive] {
        let record = try await requireConnection()
        let operationGeneration = generation
        do {
            let drives = try await adapter.listDrives()
            try ensureCurrent(operationGeneration)

            let accountKey = cloudAccount(from: record).stableAccountKey
            var seen = Set<String>()
            return drives.compactMap { drive in
                let id = drive.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                let name = drive.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return CloudDrive(
                    provider: .oneDrive,
                    accountKey: accountKey,
                    id: id,
                    name: name.isEmpty ? "OneDrive" : name,
                    isDefault: drive.isDefault
                )
            }
        } catch {
            throw map(error)
        }
    }

    func search(_ query: String, cursor: CloudCursor?) async throws -> CloudPage {
        try await search(query, driveID: nil, cursor: cursor)
    }

    func search(
        _ query: String,
        driveID: String?,
        cursor: CloudCursor?
    ) async throws -> CloudPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CloudPage() }

        let record = try await requireConnection()
        let operationGeneration = generation
        do {
            let result = try await adapter.search(
                query: trimmed,
                driveID: driveID,
                nextLink: cursor?.rawValue
            )
            try ensureCurrent(operationGeneration)
            return makePage(result, account: record, deduplicating: true)
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
        guard exportFormat == nil else {
            throw CloudStorageError.unsupportedExportFormat(exportFormat)
        }
        guard item.kind == .file else { throw CloudStorageError.unsupportedItem }

        let operationGeneration = generation
        var destinationContainsUnverifiedBytes = false
        var downloadedURL: URL?
        do {
            for attempt in 0..<2 {
                let before = try await adapter.metadata(
                    itemID: item.id,
                    driveID: item.driveID
                )
                try ensureCurrent(operationGeneration)
                let beforeFormat = try verifiedFormat(
                    for: before,
                    expectedItemID: item.id,
                    expectedDriveID: item.driveID
                )
                let maximumBytes = beforeFormat.maximumInputBytes
                try Self.validateFreshSize(
                    before.size,
                    maximumBytes: maximumBytes
                )
                try capacityPreflight(before.size ?? maximumBytes, destination)

                let transfer = try await adapter.download(
                    itemID: item.id,
                    driveID: item.driveID,
                    destination: destination,
                    maximumBytes: maximumBytes,
                    progress: progress
                )
                destinationContainsUnverifiedBytes = true
                downloadedURL = transfer.localURL
                try ensureCurrent(operationGeneration)
                try Self.validateFinalTransferSize(
                    transfer.byteCount,
                    maximumBytes: maximumBytes
                )

                let after = try await adapter.metadata(
                    itemID: item.id,
                    driveID: item.driveID
                )
                try ensureCurrent(operationGeneration)
                let finalFormat = try verifiedFormat(
                    for: after,
                    expectedItemID: item.id,
                    expectedDriveID: item.driveID
                )
                try Self.validateFreshSize(
                    after.size,
                    maximumBytes: finalFormat.maximumInputBytes
                )

                guard Self.metadataIsStable(
                    before: before,
                    after: after,
                    downloadedByteCount: transfer.byteCount
                ) else {
                    if attempt == 0 { continue }
                    throw CloudStorageError.provider(
                        code: "onedrive_item_changed_during_download",
                        retryable: true
                    )
                }

                destinationContainsUnverifiedBytes = false
                return CloudDownloadReceipt(
                    localURL: transfer.localURL,
                    effectiveFilename: SupportedDocumentFormat.normalizedFilename(
                        after.name,
                        format: finalFormat,
                        mimeType: after.mimeType
                    ),
                    effectiveMIMEType: Self.effectiveMIMEType(
                        after.mimeType,
                        fallback: finalFormat.preferredMIMEType
                    ),
                    effectiveFormat: finalFormat,
                    finalRevision: after.revision,
                    byteCount: max(0, transfer.byteCount)
                )
            }

            throw CloudStorageError.provider(
                code: "onedrive_item_changed_during_download",
                retryable: true
            )
        } catch {
            if destinationContainsUnverifiedBytes || error is DocumentImportError {
                Self.removeDownloadedBytes(at: downloadedURL, destination: destination)
            }
            if let error = error as? DocumentImportError { throw error }
            throw map(error)
        }
    }

    func disconnect() async -> CloudDisconnectResult {
        generation &+= 1
        let activeIdentifier = activeRecord?.cacheAccountIdentifier
            ?? defaults.string(forKey: accountIdentifierKey)
        let candidateIdentifier = candidateRecord?.cacheAccountIdentifier
            ?? defaults.string(forKey: candidateAccountIdentifierKey)
        let retiredIdentifier = defaults.string(forKey: retiredAccountIdentifierKey)
        activeRecord = nil
        candidateRecord = nil
        state = .disconnected

        // Persist the complete cleanup transaction before removing the active
        // association. A crash at any later point can retry every MSAL cache
        // account instead of losing an older retired/candidate identifier when
        // the active identifier would otherwise overwrite a single marker.
        var cleanupIdentifiers = pendingCleanupAccountIdentifiers()
        cleanupIdentifiers.formUnion(
            [activeIdentifier, candidateIdentifier, retiredIdentifier].compactMap { $0 }
        )
        persistPendingCleanupAccountIdentifiers(cleanupIdentifiers)
        clearPersistedValue(forKey: accountIdentifierKey)

        let cleanup = await cleanPendingMSALAccounts(cleanupIdentifiers)
        clearLegacyCleanupMarkers(
            remaining: cleanup.remaining,
            activeIdentifier: nil
        )
        return CloudDisconnectResult(
            provider: .oneDrive,
            localAssociationRemoved: cleanup.remaining.isEmpty,
            remoteRevocationStatus: .unsupported,
            retryable: cleanup.retryable,
            diagnosticCode: cleanup.diagnosticCode
        )
    }

    // MARK: Provider policy

    private func requireConnection() async throws -> OneDriveAccountRecord {
        guard !sdkAccountTransitionInProgress else { throw CloudStorageError.staleSession }
        if let activeRecord { return activeRecord }
        _ = try await ensureConnected()
        guard let activeRecord else { throw CloudStorageError.notConnected }
        return activeRecord
    }

    private func reconcilePersistedCredentialCleanup() async throws {
        var activeIdentifier = activeRecord?.cacheAccountIdentifier
            ?? defaults.string(forKey: accountIdentifierKey)
        let retiredIdentifier = defaults.string(forKey: retiredAccountIdentifierKey)
        let candidateIdentifier = defaults.string(forKey: candidateAccountIdentifierKey)
        var cleanupIdentifiers = pendingCleanupAccountIdentifiers()

        // A pending-set entry matching the persisted active account is a
        // crash-recovered disconnect intent. Do not resurrect that credential.
        if let disconnectIdentifier = activeIdentifier,
           cleanupIdentifiers.contains(disconnectIdentifier) {
            clearPersistedValue(forKey: accountIdentifierKey)
            if activeRecord?.cacheAccountIdentifier == disconnectIdentifier {
                activeRecord = nil
            }
            self.state = .disconnected
            self.candidateRecord = nil
            self.sdkAccountTransitionInProgress = false
            self.generation &+= 1
            activeIdentifier = nil
        }

        // Migrate the two legacy single-value markers into the crash-safe set.
        // A marker equal to the still-active account is a completed transaction
        // remnant and must not sign that account out.
        for identifier in [retiredIdentifier, candidateIdentifier].compactMap({ $0 })
        where identifier != activeIdentifier {
            cleanupIdentifiers.insert(identifier)
        }
        persistPendingCleanupAccountIdentifiers(cleanupIdentifiers)

        let cleanup = await cleanPendingMSALAccounts(cleanupIdentifiers)
        clearLegacyCleanupMarkers(
            remaining: cleanup.remaining,
            activeIdentifier: activeIdentifier
        )

        if !cleanupIdentifiers.isEmpty, let activeIdentifier {
            _ = try? await adapter.restoreAccount(accountIdentifier: activeIdentifier)
        }
        if let firstError = cleanup.firstError {
            throw firstError
        }
    }

    private func pendingCleanupAccountIdentifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: pendingCleanupAccountIdentifiersKey) ?? [])
    }

    private func persistPendingCleanupAccountIdentifiers(_ identifiers: Set<String>) {
        if identifiers.isEmpty {
            defaults.removeObject(forKey: pendingCleanupAccountIdentifiersKey)
        } else {
            defaults.set(identifiers.sorted(), forKey: pendingCleanupAccountIdentifiersKey)
        }
        _ = defaults.synchronize()
    }

    private func cleanPendingMSALAccounts(
        _ identifiers: Set<String>
    ) async -> (
        remaining: Set<String>,
        firstError: Error?,
        retryable: Bool,
        diagnosticCode: String?
    ) {
        var remaining = identifiers
        var firstError: Error?
        var retryable = false
        var firstDiagnosticCode: String?

        for identifier in identifiers.sorted() {
            do {
                try await adapter.signOut(accountIdentifier: identifier)
                remaining.remove(identifier)
                // Persist after each successful removal so a process death does
                // not repeat already-completed work or lose failures still owed.
                persistPendingCleanupAccountIdentifiers(remaining)
            } catch {
                firstError = firstError ?? error
                let mapped = map(error)
                retryable = retryable || isRetryable(mapped)
                firstDiagnosticCode = firstDiagnosticCode ?? diagnosticCode(mapped)
            }
        }
        persistPendingCleanupAccountIdentifiers(remaining)
        return (remaining, firstError, retryable, firstDiagnosticCode)
    }

    private func clearLegacyCleanupMarkers(
        remaining: Set<String>,
        activeIdentifier: String?
    ) {
        if let candidateIdentifier = defaults.string(forKey: candidateAccountIdentifierKey),
           candidateIdentifier == activeIdentifier || !remaining.contains(candidateIdentifier) {
            clearPersistedValue(forKey: candidateAccountIdentifierKey)
        }
        if let retiredIdentifier = defaults.string(forKey: retiredAccountIdentifierKey),
           retiredIdentifier == activeIdentifier || !remaining.contains(retiredIdentifier) {
            clearPersistedValue(forKey: retiredAccountIdentifierKey)
        }
    }

    private func commit(_ record: OneDriveAccountRecord) -> CloudAccount {
        activeRecord = record
        persist(record.cacheAccountIdentifier, forKey: accountIdentifierKey)
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

    private func cloudAccount(from record: OneDriveAccountRecord) -> CloudAccount {
        CloudAccount(
            provider: .oneDrive,
            stableAccountKey: CloudStableIdentifier.accountKey(
                provider: .oneDrive,
                rawAccountID: record.rawAccountID
            ),
            displayName: record.displayName,
            maskedEmail: Self.maskEmail(record.email)
        )
    }

    private static func placeholderAccount(_ stableAccountKey: String) -> CloudAccount {
        CloudAccount(
            provider: .oneDrive,
            stableAccountKey: stableAccountKey
        )
    }

    private func validate(folder: CloudFolder?, account: OneDriveAccountRecord) throws {
        guard let folder else { return }
        guard folder.provider == .oneDrive,
              folder.accountKey == cloudAccount(from: account).stableAccountKey else {
            throw CloudStorageError.accountMismatch
        }
    }

    private func validate(item: CloudItem, account: OneDriveAccountRecord) throws {
        guard item.provider == .oneDrive,
              item.accountKey == cloudAccount(from: account).stableAccountKey else {
            throw CloudStorageError.accountMismatch
        }
    }

    private func verifiedFormat(
        for metadata: OneDriveItemRecord,
        expectedItemID: String,
        expectedDriveID: String?
    ) throws -> SupportedDocumentFormat {
        guard metadata.id == expectedItemID,
              metadata.driveID == expectedDriveID else {
            throw CloudStorageError.accountMismatch
        }
        guard !metadata.isFolder,
              !metadata.isPackage,
              let format = Self.documentFormat(
                filename: metadata.name,
                mimeType: metadata.mimeType
              ) else {
            throw CloudStorageError.unsupportedItem
        }
        return format
    }

    /// A successful receipt requires the remote metadata to bracket the exact
    /// transfer without changing. `cTag` protects file content, `eTag` also
    /// catches metadata/rename changes, and the size check ties the installed
    /// bytes to the final snapshot when Graph supplies a size.
    private static func metadataIsStable(
        before: OneDriveItemRecord,
        after: OneDriveItemRecord,
        downloadedByteCount: Int64
    ) -> Bool {
        guard before.id == after.id,
              before.driveID == after.driveID,
              before.name == after.name,
              before.cTag == after.cTag,
              before.eTag == after.eTag,
              before.size == after.size,
              normalizedMIMEType(before.mimeType) == normalizedMIMEType(after.mimeType)
        else { return false }

        guard let finalSize = after.size else { return downloadedByteCount >= 0 }
        return finalSize == downloadedByteCount
    }

    private static func validateFreshSize(
        _ size: Int64?,
        maximumBytes: Int64
    ) throws {
        guard let size else { return }
        guard size >= 0 else {
            throw CloudStorageError.invalidResponse(code: "onedrive_invalid_item_size")
        }
        guard size <= maximumBytes else {
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }
    }

    private static func validateFinalTransferSize(
        _ size: Int64,
        maximumBytes: Int64
    ) throws {
        guard size >= 0 else {
            throw CloudStorageError.invalidResponse(code: "onedrive_invalid_transfer_size")
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

    private static func normalizedMIMEType(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func effectiveMIMEType(_ value: String?, fallback: String) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return fallback }
        return value
    }

    private func makePage(
        _ page: OneDrivePageRecord,
        account: OneDriveAccountRecord,
        deduplicating: Bool = false
    ) -> CloudPage {
        let accountKey = cloudAccount(from: account).stableAccountKey
        var folders: [CloudFolder] = []
        var items: [CloudItem] = []
        var seen = Set<String>()

        for entry in page.entries {
            let stableID = (entry.driveID ?? "") + ":" + entry.id
            guard !deduplicating || seen.insert(stableID).inserted else { continue }

            if entry.isFolder, !entry.isPackage {
                folders.append(CloudFolder(
                    provider: .oneDrive,
                    accountKey: accountKey,
                    driveID: entry.driveID,
                    id: entry.id,
                    name: entry.name
                ))
                continue
            }

            let format = Self.documentFormat(filename: entry.name, mimeType: entry.mimeType)
            let kind: CloudItemKind = !entry.isPackage && !entry.isFolder && format != nil
                ? .file
                : .unsupported
            items.append(CloudItem(
                provider: .oneDrive,
                accountKey: accountKey,
                driveID: entry.driveID,
                id: entry.id,
                name: entry.name,
                mimeType: entry.mimeType ?? format?.preferredMIMEType,
                size: entry.size,
                modifiedAt: entry.modifiedAt,
                revision: entry.revision,
                kind: kind
            ))
        }

        return CloudPage(
            folders: folders,
            items: items,
            nextCursor: page.nextLink.map(CloudCursor.init(rawValue:))
        )
    }

    private func ensureCurrent(_ operationGeneration: UInt64) throws {
        guard !Task.isCancelled else { throw CloudStorageError.userCancelled }
        guard operationGeneration == generation else { throw CloudStorageError.staleSession }
    }

    private func map(_ error: Error) -> CloudStorageError {
        if let error = error as? CloudStorageError { return error }
        if error is CancellationError { return .userCancelled }
        guard let error = error as? OneDriveAdapterError else {
            return .provider(code: "onedrive_unknown", retryable: false)
        }
        switch error {
        case .userCancelled: return .userCancelled
        case .notConnected: return .notConnected
        case .needsReauthorization: return .needsReauthorization
        case .itemUnavailable: return .itemUnavailable
        case .downloadNotAllowed: return .downloadNotAllowed
        case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
        case .invalidResponse(let code): return .invalidResponse(code: code)
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
        case .rateLimited: return "onedrive_rate_limited"
        case .needsReauthorization: return "onedrive_reauthorization_required"
        case .provider(let code, _): return code
        default: return "onedrive_signout_failed"
        }
    }

    static func documentFormat(filename: String, mimeType: String?) -> SupportedDocumentFormat? {
        SupportedDocumentFormat.resolve(filename: filename, mimeType: mimeType)
    }

    static func maskEmail(_ email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        let local = String(email[..<at])
        let domain = String(email[at...])
        guard !local.isEmpty else { return "***" + domain }
        return String(local.prefix(1)) + "***" + domain
    }
}

// MARK: - Microsoft Graph codec

enum OneDriveGraphCodec {
    private static let graphHost = "graph.microsoft.com"
    private static let selectFields = "id,name,size,lastModifiedDateTime,eTag,cTag,file,folder,package,parentReference,remoteItem"

    static func rootChildrenURL() -> URL {
        endpointURL(path: "/v1.0/me/drive/root/children")
    }

    static func childrenURL(driveID: String?, itemID: String) -> URL {
        if let driveID {
            if itemID == "root" {
                return endpointURL(pathComponents: ["v1.0", "drives", driveID, "root", "children"])
            }
            return endpointURL(pathComponents: ["v1.0", "drives", driveID, "items", itemID, "children"])
        }
        if itemID == "root" { return rootChildrenURL() }
        return endpointURL(pathComponents: ["v1.0", "me", "drive", "items", itemID, "children"])
    }

    static func searchURL(query: String, driveID: String?) -> URL {
        let escaped = query.replacingOccurrences(of: "'", with: "''")
        if let driveID {
            return endpointURL(pathComponents: [
                "v1.0", "drives", driveID, "root", "search(q='\(escaped)')"
            ])
        }
        return endpointURL(path: "/v1.0/me/drive/root/search(q='\(escaped)')")
    }

    static func defaultDriveURL() -> URL {
        endpointURL(path: "/v1.0/me/drive", select: "id,name")
    }

    static func drivesURL() -> URL {
        endpointURL(path: "/v1.0/me/drives", select: "id,name")
    }

    static func contentURL(driveID: String?, itemID: String) -> URL {
        if let driveID {
            return endpointURL(pathComponents: ["v1.0", "drives", driveID, "items", itemID, "content"], includeSelect: false)
        }
        return endpointURL(pathComponents: ["v1.0", "me", "drive", "items", itemID, "content"], includeSelect: false)
    }

    static func metadataURL(driveID: String?, itemID: String) -> URL {
        if let driveID {
            return endpointURL(pathComponents: ["v1.0", "drives", driveID, "items", itemID])
        }
        return endpointURL(pathComponents: ["v1.0", "me", "drive", "items", itemID])
    }

    static func validatedNextLink(_ rawValue: String) throws -> URL {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == graphHost,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let url = components.url else {
            throw OneDriveAdapterError.invalidResponse("onedrive_untrusted_next_link")
        }
        return url
    }

    static func validatedPreauthenticatedDownloadURL(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw OneDriveAdapterError.invalidResponse("onedrive_invalid_download_redirect")
        }
        return url
    }

    static func preauthenticatedDownloadRequest(url: URL) throws -> URLRequest {
        var request = URLRequest(url: try validatedPreauthenticatedDownloadURL(url))
        request.httpMethod = "GET"
        // Constructed from scratch on purpose: Authorization from the Graph
        // request must never reach the preauthenticated storage host.
        return request
    }

    static func decodePage(_ data: Data) throws -> OneDrivePageRecord {
        let response: GraphCollection
        do {
            response = try JSONDecoder().decode(GraphCollection.self, from: data)
        } catch {
            throw OneDriveAdapterError.invalidResponse("onedrive_page_decode")
        }
        return OneDrivePageRecord(
            entries: response.value.compactMap(canonicalRecord(from:)),
            nextLink: response.nextLink
        )
    }

    static func decodeItem(_ data: Data) throws -> OneDriveItemRecord {
        let item: GraphDriveItem
        do {
            item = try JSONDecoder().decode(GraphDriveItem.self, from: data)
        } catch {
            throw OneDriveAdapterError.invalidResponse("onedrive_metadata_decode")
        }
        guard let record = canonicalRecord(from: item) else {
            throw OneDriveAdapterError.invalidResponse("onedrive_metadata_missing_id")
        }
        return record
    }

    static func decodeDefaultDrive(_ data: Data) throws -> OneDriveDriveRecord {
        let drive: GraphDrive
        do {
            drive = try JSONDecoder().decode(GraphDrive.self, from: data)
        } catch {
            throw OneDriveAdapterError.invalidResponse("onedrive_default_drive_decode")
        }
        guard let record = driveRecord(from: drive, isDefault: true) else {
            throw OneDriveAdapterError.invalidResponse("onedrive_default_drive_missing_id")
        }
        return record
    }

    static func decodeDrivePage(
        _ data: Data,
        defaultDriveID: String
    ) throws -> (drives: [OneDriveDriveRecord], nextLink: String?) {
        let response: GraphDriveCollection
        do {
            response = try JSONDecoder().decode(GraphDriveCollection.self, from: data)
        } catch {
            throw OneDriveAdapterError.invalidResponse("onedrive_drives_decode")
        }
        return (
            response.value.compactMap {
                driveRecord(from: $0, isDefault: $0.id == defaultDriveID)
            },
            response.nextLink
        )
    }

    private static func driveRecord(
        from drive: GraphDrive,
        isDefault: Bool
    ) -> OneDriveDriveRecord? {
        guard let id = drive.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        let name = drive.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OneDriveDriveRecord(
            id: id,
            name: name?.isEmpty == false ? name! : "OneDrive",
            isDefault: isDefault
        )
    }

    private static func canonicalRecord(from item: GraphDriveItem) -> OneDriveItemRecord? {
        let target = item.remoteItem.map(GraphCanonicalItem.init) ?? GraphCanonicalItem(item)
        guard let id = target.id, !id.isEmpty else { return nil }
        let displayName = item.name?.isEmpty == false ? item.name! : (target.name ?? "")
        return OneDriveItemRecord(
            id: id,
            driveID: target.parentReference?.driveID ?? item.parentReference?.driveID,
            name: displayName,
            size: target.size ?? item.size,
            modifiedAt: parseDate(target.lastModifiedDateTime ?? item.lastModifiedDateTime),
            eTag: target.eTag ?? item.eTag,
            cTag: target.cTag ?? item.cTag,
            mimeType: target.file?.mimeType ?? item.file?.mimeType,
            isFolder: target.folder != nil,
            isPackage: target.package != nil
        )
    }

    private static func endpointURL(path: String, select: String = selectFields) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = graphHost
        components.path = path
        components.queryItems = [URLQueryItem(name: "$select", value: select)]
        return components.url!
    }

    private static func endpointURL(
        pathComponents: [String],
        includeSelect: Bool = true
    ) -> URL {
        var url = URL(string: "https://\(graphHost)")!
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        guard includeSelect else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "$select", value: selectFields)]
        return components.url!
    }

    private static func parseDate(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: rawValue) ?? ISO8601DateFormatter().date(from: rawValue)
    }

    private struct GraphCollection: Decodable {
        let value: [GraphDriveItem]
        let nextLink: String?

        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct GraphDriveCollection: Decodable {
        let value: [GraphDrive]
        let nextLink: String?

        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct GraphDrive: Decodable {
        let id: String?
        let name: String?
    }

    private struct GraphDriveItem: Decodable {
        let id: String?
        let name: String?
        let size: Int64?
        let lastModifiedDateTime: String?
        let eTag: String?
        let cTag: String?
        let file: GraphFileFacet?
        let folder: GraphFolderFacet?
        let package: GraphPackageFacet?
        let parentReference: GraphParentReference?
        let remoteItem: GraphRemoteItem?
    }

    private struct GraphRemoteItem: Decodable {
        let id: String?
        let name: String?
        let size: Int64?
        let lastModifiedDateTime: String?
        let eTag: String?
        let cTag: String?
        let file: GraphFileFacet?
        let folder: GraphFolderFacet?
        let package: GraphPackageFacet?
        let parentReference: GraphParentReference?
    }

    private struct GraphCanonicalItem {
        let id: String?
        let name: String?
        let size: Int64?
        let lastModifiedDateTime: String?
        let eTag: String?
        let cTag: String?
        let file: GraphFileFacet?
        let folder: GraphFolderFacet?
        let package: GraphPackageFacet?
        let parentReference: GraphParentReference?

        init(_ item: GraphDriveItem) {
            id = item.id
            name = item.name
            size = item.size
            lastModifiedDateTime = item.lastModifiedDateTime
            eTag = item.eTag
            cTag = item.cTag
            file = item.file
            folder = item.folder
            package = item.package
            parentReference = item.parentReference
        }

        init(_ item: GraphRemoteItem) {
            id = item.id
            name = item.name
            size = item.size
            lastModifiedDateTime = item.lastModifiedDateTime
            eTag = item.eTag
            cTag = item.cTag
            file = item.file
            folder = item.folder
            package = item.package
            parentReference = item.parentReference
        }
    }

    private struct GraphFileFacet: Decodable { let mimeType: String? }
    private struct GraphFolderFacet: Decodable {}
    private struct GraphPackageFacet: Decodable {}

    private struct GraphParentReference: Decodable {
        let driveID: String?
        enum CodingKeys: String, CodingKey { case driveID = "driveId" }
    }
}

// MARK: - Graph transport

private final class OneDriveDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRedirectURL: URL?
    private var didExceedLimit = false
    private let blockRedirects: Bool
    private let maximumBytes: Int64
    private let progress: CloudDownloadProgressHandler

    init(
        blockRedirects: Bool,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) {
        self.blockRedirects = blockRedirects
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    var redirectURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRedirectURL
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceedLimit
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard blockRedirects else {
            completionHandler(request)
            return
        }
        lock.lock()
        capturedRedirectURL = request.url
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes
            || totalBytesExpectedToWrite > maximumBytes {
            lock.lock()
            didExceedLimit = true
            lock.unlock()
            downloadTask.cancel()
            return
        }
        progress(CloudDownloadProgress(
            completedBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

private struct OneDriveGraphErrorEnvelope: Decodable {
    let error: OneDriveGraphErrorDetails
}

private final class OneDriveGraphErrorDetails: Decodable {
    let code: String?
    let innerError: OneDriveGraphErrorDetails?
}

enum OneDriveGraphErrorMapper {
    static func map(
        response: HTTPURLResponse,
        data: Data?,
        isDownload: Bool
    ) -> OneDriveAdapterError? {
        guard !(200..<400).contains(response.statusCode) else { return nil }

        let codes = normalizedCodes(data)
        if codes.contains("invalidauthenticationtoken")
            || codes.contains("tokenexpired") {
            return .needsReauthorization
        }
        if codes.contains("itemnotfound")
            || codes.contains("resourcenotfound") {
            return .itemUnavailable
        }
        if codes.contains("activitylimitreached")
            || codes.contains("throttledrequest") {
            return .rateLimited(retryAfterSeconds(response))
        }

        switch response.statusCode {
        case 401:
            return .needsReauthorization
        case 404, 410:
            return .itemUnavailable
        case 403:
            if isAdministrativePolicy(codes) {
                return .provider(code: "onedrive_admin_policy", retryable: false)
            }
            if isDownload, isExplicitDownloadRestriction(codes) {
                return .downloadNotAllowed
            }
            return .provider(code: "onedrive_access_denied", retryable: false)
        case 429:
            return .rateLimited(retryAfterSeconds(response))
        case 500..<600:
            return .provider(
                code: "onedrive_http_\(response.statusCode)",
                retryable: true
            )
        default:
            return .provider(
                code: "onedrive_http_\(response.statusCode)",
                retryable: false
            )
        }
    }

    private static func normalizedCodes(_ data: Data?) -> Set<String> {
        guard let data,
              let envelope = try? JSONDecoder().decode(
                  OneDriveGraphErrorEnvelope.self,
                  from: data
              ) else { return [] }
        var codes = Set<String>()
        var details: OneDriveGraphErrorDetails? = envelope.error
        var depth = 0
        while let current = details, depth < 8 {
            if let code = current.code {
                codes.insert(normalized(code))
            }
            details = current.innerError
            depth += 1
        }
        return codes
    }

    private static func normalized(_ value: String) -> String {
        String(value.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
            .lowercased()
    }

    private static func isAdministrativePolicy(_ codes: Set<String>) -> Bool {
        codes.contains { code in
            code.contains("conditionalaccess")
                || code.contains("admin")
                || code.contains("tenantpolicy")
                || code.contains("compliancepolicy")
                || code == "blockedbypolicy"
        }
    }

    private static func isExplicitDownloadRestriction(_ codes: Set<String>) -> Bool {
        !codes.isDisjoint(with: [
            "downloadnotallowed", "contentrestricted", "restrictedcontent",
            "virusdetected", "malwaredetected",
        ])
    }

    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
    }
}

actor OneDriveGraphAPI {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func metadata(
        itemID: String,
        driveID: String?,
        accessToken: String
    ) async throws -> OneDriveItemRecord {
        var request = URLRequest(
            url: OneDriveGraphCodec.metadataURL(driveID: driveID, itemID: itemID)
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, rawResponse) = try await session.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else {
                throw OneDriveAdapterError.invalidResponse("onedrive_metadata_non_http")
            }
            try validate(response, data: data)
            return try OneDriveGraphCodec.decodeItem(data)
        } catch let error as OneDriveAdapterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw OneDriveAdapterError.network("onedrive_url_\(nsError.code)")
            }
            throw OneDriveAdapterError.provider(code: "onedrive_metadata", retryable: true)
        }
    }

    func listDrives(accessToken: String) async throws -> [OneDriveDriveRecord] {
        let defaultData = try await jsonData(
            url: OneDriveGraphCodec.defaultDriveURL(),
            accessToken: accessToken,
            failureCode: "onedrive_default_drive"
        )
        let defaultDrive = try OneDriveGraphCodec.decodeDefaultDrive(defaultData)

        var records: [OneDriveDriveRecord] = []
        var seen = Set<String>()
        var pageURL: URL? = OneDriveGraphCodec.drivesURL()
        while let url = pageURL {
            try Task.checkCancellation()
            let data = try await jsonData(
                url: url,
                accessToken: accessToken,
                failureCode: "onedrive_drives"
            )
            let page = try OneDriveGraphCodec.decodeDrivePage(
                data,
                defaultDriveID: defaultDrive.id
            )
            for drive in page.drives where seen.insert(drive.id).inserted {
                records.append(drive)
            }
            pageURL = try page.nextLink.map(OneDriveGraphCodec.validatedNextLink)
        }

        if seen.insert(defaultDrive.id).inserted {
            records.insert(defaultDrive, at: 0)
        }
        return records
    }

    func list(
        folderID: String?,
        driveID: String?,
        nextLink: String?,
        accessToken: String
    ) async throws -> OneDrivePageRecord {
        let url: URL
        if let nextLink {
            url = try OneDriveGraphCodec.validatedNextLink(nextLink)
        } else if let folderID {
            url = OneDriveGraphCodec.childrenURL(driveID: driveID, itemID: folderID)
        } else {
            url = OneDriveGraphCodec.rootChildrenURL()
        }
        return try await page(url: url, accessToken: accessToken)
    }

    func search(
        query: String,
        driveID: String?,
        nextLink: String?,
        accessToken: String
    ) async throws -> OneDrivePageRecord {
        let url = try nextLink.map(OneDriveGraphCodec.validatedNextLink)
            ?? OneDriveGraphCodec.searchURL(query: query, driveID: driveID)
        return try await page(url: url, accessToken: accessToken)
    }

    func download(
        itemID: String,
        driveID: String?,
        accessToken: String,
        destination: URL,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> OneDriveTransferRecord {
        var graphRequest = URLRequest(
            url: OneDriveGraphCodec.contentURL(driveID: driveID, itemID: itemID)
        )
        graphRequest.httpMethod = "GET"
        graphRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        var activeDownloadDelegate: OneDriveDownloadDelegate?
        do {
            // First download task cannot follow redirects. This avoids loading
            // a rare direct 200 response in memory and prevents URLSession from
            // forwarding the Bearer header to the storage host.
            let firstDelegate = OneDriveDownloadDelegate(
                blockRedirects: true,
                maximumBytes: maximumBytes,
                progress: { _ in }
            )
            activeDownloadDelegate = firstDelegate
            let (firstTemporaryURL, rawResponse) = try await session.download(
                for: graphRequest,
                delegate: firstDelegate
            )
            guard let response = rawResponse as? HTTPURLResponse else {
                try? fileManager.removeItem(at: firstTemporaryURL)
                throw OneDriveAdapterError.invalidResponse("onedrive_content_non_http")
            }

            if (200..<300).contains(response.statusCode), firstDelegate.redirectURL == nil {
                let byteCount = try install(firstTemporaryURL, at: destination)
                guard byteCount <= maximumBytes else {
                    try? fileManager.removeItem(at: destination)
                    throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
                }
                progress(CloudDownloadProgress(completedBytes: byteCount, totalBytes: byteCount))
                return OneDriveTransferRecord(localURL: destination, byteCount: byteCount)
            }

            let graphErrorData = Self.boundedErrorData(at: firstTemporaryURL)
            try? fileManager.removeItem(at: firstTemporaryURL)
            try validate(response, data: graphErrorData, isDownload: true)
            let location = firstDelegate.redirectURL
                ?? response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))
            guard let location else {
                throw OneDriveAdapterError.invalidResponse("onedrive_content_redirect_missing")
            }

            let storageRequest = try OneDriveGraphCodec.preauthenticatedDownloadRequest(url: location)
            let storageDelegate = OneDriveDownloadDelegate(
                blockRedirects: false,
                maximumBytes: maximumBytes,
                progress: progress
            )
            activeDownloadDelegate = storageDelegate
            let (temporaryURL, storageRawResponse) = try await session.download(
                for: storageRequest,
                delegate: storageDelegate
            )
            guard let storageResponse = storageRawResponse as? HTTPURLResponse else {
                try? fileManager.removeItem(at: temporaryURL)
                throw OneDriveAdapterError.invalidResponse("onedrive_download_non_http")
            }
            guard (200..<300).contains(storageResponse.statusCode) else {
                try? fileManager.removeItem(at: temporaryURL)
                try validate(storageResponse, isDownload: true)
                throw OneDriveAdapterError.invalidResponse("onedrive_download_status")
            }

            let byteCount = try install(temporaryURL, at: destination)
            guard byteCount <= maximumBytes else {
                try? fileManager.removeItem(at: destination)
                throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
            }
            progress(CloudDownloadProgress(completedBytes: byteCount, totalBytes: byteCount))
            return OneDriveTransferRecord(localURL: destination, byteCount: byteCount)
        } catch let error as DocumentImportError {
            throw error
        } catch let error as OneDriveAdapterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if activeDownloadDelegate?.exceededLimit == true {
                try? fileManager.removeItem(at: destination)
                throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw OneDriveAdapterError.network("onedrive_url_\(nsError.code)")
            }
            throw OneDriveAdapterError.provider(code: "onedrive_download", retryable: true)
        }
    }

    private func page(url: URL, accessToken: String) async throws -> OneDrivePageRecord {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, rawResponse) = try await session.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else {
                throw OneDriveAdapterError.invalidResponse("onedrive_non_http")
            }
            try validate(response, data: data)
            return try OneDriveGraphCodec.decodePage(data)
        } catch let error as OneDriveAdapterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw OneDriveAdapterError.network("onedrive_url_\(nsError.code)")
            }
            throw OneDriveAdapterError.provider(code: "onedrive_graph", retryable: true)
        }
    }

    private func jsonData(
        url: URL,
        accessToken: String,
        failureCode: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, rawResponse) = try await session.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else {
                throw OneDriveAdapterError.invalidResponse("\(failureCode)_non_http")
            }
            try validate(response, data: data)
            return data
        } catch let error as OneDriveAdapterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw OneDriveAdapterError.network("onedrive_url_\(nsError.code)")
            }
            throw OneDriveAdapterError.provider(code: failureCode, retryable: true)
        }
    }

    private func validate(
        _ response: HTTPURLResponse,
        data: Data? = nil,
        isDownload: Bool = false
    ) throws {
        if let error = OneDriveGraphErrorMapper.map(
            response: response,
            data: data,
            isDownload: isDownload
        ) {
            throw error
        }
    }

    private static func boundedErrorData(at url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0, size <= 256 * 1_024 else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func install(_ temporaryURL: URL, at destination: URL) throws -> Int64 {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}

// MARK: - MSAL production adapter

#if canImport(MSAL)

@MainActor
private final class MSALOneDriveAuthSession {
    private static let scopes = ["Files.Read"]

    private struct PendingInteractiveAuthorization {
        let id: UInt64
        let continuation: CheckedContinuation<MSALResult, Error>
    }

    nonisolated(unsafe) private let application: MSALPublicClientApplication
    private let presenter: @MainActor @Sendable () -> UIViewController?
    private var currentAccount: MSALAccount?
    private var nextInteractiveAuthorizationID: UInt64 = 0
    private var pendingInteractiveAuthorization: PendingInteractiveAuthorization?
    private var acceptedInteractiveAccountIdentifiers = Set<String>()
    private var deferredOrphanAccounts: [MSALAccount] = []

    nonisolated init(
        clientID: String,
        authority: String,
        redirectURI: String?,
        presenter: @escaping @MainActor @Sendable () -> UIViewController?
    ) throws {
        let validatedClientID = try Self.validatedClientID(clientID)
        let authorityURL = try Self.validatedAuthorityURL(authority)
        let validatedRedirectURI = try Self.validatedRedirectURI(redirectURI)

        let aadAuthority: MSALAADAuthority
        do {
            aadAuthority = try MSALAADAuthority(url: authorityURL)
        } catch {
            throw CloudStorageError.invalidConfiguration(code: "onedrive_msal_configuration")
        }
        let configuration = MSALPublicClientApplicationConfig(
            clientId: validatedClientID,
            redirectUri: validatedRedirectURI,
            authority: aadAuthority
        )
        do {
            application = try MSALPublicClientApplication(configuration: configuration)
        } catch {
            throw CloudStorageError.invalidConfiguration(code: "onedrive_msal_configuration")
        }
        self.presenter = presenter
    }

    nonisolated private static func validatedClientID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else {
            throw CloudStorageError.invalidConfiguration(code: "onedrive_client_id")
        }
        return trimmed
    }

    nonisolated private static func validatedAuthorityURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            throw CloudStorageError.invalidConfiguration(code: "onedrive_authority")
        }
        return url
    }

    nonisolated private static func validatedRedirectURI(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.isEmpty == false,
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.url != nil else {
            throw CloudStorageError.invalidConfiguration(code: "onedrive_redirect_uri")
        }
        return trimmed
    }

    func restore(accountIdentifier: String?) async throws -> OneDriveAccountRecord? {
        guard let accountIdentifier else { return nil }
        let account: MSALAccount?
        do {
            account = try application.account(forIdentifier: accountIdentifier)
        } catch {
            throw map(error)
        }
        guard let account else { return nil }
        currentAccount = account
        _ = try await acquireSilent(account: account, forceRefresh: false)
        return record(from: account)
    }

    func authorize(selectAccount: Bool) async throws -> OneDriveAccountRecord {
        guard pendingInteractiveAuthorization == nil else {
            throw OneDriveAdapterError.provider(
                code: "onedrive_authorization_in_progress",
                retryable: true
            )
        }
        guard let controller = presenter() else {
            throw OneDriveAdapterError.provider(code: "onedrive_presenter_missing", retryable: true)
        }
        let web = MSALWebviewParameters(authPresentationViewController: controller)
        let parameters = MSALInteractiveTokenParameters(scopes: Self.scopes, webviewParameters: web)
        parameters.promptType = selectAccount ? .selectAccount : .default

        nextInteractiveAuthorizationID &+= 1
        let authorizationID = nextInteractiveAuthorizationID
        let protectedAccountIdentifier = currentAccount.flatMap(Self.cacheIdentifier(for:))
        let result: MSALResult
        do {
            result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingInteractiveAuthorization = PendingInteractiveAuthorization(
                        id: authorizationID,
                        continuation: continuation
                    )
                    application.acquireToken(with: parameters) { [weak self] result, error in
                        Task { @MainActor in
                            self?.finishInteractiveAuthorization(
                                id: authorizationID,
                                result: result,
                                error: error,
                                protectedAccountIdentifier: protectedAccountIdentifier
                            )
                        }
                    }
                }
            } onCancel: {
                _ = MSALPublicClientApplication.cancelCurrentWebAuthSession()
                Task { @MainActor [weak self] in
                    self?.cancelInteractiveAuthorization(id: authorizationID)
                }
            }
            if Task.isCancelled {
                if let identifier = Self.cacheIdentifier(for: result.account) {
                    acceptedInteractiveAccountIdentifiers.remove(identifier)
                }
                removeAccountIfUnprotected(
                    result.account,
                    protectedAccountIdentifier: protectedAccountIdentifier
                )
                throw CancellationError()
            }
        } catch {
            throw map(error)
        }
        // Keep the currently committed account pinned. The provider may be
        // staging this result for confirmation; it explicitly restores the
        // selected account only when committing/using it.
        return record(from: result.account)
    }

    private func cancelInteractiveAuthorization(id: UInt64) {
        guard let pending = pendingInteractiveAuthorization,
              pending.id == id else { return }
        pendingInteractiveAuthorization = nil
        pending.continuation.resume(throwing: CancellationError())
        cleanupDeferredOrphanAccounts()
    }

    private func finishInteractiveAuthorization(
        id: UInt64,
        result: MSALResult?,
        error: Error?,
        protectedAccountIdentifier: String?
    ) {
        guard let pending = pendingInteractiveAuthorization,
              pending.id == id else {
            if let result {
                // Do not remove a cache account while a newer interactive
                // attempt may be adopting the same account. Defer ownership
                // resolution until that attempt completes or is cancelled.
                if pendingInteractiveAuthorization != nil {
                    deferredOrphanAccounts.append(result.account)
                } else {
                    removeAccountIfUnprotected(
                        result.account,
                        protectedAccountIdentifier: protectedAccountIdentifier
                    )
                }
            }
            return
        }

        pendingInteractiveAuthorization = nil
        if let result {
            if let identifier = Self.cacheIdentifier(for: result.account) {
                acceptedInteractiveAccountIdentifiers.insert(identifier)
            }
            cleanupDeferredOrphanAccounts()
            pending.continuation.resume(returning: result)
        } else {
            cleanupDeferredOrphanAccounts()
            pending.continuation.resume(throwing: error
                ?? OneDriveAdapterError.invalidResponse("msal_empty_result"))
        }
    }

    private func removeAccountIfUnprotected(
        _ account: MSALAccount,
        protectedAccountIdentifier: String?
    ) {
        if let identifier = Self.cacheIdentifier(for: account),
           acceptedInteractiveAccountIdentifiers.contains(identifier) {
            return
        }
        if let currentAccount,
           let identifier = Self.cacheIdentifier(for: currentAccount),
           Self.matches(account, identifier: identifier) {
            return
        }
        if let protectedAccountIdentifier,
           Self.matches(account, identifier: protectedAccountIdentifier) {
            return
        }
        try? application.remove(account)
    }

    private func cleanupDeferredOrphanAccounts() {
        let accounts = deferredOrphanAccounts
        deferredOrphanAccounts.removeAll(keepingCapacity: true)
        for account in accounts {
            removeAccountIfUnprotected(account, protectedAccountIdentifier: nil)
        }
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let currentAccount else { throw OneDriveAdapterError.notConnected }
        return try await acquireSilent(account: currentAccount, forceRefresh: forceRefresh)
    }

    func signOut(accountIdentifier: String) throws {
        acceptedInteractiveAccountIdentifiers.remove(accountIdentifier)
        let accounts = try application.allAccounts()
        guard let account = accounts.first(where: {
            Self.matches($0, identifier: accountIdentifier)
        }) else { return }
        if let cacheIdentifier = Self.cacheIdentifier(for: account) {
            acceptedInteractiveAccountIdentifiers.remove(cacheIdentifier)
        }
        _ = try application.remove(account)
        if let currentAccount,
           Self.matches(currentAccount, identifier: accountIdentifier) {
            self.currentAccount = nil
        }
    }

    private func acquireSilent(account: MSALAccount, forceRefresh: Bool) async throws -> String {
        let parameters = MSALSilentTokenParameters(scopes: Self.scopes, account: account)
        parameters.forceRefresh = forceRefresh
        do {
            let result: MSALResult = try await withCheckedThrowingContinuation { continuation in
                application.acquireTokenSilent(with: parameters) { result, error in
                    if let result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: error ?? OneDriveAdapterError.invalidResponse("msal_empty_silent_result"))
                    }
                }
            }
            guard let requestedIdentifier = Self.cacheIdentifier(for: account),
                  Self.matches(result.account, identifier: requestedIdentifier) else {
                throw OneDriveAdapterError.invalidResponse(
                    "msal_silent_account_mismatch"
                )
            }
            // Silent refresh is request-scoped. It must not mutate the global
            // active MSAL account: a late refresh for retired A can complete
            // after the user has confirmed B.
            return result.accessToken
        } catch {
            throw map(error)
        }
    }

    private func record(from account: MSALAccount) -> OneDriveAccountRecord {
        let rawID = account.homeAccountId?.identifier
            ?? account.identifier
            ?? account.username
            ?? "unknown"
        let cacheID = account.identifier ?? account.homeAccountId?.identifier ?? rawID
        let displayName = account.accountClaims?["name"] as? String
        return OneDriveAccountRecord(
            rawAccountID: rawID,
            cacheAccountIdentifier: cacheID,
            displayName: displayName,
            email: account.username
        )
    }

    private static func cacheIdentifier(for account: MSALAccount) -> String? {
        account.identifier ?? account.homeAccountId?.identifier
    }

    private static func matches(_ account: MSALAccount, identifier: String) -> Bool {
        account.identifier == identifier || account.homeAccountId?.identifier == identifier
    }

    private func map(_ error: Error) -> OneDriveAdapterError {
        if let error = error as? OneDriveAdapterError { return error }
        if error is CancellationError { return .userCancelled }
        let nsError = error as NSError
        if nsError.domain == MSALErrorDomain {
            if nsError.code == MSALError.userCanceled.rawValue { return .userCancelled }
            if nsError.code == MSALError.interactionRequired.rawValue {
                return .needsReauthorization
            }
        }
        if nsError.domain == NSURLErrorDomain {
            return .network("msal_url_\(nsError.code)")
        }
        return .provider(code: "msal_\(nsError.code)", retryable: false)
    }
}

private actor MSALOneDriveAdapter: OneDriveProviderAdapter {
    private let auth: MSALOneDriveAuthSession
    private let graph: OneDriveGraphAPI

    init(auth: MSALOneDriveAuthSession, graph: OneDriveGraphAPI) {
        self.auth = auth
        self.graph = graph
    }

    func restoreAccount(accountIdentifier: String?) async throws -> OneDriveAccountRecord? {
        try await auth.restore(accountIdentifier: accountIdentifier)
    }

    func authorize(selectAccount: Bool) async throws -> OneDriveAccountRecord {
        try await auth.authorize(selectAccount: selectAccount)
    }

    func metadata(itemID: String, driveID: String?) async throws -> OneDriveItemRecord {
        try await withTokenRetry { token in
            try await graph.metadata(
                itemID: itemID,
                driveID: driveID,
                accessToken: token
            )
        }
    }

    func listDrives() async throws -> [OneDriveDriveRecord] {
        try await withTokenRetry { token in
            try await graph.listDrives(accessToken: token)
        }
    }

    func list(
        folderID: String?,
        driveID: String?,
        nextLink: String?
    ) async throws -> OneDrivePageRecord {
        try await withTokenRetry { token in
            try await graph.list(
                folderID: folderID,
                driveID: driveID,
                nextLink: nextLink,
                accessToken: token
            )
        }
    }

    func search(
        query: String,
        driveID: String?,
        nextLink: String?
    ) async throws -> OneDrivePageRecord {
        try await withTokenRetry { token in
            try await graph.search(
                query: query,
                driveID: driveID,
                nextLink: nextLink,
                accessToken: token
            )
        }
    }

    func download(
        itemID: String,
        driveID: String?,
        destination: URL,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> OneDriveTransferRecord {
        try await withTokenRetry { token in
            try await graph.download(
                itemID: itemID,
                driveID: driveID,
                accessToken: token,
                destination: destination,
                maximumBytes: maximumBytes,
                progress: progress
            )
        }
    }

    func signOut(accountIdentifier: String) async throws {
        try await auth.signOut(accountIdentifier: accountIdentifier)
    }

    private func withTokenRetry<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        let token = try await auth.accessToken(forceRefresh: false)
        do {
            return try await operation(token)
        } catch OneDriveAdapterError.needsReauthorization {
            let refreshed = try await auth.accessToken(forceRefresh: true)
            return try await operation(refreshed)
        }
    }
}

#endif
