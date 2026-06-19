//
//  VoiceCatalog.swift
//  CastReader
//
//  Kokoro 音色清单（对齐扩展 voices.ts）。免费 vs Pro 由 isPro 标记，闸门在选择处执行。
//

import Foundation

struct VoiceOption: Identifiable, Equatable, Hashable {
    let code: String       // 如 "af_heart"
    let name: String       // 展示名
    let isPro: Bool
    let lang: String       // "en" / "zh"
    let gender: String     // "female" / "male"

    var id: String { code }
}

enum VoiceCatalog {

    // 英文（Kokoro v1.1）
    static let english: [VoiceOption] = [
        .init(code: "af_heart", name: "Heart", isPro: false, lang: "en", gender: "female"),
        .init(code: "af_bella", name: "Bella", isPro: false, lang: "en", gender: "female"),
        .init(code: "bf_emma",  name: "Emma (UK)", isPro: false, lang: "en", gender: "female"),
        .init(code: "am_adam",  name: "Adam", isPro: false, lang: "en", gender: "male"),
        .init(code: "af_nova",  name: "Nova", isPro: true, lang: "en", gender: "female"),
        .init(code: "af_sky",   name: "Sky", isPro: true, lang: "en", gender: "female"),
        .init(code: "am_eric",  name: "Eric", isPro: true, lang: "en", gender: "male"),
        .init(code: "bm_george", name: "George (UK)", isPro: true, lang: "en", gender: "male"),
    ]

    // 中文（Kokoro v1.1-zh）
    static let chinese: [VoiceOption] = [
        .init(code: "zf_001", name: "晓萱", isPro: false, lang: "zh", gender: "female"),
        .init(code: "zm_009", name: "云泽", isPro: false, lang: "zh", gender: "male"),
        .init(code: "zf_017", name: "晓雅", isPro: true, lang: "zh", gender: "female"),
        .init(code: "zf_027", name: "晓柔", isPro: true, lang: "zh", gender: "female"),
        .init(code: "zf_046", name: "晓悦", isPro: true, lang: "zh", gender: "female"),
        .init(code: "zf_079", name: "晓晴", isPro: true, lang: "zh", gender: "female"),
        .init(code: "zm_029", name: "云朗", isPro: true, lang: "zh", gender: "male"),
        .init(code: "zm_033", name: "云辰", isPro: true, lang: "zh", gender: "male"),
        .init(code: "zm_095", name: "云谦", isPro: true, lang: "zh", gender: "male"),
        .init(code: "zm_098", name: "云瀚", isPro: true, lang: "zh", gender: "male"),
    ]

    static let all: [VoiceOption] = english + chinese

    /// 某语言可选音色列表（zh* 走中文，其余走英文）。
    static func voices(for language: String) -> [VoiceOption] {
        language.hasPrefix("zh") ? chinese : english
    }

    static func option(for code: String) -> VoiceOption? {
        all.first { $0.code == code }
    }

    static func displayName(for code: String) -> String {
        option(for: code)?.name ?? code
    }

    static func isFree(_ code: String) -> Bool {
        option(for: code)?.isPro == false
    }

    /// 该语言的免费默认音色（用于被锁 Pro 音色时回退）。
    static func defaultFreeVoice(for language: String) -> String {
        voices(for: language).first { !$0.isPro }?.code ?? Constants.TTS.defaultVoice
    }
}
