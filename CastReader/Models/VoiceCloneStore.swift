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
    @Published private(set) var capability: VoiceCloneCapability = .unknown
    @Published private(set) var lastCreatedVoiceID: String?
    @Published private(set) var refreshErrorMessage: String?
    @Published var errorMessage: String?

    private let service: VoiceCloneService
    private let defaults: UserDefaults
    private var labels: [String: String] = [:]
    private var referenceLanguages: [String: String] = [:]
    private var activeStorageID: String?

    init(service: VoiceCloneService = .shared, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    func activateAccountScope(storageID: String) {
        guard storageID.count == 64,
              storageID.allSatisfy(\.isHexDigit) else {
            deactivateAccountScope()
            return
        }
        guard activeStorageID != storageID else { return }
        clearTransientState()
        activeStorageID = storageID
        loadLocalMetadata()
    }

    func deactivateAccountScope() {
        clearTransientState()
        activeStorageID = nil
        labels = [:]
        referenceLanguages = [:]
    }

    #if DEBUG
    func activateLegacyTestingScope() {
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
        if let label = labels[voice.voiceId] { return label }
        let order = max(1, voices.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            .firstIndex(where: { $0.voiceId == voice.voiceId }).map { $0 + 1 } ?? 1)
        return String(
            format: AppLocalized("我的声音 %lld"),
            Int64(order)
        )
    }

    func referenceLanguage(for voice: ClonedVoice) -> String? {
        let value = voice.referenceLanguage ?? referenceLanguages[voice.voiceId]
        let normalized = VoiceCatalog.normalizedLanguage(value ?? "")
        return normalized.isEmpty ? nil : normalized
    }

    func refresh() async {
        guard Constants.Features.voiceCloningEnabled else {
            voices = []
            refreshErrorMessage = nil
            errorMessage = nil
            return
        }
        guard AuthService.shared.isSignedIn else {
            voices = []
            refreshErrorMessage = nil
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.listVoices()
            voices = result.voices
            nextCreateAt = result.nextCreateAt
            applyCapability(result.capability)
            for voice in result.voices {
                if let language = voice.referenceLanguage {
                    referenceLanguages[voice.voiceId] = VoiceCatalog.normalizedLanguage(language)
                }
            }
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
            refreshErrorMessage = error.localizedDescription
        }
    }

    func create(
        recordingURL: URL,
        referenceLanguage: String,
        referenceText: String,
        consentConfirmed: Bool
    ) async -> Bool {
        guard Constants.Features.voiceCloningEnabled else { return false }
        guard !isCreating else { return false }
        isCreating = true
        uploadProgress = 0
        defer { isCreating = false }
        do {
            let created = try await service.createVoice(
                recordingURL: recordingURL,
                referenceLanguage: referenceLanguage,
                referenceText: referenceText,
                consentConfirmed: consentConfirmed
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.uploadProgress = progress
                }
            }
            // The create response is authoritative. Publish it immediately so
            // a transient list refresh failure cannot make a successfully
            // created voice look empty or lost to the user.
            if let index = voices.firstIndex(where: { $0.voiceId == created.voiceId }) {
                voices[index] = created
            } else {
                voices.insert(created, at: 0)
            }
            assignLabelIfNeeded(created.voiceId)
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
            Task { [weak self] in
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
        deletingVoiceId = voice.voiceId
        defer { deletingVoiceId = nil }
        do {
            try await service.deleteVoice(voice.voiceId)
            AppSettings.shared.clearActiveClonedVoice(ifMatching: voice.voiceId)
            labels.removeValue(forKey: voice.voiceId)
            referenceLanguages.removeValue(forKey: voice.voiceId)
            persistLabels()
            persistReferenceLanguages()
            await refresh()
        } catch {
            handle(error)
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

    private func clearTransientState() {
        voices = []
        nextCreateAt = nil
        isLoading = false
        isCreating = false
        uploadProgress = 0
        deletingVoiceId = nil
        capability = .unknown
        lastCreatedVoiceID = nil
        refreshErrorMessage = nil
        errorMessage = nil
    }

    private func loadLocalMetadata() {
        guard let keys = scopedKeys else {
            labels = [:]
            referenceLanguages = [:]
            return
        }
        labels = defaults.dictionary(forKey: keys.labels)?
            .compactMapValues { $0 as? String } ?? [:]
        referenceLanguages = defaults.dictionary(forKey: keys.referenceLanguages)?
            .compactMapValues { $0 as? String } ?? [:]
    }

    private func persistLabels() {
        guard let key = scopedKeys?.labels else { return }
        defaults.set(labels, forKey: key)
    }
    private func persistReferenceLanguages() {
        guard let key = scopedKeys?.referenceLanguages else { return }
        defaults.set(referenceLanguages, forKey: key)
    }

    private var scopedKeys: (
        labels: String,
        referenceLanguages: String
    )? {
        guard let activeStorageID else { return nil }
        #if DEBUG
        if activeStorageID == "debug-legacy" {
            return (Keys.labels, Keys.referenceLanguages)
        }
        #endif
        return (
            "\(Keys.labels).account.\(activeStorageID)",
            "\(Keys.referenceLanguages).account.\(activeStorageID)"
        )
    }

    private enum Keys {
        static let labels = "voice_clone_labels_v1"
        static let referenceLanguages = "voice_clone_reference_languages_v1"
    }
}
