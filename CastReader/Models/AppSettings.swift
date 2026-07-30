//
//  AppSettings.swift
//  CastReader
//
//  全局用户设置（持久化于 UserDefaults，可观察）。语音按语言记忆，speed 免费上限 2.0。
//

import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case brazilianPortuguese = "pt-BR"
    case italian = "it"
    case hindi = "hi"

    var id: String { rawValue }

    var bundleLocalization: String? {
        self == .system ? nil : rawValue
    }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en_US")
        case .simplifiedChinese: return Locale(identifier: "zh_CN")
        case .japanese: return Locale(identifier: "ja_JP")
        case .spanish: return Locale(identifier: "es_ES")
        case .french: return Locale(identifier: "fr_FR")
        case .german: return Locale(identifier: "de_DE")
        case .brazilianPortuguese: return Locale(identifier: "pt_BR")
        case .italian: return Locale(identifier: "it_IT")
        case .hindi: return Locale(identifier: "hi_IN")
        }
    }

    /// Keep language names self-identifying so users can always recover after
    /// selecting a language they do not read.
    var displayName: String {
        switch self {
        case .system: return AppLocalized("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .brazilianPortuguese: return "Português (Brasil)"
        case .italian: return "Italiano"
        case .hindi: return "हिन्दी"
        }
    }
}

final class AppLanguageManager: ObservableObject {
    static let shared = AppLanguageManager()

    @Published private(set) var selectedLanguage: AppLanguage
    private(set) var localizationBundle: Bundle

    private let defaults: UserDefaults
    private static let defaultsKey = "interfaceLanguage"
    private static let sharedDefaults = UserDefaults(suiteName: "group.com.same.castreader")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restoredLanguage = defaults.string(forKey: Self.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        selectedLanguage = restoredLanguage
        localizationBundle = Self.bundle(for: restoredLanguage)
        // The Share Extension runs in a different process, so `.standard`
        // cannot carry the user's in-app language choice across the target
        // boundary. Mirror only this non-sensitive preference into App Group.
        Self.sharedDefaults?.set(restoredLanguage.rawValue, forKey: Self.defaultsKey)
    }

    var locale: Locale { selectedLanguage.locale }

    func select(_ language: AppLanguage) {
        guard selectedLanguage != language else { return }
        localizationBundle = Self.bundle(for: language)
        defaults.set(language.rawValue, forKey: Self.defaultsKey)
        Self.sharedDefaults?.set(language.rawValue, forKey: Self.defaultsKey)
        selectedLanguage = language
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let localization = language.bundleLocalization,
              let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return .main
        }
        return languageBundle
    }
}

/// Runtime strings must use the selected language bundle explicitly. Foundation
/// caches localized lookups by bundle identity, so swapping Bundle.main cannot
/// reliably support multiple consecutive in-app language changes.
func AppLocalized(_ key: String.LocalizationValue) -> String {
    let language = AppLanguageManager.shared
    return String(
        localized: key,
        bundle: language.localizationBundle,
        locale: language.locale
    )
}

enum BoundLibraryOnboardingSource: String, CaseIterable, Identifiable {
    case kindle
    case weread
    case googleBooks = "google_books"
    case kobo

    var id: String { rawValue }

    var analyticsSource: AnalyticsContentSource {
        switch self {
        case .kindle: return .kindle
        case .weread: return .weread
        case .googleBooks: return .googleBooks
        case .kobo: return .kobo
        }
    }

    var analyticsFormat: AnalyticsContentFormat {
        switch self {
        case .kindle: return .kindle
        case .weread: return .weread
        case .googleBooks: return .googleBooks
        case .kobo: return .kobo
        }
    }

    var readingSourceKind: ReadingSourceKind {
        switch self {
        case .kindle: return .kindle
        case .weread: return .weread
        case .googleBooks: return .googleBooks
        case .kobo: return .kobo
        }
    }
}

/// Versioned first-use state for the mobile activation path:
///
/// choose Kindle/WeRead → bind a real shelf → open a book → listen for 30 seconds.
///
/// This store intentionally owns no WebView and no credentials. It only
/// persists semantic progress, leaving both providers' existing login/session
/// implementations untouched.
@MainActor
final class BoundLibraryOnboardingStore: ObservableObject {
    static let shared = BoundLibraryOnboardingStore()
    static let activationSeconds = 30

    @Published private(set) var selectedSource: BoundLibraryOnboardingSource?
    @Published private(set) var hasSeenChooser: Bool
    @Published private(set) var isActivated: Bool
    @Published private(set) var isChooserPresented: Bool
    @Published private(set) var activationPlaybackSeconds: Double

    private let defaults: UserDefaults
    private var lastPersistedPlaybackBucket: Int

    private enum Key {
        static let selectedSource = "boundLibraryOnboarding.v1.selectedSource"
        static let hasSeenChooser = "boundLibraryOnboarding.v1.hasSeenChooser"
        static let isActivated = "boundLibraryOnboarding.v1.isActivated"
        static let activationPlaybackSeconds = "boundLibraryOnboarding.v1.activationPlaybackSeconds"
    }

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults

        if arguments.contains("-CastReaderResetLibraryOnboarding") {
            Self.clearPersistedState(in: defaults)
        }

        let restoredSource = defaults.string(forKey: Key.selectedSource)
            .flatMap(BoundLibraryOnboardingSource.init(rawValue:))
        let restoredHasSeenChooser = defaults.bool(forKey: Key.hasSeenChooser)
        let restoredIsActivated = defaults.bool(forKey: Key.isActivated)
        let restoredPlaybackSeconds = min(
            Double(Self.activationSeconds),
            max(0, defaults.double(forKey: Key.activationPlaybackSeconds))
        )
        let skipsChooser = arguments.contains("-CastReaderSkipLibraryOnboarding")
        selectedSource = restoredSource
        hasSeenChooser = restoredHasSeenChooser
        isActivated = restoredIsActivated
        activationPlaybackSeconds = restoredPlaybackSeconds
        lastPersistedPlaybackBucket = Int(restoredPlaybackSeconds / 5)
        isChooserPresented = !skipsChooser && !restoredIsActivated && !restoredHasSeenChooser
    }

    var shouldShowReminder: Bool {
        hasSeenChooser && !isActivated
    }

    func select(_ source: BoundLibraryOnboardingSource) {
        if selectedSource != nil, selectedSource != source, !isActivated {
            activationPlaybackSeconds = 0
            lastPersistedPlaybackBucket = 0
            defaults.removeObject(forKey: Key.activationPlaybackSeconds)
        }
        selectedSource = source
        hasSeenChooser = true
        isChooserPresented = false
        defaults.set(source.rawValue, forKey: Key.selectedSource)
        defaults.set(true, forKey: Key.hasSeenChooser)
    }

    func postpone() {
        hasSeenChooser = true
        isChooserPresented = false
        defaults.set(true, forKey: Key.hasSeenChooser)
    }

    func presentChooser() {
        isChooserPresented = true
    }

    func dismissChooser() {
        isChooserPresented = false
    }

    /// Keep onboarding attribution on the real reader session, including when
    /// the user binds now but opens the first book later from the normal shelf.
    func analyticsEntryPoint(for source: BoundLibraryOnboardingSource) -> String? {
        guard hasSeenChooser, !isActivated else { return nil }
        guard selectedSource == nil || selectedSource == source else { return nil }
        return "library_onboarding"
    }

    /// Accumulate a player's positive, natural playback tick. Deltas above the
    /// threshold are rejected as seeks. This lives above an individual
    /// ReadAloudViewModel because Kindle swaps VMs at page boundaries; a
    /// 12-second page plus an 18-second page must still complete the same
    /// 30-second activation.
    func recordPlayback(source: ReadingSourceKind, seconds: Double) {
        guard !isActivated, seconds > 0, seconds <= 2.01 else { return }
        let playbackSource: BoundLibraryOnboardingSource
        switch source {
        case .kindle: playbackSource = .kindle
        case .weread: playbackSource = .weread
        case .googleBooks: playbackSource = .googleBooks
        case .kobo: playbackSource = .kobo
        default: return
        }
        guard selectedSource == nil || selectedSource == playbackSource else { return }

        if selectedSource == nil {
            selectedSource = playbackSource
            defaults.set(playbackSource.rawValue, forKey: Key.selectedSource)
        }
        hasSeenChooser = true
        defaults.set(true, forKey: Key.hasSeenChooser)

        activationPlaybackSeconds = min(
            Double(Self.activationSeconds),
            activationPlaybackSeconds + seconds
        )
        let persistenceBucket = Int(activationPlaybackSeconds / 5)
        if persistenceBucket > lastPersistedPlaybackBucket {
            lastPersistedPlaybackBucket = persistenceBucket
            defaults.set(
                activationPlaybackSeconds,
                forKey: Key.activationPlaybackSeconds
            )
        }

        guard activationPlaybackSeconds >= Double(Self.activationSeconds) else { return }
        completeActivation(source: playbackSource)
    }

    /// Deterministic helper for tests and migrations that already hold a trusted
    /// cumulative playback total.
    func markActivatedIfNeeded(source: ReadingSourceKind, playbackSeconds: Int) {
        guard playbackSeconds >= Self.activationSeconds else { return }
        let playbackSource: BoundLibraryOnboardingSource
        switch source {
        case .kindle: playbackSource = .kindle
        case .weread: playbackSource = .weread
        case .googleBooks: playbackSource = .googleBooks
        case .kobo: playbackSource = .kobo
        default: return
        }
        guard selectedSource == nil || selectedSource == playbackSource else { return }
        activationPlaybackSeconds = Double(Self.activationSeconds)
        completeActivation(source: playbackSource)
    }

    private func completeActivation(source: BoundLibraryOnboardingSource) {
        guard !isActivated else { return }
        selectedSource = source
        hasSeenChooser = true
        isActivated = true
        isChooserPresented = false
        activationPlaybackSeconds = Double(Self.activationSeconds)
        lastPersistedPlaybackBucket = Self.activationSeconds / 5
        defaults.set(source.rawValue, forKey: Key.selectedSource)
        defaults.set(true, forKey: Key.hasSeenChooser)
        defaults.set(true, forKey: Key.isActivated)
        defaults.set(activationPlaybackSeconds, forKey: Key.activationPlaybackSeconds)
    }

    /// Available to the DEBUG settings screen and deterministic UI tests.
    func reset() {
        Self.clearPersistedState(in: defaults)
        selectedSource = nil
        hasSeenChooser = false
        isActivated = false
        isChooserPresented = true
        activationPlaybackSeconds = 0
        lastPersistedPlaybackBucket = 0
    }

    private static func clearPersistedState(in defaults: UserDefaults) {
        defaults.removeObject(forKey: Key.selectedSource)
        defaults.removeObject(forKey: Key.hasSeenChooser)
        defaults.removeObject(forKey: Key.isActivated)
        defaults.removeObject(forKey: Key.activationPlaybackSeconds)
    }
}

extension ShareInboxRecord {
    /// Persist semantic fallback intent, not a translated string. Real titles
    /// remain untouched; generated placeholders follow every in-app language
    /// change, including records created by the Share Extension.
    var localizedDisplayTitle: String {
        let semanticFallback: ShareInboxFallbackTitle?
        if let fallbackTitle {
            semanticFallback = fallbackTitle
        } else {
            // Records saved before semantic fallbacks were introduced contain
            // one of these already-translated placeholders.
            switch kind {
            case .image:
                semanticFallback = Self.legacyImageTitles.contains(title) ? .image : nil
            case .text:
                semanticFallback = Self.legacyTextTitles.contains(title) ? .text : nil
            case .pdf, .epub, .docx:
                semanticFallback = Self.legacyDocumentTitles.contains(title) ? .document : nil
            case .url:
                semanticFallback = nil
            }
        }
        switch semanticFallback {
        case .document: return AppLocalized("文档")
        case .text: return AppLocalized("文本")
        case .image: return AppLocalized("图片")
        case nil: return title
        }
    }

    private static let legacyDocumentTitles: Set<String> = [
        "Shared document", "分享的文档", "共有ドキュメント", "Documento compartido",
        "Document partagé", "Geteiltes Dokument", "Documento compartilhado",
        "Documento condiviso", "साझा दस्तावेज़",
    ]
    private static let legacyTextTitles: Set<String> = [
        "Shared text", "分享的文本", "共有テキスト", "Texto compartido", "Texte partagé",
        "Geteilter Text", "Texto compartilhado", "Testo condiviso", "साझा किया गया टेक्स्ट",
    ]
    private static let legacyImageTitles: Set<String> = [
        "Shared image", "分享的图片", "共有画像", "Imagen compartida", "Image partagée",
        "Geteiltes Bild", "Imagem compartilhada", "Immagine condivisa", "साझा की गई छवि",
    ]
}

extension Notification.Name {
    static let castReaderPlaybackVoiceWillSwitch = Notification.Name("castReaderPlaybackVoiceWillSwitch")
}

struct VoiceSwitchProgress: Equatable, Identifiable {
    let id: UUID
    let language: String
    let fromVoiceID: String
    let toVoiceID: String
    let fromVoiceName: String
    let toVoiceName: String
    let startedAt: Date

    var localizedMessage: String {
        String(
            format: AppLocalized("正在切换音色：%@ → %@"),
            fromVoiceName,
            toVoiceName
        )
    }
}

/// One global, observable transaction for an in-flight playback voice handoff.
/// The player, Kindle controls and voice browser all observe the same value, so
/// a selection can never look like a no-op while new audio is being prepared.
@MainActor
final class VoiceSwitchStatusCenter: ObservableObject {
    static let shared = VoiceSwitchStatusCenter()

    @Published private(set) var progress: VoiceSwitchProgress?
    private let minimumVisibleDuration: TimeInterval = 0.65

    private init() {}

    @discardableResult
    func begin(language: String, from oldVoiceID: String, to newVoiceID: String) -> UUID {
        let id = UUID()
        progress = VoiceSwitchProgress(
            id: id,
            language: VoiceCatalog.normalizedLanguage(language),
            fromVoiceID: oldVoiceID,
            toVoiceID: newVoiceID,
            fromVoiceName: Self.displayName(for: oldVoiceID),
            toVoiceName: Self.displayName(for: newVoiceID),
            startedAt: Date()
        )
        return id
    }

    func finish(_ id: UUID) {
        guard let current = progress, current.id == id else { return }
        let delay = max(0, minimumVisibleDuration - Date().timeIntervalSince(current.startedAt))
        guard delay > 0.01 else {
            progress = nil
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self?.progress?.id == id else { return }
            self?.progress = nil
        }
    }

    private static func displayName(for voiceID: String) -> String {
        if let option = VoiceCatalog.option(for: voiceID) { return option.name }
        if let clone = VoiceCloneStore.shared.voices.first(where: { $0.voiceId == voiceID }) {
            return VoiceCloneStore.shared.displayName(for: clone)
        }
        return voiceID
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 免费用户最大语速
    static let freeMaxSpeed: Double = 2.0
    static let maxSpeed: Double = 3.0
    static let minSpeed: Double = 0.5

    private let d: UserDefaults
    private let voiceCloningEnabled: Bool

    @Published private(set) var voicesByLanguage: [String: String]
    @Published private(set) var clonedVoicesByLanguage: [String: String]
    @Published var speed: Double { didSet { d.set(speed, forKey: K.speed) } }
    @Published var explainLanguage: String { didSet { d.set(explainLanguage, forKey: K.explainLang) } } // "" = 跟随原文
    @Published var explainDepth: String { didSet { d.set(explainDepth, forKey: K.explainDepth) } }
    @Published var highlightColorHex: String { didSet { d.set(highlightColorHex, forKey: K.highlightColor) } }
    @Published var autoScroll: Bool { didSet { d.set(autoScroll, forKey: K.autoScroll) } }
    @Published var autoPlay: Bool { didSet { d.set(autoPlay, forKey: K.autoPlay) } }

    init(
        defaults: UserDefaults = .standard,
        voiceCloningEnabled: Bool = Constants.Features.voiceCloningEnabled
    ) {
        d = defaults
        self.voiceCloningEnabled = voiceCloningEnabled
        var storedVoices = d.dictionary(forKey: K.voicesByLanguage)?
            .compactMapValues { $0 as? String } ?? [:]
        if storedVoices["en"] == nil {
            storedVoices["en"] = d.string(forKey: K.voiceEN) ?? "af_heart"
        }
        if storedVoices["zh"] == nil {
            storedVoices["zh"] = d.string(forKey: K.voiceZH) ?? "zf_001"
        }
        voicesByLanguage = storedVoices
        var storedClones = d.dictionary(forKey: K.clonedVoicesByLanguage)?
            .compactMapValues { $0 as? String }
            .filter { !$0.key.isEmpty && $0.value.hasPrefix("vc_") } ?? [:]
        let legacyClone = d.string(forKey: K.activeClonedVoice)?.trimmed ?? ""
        if storedClones.isEmpty, legacyClone.hasPrefix("vc_") {
            // The old contract made one clone global. Preserve that behavior for the two
            // currently supported product languages, then move to language-scoped storage.
            storedClones["en"] = legacyClone
            storedClones["zh"] = legacyClone
        }
        clonedVoicesByLanguage = storedClones
        d.set(storedVoices, forKey: K.voicesByLanguage)
        d.set(storedClones, forKey: K.clonedVoicesByLanguage)
        d.removeObject(forKey: K.activeClonedVoice)
        speed = d.object(forKey: K.speed) as? Double ?? 1.0
        let storedExplainLanguage = d.string(forKey: K.explainLang) ?? ""
        explainLanguage = storedExplainLanguage.isEmpty
            ? ""
            : (SupportedTTSLanguage(identifier: storedExplainLanguage)?.rawValue ?? "")
        explainDepth = d.string(forKey: K.explainDepth) ?? QuickreadDepth.standard.rawValue
        highlightColorHex = d.string(forKey: K.highlightColor) ?? "#FD5F01"
        autoScroll = d.object(forKey: K.autoScroll) as? Bool ?? true
        autoPlay = d.object(forKey: K.autoPlay) as? Bool ?? true
    }

    /// 旧调用方兼容属性；真实存储已经迁移为按语言字典。
    var voiceEN: String {
        get { selectedVoiceID(for: "en") ?? "af_heart" }
        set { _ = setVoice(newValue, for: "en") }
    }

    var voiceZH: String {
        get { selectedVoiceID(for: "zh") ?? "zf_001" }
        set { _ = setVoice(newValue, for: "zh") }
    }

    /// Compatibility for older UI: only non-nil when every active language uses one clone.
    var activeClonedVoiceId: String? {
        guard voiceCloningEnabled else { return nil }
        let values = Set(clonedVoicesByLanguage.values)
        return values.count == 1 ? values.first : nil
    }

    var activeClonedVoiceIDs: Set<String> {
        guard voiceCloningEnabled else { return [] }
        return Set(clonedVoicesByLanguage.values)
    }

    func selectedVoiceID(for language: String) -> String? {
        guard let value = voicesByLanguage[VoiceCatalog.normalizedLanguage(language)]?.trimmed,
              !value.isEmpty else { return nil }
        return value
    }

    /// 每种内容语言只读取自己的偏好；目录有该语言时由其 defaultVoice 补位。
    func voice(for language: String) -> String {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        if let clone = activeClonedVoiceID(for: normalized) { return clone }
        var preferred = selectedVoiceID(for: normalized) ?? ""
        if let option = VoiceCatalog.option(for: preferred),
           VoiceCatalog.normalizedLanguage(option.lang) != normalized {
            preferred = ""
        }
        return VoiceCatalog.resolvedVoice(preferred: preferred, for: language)
    }

    /// 返回 false 表示拒绝跨语言或无效偏好，调用方不得展示为已选。
    @discardableResult
    func setVoice(_ code: String, for language: String) -> Bool {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        let value = code.trimmed
        guard !normalized.isEmpty, !value.isEmpty, !value.hasPrefix("vc_") else { return false }
        if let option = VoiceCatalog.option(for: value),
           VoiceCatalog.normalizedLanguage(option.lang) != normalized {
            return false
        }

        var next = voicesByLanguage
        next[normalized] = value
        voicesByLanguage = next
        d.set(next, forKey: K.voicesByLanguage)
        if normalized == "en" { d.set(value, forKey: K.voiceEN) }
        if normalized == "zh" { d.set(value, forKey: K.voiceZH) }
        clearActiveClonedVoice(for: normalized)
        return true
    }

    @discardableResult
    func setActiveClonedVoice(_ voiceID: String, for language: String) -> Bool {
        guard voiceCloningEnabled else { return false }
        let value = voiceID.trimmed
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard value.hasPrefix("vc_"), value.count > 3, !normalized.isEmpty else { return false }
        var next = clonedVoicesByLanguage
        next[normalized] = value
        clonedVoicesByLanguage = next
        d.set(next, forKey: K.clonedVoicesByLanguage)
        return true
    }

    /// Legacy helper retained for callers that intentionally apply one clone to both languages.
    @discardableResult
    func setActiveClonedVoice(_ voiceID: String) -> Bool {
        let english = setActiveClonedVoice(voiceID, for: "en")
        let chinese = setActiveClonedVoice(voiceID, for: "zh")
        return english && chinese
    }

    func activeClonedVoiceID(for language: String) -> String? {
        guard voiceCloningEnabled else { return nil }
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard let value = clonedVoicesByLanguage[normalized], value.hasPrefix("vc_") else { return nil }
        return value
    }

    func clearActiveClonedVoice(for language: String, ifMatching voiceID: String? = nil) {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard !normalized.isEmpty else { return }
        if let voiceID, clonedVoicesByLanguage[normalized] != voiceID { return }
        var next = clonedVoicesByLanguage
        next.removeValue(forKey: normalized)
        clonedVoicesByLanguage = next
        d.set(next, forKey: K.clonedVoicesByLanguage)
    }

    func clearActiveClonedVoice(ifMatching voiceID: String? = nil) {
        let next = clonedVoicesByLanguage.filter { _, value in
            guard let voiceID else { return false }
            return value != voiceID
        }
        guard next != clonedVoicesByLanguage else { return }
        clonedVoicesByLanguage = next
        d.set(next, forKey: K.clonedVoicesByLanguage)
    }

    /// 讲解语言：空串表示跟随原文（请求里传 nil）。
    var explainLangOrNil: String? {
        explainLanguage.isEmpty ? nil : explainLanguage
    }

    /// 在给定 Pro 状态下夹取语速（免费上限 2.0）。
    func effectiveSpeed(isPro: Bool) -> Double {
        let cap = isPro ? Self.maxSpeed : Self.freeMaxSpeed
        return min(max(speed, Self.minSpeed), cap)
    }

    private enum K {
        static let voiceEN = "voice_en"
        static let voiceZH = "voice_zh"
        static let voicesByLanguage = "tts_voice_by_language_v1"
        static let activeClonedVoice = "active_cloned_voice_id_v1"
        static let clonedVoicesByLanguage = "active_cloned_voice_by_language_v2"
        static let speed = "tts_speed"
        static let explainLang = "explain_language"
        static let explainDepth = "explain_depth"
        static let highlightColor = "highlight_color_hex"
        static let autoScroll = "auto_scroll"
        static let autoPlay = "auto_play"
    }
}
