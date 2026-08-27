import Foundation

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
            return AppLocalized("有效讲话时间太短，请完整朗读文案")
        case "VOICE_REFERENCE_TOO_MUCH_SILENCE":
            return AppLocalized("录音中的静音太多，请按住后尽快开始朗读")
        case "VOICE_REFERENCE_TOO_QUIET":
            return AppLocalized("声音太小，请靠近手机并重新录制")
        case "VOICE_REFERENCE_CLIPPING":
            return AppLocalized("声音过大并出现失真，请稍微远离手机重新录制")
        case "VOICE_REFERENCE_TOO_NOISY":
            return AppLocalized("环境噪声太大，请换到更安静的地方重新录制")
        case "VOICE_REFERENCE_TOO_REVERBERANT":
            return AppLocalized("房间回声太重，请靠近手机并换到较小、柔软的空间录制")
        case "VOICE_REFERENCE_MULTIPLE_SPEAKERS":
            return AppLocalized("录音中可能有多人说话，请确保只有本人朗读")
        default:
            return nil
        }
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

    var id: String { voiceId }

    init(
        voiceId: String,
        createdAt: String? = nil,
        sampleURL: String? = nil,
        status: String? = nil,
        previewStatus: String? = nil,
        previewDurationMs: Int? = nil,
        referenceLanguage: String? = nil,
        supportedLanguages: [String] = []
    ) {
        self.voiceId = voiceId
        self.createdAt = createdAt
        self.sampleURL = sampleURL
        self.status = status
        self.previewStatus = previewStatus
        self.previewDurationMs = previewDurationMs
        self.referenceLanguage = referenceLanguage
        self.supportedLanguages = supportedLanguages
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
    }

    private enum CodingKeys: String, CodingKey {
        case voiceId, id, createdAt, sampleUrl, status, previewStatus, previewDurationMs, referenceLanguage, supportedLanguages
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
            return VoiceCloneListResult(voices: try decodeVoices(array), nextCreateAt: nil)
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
            voices: try decodeVoices(rawVoices),
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

    static func serverMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return string(root, keys: ["message", "error", "detail"])
            ?? (root["data"] as? [String: Any]).flatMap { string($0, keys: ["message", "error", "detail"]) }
    }

    static func serverCode(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return string(root, keys: ["code", "error_code"])
            ?? (root["data"] as? [String: Any]).flatMap { string($0, keys: ["code", "error_code"]) }
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

    private static func decodeVoices(_ objects: [[String: Any]]) throws -> [ClonedVoice] {
        try objects.map {
            try JSONDecoder().decode(ClonedVoice.self, from: JSONSerialization.data(withJSONObject: $0))
        }.filter { $0.voiceId.hasPrefix("vc_") }
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
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
