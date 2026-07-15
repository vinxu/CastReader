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
    /// 仅用于网络目录尚未载入时的安全默认；不是语言白名单。
    static let primary = ["zh", "en"]

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
            String(localized: "%lld 个音色"),
            Int64(count)
        )
    }

    static func languageCountText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "%lld 种语言"),
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
        let query = search.trimmed.lowercased()
        let normalizedLanguage = VoiceCatalog.normalizedLanguage(language)
        let normalizedGender = gender.trimmed.lowercased()
        let normalizedAccent = accent.trimmed.lowercased()

        return voices.filter { voice in
            guard voice.selectable else { return false }
            if !normalizedLanguage.isEmpty,
               VoiceCatalog.normalizedLanguage(voice.lang) != normalizedLanguage {
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
            return searchable.contains(query)
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

    @Published private(set) var playingVoiceID: String?
    @Published private(set) var loadingVoiceID: String?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusCancellable: AnyCancellable?

    func toggle(voiceID: String, sampleURL: String?) {
        if playingVoiceID == voiceID || loadingVoiceID == voiceID {
            stop()
            return
        }
        guard let url = Self.validSampleURL(sampleURL) else { return }

        stop(resumeSuspendedPlayback: false)
        VoiceClonePreviewPlayer.shared.stop(resumeSuspendedPlayback: false)
        VoicePreviewPlaybackCoordinator.shared.begin()
        loadingVoiceID = voiceID
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, self.loadingVoiceID == voiceID else { return }
                switch status {
                case .readyToPlay:
                    self.loadingVoiceID = nil
                    self.playingVoiceID = voiceID
                    self.player?.play()
                case .failed:
                    self.stop()
                default:
                    break
                }
            }
    }

    func stop(resumeSuspendedPlayback: Bool = true) {
        player?.pause()
        player = nil
        statusCancellable?.cancel()
        statusCancellable = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playingVoiceID = nil
        loadingVoiceID = nil
        if resumeSuspendedPlayback { VoicePreviewPlaybackCoordinator.shared.end() }
    }

    nonisolated static func validSampleURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

@MainActor
final class VoicePreviewPlaybackCoordinator {
    static let shared = VoicePreviewPlaybackCoordinator()

    private var suspendedSegmentID: String?
    private var suspendedBookID: String?

    func begin() {
        guard suspendedSegmentID == nil else { return }
        let audio = AudioPlayerService.shared
        guard audio.isPlaying, let segment = audio.currentSegment else { return }
        suspendedSegmentID = segment.id
        suspendedBookID = audio.currentBookId
        audio.pause()
        NSLog("[VoicePreview] suspended content segment=%@ book=%@", segment.id, audio.currentBookId ?? "-")
    }

    func end() {
        defer {
            suspendedSegmentID = nil
            suspendedBookID = nil
        }
        guard let segmentID = suspendedSegmentID else { return }
        let audio = AudioPlayerService.shared
        guard !audio.isPlaying,
              audio.currentSegment?.id == segmentID,
              audio.currentBookId == suspendedBookID else { return }
        audio.play()
        NSLog("[VoicePreview] resumed content segment=%@", segmentID)
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
    /// Pro 不满足时不写入偏好；UI 刷新 Pro 后可以再次调用。
    @MainActor
    static func select(
        _ voice: VoiceOption,
        isPro: Bool,
        settings: AppSettings
    ) -> Bool {
        guard voice.selectable, !voice.isPro || isPro else { return false }
        return settings.setVoice(voice.code, for: voice.lang)
    }
}
