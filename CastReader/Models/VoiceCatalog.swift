//
//  VoiceCatalog.swift
//  CastReader
//
//  后端权威 TTS 音色目录。网络目录必须完整通过 v1 contract 校验才会替换
//  本地 fallback 与服务端可选 voice 集合对齐；用户已保存的 voice id 永远不由目录刷新改写。
//

import Foundation
import Combine

struct VoiceOption: Identifiable, Equatable, Hashable {
    let code: String
    let name: String
    let isPro: Bool
    let lang: String
    let gender: String
    let tier: String
    let status: String
    let modelVersion: String
    let timestampMode: String
    let enabled: Bool
    let selectable: Bool
    let locale: String
    let tags: [String]
    let avatarURL64: String?
    let avatarURL256: String?
    let accent: String?
    let sourceModelVersion: String?
    let collection: String?
    let recommended: Bool
    let qualityGrade: String?
    let trainingDuration: String?
    let description: String?
    let descriptionZh: String?
    let bestFor: [String]
    let sampleURL: String?

    var id: String { code }

    init(
        code: String,
        name: String,
        isPro: Bool,
        lang: String,
        gender: String,
        tier: String? = nil,
        status: String = "ga",
        modelVersion: String = "static-v1",
        timestampMode: String = "word",
        enabled: Bool = true,
        selectable: Bool = true,
        locale: String = "",
        tags: [String] = [],
        avatarURL64: String? = nil,
        avatarURL256: String? = nil,
        accent: String? = nil,
        sourceModelVersion: String? = nil,
        collection: String? = nil,
        recommended: Bool = false,
        qualityGrade: String? = nil,
        trainingDuration: String? = nil,
        description: String? = nil,
        descriptionZh: String? = nil,
        bestFor: [String] = [],
        sampleURL: String? = nil
    ) {
        self.code = code
        self.name = name
        self.isPro = isPro
        self.lang = lang
        self.gender = gender
        self.tier = tier ?? (isPro ? "pro" : "free")
        self.status = status
        self.modelVersion = modelVersion
        self.timestampMode = timestampMode
        self.enabled = enabled
        self.selectable = selectable
        self.locale = locale
        self.tags = tags
        self.avatarURL64 = avatarURL64
        self.avatarURL256 = avatarURL256
        self.accent = accent
        self.sourceModelVersion = sourceModelVersion
        self.collection = collection
        self.recommended = recommended
        self.qualityGrade = qualityGrade
        self.trainingDuration = trainingDuration
        self.description = description
        self.descriptionZh = descriptionZh
        self.bestFor = bestFor
        let normalizedSampleURL = sampleURL?.trimmed
        self.sampleURL = normalizedSampleURL?.isEmpty == false ? normalizedSampleURL : nil
    }
}

/// 音色浏览器使用的语言摘要。列表由服务端 catalog 驱动，新增语言无需改客户端枚举。
struct VoiceCatalogLanguageOption: Identifiable, Equatable {
    let code: String
    let locale: String
    let name: String
    let status: String
    let voiceCount: Int

    var id: String { code }
}

struct TTSVoiceCatalogLanguage: Codable, Equatable {
    let code: String
    let locale: String
    let name: String
    let status: String
    let defaultVoice: String
    let timestampMode: String
}

struct TTSVoiceCatalogAvatar: Codable, Equatable {
    let id: String?
    let url64: String?
    let url256: String?
}

struct TTSVoiceCatalogVoice: Codable, Equatable {
    let id: String
    let name: String
    let engine: String
    let modelVersion: String
    let language: String
    let locale: String
    let genderPresentation: String
    let tier: String
    let status: String
    let enabled: Bool
    let selectable: Bool
    let timestampMode: String
    let tags: [String]?
    let avatar: TTSVoiceCatalogAvatar?
    let sampleUrl: String?
    let accent: String?
    let sourceModelVersion: String?
    let collection: String?
    let recommended: Bool?
    let qualityGrade: String?
    let trainingDuration: String?
    let description: String?
    let descriptionZh: String?
    let bestFor: [String]?
}

struct TTSVoiceCatalogDocument: Codable, Equatable {
    static let expectedContract = "tts-voice-catalog-v1"

    let contract: String
    let version: String
    let languages: [TTSVoiceCatalogLanguage]
    let voices: [TTSVoiceCatalogVoice]

    static func decodeServerResponse(from data: Data) throws -> TTSVoiceCatalogDocument {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(TTSVoiceCatalogDocument.self, from: data) {
            try direct.validate()
            return direct
        }
        let envelope = try decoder.decode(TTSVoiceCatalogEnvelope.self, from: data)
        guard let catalog = envelope.data ?? envelope.catalog else {
            throw VoiceCatalogError.missingCatalog
        }
        try catalog.validate()
        return catalog
    }

    func validate() throws {
        guard contract == Self.expectedContract else { throw VoiceCatalogError.contractMismatch }
        guard !version.trimmed.isEmpty, !languages.isEmpty, !voices.isEmpty else {
            throw VoiceCatalogError.incompleteCatalog
        }

        var languageCodes = Set<String>()
        for language in languages {
            let code = VoiceCatalog.normalizedLanguage(language.code)
            guard !code.isEmpty,
                  SupportedTTSLanguage(identifier: code) != nil,
                  !language.locale.trimmed.isEmpty,
                  !language.name.trimmed.isEmpty,
                  !language.status.trimmed.isEmpty,
                  !language.defaultVoice.trimmed.isEmpty,
                  !language.timestampMode.trimmed.isEmpty,
                  languageCodes.insert(code).inserted else {
                throw VoiceCatalogError.incompleteCatalog
            }
        }

        var voiceIDs = Set<String>()
        for voice in voices {
            let language = VoiceCatalog.normalizedLanguage(voice.language)
            guard !voice.id.trimmed.isEmpty,
                  !voice.name.trimmed.isEmpty,
                  !voice.engine.trimmed.isEmpty,
                  !voice.modelVersion.trimmed.isEmpty,
                  !language.isEmpty,
                  !voice.locale.trimmed.isEmpty,
                  !voice.genderPresentation.trimmed.isEmpty,
                  !voice.tier.trimmed.isEmpty,
                  !voice.status.trimmed.isEmpty,
                  !voice.timestampMode.trimmed.isEmpty,
                  languageCodes.contains(language),
                  voiceIDs.insert(voice.id).inserted else {
                throw VoiceCatalogError.incompleteCatalog
            }
        }

        for language in languages {
            let code = VoiceCatalog.normalizedLanguage(language.code)
            guard voices.contains(where: {
                $0.id == language.defaultVoice && VoiceCatalog.normalizedLanguage($0.language) == code
            }) else {
                throw VoiceCatalogError.incompleteCatalog
            }
        }
    }
}

private struct TTSVoiceCatalogEnvelope: Decodable {
    let data: TTSVoiceCatalogDocument?
    let catalog: TTSVoiceCatalogDocument?
}

enum VoiceCatalogError: Error, Equatable {
    case missingCatalog
    case contractMismatch
    case incompleteCatalog
    case invalidResponse
}

enum VoiceCatalogSource: String, Equatable {
    case fallback
    case cache
    case network
}

private struct VoiceCatalogCacheRecord: Codable {
    let savedAt: Date
    let catalog: TTSVoiceCatalogDocument
}

private final class VoiceCatalogRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var catalog: TTSVoiceCatalogDocument?

    func read() -> TTSVoiceCatalogDocument? {
        lock.lock()
        defer { lock.unlock() }
        return catalog
    }

    func replace(with catalog: TTSVoiceCatalogDocument?) {
        lock.lock()
        self.catalog = catalog
        lock.unlock()
    }
}

enum VoiceCatalog {
    private static let runtime = VoiceCatalogRuntime()

    // 英文 fallback 与 english-31 的 28 个 selectable v1.0 voice 对齐。
    // 头像和试听仍以网络 catalog 为准，fallback 只保留稳定选择合同字段。
    static let english: [VoiceOption] = [
        fallbackEnglish("af_heart", "Heart", gender: "female", isPro: false, accent: "American"),
        fallbackEnglish("af_alloy", "Alloy", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("af_aoede", "Aoede", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("af_bella", "Bella", gender: "female", isPro: false, accent: "American"),
        fallbackEnglish("af_jessica", "Jessica", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("af_kore", "Kore", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("af_nicole", "Nicole", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("af_nova", "Nova", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("af_river", "River", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("af_sarah", "Sarah", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("af_sky", "Sky", gender: "female", isPro: true, accent: "American"),
        fallbackEnglish("am_adam", "Adam", gender: "male", isPro: false, accent: "American"),
        fallbackEnglish("am_echo", "Echo", gender: "male", isPro: true, accent: "American"),
        fallbackEnglish("am_eric", "Eric", gender: "male", isPro: true, accent: "American"),
        fallbackEnglish("am_fenrir", "Fenrir", gender: "male", isPro: true, accent: "American"),
        fallbackEnglish("am_liam", "Liam", gender: "male", isPro: true, accent: "American"),
        fallbackEnglish("am_michael", "Michael", gender: "male", isPro: true, accent: "American"),
        fallbackEnglish("am_onyx", "Onyx", gender: "male", isPro: true, accent: "American"),
        fallbackEnglish("am_puck", "Puck", gender: "male", isPro: true, accent: "American"),
        fallbackEnglish("am_santa", "Santa", gender: "male", isPro: true, accent: "American"),
        fallbackEnglish("bf_alice", "Alice", gender: "female", isPro: true, accent: "British"),
        fallbackEnglish("bf_emma", "Emma", gender: "female", isPro: false, accent: "British"),
        fallbackEnglish("bf_isabella", "Isabella", gender: "female", isPro: true, accent: "British"),
        fallbackEnglish("bf_lily", "Lily", gender: "female", isPro: true, accent: "British"),
        fallbackEnglish("bm_daniel", "Daniel", gender: "male", isPro: true, accent: "British"),
        fallbackEnglish("bm_fable", "Fable", gender: "male", isPro: true, accent: "British"),
        fallbackEnglish("bm_george", "George", gender: "male", isPro: true, accent: "British"),
        fallbackEnglish("bm_lewis", "Lewis", gender: "male", isPro: true, accent: "British"),
    ]

    static let chinese: [VoiceOption] = [
        .init(code: "zf_001", name: "晓萱", isPro: false, lang: "zh", gender: "female", timestampMode: "segment"),
        .init(code: "zm_009", name: "云泽", isPro: false, lang: "zh", gender: "male", timestampMode: "segment"),
        .init(code: "zf_017", name: "晓雅", isPro: true, lang: "zh", gender: "female", timestampMode: "segment"),
        .init(code: "zf_027", name: "晓柔", isPro: true, lang: "zh", gender: "female", timestampMode: "segment"),
        .init(code: "zf_046", name: "晓悦", isPro: true, lang: "zh", gender: "female", timestampMode: "segment"),
        .init(code: "zf_079", name: "晓晴", isPro: true, lang: "zh", gender: "female", timestampMode: "segment"),
        .init(code: "zm_029", name: "云朗", isPro: true, lang: "zh", gender: "male", timestampMode: "segment"),
        .init(code: "zm_033", name: "云辰", isPro: true, lang: "zh", gender: "male", timestampMode: "segment"),
        .init(code: "zm_095", name: "云谦", isPro: true, lang: "zh", gender: "male", timestampMode: "segment"),
        .init(code: "zm_098", name: "云瀚", isPro: true, lang: "zh", gender: "male", timestampMode: "segment"),
    ]

    /// 网络目录/缓存尚未到达时也能为九种语言解析正确的默认音色。
    /// 这里只保留每种新增语言的免费默认音色；完整音色与元数据仍以服务端为准。
    static let multilingualDefaults: [VoiceOption] = SupportedTTSLanguage.allCases
        .filter { $0 != .english && $0 != .chinese }
        .map {
            VoiceOption(
                code: $0.defaultVoiceID,
                name: $0.defaultVoiceName,
                isPro: false,
                lang: $0.rawValue,
                gender: "female",
                timestampMode: $0.timestampMode,
                locale: $0.localeIdentifier
            )
        }

    static let fallbackAll: [VoiceOption] = english + chinese + multilingualDefaults

    static var all: [VoiceOption] {
        guard let catalog = runtime.read() else { return fallbackAll }
        let remote = catalog.voices.map(option(from:))
        let remoteLanguages = Set(remote.map { normalizedLanguage($0.lang) })
        return remote + fallbackAll.filter { !remoteLanguages.contains(normalizedLanguage($0.lang)) }
    }

    static var selectableVoices: [VoiceOption] {
        all.filter(\.selectable)
    }

    /// 九语产品顺序就是浏览器展示顺序；没有可选音色的远端语言使用静态安全默认。
    /// 离线或首次启动时每种语言都有安全默认，网络目录到达后替换为完整音色元数据。
    static var availableLanguages: [VoiceCatalogLanguageOption] {
        guard let catalog = runtime.read() else {
            return SupportedTTSLanguage.allCases.map { language in
                VoiceCatalogLanguageOption(
                    code: language.rawValue,
                    locale: language.localeIdentifier,
                    name: language.catalogName,
                    status: language == .english || language == .chinese ? "ga" : "offline-default",
                    voiceCount: voices(for: language.rawValue).count
                )
            }
        }

        let counts = Dictionary(grouping: catalog.voices.filter(\.selectable)) {
            normalizedLanguage($0.language)
        }.mapValues(\.count)

        return SupportedTTSLanguage.allCases.compactMap { supported in
            let language = catalog.languages.first(where: {
                normalizedLanguage($0.code) == supported.rawValue
            })
            let code = supported.rawValue
            let count = counts[code] ?? fallbackAll.filter {
                normalizedLanguage($0.lang) == code && $0.selectable
            }.count
            guard count > 0 else { return nil }
            return VoiceCatalogLanguageOption(
                code: code,
                locale: language?.locale ?? supported.localeIdentifier,
                name: language?.name ?? supported.catalogName,
                status: language?.status ?? "offline-default",
                voiceCount: count
            )
        }
    }

    static func languageOption(for language: String) -> VoiceCatalogLanguageOption? {
        let normalized = normalizedLanguage(language)
        return availableLanguages.first { $0.code == normalized }
    }

    /// selectable 是选择器可见性的唯一权威；status 只描述质量/维护状态。
    static func voices(for language: String) -> [VoiceOption] {
        let normalized = normalizedLanguage(language)
        guard let catalog = runtime.read() else {
            return fallbackAll.filter { normalizedLanguage($0.lang) == normalized }
        }
        let remote = catalog.voices
            .filter {
                normalizedLanguage($0.language) == normalized && $0.selectable
            }
            .map(option(from:))
        return remote.isEmpty
            ? fallbackAll.filter { normalizedLanguage($0.lang) == normalized && $0.selectable }
            : remote
    }

    static func option(for code: String) -> VoiceOption? {
        if let remote = runtime.read()?.voices.first(where: { $0.id == code }) {
            return option(from: remote)
        }
        return fallbackAll.first { $0.code == code }
    }

    static func displayName(for code: String) -> String {
        option(for: code)?.name ?? code
    }

    static func isFree(_ code: String) -> Bool {
        option(for: code)?.isPro == false
    }

    static func defaultFreeVoice(for language: String) -> String {
        voices(for: language).first { !$0.isPro }?.code ?? fallbackDefault(for: language)
    }

    /// 所有朗读/解读入口都通过这里解析 voice。任意语言的已保存偏好优先，
    /// 未保存时采用远端权威 defaultVoice，目录不可用才走静态安全 fallback。
    static func resolvedVoice(preferred: String, for language: String) -> String {
        let normalized = normalizedLanguage(language)
        let value = preferred.trimmed
        if !value.isEmpty { return value }
        if let remoteDefault = runtime.read()?.languages.first(where: {
            normalizedLanguage($0.code) == normalized
        })?.defaultVoice.trimmed, !remoteDefault.isEmpty {
            return remoteDefault
        }
        return fallbackDefault(for: language)
    }

    static func hasRemoteCatalog() -> Bool { runtime.read() != nil }

    static func install(_ catalog: TTSVoiceCatalogDocument) throws {
        try catalog.validate()
        runtime.replace(with: catalog)
    }

    static func resetForTesting() {
        runtime.replace(with: nil)
    }

    static func normalizedLanguage(_ language: String) -> String {
        let value = language.trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
        return value.split(separator: "-").first.map(String.init) ?? ""
    }

    private static func defaultVoice(for language: String) -> String {
        let normalized = normalizedLanguage(language)
        if let value = runtime.read()?.languages.first(where: {
            normalizedLanguage($0.code) == normalized
        })?.defaultVoice.trimmed, !value.isEmpty {
            return value
        }
        return fallbackDefault(for: normalized)
    }

    private static func fallbackDefault(for language: String) -> String {
        SupportedTTSLanguage(identifier: language)?.defaultVoiceID ?? Constants.TTS.defaultVoice
    }

    private static func fallbackEnglish(
        _ code: String,
        _ name: String,
        gender: String,
        isPro: Bool,
        accent: String
    ) -> VoiceOption {
        VoiceOption(
            code: code,
            name: name,
            isPro: isPro,
            lang: "en",
            gender: gender,
            modelVersion: "v1.0",
            locale: accent == "British" ? "en-GB" : "en-US",
            accent: accent
        )
    }

    private static func option(from voice: TTSVoiceCatalogVoice) -> VoiceOption {
        VoiceOption(
            code: voice.id,
            name: voice.name,
            isPro: voice.tier.lowercased() != "free",
            lang: normalizedLanguage(voice.language),
            gender: voice.genderPresentation,
            tier: voice.tier,
            status: voice.status,
            modelVersion: voice.modelVersion,
            timestampMode: voice.timestampMode,
            enabled: voice.enabled,
            selectable: voice.selectable,
            locale: voice.locale,
            tags: voice.tags ?? [],
            avatarURL64: voice.avatar?.url64,
            avatarURL256: voice.avatar?.url256,
            accent: voice.accent,
            sourceModelVersion: voice.sourceModelVersion,
            collection: voice.collection,
            recommended: voice.recommended ?? false,
            qualityGrade: voice.qualityGrade,
            trainingDuration: voice.trainingDuration,
            description: voice.description,
            descriptionZh: voice.descriptionZh,
            bestFor: voice.bestFor ?? [],
            sampleURL: voice.sampleUrl
        )
    }
}

@MainActor
final class VoiceCatalogService: ObservableObject {
    static let shared = VoiceCatalogService()

    @Published private(set) var revision = 0
    @Published private(set) var source: VoiceCatalogSource = .fallback
    @Published private(set) var isRefreshing = false

    private static let cacheKey = "tts_voice_catalog_v2_nine_language_cache"
    private static let minimumRefreshInterval: TimeInterval = 15 * 60

    private let session: URLSession
    private let defaults: UserDefaults
    private let endpoint: URL
    private let now: () -> Date
    private var started = false
    private var lastNetworkRefreshAt: Date?

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        endpoint: URL = URL(string: Constants.API.ttsCatalog)!,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.defaults = defaults
        self.endpoint = endpoint
        self.now = now
    }

    func start() {
        guard !started else { return }
        started = true
        _ = loadCachedCatalog()
        Task { await refresh(force: true) }
    }

    func refreshIfStale() async {
        await refresh(force: false)
    }

    func refresh(force: Bool = true) async {
        guard !isRefreshing else { return }
        if !force,
           let lastNetworkRefreshAt,
           now().timeIntervalSince(lastNetworkRefreshAt) < Self.minimumRefreshInterval {
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 12
            request.setValue(TTSVoiceCatalogDocument.expectedContract, forHTTPHeaderField: "x-catalog-contract")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw VoiceCatalogError.invalidResponse
            }
            let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(from: data)
            try VoiceCatalog.install(catalog)
            let record = VoiceCatalogCacheRecord(savedAt: now(), catalog: catalog)
            defaults.set(try JSONEncoder().encode(record), forKey: Self.cacheKey)
            lastNetworkRefreshAt = now()
            source = .network
            revision &+= 1
            debugLog("network version=\(catalog.version) voices=\(catalog.voices.count)")
        } catch {
            debugLog("refresh failed source=\(source.rawValue) error=\(error.localizedDescription)")
        }
    }

    @discardableResult
    func loadCachedCatalog() -> Bool {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return false }
        do {
            let record = try JSONDecoder().decode(VoiceCatalogCacheRecord.self, from: data)
            try VoiceCatalog.install(record.catalog)
            lastNetworkRefreshAt = record.savedAt
            source = .cache
            revision &+= 1
            debugLog("cache version=\(record.catalog.version) voices=\(record.catalog.voices.count)")
            return true
        } catch {
            defaults.removeObject(forKey: Self.cacheKey)
            debugLog("cache rejected error=\(error.localizedDescription)")
            return false
        }
    }

    func clearCacheForTesting() {
        defaults.removeObject(forKey: Self.cacheKey)
        VoiceCatalog.resetForTesting()
        source = .fallback
        lastNetworkRefreshAt = nil
        revision &+= 1
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[VoiceCatalog] \(message)")
        #endif
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
