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

    private let d = UserDefaults.standard

    @Published var voiceEN: String { didSet { d.set(voiceEN, forKey: K.voiceEN) } }
    @Published var voiceZH: String { didSet { d.set(voiceZH, forKey: K.voiceZH) } }
    @Published var speed: Double { didSet { d.set(speed, forKey: K.speed) } }
    @Published var explainLanguage: String { didSet { d.set(explainLanguage, forKey: K.explainLang) } } // "" = 跟随原文
    @Published var explainDepth: String { didSet { d.set(explainDepth, forKey: K.explainDepth) } }
    @Published var highlightColorHex: String { didSet { d.set(highlightColorHex, forKey: K.highlightColor) } }
    @Published var autoScroll: Bool { didSet { d.set(autoScroll, forKey: K.autoScroll) } }
    @Published var autoPlay: Bool { didSet { d.set(autoPlay, forKey: K.autoPlay) } }

    private init() {
        voiceEN = d.string(forKey: K.voiceEN) ?? "af_heart"
        voiceZH = d.string(forKey: K.voiceZH) ?? "zf_001"
        speed = d.object(forKey: K.speed) as? Double ?? 1.0
        explainLanguage = d.string(forKey: K.explainLang) ?? ""
        explainDepth = d.string(forKey: K.explainDepth) ?? QuickreadDepth.standard.rawValue
        highlightColorHex = d.string(forKey: K.highlightColor) ?? "#FD5F01"
        autoScroll = d.object(forKey: K.autoScroll) as? Bool ?? true
        autoPlay = d.object(forKey: K.autoPlay) as? Bool ?? true
    }

    /// 该语言当前选用的音色（zh* 用中文音色，其余英文）。
    func voice(for language: String) -> String {
        language.hasPrefix("zh") ? voiceZH : voiceEN
    }

    func setVoice(_ code: String, for language: String) {
        if language.hasPrefix("zh") { voiceZH = code } else { voiceEN = code }
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
        static let speed = "tts_speed"
        static let explainLang = "explain_language"
        static let explainDepth = "explain_depth"
        static let highlightColor = "highlight_color_hex"
        static let autoScroll = "auto_scroll"
        static let autoPlay = "auto_play"
    }
}
