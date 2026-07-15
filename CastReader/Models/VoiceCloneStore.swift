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
    @Published var errorMessage: String?

    private let service: VoiceCloneService
    private let defaults: UserDefaults
    private var labels: [String: String]
    private var referenceLanguages: [String: String]

    init(service: VoiceCloneService = .shared, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        labels = defaults.dictionary(forKey: Keys.labels)?.compactMapValues { $0 as? String } ?? [:]
        referenceLanguages = defaults.dictionary(forKey: Keys.referenceLanguages)?
            .compactMapValues { $0 as? String } ?? [:]
    }

    var canCreateNow: Bool { nextCreateAt.map { $0 <= Date() } ?? true }

    func displayName(for voice: ClonedVoice) -> String {
        if let label = labels[voice.voiceId] { return label }
        let order = max(1, voices.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            .firstIndex(where: { $0.voiceId == voice.voiceId }).map { $0 + 1 } ?? 1)
        return String(localized: "我的声音 \(order)")
    }

    func referenceLanguage(for voice: ClonedVoice) -> String? {
        let value = voice.referenceLanguage ?? referenceLanguages[voice.voiceId]
        let normalized = VoiceCatalog.normalizedLanguage(value ?? "")
        return normalized.isEmpty ? nil : normalized
    }

    func refresh() async {
        guard Constants.Features.voiceCloningEnabled else {
            voices = []
            errorMessage = nil
            return
        }
        guard AuthService.shared.isSignedIn else {
            voices = []
            errorMessage = nil
            return
        }
        guard ProManager.shared.serverPro else {
            voices = []
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.listVoices()
            voices = result.voices
            nextCreateAt = result.nextCreateAt
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
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func create(recordingURL: URL, referenceLanguage: String, consentConfirmed: Bool) async -> Bool {
        guard Constants.Features.voiceCloningEnabled else { return false }
        guard !isCreating else { return false }
        guard canCreateNow else {
            errorMessage = VoiceCloneError.creationLimit(nextCreateAt).localizedDescription
            return false
        }
        isCreating = true
        uploadProgress = 0
        defer { isCreating = false }
        do {
            let created = try await service.createVoice(
                recordingURL: recordingURL,
                referenceLanguage: referenceLanguage,
                consentConfirmed: consentConfirmed
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.uploadProgress = progress
                }
            }
            assignLabelIfNeeded(created.voiceId)
            let normalized = VoiceCatalog.normalizedLanguage(referenceLanguage)
            referenceLanguages[created.voiceId] = normalized
            persistReferenceLanguages()
            AppSettings.shared.setActiveClonedVoice(created.voiceId, for: normalized)
            await refresh()
            return true
        } catch let error as VoiceCloneError {
            if case .creationLimit(let next) = error { nextCreateAt = next }
            handle(error)
            return false
        } catch {
            handle(error)
            return false
        }
    }

    func select(_ voice: ClonedVoice, for language: String) async {
        guard Constants.Features.voiceCloningEnabled else { return }
        guard ProManager.shared.serverPro else {
            VoiceCloneAccessCoordinator.shared.prompt = .paywall
            return
        }
        guard await service.hasSession() else {
            handle(VoiceCloneError.sessionUnavailable)
            return
        }
        AppSettings.shared.setActiveClonedVoice(voice.voiceId, for: language)
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

    private func handle(_ error: Error) {
        errorMessage = error.localizedDescription
        guard let cloneError = error as? VoiceCloneError else { return }
        switch cloneError {
        case .signInRequired:
            VoiceCloneAccessCoordinator.shared.prompt = .signIn
        case .sessionUnavailable:
            VoiceCloneAccessCoordinator.shared.prompt = .message(cloneError.localizedDescription)
        case .proRequired:
            AppSettings.shared.clearActiveClonedVoice()
            VoiceCloneAccessCoordinator.shared.prompt = .paywall
        case .voiceNotFound:
            AppSettings.shared.clearActiveClonedVoice()
        default:
            break
        }
    }

    private func assignLabelIfNeeded(_ voiceId: String) {
        guard labels[voiceId] == nil else { return }
        labels[voiceId] = String(localized: "我的声音 \(labels.count + 1)")
        persistLabels()
    }

    private func pruneLabels() {
        let ids = Set(voices.map(\.voiceId))
        labels = labels.filter { ids.contains($0.key) }
        referenceLanguages = referenceLanguages.filter { ids.contains($0.key) }
        persistLabels()
        persistReferenceLanguages()
    }

    private func persistLabels() { defaults.set(labels, forKey: Keys.labels) }
    private func persistReferenceLanguages() {
        defaults.set(referenceLanguages, forKey: Keys.referenceLanguages)
    }

    private enum Keys {
        static let labels = "voice_clone_labels_v1"
        static let referenceLanguages = "voice_clone_reference_languages_v1"
    }
}
