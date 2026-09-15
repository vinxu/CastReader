//
//  VoiceBrowserModel.swift
//  CastReader
//
//  音色浏览器的纯筛选、收藏/最近使用和选择权限合同。
//

import Foundation
import Combine
import AVFoundation

enum VoiceBrowserTab: String, CaseIterable, Identifiable {
    case recent
    case favorites
    case explore
    case created

    var id: String { rawValue }
}

enum VoiceTierFilter: String, CaseIterable, Identifiable {
    case all
    case free
    case pro

    var id: String { rawValue }
}

enum VoiceBrowserLanguage {
    static let primary = SupportedTTSLanguage.allCases.map(\.rawValue)

    static func defaultLanguage(
        preferredLanguages: [String],
        availableLanguages: [String] = primary
    ) -> String {
        let available = Set(availableLanguages.map(VoiceCatalog.normalizedLanguage))
        for language in preferredLanguages {
            let normalized = VoiceCatalog.normalizedLanguage(language)
            if available.contains(normalized) { return normalized }
        }
        if available.contains("en") { return "en" }
        return availableLanguages.first.map(VoiceCatalog.normalizedLanguage) ?? "en"
    }

    static func displayName(
        for language: VoiceCatalogLanguageOption,
        locale: Locale = .current
    ) -> String {
        let localized = locale.localizedString(forIdentifier: language.locale)?.trimmed
        if let localized, !localized.isEmpty { return localized }
        return language.name
    }

    static func voiceCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            AppLocalized("%lld 个音色"),
            Int64(count)
        )
    }

    static func languageCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            AppLocalized("%lld 种语言"),
            Int64(count)
        )
    }

    static func matchesSearch(
        _ language: VoiceCatalogLanguageOption,
        query: String,
        locale: Locale = .current
    ) -> Bool {
        let normalizedQuery = query.trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        )
        guard !normalizedQuery.isEmpty else { return true }
        let searchable = [
            displayName(for: language, locale: locale),
            language.name,
            language.code,
            language.locale,
        ].joined(separator: " ").folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        )
        return searchable.contains(normalizedQuery)
    }
}

/// Voice metadata can contain absolute media URLs. The catalog endpoint alone
/// is not a sufficient route boundary: on the CN route, known legacy API media
/// is rewritten through the filed gateway and every other legacy owned host is
/// rejected. Third-party HTTPS CDNs remain usable.
enum VoiceCatalogAssetURL {
    static func resolve(
        _ rawValue: String?,
        route: ServiceRoute = ComputeRouting.current
    ) -> URL? {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if raw.hasPrefix("/"), !raw.hasPrefix("//"),
           let relative = URLComponents(string: raw),
           (OwnedAPIRedirectPolicy.isChinaGatewayBackedResponsePath(relative.path)
                || relative.path.hasPrefix("/api/voice-clone/public/")
                || relative.path.hasPrefix("/voice-library/avatars/")
                || relative.path.hasPrefix("/voice-discovery/artwork/")) {
            return URL(
                string: raw,
                relativeTo: URL(string: route.apiGatewayBaseURL)
            )?.absoluteURL
        }

        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if OwnedAPIRedirectPolicy.isCastReaderOwnedHost(host) {
            return components.url.flatMap {
                OwnedAPIRedirectPolicy.routedResponseURL(
                    $0,
                    route: route
                )
            }
        }
        return components.url
    }
}

enum VoiceBrowserFilter {
    static func apply(
        voices: [VoiceOption],
        search: String,
        language: String,
        gender: String,
        tier: VoiceTierFilter,
        accent: String = "",
        recommendedOnly: Bool = false
    ) -> [VoiceOption] {
        let query = VoiceDiscovery.normalized(search)
        let normalizedLanguage = VoiceCatalog.normalizedLanguage(language)
        let normalizedGender = gender.trimmed.lowercased()
        let normalizedAccent = accent.trimmed.lowercased()

        return voices.filter { voice in
            guard voice.selectable else { return false }
            if !normalizedLanguage.isEmpty,
               !voice.supports(normalizedLanguage) {
                return false
            }
            if !normalizedGender.isEmpty,
               voice.gender.trimmed.lowercased() != normalizedGender {
                return false
            }
            if !normalizedAccent.isEmpty,
               normalizedAccentValue(for: voice) != normalizedAccent {
                return false
            }
            if recommendedOnly, !voice.recommended { return false }
            switch tier {
            case .all: break
            case .free where voice.isPro: return false
            case .pro where !voice.isPro: return false
            default: break
            }
            guard !query.isEmpty else { return true }
            let searchable = ([
                voice.name, voice.code, voice.locale, voice.accent ?? "",
                voice.description ?? "", voice.descriptionZh ?? "",
                voice.collection ?? ""
            ] + voice.tags + voice.bestFor)
                .joined(separator: " ")
                .lowercased()
            return VoiceDiscovery.normalized(searchable + " " + VoiceDiscovery.searchTerms(voice)).contains(query)
        }
    }

    static func normalizedAccentValue(for voice: VoiceOption) -> String {
        if let accent = voice.accent?.trimmed.lowercased(), !accent.isEmpty {
            if accent.contains("brit") || accent == "uk" || accent == "gb" { return "uk" }
            if accent.contains("america") || accent == "us" { return "us" }
            return accent
        }
        let locale = voice.locale.trimmed.lowercased()
        if locale.contains("-gb") || locale.contains("_gb") { return "uk" }
        if locale.contains("-us") || locale.contains("_us") { return "us" }
        return ""
    }
}

@MainActor
final class VoiceSamplePlayer: ObservableObject {
    static let shared = VoiceSamplePlayer()

    enum Status: String { case stopped, loading, playing }
    enum PlaybackState: Equatable {
        case stopped, loading(String), playing(String)
        func status(for voiceID: String) -> Status {
            switch self {
            case .loading(let id) where id == voiceID: return .loading
            case .playing(let id) where id == voiceID: return .playing
            default: return .stopped
            }
        }
    }
    @Published private(set) var playbackState: PlaybackState = .stopped
    var playingVoiceID: String? { if case .playing(let id) = playbackState { return id }; return nil }
    var loadingVoiceID: String? { if case .loading(let id) = playbackState { return id }; return nil }
    @Published var previewError: String?

    private var player: AVPlayer?
    private var endObservers: [NSObjectProtocol] = []
    private var statusCancellable: AnyCancellable?
    private var sampleLoadTask: Task<Void, Never>?
    private var sampleLoadID: UUID?
    private var readinessTimeout: Task<Void, Never>?

    func toggle(voiceID: String, sampleURL: String?) {
        #if DEBUG
        VoiceSampleDiagnostics.start()
        #endif
        if previewError != nil { previewError = nil }
        if playingVoiceID == voiceID || loadingVoiceID == voiceID {
            stop()
            return
        }
        let route = ComputeRouting.current
        guard let url = Self.validSampleURL(sampleURL, route: route) else {
            previewError = AppLocalized("试听暂不可用，请稍后重试")
            return
        }

        stop(resumeSuspendedPlayback: false)
        VoiceClonePreviewPlayer.shared.stop(resumeSuspendedPlayback: false)
        VoicePreviewPlaybackCoordinator.shared.begin()
        playbackState = .loading(voiceID)
        let loadID = UUID()
        sampleLoadID = loadID
        sampleLoadTask = Task { [weak self] in
            do {
                let localURL = try await Self.downloadSample(url: url, route: route)
                try Task.checkCancellation()
                guard let self,
                      self.sampleLoadID == loadID, self.loadingVoiceID == voiceID else {
                    return
                }
                self.installPlayer(voiceID: voiceID, url: localURL, loadID: loadID)
            } catch {
                guard let self, self.sampleLoadID == loadID, self.loadingVoiceID == voiceID else { return }
                self.stop()
                self.previewError = AppLocalized("试听暂不可用，请稍后重试")
                #if DEBUG
                NSLog("[VoiceSample] download failed: %@", error.localizedDescription)
                #endif
            }
        }
    }

    private func installPlayer(voiceID: String, url: URL, loadID: UUID) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        for name in [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime] {
            endObservers.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.sampleLoadID == loadID else { return }
                    self.stop()
                    if name == .AVPlayerItemFailedToPlayToEndTime {
                        self.previewError = AppLocalized("试听暂不可用，请稍后重试")
                    }
                }
            })
        }
        readinessTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.sampleLoadID == loadID, self.loadingVoiceID == voiceID else { return }
            self.stop()
            self.previewError = AppLocalized("试听暂不可用，请稍后重试")
        }
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, self.sampleLoadID == loadID, self.loadingVoiceID == voiceID else { return }
                switch status {
                case .readyToPlay:
                    self.readinessTimeout?.cancel()
                    self.readinessTimeout = nil
                    self.playbackState = .playing(voiceID)
                    self.player?.play()
                    #if DEBUG
                    NSLog("[VoiceSample] playing %@", voiceID)
                    #endif
                case .failed:
                    self.stop()
                    self.previewError = AppLocalized("试听暂不可用，请稍后重试")
                    #if DEBUG
                    NSLog("[VoiceSample] player failed: %@", item?.error?.localizedDescription ?? "unknown")
                    #endif
                default:
                    break
                }
            }
    }

    func stop(resumeSuspendedPlayback: Bool = true) {
        sampleLoadID = nil
        sampleLoadTask?.cancel()
        sampleLoadTask = nil
        readinessTimeout?.cancel()
        readinessTimeout = nil
        statusCancellable?.cancel()
        statusCancellable = nil
        endObservers.forEach { NotificationCenter.default.removeObserver($0) }
        endObservers.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if playbackState != .stopped { playbackState = .stopped }
        if resumeSuspendedPlayback { VoicePreviewPlaybackCoordinator.shared.end() }
    }

    nonisolated static func validSampleURL(
        _ value: String?,
        route: ServiceRoute = ComputeRouting.current
    ) -> URL? {
        VoiceCatalogAssetURL.resolve(value, route: route)
    }

    private nonisolated static func downloadSample(
        url: URL,
        route: ServiceRoute
    ) async throws -> URL {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-CastReaderVoiceExploreFixture"),
           let directory = ProcessInfo.processInfo.environment["CASTREADER_VOICE_FIXTURE_DIRECTORY"],
           url.path.hasPrefix("/api/voice-clone/public/"),
           let id = url.pathComponents.dropLast().last,
           id.range(of: #"^vl_[a-z0-9_]+$"#, options: .regularExpression) != nil,
           let language = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "language" })?.value,
           ["en", "zh"].contains(language) {
            let source = URL(fileURLWithPath: directory).appendingPathComponent("\(id)-\(language).mp3")
            return source
        }
        #endif
        return try await VoiceSampleCache.shared.file(for: url, route: route)
    }
}

@MainActor
final class VoicePreviewPlaybackCoordinator {
    static let shared = VoicePreviewPlaybackCoordinator()

    private var resumeHandle: AudioPlaybackResumeHandle?

    func begin() {
        guard resumeHandle == nil else { return }
        let audio = AudioPlayerService.shared
        guard let handle = audio.suspendActivePlaybackForVoicePreview() else { return }
        resumeHandle = handle
        NSLog("[VoicePreview] suspended owned content")
    }

    func end() {
        defer { resumeHandle = nil }
        guard let handle = resumeHandle else { return }
        let resumed = AudioPlayerService.shared.resumePlaybackAfterVoicePreview(handle)
        NSLog("[VoicePreview] resume owned content=%@", resumed ? "Y" : "N")
    }

    /// A real voice selection supersedes the temporary preview. Return whether
    /// content had been playing so the voice handoff can preserve that intent
    /// without briefly resuming the old voice first.
    @discardableResult
    func cancelForVoiceSwitch() -> Bool {
        let shouldResume = resumeHandle != nil
        resumeHandle = nil
        return shouldResume
    }
}

@MainActor
final class VoiceLibraryStore: ObservableObject {
    static let shared = VoiceLibraryStore()
    static let recentLimit = 12

    @Published private(set) var favoriteIDs: Set<String>
    @Published private(set) var recentIDs: [String]
    @Published private(set) var browserLanguage: String
    private(set) var hasExplicitBrowserLanguageSelection: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favoriteIDs = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        recentIDs = Self.normalizedRecents(defaults.stringArray(forKey: Keys.recents) ?? [])
        let stored = VoiceCatalog.normalizedLanguage(defaults.string(forKey: Keys.browserLanguage) ?? "")
        hasExplicitBrowserLanguageSelection = !stored.isEmpty
        if !stored.isEmpty {
            browserLanguage = stored
        } else {
            browserLanguage = VoiceBrowserLanguage.defaultLanguage(
                preferredLanguages: Locale.preferredLanguages + Bundle.main.preferredLocalizations
            )
        }
    }

    func isFavorite(_ voiceID: String) -> Bool {
        favoriteIDs.contains(voiceID)
    }

    func toggleFavorite(_ voiceID: String) {
        if favoriteIDs.contains(voiceID) {
            favoriteIDs.remove(voiceID)
        } else {
            favoriteIDs.insert(voiceID)
        }
        defaults.set(favoriteIDs.sorted(), forKey: Keys.favorites)
    }

    func recordRecent(_ voiceID: String) {
        recentIDs = Self.normalizedRecents([voiceID] + recentIDs)
        defaults.set(recentIDs, forKey: Keys.recents)
    }

    func setBrowserLanguage(_ language: String) {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard !normalized.isEmpty else { return }
        if normalized != browserLanguage { browserLanguage = normalized }
        hasExplicitBrowserLanguageSelection = true
        defaults.set(normalized, forKey: Keys.browserLanguage)
    }

    /// 首次使用时按设备首选语言确定单一作用域，但不把系统推导结果当成用户选择。
    /// 因此完整 catalog 稍后到达时，西语/日语等用户仍能自动切到自己的语言。
    func applyDefaultBrowserLanguage(_ language: String) {
        guard !hasExplicitBrowserLanguageSelection else { return }
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard !normalized.isEmpty, normalized != browserLanguage else { return }
        browserLanguage = normalized
    }

    /// 用户之前选择的语言已从完整目录下线时，回到设备默认并清除失效偏好。
    func replaceUnavailableBrowserLanguage(with language: String) {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard !normalized.isEmpty else { return }
        if normalized != browserLanguage { browserLanguage = normalized }
        hasExplicitBrowserLanguageSelection = false
        defaults.removeObject(forKey: Keys.browserLanguage)
    }

    private static func normalizedRecents(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(recentLimit)
            .map { $0 }
    }

    private enum Keys {
        static let favorites = "voice_browser_favorites_v1"
        static let recents = "voice_browser_recent_v1"
        static let browserLanguage = "voice_browser_language_v1"
    }
}

enum VoiceSelectionPolicy {
    @MainActor
    static func carrySelection(from sourceLanguage: String, to targetLanguage: String, settings: AppSettings) {
        let current = settings.voice(for: sourceLanguage)
        guard let voice = VoiceCatalog.option(for: current),
              voice.usesMonthlyGeneration, voice.supports(targetLanguage) else { return }
        _ = settings.setVoice(current, for: targetLanguage)
    }

    /// Pro 不满足时不写入偏好；UI 刷新 Pro 后可以再次调用。
    @MainActor
    static func select(
        _ voice: VoiceOption,
        isPro: Bool,
        settings: AppSettings,
        language: String? = nil
    ) -> Bool {
        guard voice.selectable, !voice.isPro || isPro else { return false }
        if voice.usesMonthlyGeneration {
            guard voice.supports(language ?? voice.lang) else { return false }
            return settings.setMultilingualClonedVoice(voice.code, supportedLanguages: voice.supportedLanguages)
        }
        return settings.setVoice(voice.code, for: language ?? voice.lang)
    }
}
