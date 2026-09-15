import Foundation

enum VoiceUsageFilter: String, CaseIterable, Identifiable {
    case all, regular, monthly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return AppLocalized("全部音色")
        case .regular: return AppLocalized("不使用月额度")
        case .monthly: return AppLocalized("使用月额度")
        }
    }
    func includes(_ voice: VoiceOption) -> Bool {
        self == .all || (self == .monthly) == voice.usesMonthlyGeneration
    }
}

enum VoiceDiscoveryTopic: String, CaseIterable, Identifiable, Hashable, Codable {
    case everyday, focus, stories, gentle, conversation, character
    static let browseCases: [Self] = [.everyday, .stories, .focus, .gentle]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everyday: return AppLocalized("日常资讯")
        case .focus: return AppLocalized("学习讲解")
        case .stories: return AppLocalized("长文故事")
        case .gentle: return AppLocalized("睡前陪伴")
        case .conversation: return AppLocalized("像朋友讲给你听")
        case .character: return AppLocalized("给文字一点角色感")
        }
    }
    var shortTitle: String {
        switch self {
        case .everyday: return title
        case .focus: return title
        case .stories: return title
        case .gentle: return title
        case .conversation: return AppLocalized("聊天感")
        case .character: return AppLocalized("角色感")
        }
    }
    var symbol: String {
        switch self {
        case .everyday: return "headphones"
        case .focus: return "lightbulb"
        case .stories: return "book.closed"
        case .gentle: return "moon.stars"
        case .conversation: return "quote.bubble"
        case .character: return "theatermasks"
        }
    }
    var keywords: Set<String> {
        switch self {
        case .everyday: return ["articles", "article reading", "general reading", "news", "essays", "文章资讯", "通用阅读"]
        case .focus: return ["education", "focused study", "study", "explanations", "explainers", "documentaries", "知识讲解", "专注学习", "学习材料"]
        case .stories: return ["storytelling", "stories", "narrative reading", "narrative articles", "audiobooks", "dramatic", "expressive", "literary", "literature", "long-form", "long-form reading", "长文阅读"]
        case .gentle: return ["warm", "gentle", "soft", "calm", "soothing", "relaxed reading", "measured", "slow", "meditation"]
        case .conversation: return ["conversation", "conversational", "friendly", "friendly narration", "approachable"]
        case .character: return ["characters", "gaming", "playful", "dramatic", "entertainment"]
        }
    }
}

/// Metadata is a recall signal, not an acoustic quality verdict. Unknown voices
/// stay searchable; technical/experimental grades never become editorial claims.
enum VoiceDiscovery {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func features(_ voice: VoiceOption) -> Set<String> {
        let ignored: Set<String> = ["", "male", "female", "neutral", "unknown", "recommended", "en", "zh", "ga", "pro", "free"]
        return Set((voice.tags + voice.bestFor + [voice.collection ?? ""]).map(normalized)).subtracting(ignored)
    }

    static func topics(for voice: VoiceOption) -> [VoiceDiscoveryTopic] {
        let values = features(voice)
        return VoiceDiscoveryTopic.allCases.filter {
            if $0 == .focus {
                let explicit: Set<String> = ["education", "explanations", "explainers", "documentaries", "知识讲解"]
                let study: Set<String> = ["focused study", "study", "专注学习", "学习材料"]
                let clarity: Set<String> = ["clear", "crisp", "articulate", "professional", "bright", "high"]
                return !explicit.isDisjoint(with: values) || (!study.isDisjoint(with: values) && !clarity.isDisjoint(with: values))
            }
            if $0 == .gentle && !values.isDisjoint(with: ["brisk", "fast", "energetic", "intense"]) { return false }
            return !$0.keywords.isDisjoint(with: values)
        }
    }

    static func voices(in topic: VoiceDiscoveryTopic, from voices: [VoiceOption]) -> [VoiceOption] {
        voices.filter { topics(for: $0).contains(topic) }
    }

    static func searchTerms(_ voice: VoiceOption) -> String {
        let translated = styleLabels(for: voice) + topics(for: voice).flatMap { [$0.title, $0.shortTitle] }
        return normalized((translated + voice.tags + voice.bestFor).joined(separator: " "))
    }

    static let styleRules: [(Set<String>, String.LocalizationValue)] = [
        (["warm"], "温暖"), (["gentle", "soft"], "柔和"),
        (["deep", "grounded", "low"], "低沉"), (["bright", "high"], "明亮"),
        (["clear", "crisp", "articulate"], "清晰"), (["calm", "composed"], "沉稳"),
        (["conversational", "friendly", "approachable"], "亲切"),
        (["expressive", "dramatic"], "有表现力"), (["playful"], "俏皮"),
        (["energetic", "cheerful", "brisk"], "轻快"),
        (["measured", "steady", "slow"], "舒缓"), (["raspy"], "沙哑")
    ]

    static func styleLabels(for voice: VoiceOption) -> [String] {
        let values = features(voice)

        return styleRules.compactMap { $0.0.isDisjoint(with: values) ? nil : AppLocalized($0.1) }
    }

    private static func styleProfile(_ voice: VoiceOption) -> Int? {
        let values = features(voice)
        return styleRules.firstIndex { !$0.0.isDisjoint(with: values) }
    }

    static func subtitle(_ voice: VoiceOption, chinese: Bool) -> String {
        let styles = styleLabels(for: voice)
        if let purpose = purpose(for: voice) {
            return ([styles.first, purpose.shortTitle].compactMap { $0 }).joined(separator: " · ")
        }
        if !styles.isEmpty { return styles.prefix(2).joined(separator: " · ") }
        let text = (chinese ? voice.descriptionZh : voice.description)?.trimmed ?? ""
        let technical = ["解码器", "基模", "修复版", "timestamp", "decoder", "voicepack", "r109"]
        if !text.isEmpty, !technical.contains(where: { normalized(text).contains($0) }) { return text }
        if let topic = topics(for: voice).first { return topic.title }
        switch voice.gender.lowercased() {
        case "female": return AppLocalized("女声")
        case "male": return AppLocalized("男声")
        default: return AppLocalized("听听这个声音")
        }
    }

    static func purpose(for voice: VoiceOption) -> VoiceDiscoveryTopic? {
        // Explicit intended-use metadata takes precedence over timbre. A deep
        // voice is not automatically a storyteller, nor a clear voice a teacher.
        let matches = topics(for: voice)
        for use in voice.bestFor {
            if let topic = VoiceDiscoveryTopic.browseCases.first(where: { matches.contains($0) && $0.keywords.contains(normalized(use)) }) { return topic }
        }
        return VoiceDiscoveryTopic.browseCases.first { matches.contains($0) }
    }

    /// Stable, preference-aware and diverse. No usage counts or popularity are
    /// invented. Limit repeats globally in the feed, not across entire collections.
    static func recommended(_ voices: [VoiceOption], language: String,
                            favoriteIDs: Set<String> = [], recentIDs: [String] = [],
                            excluding: Set<String> = [], limit: Int = 6,
                            preferenceSource: [VoiceOption]? = nil) -> [VoiceOption] {
        let preferred = (preferenceSource ?? voices).filter { favoriteIDs.contains($0.id) || recentIDs.prefix(3).contains($0.id) }
        let preferredFeatures = preferred.reduce(into: Set<String>()) { $0.formUnion(features($1)) }
        let eligible = voices.filter {
            $0.enabled && $0.selectable && $0.supports(language) && !excluding.contains($0.id)
                && !["lab", "legacy"].contains($0.status)
                && $0.previewURL(for: language) != nil
        }
        var scored: [(voice: VoiceOption, score: Int)] = []
        for voice in eligible {
            var score = voice.recommended ? 12 : 0
            if voice.status == "ga" { score += 3 }
            score += min(6, features(voice).intersection(preferredFeatures).count * 2)
            if favoriteIDs.contains(voice.id) { score += 2 }
            scored.append((voice, score))
        }
        scored.sort { left, right in
            if left.score == right.score { return left.voice.id < right.voice.id }
            return left.score > right.score
        }
        var remaining: [VoiceOption] = scored.map { $0.voice }
        var result: [VoiceOption] = []
        var seen = Set<String>()
        while !remaining.isEmpty && result.count < limit {
            // Prefer a different profile when scores are close; never force in
            // an unavailable voice merely to balance engine or gender counts.
            let index: Int
            if let last = result.last,
               let different = remaining.prefix(8).firstIndex(where: {
                   $0.gender != last.gender || styleProfile($0) != styleProfile(last)
               }) { index = different } else { index = 0 }
            let voice = remaining.remove(at: index)
            if seen.insert(voice.id).inserted { result.append(voice) }
        }
        return result
    }
}

struct VoiceDiscoveryModule: Codable, Equatable, Identifiable {
    let id: String
    let layout: String
    let title: [String: String]
    let theme: VoiceDiscoveryTopic
    let voiceIds: [String]
    var artworkURL: String? = nil

    var localizedTitle: String {
        title[AppLanguageManager.shared.selectedLanguage.resolvedLanguageCode] ?? title["en"] ?? theme.title
    }

    func voices(from catalog: [VoiceOption], language: String) -> [VoiceOption] {
        var seen = Set<String>()
        return voiceIds.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return catalog.first { $0.id == id && $0.enabled && $0.selectable && $0.supports(language)
                && $0.previewURL(for: language) != nil && !["lab", "legacy"].contains($0.status) }
        }
    }
}

struct VoiceDiscoveryEdition: Codable, Equatable {
    let id: String
    let startsAt: String
    let endsAt: String
    let modules: [VoiceDiscoveryModule]

    func activeModules(from voices: [VoiceOption], language: String, now: Date = Date()) -> [VoiceDiscoveryModule] {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: String) -> Date? {
            if let date = parser.date(from: value) { return date }
            return ISO8601DateFormatter().date(from: value)
        }
        guard let start = date(startsAt), let end = date(endsAt), start <= now && now < end else { return [] }
        var seen = Set<String>()
        var moduleIDs = Set<String>()
        return modules.prefix(8).compactMap { module in
            guard moduleIDs.insert(module.id).inserted,
                  ["feature", "rows", "portraits"].contains(module.layout),
                  module.title["en"]?.isEmpty == false else { return nil }
            let ids = module.voices(from: voices, language: language).prefix(24)
                .map(\.id).filter { seen.insert($0).inserted }
            guard !ids.isEmpty else { return nil }
            return VoiceDiscoveryModule(id: module.id, layout: module.layout, title: module.title, theme: module.theme, voiceIds: ids, artworkURL: module.artworkURL)
        }
    }
}


/// Product storefront chooses editorial culture; reading language and service
/// routing remain independent (including route overrides in test builds).
enum VoiceEditorialRegion: String, CaseIterable {
    case cn, international
    static var current: Self { AppRegion.current == .cn ? .cn : .international }
}

struct VoiceDiscoveryCollection: Codable, Equatable, Identifiable {
    let id: String
    let title: [String: String]
    let theme: VoiceDiscoveryTopic
    let voiceIds: [String]
    var localizedTitle: String {
        title[AppLanguageManager.shared.selectedLanguage.resolvedLanguageCode] ?? title["en"] ?? theme.title
    }
    func voices(from catalog: [VoiceOption], language: String) -> [VoiceOption] {
        let indexed = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return voiceIds.prefix(2000).compactMap { id in
            guard seen.insert(id).inserted, let voice = indexed[id], voice.enabled,
                  voice.selectable, voice.supports(language) else { return nil }
            return voice
        }
    }
}

/// Listening character is a filter, separate from the purpose collections.
enum VoiceListeningStyle: String, CaseIterable, Identifiable {
    case all, gentle, grounded, bright, lively
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return AppLocalized("全部")
        case .gentle: return AppLocalized("柔和")
        case .grounded: return AppLocalized("沉稳")
        case .bright: return AppLocalized("明亮")
        case .lively: return AppLocalized("轻快")
        }
    }
    func includes(_ voice: VoiceOption) -> Bool {
        let keys: Set<String>
        switch self {
        case .all: return true
        case .gentle: keys = ["gentle", "soft", "warm", "soothing"]
        case .grounded: keys = ["grounded", "low", "deep", "calm", "measured", "steady"]
        case .bright: keys = ["bright", "high", "crisp"]
        case .lively: keys = ["brisk", "energetic", "cheerful", "playful"]
        }
        return !keys.isDisjoint(with: VoiceDiscovery.features(voice))
    }
}
