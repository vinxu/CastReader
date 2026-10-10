import Foundation

/// Unconstrained labels from the pinned on-device classifier. Never restrict
/// hypotheses to the product's supported languages: neighbours are evidence too.
enum SupplementalLanguageIdentifier {
    static func rawHypotheses(for text: String) -> [String: Double] {
        guard let path = Bundle.main.path(forResource: "glotlid-v3-q300k", ofType: "ftz", inDirectory: "LanguageIdentification") else { return [:] }
        return NativeLanguageIdentifier.hypotheses(for: String(text.prefix(4000)), modelPath: path, count: 8)
            .mapValues(\.doubleValue)
    }

    static func hypotheses(for text: String) -> [String: Double] {
        normalized(rawHypotheses(for: text))
    }

    static func normalized(_ raw: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (label, probability) in raw where probability.isFinite && probability > 0 {
            let code = languageCode(for: label)
            result[code] = min(1, (result[code] ?? 0) + probability)
        }
        return result
    }

    static func languageCode(for label: String) -> String {
        let raw = label.replacingOccurrences(of: "__label__", with: "")
        guard let code = raw.split(separator: "_").first.map(String.init) else { return "und" }
        if code == "und" || code == "zxx" { return "und" }
        if code == "cmn" { return "zh" }
        if code == "zsm" { return "ms" }
        if code == "npi" { return "ne" }
        if code == "pes" { return "fa" }
        if code == "swh" { return "sw" }
        if code == "ekk" { return "et" }
        if code == "azj" { return "az" }
        if arabicExtlangs.contains(code) { return "ar" }
        let minimal = Locale.Language(identifier: code).minimalIdentifier
        return SupportedTTSLanguage.canonicalCode(minimal)
    }

    // IANA language-subtag registry, extlang records with Prefix: ar,
    // retrieved 2026-10-08. Do not apply the same macrolanguage collapse to
    // Malay/Indonesian, Mandarin/Cantonese or Bokmål/Nynorsk.
    // https://www.iana.org/assignments/language-subtag-registry/language-subtag-registry
    private static let arabicExtlangs: Set<String> = [
        "aao", "abh", "abv", "acm", "acq", "acw", "acx", "acy", "adf", "aeb",
        "aec", "afb", "ajp", "apc", "apd", "arb", "arq", "ars", "ary", "arz",
        "auz", "avl", "ayh", "ayl", "ayn", "ayp", "bbz", "pga", "shu", "ssh"
    ]
}
