import Foundation
import CoreFoundation

enum VoiceCloneLanguageSupport {
    static let all = ["de", "en", "es", "fr", "it", "ja", "ko", "pt", "ru", "zh"]

    static func languages(for voice: ClonedVoice) -> [String] {
        let values = voice.supportedLanguages.isEmpty ? all : voice.supportedLanguages
        return Array(Set(values.map(VoiceCatalog.normalizedLanguage)))
            .filter { all.contains($0) }
            .sorted()
    }
}

enum VoiceCloneRecordingPrompt {
    /// Languages that can be selected explicitly while recording. Keep this
    /// independent from output-language support: the recording language only
    /// describes the sample the user is about to speak.
    static let selectableLanguages = ["zh", "en", "ja", "es", "fr", "de", "pt", "it", "hi"]

    static func languageCode(
        for selection: AppLanguage,
        systemLanguageCode: String? = nil
    ) -> String {
        let raw: String
        if selection == .system {
            raw = systemLanguageCode
                ?? Locale.autoupdatingCurrent.language.languageCode?.identifier
                ?? "en"
        } else {
            raw = selection.rawValue
        }
        let normalized = VoiceCatalog.normalizedLanguage(raw)
        return scripts[normalized] == nil ? "en" : normalized
    }

    static func text(for language: String) -> String {
        scripts[VoiceCatalog.normalizedLanguage(language)] ?? scripts["en"]!
    }

    static func displayName(for language: String, locale: Locale) -> String {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        return locale.localizedString(forLanguageCode: normalized)
            ?? normalized.uppercased()
    }

    private static let scripts: [String: String] = [
        "zh": "我最喜欢的事情就是学习啦，我每天都会看书，学各种知识，希望变得更聪明！",
        "en": "My favorite thing is learning. I read every day, discover new ideas, and hope to understand the world a little better.",
        "ja": "私が一番好きなことは学ぶことです。毎日本を読んで新しい知識に触れ、世界のことをもっと深く理解したいと思っています。",
        "es": "Lo que más me gusta es aprender. Leo todos los días, descubro ideas nuevas y espero comprender el mundo un poco mejor.",
        "fr": "Ce que j’aime le plus, c’est apprendre. Je lis chaque jour, je découvre de nouvelles idées et j’espère mieux comprendre le monde.",
        "de": "Am liebsten lerne ich neue Dinge. Ich lese jeden Tag, entdecke neue Ideen und möchte die Welt ein wenig besser verstehen.",
        "pt": "O que eu mais gosto é aprender. Leio todos os dias, descubro novas ideias e espero compreender o mundo um pouco melhor.",
        "it": "La cosa che amo di più è imparare. Leggo ogni giorno, scopro nuove idee e spero di capire un po’ meglio il mondo.",
        "hi": "मुझे नई चीज़ें सीखना सबसे अच्छा लगता है। मैं हर दिन पढ़ता हूँ, नए विचार खोजता हूँ और दुनिया को थोड़ा बेहतर समझने की कोशिश करता हूँ।",
    ]
}

enum VoiceCloneCreationSubmissionOutcome: Equatable {
    case completed
    case retryOriginalRecording

    init(succeeded: Bool) {
        self = succeeded ? .completed : .retryOriginalRecording
    }
}

enum VoiceCloneQualityMessage {
    static func localized(for code: String?) -> String? {
        switch code?.uppercased() {
        case "VOICE_REFERENCE_INVALID", "VOICE_REFERENCE_SAMPLE_RATE_UNSUPPORTED":
            return AppLocalized("录音文件无效，请重新录制")
        case "VOICE_REFERENCE_DURATION_INVALID":
            return AppLocalized("请录制 3 到 30 秒的声音")
        case "VOICE_REFERENCE_NO_SPEECH":
            return AppLocalized("没有检测到清晰人声，请在安静环境中重新录制")
        case "VOICE_REFERENCE_SPEECH_TOO_SHORT":
            return AppLocalized("有效讲话时间太短，请连续清晰说话至少 3 秒")
        case "VOICE_REFERENCE_TOO_MUCH_SILENCE":
            return AppLocalized("录音中的静音太多，请按住后尽快开始说话")
        case "VOICE_REFERENCE_TOO_QUIET":
            return AppLocalized("声音太小，请靠近手机并重新录制")
        case "VOICE_REFERENCE_CLIPPING":
            return AppLocalized("声音过大并出现失真，请稍微远离手机重新录制")
        case "VOICE_REFERENCE_TOO_NOISY":
            return AppLocalized("环境噪声太大，请换到更安静的地方重新录制")
        case "VOICE_REFERENCE_TOO_REVERBERANT":
            return AppLocalized("房间回声太重，请靠近手机并换到较小、柔软的空间录制")
        case "VOICE_REFERENCE_MULTIPLE_SPEAKERS":
            return AppLocalized("录音中可能有多人说话，请确保只有本人说话")
        case "VOICE_REFERENCE_TEXT_MISMATCH":
            return AppLocalized("声音服务仍在更新。录音已保留，请稍后重试")
        case "REFERENCE_LANGUAGE_UNSUPPORTED", "VOICE_REFERENCE_LANGUAGE_UNSUPPORTED":
            return AppLocalized("暂不支持所选录音语言，请选择其他语言")
        default:
            return nil
        }
    }
}

struct VoiceCloneAvatarPresentation: Equatable, Codable {
    enum Glyph: String, Equatable, Codable {
        case waveBars = "wave-bars"
        case wavePulse = "wave-pulse"
        case waveOrbit = "wave-orbit"
        case waveRipple = "wave-ripple"
    }

    let styleVersion: String
    let backgroundStart: String
    let backgroundEnd: String
    let foreground: String
    let glyph: Glyph

    var isSupported: Bool {
        styleVersion == "v1"
            && Self.isHexColor(backgroundStart)
            && Self.isHexColor(backgroundEnd)
            && Self.isHexColor(foreground)
    }

    private static func isHexColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes.first == 0x23 else { return false }
        return bytes.dropFirst().allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x46).contains($0)
                || (0x61...0x66).contains($0)
        }
    }
}

struct VoiceCloneIdentity: Equatable, Codable {
    enum NameMode: String, Equatable, Codable {
        case auto
        case custom
    }

    let schemaVersion: String
    let nameMode: NameMode
    let autoNameIndex: Int
    let customName: String?
    let avatarToken: String
    let avatar: VoiceCloneAvatarPresentation
    let revision: Int

    var isSupported: Bool {
        let tokenBytes = Array(avatarToken.utf8)
        let validToken = tokenBytes.count == 15
            && tokenBytes.prefix(3).elementsEqual([0x76, 0x31, 0x3A])
            && tokenBytes.dropFirst(3).allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
        let validNameMode: Bool
        switch nameMode {
        case .auto:
            validNameMode = customName == nil
        case .custom:
            if let customName,
               let normalized = try? VoiceCloneNameValidator.normalized(customName) {
                validNameMode = normalized == customName
            } else {
                validNameMode = false
            }
        }
        return schemaVersion == "v1"
            && autoNameIndex > 0
            && autoNameIndex <= Int(Int32.max)
            && revision > 0
            && revision <= Int(Int32.max)
            && validToken
            && validNameMode
            && avatar.isSupported
    }

    func matchesRequestedName(_ normalizedName: String?) -> Bool {
        switch (nameMode, normalizedName) {
        case (.auto, nil):
            return customName == nil
        case (.custom, .some(let value)):
            return customName == value
        default:
            return false
        }
    }
}

enum VoiceCloneNameValidator {
    static let maximumGraphemes = 40
    static let maximumUnicodeScalars = 1_024
    static let maximumExpectedRevision = 2_147_483_646

    /// Matches ECMAScript String.prototype.trim, which is the canonical Web
    /// and backend normalization contract. Foundation differs for U+200B and
    /// U+FEFF, so using `.whitespacesAndNewlines` would make identities valid
    /// on one client but disappear on another.
    private static let canonicalTrimCharacters: CharacterSet = {
        let codePoints = [
            0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0,
            0x1680,
            0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
            0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
            0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
        ]
        var characters = CharacterSet()
        for codePoint in codePoints {
            if let scalar = UnicodeScalar(codePoint) {
                characters.insert(charactersIn: String(scalar))
            }
        }
        return characters
    }()

    static func normalized(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: canonicalTrimCharacters)
        guard !normalized.isEmpty else {
            throw VoiceCloneError.identityInvalid(AppLocalized("声音名称不能为空"))
        }
        let containsForbiddenScalar = normalized.unicodeScalars.contains { scalar in
            let value = scalar.value
            return value <= 0x1F
                || (0x7F...0x9F).contains(value)
                || value == 0x2028
                || value == 0x2029
        }
        guard !containsForbiddenScalar else {
            throw VoiceCloneError.identityInvalid(AppLocalized("声音名称不能包含换行或控制字符"))
        }
        guard normalized.count <= maximumGraphemes,
              normalized.unicodeScalars.count <= maximumUnicodeScalars else {
            throw VoiceCloneError.identityInvalid(String(
                format: AppLocalized("声音名称不能超过 %lld 个字符"),
                Int64(maximumGraphemes)
            ))
        }
        return normalized
    }
}

struct ClonedVoice: Identifiable, Equatable, Decodable {
    let voiceId: String
    let createdAt: String?
    let sampleURL: String?
    let status: String?
    let previewStatus: String?
    let previewDurationMs: Int?
    let referenceLanguage: String?
    let supportedLanguages: [String]
    let identity: VoiceCloneIdentity?

    var id: String { voiceId }

    init(
        voiceId: String,
        createdAt: String? = nil,
        sampleURL: String? = nil,
        status: String? = nil,
        previewStatus: String? = nil,
        previewDurationMs: Int? = nil,
        referenceLanguage: String? = nil,
        supportedLanguages: [String] = [],
        identity: VoiceCloneIdentity? = nil
    ) {
        self.voiceId = voiceId
        self.createdAt = createdAt
        self.sampleURL = sampleURL
        self.status = status
        self.previewStatus = previewStatus
        self.previewDurationMs = previewDurationMs
        self.referenceLanguage = referenceLanguage
        self.supportedLanguages = supportedLanguages
        self.identity = identity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedVoiceID = try container.decodeIfPresent(String.self, forKey: .voiceId)
            ?? container.decodeIfPresent(String.self, forKey: .voiceIdSnake)
            ?? container.decodeIfPresent(String.self, forKey: .id) else {
            throw DecodingError.dataCorruptedError(forKey: .voiceId, in: container, debugDescription: "Missing voice id")
        }
        voiceId = decodedVoiceID
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? container.decodeIfPresent(String.self, forKey: .createdAtSnake)
        sampleURL = try container.decodeIfPresent(String.self, forKey: .sampleUrl)
            ?? container.decodeIfPresent(String.self, forKey: .sampleUrlSnake)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        previewStatus = try container.decodeIfPresent(String.self, forKey: .previewStatus)
            ?? container.decodeIfPresent(String.self, forKey: .previewStatusSnake)
        previewDurationMs = try container.decodeIfPresent(Int.self, forKey: .previewDurationMs)
            ?? container.decodeIfPresent(Int.self, forKey: .previewDurationMsSnake)
        referenceLanguage = try container.decodeIfPresent(String.self, forKey: .referenceLanguage)
            ?? container.decodeIfPresent(String.self, forKey: .referenceLanguageSnake)
        supportedLanguages = try container.decodeIfPresent([String].self, forKey: .supportedLanguages)
            ?? container.decodeIfPresent([String].self, forKey: .supportedLanguagesSnake)
            ?? []
        let decodedIdentity = try? container.decode(VoiceCloneIdentity.self, forKey: .identity)
        identity = decodedIdentity?.isSupported == true ? decodedIdentity : nil
    }

    func replacingIdentity(_ identity: VoiceCloneIdentity?) -> ClonedVoice {
        ClonedVoice(
            voiceId: voiceId,
            createdAt: createdAt,
            sampleURL: sampleURL,
            status: status,
            previewStatus: previewStatus,
            previewDurationMs: previewDurationMs,
            referenceLanguage: referenceLanguage,
            supportedLanguages: supportedLanguages,
            identity: identity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case voiceId, id, createdAt, sampleUrl, status, previewStatus, previewDurationMs, referenceLanguage, supportedLanguages, identity
        case voiceIdSnake = "voice_id"
        case createdAtSnake = "created_at"
        case sampleUrlSnake = "sample_url"
        case previewStatusSnake = "preview_status"
        case previewDurationMsSnake = "preview_duration_ms"
        case referenceLanguageSnake = "reference_language"
        case supportedLanguagesSnake = "supported_languages"
    }
}

struct VoiceCloneCapability: Equatable {
    var canCreate: Bool?
    var freeCreationConsumed: Bool?
    var canApply: Bool?
    var monthlyLimitSeconds: Int?
    var monthlyUsedSeconds: Int?
    var monthlyRemainingSeconds: Int?
    var resetAt: Date?

    static let unknown = VoiceCloneCapability()

    var quotaIsExhausted: Bool {
        guard let monthlyRemainingSeconds else { return false }
        return monthlyRemainingSeconds <= 0 && (resetAt == nil || resetAt! > Date())
    }
}

/// A presentation-safe snapshot of the monthly cloned-voice allowance.
/// The service can briefly return only `used` or `remaining` during an
/// entitlement refresh, so the missing side is derived without inventing
/// usage when neither counter is available.
struct VoiceCloneQuotaPresentation: Equatable {
    static let proMonthlyLimitSeconds = 120 * 60

    let limitSeconds: Int
    let usedSeconds: Int?
    let remainingSeconds: Int?
    let resetAt: Date?

    init(capability: VoiceCloneCapability, now: Date = Date()) {
        let limit = max(
            1,
            capability.monthlyLimitSeconds ?? Self.proMonthlyLimitSeconds
        )
        limitSeconds = limit
        resetAt = capability.resetAt

        if let resetAt = capability.resetAt,
           resetAt <= now,
           capability.monthlyRemainingSeconds == 0 {
            usedSeconds = 0
            remainingSeconds = limit
            return
        }

        if let used = capability.monthlyUsedSeconds {
            let clampedUsed = min(limit, max(0, used))
            usedSeconds = clampedUsed
            remainingSeconds = min(
                limit,
                max(
                    0,
                    capability.monthlyRemainingSeconds
                        ?? (limit - clampedUsed)
                )
            )
        } else if let remaining = capability.monthlyRemainingSeconds {
            let clampedRemaining = min(limit, max(0, remaining))
            usedSeconds = limit - clampedRemaining
            remainingSeconds = clampedRemaining
        } else {
            usedSeconds = nil
            remainingSeconds = nil
        }
    }

    var progress: Double? {
        guard let usedSeconds else { return nil }
        return min(1, max(0, Double(usedSeconds) / Double(limitSeconds)))
    }
}

struct VoiceCloneListResult: Equatable {
    let voices: [ClonedVoice]
    let nextCreateAt: Date?
    let capability: VoiceCloneCapability

    init(
        voices: [ClonedVoice],
        nextCreateAt: Date?,
        capability: VoiceCloneCapability = .unknown
    ) {
        self.voices = voices
        self.nextCreateAt = nextCreateAt
        self.capability = capability
    }
}

enum VoiceCloneResponseParser {
    static func isVoiceNotFound(statusCode: Int, data: Data) -> Bool {
        statusCode == 404 && serverCode(from: data)?.uppercased() == "VOICE_NOT_FOUND"
    }

    static func list(from data: Data) throws -> VoiceCloneListResult {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] {
            return VoiceCloneListResult(voices: decodeVoices(array), nextCreateAt: nil)
        }
        guard let root = object as? [String: Any] else { throw VoiceCloneError.invalidResponse }
        let payload = (root["data"] as? [String: Any]) ?? root
        let rawVoices = (payload["voices"] as? [[String: Any]])
            ?? (root["voices"] as? [[String: Any]])
            ?? []
        let creation = payload["creation"] as? [String: Any]
        let usage = payload["usage"] as? [String: Any]
        let next = creation.flatMap { string($0, keys: ["nextCreateAt", "next_create_at"]) }
            ?? string(payload, keys: ["nextCreateAt", "next_create_at"])
            ?? string(root, keys: ["nextCreateAt", "next_create_at"])
        let capability = VoiceCloneCapability(
            canCreate: creation.flatMap { bool($0, keys: ["canCreate", "can_create"]) },
            freeCreationConsumed: creation.flatMap {
                bool($0, keys: ["freeCreationConsumed", "free_creation_consumed"])
            },
            canApply: usage.flatMap { bool($0, keys: ["canApply", "can_apply"]) },
            monthlyLimitSeconds: usage.flatMap {
                int($0, keys: ["monthlyLimitSeconds", "monthly_limit_seconds"])
            },
            monthlyUsedSeconds: usage.flatMap {
                int($0, keys: ["monthlyUsedSeconds", "monthly_used_seconds"])
            },
            monthlyRemainingSeconds: usage.flatMap {
                int($0, keys: ["monthlyRemainingSeconds", "monthly_remaining_seconds"])
            },
            resetAt: parseDate(usage.flatMap {
                string($0, keys: ["resetAt", "reset_at"])
            })
        )
        return VoiceCloneListResult(
            voices: decodeVoices(rawVoices),
            nextCreateAt: parseDate(next),
            capability: capability
        )
    }

    static func createdVoice(from data: Data) throws -> ClonedVoice {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw VoiceCloneError.invalidResponse }
        let candidate = (root["voice"] as? [String: Any])
            ?? ((root["data"] as? [String: Any])?["voice"] as? [String: Any])
            ?? (root["data"] as? [String: Any])
            ?? root
        let decoded = try JSONDecoder().decode(ClonedVoice.self, from: JSONSerialization.data(withJSONObject: candidate))
        guard decoded.voiceId.hasPrefix("vc_") else { throw VoiceCloneError.invalidResponse }
        return decoded
    }

    static func identity(from data: Data) throws -> VoiceCloneIdentity {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw VoiceCloneError.invalidResponse
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let object = (payload["identity"] as? [String: Any])
            ?? (root["identity"] as? [String: Any]),
              let encoded = try? JSONSerialization.data(withJSONObject: object),
              let identity = try? JSONDecoder().decode(VoiceCloneIdentity.self, from: encoded),
              identity.isSupported else {
            throw VoiceCloneError.invalidResponse
        }
        return identity
    }

    static func renamedIdentity(
        from data: Data,
        expectedVoiceID: String,
        requestedName: String?,
        expectedRevision: Int
    ) throws -> VoiceCloneIdentity {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              let code = root["code"] as? NSNumber,
              CFGetTypeID(code) != CFBooleanGetTypeID(),
              code.doubleValue == 0,
              let payload = root["data"] as? [String: Any],
              payload["voiceId"] as? String == expectedVoiceID else {
            throw VoiceCloneError.invalidResponse
        }
        let identity = try identity(from: data)
        guard identity.revision > expectedRevision,
              identity.matchesRequestedName(requestedName) else {
            throw VoiceCloneError.invalidResponse
        }
        return identity
    }

    static func conflictIdentity(from data: Data) -> VoiceCloneIdentity? {
        try? identity(from: data)
    }

    static func serverMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for object in responseObjects(from: root) {
            if let value = string(object, keys: ["message", "error", "detail"]) {
                return value
            }
        }
        return nil
    }

    static func serverCode(
        from data: Data,
        response: HTTPURLResponse? = nil
    ) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for object in responseObjects(from: root) {
                if let value = string(object, keys: ["code", "error_code", "errorCode"]) {
                    return value
                }
                if let value = object["error"] as? String,
                   isStructuredErrorCode(value) {
                    return value
                }
            }
        }
        guard let response else { return nil }
        for name in ["X-Voice-Error-Code", "X-CastReader-Error-Code", "X-Error-Code"] {
            if let value = response.value(forHTTPHeaderField: name)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func nextCreateAt(from data: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (root["data"] as? [String: Any]) ?? root
        let creation = payload["creation"] as? [String: Any]
        return parseDate(creation.flatMap { string($0, keys: ["nextCreateAt", "next_create_at"]) }
            ?? string(payload, keys: ["nextCreateAt", "next_create_at"]))
    }

    static func quotaResetAt(from data: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (root["data"] as? [String: Any]) ?? root
        return parseDate(
            string(payload, keys: ["cloneQuotaResetAt", "clone_quota_reset_at", "resetAt", "reset_at"])
                ?? string(root, keys: ["cloneQuotaResetAt", "clone_quota_reset_at", "resetAt", "reset_at"])
        )
    }

    static func quotaCapability(from response: HTTPURLResponse) -> VoiceCloneCapability {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        }
        return VoiceCloneCapability(
            canCreate: nil,
            freeCreationConsumed: nil,
            canApply: nil,
            monthlyLimitSeconds: Int(fields["x-clone-quota-limit-seconds"] ?? ""),
            monthlyUsedSeconds: Int(fields["x-clone-quota-used-seconds"] ?? ""),
            monthlyRemainingSeconds: Int(fields["x-clone-quota-remaining-seconds"] ?? ""),
            resetAt: parseDate(fields["x-clone-quota-reset-at"])
        )
    }

    static func parseServerDate(_ value: String?) -> Date? {
        parseDate(value)
    }

    private static func decodeVoices(_ objects: [[String: Any]]) -> [ClonedVoice] {
        objects.compactMap { object in
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let voice = try? JSONDecoder().decode(ClonedVoice.self, from: data),
                  voice.voiceId.hasPrefix("vc_") else {
                return nil
            }
            return voice
        }
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func responseObjects(from root: [String: Any]) -> [[String: Any]] {
        var result = [root]
        var index = 0
        while index < result.count, result.count < 16 {
            let object = result[index]
            for key in ["data", "error", "detail"] {
                if let nested = object[key] as? [String: Any] {
                    result.append(nested)
                }
            }
            index += 1
        }
        return result
    }

    private static func isStructuredErrorCode(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == normalized.uppercased() else { return false }
        return normalized.unicodeScalars.allSatisfy {
            CharacterSet.uppercaseLetters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || $0 == "_"
        }
    }

    private static func bool(_ object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? NSNumber { return value.boolValue }
            if let value = object[key] as? String {
                switch value.lowercased() {
                case "true", "1": return true
                case "false", "0": return false
                default: continue
                }
            }
        }
        return nil
    }

    private static func int(_ object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum VoiceCloneError: Error, LocalizedError, Equatable {
    case signInRequired
    case sessionUnavailable
    case proRequired
    case voiceNotFound
    case languageUnsupported
    case invalidRecording(String)
    case slotFull
    case creationLimit(Date?)
    case quotaExhausted(Date?)
    case workerBusy(String?)
    case identityConflict(VoiceCloneIdentity?)
    case identityInvalid(String?)
    case identityUnavailable
    case temporaryUnavailable
    case server(Int, String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .signInRequired: return AppLocalized("请先登录以使用声音克隆")
        case .sessionUnavailable: return AppLocalized("声音克隆登录服务尚未就绪，请稍后再试")
        case .proRequired: return AppLocalized("升级到 Pro 后，即可将自己的声音用于朗读和解读")
        case .voiceNotFound: return AppLocalized("这个声音已不存在，请重新创建")
        case .languageUnsupported: return AppLocalized("这个克隆音色暂不支持当前朗读语言")
        case .invalidRecording(let message): return message
        case .slotFull: return AppLocalized("声音服务正在更新，请稍后重试")
        case .creationLimit: return AppLocalized("声音服务正在更新，请稍后重试")
        case .quotaExhausted(let resetAt):
            if let resetAt {
                let formatter = DateFormatter()
                formatter.locale = AppLanguageManager.shared.locale
                formatter.setLocalizedDateFormatFromTemplate("MMM d")
                return String(
                    format: AppLocalized("本月 120 分钟的克隆音色额度已用完，将于 %@ 自动恢复。你可以切换到预设音色继续朗读或解读。"),
                    formatter.string(from: resetAt)
                )
            }
            return AppLocalized("本月 120 分钟的克隆音色额度已用完。你可以切换到预设音色继续朗读或解读。")
        case .workerBusy: return AppLocalized("声音服务繁忙，请重试")
        case .identityConflict:
            return AppLocalized("声音名称已在其他设备更新，请确认后重试")
        case .identityInvalid(let message):
            return message ?? AppLocalized("声音名称无效，请修改后重试")
        case .identityUnavailable:
            return AppLocalized("声音仍可正常使用，名称同步暂不可用，请稍后重试")
        case .temporaryUnavailable: return AppLocalized("声音服务暂时不可用，请稍后重试")
        case .server: return AppLocalized("声音克隆请求失败")
        case .invalidResponse: return AppLocalized("声音克隆返回数据无效")
        }
    }

    var isQuotaExhausted: Bool {
        if case .quotaExhausted = self { return true }
        return false
    }
}
