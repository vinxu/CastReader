//
//  CloudStorageCenter.swift
//  CastReader
//
//  Main-actor registry for the three read-only cloud providers. Provider
//  actors own credentials and network work; this object only publishes safe
//  connection state for SwiftUI and routes user-initiated operations.
//

import Foundation
import UIKit

/// UIApplicationDelegate and SwiftUI's scene `onOpenURL` can both surface the
/// same OAuth callback. This short-lived, main-actor gate gives that callback a
/// single SDK owner without conflating distinct OAuth attempts (whose complete
/// URLs contain different state/code values).
@MainActor
final class CloudOAuthCallbackDeduplicator {
    private let retentionInterval: TimeInterval
    private var recentlyForwarded: [String: Date] = [:]

    init(retentionInterval: TimeInterval = 10) {
        self.retentionInterval = max(0, retentionInterval)
    }

    func shouldForward(_ url: URL, now: Date = Date()) -> Bool {
        recentlyForwarded = recentlyForwarded.filter { _, forwardedAt in
            let age = now.timeIntervalSince(forwardedAt)
            return age >= 0 && age < retentionInterval
        }
        let callbackIdentity = url.absoluteString
        guard recentlyForwarded[callbackIdentity] == nil else { return false }
        recentlyForwarded[callbackIdentity] = now
        return true
    }
}

/// Non-secret ownership marker for native cloud credentials.
///
/// Provider SDKs keep their actual tokens in Keychain/MSAL. This marker binds
/// that single device-local credential set to CastReader's opaque
/// `route x account` scope, so another signed-in identity can never silently
/// restore it. Missing markers are treated as legacy/unowned and fail closed.
struct CloudCredentialOwnershipStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "castreader.cloud.credential-owner.v1"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func ownerStorageID(for provider: CloudProviderID) -> String? {
        guard let value = defaults.string(forKey: key(for: provider)),
              Self.isOpaqueStorageID(value) else { return nil }
        return value
    }

    func setOwnerStorageID(
        _ storageID: String,
        for provider: CloudProviderID
    ) {
        guard Self.isOpaqueStorageID(storageID) else { return }
        defaults.set(storageID, forKey: key(for: provider))
    }

    func removeOwner(for provider: CloudProviderID) {
        defaults.removeObject(forKey: key(for: provider))
    }

    private func key(for provider: CloudProviderID) -> String {
        "\(keyPrefix).\(provider.rawValue)"
    }

    private static func isOpaqueStorageID(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

@MainActor
final class CloudStorageCenter: ObservableObject {
    static let shared = CloudStorageCenter()

    @Published private(set) var connectionStates: [CloudProviderID: CloudConnectionState] = [:]

    private let googleDrive: GoogleDriveProvider?
    private let dropbox: DropboxProvider?
    private let oneDrive: OneDriveProvider?
    private let credentialOwnership = CloudCredentialOwnershipStore()
    private var lifecycleEpochs: [CloudProviderID: UInt64] = [:]
    private var disconnectingProviders = Set<CloudProviderID>()
    private var activeAccountStorageID: String?

    private init() {
        if Constants.CloudStorage.GoogleDrive.isConfigured {
            googleDrive = GoogleDriveProvider.live(
                configuration: .init(
                    clientID: Constants.CloudStorage.GoogleDrive.clientID,
                    redirectURI: Constants.CloudStorage.GoogleDrive.redirectURI,
                    callbackScheme: Constants.CloudStorage.GoogleDrive.redirectScheme
                )
            )
        } else {
            googleDrive = nil
        }

        let presenter: @MainActor @Sendable () -> UIViewController? = {
            CloudPresentationContext.topViewController()
        }
        if Constants.CloudStorage.Dropbox.isConfigured {
            dropbox = DropboxProvider(
                appKey: Constants.CloudStorage.Dropbox.appKey,
                presenter: presenter
            )
        } else {
            dropbox = nil
        }
        if Constants.CloudStorage.Microsoft.isConfigured {
            oneDrive = try? OneDriveProvider(
                clientID: Constants.CloudStorage.Microsoft.clientID,
                authority: Constants.CloudStorage.Microsoft.authority,
                redirectURI: Constants.CloudStorage.Microsoft.redirectURI,
                presenter: presenter
            )
        } else {
            oneDrive = nil
        }

        for provider in CloudProviderID.allCases {
            connectionStates[provider] = .disconnected
        }
    }

    /// Opens the native-cloud gate for one CastReader account. Credentials
    /// owned by another route/account (or by an old unscoped build) are hidden
    /// synchronously, then removed locally before this account can connect.
    func activateAccountScope(storageID: String) {
        guard storageID.count == 64 else {
            deactivateAccountScope()
            return
        }
        guard activeAccountStorageID != storageID else { return }
        activeAccountStorageID = storageID

        for provider in CloudProviderID.allCases {
            connectionStates[provider] = .disconnected
            let lifecycleEpoch = beginLifecycleOperation(provider)
            if credentialOwnership.ownerStorageID(for: provider) == storageID {
                disconnectingProviders.remove(provider)
                continue
            }

            // Remove the owner marker before awaiting SDK cleanup. Every API
            // remains closed by `disconnectingProviders` during this window.
            credentialOwnership.removeOwner(for: provider)
            disconnectingProviders.insert(provider)
            Task { [weak self] in
                await self?.clearUnownedLocalAuthorization(
                    for: provider,
                    lifecycleEpoch: lifecycleEpoch
                )
            }
        }
    }

    /// Signed-out UI must not display or use a provider connection. The local
    /// token may remain dormant so signing back into the exact same CastReader
    /// account can resume it; a different scope will clear it on activation.
    func deactivateAccountScope() {
        activeAccountStorageID = nil
        disconnectingProviders.removeAll()
        for provider in CloudProviderID.allCases {
            _ = beginLifecycleOperation(provider)
            connectionStates[provider] = .disconnected
        }
        Task {
            for provider in CloudProviderID.allCases {
                _ = await CloudImportCoordinator.shared.cancel(provider: provider)
            }
        }
    }

    func isConfigured(_ provider: CloudProviderID) -> Bool {
        switch provider {
        case .googleDrive: return googleDrive != nil
        case .dropbox: return dropbox != nil
        case .oneDrive: return oneDrive != nil
        }
    }

    #if DEBUG
    func resetGoogleDriveLocalStateForDeviceTesting() async {
        _ = beginLifecycleOperation(.googleDrive)
        disconnectingProviders.remove(.googleDrive)
        credentialOwnership.removeOwner(for: .googleDrive)
        if let googleDrive {
            await googleDrive.resetLocalStateForDeviceTesting()
        }
        _ = await CloudConnectionStore.shared.removeActive(for: .googleDrive)
        CloudPrivacyAcknowledgementStore.reset(.googleDrive)
        connectionStates[.googleDrive] = .disconnected
    }
    #endif

    func state(for provider: CloudProviderID) -> CloudConnectionState {
        connectionStates[provider] ?? .disconnected
    }

    func refreshConnectionStates() async {
        guard activeAccountStorageID != nil else {
            for provider in CloudProviderID.allCases {
                connectionStates[provider] = .disconnected
            }
            return
        }

        if hasActiveCredentialOwnership(.googleDrive), let googleDrive {
            let epoch = lifecycleEpochs[.googleDrive, default: 0]
            let storeEpoch = await CloudConnectionStore.shared.connectionEpoch(
                for: .googleDrive
            )
            let providerState = await googleDrive.connectionState()
            let reconciled = await reconciledState(
                providerState,
                provider: .googleDrive,
                liveCandidate: await googleDrive.stagedCandidateAccount(),
                expectedStoreEpoch: storeEpoch
            )
            if isCurrentLifecycle(.googleDrive, epoch: epoch),
               !disconnectingProviders.contains(.googleDrive) {
                connectionStates[.googleDrive] = reconciled
            }
        } else {
            connectionStates[.googleDrive] = .disconnected
        }
        if hasActiveCredentialOwnership(.dropbox), let dropbox {
            let epoch = lifecycleEpochs[.dropbox, default: 0]
            let storeEpoch = await CloudConnectionStore.shared.connectionEpoch(for: .dropbox)
            let providerState = await restoredPersistentProviderState(
                provider: .dropbox,
                initialState: await dropbox.connectionState(),
                expectedStoreEpoch: storeEpoch
            )
            if isCurrentLifecycle(.dropbox, epoch: epoch),
               !disconnectingProviders.contains(.dropbox) {
                connectionStates[.dropbox] = providerState
            }
        } else {
            connectionStates[.dropbox] = .disconnected
        }
        if hasActiveCredentialOwnership(.oneDrive), let oneDrive {
            let epoch = lifecycleEpochs[.oneDrive, default: 0]
            let storeEpoch = await CloudConnectionStore.shared.connectionEpoch(for: .oneDrive)
            let providerState = await restoredPersistentProviderState(
                provider: .oneDrive,
                initialState: await oneDrive.connectionState(),
                expectedStoreEpoch: storeEpoch
            )
            if isCurrentLifecycle(.oneDrive, epoch: epoch),
               !disconnectingProviders.contains(.oneDrive) {
                connectionStates[.oneDrive] = providerState
            }
        } else {
            connectionStates[.oneDrive] = .disconnected
        }
    }

    func authorizeAndPickGoogleDrive(
        forceAccountSelection: Bool = false,
        expectedAccount: CloudAccount? = nil
    ) async throws -> CloudAtomicPickResult {
        guard let googleDrive else { throw configurationError(.googleDrive) }
        try ensureAccountScopeCanAuthorize(.googleDrive)
        guard !disconnectingProviders.contains(.googleDrive) else {
            throw CloudStorageError.staleSession
        }
        let lifecycleEpoch = beginLifecycleOperation(.googleDrive)
        let priorState = connectionStates[.googleDrive] ?? .disconnected
        connectionStates[.googleDrive] = .connecting
        do {
            let result = try await googleDrive.authorizeAndPickPreservingExistingAccount(
                forceAccountSelection: forceAccountSelection,
                expectedAccountKey: expectedAccount?.stableAccountKey
            )
            try ensureCurrentLifecycle(.googleDrive, epoch: lifecycleEpoch)
            if result.requiresAccountSwitchConfirmation {
                await CloudConnectionStore.shared.stageCandidate(result.account)
                try ensureCurrentLifecycle(.googleDrive, epoch: lifecycleEpoch)
                connectionStates[.googleDrive] = priorState
            } else {
                _ = await CloudConnectionStore.shared.setActive(result.account)
                try ensureCurrentLifecycle(.googleDrive, epoch: lifecycleEpoch)
                try bindCredentialsToActiveAccountScope(.googleDrive)
                connectionStates[.googleDrive] = .connected(result.account)
            }
            return result
        } catch {
            if isCurrentLifecycle(.googleDrive, epoch: lifecycleEpoch) {
                let recovered = await googleDrive.connectionState()
                if isCurrentLifecycle(.googleDrive, epoch: lifecycleEpoch),
                   hasActiveCredentialOwnership(.googleDrive),
                   !disconnectingProviders.contains(.googleDrive) {
                    connectionStates[.googleDrive] = recovered
                }
            }
            throw error
        }
    }

    func commitStagedGoogleDriveAccount() async throws -> (CloudAccount, CloudItem) {
        guard let googleDrive else { throw configurationError(.googleDrive) }
        try ensureActiveCredentialOwner(.googleDrive)
        guard !disconnectingProviders.contains(.googleDrive) else {
            throw CloudStorageError.staleSession
        }
        let lifecycleEpoch = beginLifecycleOperation(.googleDrive)
        connectionStates[.googleDrive] = .connecting
        do {
            let result = try await googleDrive.commitStagedAccount()
            try ensureCurrentLifecycle(.googleDrive, epoch: lifecycleEpoch)
            _ = await CloudConnectionStore.shared.setActive(result.account)
            try ensureCurrentLifecycle(.googleDrive, epoch: lifecycleEpoch)
            try bindCredentialsToActiveAccountScope(.googleDrive)
            connectionStates[.googleDrive] = .connected(result.account)
            return result
        } catch {
            if isCurrentLifecycle(.googleDrive, epoch: lifecycleEpoch) {
                await refreshState(for: .googleDrive)
            }
            throw error
        }
    }

    func discardStagedGoogleDriveAccount() async {
        guard hasActiveCredentialOwnership(.googleDrive) else { return }
        await googleDrive?.discardStagedAccount()
        await CloudConnectionStore.shared.discardCandidate(for: .googleDrive)
        await refreshState(for: .googleDrive)
    }

    func ensureConnected(
        _ provider: CloudProviderID,
        expectedAccount: CloudAccount? = nil,
        forceAccountSelection: Bool = false
    ) async throws -> CloudAccount {
        try ensureAccountScopeCanAuthorize(provider)
        guard !disconnectingProviders.contains(provider) else {
            throw CloudStorageError.staleSession
        }
        let lifecycleEpoch = beginLifecycleOperation(provider)
        let storeEpoch = await CloudConnectionStore.shared.connectionEpoch(for: provider)
        let recoveredState = await restoredPersistentProviderState(
            provider: provider,
            initialState: await rawProviderState(for: provider),
            expectedStoreEpoch: storeEpoch
        )
        try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
        connectionStates[provider] = recoveredState
        let protectedAccount: CloudAccount?
        if let expectedAccount {
            protectedAccount = expectedAccount
        } else {
            protectedAccount = await CloudConnectionStore.shared.activeAccount(for: provider)
        }
        try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
        connectionStates[provider] = .connecting
        do {
            let account: CloudAccount
            switch provider {
            case .googleDrive:
                guard let googleDrive else { throw configurationError(provider) }
                account = try await googleDrive.ensureConnected(
                    expectedAccountKey: protectedAccount?.stableAccountKey,
                    forceAccountSelection: forceAccountSelection
                )
            case .dropbox:
                guard let dropbox else { throw configurationError(provider) }
                account = try await dropbox.ensureConnected(
                    expectedAccountKey: protectedAccount?.stableAccountKey,
                    forceAccountSelection: forceAccountSelection
                )
            case .oneDrive:
                guard let oneDrive else { throw configurationError(provider) }
                account = try await oneDrive.ensureConnected(
                    expectedAccountKey: protectedAccount?.stableAccountKey,
                    forceAccountSelection: forceAccountSelection
                )
            }
            try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
            _ = await CloudConnectionStore.shared.setActive(account)
            try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
            try bindCredentialsToActiveAccountScope(provider)
            connectionStates[provider] = .connected(account)
            return account
        } catch {
            if isCurrentLifecycle(provider, epoch: lifecycleEpoch),
               error as? CloudStorageError == .accountMismatch,
               let candidate = await stagedCandidateAccount(for: provider) {
                await CloudConnectionStore.shared.stageCandidate(candidate)
                connectionStates[provider] = .needsReauthorization(protectedAccount)
                throw error
            }
            if isCurrentLifecycle(provider, epoch: lifecycleEpoch) {
                await refreshState(for: provider)
            }
            throw error
        }
    }

    /// Restores a cached provider account without ever presenting OAuth. This
    /// is the only account path available to History reopen validation.
    func restorePersistedAccount(
        _ provider: CloudProviderID,
        expectedAccountKey: String
    ) async throws -> CloudAccount {
        try ensureActiveCredentialOwner(provider)
        guard !disconnectingProviders.contains(provider) else {
            throw CloudStorageError.staleSession
        }
        let lifecycleEpoch = beginLifecycleOperation(provider)
        let storeEpoch = await CloudConnectionStore.shared.connectionEpoch(for: provider)
        let recoveredState = await restoredPersistentProviderState(
            provider: provider,
            initialState: await rawProviderState(for: provider),
            expectedStoreEpoch: storeEpoch
        )
        try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
        if case .connected(let recovered) = recoveredState {
            guard recovered.stableAccountKey == expectedAccountKey else {
                throw CloudStorageError.accountMismatch
            }
            connectionStates[provider] = .connected(recovered)
            return recovered
        }
        let account: CloudAccount
        switch provider {
        case .googleDrive:
            guard let googleDrive else { throw configurationError(provider) }
            account = try await googleDrive.restorePersistedAccount(
                expectedAccountKey: expectedAccountKey
            )
        case .dropbox:
            guard let dropbox else { throw configurationError(provider) }
            account = try await dropbox.restorePersistedAccount(
                expectedAccountKey: expectedAccountKey
            )
        case .oneDrive:
            guard let oneDrive else { throw configurationError(provider) }
            account = try await oneDrive.restorePersistedAccount(
                expectedAccountKey: expectedAccountKey
            )
        }
        try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
        _ = await CloudConnectionStore.shared.setActive(account)
        try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
        connectionStates[provider] = .connected(account)
        return account
    }

    func stagedCandidateAccount(for provider: CloudProviderID) async -> CloudAccount? {
        guard hasActiveCredentialOwnership(provider) else { return nil }
        switch provider {
        case .googleDrive:
            return await googleDrive?.stagedCandidateAccount()
        case .dropbox:
            return await dropbox?.stagedCandidate()
        case .oneDrive:
            return await oneDrive?.stagedCandidate()
        }
    }

    /// Authorizes a candidate account while preserving the current account as
    /// active. The caller must explicitly commit or discard the candidate.
    func stageAnotherAccount(_ provider: CloudProviderID) async throws -> CloudAccount {
        try ensureActiveCredentialOwner(provider)
        guard !disconnectingProviders.contains(provider) else {
            throw CloudStorageError.staleSession
        }
        let lifecycleEpoch = beginLifecycleOperation(provider)
        let priorState = connectionStates[provider] ?? .disconnected
        connectionStates[provider] = .connecting
        do {
            let candidate: CloudAccount
            switch provider {
            case .googleDrive:
                guard let googleDrive else { throw configurationError(provider) }
                candidate = try await googleDrive.stageAnotherAccount()
            case .dropbox:
                guard let dropbox else { throw configurationError(provider) }
                candidate = try await dropbox.stageAnotherAccount()
            case .oneDrive:
                guard let oneDrive else { throw configurationError(provider) }
                candidate = try await oneDrive.stageAnotherAccount()
            }
            try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
            await CloudConnectionStore.shared.stageCandidate(candidate)
            try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
            // Staging never changes the active association shown elsewhere in
            // the app. Keep A visible until the user confirms A → B.
            connectionStates[provider] = priorState
            return candidate
        } catch {
            if isCurrentLifecycle(provider, epoch: lifecycleEpoch) {
                await refreshState(for: provider)
            }
            throw error
        }
    }

    func commitStagedAccount(_ provider: CloudProviderID) async throws -> CloudAccount {
        try ensureActiveCredentialOwner(provider)
        guard !disconnectingProviders.contains(provider) else {
            throw CloudStorageError.staleSession
        }
        let lifecycleEpoch = beginLifecycleOperation(provider)
        connectionStates[provider] = .connecting
        do {
            let account: CloudAccount
            switch provider {
            case .googleDrive:
                guard let googleDrive else { throw configurationError(provider) }
                account = try await googleDrive.commitCandidate()
            case .dropbox:
                guard let dropbox else { throw configurationError(provider) }
                account = try await dropbox.commitCandidate()
            case .oneDrive:
                guard let oneDrive else { throw configurationError(provider) }
                account = try await oneDrive.commitCandidate()
            }
            try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
            _ = await CloudConnectionStore.shared.setActive(account)
            try ensureCurrentLifecycle(provider, epoch: lifecycleEpoch)
            try bindCredentialsToActiveAccountScope(provider)
            connectionStates[provider] = .connected(account)
            return account
        } catch {
            if isCurrentLifecycle(provider, epoch: lifecycleEpoch) {
                await refreshState(for: provider)
            }
            throw error
        }
    }

    func discardStagedAccount(_ provider: CloudProviderID) async {
        guard hasActiveCredentialOwnership(provider) else { return }
        switch provider {
        case .googleDrive:
            await googleDrive?.discardCandidate()
        case .dropbox:
            await dropbox?.discardCandidate()
        case .oneDrive:
            await oneDrive?.discardCandidate()
        }
        await CloudConnectionStore.shared.discardCandidate(for: provider)
        await refreshState(for: provider)
    }

    func list(
        provider: CloudProviderID,
        folder: CloudFolder?,
        cursor: CloudCursor?
    ) async throws -> CloudPage {
        try ensureActiveCredentialOwner(provider)
        switch provider {
        case .googleDrive:
            guard let googleDrive else { throw configurationError(provider) }
            return try await googleDrive.list(folder: folder, cursor: cursor)
        case .dropbox:
            guard let dropbox else { throw configurationError(provider) }
            return try await dropbox.list(folder: folder, cursor: cursor)
        case .oneDrive:
            guard let oneDrive else { throw configurationError(provider) }
            return try await oneDrive.list(folder: folder, cursor: cursor)
        }
    }

    func listDrives(provider: CloudProviderID) async throws -> [CloudDrive] {
        try ensureActiveCredentialOwner(provider)
        switch provider {
        case .googleDrive:
            guard let googleDrive else { throw configurationError(provider) }
            return try await googleDrive.listDrives()
        case .oneDrive:
            guard let oneDrive else { throw configurationError(provider) }
            return try await oneDrive.listDrives()
        case .dropbox:
            return []
        }
    }

    func search(
        provider: CloudProviderID,
        query: String,
        driveID: String? = nil,
        cursor: CloudCursor?
    ) async throws -> CloudPage {
        try ensureActiveCredentialOwner(provider)
        switch provider {
        case .googleDrive:
            guard let googleDrive else { throw configurationError(provider) }
            return try await googleDrive.search(
                query,
                driveID: driveID,
                cursor: cursor
            )
        case .dropbox:
            guard let dropbox else { throw configurationError(provider) }
            return try await dropbox.search(query, cursor: cursor)
        case .oneDrive:
            guard let oneDrive else { throw configurationError(provider) }
            return try await oneDrive.search(
                query,
                driveID: driveID,
                cursor: cursor
            )
        }
    }

    func download(
        provider: CloudProviderID,
        item: CloudItem,
        exportFormat: CloudExportFormat?,
        destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt {
        try ensureActiveCredentialOwner(provider)
        let destinationAllowed = CloudDownloadDestinationPolicy.allows(destination)
        #if DEBUG
        print(
            "CloudStorageCenter provider=\(provider.rawValue) event=download_begin "
                + "isFileURL=\(destination.isFileURL) "
                + "destinationAllowed=\(destinationAllowed)"
        )
        #endif
        guard destinationAllowed else {
            throw CloudStorageError.downloadNotAllowed
        }
        // `item` may come from an old list page or History and can be stale
        // after a same-ID rename, format conversion, or size change. Each
        // provider refreshes authoritative metadata before applying its format
        // cap and disk-capacity preflight.
        let receipt: CloudDownloadReceipt
        switch provider {
        case .googleDrive:
            guard let googleDrive else { throw configurationError(provider) }
            receipt = try await googleDrive.download(
                item,
                exportFormat: exportFormat,
                to: destination,
                progress: progress
            )
        case .dropbox:
            guard let dropbox else { throw configurationError(provider) }
            receipt = try await dropbox.download(
                item,
                exportFormat: exportFormat,
                to: destination,
                progress: progress
            )
        case .oneDrive:
            guard let oneDrive else { throw configurationError(provider) }
            receipt = try await oneDrive.download(
                item,
                exportFormat: exportFormat,
                to: destination,
                progress: progress
            )
        }
        try CloudTemporaryFileSecurity.secureFile(at: receipt.localURL)
        return receipt
    }

    func disconnect(_ provider: CloudProviderID) async -> CloudDisconnectResult {
        guard !disconnectingProviders.contains(provider) else {
            return CloudDisconnectResult(
                provider: provider,
                remoteRevocationStatus: .unconfirmed,
                retryable: true,
                diagnosticCode: "disconnect_in_progress"
            )
        }
        disconnectingProviders.insert(provider)
        let lifecycleEpoch = beginLifecycleOperation(provider)
        connectionStates[provider] = .disconnected
        _ = await CloudImportCoordinator.shared.cancel(provider: provider)
        _ = await CloudConnectionStore.shared.removeActive(for: provider)
        credentialOwnership.removeOwner(for: provider)

        let result: CloudDisconnectResult
        switch provider {
        case .googleDrive:
            result = await googleDrive?.disconnect()
                ?? CloudDisconnectResult(provider: provider, remoteRevocationStatus: .unsupported)
        case .dropbox:
            result = await dropbox?.disconnect()
                ?? CloudDisconnectResult(provider: provider, remoteRevocationStatus: .unsupported)
        case .oneDrive:
            result = await oneDrive?.disconnect()
                ?? CloudDisconnectResult(provider: provider, remoteRevocationStatus: .unsupported)
        }
        if isCurrentLifecycle(provider, epoch: lifecycleEpoch) {
            connectionStates[provider] = .disconnected
        }
        disconnectingProviders.remove(provider)
        return result
    }

    /// Google can retry provider-side token revocation after the device-local
    /// association has already been removed. No equivalent operation is
    /// advertised for SDKs whose retry credential was deleted by their own
    /// local sign-out semantics.
    func retryPendingRemoteRevocation(
        for provider: CloudProviderID
    ) async -> CloudDisconnectResult {
        guard provider == .googleDrive, let googleDrive else {
            return CloudDisconnectResult(
                provider: provider,
                remoteRevocationStatus: .unsupported
            )
        }
        return await googleDrive.retryPendingRevocations()
    }

    private func refreshState(for provider: CloudProviderID) async {
        guard hasActiveCredentialOwnership(provider) else {
            connectionStates[provider] = .disconnected
            return
        }
        // Recovery paths can outlive the operation that started them. Publish
        // only if no disconnect or newer account lifecycle won while the
        // provider and durable connection actors were being awaited.
        let lifecycleEpoch = lifecycleEpochs[provider, default: 0]
        let refreshedState: CloudConnectionState
        switch provider {
        case .googleDrive:
            let storeEpoch = await CloudConnectionStore.shared.connectionEpoch(
                for: provider
            )
            let state = await googleDrive?.connectionState() ?? .disconnected
            refreshedState = await reconciledState(
                state,
                provider: provider,
                liveCandidate: await googleDrive?.stagedCandidateAccount(),
                expectedStoreEpoch: storeEpoch
            )
        case .dropbox, .oneDrive:
            let storeEpoch = await CloudConnectionStore.shared.connectionEpoch(for: provider)
            refreshedState = await restoredPersistentProviderState(
                provider: provider,
                initialState: await rawProviderState(for: provider),
                expectedStoreEpoch: storeEpoch
            )
        }
        guard isCurrentLifecycle(provider, epoch: lifecycleEpoch),
              !disconnectingProviders.contains(provider) else { return }
        connectionStates[provider] = refreshedState
    }

    private func rawProviderState(for provider: CloudProviderID) async -> CloudConnectionState {
        switch provider {
        case .googleDrive:
            return await googleDrive?.connectionState() ?? .disconnected
        case .dropbox:
            return await dropbox?.connectionState() ?? .disconnected
        case .oneDrive:
            return await oneDrive?.connectionState() ?? .disconnected
        }
    }

    /// Restores SDK credentials without interaction and resolves a possible
    /// crash between the provider-side commit and CloudConnectionStore commit.
    private func restoredPersistentProviderState(
        provider: CloudProviderID,
        initialState: CloudConnectionState,
        expectedStoreEpoch: UInt64
    ) async -> CloudConnectionState {
        let account: CloudAccount
        do {
            switch initialState {
            case .connected(let connected):
                account = connected
            case .connecting:
                return initialState
            case .disconnected, .needsReauthorization:
                switch provider {
                case .dropbox:
                    guard let dropbox else { return .disconnected }
                    account = try await dropbox.restorePersistedAccount()
                case .oneDrive:
                    guard let oneDrive else { return .disconnected }
                    account = try await oneDrive.restorePersistedAccount()
                case .googleDrive:
                    return initialState
                }
            }
        } catch {
            let known = await CloudConnectionStore.shared.activeAccount(for: provider)
            return .needsReauthorization(known)
        }

        let liveCandidate = await stagedCandidateAccount(for: provider)
        guard let reconciled = await CloudConnectionStore.shared.reconcileObservedActiveAccount(
            account,
            preserveLiveCandidate: liveCandidate != nil,
            expectedEpoch: expectedStoreEpoch
        ) else {
            return .needsReauthorization(
                await CloudConnectionStore.shared.activeAccount(for: provider)
            )
        }
        return .connected(reconciled)
    }

    private func reconciledState(
        _ providerState: CloudConnectionState,
        provider: CloudProviderID,
        liveCandidate: CloudAccount?,
        expectedStoreEpoch: UInt64
    ) async -> CloudConnectionState {
        guard case .connected(let account) = providerState else {
            if case .disconnected = providerState,
               let persisted = await CloudConnectionStore.shared.activeAccount(for: provider) {
                return .needsReauthorization(persisted)
            }
            return providerState
        }
        guard let reconciled = await CloudConnectionStore.shared.reconcileObservedActiveAccount(
            account,
            preserveLiveCandidate: liveCandidate != nil,
            expectedEpoch: expectedStoreEpoch
        ) else {
            return .needsReauthorization(
                await CloudConnectionStore.shared.activeAccount(for: provider)
            )
        }
        return .connected(reconciled)
    }

    private func clearUnownedLocalAuthorization(
        for provider: CloudProviderID,
        lifecycleEpoch: UInt64
    ) async {
        _ = await CloudImportCoordinator.shared.cancel(provider: provider)
        _ = await CloudConnectionStore.shared.removeActive(for: provider)
        switch provider {
        case .googleDrive:
            await googleDrive?.clearLocalAuthorizationForAccountBoundary()
        case .dropbox:
            await dropbox?.clearLocalAuthorizationForAccountBoundary()
        case .oneDrive:
            await oneDrive?.clearLocalAuthorizationForAccountBoundary()
        }

        guard isCurrentLifecycle(provider, epoch: lifecycleEpoch),
              activeAccountStorageID != nil else { return }
        disconnectingProviders.remove(provider)
        connectionStates[provider] = .disconnected
    }

    /// Explicit connect/authorize is allowed when this account has no owner
    /// marker yet, but never while signed out or while another account's local
    /// credential is still being erased.
    private func ensureAccountScopeCanAuthorize(
        _ provider: CloudProviderID
    ) throws {
        guard let activeAccountStorageID,
              !disconnectingProviders.contains(provider) else {
            throw CloudStorageError.staleSession
        }
        if let owner = credentialOwnership.ownerStorageID(for: provider),
           owner != activeAccountStorageID {
            throw CloudStorageError.staleSession
        }
    }

    private func hasActiveCredentialOwnership(
        _ provider: CloudProviderID
    ) -> Bool {
        guard let activeAccountStorageID,
              !disconnectingProviders.contains(provider) else { return false }
        return credentialOwnership.ownerStorageID(for: provider)
            == activeAccountStorageID
    }

    /// Silent restore/list/search/download paths require an exact owner match;
    /// an unowned SDK token can never bootstrap itself into the new account.
    private func ensureActiveCredentialOwner(
        _ provider: CloudProviderID
    ) throws {
        try ensureAccountScopeCanAuthorize(provider)
        guard let activeAccountStorageID,
              credentialOwnership.ownerStorageID(for: provider)
                == activeAccountStorageID else {
            throw CloudStorageError.notConnected
        }
    }

    private func bindCredentialsToActiveAccountScope(
        _ provider: CloudProviderID
    ) throws {
        guard let activeAccountStorageID,
              !disconnectingProviders.contains(provider) else {
            throw CloudStorageError.staleSession
        }
        credentialOwnership.setOwnerStorageID(
            activeAccountStorageID,
            for: provider
        )
    }

    private func configurationError(_ provider: CloudProviderID) -> CloudStorageError {
        .invalidConfiguration(code: "\(provider.rawValue)_not_configured")
    }

    @discardableResult
    private func beginLifecycleOperation(_ provider: CloudProviderID) -> UInt64 {
        let next = lifecycleEpochs[provider, default: 0] &+ 1
        lifecycleEpochs[provider] = next
        return next
    }

    private func isCurrentLifecycle(_ provider: CloudProviderID, epoch: UInt64) -> Bool {
        lifecycleEpochs[provider, default: 0] == epoch
    }

    private func ensureCurrentLifecycle(
        _ provider: CloudProviderID,
        epoch: UInt64
    ) throws {
        guard isCurrentLifecycle(provider, epoch: epoch),
              !disconnectingProviders.contains(provider) else {
            throw CloudStorageError.staleSession
        }
    }

    /// Dropbox and MSAL normally use app URL callbacks. Google normally returns
    /// through ASWebAuthenticationSession, but the mobile Picker can open a new
    /// default-browser tab whose custom-scheme redirect reaches the app instead.
    static func isOAuthRedirectURL(_ url: URL) -> Bool {
        GoogleDriveSystemWebAuthenticator.matches(
            url,
            callbackScheme: Constants.CloudStorage.GoogleDrive.redirectScheme
        )
            || url.scheme == Constants.CloudStorage.Dropbox.callbackScheme
            || url.scheme == URL(string: Constants.CloudStorage.Microsoft.redirectURI)?.scheme
    }

    private static let oauthCallbackDeduplicator = CloudOAuthCallbackDeduplicator()

    /// The app delegate and SwiftUI scene both call this entry point. A duplicate
    /// is reported as consumed, but only the first delivery reaches Dropbox or
    /// MSAL. `sourceApplication` is optional because scene callbacks do not
    /// provide it and both SDKs support that path.
    static func handleOAuthRedirect(
        _ url: URL,
        sourceApplication: String? = nil
    ) -> Bool {
        guard isOAuthRedirectURL(url) else { return false }
        guard oauthCallbackDeduplicator.shouldForward(url) else { return true }
        if GoogleDriveSystemWebAuthenticator.matches(
            url,
            callbackScheme: Constants.CloudStorage.GoogleDrive.redirectScheme
        ) {
            // Treat a recognized but late callback as consumed. The
            // authenticator itself only resumes the currently active attempt;
            // provider-level route/state checks run before any token exchange.
            _ = GoogleDriveSystemWebAuthenticator.handleRedirectURL(url)
            return true
        }
        if url.scheme == Constants.CloudStorage.Dropbox.callbackScheme {
            return DropboxProvider.handleRedirectURL(url)
        }
        if url.scheme == URL(string: Constants.CloudStorage.Microsoft.redirectURI)?.scheme {
            return OneDriveProvider.handleRedirectURL(
                url,
                sourceApplication: sourceApplication
            )
        }
        return false
    }
}

enum CloudPrivacyAcknowledgementStore {
    // Version 2 explicitly discloses that TTS/QuickRead may receive the full
    // selected text plus retention/region/deletion details. Existing version
    // 1 acknowledgements must not suppress this materially expanded notice.
    private static let disclosureVersion = 2

    static func hasAcknowledged(_ provider: CloudProviderID, defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: key(provider)) >= disclosureVersion
    }

    static func acknowledge(_ provider: CloudProviderID, defaults: UserDefaults = .standard) {
        defaults.set(disclosureVersion, forKey: key(provider))
    }

    #if DEBUG
    static func reset(_ provider: CloudProviderID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(provider))
    }
    #endif

    private static func key(_ provider: CloudProviderID) -> String {
        "cloud.privacy.\(provider.rawValue).version"
    }
}

/// A process crash can bypass per-attempt `defer` cleanup. On the next cold
/// launch remove only CastReader's two explicit cloud-import roots; never scan
/// or delete the system temporary directory broadly.
enum CloudTemporaryFileJanitor {
    private static let directoryNames = [
        "CastReaderCloudImports",
        "CastReaderCloudHistoryReopen",
    ]

    static func removeAbandonedImports(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        guard temporaryRoot.isFileURL else { return }
        for name in directoryNames {
            let directory = temporaryRoot.appendingPathComponent(name, isDirectory: true)
            try? fileManager.removeItem(at: directory)
        }
    }
}

/// Defense in depth for provider bytes while they briefly exist on-device.
/// The directory/file remain outside backups and receive iOS Data Protection;
/// callers still remove them immediately after parsing.
enum CloudTemporaryFileSecurity {
    private static let minimumFreeSpaceAfterDownload: Int64 = 64 * 1_024 * 1_024

    static func preflightDiskCapacity(
        expectedBytes: Int64,
        near destination: URL
    ) throws {
        guard expectedBytes >= 0 else { return }
        let probe = destination.deletingLastPathComponent()
        let existingProbe = FileManager.default.fileExists(atPath: probe.path)
            ? probe
            : FileManager.default.temporaryDirectory
        guard let available = try? existingProbe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else {
            // Capacity reporting is advisory. A provider write will still fail
            // safely if the platform cannot report it on a particular volume.
            return
        }
        try requireCapacity(expectedBytes: expectedBytes, availableBytes: available)
    }

    static func requireCapacity(
        expectedBytes: Int64,
        availableBytes: Int64
    ) throws {
        guard availableBytes >= expectedBytes + minimumFreeSpaceAfterDownload else {
            throw DocumentImportError.resourceLimitExceeded(.insufficientDeviceStorage)
        }
    }

    static func prepareDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try excludeFromBackup(directory)
        try applyDataProtection(directory, fileManager: fileManager)
    }

    static func secureFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        let exists = fileManager.fileExists(atPath: url.path)
        #if DEBUG
        print(
            "CloudTemporaryFileSecurity event=secure_file "
                + "isFileURL=\(url.isFileURL) exists=\(exists)"
        )
        #endif
        guard url.isFileURL, exists else {
            throw CloudStorageError.invalidResponse(
                code: "cloud_download_missing_local_file"
            )
        }
        try excludeFromBackup(url)
        try applyDataProtection(url, fileManager: fileManager)
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private static func applyDataProtection(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

@MainActor
enum CloudPresentationContext {
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let root = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return descend(from: root)
    }

    private static func descend(from controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if let presented = controller.presentedViewController {
            return descend(from: presented)
        }
        if let navigation = controller as? UINavigationController {
            return descend(from: navigation.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return descend(from: tab.selectedViewController)
        }
        return controller
    }
}
