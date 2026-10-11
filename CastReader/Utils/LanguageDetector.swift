//
//  LanguageDetector.swift
//  CastReader
//
//  统一语言检测——朗读/解读选音色与 TTS language 的唯一依据，避免中文用英文音色等错配。
//  系统与本地模型均保留不支持语言，不能把候选限制成产品列表。
//  文本/文件/OCR/网页统一取证；近似语言证据不足时由文档上下文或用户确认。
//

import Foundation
import NaturalLanguage

/// Native evidence is unconstrained: excluded and neighbouring languages must remain
/// visible. Script membership alone cannot distinguish Hindi/Nepali or Arabic/Urdu.
enum LanguageDetector {
    enum Status: Equatable {
        case supported(SupportedTTSLanguage)
        case unsupported(String)
        case uncertain
    }

    struct Evidence: Equatable {
        let language: String
        let confidence: Double
        let readableCharacterCount: Int
        var candidates: [String: Double] = [:]
        var nativeCandidates: [String: Double] = [:]
        var supplementalCandidates: [String: Double] = [:]
        var embeddedTermCandidates: [String: Double] = [:]

        var status: Status {
            guard confidence >= 0.75, readableCharacterCount > 0, !language.isEmpty,
                  language != "und", language != "no" else { return .uncertain }
            if let supported = SupportedTTSLanguage(identifier: language) { return .supported(supported) }
            return .unsupported(language)
        }
    }

    static func detect(_ text: String) -> String {
        let evidence = evidence(for: text)
        switch evidence.status {
        case .supported(let language): return language.rawValue
        case .unsupported(let language): return language
        case .uncertain: return ""
        }
    }

    static func evidence(for text: String) -> Evidence {
        let sample = String(text.prefix(4000))
        let count = sample.unicodeScalars.filter { $0.properties.isAlphabetic }.count
        guard count > 0 else { return Evidence(language: "", confidence: 0, readableCharacterCount: 0) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
        var candidates: [String: Double] = [:]
        for (language, probability) in hypotheses {
            let code = SupportedTTSLanguage.normalizedIdentifier(language.rawValue)
            candidates[code] = (candidates[code] ?? 0) + probability
        }
        let result = reconcile(native: candidates, supplemental: SupplementalLanguageIdentifier.hypotheses(for: sample),
                               readableCharacterCount: count)
        guard result.status == .uncertain,
              let prose = proseAroundEmbeddedLatinTerm(sample) else { return result }
        let proseRecognizer = NLLanguageRecognizer()
        proseRecognizer.processString(prose)
        let proseModel = SupplementalLanguageIdentifier.hypotheses(for: prose)
        let proseNative = proseRecognizer.languageHypotheses(withMaximum: 2)
        // This is additional linguistic evidence, not a Han-script override.
        // Preserve Cantonese/Japanese/other candidates and the original scores.
        guard (proseNative[.simplifiedChinese] ?? 0) + (proseNative[.traditionalChinese] ?? 0) >= 0.95,
              (proseModel["zh"] ?? 0) >= 0.98 else { return result }
        return Evidence(language: "zh", confidence: proseModel["zh"]!, readableCharacterCount: count,
                        candidates: result.candidates, nativeCandidates: result.nativeCandidates,
                        supplementalCandidates: result.supplementalCandidates, embeddedTermCandidates: proseModel)
    }

    /// A short inline Latin term can dominate both classifiers in a Chinese
    /// sentence. Only reconsider a single bounded term surrounded by substantial
    /// Han prose; foreign sentences, quotations and other scripts stay intact.
    static func proseAroundEmbeddedLatinTerm(_ text: String) -> String? {
        let pattern = #"^[\p{Han}\p{N}\p{P}\p{Z}\s]+([A-Za-z][A-Za-z\- ]*[A-Za-z])[\p{Han}\p{N}\p{P}\p{Z}\s]+$"#
        guard text.count <= 240,
              !text.contains(where: { "\"“”「」『』«»".contains($0) }),
              let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let termRange = Range(match.range(at: 1), in: text) else { return nil }
        let term = text[termRange]
        guard term.split(whereSeparator: { $0 == " " || $0 == "-" }).count <= 5,
              term.count <= 60 else { return nil }
        let before = String(text[..<termRange.lowerBound])
        let after = String(text[termRange.upperBound...])
        func hanCount(_ value: String) -> Int {
            value.unicodeScalars.filter { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }.count
        }
        guard hanCount(before) >= 4, hanCount(after) >= 4,
              hanCount(before + after) >= 10,
              !before.contains(where: { "。！？.!?".contains($0) }),
              !after.dropLast().contains(where: { "。！？.!?".contains($0) }) else { return nil }
        return before + " " + after
    }

    /// The system recognizer does not distinguish all product languages. In
    /// particular its Indonesian and Bokmål scores cannot corroborate a claim
    /// against Malay or Nynorsk. No device/UI/selected-voice prior participates.
    static func reconcile(native: [String: Double], supplemental: [String: Double],
                          readableCharacterCount count: Int) -> Evidence {
        let nativeBest = native.max(by: { $0.value < $1.value })
        guard let modelBest = supplemental.max(by: { $0.value < $1.value }) else {
            // A missing/corrupt model must not restore the unsafe old guesses.
            return Evidence(language: "", confidence: 0, readableCharacterCount: count,
                            candidates: native, nativeCandidates: native)
        }
        let language = modelBest.key
        let modelScore = min(1, max(0, modelBest.value))
        let closeFamily = ["id", "ms", "nb", "nn", "da"].contains(language)
        var confidence = modelScore
        if closeFamily {
            // These labels require a clear margin from the independent model;
            // an Apple score of 1 cannot resolve a language it does not expose.
            if modelScore < 0.98 { confidence = min(confidence, 0.74) }
        } else if nativeBest?.key == language, modelScore >= 0.50 {
            confidence = (modelScore + (nativeBest?.value ?? 0)) / 2
        } else if modelScore < 0.90 {
            confidence = min(confidence, 0.74)
        }
        return Evidence(language: language, confidence: confidence, readableCharacterCount: count,
                        candidates: supplemental, nativeCandidates: native, supplementalCandidates: supplemental)
    }
}

enum SpeechTextSanitizer {
    /// Keep the live page's lexical source unchanged while making partly
    /// suffixes stable under the service's punctuation normalization. The
    /// right-hand letter is a lookahead so a-b-c is normalized in one pass.
    static func livePageRequest(_ text: String) -> String {
        var result = sanitizedForTTS(text)
        result = result.replacingOccurrences(of: #"[‐‑‒–—―−]"#, with: "-", options: .regularExpression)
        result = result.replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([\p{L}\p{N}])-+(?=[\p{L}\p{N}])"#, with: "$1 ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<=\s)-(?=\s)"#, with: "", options: .regularExpression)
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text sent to TTS must contain speakable content, not Markdown markers or visual separators.
    static func sanitizedForTTS(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        // Caption tracks use musical-note glyphs as visual line boundaries.
        // Sending them to the production TTS aligner makes otherwise complete
        // audio responses lose the final few word timestamps. Keep the glyphs
        // in the source transcript, but turn them into spoken-text boundaries.
        s = s.replacingOccurrences(
            of: #"^\s*(?:[♪♫♩♬🎵🎶]+\s*)+"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?:\s*[♪♫♩♬🎵🎶]+\s*)+"#,
            with: ". ",
            options: .regularExpression
        )

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
