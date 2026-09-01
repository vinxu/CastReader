import Foundation
import CoreFoundation
import CryptoKit

enum VoiceCloneCreateIdempotency {
    private static let prefix = "ios:"
    private static let fingerprintVersion = "voice-clone-create-v1"

    static func makeKey(uuid: UUID = UUID()) -> String {
        prefix + uuid.uuidString.lowercased()
    }

    static func isValidKey(_ value: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
    }

    static func apply(_ key: String, to request: inout URLRequest) throws {
        guard isValidKey(key) else { throw VoiceCloneError.invalidResponse }
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
    }

    /// Binds retry identity to the exact recording and semantic inputs. Length
    /// prefixes keep field boundaries unambiguous without persisting audio or
    /// user text in defaults/logs.
    static func fingerprint(
        recordingData: Data,
        referenceLanguage: String,
        referenceText: String?
    ) -> String {
        let normalizedLanguage = VoiceCatalog.normalizedLanguage(referenceLanguage)
        let trimmedText = referenceText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = trimmedText?.isEmpty == false ? trimmedText! : ""
        var payload = Data()
        appendLengthPrefixed(Data(fingerprintVersion.utf8), to: &payload)
        appendLengthPrefixed(Data(normalizedLanguage.utf8), to: &payload)
        appendLengthPrefixed(Data(normalizedText.utf8), to: &payload)
        appendLengthPrefixed(recordingData, to: &payload)
        return SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func fingerprint(
        recordingURL: URL,
        referenceLanguage: String,
        referenceText: String?
    ) throws -> String {
        fingerprint(
            recordingData: try Data(contentsOf: recordingURL),
            referenceLanguage: referenceLanguage,
            referenceText: referenceText
        )
    }

    private static func appendLengthPrefixed(_ value: Data, to payload: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(value)
    }
}

enum VoiceCloneReferenceIntegrity {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

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

struct VoiceGiftDonor: Equatable, Decodable {
    let displayName: String?
    /// Optional account portrait supplied for attribution and for the
    /// server-authored unified-library presentation.
    let avatarURL: String?
    let identity: VoiceCloneIdentity?

    init(
        displayName: String? = nil,
        avatarURL: String? = nil,
        identity: VoiceCloneIdentity? = nil
    ) {
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.identity = identity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .name)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? container.decodeIfPresent(String.self, forKey: .avatarUrl)
            ?? container.decodeIfPresent(String.self, forKey: .avatarURLSnake)
        let decodedIdentity = try? container.decode(VoiceCloneIdentity.self, forKey: .identity)
        identity = decodedIdentity?.isSupported == true ? decodedIdentity : nil
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, name, avatarURL, avatarUrl, identity
        case avatarURLSnake = "avatar_url"
    }
}

/// Server-authored identity for a voice-library row. The backend owns the
/// cross-client title/avatar precedence; every field remains optional so a
/// partially rolled-out presentation can safely fall back to identity/donor.
struct VoiceGiftPresentation: Equatable, Decodable {
    struct Avatar: Equatable, Decodable {
        let source: String?
        let style: VoiceCloneAvatarPresentation?
        let url: String?
        let defaultKey: String?

        var resolvedStyle: VoiceCloneAvatarPresentation? {
            guard source == "identity" || source == "default",
                  let style,
                  style.isSupported else { return nil }
            return style
        }

        var remoteURL: URL? {
            guard source == "donor",
                  let url,
                  let components = URLComponents(string: url),
                  components.scheme?.lowercased() == "https",
                  components.user == nil,
                  components.password == nil,
                  components.host?.isEmpty == false else { return nil }
            return components.url
        }
    }

    let title: String?
    let titleSource: String?
    let avatar: Avatar?

    var normalizedTitle: String? {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

struct VoiceGiftCapabilities: Equatable, Decodable {
    let canPreview: Bool
    let canUse: Bool
    let canEditAlias: Bool
    let canRemoveAccess: Bool
    let canRename: Bool
    let canDelete: Bool

    init(
        canPreview: Bool = false,
        canUse: Bool = false,
        canEditAlias: Bool = false,
        canRemoveAccess: Bool = false,
        canRename: Bool = false,
        canDelete: Bool = false
    ) {
        self.canPreview = canPreview
        self.canUse = canUse
        self.canEditAlias = canEditAlias
        self.canRemoveAccess = canRemoveAccess
        self.canRename = canRename
        self.canDelete = canDelete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Canonical Voice Gift v1 names come first. The `canX` aliases keep
        // compatibility with early mobile fixtures without weakening a
        // missing permission into `true`.
        canPreview = try container.decodeIfPresent(Bool.self, forKey: .preview)
            ?? container.decodeIfPresent(Bool.self, forKey: .canPreview)
            ?? false
        canUse = try container.decodeIfPresent(Bool.self, forKey: .useTts)
            ?? container.decodeIfPresent(Bool.self, forKey: .canUse)
            ?? container.decodeIfPresent(Bool.self, forKey: .use)
            ?? false
        canEditAlias = try container.decodeIfPresent(Bool.self, forKey: .setAlias)
            ?? container.decodeIfPresent(Bool.self, forKey: .canEditAlias)
            ?? container.decodeIfPresent(Bool.self, forKey: .editAlias)
            ?? false
        canRemoveAccess = try container.decodeIfPresent(Bool.self, forKey: .remove)
            ?? container.decodeIfPresent(Bool.self, forKey: .canRemoveAccess)
            ?? container.decodeIfPresent(Bool.self, forKey: .removeAccess)
            ?? false
        canRename = try container.decodeIfPresent(Bool.self, forKey: .rename)
            ?? container.decodeIfPresent(Bool.self, forKey: .canRename)
            ?? false
        canDelete = try container.decodeIfPresent(Bool.self, forKey: .delete)
            ?? container.decodeIfPresent(Bool.self, forKey: .canDelete)
            ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case canPreview, canUse, canEditAlias, canRemoveAccess, canRename, canDelete
        case preview, useTts, setAlias, remove, rename, delete
        case use, editAlias, removeAccess
    }
}

struct VoiceGiftAccess: Equatable, Decodable {
    enum Kind: String, Decodable {
        case owner
        case gifted
    }

    let kind: Kind
    let grantId: String?
    let shareId: String?
    /// Kept as a string so a newly introduced backend state remains decodable.
    let status: String?
    let donor: VoiceGiftDonor?
    let recipientAlias: String?
    let capabilities: VoiceGiftCapabilities

    init(
        kind: Kind,
        grantId: String? = nil,
        shareId: String? = nil,
        status: String? = nil,
        donor: VoiceGiftDonor? = nil,
        recipientAlias: String? = nil,
        capabilities: VoiceGiftCapabilities? = nil
    ) {
        self.kind = kind
        self.grantId = grantId
        self.shareId = shareId
        self.status = status
        self.donor = donor
        self.recipientAlias = recipientAlias
        self.capabilities = capabilities ?? Self.defaultCapabilities(for: kind)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        grantId = try container.decodeIfPresent(String.self, forKey: .grantId)
            ?? container.decodeIfPresent(String.self, forKey: .grantIdSnake)
        shareId = try container.decodeIfPresent(String.self, forKey: .shareId)
            ?? container.decodeIfPresent(String.self, forKey: .shareIdSnake)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        donor = try container.decodeIfPresent(VoiceGiftDonor.self, forKey: .donor)
        recipientAlias = try container.decodeIfPresent(String.self, forKey: .recipientAlias)
            ?? container.decodeIfPresent(String.self, forKey: .recipientAliasSnake)
        // An explicit access object is the canonical authorization boundary;
        // missing permissions fail closed. Legacy owner rows omit the entire
        // access field and are handled separately by ClonedVoice.
        capabilities = try container.decodeIfPresent(
            VoiceGiftCapabilities.self,
            forKey: .capabilities
        ) ?? VoiceGiftCapabilities()
    }

    /// Grant lifecycle and product entitlement are separate axes. In
    /// particular, `useTts == false` can merely mean the recipient is not Pro;
    /// it must never be interpreted as the donor revoking authorization.
    var authorizationActive: Bool {
        guard kind == .gifted else { return true }
        guard let status = status?.lowercased() else { return true }
        return status == "active" || status == "fulfilled"
    }

    var hasTerminalRevocation: Bool {
        guard kind == .gifted else { return false }
        let normalized = status?.lowercased()
        return normalized == "revoked" || normalized == "expired"
    }

    /// PATCH/DELETE are share-scoped. A grant id is deliberately not a route
    /// fallback because the two namespaces are not interchangeable.
    var mutationID: String? {
        let normalized = shareId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func defaultCapabilities(for kind: Kind) -> VoiceGiftCapabilities {
        switch kind {
        case .owner:
            return VoiceGiftCapabilities(
                canPreview: true,
                canUse: true,
                canRename: true,
                canDelete: true
            )
        case .gifted:
            // Gift permissions fail closed until the library explicitly grants
            // them; older owner-only responses remain fully compatible.
            return VoiceGiftCapabilities()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, grantId, shareId, status, donor, recipientAlias, capabilities
        case grantIdSnake = "grant_id"
        case shareIdSnake = "share_id"
        case recipientAliasSnake = "recipient_alias"
    }
}

enum VoiceGiftInvitationURLValidator {
    static func validatedURL(_ value: String) -> URL? {
        validatedURL(value, route: nil)
    }

    static func validatedURL(_ value: String, for route: ServiceRoute) -> URL? {
        validatedURL(value, route: route)
    }

    private static func validatedURL(_ value: String, route: ServiceRoute?) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              isAllowedHost(host, route: route),
              isAllowedPath(components.path),
              components.percentEncodedPath == components.path,
              components.query == nil,
              let token = components.fragment,
              components.percentEncodedFragment == token,
              isAllowedToken(token) else {
            return nil
        }
        #if !DEBUG
        guard components.port == nil else { return nil }
        #endif
        return components.url
    }

    private static func isAllowedHost(_ host: String, route: ServiceRoute?) -> Bool {
        let globalHosts = ["castreader.com"]
        let chinaHosts = ["api.castreader.cn"]
        let allowedHosts: [String]
        switch route {
        case .globalGateway:
            allowedHosts = globalHosts
        case .chinaGateway:
            allowedHosts = chinaHosts
        case nil:
            allowedHosts = globalHosts + chinaHosts
        }
        if allowedHosts.contains(host) {
            return true
        }
        #if DEBUG
        // Debug-only injection supports deterministic localhost fixtures while
        // the production binary remains pinned to the route-owned CastReader hosts.
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
        #else
        return false
        #endif
    }

    private static func isAllowedPath(_ path: String) -> Bool {
        let allowedPaths: Set<String> = [
            "/voice-gift/request",
            "/zh/voice-gift/request",
            "/ja/voice-gift/request",
            "/es/voice-gift/request",
            "/fr/voice-gift/request",
            "/de/voice-gift/request",
            "/pt-br/voice-gift/request",
            "/it/voice-gift/request",
            "/hi/voice-gift/request",
        ]
        return allowedPaths.contains(path)
    }

    private static func isAllowedToken(_ token: String) -> Bool {
        guard token.utf8.count == 43 else { return false }
        return token.utf8.allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x5A).contains($0)
                || (0x61...0x7A).contains($0)
                || $0 == 0x2D
                || $0 == 0x5F
        }
    }
}

struct VoiceGiftInvitation: Identifiable, Equatable, Decodable {
    struct Authorization: Equatable, Decodable {
        let mode: String
        let expiresAt: String?
    }

    let requestId: String
    let invitationURL: String
    /// String-backed to tolerate new lifecycle states without hiding the row.
    let status: String
    let createdAt: String?
    let requestExpiresAt: String?
    let authorization: Authorization?

    var id: String { requestId }
    var isPending: Bool {
        // Unknown future states stay visible instead of being mistaken for a
        // terminal server deletion. Only the frozen terminal states remove a
        // request from the in-progress section.
        !["fulfilled", "cancelled", "expired"].contains(status.lowercased())
    }

    var isClaimed: Bool {
        ["claimed", "accepted"].contains(status.lowercased())
    }

    init(
        requestId: String,
        invitationURL: String,
        status: String = "pending",
        createdAt: String? = nil,
        requestExpiresAt: String? = nil,
        authorization: Authorization? = nil
    ) {
        self.requestId = requestId
        self.invitationURL = invitationURL
        self.status = status
        self.createdAt = createdAt
        self.requestExpiresAt = requestExpiresAt
        self.authorization = authorization
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
            ?? container.decodeIfPresent(String.self, forKey: .requestIdSnake)
            ?? container.decodeIfPresent(String.self, forKey: .id),
              let invitationURL = try container.decodeIfPresent(String.self, forKey: .invitationURL)
            ?? container.decodeIfPresent(String.self, forKey: .invitationUrl)
            ?? container.decodeIfPresent(String.self, forKey: .invitationURLSnake),
              VoiceGiftInvitationURLValidator.validatedURL(invitationURL) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .requestId,
                in: container,
                debugDescription: "Missing request id or invalid invitation URL"
            )
        }
        self.requestId = requestId
        self.invitationURL = invitationURL
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
            ?? container.decodeIfPresent(String.self, forKey: .createdAtSnake)
        requestExpiresAt = try container.decodeIfPresent(String.self, forKey: .requestExpiresAt)
            ?? container.decodeIfPresent(String.self, forKey: .requestExpiresAtSnake)
        if let object = try container.decodeIfPresent(Authorization.self, forKey: .authorization) {
            authorization = object
        } else if let mode = try container.decodeIfPresent(String.self, forKey: .authorizationMode)
            ?? container.decodeIfPresent(String.self, forKey: .authorizationModeSnake) {
            authorization = Authorization(mode: mode, expiresAt: nil)
        } else {
            authorization = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, id, invitationURL = "invitationURL", invitationUrl, status, createdAt, requestExpiresAt, authorization, authorizationMode
        case requestIdSnake = "request_id"
        case invitationURLSnake = "invitation_url"
        case createdAtSnake = "created_at"
        case requestExpiresAtSnake = "request_expires_at"
        case authorizationModeSnake = "authorization_mode"
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
    let access: VoiceGiftAccess
    let presentation: VoiceGiftPresentation?

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
        identity: VoiceCloneIdentity? = nil,
        access: VoiceGiftAccess = VoiceGiftAccess(kind: .owner),
        presentation: VoiceGiftPresentation? = nil
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
        self.access = access
        self.presentation = presentation
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
        if container.contains(.access) {
            // Never reinterpret an unknown/malformed access kind as owner:
            // that would expose rename/delete for a donor-owned voice. New
            // status values remain string-backed and therefore lossless, while
            // the security boundary itself stays fail closed.
            access = try container.decode(VoiceGiftAccess.self, forKey: .access)
        } else {
            access = VoiceGiftAccess(kind: .owner)
        }
        presentation = try? container.decode(
            VoiceGiftPresentation.self,
            forKey: .presentation
        )
    }

    func replacingIdentity(
        _ identity: VoiceCloneIdentity?,
        preservingPresentation: Bool = true
    ) -> ClonedVoice {
        ClonedVoice(
            voiceId: voiceId,
            createdAt: createdAt,
            sampleURL: sampleURL,
            status: status,
            previewStatus: previewStatus,
            previewDurationMs: previewDurationMs,
            referenceLanguage: referenceLanguage,
            supportedLanguages: supportedLanguages,
            identity: identity,
            access: access,
            presentation: preservingPresentation ? presentation : nil
        )
    }

    func replacingAccess(
        _ access: VoiceGiftAccess,
        preservingPresentation: Bool = true
    ) -> ClonedVoice {
        ClonedVoice(
            voiceId: voiceId,
            createdAt: createdAt,
            sampleURL: sampleURL,
            status: status,
            previewStatus: previewStatus,
            previewDurationMs: previewDurationMs,
            referenceLanguage: referenceLanguage,
            supportedLanguages: supportedLanguages,
            identity: identity,
            access: access,
            presentation: preservingPresentation ? presentation : nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case voiceId, id, createdAt, sampleUrl, status, previewStatus, previewDurationMs, referenceLanguage, supportedLanguages, identity, access, presentation
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
    let schemaVersion: String
    let snapshotComplete: Bool
    let invitationsSnapshotComplete: Bool
    let voiceGiftEnabled: Bool
    let voices: [ClonedVoice]
    let invitations: [VoiceGiftInvitation]
    let nextCreateAt: Date?
    let capability: VoiceCloneCapability

    init(
        schemaVersion: String = "legacy-v1",
        snapshotComplete: Bool = true,
        invitationsSnapshotComplete: Bool = true,
        voiceGiftEnabled: Bool = false,
        voices: [ClonedVoice],
        invitations: [VoiceGiftInvitation] = [],
        nextCreateAt: Date?,
        capability: VoiceCloneCapability = .unknown
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotComplete = snapshotComplete
        self.invitationsSnapshotComplete = invitationsSnapshotComplete
        self.voiceGiftEnabled = voiceGiftEnabled
        self.voices = voices
        self.invitations = invitations
        self.nextCreateAt = nextCreateAt
        self.capability = capability
    }
}

struct VoiceGiftCapabilityManifest: Equatable {
    static let supportedVersion = "voice-gift-v1"
    static let supportedLibraryVersion = "voice-library-v1"

    let enabled: Bool
    let version: String
    let libraryVersion: String
    let serviceRoute: String

    func isCompatible(with route: ServiceRoute) -> Bool {
        enabled
            && version == Self.supportedVersion
            && libraryVersion == Self.supportedLibraryVersion
            && serviceRoute == route.rawValue
    }

    static func decode(from data: Data) -> VoiceGiftCapabilityManifest? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let voiceGift = payload["voiceGift"] as? [String: Any],
              let enabled = voiceGift["enabled"] as? Bool,
              let version = voiceGift["version"] as? String,
              let libraryVersion = voiceGift["libraryVersion"] as? String,
              let serviceRoute = voiceGift["serviceRoute"] as? String else {
            return nil
        }
        return VoiceGiftCapabilityManifest(
            enabled: enabled,
            version: version,
            libraryVersion: libraryVersion,
            serviceRoute: serviceRoute
        )
    }
}

enum VoiceGiftAccessLoss: Equatable {
    case voiceNotFound
    case recipientMismatch
    case revoked
    case expired
    case unavailable

    var error: VoiceCloneError {
        switch self {
        case .voiceNotFound: return .voiceNotFound
        case .revoked: return .giftRevoked
        case .expired: return .giftExpired
        case .recipientMismatch, .unavailable: return .giftAccessLost
        }
    }
}

enum VoiceCloneResponseParser {
    struct VoiceGiftInvitationLimitDetails: Equatable {
        let limitType: String?
        let limit: Int?
        let current: Int?
        let invitationTTLSeconds: Int?
        let windowSeconds: Int?
        let earliestExpiryAt: Date?
        let retryAt: Date?
        let retryAfterSeconds: Int?
    }

    static func isVoiceNotFound(statusCode: Int, data: Data) -> Bool {
        statusCode == 404 && serverCode(from: data)?.uppercased() == "VOICE_NOT_FOUND"
    }

    /// A transport status by itself never proves that a persisted voice or
    /// grant disappeared. Keep this table aligned with voice-gift-v1 so route
    /// misses, rollout errors and feature-level 404s cannot erase a user's
    /// current selection.
    static func confirmedVoiceGiftAccessLoss(
        statusCode: Int,
        data: Data
    ) -> VoiceGiftAccessLoss? {
        guard let code = serverCode(from: data)?.uppercased() else { return nil }
        switch (statusCode, code) {
        case (404, "VOICE_NOT_FOUND"):
            return .voiceNotFound
        case (403, "VOICE_GIFT_RECIPIENT_MISMATCH"):
            return .recipientMismatch
        case (410, "VOICE_GIFT_REVOKED"):
            return .revoked
        case (410, "VOICE_GIFT_EXPIRED"):
            return .expired
        case (410, "VOICE_GIFT_UNAVAILABLE"):
            return .unavailable
        default:
            return nil
        }
    }

    static func list(from data: Data) throws -> VoiceCloneListResult {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] {
            return VoiceCloneListResult(voices: decodeVoiceItems(array), nextCreateAt: nil)
        }
        guard let root = object as? [String: Any] else { throw VoiceCloneError.invalidResponse }
        let payload = (root["data"] as? [String: Any]) ?? root
        let rawVoices = (payload["items"] as? [[String: Any]])
            ?? (payload["voices"] as? [[String: Any]])
            ?? (root["items"] as? [[String: Any]])
            ?? (root["voices"] as? [[String: Any]])
            ?? []
        let rawInvitations = (payload["pendingInvitations"] as? [[String: Any]])
            ?? (payload["invitations"] as? [[String: Any]])
            ?? (payload["requests"] as? [[String: Any]])
            ?? (root["pendingInvitations"] as? [[String: Any]])
            ?? (root["invitations"] as? [[String: Any]])
            ?? []
        let hasInvitationSnapshot = ["pendingInvitations", "invitations", "requests"]
            .contains { payload[$0] != nil || root[$0] != nil }
        let schemaVersion = string(payload, keys: ["schemaVersion", "schema_version"])
            ?? string(root, keys: ["schemaVersion", "schema_version"])
            ?? "legacy-v1"
        if schemaVersion == VoiceGiftCapabilityManifest.supportedLibraryVersion,
           payload["voices"] as? [[String: Any]] == nil {
            // A canonical empty snapshot is `voices: []`. Missing the field is
            // a contract failure and must never be interpreted as deleting all
            // locally known owner/gifted voices.
            throw VoiceCloneError.invalidResponse
        }
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
        let decodedVoices = decodeVoiceItems(
            rawVoices,
            requiresExplicitAccess: schemaVersion
                == VoiceGiftCapabilityManifest.supportedLibraryVersion
        )
        let declaredSnapshotComplete = bool(
            payload,
            keys: ["snapshotComplete", "snapshot_complete"]
        ) ?? bool(
            root,
            keys: ["snapshotComplete", "snapshot_complete"]
        ) ?? (schemaVersion == VoiceGiftCapabilityManifest.supportedLibraryVersion
            ? false
            : true)
        return VoiceCloneListResult(
            schemaVersion: schemaVersion,
            snapshotComplete: declaredSnapshotComplete
                && decodedVoices.count == rawVoices.count,
            invitationsSnapshotComplete: hasInvitationSnapshot,
            voices: decodedVoices,
            invitations: decodeInvitations(rawInvitations),
            nextCreateAt: parseDate(next),
            capability: capability
        )
    }

    static func giftInvitation(from data: Data) throws -> VoiceGiftInvitation {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw VoiceCloneError.invalidResponse
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        var candidate = (payload["request"] as? [String: Any])
            ?? (payload["invitation"] as? [String: Any])
            ?? payload
        if candidate["invitationURL"] == nil,
           candidate["invitationUrl"] == nil,
           candidate["invitation_url"] == nil {
            candidate["invitationURL"] = string(
                payload,
                keys: ["invitationURL", "invitationUrl", "invitation_url", "url"]
            ) ?? string(root, keys: ["invitationURL", "invitationUrl", "invitation_url", "url"])
        }
        if candidate["requestId"] == nil,
           candidate["request_id"] == nil,
           candidate["id"] == nil {
            candidate["requestId"] = string(payload, keys: ["requestId", "request_id"])
                ?? string(root, keys: ["requestId", "request_id"])
        }
        if candidate["authorization"] == nil {
            candidate["authorization"] = payload["authorization"]
                ?? root["authorization"]
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: candidate),
              let invitation = try? JSONDecoder().decode(VoiceGiftInvitation.self, from: encoded) else {
            throw VoiceCloneError.invalidResponse
        }
        return invitation
    }

    static func sentGiftInvitations(from data: Data) throws -> (
        schemaVersion: String,
        invitations: [VoiceGiftInvitation],
        snapshotComplete: Bool
    ) {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw VoiceCloneError.invalidResponse
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        guard let sent = payload["sent"] as? [[String: Any]] else {
            throw VoiceCloneError.invalidResponse
        }
        let decoded = decodeInvitations(sent)
        let declaredSnapshotComplete = bool(
            payload,
            keys: ["snapshotComplete", "snapshot_complete"]
        ) ?? false
        return (
            schemaVersion: string(payload, keys: ["schemaVersion", "schema_version"])
                ?? "unknown",
            // Preserve explicit terminal rows as tombstones. The Store filters
            // display rows after using every returned id to remove stale local
            // pending invitations from an incomplete snapshot.
            invitations: decoded,
            snapshotComplete: declaredSnapshotComplete
                && decoded.count == sent.count
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

    static func voiceGiftInvitationLimitDetails(
        from data: Data,
        response: HTTPURLResponse,
        now: Date = Date()
    ) -> VoiceGiftInvitationLimitDetails {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let objects = root.map(responseObjects(from:)) ?? []
        let firstString: ([String]) -> String? = { keys in
            objects.lazy.compactMap { string($0, keys: keys) }.first
        }
        let firstInt: ([String]) -> Int? = { keys in
            objects.lazy.compactMap { int($0, keys: keys) }.first
        }
        let retryAfterSeconds = firstInt(["retryAfterSeconds", "retry_after_seconds"])
            ?? Self.retryAfterSeconds(from: response, now: now)
        let explicitRetryAt = parseDate(firstString(["retryAt", "retry_at"]))
        let derivedRetryAt = retryAfterSeconds.map {
            now.addingTimeInterval(TimeInterval(max(0, $0)))
        }
        return VoiceGiftInvitationLimitDetails(
            limitType: firstString(["limitType", "limit_type"]),
            limit: firstInt(["limit"]),
            current: firstInt(["current"]),
            invitationTTLSeconds: firstInt([
                "invitationTtlSeconds", "invitationTTLSeconds", "invitation_ttl_seconds",
            ]),
            windowSeconds: firstInt(["windowSeconds", "window_seconds"]),
            earliestExpiryAt: parseDate(firstString([
                "earliestExpiryAt", "earliest_expiry_at",
            ])),
            retryAt: explicitRetryAt ?? derivedRetryAt,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    static func parseServerDate(_ value: String?) -> Date? {
        parseDate(value)
    }

    private static func decodeVoiceItems(
        _ objects: [[String: Any]],
        requiresExplicitAccess: Bool = false
    ) -> [ClonedVoice] {
        objects.compactMap { object in
            var candidate = (object["voice"] as? [String: Any]) ?? object
            if candidate["identity"] == nil {
                candidate["identity"] = object["identity"]
            }
            if candidate["presentation"] == nil {
                candidate["presentation"] = object["presentation"]
            }
            if var access = object["access"] as? [String: Any] {
                for key in [
                    "grantId", "grant_id", "shareId", "share_id", "status",
                    "donor", "recipientAlias", "recipient_alias", "capabilities",
                ] where access[key] == nil {
                    access[key] = object[key]
                }
                candidate["access"] = access
            }
            if requiresExplicitAccess, candidate["access"] == nil {
                // In the unified library, absence of ownership metadata is a
                // security failure, not a legacy owner voice.
                return nil
            }
            guard let data = try? JSONSerialization.data(withJSONObject: candidate),
                  let voice = try? JSONDecoder().decode(ClonedVoice.self, from: data),
                  voice.voiceId.hasPrefix("vc_") else {
                return nil
            }
            return voice
        }
    }

    private static func decodeInvitations(_ objects: [[String: Any]]) -> [VoiceGiftInvitation] {
        objects.compactMap { object in
            let candidate = (object["request"] as? [String: Any]) ?? object
            guard let data = try? JSONSerialization.data(withJSONObject: candidate),
                  let invitation = try? JSONDecoder().decode(VoiceGiftInvitation.self, from: data) else {
                return nil
            }
            return invitation
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
            for key in ["data", "error", "detail", "details"] {
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

    private static func retryAfterSeconds(
        from response: HTTPURLResponse,
        now: Date
    ) -> Int? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let seconds = Int(value) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, Int(ceil(date.timeIntervalSince(now))))
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
    case creationIdempotencyInProgress
    case creationIdempotencyConflict
    case quotaExhausted(Date?)
    case workerBusy(String?)
    case identityConflict(VoiceCloneIdentity?)
    case identityInvalid(String?)
    case identityUnavailable
    case giftUnavailableInRegion
    case giftRevoked
    case giftExpired
    case giftAccessLost
    case giftAccessUnavailable
    case giftActiveInvitationLimit(limit: Int, earliestExpiryAt: Date?)
    case giftDailyInvitationLimit(limit: Int, retryAt: Date?)
    case giftInvitationRateLimited(retryAt: Date?)
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
        case .creationIdempotencyInProgress:
            return AppLocalized("这个声音正在创建，请稍后使用同一录音重试")
        case .creationIdempotencyConflict:
            return AppLocalized("创建记录与当前录音不一致，请重新录制或刷新后再试")
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
        case .giftUnavailableInRegion:
            return AppLocalized("邀请朋友录制声音暂未在当前地区开放")
        case .giftRevoked:
            return AppLocalized("朗读者已收回这个声音的使用授权，已为你取消选择")
        case .giftExpired:
            return AppLocalized("这个声音的使用授权已过期，已为你取消选择")
        case .giftAccessLost:
            return AppLocalized("这个朗读者声音已无法访问，已为你取消选择")
        case .giftAccessUnavailable:
            return AppLocalized("这个朗读者声音暂时无法使用，请刷新声音列表后重试")
        case .giftActiveInvitationLimit(let limit, let earliestExpiryAt):
            if let earliestExpiryAt {
                return String(
                    format: AppLocalized("最多可同时保留 %1$lld 个未完成邀请。最早一条将于 %2$@ 自动过期，之后即可再次邀请。"),
                    Int64(limit),
                    Self.localizedDateTime(earliestExpiryAt)
                )
            }
            return String(
                format: AppLocalized("最多可同时保留 %lld 个未完成邀请。未完成邀请会在创建 48 小时后自动过期，之后即可再次邀请。"),
                Int64(limit)
            )
        case .giftDailyInvitationLimit(let limit, let retryAt):
            if let retryAt {
                return String(
                    format: AppLocalized("24 小时内最多发送 %1$lld 个邀请。请于 %2$@ 后再试；未完成邀请会在创建 48 小时后自动过期。"),
                    Int64(limit),
                    Self.localizedDateTime(retryAt)
                )
            }
            return String(
                format: AppLocalized("24 小时内最多发送 %lld 个邀请。请稍后再试；未完成邀请会在创建 48 小时后自动过期。"),
                Int64(limit)
            )
        case .giftInvitationRateLimited(let retryAt):
            if let retryAt {
                return String(
                    format: AppLocalized("邀请数量已达当前上限。请于 %@ 后再试；未完成邀请会在创建 48 小时后自动过期。"),
                    Self.localizedDateTime(retryAt)
                )
            }
            return AppLocalized("邀请数量已达当前上限。未完成邀请会在创建 48 小时后自动过期，请稍后再试。")
        case .temporaryUnavailable: return AppLocalized("声音服务暂时不可用，请稍后重试")
        case .server: return AppLocalized("声音克隆请求失败")
        case .invalidResponse: return AppLocalized("声音克隆返回数据无效")
        }
    }

    var isQuotaExhausted: Bool {
        if case .quotaExhausted = self { return true }
        return false
    }

    private static func localizedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguageManager.shared.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
