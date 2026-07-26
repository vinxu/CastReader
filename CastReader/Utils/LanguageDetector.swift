//
//  LanguageDetector.swift
//  CastReader
//
//  统一语言检测——朗读/解读选音色与 TTS language 的唯一依据，避免中文用英文音色等错配。
//  对齐扩展 readout-desktop：按脚本字符（CJK/假名/谚文/拉丁）占比判定，分母只算脚本字符
//  （排除标点/空格/数字），中英混排也能正确判为中文。文本/文件/OCR/网页四种源统一调用。
//

import Foundation
import NaturalLanguage

/// iOS TTS 的产品能力边界。音色明细由服务端 catalog 驱动，但语言集合、顺序与
/// BCP-47 归一化只在这里定义，避免设置、OCR、检测和请求层各自维护一份名单。
enum SupportedTTSLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"
    case japanese = "ja"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case brazilianPortuguese = "pt"
    case italian = "it"
    case hindi = "hi"

    var id: String { rawValue }

    var localeIdentifier: String {
        switch self {
        case .english: return "en-US"
        case .chinese: return "zh-CN"
        case .japanese: return "ja-JP"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .brazilianPortuguese: return "pt-BR"
        case .italian: return "it-IT"
        case .hindi: return "hi-IN"
        }
    }

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .brazilianPortuguese: return "Português (Brasil)"
        case .italian: return "Italiano"
        case .hindi: return "हिन्दी"
        }
    }

    var catalogName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "Mandarin Chinese"
        case .japanese: return "Japanese"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .brazilianPortuguese: return "Brazilian Portuguese"
        case .italian: return "Italian"
        case .hindi: return "Hindi"
        }
    }

    var defaultVoiceID: String {
        switch self {
        case .english: return "af_heart"
        case .chinese: return "zf_001"
        case .japanese: return "jf_alpha"
        case .spanish: return "ef_dora"
        case .french: return "ff_siwis"
        case .german: return "df_mls_19"
        case .brazilianPortuguese: return "pf_dora"
        case .italian: return "if_sara"
        case .hindi: return "hf_alpha"
        }
    }

    var defaultVoiceName: String {
        switch self {
        case .english: return "Heart"
        case .chinese: return "晓萱"
        case .japanese, .hindi: return "Alpha"
        case .spanish, .brazilianPortuguese: return "Dora"
        case .french: return "Siwis"
        case .german: return "Emilia"
        case .italian: return "Sara"
        }
    }

    /// Production-verified synchronization ceiling. Runtime consumers still
    /// validate every response segment before enabling word highlighting.
    var timestampMode: String {
        self == .chinese || self == .japanese ? "segment" : "word"
    }

    /// Vision 的 OCR locale 与 TTS locale 并不完全相同。简体中文必须使用
    /// `zh-Hans`；传 `zh-CN` 会被 Vision 拒绝并在旧实现里静默退回英文。
    var visionRecognitionLanguage: String {
        self == .chinese ? "zh-Hans" : localeIdentifier
    }

    init?(identifier: String) {
        let primary = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        self.init(rawValue: primary)
    }

    static func canonicalCode(_ identifier: String, fallback: SupportedTTSLanguage = .english) -> String {
        SupportedTTSLanguage(identifier: identifier)?.rawValue ?? fallback.rawValue
    }
}

enum LanguageDetector {

    struct Evidence: Equatable {
        let language: String
        let confidence: Double
        let readableCharacterCount: Int
    }

    /// 返回九语权威目录中的主语言码。CJK/假名/天城文先按脚本确定；
    /// 拉丁字母语言交给 NaturalLanguage 在英/西/法/德/葡/意之间判别。
    static func detect(_ text: String) -> String {
        evidence(for: text).language
    }

    /// Returns both the product language and the strength of the script/language evidence.
    /// Kindle uses this to compare independent single-locale OCR passes; it must never let
    /// the first locale in one multilingual Vision request become the book authority.
    static func evidence(for text: String) -> Evidence {
        var cjk = 0, kana = 0, devanagari = 0, latin = 0
        var seen = 0
        for scalar in text.unicodeScalars {
            seen += 1
            if seen > 4000 { break }            // 取样上限，长文无需全扫
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                cjk += 1
            } else if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) {
                kana += 1
            } else if (0x0900...0x097F).contains(v) {
                devanagari += 1
            } else if scalar.properties.isAlphabetic {
                latin += 1
            }
        }
        let scripted = cjk + kana + devanagari + latin
        guard scripted > 0 else { return Evidence(language: "en", confidence: 0, readableCharacterCount: 0) }
        let total = Double(scripted)
        // 假名优先（日文正文含大量汉字，会落入 cjk；有假名即判日文）。
        if Double(kana) / total > 0.1 {
            return Evidence(language: "ja", confidence: min(1, 0.65 + Double(kana) / total), readableCharacterCount: scripted)
        }
        if Double(devanagari) / total > 0.1 {
            return Evidence(language: "hi", confidence: min(1, 0.65 + Double(devanagari) / total), readableCharacterCount: scripted)
        }
        // 中文：CJK 占脚本字符 ≥ 0.15（中英混排技术文章亦可正确判定；纯中文接近 1）。
        if Double(cjk) / total > 0.15 {
            return Evidence(language: "zh", confidence: min(1, 0.55 + Double(cjk) / total * 0.45), readableCharacterCount: scripted)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish, .french, .german, .portuguese, .italian]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let best = hypotheses.compactMap { language, probability -> (String, Double)? in
            guard let supported = SupportedTTSLanguage(identifier: language.rawValue) else { return nil }
            return (supported.rawValue, probability)
        }.max { $0.1 < $1.1 }
        guard let best else {
            return Evidence(language: SupportedTTSLanguage.english.rawValue, confidence: 0, readableCharacterCount: scripted)
        }
        return Evidence(language: best.0, confidence: best.1, readableCharacterCount: scripted)
    }
}

enum SpeechTextSanitizer {
    /// Text sent to TTS must contain speakable content, not Markdown markers or visual separators.
    static func sanitizedForTTS(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        // Keep arithmetic multiplication readable, but remove standalone Markdown/bullet/star ornaments.
        s = s.replacingOccurrences(
            of: #"(?<=\d)\s*[*＊﹡×]\s*(?=\d)"#,
            with: " times ",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?m)^\s*[*＊﹡⁕✱✲✳✴✶✷✸✹✺✻✼✽✾✿❀❁❂❃❋•◦▪▫‣⁃]\s+"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"[*＊﹡⁕✱✲✳✴✶✷✸✹✺✻✼✽✾✿❀❁❂❃❋_`~#]+"#,
            with: " ",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"[•◦▪▫‣⁃]+"#,
            with: " ",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"[\s\n]+"#,
            with: " ",
            options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsSpeakableContent(_ text: String) -> Bool {
        sanitizedForTTS(text).unicodeScalars.contains(where: isSpeakableScalar)
    }

    private static func isSpeakableScalar(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) { return true }
        if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) { return true }
        if (0xAC00...0xD7AF).contains(v) { return true }
        return scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)
    }
}
