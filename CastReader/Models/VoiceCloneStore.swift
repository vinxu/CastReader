import Foundation
import Combine

@MainActor
final class VoiceCloneStore: ObservableObject {
    static let shared = VoiceCloneStore()

    @Published private(set) var voices: [ClonedVoice] = []
    @Published private(set) var nextCreateAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var isCreating = false
    @Published private(set) var uploadProgress: Double = 0
    @Published private(set) var deletingVoiceId: String?
    @Published private(set) var renamingVoiceId: String?
    @Published private(set) var capability: VoiceCloneCapability = .unknown
    @Published private(set) var lastCreatedVoiceID: String?
    @Published private(set) var refreshErrorMessage: String?
    @Published var errorMessage: String?

    private let service: any VoiceCloneStoreServicing
    private let defaults: UserDefaults
    private let isSignedIn: @MainActor () -> Bool
    private var labels: [String: String] = [:]
    private var referenceLanguages: [String: String] = [:]
    private var cachedIdentities: [String: VoiceCloneIdentity] = [:]
    private var activeStorageID: String?
    private var accountGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var activeCreateRequestID: UUID?
    private var activeDeleteRequestID: UUID?
    private var activeRenameRequests: [String: UUID] = [:]
    private var reconciliationTask: Task<Void, Never>?
    private var authoritativeCreatedVoices: [String: ClonedVoice] = [:]

    init(
        service: any VoiceCloneStoreServicing = VoiceCloneService.shared,
        defaults: UserDefaults = .standard,
        isSignedIn: @escaping @MainActor () -> Bool = { AuthService.shared.isSignedIn }
    ) {
        self.service = service
        self.defaults = defaults
        self.isSignedIn = isSignedIn
    }

    func activateAccountScope(storageID: String) {
        guard storageID.count == 64,
              storageID.allSatisfy(\.isHexDigit) else {
            deactivateAccountScope()
            return
        }
        guard activeStorageID != storageID else { return }
        invalidateAccountWork()
        clearTransientState()
        activeStorageID = storageID
        loadLocalMetadata()
    }

    func deactivateAccountScope() {
        invalidateAccountWork()
        clearTransientState()
        activeStorageID = nil
        labels = [:]
        referenceLanguages = [:]
        cachedIdentities = [:]
    }

    #if DEBUG
    func activateLegacyTestingScope() {
        invalidateAccountWork()
        clearTransientState()
        activeStorageID = "debug-legacy"
        loadLocalMetadata()
    }
    #endif

    var canCreateNow: Bool {
        // Creation is intentionally available to every signed-in account.
        // The 120-minute entitlement only gates applying a cloned voice to
        // Read Aloud / Explain; it is never a voice-count or creation limit.
        true
    }

    var canApply: Bool {
        guard ProManager.shared.isPro else { return false }
        if isQuotaBlocked { return false }
        // The app may stay open across the UTC monthly reset. A stale exhausted
        // snapshot must not keep the voice locked after its reset time; the next
        // request lets the server return the new authoritative counters.
        if quotaWindowHasResetLocally { return true }
        return capability.canApply ?? true
    }

    var isQuotaBlocked: Bool {
        guard let remaining = capability.monthlyRemainingSeconds,
              remaining <= 0 else { return false }
        guard let resetAt = capability.resetAt else { return true }
        return resetAt > Date()
    }

    var remainingMinutes: Int? {
        if quotaWindowHasResetLocally { return nil }
        return capability.monthlyRemainingSeconds.map { max(0, Int(ceil(Double($0) / 60))) }
    }

    var quotaPresentation: VoiceCloneQuotaPresentation {
        VoiceCloneQuotaPresentation(capability: capability)
    }

    private var quotaWindowHasResetLocally: Bool {
        guard capability.monthlyRemainingSeconds == 0,
              let resetAt = capability.resetAt else { return false }
        return resetAt <= Date()
    }

    func displayName(for voice: ClonedVoice) -> String {
        if let customName = voice.identity?.customName, !customName.isEmpty {
            return customName
        }
        if let index = voice.identity?.autoNameIndex, index > 0 {
            return String(
                format: AppLocalized("我的声音 %lld"),
                Int64(index)
            )
        }
        if let label = labels[voice.voiceId] { return label }
        let order = max(1, voices.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            .firstIndex(where: { $0.voiceId == voice.voiceId }).map { $0 + 1 } ?? 1)
        return String(
            format: AppLocalized("我的声音 %lld"),
            Int64(order)
        )
    }

    func voice(withID voiceID: String) -> ClonedVoice? {
        voices.first { $0.voiceId == voiceID }
    }

    /// Last-known display metadata is account-scoped and never participates in
    /// creation, preview, selection, entitlement or TTS. It only prevents a
    /// cold launch from replacing a selected clone's stable avatar/name with a
    /// generic placeholder before the Created screen performs its first GET.
    func presentationVoice(withID voiceID: String) -> ClonedVoice? {
        if let voice = voice(withID: voiceID) {
            if voice.identity != nil { return voice }
            return voice.replacingIdentity(cachedIdentities[voiceID])
        }
        guard let identity = cachedIdentities[voiceID] else { return nil }
        return ClonedVoice(voiceId: voiceID, identity: identity)
    }

    func referenceLanguage(for voice: ClonedVoice) -> String? {
        let value = voice.referenceLanguage ?? referenceLanguages[voice.voiceId]
        let normalized = VoiceCatalog.normalizedLanguage(value ?? "")
        return normalized.isEmpty ? nil : normalized
    }

    func refresh() async {
        guard Constants.Features.voiceCloningEnabled else {
            invalidateRefreshes()
            voices = []
            refreshErrorMessage = nil
            errorMessage = nil
            return
        }
        guard isSignedIn(), activeStorageID != nil else {
            invalidateRefreshes()
            voices = []
            refreshErrorMessage = nil
            errorMessage = nil
            return
        }
        let token = beginRefresh()
        isLoading = true
        defer {
            if isCurrent(token) {
                isLoading = false
            }
        }
        do {
            let result = try await service.listVoices()
            guard isCurrent(token), !Task.isCancelled else { return }
            voices = reconcileServerVoices(result.voices)
            nextCreateAt = result.nextCreateAt
            applyCapability(result.capability)
            for voice in voices {
                if let language = voice.referenceLanguage {
                    referenceLanguages[voice.voiceId] = VoiceCatalog.normalizedLanguage(language)
                }
            }
            updateIdentityCache(from: voices)
            pruneLabels()
            persistReferenceLanguages()
            for active in AppSettings.shared.activeClonedVoiceIDs where !voices.contains(where: { $0.voiceId == active }) {
                AppSettings.shared.clearActiveClonedVoice(ifMatching: active)
            }
            refreshErrorMessage = nil
            errorMessage = nil
        } catch is CancellationError {
            // Leaving the Created tab cancels its SwiftUI task. Keep the cached
            // voices on screen and treat that cancellation as a silent refresh
            // stop, not as a user-facing clone error.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession may surface task cancellation as URLError.cancelled.
        } catch let cloneError as VoiceCloneError {
            guard isCurrent(token) else { return }
            switch cloneError {
            case .signInRequired, .sessionUnavailable:
                handle(cloneError)
            default:
                // Opening the Created tab performs a background refresh. A
                // transient list failure must not present a blocking alert or
                // erase already-cached voices; the page exposes an inline retry.
                refreshErrorMessage = cloneError.localizedDescription
            }
        } catch {
            guard isCurrent(token) else { return }
            refreshErrorMessage = error.localizedDescription
        }
    }

    func create(
        recordingURL: URL,
        referenceLanguage: String,
        referenceText: String?,
        consentConfirmed: Bool
    ) async -> Bool {
        guard Constants.Features.voiceCloningEnabled else { return false }
        guard !isCreating else { return false }
        let scopeToken = currentAccountToken
        guard scopeToken.storageID != nil else { return false }
        let requestID = UUID()
        activeCreateRequestID = requestID
        isCreating = true
        uploadProgress = 0
        defer {
            if activeCreateRequestID == requestID {
                activeCreateRequestID = nil
                isCreating = false
            }
        }
        do {
            let created = try await service.createVoice(
                recordingURL: recordingURL,
                referenceLanguage: referenceLanguage,
                referenceText: referenceText,
                consentConfirmed: consentConfirmed
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          self.activeCreateRequestID == requestID,
                          self.isCurrent(scopeToken) else { return }
                    self.uploadProgress = progress
                }
            }
            guard activeCreateRequestID == requestID,
                  isCurrent(scopeToken),
                  !Task.isCancelled else { return false }
            // The create response is authoritative. Publish it immediately so
            // a transient list refresh failure cannot make a successfully
            // created voice look empty or lost to the user.
            if let index = voices.firstIndex(where: { $0.voiceId == created.voiceId }) {
                voices[index] = created
            } else {
                voices.insert(created, at: 0)
            }
            authoritativeCreatedVoices[created.voiceId] = created
            if created.identity == nil {
                assignLabelIfNeeded(created.voiceId)
            } else if let identity = created.identity {
                cachedIdentities[created.voiceId] = identity
                persistIdentities()
            }
            let normalized = VoiceCatalog.normalizedLanguage(referenceLanguage)
            referenceLanguages[created.voiceId] = normalized
            persistReferenceLanguages()
            lastCreatedVoiceID = created.voiceId
            // Do not select the voice automatically: free users may preview it,
            // while Pro users explicitly choose where to apply it. Creation
            // itself never consumes the 120-minute usage allowance.
            if !ProManager.shared.isPro {
                capability.canApply = false
            }
            // The POST response is already authoritative. Return success to the
            // creation flow immediately and reconcile the list in the background;
            // a slow or transient list request must not hold the success screen.
            reconciliationTask?.cancel()
            reconciliationTask = Task { [weak self] in
                await self?.refresh()
            }
            return true
        } catch let error as VoiceCloneError {
            handle(error)
            return false
        } catch {
            handle(error)
            return false
        }
    }

    @discardableResult
    func select(_ voice: ClonedVoice, for language: String) async -> Bool {
        guard Constants.Features.voiceCloningEnabled else { return false }
        let normalizedLanguage = VoiceCatalog.normalizedLanguage(language)
        let supported = Set(VoiceCloneLanguageSupport.languages(for: voice))
        guard supported.contains(normalizedLanguage) else {
            handle(VoiceCloneError.languageUnsupported)
            return false
        }
        guard ProManager.shared.isPro else {
            VoiceCloneAccessCoordinator.shared.prompt = .paywall
            return false
        }
        guard canApply else {
            if isQuotaBlocked {
                handle(VoiceCloneError.quotaExhausted(capability.resetAt))
            } else {
                VoiceCloneAccessCoordinator.shared.prompt = .message(
                    AppLocalized("Pro 权益正在同步，请稍后重试")
                )
            }
            return false
        }
        guard await service.hasSession() else {
            handle(VoiceCloneError.sessionUnavailable)
            return false
        }
        AppSettings.shared.setActiveClonedVoice(voice.voiceId, for: normalizedLanguage)
        return true
    }

    func delete(_ voice: ClonedVoice) async {
        guard Constants.Features.voiceCloningEnabled else { return }
        guard deletingVoiceId == nil else { return }
        let scopeToken = currentAccountToken
        guard scopeToken.storageID != nil else { return }
        let requestID = UUID()
        activeDeleteRequestID = requestID
        deletingVoiceId = voice.voiceId
        activeRenameRequests.removeValue(forKey: voice.voiceId)
        if renamingVoiceId == voice.voiceId { renamingVoiceId = nil }
        defer {
            if activeDeleteRequestID == requestID {
                activeDeleteRequestID = nil
                if deletingVoiceId == voice.voiceId { deletingVoiceId = nil }
            }
        }
        do {
            try await service.deleteVoice(voice.voiceId)
            guard isCurrent(scopeToken),
                  activeDeleteRequestID == requestID,
                  !Task.isCancelled else { return }
            authoritativeCreatedVoices.removeValue(forKey: voice.voiceId)
            AppSettings.shared.clearActiveClonedVoice(ifMatching: voice.voiceId)
            labels.removeValue(forKey: voice.voiceId)
            referenceLanguages.removeValue(forKey: voice.voiceId)
            cachedIdentities.removeValue(forKey: voice.voiceId)
            persistLabels()
            persistReferenceLanguages()
            persistIdentities()
            await refresh()
        } catch {
            guard isCurrent(scopeToken),
                  activeDeleteRequestID == requestID else { return }
            handle(error)
        }
    }

    @discardableResult
    func rename(_ voiceID: String, to name: String?) async -> Bool {
        guard Constants.Features.voiceCloningEnabled else { return false }
        guard renamingVoiceId == nil,
              deletingVoiceId != voiceID,
              let currentVoice = voice(withID: voiceID),
              let identity = currentVoice.identity else {
            errorMessage = VoiceCloneError.identityUnavailable.localizedDescription
            return false
        }
        let normalizedName: String?
        do {
            normalizedName = try VoiceCloneNameValidator.normalized(name)
        } catch {
            handle(error)
            return false
        }
        let scopeToken = currentAccountToken
        guard scopeToken.storageID != nil else { return false }
        let requestID = UUID()
        activeRenameRequests[voiceID] = requestID
        renamingVoiceId = voiceID
        defer {
            if activeRenameRequests[voiceID] == requestID {
                activeRenameRequests.removeValue(forKey: voiceID)
                if renamingVoiceId == voiceID { renamingVoiceId = nil }
            }
        }
        do {
            let updated = try await service.renameVoice(
                voiceID,
                name: normalizedName,
                expectedRevision: identity.revision
            )
            guard isCurrent(scopeToken),
                  activeRenameRequests[voiceID] == requestID,
                  deletingVoiceId != voiceID,
                  voice(withID: voiceID) != nil else { return false }
            applyIdentity(updated, to: voiceID)
            errorMessage = nil
            return true
        } catch VoiceCloneError.identityConflict(let latest) {
            guard isCurrent(scopeToken),
                  activeRenameRequests[voiceID] == requestID,
                  deletingVoiceId != voiceID,
                  voice(withID: voiceID) != nil else { return false }
            if let latest,
               latest.revision > identity.revision,
               latest.matchesRequestedName(normalizedName) {
                // The first request committed but its success response was
                // lost. Converge by desired state instead of showing a false
                // cross-device conflict.
                applyIdentity(latest, to: voiceID)
                errorMessage = nil
                return true
            }
            if let latest { applyIdentity(latest, to: voiceID) }
            handle(VoiceCloneError.identityConflict(latest))
            return false
        } catch {
            guard isCurrent(scopeToken),
                  activeRenameRequests[voiceID] == requestID else { return false }
            handle(error)
            return false
        }
    }

    func applyServerStatus(_ status: ProStatusDTO) {
        applyCapability(
            VoiceCloneCapability(
                canCreate: status.cloneCanCreate,
                freeCreationConsumed: status.cloneFreeCreationConsumed,
                canApply: status.cloneCanApply,
                monthlyLimitSeconds: status.cloneMonthlyLimitSeconds,
                monthlyUsedSeconds: status.cloneMonthlyUsedSeconds,
                monthlyRemainingSeconds: status.cloneMonthlyRemainingSeconds,
                resetAt: VoiceCloneResponseParser.parseServerDate(status.cloneQuotaResetAt)
            )
        )
    }

    func clearEntitlementStatus() {
        capability = .unknown
    }

    func applyCapability(_ update: VoiceCloneCapability) {
        // Decode legacy creation fields for wire compatibility, but never use
        // or persist them as an eligibility gate. Older servers may briefly
        // return canCreate=false/freeCreationConsumed=true during rollout.
        capability.canCreate = true
        capability.freeCreationConsumed = false
        if let value = update.canApply { capability.canApply = value }
        if let value = update.monthlyLimitSeconds { capability.monthlyLimitSeconds = value }
        if let value = update.monthlyUsedSeconds { capability.monthlyUsedSeconds = value }
        if let value = update.monthlyRemainingSeconds {
            capability.monthlyRemainingSeconds = value
            if value > 0, update.canApply == nil, ProManager.shared.isPro {
                capability.canApply = true
            }
        }
        if let value = update.resetAt { capability.resetAt = value }
    }

    func applyQuotaHeaders(_ response: HTTPURLResponse) {
        applyCapability(VoiceCloneResponseParser.quotaCapability(from: response))
    }

    func markQuotaExhausted(resetAt: Date?) {
        capability.canApply = false
        capability.monthlyRemainingSeconds = 0
        if let resetAt { capability.resetAt = resetAt }
    }

    private func handle(_ error: Error) {
        errorMessage = error.localizedDescription
        guard let cloneError = error as? VoiceCloneError else { return }
        switch cloneError {
        case .signInRequired:
            VoiceCloneAccessCoordinator.shared.prompt = .signIn
        case .sessionUnavailable:
            VoiceCloneAccessCoordinator.shared.prompt = .message(cloneError.localizedDescription)
        case .proRequired:
            if ProManager.shared.isPro {
                VoiceCloneAccessCoordinator.shared.prompt = .message(
                    AppLocalized("Pro 权益正在同步，请稍后重试")
                )
            } else {
                VoiceCloneAccessCoordinator.shared.prompt = .paywall
            }
        case .quotaExhausted(let resetAt):
            markQuotaExhausted(resetAt: resetAt)
            VoiceCloneAccessCoordinator.shared.prompt = .message(cloneError.localizedDescription)
        default:
            break
        }
    }

    private func assignLabelIfNeeded(_ voiceId: String) {
        guard labels[voiceId] == nil else { return }
        labels[voiceId] = String(
            format: AppLocalized("我的声音 %lld"),
            Int64(labels.count + 1)
        )
        persistLabels()
    }

    private func pruneLabels() {
        let ids = Set(voices.map(\.voiceId))
        labels = labels.filter { ids.contains($0.key) }
        referenceLanguages = referenceLanguages.filter { ids.contains($0.key) }
        persistLabels()
        persistReferenceLanguages()
    }

    private struct AccountToken: Equatable, Sendable {
        let storageID: String?
        let generation: UInt64
    }

    private struct RefreshToken: Equatable, Sendable {
        let account: AccountToken
        let generation: UInt64
    }

    private var currentAccountToken: AccountToken {
        AccountToken(storageID: activeStorageID, generation: accountGeneration)
    }

    private func beginRefresh() -> RefreshToken {
        refreshGeneration &+= 1
        return RefreshToken(
            account: currentAccountToken,
            generation: refreshGeneration
        )
    }

    private func isCurrent(_ token: AccountToken) -> Bool {
        token == currentAccountToken
    }

    private func isCurrent(_ token: RefreshToken) -> Bool {
        token.account == currentAccountToken && token.generation == refreshGeneration
    }

    private func invalidateRefreshes() {
        refreshGeneration &+= 1
        reconciliationTask?.cancel()
        reconciliationTask = nil
        isLoading = false
    }

    private func invalidateAccountWork() {
        accountGeneration &+= 1
        invalidateRefreshes()
        activeCreateRequestID = nil
        activeDeleteRequestID = nil
        activeRenameRequests = [:]
        renamingVoiceId = nil
        authoritativeCreatedVoices = [:]
    }

    /// A create response is authoritative until the list endpoint has observed
    /// that exact ID once. This prevents an eventually-consistent or older
    /// in-flight list response from making a successful creation disappear.
    private func reconcileServerVoices(_ serverVoices: [ClonedVoice]) -> [ClonedVoice] {
        let localByID = Dictionary(uniqueKeysWithValues: voices.map { ($0.voiceId, $0) })
        let mergedServerVoices = serverVoices.map { serverVoice in
            guard let localIdentity = localByID[serverVoice.voiceId]?.identity
                    ?? cachedIdentities[serverVoice.voiceId] else {
                return serverVoice
            }
            guard let serverIdentity = serverVoice.identity,
                  serverIdentity.revision > localIdentity.revision else {
                return serverVoice.replacingIdentity(localIdentity)
            }
            return serverVoice
        }
        let serverIDs = Set(mergedServerVoices.map(\.voiceId))
        for voiceID in serverIDs {
            authoritativeCreatedVoices.removeValue(forKey: voiceID)
        }
        let missingCreated = authoritativeCreatedVoices.values
            .filter { !serverIDs.contains($0.voiceId) }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        return missingCreated + mergedServerVoices
    }

    private func applyIdentity(_ identity: VoiceCloneIdentity, to voiceID: String) {
        guard identity.isSupported else { return }
        var cacheChanged = false
        if let index = voices.firstIndex(where: { $0.voiceId == voiceID }) {
            let currentRevision = voices[index].identity?.revision ?? 0
            if identity.revision >= currentRevision {
                voices[index] = voices[index].replacingIdentity(identity)
            }
        }
        if let created = authoritativeCreatedVoices[voiceID] {
            let currentRevision = created.identity?.revision ?? 0
            if identity.revision >= currentRevision {
                authoritativeCreatedVoices[voiceID] = created.replacingIdentity(identity)
            }
        }
        let cachedRevision = cachedIdentities[voiceID]?.revision ?? 0
        if identity.revision >= cachedRevision {
            cachedIdentities[voiceID] = identity
            cacheChanged = true
        }
        if cacheChanged { persistIdentities() }
    }

    private func updateIdentityCache(from activeVoices: [ClonedVoice]) {
        let activeIDs = Set(activeVoices.map(\.voiceId))
        cachedIdentities = cachedIdentities.filter { activeIDs.contains($0.key) }
        for voice in activeVoices {
            guard let identity = voice.identity, identity.isSupported else { continue }
            let cachedRevision = cachedIdentities[voice.voiceId]?.revision ?? 0
            if identity.revision >= cachedRevision {
                cachedIdentities[voice.voiceId] = identity
            }
        }
        persistIdentities()
    }

    private func clearTransientState() {
        voices = []
        nextCreateAt = nil
        isLoading = false
        isCreating = false
        uploadProgress = 0
        deletingVoiceId = nil
        renamingVoiceId = nil
        cachedIdentities = [:]
        capability = .unknown
        lastCreatedVoiceID = nil
        refreshErrorMessage = nil
        errorMessage = nil
    }

    private func loadLocalMetadata() {
        guard let keys = scopedKeys else {
            labels = [:]
            referenceLanguages = [:]
            cachedIdentities = [:]
            return
        }
        labels = defaults.dictionary(forKey: keys.labels)?
            .compactMapValues { $0 as? String } ?? [:]
        referenceLanguages = defaults.dictionary(forKey: keys.referenceLanguages)?
            .compactMapValues { $0 as? String } ?? [:]
        if let data = defaults.data(forKey: keys.identities),
           let decoded = try? JSONDecoder().decode(
               [String: VoiceCloneIdentity].self,
               from: data
           ) {
            cachedIdentities = decoded.filter {
                $0.key.hasPrefix("vc_") && $0.value.isSupported
            }
        } else {
            cachedIdentities = [:]
        }
    }

    private func persistLabels() {
        guard let key = scopedKeys?.labels else { return }
        defaults.set(labels, forKey: key)
    }
    private func persistReferenceLanguages() {
        guard let key = scopedKeys?.referenceLanguages else { return }
        defaults.set(referenceLanguages, forKey: key)
    }
    private func persistIdentities() {
        guard let key = scopedKeys?.identities,
              let data = try? JSONEncoder().encode(cachedIdentities) else { return }
        defaults.set(data, forKey: key)
    }

    private var scopedKeys: (
        labels: String,
        referenceLanguages: String,
        identities: String
    )? {
        guard let activeStorageID else { return nil }
        #if DEBUG
        if activeStorageID == "debug-legacy" {
            return (Keys.labels, Keys.referenceLanguages, Keys.identities)
        }
        #endif
        return (
            "\(Keys.labels).account.\(activeStorageID)",
            "\(Keys.referenceLanguages).account.\(activeStorageID)",
            "\(Keys.identities).account.\(activeStorageID)"
        )
    }

    private enum Keys {
        static let labels = "voice_clone_labels_v1"
        static let referenceLanguages = "voice_clone_reference_languages_v1"
        static let identities = "voice_clone_identities_v1"
    }
}
