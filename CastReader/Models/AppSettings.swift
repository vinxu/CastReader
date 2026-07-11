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

    @Published private(set) var voicesByLanguage: [String: String]
    @Published var speed: Double { didSet { d.set(speed, forKey: K.speed) } }
    @Published var explainLanguage: String { didSet { d.set(explainLanguage, forKey: K.explainLang) } } // "" = 跟随原文
    @Published var explainDepth: String { didSet { d.set(explainDepth, forKey: K.explainDepth) } }
    @Published var highlightColorHex: String { didSet { d.set(highlightColorHex, forKey: K.highlightColor) } }
    @Published var autoScroll: Bool { didSet { d.set(autoScroll, forKey: K.autoScroll) } }
    @Published var autoPlay: Bool { didSet { d.set(autoPlay, forKey: K.autoPlay) } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        var storedVoices = d.dictionary(forKey: K.voicesByLanguage)?
            .compactMapValues { $0 as? String } ?? [:]
        if storedVoices["en"] == nil {
            storedVoices["en"] = d.string(forKey: K.voiceEN) ?? "af_heart"
        }
        if storedVoices["zh"] == nil {
            storedVoices["zh"] = d.string(forKey: K.voiceZH) ?? "zf_001"
        }
        voicesByLanguage = storedVoices
        d.set(storedVoices, forKey: K.voicesByLanguage)
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

    func selectedVoiceID(for language: String) -> String? {
        guard let value = voicesByLanguage[VoiceCatalog.normalizedLanguage(language)]?.trimmed,
              !value.isEmpty else { return nil }
        return value
    }

    /// 每种内容语言只读取自己的偏好；目录有该语言时由其 defaultVoice 补位。
    func voice(for language: String) -> String {
        let normalized = VoiceCatalog.normalizedLanguage(language)
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
        guard !normalized.isEmpty, !value.isEmpty else { return false }
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
        return true
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
        static let speed = "tts_speed"
        static let explainLang = "explain_language"
        static let explainDepth = "explain_depth"
        static let highlightColor = "highlight_color_hex"
        static let autoScroll = "auto_scroll"
        static let autoPlay = "auto_play"
    }
}
