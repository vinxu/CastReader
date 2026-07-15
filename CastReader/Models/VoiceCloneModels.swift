import Foundation

struct ClonedVoice: Identifiable, Equatable, Decodable {
    let voiceId: String
    let createdAt: String?
    let sampleURL: String?
    let status: String?
    let referenceLanguage: String?
    let supportedLanguages: [String]

    var id: String { voiceId }

    init(
        voiceId: String,
        createdAt: String? = nil,
        sampleURL: String? = nil,
        status: String? = nil,
        referenceLanguage: String? = nil,
        supportedLanguages: [String] = []
    ) {
        self.voiceId = voiceId
        self.createdAt = createdAt
        self.sampleURL = sampleURL
        self.status = status
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
        referenceLanguage = try container.decodeIfPresent(String.self, forKey: .referenceLanguage)
            ?? container.decodeIfPresent(String.self, forKey: .referenceLanguageSnake)
        supportedLanguages = try container.decodeIfPresent([String].self, forKey: .supportedLanguages)
            ?? container.decodeIfPresent([String].self, forKey: .supportedLanguagesSnake)
            ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case voiceId, id, createdAt, sampleUrl, status, referenceLanguage, supportedLanguages
        case voiceIdSnake = "voice_id"
        case createdAtSnake = "created_at"
        case sampleUrlSnake = "sample_url"
        case referenceLanguageSnake = "reference_language"
        case supportedLanguagesSnake = "supported_languages"
    }
}

struct VoiceCloneListResult: Equatable {
    let voices: [ClonedVoice]
    let nextCreateAt: Date?
}

enum VoiceCloneResponseParser {
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
        let next = creation.flatMap { string($0, keys: ["nextCreateAt", "next_create_at"]) }
            ?? string(payload, keys: ["nextCreateAt", "next_create_at"])
            ?? string(root, keys: ["nextCreateAt", "next_create_at"])
        return VoiceCloneListResult(voices: try decodeVoices(rawVoices), nextCreateAt: parseDate(next))
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
    case invalidRecording(String)
    case creationLimit(Date?)
    case workerBusy(String?)
    case temporaryUnavailable
    case server(Int, String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .signInRequired: return String(localized: "请先登录以使用声音克隆")
        case .sessionUnavailable: return String(localized: "声音克隆登录服务尚未就绪，请稍后再试")
        case .proRequired: return String(localized: "声音克隆仅面向 Pro 会员")
        case .voiceNotFound: return String(localized: "这个声音已不存在，请重新创建")
        case .invalidRecording(let message): return message
        case .creationLimit: return String(localized: "每 24 小时只能创建一个声音")
        case .workerBusy(let message): return message ?? String(localized: "声音服务繁忙，请重试")
        case .temporaryUnavailable: return String(localized: "声音服务暂时不可用，请稍后重试")
        case .server(_, let message): return message ?? String(localized: "声音克隆请求失败")
        case .invalidResponse: return String(localized: "声音克隆返回数据无效")
        }
    }
}
