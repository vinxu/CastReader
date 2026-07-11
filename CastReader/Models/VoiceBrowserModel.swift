//
//  VoiceBrowserModel.swift
//  CastReader
//
//  音色浏览器的纯筛选、收藏/最近使用和选择权限合同。
//

import Foundation
import Combine

enum VoiceBrowserTab: String, CaseIterable, Identifiable {
    case recent
    case favorites
    case explore

    var id: String { rawValue }
}

enum VoiceTierFilter: String, CaseIterable, Identifiable {
    case all
    case free
    case pro

    var id: String { rawValue }
}

enum VoiceBrowserFilter {
    static func apply(
        voices: [VoiceOption],
        search: String,
        language: String,
        gender: String,
        tier: VoiceTierFilter
    ) -> [VoiceOption] {
        let query = search.trimmed.lowercased()
        let normalizedLanguage = VoiceCatalog.normalizedLanguage(language)
        let normalizedGender = gender.trimmed.lowercased()

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
            switch tier {
            case .all: break
            case .free where voice.isPro: return false
            case .pro where !voice.isPro: return false
            default: break
            }
            guard !query.isEmpty else { return true }
            let searchable = ([voice.name, voice.code, voice.locale] + voice.tags)
                .joined(separator: " ")
                .lowercased()
            return searchable.contains(query)
        }
    }
}

@MainActor
final class VoiceLibraryStore: ObservableObject {
    static let shared = VoiceLibraryStore()
    static let recentLimit = 12

    @Published private(set) var favoriteIDs: Set<String>
    @Published private(set) var recentIDs: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favoriteIDs = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
        recentIDs = Self.normalizedRecents(defaults.stringArray(forKey: Keys.recents) ?? [])
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

    private static func normalizedRecents(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(recentLimit)
            .map { $0 }
    }

    private enum Keys {
        static let favorites = "voice_browser_favorites_v1"
        static let recents = "voice_browser_recent_v1"
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
