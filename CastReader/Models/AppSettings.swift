//
//  AppSettings.swift
//  CastReader
//
//  全局用户设置（持久化于 UserDefaults，可观察）。语音按语言记忆，speed 免费上限 2.0。
//

import Foundation
import Combine

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
        explainLanguage = d.string(forKey: K.explainLang) ?? ""
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
