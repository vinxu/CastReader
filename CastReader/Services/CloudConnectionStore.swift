//
//  CloudConnectionStore.swift
//  CastReader
//
//  Persists only non-secret active/candidate account associations. Provider
//  refresh/access tokens remain in Keychain or the official SDK token cache.
//

import Foundation

actor CloudConnectionStore {
    static let shared = CloudConnectionStore()

    private struct PersistedAccount: Codable {
        let providerRawValue: String
        let stableAccountKey: String
        let displayName: String?
        let maskedEmail: String?

        init(_ account: CloudAccount) {
            providerRawValue = account.provider.rawValue
            stableAccountKey = account.stableAccountKey
            displayName = account.displayName
            maskedEmail = account.maskedEmail
        }

        var account: CloudAccount? {
            guard let provider = CloudProviderID(rawValue: providerRawValue),
                  !stableAccountKey.isEmpty else { return nil }
            return CloudAccount(
                provider: provider,
                stableAccountKey: stableAccountKey,
                displayName: displayName,
                maskedEmail: maskedEmail
            )
        }
    }

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var activeAccounts: [PersistedAccount]
        var candidateAccounts: [PersistedAccount]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var activeAccounts: [CloudProviderID: CloudAccount] = [:]
    private var candidateAccounts: [CloudProviderID: CloudAccount] = [:]

    /// Process-local generation used to reject work started before account
    /// replacement or disconnect. It intentionally need not survive relaunch.
    private var epochs: [CloudProviderID: UInt64] = [:]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "castreader.cloud.connections.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        guard let data = defaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        for value in state.activeAccounts.compactMap(\.account) {
            activeAccounts[value.provider] = value
        }
        for value in state.candidateAccounts.compactMap(\.account) {
            candidateAccounts[value.provider] = value
        }
    }

    func activeAccount(for provider: CloudProviderID) -> CloudAccount? {
        activeAccounts[provider]
    }

    func candidateAccount(for provider: CloudProviderID) -> CloudAccount? {
        candidateAccounts[provider]
    }

    func allActiveAccounts() -> [CloudAccount] {
        CloudProviderID.allCases.compactMap { activeAccounts[$0] }
    }

    func connectionEpoch(for provider: CloudProviderID) -> UInt64 {
        epochs[provider, default: 0]
    }

    func isCurrent(
        provider: CloudProviderID,
        accountKey: String,
        epoch: UInt64
    ) -> Bool {
        activeAccounts[provider]?.stableAccountKey == accountKey
            && epochs[provider, default: 0] == epoch
    }

    /// Used for Google after an atomic authorize-and-pick, and for a provider's
    /// first account connection. Calling it also invalidates earlier work for
    /// that provider, even when the stable account did not change, because the
    /// authorization generation may have changed.
    @discardableResult
    func setActive(_ account: CloudAccount) -> UInt64 {
        activeAccounts[account.provider] = account
        candidateAccounts[account.provider] = nil
        let epoch = advanceEpoch(for: account.provider)
        persist()
        return epoch
    }

    /// Account switching is two-phase: keep the old active account usable
    /// while the newly authorized account waits for explicit confirmation.
    func stageCandidate(_ account: CloudAccount) {
        candidateAccounts[account.provider] = account
        persist()
    }

    @discardableResult
    func commitCandidate(for provider: CloudProviderID) -> CloudAccount? {
        guard let candidate = candidateAccounts.removeValue(forKey: provider) else {
            return nil
        }
        activeAccounts[provider] = candidate
        _ = advanceEpoch(for: provider)
        persist()
        return candidate
    }

    func discardCandidate(for provider: CloudProviderID) {
        guard candidateAccounts.removeValue(forKey: provider) != nil else { return }
        persist()
    }

    /// Reconciles the provider SDK's durable active account with the app's
    /// two-phase switch record after a process death.
    ///
    /// The provider credential/cache is written before `setActive` is called.
    /// Therefore a crash after the provider commit leaves A as `active` and B
    /// as `candidate` here, while the provider reports B. Matching B commits
    /// the pending transaction. If the provider still reports A, the switch
    /// was never durably committed; a cold-start reconciliation may discard
    /// the orphan candidate. A live confirmation sheet passes
    /// `preserveLiveCandidate = true` so a normal refresh cannot cancel it.
    @discardableResult
    func reconcileObservedActiveAccount(
        _ observed: CloudAccount,
        preserveLiveCandidate: Bool,
        expectedEpoch: UInt64
    ) -> CloudAccount? {
        let provider = observed.provider
        guard epochs[provider, default: 0] == expectedEpoch else { return nil }

        if candidateAccounts[provider]?.stableAccountKey == observed.stableAccountKey {
            activeAccounts[provider] = observed
            candidateAccounts[provider] = nil
            _ = advanceEpoch(for: provider)
            persist()
            return observed
        }

        if activeAccounts[provider]?.stableAccountKey == observed.stableAccountKey {
            // Refresh non-secret display metadata from the authoritative SDK.
            activeAccounts[provider] = observed
            if !preserveLiveCandidate {
                candidateAccounts[provider] = nil
            }
            persist()
            return observed
        }

        // Supports upgrades from builds that persisted provider credentials
        // before CloudConnectionStore existed, without allowing an unexplained
        // A -> B replacement when an app-level association is already present.
        if activeAccounts[provider] == nil,
           candidateAccounts[provider] == nil {
            activeAccounts[provider] = observed
            _ = advanceEpoch(for: provider)
            persist()
            return observed
        }

        return nil
    }

    /// Removes device-local association immediately and advances the epoch so
    /// in-flight list/download/auth callbacks can no longer commit state.
    @discardableResult
    func removeActive(for provider: CloudProviderID) -> CloudAccount? {
        let removed = activeAccounts.removeValue(forKey: provider)
        candidateAccounts[provider] = nil
        _ = advanceEpoch(for: provider)
        persist()
        return removed
    }

    private func advanceEpoch(for provider: CloudProviderID) -> UInt64 {
        let next = epochs[provider, default: 0] &+ 1
        epochs[provider] = next
        return next
    }

    private func persist() {
        let state = PersistedState(
            schemaVersion: 1,
            activeAccounts: CloudProviderID.allCases.compactMap {
                activeAccounts[$0].map(PersistedAccount.init)
            },
            candidateAccounts: CloudProviderID.allCases.compactMap {
                candidateAccounts[$0].map(PersistedAccount.init)
            }
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
